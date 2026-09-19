# Annex design decisions

Decisions, with the reasoning and the rejected alternatives. Read this before
changing anything here — several of these look arbitrary and are not.

Status: written 2026-09-18, against reMarkable Paper Pro OS 3.28.0.172.

---

## 1. The host is parented inside the navigator

An Annex app is the last child of `Navigator.qml`'s `FocusScope`, so it draws
over the library chrome and **under** the document view, which is later in
`MainView`.

That ordering is the reason Annex exists. It means an app can hand a document
to the stock reader and still be there when the reader closes — reading
position, pen annotations and all of xochitl's own machinery stay with
xochitl, and the app does not have to reimplement any of it.

**Rejected: `z` ordering.** The document view is nested inside the same branch
as the navigator, so no `z` value on the host can put the document above it.
The parent choice is the only lever.

**Rejected: an overlay that undoes AppLoad's own injection.** Directory `.qmd`
files are applied *before* an extension's programmatically registered diff, and
the extension depends on qt-resource-rebuilder. The ordering makes it
structurally impossible, not merely awkward.

**Rejected: a patched AppLoad fork.** It worked on 3.27 and is the smaller
change, but it leaves us maintaining a fork of someone else's host whose
upstream has said AI-written contributions are unwelcome — so the fix could
never go home, and every AppLoad release would have to be re-forked.

## 2. Zero hashed identifiers in the injection

`annex.qmd` uses element names only.

qmldiff has two failure modes and they are not comparable. A selector that
matches nothing logs an error and returns the original file: Annex does not
load, xochitl is fine, and `annex-disable` is not even needed. An
**unresolvable hashed identifier panics and takes xochitl down** — which is
what AppLoad did on 3.28.0.172, and the reason this project exists in its
current form.

Names also survive OS bumps that hashes do not. Using no hashes makes the panic
path unreachable by construction rather than by care.

## 3. Comment syntax inside INSERT blocks

`;` comments are legal only *outside* `INSERT`. Inside, the content is QML and
`;` parses as code, so the whole file fails to load. Use `//` inside INSERT.

This is a footgun with no diagnostic worth the name; it is written down because
it cost an afternoon.

## 4. Apps are discovered *and loaded* from the filesystem, not a bundle

An app is a directory with `manifest.json` and QML. The host reads
`apps.index`, then each manifest, over `XMLHttpRequest` against `file://` —
which works because qt-resource-rebuilder's drop-in sets
`QML_XHR_ALLOW_FILE_READ=1` on xochitl.

**The QML itself is then loaded by path, and this was measured rather than
assumed.** It is the load-bearing assumption of the whole design and the main
thing separating Annex from AppLoad, so it is recorded with its evidence.
2026-09-18, OS 3.28.0.172:

```
[annex] opening hello from /home/root/annex/apps/hello
[hello] unloading (unloading file:///home/root/annex/apps/hello/ui/Main.qml:28)
[annex] opening hello from /home/root/annex/apps/hello
```

The middle line is QML's own source attribution on a `console.log` from inside
the app: xochitl's `Loader` took a plain path, the running code really did come
from the filesystem, `unloading()` ran on close, and it reopened. AppLoad has
no loose-file fallback — it calls `QResource::registerResource()` on a
`resources.rcc` and the manifest's `entry` is a path *inside* that resource
tree — so an AppLoad app cannot be built without Qt's `rcc`, and Quire carried a
committed `prebuilt/resources.rcc` purely so that installing it needed only a
Go toolchain.

**There is therefore no build step anywhere in Annex.** No `.rcc`, no
registration call, no compiled host extension (§5), no cross-toolchain. An app
is a directory; adding one is a copy and `annex-index`, and `annex.qmd` never
changes. Everything else in this document is downstream of that being true.

**`apps.index` is newline-delimited paths and deliberately not JSON.** It is
written by a busybox shell script, where building JSON means quoting bugs, and
the host is already doing one XHR per app to read the manifests. A list of
paths has nothing to get wrong. It is written to a temp file and renamed,
because the host may be reading it while the indexer runs.

---

# The transport

## 5. The message protocol is AppLoad's; the transport is not

A message is `(int32 type, []byte payload)`. System types keep AppLoad's
numbering (`-1` terminate, `-2` new coordinator, `-3` lost coordinator).
`Conn` offers exactly `Send` and `Recv`, with the same semantics and the same
clean-shutdown signal.

A backend written against `appload.Conn` compiles against `annex.Conn` with the
import changed and nothing else. `TestSystemTypesMatchAppLoad` pins the
numbering so the claim cannot quietly stop being true.

Underneath, it is loopback HTTP.

