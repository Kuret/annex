# Writing an Annex app

How to build an app that appears in the reMarkable sidebar, what the contract
is, and what this hardware will and will not let you get away with.

Written 2026-09-19, against reMarkable Paper Pro OS 3.28.0.172. Where something
here was measured on the device, the measurement is included — this is a small
framework on an undocumented platform, and "it works" is worth less than "here
is what it printed".

`DESIGN.md` is the companion: it says *why* each of these decisions is the way
it is, and which alternatives were rejected.

---

## Before anything else

You need Annex on a device:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuret/annex/main/install.sh | sh
```

and a way to copy files to it — `ssh` and `tar`, which is all `deploy.sh` uses.

You do **not** need a toolchain, a cross-compiler, Qt's `rcc`, a container, or
a build step of any kind. An app is a directory of files. If you find yourself
compiling something, it is your backend and it is your choice (§5).

---

## 1. The app contract

An app is a directory under `/home/root/annex/apps/`:

```
myapp/
  manifest.json      required
  ui/Main.qml        required (the path is yours; the manifest names it)
  icon.svg           optional
  backend/run        optional
```

### `manifest.json`

```json
{
    "id": "myapp",
    "name": "My App",
    "entry": "ui/Main.qml",
    "icon": "icon.svg"
}
```

| field   | required | what it is |
| ------- | -------- | ---------- |
| `id`    | yes      | unique, used in log lines, in the backend service name (`annex-app@myapp`) and in the endpoint file name. Keep it to what is safe in a filename and a systemd unit instance: lowercase, digits, hyphens. |
| `name`  | yes      | what the user reads in the sidebar. |
| `entry` | yes      | QML loaded when the entry is tapped, **relative to the app directory**. |
| `icon`  | no       | SVG beside the sidebar entry, relative to the app directory. §4. |

An app missing `id`, `name` or `entry` is skipped with a line in the log and
the rest of the apps still load:

```
[annex] /home/root/annex/apps/myapp: manifest needs id, name and entry
```

A manifest that is not valid JSON is skipped the same way, with the parse
error. Nothing about one bad app takes down the others or xochitl.

The directory name and the `id` do not have to match, but make them match. The
directory is what `annex-service` instantiates units from and what you will
type at 2am.

### The entry QML

```qml
import QtQuick 2.5
import "../../../lib/Style.js" as Style

Item {
    id: app
    anchors.fill: parent

    signal close                      // emit it to put yourself away
    function unloading() { }          // optional; called before unload
    property string annexAppDir: ""   // set by the host after loading

    Rectangle { anchors.fill: parent; color: Style.paper }
}
```

Four things, and only the first is strictly required:

- **`anchors.fill: parent`.** The host is an `Item` filling the navigator and
  your root is loaded into it. Nothing sizes you if you do not.

- **`signal close`.** The host connects to it on load; emitting it unloads the
  app and returns to the library. This is AppLoad's signal, with AppLoad's
  name, on purpose — see §6.

- **`function unloading()`.** Called before the app is unloaded, inside a
  `try`, so throwing from it is logged and does not wedge the close. Stop
  timers here, detach your backend here (§5).

- **`property string annexAppDir`.** The host assigns your app's absolute
  directory after loading, if the property exists. It is how you find your own
  files — an image, a JSON file you ship — without hardcoding where Annex was
  installed:

  ```qml
  Image { source: "file://" + app.annexAppDir + "/art/cover.png" }
  ```

  Note the `file://` there. For an ordinary QML `Image` a scheme is correct;
  for a *sidebar icon* it is fatal. §4 explains why they differ.

### Give the user a way out

**Annex draws no chrome around your app.** No title bar, no close button, no
launcher behind you. There is a floor — swipe down from the top edge, which is
xochitl's own close-the-document gesture, wired to close the app — but a
gesture is not discoverable, and an app whose only exit is one is an app people
get stuck in.

Put a control on your first screen that says where it goes:

