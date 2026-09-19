# Annex

A way to put your own screens in the reMarkable sidebar, alongside the stock
library, without replacing xochitl.

An app is a directory with a manifest and a QML file. There is no build step,
no resource bundle and no registration call — you drop it in and re-run the
index.

## Install

Plug the tablet in over USB and run this **on your computer** — it drives the
device over ssh, so if the device has no ssh key it asks for its password once:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuret/annex/main/install.sh | sh
```

### What this does to your device

You are entitled to know before piping a script into a shell. It:

- **installs xovi and its `qt-resource-rebuilder` extension** into
  `/home/root/xovi`, from the pinned upstream release bundle, if they are not
  already there. An xovi you already have is left alone.
- **adds two systemd drop-ins to `xochitl.service`**: one setting
  `LD_PRELOAD`/`XOVI_ROOT` so xochitl loads xovi, one ordering it after
  `/home` is mounted.
- **installs Annex** under `/home/root/annex`, and one QML patch file
  (`annex.qmd`) where the extension looks for it.
- **installs two systemd units**: a template for app backends, and one that
  restores `qt-resource-rebuilder` at boot if a package manager removes it.
- **restarts xochitl once**, at the end, and checks three things in the journal
  to prove Annex actually loaded.
- **asks — never assumes — whether to add your ssh public key**, if the device
  has none, so later runs need no password.

It does not touch xochitl's binary, your documents, or the package manager's
state. It downloads xovi from upstream rather than shipping a copy: that
binary is GPL-3.0 and Annex redistributes none of it.

Everything in it is idempotent, so running it again is safe and is how you
update. `sh install.sh --uninstall` reverses all of it except xovi, and leaves
your apps and their data in place.

Annex is developed and tested against **OS 3.28.0.172** on a reMarkable Paper
Pro. On any other build the installer warns and asks before continuing.

**Writing an app:** [`docs/APPS.md`](docs/APPS.md).

That is measured, not aspirational. On 3.28.0.172 the host loaded an app's QML
straight off the filesystem, and QML's own source attribution proves where the
running code came from:

```
[annex] opening hello from /home/root/annex/apps/hello
[hello] unloading (unloading file:///home/root/annex/apps/hello/ui/Main.qml:28)
```

AppLoad has no loose-file fallback — it registers a `resources.rcc` and the
manifest's `entry` is a path inside it — so an AppLoad app needs Qt's `rcc` to
build at all. An Annex app needs nothing.

## The thing Annex does that the alternatives do not

An Annex app is parented **inside the navigator**. That one decision is the
whole reason this exists:

- your app draws over the library, like any other screen
- an open document draws over **your app**
- closing the document leaves your app exactly where it was

So an app can hand a document to the stock reader and still be there when the
reader closes. Under AppLoad v0.5.1+ an app's window draws *above* the document,
so an app that opens one must hide or close itself first, and the user comes
back to the library rather than to the app. Under Oxide the question does not
arise, because xochitl is paused (SIGSTOP) while another app runs — which also
means no calls into xochitl's own library, reader or HTTP interface.

Annex is for apps that want to work **with** xochitl. If you want to replace it,
use Oxide; it is better at that than this will ever be.

## What Annex does not do

- **No windowing.** One app on screen at a time, filling the navigator. No
  floating windows, no split view, no task switcher.
- **No app store, no sandbox, no permissions.** An app is QML running inside
  xochitl with everything that implies. Install what you trust.
- **No stability promise across OS updates.** Annex patches xochitl's QML by
  matching element names, so when reMarkable moves those, Annex needs
  retargeting. It fails soft: a missed anchor means no Annex, not a dead
  device. Annex uses no hashed identifiers anywhere, which is what turns that
  failure from a panic into a log line.

## An app

```
myapp/
  manifest.json
  ui/Main.qml
```

```json
{
    "id": "myapp",
    "name": "My App",
    "entry": "ui/Main.qml"
}
```

`id` must be unique and is used in logs; `name` is what appears in the sidebar;
`entry` is the QML loaded when it is tapped, relative to the app directory.

```qml
import QtQuick 2.5
import "../../../lib/Style.js" as Style

Item {
    id: app
    anchors.fill: parent

    signal close                 // emit it to put yourself away
    function unloading() { }     // optional; called before you are unloaded
    property string annexAppDir: ""   // set by the host after loading

    Rectangle { anchors.fill: parent; color: Style.paper }
}
```

That contract is AppLoad's on purpose. An app written for AppLoad needs its
manifest renamed and nothing else in the QML.

### Give the user a way out

**Annex draws no chrome around your app.** It fills the navigator, and there is
no host title bar, no close button and no launcher to fall back to. If your app
offers no way to leave, there is none — the user is stuck looking at it.

So emit `close` from somewhere they can always reach. A back control on your
first screen that says where it goes (`‹ Library`) is enough.

This bites when porting: an AppLoad app could leave its own top-level screen
with no exit, because AppLoad's chrome closed it. Quire had exactly that —
a `close()` call nothing could reach.

## An app with a backend

Only if you need one. An app that talks to an HTTP API is plain QML doing
`XMLHttpRequest` and ships no process at all.

If you do need one, put an executable at `backend/run` — a binary, or a script
that execs one:

```
myapp/
  manifest.json
  ui/Main.qml
  backend/run
```

Annex runs it as a systemd service (`annex-app@myapp`), so it keeps working
while your app is closed, restarts if it dies, and starts after `/home` is
mounted. There is no unit file to write and no path to configure; `backend/run`
existing is the whole declaration.

Your backend binds a loopback port of the kernel's choosing and publishes it,
with a token, to `/home/root/annex/run/<id>.json`. In Go that is one call — see
`backend/annex` in the Quire tree, which moves here in M4. Then talk to it:

```qml
import "../../../lib"

Backend {
    id: backend
    appId: "myapp"
    onMessage: function(type, data, b64) { ... }
}

// backend.send(42, {query: "hello"})
```

A message is `(int32 type, payload)` — AppLoad's protocol, tunnelled over
loopback HTTP rather than a unix socket. `DESIGN.md` §5 explains why, and why
it was not rewritten as REST.

Draw something for `backend.status === "starting"`. A service takes a moment,
and a screen that shows nothing looks broken rather than busy.

```sh
annex-service status      # what is running, and on which port
annex-service log myapp   # follow its journal
```

## Installing from a checkout

`install.sh` is the user path: no checkout, no xovi, one ssh password prompt.
`deploy.sh` is the developer path — it assumes the device already has xovi and
Annex, and only pushes the tree:

```sh
./deploy.sh                       # copies lib, tools and apps to the tablet
ssh root@10.11.99.1 'systemctl restart xochitl'
```

The two share their device-side half, `tools/annex-apply`, so "installed"
means one thing and is defined in one place. `install.sh` run from a checkout
uses the checkout rather than downloading.

Adding an app later is a copy plus `annex-index`; `annex.qmd` never changes.

## Getting it back off

```sh
ssh root@10.11.99.1 '/home/root/annex/tools/annex-disable'
```

Removes the injection and restarts xochitl. Apps, their data and the library
stay. `annex-enable` puts it back.

This works when the screen does not: SSH is independent of xochitl, since both
network interfaces are brought up by systemd. That is the escape hatch, and it
is a script rather than a line in a README because the moment you need it is
the moment the screen is not helping you.

## What Annex depends on, and what removes it

Annex is applied by xovi's `qt-resource-rebuilder` extension. That `.so` reads
`annex.qmd` and patches xochitl's QML; without it, Annex is a directory of
files nothing loads. Annex is not a package, so **nothing on the device records
that dependency** — and both ways it breaks are silent.

Ask, in one command:

```sh
ssh root@10.11.99.1 '/home/root/annex/tools/annex-extension check'
```

It reports the extension, the safety copy, `annex.qmd`, the boot-ordering
drop-in, the self-heal unit, and whether `qt-resource-rebuilder` is pinned in
`/etc/apk/world`. It exits non-zero when Annex is broken or will be after the
next reboot.

### A package manager can take the extension

On 2026-09-19, removing AppLoad through ReManager (a GUI over `vellum`) did
this:

```
(1/3) Purging appload
(2/3) Purging xovi-extensions
(3/3) Purging qt-resource-rebuilder
```

AppLoad owned the extension as a dependency. Annex needs it too, nothing said
so, and it was collected as an orphan — after which Annex simply was not in the
sidebar. No error, no log line, nothing to explain it. `/etc/apk/world`, the
set of explicitly-wanted packages that survives orphan cleanup, is empty on
this device, so anything else that owns the extension can do it again.

So every install keeps a copy — `annex-apply`, which both `install.sh` and
`deploy.sh` call, runs `annex-extension vendor`, which copies the live
`extensions.d/qt-resource-rebuilder.so` to `/home/root/annex/vendor/`, and
`annex-extension.service` runs `annex-extension restore` at boot, ordered
`Before=xochitl.service` because the extension is read when xochitl starts. If
the extension is gone and the copy is there, it comes back and says so loudly
in the journal.

The copy is made **on the device and is not in this repository** — it is a 9 MB
third-party GPL binary. Annex also does not edit `/etc/apk/world`; that is the
package manager's state, and `check` reports it rather than fighting over it.

### xochitl can start before `/home` is mounted

`/home` is encrypted and mounts late. xochitl is started with
`LD_PRELOAD=/home/root/xovi/xovi.so`, and the stock unit is ordered
`After=data.mount` only, so on a cold boot xochitl can win the race:

```
ERROR: ld.so: object '/home/root/xovi/xovi.so' from LD_PRELOAD cannot be
preloaded (cannot open shared object file): ignored.
```

"ignored" — the boot succeeds, xochitl runs, and the device is stock with no
xovi and no Annex. Installing adds a drop-in with `After=home.mount` to
`xochitl.service`. It is **ordering only**: if `/home` ever fails to mount, the
tablet must still come up as stock xochitl rather than wedge with no screen to
explain itself.

Do not trust `xovi-boot.service` here. It runs `xovi-autostart.sh`, which looks
for a `xovi/start` script the **vellum-packaged** xovi does not ship — its
layout differs from the upstream release tarball — logs that it is missing and
exits 0, so it reports `active (exited) status=0/SUCCESS` while doing nothing.
`annex-extension check` calls that out, because a unit that lies by succeeding
is how this stayed undiagnosed. `install.sh` installs the upstream bundle,
which has the complete tree.

### Both survive a reboot

The unit and the drop-in are written *underneath* the `/etc` overlay through a
bind mount of `/`, the same mechanism `annex-service` uses for the backend
template — `/etc` here has a tmpfs upper layer, so a plain `cp` into it is gone
at the next boot, which is precisely the boot these two are meant to survive.
Only the unit and the drop-in go on the rootfs (it is ~90% full); the 9 MB
`.so` stays on `/home`.

## The shared library

`lib/` holds what is useful to more than one app:

- `Style.js` — the stock palette, type scale and touch targets, plus the e-ink
  rules that go with them (no animations, no spinners, pages rather than
  scrolling)
- `Backend.qml` — the connection to your backend, including discovery, the
  poll loop, clean detach, and recovery when systemd restarts it under you

More lands here as apps need it, extracted from working code rather than
invented in advance.

## Status

Early. Tested on 3.28.0.172 only.

Proven on hardware: the sidebar entry appears, the host draws over the library,
a document opened from the host draws over the host and leaves it in place on
close, and app discovery finds installed apps.

Proven off-device only: loading an app's QML from the filesystem, the
manifest-driven sidebar, and the whole backend transport — which is tested
end-to-end against the real Quire backend on a development host, but has not
yet run on the tablet.

Not started: the component library (keyboard, pager, confirm strip).

`docs/APPS.md` is the developer documentation — the app contract, a walkthrough,
icons, backends, how Annex compares to AppLoad and Oxide, and what this panel
will not let you get away with. `DESIGN.md` records the decisions and why the
alternatives were rejected.