### Why not the unix socket

AppLoad's transport is a `SOCK_SEQPACKET` socket that the **host** creates and
hands to the backend as `argv[1]`. Reproducing that under Annex needs something
to call `socketpair()`, fork the backend and relay bytes into QML. QML can do
none of those, so it needs a compiled xovi extension — which needs a C
cross-toolchain and CI to keep it alive, for every developer, forever.

That was measured, not assumed: there is no aarch64 C toolchain and no
container runtime on the development host, and Go cannot substitute because a
loadable `.so` needs `c-shared`, which needs CGO, which needs the same
toolchain.

**Annex has no compiled artefact anywhere, and this is the decision that buys
it.** systemd starts the backend, the backend binds a loopback port, and QML
talks to it with `XMLHttpRequest` — which it is already doing to read
manifests. The framework is QML, shell scripts, and whatever language an app's
backend happens to be written in. There is no build infrastructure to maintain,
which is the single biggest difference from AppLoad in day-to-day terms.

It also removes a whole class of pointless process. An app that talks to some
HTTP API — a monitor for a running agent session, say — needs **no backend of
its own** under this design: it is plain QML doing XHR. Under a socket
protocol it would have had to ship a relay process that existed only to satisfy
the transport.

### Why the protocol was tunnelled rather than rewritten as REST

The obvious move when switching to HTTP is to turn each message into an
endpoint. It was rejected.

Quire's `service` package, every handler, every message type and all of
`Answers.js` are written against `Handle(ctx, out, msgType, payload)` and a
`Sender`. Tunnelling keeps every one of them untouched, which makes the port a
transport swap **in fact** and not merely in name — the diff is one constructor
and a signal handler.

It also keeps the protocol a documented, reusable thing. Per-app REST would
dissolve it into a hundred local decisions, and the next app would start from
nothing.

So:

    POST /msg      X-Annex-Type: <int32>   body: the payload bytes
    GET  /events?wait=<ms>  → {"messages":[{"type":41,"data":"…"}]}
    POST /detach

`data` is a string, with `"b64":true` and base64 when the payload is not valid
UTF-8. Quire's payloads are all JSON so this never fires there, but the
transport carries `[]byte` and silently mangling a non-UTF-8 payload would be a
bug that surfaces only in whichever app first sends one.

## 6. Long-poll, not SSE, not fixed-interval polling

`GET /events` holds the request until something is queued or the deadline
passes, then returns a **complete** response. There is no `readyState === 3`
parsing anywhere; the QML side is an ordinary XHR it re-issues in its own
handler.

SSE was rejected: on e-ink the screen cannot usefully refresh faster than about
once a second, so streaming buys nothing and costs partial-response parsing.

Fixed-interval polling was considered and is still reachable — set `waitMs: 0`
and it becomes exactly that, with no change on either side. Long-poll is the
default because it is strictly better on both axes that matter here: download
progress arrives at once, and an **idle** app costs one request per 15 seconds
instead of fifteen. On a battery-powered device the idle case is the one that
adds up.

## 7. Who starts backends: systemd, one template unit

`annex-app@.service`, instantiated per app: `systemctl enable --now
annex-app@quire`.

**Apps do not ship unit files.** The framework provides the template, and an app
that wants a backend puts an executable at `apps/<id>/backend/run`. The
convention *is* the configuration.

**Rejected: a wrapper that reads the backend path out of the manifest.**
systemd cannot parse JSON, so this would be a busybox shell script picking a
field out of JSON — the same quoting bug §4 avoided, in a place where failure
means the backend does not start.

Consequences, all of them wanted:

- **Downloads continue with the app closed.** Quire relies on this, and it now
  falls out of the design rather than being arranged. The unit deliberately
  does not require xochitl.
- **`After=home.mount`.** `/home` is encrypted and mounts late; a backend
  started before it exists finds no app directory, no state and nowhere to
  write its endpoint file. This is the same thing that bites xovi on a cold
  boot.
- **A backend that dies is restarted** (`Restart=on-failure`, `RestartSec=2`),
  because the user's answer to "it stopped" should not have to be SSH.
- **A backend that keeps dying stays dead** (`StartLimitBurst=5`). A broken
  install is not something to retry forever on a battery; after the limit the
  endpoint file stays gone and the app's screen says the backend is not
  running, which is the truth and more use than a silent restart loop.
- **`ExecStopPost` removes the endpoint file**, so a backend killed hard does
  not leave a frontend talking to a port that stopped answering.

`annex-service sync` reconciles: it enables a service for every app with a
`backend/run`, disables one for every app that lost it, and stops units whose
app directory is gone. `deploy.sh` calls it, so adding a backend is a copy and
a deploy.