```qml
Text {
    text: "‹ Library"
    MouseArea { anchors.fill: parent; anchors.margins: -40; onClicked: app.close() }
}
```

This is the single most common porting bug from AppLoad, and it bit this
project's first app: AppLoad drew chrome that closed the app, so an AppLoad app
could reach its own first screen with no exit and still be usable. Under Annex
that is a dead end. `DESIGN.md` §14 has the story.

### What the host does not give you

No lifecycle callbacks beyond `unloading()`. No suspend/resume, no "you are
about to be covered by a document", no event bus, no settings store, no
permissions, no packaging metadata, no versioning. If you need state, write a
file; your app directory is writable and so is anywhere else on `/home/root`.

---

## 2. Walkthrough: the smallest app that works

`examples/hello` in this repository is the worked example, and it exists
precisely because it is small enough to read in one go. It is **not** deployed
by `deploy.sh` — the framework does not put a stray entry in your sidebar
uninvited — so installing it is the first thing you will do by hand, which
makes it the walkthrough.

### Copy it to the device

```sh
tar cf - -C examples hello | ssh root@10.11.99.1 'tar xf - -C /home/root/annex/apps'
```

(`scp -r examples/hello root@10.11.99.1:/home/root/annex/apps/` does the same;
`tar` is what the rest of this project uses because it preserves modes, which
matters the moment you have a `backend/run`.)

### Re-index and restart

```sh
ssh root@10.11.99.1 '/home/root/annex/tools/annex-index && systemctl restart xochitl'
```

`annex-index` writes `/home/root/annex/apps.index`, a newline-delimited list of
app directories that the host reads at startup. **Adding an app is a copy and
that one command.** `annex.qmd` never changes, nothing is rebuilt, nothing is
registered.

The restart is needed because the host discovers apps in
`Component.onCompleted` — once, when xochitl's QML loads.

### What you should see

In the sidebar: a **Hello** entry under the stock ones. Tapping it draws the
app over the library.

In the journal, which is where you will live while developing:

```sh
ssh root@10.11.99.1 'journalctl -u xochitl -f' | grep -i annex
```

```
[annex] 1 app(s) installed
[annex] opening hello from /home/root/annex/apps/hello
[hello] unloading (unloading file:///home/root/annex/apps/hello/ui/Main.qml:28)
```

That middle pair is worth understanding, because it is the proof the whole
design rests on. The second line is QML's own source attribution on a
`console.log` inside the app: the running code really did come from a file on
disk, loaded by path, with no resource bundle anywhere. `DESIGN.md` §4 records
it as a measurement for exactly that reason.

### Now make it yours

```sh
cp -r examples/hello /tmp/myapp
# edit /tmp/myapp/manifest.json: id, name
# edit /tmp/myapp/ui/Main.qml
tar cf - -C /tmp myapp | ssh root@10.11.99.1 'tar xf - -C /home/root/annex/apps'
ssh root@10.11.99.1 '/home/root/annex/tools/annex-index && systemctl restart xochitl'
```

The edit-test loop is that last line, which takes a few seconds and costs you a
xochitl restart. There is no hot reload. A QML error does not crash anything:
the host shows a "could not load" screen with a way back to the library, and
the reason is in the journal.

### Using the shared library

`lib/` is at `/home/root/annex/lib`, which from
`apps/<id>/ui/Main.qml` is three directories up:

```qml
import "../../../lib/Style.js" as Style   // palette, type scale, touch targets
import "../../../lib"                     // components, e.g. Backend
```

`Style.js` is imported as a file, `lib` as a directory of types. Both are plain
local imports — there is no module registration and no `QML2_IMPORT_PATH` to
set.

---

## 3. Reading and writing files

The host reads manifests over `XMLHttpRequest` against `file://` URLs, and so
can you:

```qml
var xhr = new XMLHttpRequest();
xhr.open("GET", "file://" + app.annexAppDir + "/data/state.json");
```

This works because `qt-resource-rebuilder`'s own systemd drop-in sets
`QML_XHR_ALLOW_FILE_READ=1` on xochitl. It is not Annex's doing, and it is one
more thing that stops working if something removes that extension (§7).

