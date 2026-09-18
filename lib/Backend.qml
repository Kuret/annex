import QtQuick 2.5

// Backend is an app's connection to its own backend process.
//
//     import "../../../lib"
//
//     Backend {
//         id: backend
//         appId: "quire"
//         onMessage: function(type, data) { ... }
//         onStatusChanged: ...
//     }
//
// It finds the backend by reading the endpoint file systemd's unit told it to
// write, then long-polls for messages. Nothing about the port or the token is
// configured anywhere: both are minted by the backend at startup and
// discovered here, so two apps cannot collide and a restarted backend is
// picked up without the user doing anything.
//
// An app that has no backend does not use this at all. That is the point of
// the design — a QML-only app talking to some HTTP API over XHR ships no
// process of its own, where AppLoad's socket transport would have required a
// relay that existed for no other reason.
Item {
    id: backend

    // ---- configuration -----------------------------------------------

    // appId must match the manifest id; it names the endpoint file.
    property string appId: ""

    // annexRoot is where Annex is installed. The host sets annexAppDir on an
    // app; this is the framework root above it.
    property string annexRoot: "/home/root/annex"

    // waitMs is how long the backend holds a poll with nothing to say. Set it
    // to 0 for fixed-interval polling instead, which behaves identically from
    // here and costs a request per retryMs.
    property int waitMs: 15000

    // retryMs is the pause before re-reading the endpoint file after a
    // failure. It is not a poll interval: a healthy connection re-issues
    // immediately.
    property int retryMs: 2000

    // autoStart connects as soon as the component is ready.
    property bool autoStart: true

    // ---- state -------------------------------------------------------

    // status is one of:
    //   "idle"       not started, or stopped
    //   "starting"   no endpoint file yet — the backend has not come up
    //   "connected"  polling successfully
    //   "error"      the endpoint exists but talking to it failed
    //
    // An app should draw something for "starting": a backend under systemd
    // takes a moment after the app opens, and a screen that shows nothing at
    // all in the meantime looks broken rather than busy.
    property string status: "idle"

    // detail is a sentence for the user when status is "starting" or "error".
    property string detail: ""

    // connected is the convenience binding most apps actually want.
    readonly property bool connected: status === "connected"

    // ---- signals -----------------------------------------------------

    // message carries one backend→frontend message. `data` is the payload as
    // text, which for every message Annex apps send so far is JSON; parse it
    // with JSON.parse. `b64` is true for a payload that was not valid UTF-8,
    // in which case `data` is base64 and the app knows what to do with it.
    signal message(int type, string data, bool b64)

    // failed reports a send that did not reach the backend. It is separate
    // from status because a single failed send is not necessarily a lost
    // connection, and an app may want to retry that one action.
    signal failed(int type, string reason)

    // ---- internals ---------------------------------------------------

    // clientId identifies this frontend instance to the backend, which uses it
    // to tell a reattach from an ordinary poll. Minted per component, so a
    // reloaded app looks like a new frontend — which it is.
    property string _clientId: "qml-" + Date.now() + "-" + Math.floor(Math.random() * 100000)

    property string _base: ""
    property string _token: ""
    property bool _running: false
    property var _poll: null

    visible: false

    function start() {
        if (_running) return;
        if (!appId) {
            _fail("error", "Backend needs an appId.");
            return;
        }
        _running = true;
        _discover();
    }

    // stop detaches cleanly and stops polling.
    //
    // Call it from the app's unloading(). The backend has a timeout as a
    // backstop, but it is deliberately longer than a poll — so without this
    // the backend keeps thinking the app is open for the better part of a
    // minute, and anything it stops when the frontend leaves (Quire pauses
    // downloads) keeps running.
    function stop() {
        if (!_running) return;
        _running = false;
        if (_poll) { try { _poll.abort(); } catch (e) {} _poll = null; }
        if (_base) _detach();
        _base = "";
        _token = "";
        _pending = [];
        status = "idle";
        detail = "";
    }

    // pendingMax bounds what send() holds while the backend is still being
    // discovered. Small on purpose: this is for the handful of messages an
    // app fires from Component.onCompleted, not a retry buffer.
    property int pendingMax: 32
    property var _pending: []

    // send posts one message. `payload` may be a string, an object (encoded as
    // JSON) or undefined for an empty payload.
    //
    // A send made before discovery finishes is **queued, not failed**. Apps
    // ask for their initial state in Component.onCompleted, which always runs
    // before the endpoint file has been read — reporting that as an error
    // would put a failure message on screen on every single launch, for a
    // condition that resolves itself a frame or two later.
    function send(type, payload) {
        var body = "";
        if (payload !== undefined && payload !== null) {
            body = (typeof payload === "string") ? payload : JSON.stringify(payload);
        }

        if (!_base) {
            if (_pending.length >= pendingMax) {
                // The backend is not merely slow, it is not coming. Now it is
                // worth saying so, once, rather than growing a queue nobody
                // will ever drain.
                failed(type, detail ? detail : "The backend is not running.");
                return false;
            }
            _pending.push({ "type": type, "body": body });
            return true;
        }
        return _post(type, body);
    }

    function _flushPending() {
        var queued = _pending;
        _pending = [];
        for (var i = 0; i < queued.length; i++)
            _post(queued[i].type, queued[i].body);
    }

    function _post(type, body) {

        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 204) return;
            if (xhr.status === 401) {
                // The backend restarted and minted a new token while we held
                // the old one. Re-read the endpoint rather than reporting a
                // failure the user can do nothing about.
                console.log("[annex/" + appId + "] token rejected; rediscovering");
                _rediscover("The backend restarted.");
                return;
            }
            failed(type, xhr.status === 0
                   ? "The backend is not responding."
                   : "The backend refused the message (" + xhr.status + ").");
        };
        try {
            xhr.open("POST", _base + "/msg");
            xhr.setRequestHeader("X-Annex-Token", _token);
            xhr.setRequestHeader("X-Annex-Client", _clientId);
            xhr.setRequestHeader("X-Annex-Type", String(type));
            xhr.setRequestHeader("Content-Type", "application/octet-stream");
            xhr.send(body);
        } catch (e) {
            failed(type, "Could not reach the backend: " + e);
            return false;
        }
        return true;
    }

    // _discover reads the endpoint file the backend published.
    function _discover() {
        if (!_running) return;
        var path = annexRoot + "/run/" + appId + ".json";
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            var ok = (xhr.status === 0 || xhr.status === 200) && xhr.responseText;
            if (!ok) {
                // No endpoint file means the backend has not started, or has
                // stopped. Neither is an error the user caused, and systemd
                // is probably already restarting it — so say "starting" and
                // keep looking.
                _fail("starting", "Starting " + appId + "…");
                _retry.restart();
                return;
            }
            var ep;
            try {
                ep = JSON.parse(xhr.responseText);
            } catch (e) {
                _fail("error", "The backend's endpoint file is unreadable.");
                _retry.restart();
                return;
            }
            if (!ep.port || !ep.token) {
                _fail("error", "The backend's endpoint file is incomplete.");
                _retry.restart();
                return;
            }
            _base = "http://127.0.0.1:" + ep.port;
            _token = ep.token;
            status = "connected";
            detail = "";
            console.log("[annex/" + appId + "] backend on port " + ep.port + " (pid " + ep.pid + ")");
            // Anything the app asked for before the backend was reachable —
            // typically its Component.onCompleted requests — goes now, in the
            // order it was asked for, and before the first poll so the replies
            // arrive on it.
            _flushPending();
            _pollOnce();
        };
        try {
            xhr.open("GET", "file://" + path);
            xhr.send();
        } catch (e) {
            _fail("error", "Cannot read " + path + ": " + e);
            _retry.restart();
        }
    }

    function _rediscover(why) {
        _base = "";
        _token = "";
        if (_poll) { try { _poll.abort(); } catch (e) {} _poll = null; }
        _fail("starting", why);
        _retry.restart();
    }

    function _fail(newStatus, why) {
        status = newStatus;
        detail = why;
    }

    // _pollOnce issues one long poll and re-issues on completion.
    //
    // This is an ordinary XHR that returns a complete response, not SSE: there
    // is no readyState 3 parsing anywhere, and setting waitMs to 0 turns it
    // into a fixed-interval poll without changing a line on either side.
    function _pollOnce() {
        if (!_running || !_base) return;

        var xhr = new XMLHttpRequest();
        _poll = xhr;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (!_running) return;
            _poll = null;

            if (xhr.status === 401) {
                _rediscover("The backend restarted.");
                return;
            }
            if (xhr.status !== 200) {
                // The backend went away mid-poll. systemd restarts it on
                // failure with a new port, so the answer is always to go back
                // to the endpoint file rather than to retry this address.
                _rediscover(xhr.status === 0
                            ? "Reconnecting to " + appId + "…"
                            : "The backend answered " + xhr.status + ".");
                return;
            }

            if (status !== "connected") { status = "connected"; detail = ""; }

            var body;
            try {
                body = JSON.parse(xhr.responseText);
            } catch (e) {
                console.log("[annex/" + appId + "] bad events body: " + e);
                _retry.restart();
                return;
            }
            var msgs = (body && body.messages) ? body.messages : [];
            for (var i = 0; i < msgs.length; i++) {
                var m = msgs[i];
                // Dispatch inside try/catch: one app handler throwing must not
                // stop the poll loop, or the app silently stops receiving
                // everything because of one bad message.
                try {
                    backend.message(m.type, m.data === undefined ? "" : m.data, m.b64 === true);
                } catch (e) {
                    console.log("[annex/" + appId + "] handler for type " + m.type + " threw: " + e);
                }
            }
            _pollOnce();
        };
        try {
            xhr.open("GET", _base + "/events?wait=" + waitMs);
            xhr.setRequestHeader("X-Annex-Token", _token);
            xhr.setRequestHeader("X-Annex-Client", _clientId);
            xhr.send();
        } catch (e) {
            _poll = null;
            _rediscover("Could not reach the backend: " + e);
        }
    }

    function _detach() {
        var xhr = new XMLHttpRequest();
        try {
            xhr.open("POST", _base + "/detach");
            xhr.setRequestHeader("X-Annex-Token", _token);
            xhr.setRequestHeader("X-Annex-Client", _clientId);
            xhr.send();
        } catch (e) {
            // Nothing to do: the backend's timeout is the backstop.
        }
    }

    Timer {
        id: _retry
        interval: backend.retryMs
        repeat: false
        onTriggered: backend._discover()
    }

    Component.onCompleted: if (autoStart) start()
    Component.onDestruction: stop()
}