**`/etc` is writable on this device but is not preserved across an OS update.**
The unit template lives there and will be gone after one. Re-running
`deploy.sh` is what puts it back; that is the documented step rather than a
surprise, and it is the same re-run that retargets the injection.

## 8. Port allocation: the kernel decides

The backend binds `127.0.0.1:0` and writes the assigned port to
`run/<appId>.json`.

There is no registry, no port range and nothing in the manifest, so two apps
**cannot** collide and an app cannot squat a port something else wanted.
Collisions were named as a framework problem; this is the framework solving
them by not having them. The cost is that the port is unknowable in advance,
which is exactly what the endpoint file is for.

The file is written to a temp path and renamed. The frontend polls for it, and
a truncating write would hand it an empty file often enough to matter — a race
that would look like "the backend is not running".

It is removed on `Close`, **before** the port stops answering: while it exists
it advertises a port that is about to go away, and a frontend that reads a
stale one waits out a connection error instead of reporting the truth.

## 9. Binding and access: loopback, plus a token, and an honest limit

- **Bound to `127.0.0.1`.** The tablet already exposes a web interface on
  `10.11.99.1` over the cable. An app backend must not become a second listener
  reachable from it, so this is never `0.0.0.0`. A test asserts on the listen
  address, so "fixing" a connection problem by widening the bind fails loudly.
- **A 32-byte random token per process**, in the endpoint file at mode 0600,
  required on every request and compared in constant time.
- **Any request carrying an `Origin` header is refused outright.** A browser
  has no business here; refusing the whole class costs nothing.

**What the token is for, precisely:** it stops anything that cannot read the
endpoint file from talking to the backend — a second app, a stray script, a web
page the user has open reaching a loopback port that would otherwise answer to
anyone who guesses it.

**What it is not:** a boundary against a hostile process on the tablet.
Everything here runs as root, so such a process can simply read the file.
Saying otherwise would be a lie in the one place a reader would rely on it. The
real perimeter is that the port is unreachable from off the device at all.

## 10. Attach and detach

`SystemNewCoordinator` on the first request from a new client id;
`SystemLostCoordinator` on `POST /detach`, on a new client id replacing an old
one, or after `DetachAfter` of silence.

This matters more than it looks. Quire pushes its whole world on attach
(sources, watch list) precisely because AppLoad **dropped** messages aimed at a
backend whose socket was not yet up, which twice looked to the user like their
configured sources had been lost. And it stops downloads on detach, so a detach
that never fires means downloads that never stop.

- **`DetachAfter` (45s) must exceed the poll `Wait` (15–20s).** A frontend
  parked in a long poll is silent by design; treating that as a departure would
  detach a healthy app every poll. Outstanding polls are counted, not just
  timestamped, and both halves have a test.
- **A replaced client id produces a detach *then* an attach**, in that order.
  An app reloaded without a clean detach — QML crashed, xochitl restarted the
  view — must still run the backend's detach handler, or it is silently
  skipped.
- **The clean path is `POST /detach` from the app's `unloading()`.** The
  timeout is only the backstop; without the explicit call the backend thinks
  the app is open for the better part of a minute.

**On detach the outbound queue is dropped.** Whatever is in it was aimed at a
screen that no longer exists, and a reattaching frontend is sent the world
again — so delivering the backlog would replay stale progress over fresh state.
It also stops a backend that keeps working while nothing is attached from
slowly filling memory with undeliverable messages.

## 11. A full outbound queue drops the oldest

Bounded at 512. On overflow the oldest goes, and it is logged.

Blocking `Send` was rejected: a full queue means the frontend stopped
collecting — it crashed, or the device suspended mid-download — and a blocked
`Send` would wedge the download worker behind a UI that is never coming back.
Dropping the *newest* was rejected because it keeps a stale backlog and
discards current state, which is exactly backwards.

It is survivable only because every screen can be rebuilt from an attach push.
If this fires in normal use, the queue is too small or something upstream is
sending far too much — hence the log line.

## 12. SIGTERM is the terminate message

Under AppLoad the host sent `MessageSystemTerminate`. Under systemd the
equivalent is SIGTERM, and `quired` turns it into `Close`, which makes `Recv`
return `io.EOF` — the same clean-shutdown path the serve loop already had.

So an ordinary `systemctl stop` is not reported as a crash, and the session
marker is cleared properly. `SystemTerminate` is still defined, so the
numbering remains a complete description of the protocol, but nothing sends it.

## 13. Both transports are kept

`quired` picks by `argv[1]`: a socket path means AppLoad, anything else means
Annex.