Writing is not available from QML. If your app needs to persist more than
`Qt.labs.settings` gives you, that is what a backend is for.

---

## 4. Icons

An icon is a **48×48 SVG of solid black paths**, like the stock set. Match
that and your entry looks like it belongs; do anything else and it looks like
a sticker someone put on the device.

The one rule that will otherwise cost you an evening:

> **The `icon` path must resolve to a plain filesystem path. No scheme.**

The manifest holds a path relative to your app directory (`"icon": "icon.svg"`)
and the host makes it absolute. Do not put a URL in it.

This is not a style preference, it is the sidebar's image pipeline. A
`SidebarItem` does not use a plain `Image`: it hands the source to an ark
`Icon`, which calls `ArkImageDataProvider.resolveImageInfo(source, …)` and
renders the SVG itself. That provider accepts a filesystem path or a `qrc:`
path and nothing else. Measured against it directly on 3.28.0.172:

```
/home/root/annex/apps/quire/icon.svg            -> 48x48   ok
file:///home/root/annex/apps/quire/icon.svg     -> -1x-1   fails
qrc:/ark/icons/ebook                            -> 48x48   ok
```

A `data:` URI fails the same way. Both failures report "Could not find", which
reads like a missing file and is really an unsupported source — which is why
this is written down rather than left to be rediscovered.

`icon` is optional. Without one the source is empty, the ark `Icon` makes
itself invisible, and your entry looks exactly as sidebar entries did before
icons existed. That is a perfectly good place to start.

Inside your own app, none of this applies: an ordinary QML `Image` wants a URL,
so `"file://" + annexAppDir + "/icon.svg"` is right there and wrong in the
manifest. The asymmetry is annoying and it is the platform's, not ours.

---

## 5. Backends

**Most apps do not need one.** An app that talks to an HTTP API is plain QML
doing `XMLHttpRequest`, and ships no process at all. Under AppLoad's socket
transport such an app would have needed a relay process existing only to
satisfy the transport; here it needs nothing. Reach for a backend when you need
to do work while the screen is closed, run something native, or write files.

### The contract

Put an executable at `backend/run` — a binary, or a script that execs one:

```
myapp/
  manifest.json
  ui/Main.qml
  backend/run        must be executable
```

That is the entire declaration. **Apps do not ship unit files.** Annex provides
one systemd template, `annex-app@.service`, instantiated per app, and
`annex-service sync` (which `annex-apply` runs on every deploy) enables one for
every app that has a `backend/run` and disables one for every app that lost it.

Your process is started with:

```
WorkingDirectory=/home/root/annex/apps/<id>
ANNEX_APP_ID=<id>
ANNEX_ROOT=/home/root/annex
ANNEX_RUN=/home/root/annex/run
ANNEX_APP_DIR=/home/root/annex/apps/<id>
```

### A backend outlives the screen

This is the part that surprises people, and it is deliberate. The unit does not
require xochitl. Your backend:

- keeps running with the app closed, and across a xochitl restart
- starts at boot, after `home.mount` (the app directory is on an encrypted
  volume that mounts late)
- is restarted if it dies (`Restart=on-failure`, `RestartSec=2`)
- **stays dead after five failures in 60 seconds.** A broken install is not
  something to retry forever on a battery. The endpoint file stays gone and
  your app's screen should say the backend is not running — which is the truth.
- gets `SIGTERM` for shutdown, with 20 seconds to finish

So "downloads continue while the user reads a book" is not something you
arrange; it is what happens unless you stop it.

### Publishing an endpoint

Bind `127.0.0.1:0` — the kernel picks the port — mint a 32-byte random token,
and write both to `$ANNEX_RUN/<id>.json` at mode 0600, **to a temp path and
then rename**:

```json
{"port": 41537, "token": "…", "pid": 1234}
```

There is no port registry and nothing in the manifest, so two apps cannot
collide and no app can squat a port. Remove the file on shutdown *before* the
port stops answering. `ExecStopPost` removes it too, for a backend killed hard.

Never bind `0.0.0.0`. The tablet already serves a web interface on
`10.11.99.1`; an app backend must not become a second listener reachable over
the cable.

### Talking to it from QML

```qml
import "../../../lib"

Backend {
    id: backend
    appId: "myapp"
    onMessage: function(type, data, b64) {
        if (type === 42) { var j = JSON.parse(data); … }
    }
}

// backend.send(42, {query: "hello"})
```

`Backend.qml` does discovery, the long poll, retries, clean detach, and
recovery when systemd restarts the backend under it with a new port and token.
Its `status` is one of `idle`, `starting`, `connected`, `error`, with a
human-readable `detail`.

**Draw something for `starting`.** A service takes a moment after the app
opens, and a screen that shows nothing looks broken rather than busy.

**Call `backend.stop()` from `unloading()`.** That posts a clean detach. The
backend has a 45-second silence timeout as a backstop, but without the explicit
call it believes the app is open for most of a minute, and anything it stops
when the frontend leaves keeps running.

### The wire protocol

A message is `(int32 type, payload)` — AppLoad's protocol, tunnelled over
loopback HTTP:

```
POST /msg      X-Annex-Type: <int32>   body: the payload bytes
GET  /events?wait=<ms>  → {"messages":[{"type":41,"data":"…"}]}
POST /detach
```

Every request carries `X-Annex-Token` and `X-Annex-Client`. A request with an
`Origin` header is refused outright — a browser has no business here.

`data` is a string; `"b64": true` means the payload was not valid UTF-8 and
`data` is base64. System message types keep AppLoad's numbering (`-1`
terminate, `-2` new coordinator, `-3` lost coordinator), so a backend written
against `appload.Conn` ports by changing one import. `DESIGN.md` §5–§12 covers
the transport in full, including why it is a long poll and not SSE.

### Operating it

```sh
annex-service status        # what is running, and on which port
annex-service log myapp     # follow its journal
annex-service restart myapp
```

---

## 6. How Annex compares to AppLoad and Oxide

All three put something of yours in front of the user. They are not
substitutes, and picking the wrong one costs a rewrite.

|                         | **Annex** | **AppLoad** | **Oxide** |
| ----------------------- | --------- | ----------- | --------- |
| xochitl                 | keeps running, patched QML | keeps running, patched QML | paused (SIGSTOP) while an app runs |
| an app is               | a directory of loose files | a `resources.rcc` you build with Qt's `rcc` | a native application |
| build step              | none | `rcc`, plus a toolchain for a backend | a full cross-toolchain |
| an open document draws  | **over your app**, which stays loaded behind it | under your app (v0.5.1+), so you must hide or close first | not applicable — xochitl is frozen |
| app windows             | one, filling the navigator | one, with host chrome | a real window manager, task switcher, multiple apps |
| backends                | systemd unit per app, loopback HTTP | host-spawned `SOCK_SEQPACKET` socket | its own service model |
| maturity                | early; one OS version, weeks old | established, many apps | established, large, years old |

### What Annex actually gives you

**An app is loose files.** No resource bundle, so no `rcc`, so no Qt build on
the machine you are writing on, so no CI to keep a toolchain alive. Edit a
`.qml`, copy it over, restart xochitl, look at it. AppLoad has no loose-file
fallback — it registers a `.rcc` and the manifest's `entry` is a path *inside*
it — so an AppLoad app cannot be built without `rcc` at all.

**An open document draws over your app, and your app is still there when it
closes.** The host is parented inside the navigator, so the document view —
which lives later in `MainView` — is above it. Your app can hand a file to the
stock reader and get the user back afterwards, with reading position, pen
annotations and every bit of xochitl's own machinery intact, none of which you
had to reimplement. This is the single decision Annex exists for.

### What Annex does not do, and will not

- **No windowing.** One app at a time, filling the navigator. No floating
  windows, no split view, no task switcher. Oxide does this; Annex will not.