They differ in one constructor, so keeping both is nearly free, and it means
the device can go back to AppLoad without a rebuild. That matters while only
one of the two has been proven on hardware. It is a temporary asymmetry, not a
permanent commitment to supporting two hosts.

---

## Sequencing

M2 (runtime) → M3 (port Quire: transport swap and manifest only) → M4 (extract
shared packages, with Quire as the consumer) → M5 (developer docs).

**Nothing is extracted before M3 works on hardware.** A 9k-line refactor and a
platform port at the same time is how both become undebuggable.

`backend/annex` therefore lives in Quire's tree for now, importing nothing but
the standard library, so M4's extraction is a directory move.

---

## 14. An app draws its own chrome, including its exit

Annex draws nothing around an app. No title bar, no close button, no launcher
to return to — the app fills the navigator and that is all.

That is consistent with §1 (the app *is* the navigator's content while it is
open) and it keeps the host to one job. The cost is a trap when porting from
AppLoad, which drew chrome that closed the app: an AppLoad app could leave its
own first screen with no exit and still be usable.

Quire had precisely that. `goBack()` on its first screen called `root.close()`,
and the Back label was blank there because AppLoad's chrome was the way out —
so under Annex the call was unreachable and the app was a dead end. The fix is
one line (the label reads `‹ Library` on the first screen), but finding it
needed someone to ask "how does the user leave?", which nothing else would
have forced.

**Every app must emit `close` from something reachable on its first screen.**
The README says so in the app contract, where a developer will meet it.

---

## 15. Annex repairs its own dependency, and does not pin it

Annex needs `qt-resource-rebuilder`. It is not a package, so nothing on the
device records that. Two measurements on 2026-09-19, both silent failures, both
on real hardware.

**Measurement: a package manager removed it.** Removing AppLoad through
ReManager (a GUI over `vellum`, apk-based):

```
(1/3) Purging appload
(2/3) Purging xovi-extensions
(3/3) Purging qt-resource-rebuilder
```

AppLoad owned the extension; Annex's claim on it existed nowhere, so it was
collected as an orphan. Annex left the sidebar with no error and no log line.
`/etc/apk/world` is empty on this device, so nothing is protected from this.

**Measurement: xochitl won the boot race.** `/home` is encrypted and mounts
late; `xochitl.service` was ordered `After=data.mount` and not
`After=home.mount`, and the LD_PRELOAD of `/home/root/xovi/xovi.so` failed:

```
ERROR: ld.so: object '/home/root/xovi/xovi.so' from LD_PRELOAD cannot be
preloaded (cannot open shared object file): ignored.
```

One line, severity "ignored", boot successful, device stock. The existing
`xovi-boot.service` reported `active (exited) status=0/SUCCESS` throughout,
while doing nothing: it runs `xovi-autostart.sh`, which looks for a `start`
script xovi 0.3.3 does not ship and exits 0. False confidence cost most of the
evening.

### The decision

Annex **vendors a copy of the extension on the device** and restores it at
boot, and adds an ordering-only drop-in to `xochitl.service`.

Rejected: *writing `qt-resource-rebuilder` into `/etc/apk/world`*. That is the
right fix and it is not ours — it is the package manager's state file, and a
deploy script editing it behind vellum's back is two tools owning one file.
`annex-extension check` reports that it is unpinned and lets a human decide.

Rejected: *committing the `.so`*. 9 MB of third-party GPL binary in a tree
whose entire premise is "apps are plain files, nothing is built". The copy is
taken from the live device at deploy time; `/home` has tens of gigabytes free.

Rejected: *`Requires=home.mount` on xochitl*. It would guarantee the ordering
and it would also take the UI down with an unmountable `/home`. This device has
already spent an evening unusable; a cold boot with a broken `/home` must still
land on a working stock xochitl. Ordering costs nothing when the mount is fine
and risks nothing when it is not.

Rejected: *fixing `xovi-boot.service`*. Not our unit. `check` names it as a
no-op instead, so nobody reads its green status as evidence again.

Rejected: *checking at xochitl start, from QML*. By then it is too late — the
extension is read when xochitl starts, so a check inside the injected QML only
runs in the case where everything already worked.

### Why both go under the overlay

`/etc` is an overlay with a tmpfs upper layer (§7 records finding that the hard
way with the backend template). A unit or drop-in copied into `/etc` is gone at
the next reboot — the same reboot the boot-ordering drop-in exists to survive,
which would have made it exactly as reliable as `xovi-boot.service`. Both are
written under a bind mount of `/`, warning and carrying on if that is
unavailable. Only these two tiny files; the rootfs is ~90% full.