- **No sandbox, no permissions, no app store.** An app is QML running inside
  xochitl as root, with everything that implies. Install what you trust.
- **No stability promise across OS updates.** Annex patches xochitl's QML by
  matching element names, so when reMarkable moves them, Annex needs
  retargeting. It fails soft — a missed anchor means no Annex, not a dead
  device — because there are no hashed identifiers anywhere, which is what
  turns that failure from a panic into a log line. But "your app will keep
  working next year" is not on offer from anybody in this space.
- **No native UI toolkit.** You get QtQuick 2.5 as xochitl's QML engine
  exposes it, plus whatever ark controls you can reach. There is no widget set
  of Annex's own beyond what is in `lib/`.
- **Nothing like Oxide's reach.** Oxide replaces the environment: it can run
  anything, because xochitl is not running. The price is that xochitl's
  library, reader and HTTP interface are all unavailable while it does.
  Choose by which of those two sentences describes your app.

**If you want to replace xochitl, use Oxide.** It is better at that than this
will ever be. Annex is for apps that want to work *with* xochitl.

### Porting an AppLoad app

The QML contract is AppLoad's deliberately: same `signal close`, same
`unloading()`, same root-`Item` shape. In practice a port is:

1. rename the manifest fields to `id`/`name`/`entry` and point `entry` at a
   path on disk instead of inside the `.rcc`;
2. drop the `.rcc` and its build;
3. swap the backend's transport constructor (§5);
4. **add an exit to your first screen** — the one that AppLoad's chrome was
   providing for you, and the one thing that will otherwise strand your users.

---

## 7. Designing for this hardware

These are not stylistic preferences. Each one is something this device does
that a desktop does not, and `lib/Style.js` encodes them so that an app that
just uses the palette and the scale gets most of them for free.

**No animations, transitions or fades.** E-ink ghosts: a control that redraws
continuously leaves a smear of its previous positions behind it. There is no
animation subtle enough to be worth that. Change state in one step.

**No spinners.** Same reason, plus a spinner on a panel that refreshes about
once a second is a lie about how much is happening. Progress is discrete text
that changes a few times — "12 of 340" — and it is more informative anyway.

**Pages, not scrolling.** A list that reflows under a finger is the ghosting
problem wearing a different hat, and the panel cannot track the motion. Page
through fixed-size screens of content.

**Large touch targets.** A finger on e-ink has no hover state, no cursor and no
second chance: nothing shows the user where they are about to hit. `Style.js`
sets `rowHeight` 96 and `buttonHeight` 72 for that reason, and where a control
is visually small, extend its `MouseArea` with negative margins rather than
making the control bigger.

**Colour, if you use it at all, as solid areas — never as glyphs or thin
strokes.** The Paper Pro's colour is a filter layer over the monochrome panel:
black text is drawn at the panel's full resolution, while anything coloured
goes through the filter and comes out at a fraction of it. Coloured text and
hairline coloured rules look soft and dirty next to black ones at the same
size. A block of colour behind black text reads fine; coloured text does not.
Default to the stock look — black on white with hairline rules — and treat
colour as a highlight over an area, if at all.

**Follow the stock UI.** There is no accent colour, no logo colour and no
second typeface in `Style.js`, and that is not an oversight. An app that
invents a brand looks like a stranger on the device, and users notice it in
precisely the way you do not want.

---

## 8. Troubleshooting

### Ask the device, in one command

```sh
ssh root@10.11.99.1 '/home/root/annex/tools/annex-extension check'
```

It reports the extension, Annex's safety copy of it, `annex.qmd`, the
boot-ordering drop-in, the self-heal unit, and whether `qt-resource-rebuilder`
is pinned in `/etc/apk/world`. It exits non-zero when Annex is broken **or will
be after the next reboot**, which is the failure nobody thinks to look for.

### Where the logs are

```sh
ssh root@10.11.99.1 'journalctl -u xochitl -f'      # the host, qmldiff, your QML
ssh root@10.11.99.1 'journalctl -u annex-app@myapp -f'   # your backend
```

Everything the host prints is prefixed `[annex]`; `Backend.qml` prints
`[annex/<appId>]`. `console.log` from your QML appears here with QML's own
file-and-line attribution, which is the cheapest debugging on this platform and
frequently the only kind.

Lines worth recognising:

```
[qmldiff]: Loading file annex.qmd          the patch was found
[annex] 3 app(s) installed                 the host ran and read the index
[annex] opening myapp from /home/root/…    your app is being loaded
[annex] myapp: bad manifest: …             your JSON
[annex] failed to load myapp: …            your QML
```

### The sidebar entry is missing

In order of likelihood:

1. `annex-index` was not re-run, or xochitl was not restarted. Both.
2. The manifest is missing a required field or is not valid JSON — the journal
   says which.
3. **A package manager removed `qt-resource-rebuilder`.** This is not
   hypothetical: on 2026-09-19 removing AppLoad through ReManager purged the
   extension as an orphan, because AppLoad owned it and Annex's claim on it
   existed nowhere. Annex left the sidebar with no error and no log line.
   `annex-extension check` names it; `annex-extension restore` puts Annex's own
   copy back; a reboot does it automatically via `annex-extension.service`.
4. The QML anchors moved — a different OS build. qmldiff logs "Error while
   processing file tree: Cannot locate element in tree" and returns the
   original file. No Annex, working tablet.

### It worked yesterday, and then the device rebooted

**`/etc` on this device is an overlay with a tmpfs upper layer.** A file copied
into `/etc` — a unit, a drop-in — is gone at the next boot, while appearing to
work perfectly until then. Annex writes the files it needs there *underneath*
the overlay, through a bind mount of `/`. If you are writing tooling of your
own that touches `/etc`, this trap is waiting for you; `tools/annex-service`
and `tools/annex-extension` have the technique and the warnings that go with it
(the rootfs is ~90% full — only tiny files may go there).

A related trap: xochitl can win the race against the encrypted `/home` mount,
in which case `LD_PRELOAD=/home/root/xovi/xovi.so` fails with

```
ERROR: ld.so: object '/home/root/xovi/xovi.so' from LD_PRELOAD cannot be
preloaded (cannot open shared object file): ignored.
```

Note "ignored": the boot succeeds and the device comes up stock. Annex installs
an ordering-only drop-in (`After=home.mount`) against exactly this.

### Do not trust `xovi-boot.service`

It reports `active (exited) status=0/SUCCESS` while doing nothing at all: it
runs `xovi-autostart.sh`, which looks for a `xovi/start` script that some
builds do not ship, logs that it is missing and exits 0. **The
vellum-packaged xovi is laid out differently from the upstream tarball and has
no `xovi/start`**, so on those devices the unit is a permanent no-op wearing a
green light. Measured on hardware. `install.sh` installs the upstream bundle,
which is complete; `annex-extension check` calls out the no-op when it sees it.

### Your app is stuck on screen

Swipe down from the top edge — xochitl's own close-the-document gesture, wired
to close the app. If the QML thread is wedged, that will not fire either, and
ssh is the backstop:

```sh
ssh root@10.11.99.1 '/home/root/annex/tools/annex-disable'
```

That removes the injection and restarts xochitl. Apps, their data and the
library are untouched; `annex-enable` puts it back. SSH is independent of
xochitl — both network interfaces are brought up by systemd — so this works
when the screen does not.

### Your backend will not start

```sh
ssh root@10.11.99.1 'systemctl status annex-app@myapp'
```

- `backend/run` is not executable — the most common one, and it looks exactly
  like the file being absent. `annex-apply` chmods it on deploy; a file copied
  some other way keeps whatever mode it arrived with.
- Five failures in 60 seconds and it stops trying. Fix it, then
  `annex-service restart myapp`.
- No endpoint file and the unit is active: your backend is not writing
  `$ANNEX_RUN/<id>.json`, or is writing it somewhere else.
