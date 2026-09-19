#!/bin/sh
# Install Annex on a reMarkable Paper Pro, from nothing, in one command.
#
#     curl -fsSL https://raw.githubusercontent.com/Kuret/annex/main/install.sh | sh
#
# **This runs on your computer and drives the tablet over ssh.** It is not
# copied to the device and run there. That is what makes the password case
# work: the tablet's ssh password can be typed into `ssh` on this side, once,
# and every step after that reuses the same connection.
#
#     ./install.sh [host]        host defaults to $ANNEX_DEVICE, then 10.11.99.1
#     ./install.sh --uninstall   remove Annex, leave xovi alone
#     ./install.sh --help
#
# This is the *user* path: it installs xovi, the systemd drop-in, Annex and its
# units on a device that has none of them, and it fetches the repository
# itself. `deploy.sh` is the *developer* path: it assumes all of that is
# already there and only pushes the tree. If you have a checkout and a working
# device, use deploy.sh — it is faster and it does not ask questions.
#
# Requirements on this side: a POSIX shell, curl, ssh and tar. macOS and Linux
# both have all four. Nothing is compiled, here or there.
#
# Requirements on the device: busybox and an ssh server, which is what it ships
# with. Every command sent to the tablet is written for busybox — no `timeout`,
# no `head -N`, no GNU-only flags — because the device has none of them and the
# failure mode of assuming otherwise is a step that silently does nothing.
set -eu

# ---------------------------------------------------------------------------
# Constants
#
# **The xovi release is pinned, and tracking "latest" is deliberately not an
# option.** An upstream release moves what an install produces without a line
# changing here, and the whole point of this script is that two people running
# it get the same device. Override it if you know why:
#
#     ANNEX_XOVI_RELEASE=some-other-tag sh install.sh
#
# The pinned tag is a pre-release. That is not an oversight — it is what
# upstream currently publishes for aarch64.
XOVI_RELEASE="${ANNEX_XOVI_RELEASE:-pre-v20-08092026}"
XOVI_URL="https://github.com/asivery/rm-xovi-extensions/releases/download/$XOVI_RELEASE/xovi-aarch64.tar.gz"

TARBALL_URL=https://codeload.github.com/Kuret/annex/tar.gz/refs/heads/main

TESTED_OS=3.28.0.172

ROOT=/home/root/annex
XOVI=/home/root/xovi
QMD_DIR="$XOVI/exthome/qt-resource-rebuilder"
EXT="$XOVI/extensions.d/qt-resource-rebuilder.so"
XOVI_DROPIN=/etc/systemd/system/xochitl.service.d/00-xovi.conf

DEV_USER="${ANNEX_DEVICE_USER:-root}"

say()  { echo "annex: $*"; }
warn() { echo "annex: warning: $*" >&2; }
die()  { echo "annex: $*" >&2; exit 1; }
step() { echo; echo "annex: == $*"; }

usage() {
    cat <<'EOF'
Install Annex on a reMarkable Paper Pro over ssh.

    install.sh [host]        install (host defaults to $ANNEX_DEVICE, then
                             10.11.99.1 — the USB cable address)
    install.sh --uninstall [host]
                             remove Annex and its units. Leaves xovi, and
                             leaves your apps and their data in /home/root/annex/apps.
    install.sh --help        this

Environment:
    ANNEX_DEVICE             default host
    ANNEX_DEVICE_USER        ssh user (default: root)

What it does to your device:

  * installs xovi and its qt-resource-rebuilder extension into /home/root/xovi,
    from the pinned upstream bundle, if they are absent. An existing xovi is
    left alone.
  * adds two systemd drop-ins to xochitl.service: one to set LD_PRELOAD for
    xovi, one to order xochitl after /home is mounted
  * installs Annex under /home/root/annex and one QML patch file under xovi
  * installs a systemd template for app backends and a unit that restores
    qt-resource-rebuilder if a package manager removes it
  * restarts xochitl once, at the end
  * asks — never assumes — whether to add your ssh public key, if the device
    has none

It does not modify xochitl's binary, your documents, or the package manager's
state. `install.sh --uninstall` reverses all of it except xovi.
EOF
}

# ---------------------------------------------------------------------------
# Prompts
#
# **Every prompt reads /dev/tty, never stdin.** In the advertised one-liner the
# script *is* stdin: a `read` without this consumes the rest of the installer
# and runs half of it. ssh's own password prompt already uses /dev/tty, which
# is why the password case needs nothing special here.
#
# With no controlling terminal — a CI job, a cron line — there is nobody to
# ask, so the default stands and the script says which way it went rather than
# hanging on a tty that will never answer.
ask() {
    prompt="$1"
    default="$2"        # y or n
    if [ ! -r /dev/tty ]; then
        say "no terminal to ask on; assuming \"$default\" for: $prompt"
        [ "$default" = y ]
        return
    fi
    if [ "$default" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf 'annex: %s %s ' "$prompt" "$hint" > /dev/tty
    read -r reply < /dev/tty || reply=""
    [ -n "$reply" ] || reply="$default"
    case "$reply" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Arguments

MODE=install
HOST=""
for arg in "$@"; do
    case "$arg" in
        --help|-h)   usage; exit 0 ;;
        --uninstall) MODE=uninstall ;;
        -*)          die "unknown option: $arg (try --help)" ;;
        *)           HOST="$arg" ;;
    esac
done
[ -n "$HOST" ] || HOST="${ANNEX_DEVICE:-10.11.99.1}"

# ---------------------------------------------------------------------------
# Working directory and the ssh control socket
#
# Deliberately under /tmp and not $TMPDIR. The control socket path goes into a
# `sockaddr_un`, which is 104 bytes on macOS including the terminator, and
# macOS's $TMPDIR is a ~50-character path under /var/folders — long enough that
# "$TMPDIR/annex.XXXXXX/cm-root@10.11.99.1:22" is uncomfortably close to the
# limit. A socket that is silently not created means every step re-prompts for
# the password, which is the one thing this script exists to avoid.
WORK=$(mktemp -d /tmp/annex-install.XXXXXX) || die "could not create a temp directory"
CM="$WORK/cm-%r@%h:%p"
MASTER_UP=no

cleanup() {
    if [ "$MASTER_UP" = yes ]; then
        ssh -o ControlPath="$CM" -O exit "$DEV_USER@$HOST" >/dev/null 2>&1 || true
        MASTER_UP=no
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# dev runs one command on the tablet over the shared connection. Every remote
# command in this script goes through it, so there is exactly one place where
# the multiplexing options live.
dev() {
    # `-n` is load-bearing, not tidiness. Under the advertised
    # `curl ... | sh`, this script's stdin is the pipe carrying the script
    # itself; ssh inherits that stdin and swallows the remainder, so the
    # install stopped after the first remote command and exited 0 having done
    # nothing. Measured 2026-09-19 against the published one-liner.
    ssh -n -o ControlPath="$CM" -o ControlMaster=no "$DEV_USER@$HOST" "$@"
}

# dev_stdin is dev for the calls that *want* stdin: streaming a tarball into
# `tar x`, or a file into `cat >` / `cmp -`. It deliberately omits -n.
#
# Getting this split wrong is not a subtle failure. `ssh -n` redirects ssh's
# stdin from /dev/null, which silently overrides a `< file` redirection on the
# caller — so a `dev "cat > x" < f` wrote a **zero-byte** file, which is how
# the xovi drop-in came to be empty and xochitl started without LD_PRELOAD on
# 2026-09-19. Anything that feeds bytes to the device belongs here; everything
# else belongs in dev, or `curl | sh` eats the rest of the script.
dev_stdin() {
    ssh -o ControlPath="$CM" -o ControlMaster=no "$DEV_USER@$HOST" "$@"
}

# ---------------------------------------------------------------------------
# 1. Reach the device, and find out how it wants to authenticate
#
# The probe is a BatchMode ssh, which never prompts. Three outcomes, and they
# are distinguishable, which matters because "cannot connect" and "needs a
# password" have completely different fixes:
#
#   exit 0                     key auth works — the whole install is unattended
#   "Permission denied"        the host answered, so it is reachable and the
#                              only thing missing is credentials
#   anything else              no route, refused, timed out: a cable problem

step "device: $DEV_USER@$HOST"

probe_err="$WORK/probe.err"
AUTH=""
if ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
       "$DEV_USER@$HOST" true 2>"$probe_err"; then
    AUTH=key
elif grep -qi 'permission denied\|no supported authentication\|too many authentication' "$probe_err"; then
    AUTH=password
elif grep -qi 'host key verification failed\|remote host identification has changed' "$probe_err"; then
    # An OS update regenerates the tablet's host key, so this is a routine
    # event here rather than a sign of anything sinister — and it would
    # otherwise be reported as "check your cable", which is a fix that cannot
    # work.
    echo "annex: the device's ssh host key has changed, which an OS update does." >&2
    sed 's/^/annex:   /' "$probe_err" >&2 || true
    echo "annex: if that is the explanation, forget the old key and run this again:" >&2
    echo "annex:     ssh-keygen -R $HOST" >&2
    exit 1
else
    echo "annex: cannot reach $DEV_USER@$HOST." >&2
    sed 's/^/annex:   /' "$probe_err" >&2 || true
    cat >&2 <<EOF

annex: things to check, in the order they are usually wrong:
annex:   * the USB cable is plugged in and the tablet is awake
annex:   * 10.11.99.1 is the tablet's USB address; over wifi, pass its IP:
annex:         sh install.sh 192.168.1.42
annex:   * the tablet's ssh password is under Settings -> Help -> Copyrights,
annex:     at the bottom, together with the address it is listening on
annex:   * "USB web interface" must be enabled in Settings -> Storage for the
annex:     USB network to come up at all
EOF
    exit 1
fi

if [ "$AUTH" = key ]; then
    say "authenticating with an ssh key — this install is unattended"
else
    say "no ssh key on the device; ssh will ask for its password once"
    say "it is under Settings -> Help -> Copyrights, at the bottom of the page"
fi

# One master connection for the whole run. -f backgrounds it *after*
# authentication, so the password prompt (on /dev/tty, from ssh itself) happens
# here and nowhere else; every `dev` call after this reuses the open channel.
ssh -f -N -o ControlMaster=yes -o ControlPath="$CM" -o ControlPersist=5m \
    -o StrictHostKeyChecking=accept-new "$DEV_USER@$HOST" \
    || die "could not open the ssh connection to $DEV_USER@$HOST"
MASTER_UP=yes
dev true || die "the shared ssh connection did not come up"

offer_key() {
    PUBKEY=""
    for k in "${HOME:-}/.ssh/id_ed25519.pub" "${HOME:-}/.ssh/id_ecdsa.pub" "${HOME:-}/.ssh/id_rsa.pub"; do
        if [ -f "$k" ]; then PUBKEY="$k"; break; fi
    done
    if [ -n "$PUBKEY" ]; then
        say "found a public key at $PUBKEY"
        if ask "Install it on the device so future runs need no password?" n; then
            key=$(cat "$PUBKEY")
            case "$key" in
                # The key is interpolated into a remote shell command in single
                # quotes. A key whose comment contains one would break out of
                # them, so it is refused rather than escaped cleverly.
                *\'*) warn "that key contains a quote character; not installing it"; key="" ;;
            esac
            if [ -n "$key" ]; then
                # Appended only if it is not already there, so this cannot grow
                # a file of duplicates across runs.
                if dev "mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh &&
                        touch /home/root/.ssh/authorized_keys &&
                        chmod 600 /home/root/.ssh/authorized_keys;
                        grep -qxF '$key' /home/root/.ssh/authorized_keys ||
                        echo '$key' >> /home/root/.ssh/authorized_keys"; then
                    say "installed your public key; the next run will not ask"
                else
                    warn "could not install the key; carrying on with the password"
                fi
            fi
        else
            say "not installing a key"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Uninstall takes the short path out.

uninstall() {
    step "removing Annex"

    if dev "[ -x $ROOT/tools/annex-disable ]"; then
        # This is the tool that knows how to stop backends and put xochitl back
        # the way it was; it also restarts xochitl, so the UI is stock from
        # here on and the rest of this is tidying.
        dev "$ROOT/tools/annex-disable" || warn "annex-disable reported a problem"
    else
        say "no annex-disable on the device; removing what is there"
        dev "rm -f $QMD_DIR/annex.qmd $QMD_DIR/annex.qmd.disabled"
    fi

    # The unit and the two drop-ins exist in /etc *and* underneath the overlay,
    # and only the second copy survives a reboot — so removing the live one
    # alone would resurrect Annex's units at the next boot. annex-extension is
    # what owns that mechanism; use it while it is still installed.
    if dev "[ -x $ROOT/tools/annex-extension ]"; then
        dev "$ROOT/tools/annex-extension unpersist /etc/systemd/system/annex-extension.service" || true
        dev "$ROOT/tools/annex-extension unpersist /etc/systemd/system/xochitl.service.d/01-annex-wait-for-home.conf" || true
        dev "$ROOT/tools/annex-extension unpersist /etc/systemd/system/annex-app@.service" || true
        dev "$ROOT/tools/annex-extension unpersist /etc/systemd/system/multi-user.target.wants/annex-extension.service" || true
    else
        warn "annex-extension is gone; units under the /etc overlay may survive a reboot"
    fi

    dev "systemctl disable --now annex-extension.service >/dev/null 2>&1; true"
    dev "rm -f /etc/systemd/system/annex-extension.service \
                /etc/systemd/system/xochitl.service.d/01-annex-wait-for-home.conf \
                /etc/systemd/system/annex-app@.service \
                /etc/systemd/system/multi-user.target.wants/annex-extension.service"
    dev "systemctl daemon-reload || true"

    # Annex's own files go; apps and their data stay. Deleting somebody's
    # reading state because they uninstalled a framework is not a decision an
    # installer gets to make silently — it prints the one command that does it.
    dev "rm -rf $ROOT/lib $ROOT/tools $ROOT/systemd $ROOT/vendor $ROOT/run \
                $ROOT/apps.index $ROOT/README.md"

    say "Annex removed. xovi and qt-resource-rebuilder are untouched."
    if dev "[ -d $ROOT/apps ]"; then
        say "your apps and their data are still at $ROOT/apps"
        say "to remove those too:"
        say "    ssh $DEV_USER@$HOST 'rm -rf $ROOT'"
    fi
    exit 0
}

[ "$MODE" = install ] || uninstall

# Offer, once, to make the next run unattended. **Never required**: Annex
# installs perfectly well over a password, and a script that pipes a public key
# into somebody's device without asking is exactly the kind of thing that makes
# `curl | sh` deserve its reputation. Default is no, and the question is asked
# on /dev/tty like every other prompt here. Asked after the uninstall path has
# gone, because offering to add a key while removing Annex is nonsense.
[ "$AUTH" = key ] || offer_key

# ---------------------------------------------------------------------------
# 2. OS version
#
# Annex patches xochitl's QML by matching element names (never hashes — see
# DESIGN.md §2), so a build that moved those is a build where Annex does not
# appear and xochitl is otherwise fine. That is a warning, not a refusal:
# people run other builds, the failure is soft by construction, and a hard stop
# here would only teach them to edit the script.

step "checking the OS version"

BUILD=$(dev "cat /etc/version 2>/dev/null" || true)
# The human-readable version lives in /etc/os-release as IMG_VERSION, and
# nowhere else that is reliable. /usr/share/remarkable/update.conf was the
# obvious candidate and is wrong: on 3.28.0.172 it yields nothing at all, so a
# check written against it reports every device as "unknown" and the warning
# below never fires. Measured on hardware 2026-09-19, which is the only reason
# this is not still reading the wrong file.
RELEASE=$(dev "sed -n 's/^IMG_VERSION=//p' /etc/os-release 2>/dev/null | tr -d '\"'" || true)
[ -n "$RELEASE" ] || RELEASE="unknown"
[ -n "$BUILD" ] || BUILD="unknown"

say "OS $RELEASE (build $BUILD)"

if [ "$RELEASE" = "$TESTED_OS" ]; then
    say "this is the version Annex is developed and tested against"
else
    warn "Annex is developed and tested against $TESTED_OS only."
    warn "On $RELEASE the QML anchors it patches may have moved. If they have,"
    warn "qmldiff logs an error and returns the original file: no Annex, and a"
    warn "working tablet. It should not brick anything, but nobody has tried it."
    ask "Continue anyway?" n || die "stopped. Nothing has been changed on the device."
fi

# ---------------------------------------------------------------------------
# 3. xovi, from the upstream bundle
#
# xovi is the loader xochitl is started with; `qt-resource-rebuilder` is the
# xovi extension that reads annex.qmd and patches xochitl's QML. Without both,
# Annex is a directory of files nothing reads.
#
# **Both come from one upstream tarball, and neither is built or redistributed
# here.** xovi-aarch64.tar.gz ships the complete tree in the layout a working
# device has:
#
#     xovi/xovi.so
#     xovi/extensions.d/qt-resource-rebuilder.so
#     xovi/services/xochitl.service/{extensions.d,exthome,qt-resource-rebuilder.conf}
#     xovi/exthome/qt-resource-rebuilder/
#     xovi/start  xovi/stock  xovi/rebuild_hashtable  xovi/scripts/...
#     xovi/inactive-extensions/*.so
#
# so there is nothing for this script to assemble and nothing to guess.
#
# **Do not vendor any of this into the repository.** The extension is GPL-3.0
# (origin package `xovi-extensions`, upstream asivery/rm-xovi-extensions).
# Fetching the official build at install time means Annex redistributes none of
# it, which is the reason it is downloaded rather than committed — not an
# oversight to "optimise" away later.
#
# It also fixes a real defect in the packaged alternative: the vellum-packaged
# xovi some devices carry is laid out differently and has **no `xovi/start`**,
# which is the file `xovi-autostart.sh` looks for. On those devices
# xovi-boot.service runs, finds nothing, exits 0, and reports
# `active (exited) status=0/SUCCESS` while doing nothing at all. This tarball
# gives a complete tree. Measured on hardware, not inferred.

step "xovi"

XOVI_PRESENT=no
if dev "[ -f $XOVI/xovi.so ]"; then XOVI_PRESENT=yes; fi

EXT_PRESENT=no
if dev "[ -f $EXT ]"; then EXT_PRESENT=yes; fi

if [ "$XOVI_PRESENT" = yes ] && [ "$EXT_PRESENT" = yes ]; then
    say "xovi and qt-resource-rebuilder are already installed — leaving both alone"
else
    say "downloading xovi ($XOVI_RELEASE, aarch64)"
    # Downloaded and checked here, then shipped. Verifying on this side means a
    # truncated download, or an HTML error page served with a 200, never
    # reaches the device — where the result would be a preload failure in a log
    # nobody is reading.
    curl -fsSL "$XOVI_URL" -o "$WORK/xovi.tar.gz" \
        || die "could not download $XOVI_URL"

    size=$(wc -c < "$WORK/xovi.tar.gz" | tr -d ' ')
    [ "$size" -gt 0 ] || die "the downloaded xovi bundle is empty"
    magic=$(od -An -tx1 -N 2 "$WORK/xovi.tar.gz" | tr -d ' \n')
    [ "$magic" = "1f8b" ] || die "the downloaded xovi bundle is not gzip (magic $magic) — check $XOVI_URL"

    tar tzf "$WORK/xovi.tar.gz" > "$WORK/xovi.list" 2>/dev/null \
        || die "the downloaded xovi bundle is not a readable tar archive"
    grep -q '^xovi/xovi\.so$' "$WORK/xovi.list" \
        || die "the xovi bundle has no xovi/xovi.so — wrong asset for $XOVI_RELEASE?"
    grep -q '^xovi/extensions\.d/qt-resource-rebuilder\.so$' "$WORK/xovi.list" \
        || die "the xovi bundle has no qt-resource-rebuilder — wrong asset for $XOVI_RELEASE?"
    say "downloaded $size bytes; xovi.so and qt-resource-rebuilder.so are both in it"

    dev "mkdir -p /home/root"
    if [ "$XOVI_PRESENT" = no ]; then
        # Nothing to preserve: extract the whole tree.
        dev_stdin "tar xzf - -C /home/root" < "$WORK/xovi.tar.gz" \
            || die "could not extract the xovi bundle on the device"
        say "installed $XOVI from the upstream bundle"
    else
        # **An existing xovi is not overwritten.** Somebody else's extensions,
        # their exthome data and any local edits to the scripts are theirs; the
        # only thing Annex needs that is missing here is the extension, so that
        # is the only member extracted.
        say "xovi is already installed; extracting only qt-resource-rebuilder"
        dev_stdin "tar xzf - -C /home/root xovi/extensions.d/qt-resource-rebuilder.so" < "$WORK/xovi.tar.gz" \
            || die "could not extract qt-resource-rebuilder on the device"
    fi
fi

# The extension is what applies Annex. If it is not there after all of the
# above, stop here rather than installing a framework nothing will load.
dev "[ -f $EXT ]" || die "$EXT is missing after installing xovi — the bundle did not extract as expected"
say "qt-resource-rebuilder present at $EXT"

# The XOVI_ROOT tree. The bundle ships it, so this is a check rather than
# construction — but a device with a pre-existing, differently-packaged xovi
# may not have it, and the drop-in below points XOVI_ROOT here. The two
# symlinks are what make one shared extensions.d serve the xochitl service.
dev "mkdir -p $XOVI/extensions.d $XOVI/exthome $XOVI/services/xochitl.service"

ensure_link() {
    _target="$1"; _link="$2"
    if dev "[ -L $_link ]"; then
        _cur=$(dev "readlink $_link" || true)
        if [ "$_cur" = "$_target" ]; then
            say "symlink ok: $_link"
        else
            warn "$_link points at $_cur, not $_target — leaving it alone"
        fi
    elif dev "[ -e $_link ]"; then
        warn "$_link exists and is not a symlink — leaving it alone"
    else
        dev "ln -s $_target $_link" && say "created symlink $_link -> $_target"
    fi
}
ensure_link "$XOVI/extensions.d" "$XOVI/services/xochitl.service/extensions.d"
ensure_link "$XOVI/exthome"      "$XOVI/services/xochitl.service/exthome"

# ---------------------------------------------------------------------------
# 4. The xovi drop-in, written underneath the /etc overlay
#
# /etc on this device is an overlay with a tmpfs upper layer, so a file copied
# into /etc is gone at the next boot — and this is the file that makes xochitl
# load xovi at all, so losing it means the tablet comes back stock with no
# error anywhere. DESIGN.md §15 has the measurement.
#
# tools/annex-extension already implements writing under the overlay through a
# bind mount of /, with all the warnings about the ~90%-full rootfs attached to
# it. It is copied to the device first, before the rest of Annex, precisely so
# this step can call it rather than reimplement it here — a second copy of that
# technique in a shell heredoc is how the two drift apart.

step "xovi systemd drop-in"

# --- locate the source tree ------------------------------------------------
#
# Run from a checkout, use the checkout. Run from `curl | sh` there is no
# checkout and $0 is not a path, so fetch the tarball. Both are supported
# because the second is what users do and the first is what anyone changing
# this script does.
HERE=""
# `sh install.sh` from inside the checkout leaves $0 with no slash in it, which
# an earlier version of this took to mean "no checkout" and went to the network
# — downloading a tarball to replace the tree it was already standing in, and
# 404ing before the repository existed. A bare name means the current
# directory; `curl | sh` gives $0 as "sh", which lands here too and is correct,
# because then the annex.qmd test below is what decides.
case "$0" in
    */*) HERE_DIR=$(dirname "$0") ;;
    *)   HERE_DIR=. ;;
esac
HERE=$(cd "$HERE_DIR" 2>/dev/null && pwd) || HERE=""

if [ -n "$HERE" ] && [ -f "$HERE/annex.qmd" ]; then
    SRC="$HERE"
    say "using the checkout at $SRC"
else
    say "fetching the Annex tree"
    curl -fsSL "$TARBALL_URL" -o "$WORK/annex.tar.gz" \
        || die "could not download $TARBALL_URL"
    tar xzf "$WORK/annex.tar.gz" -C "$WORK" || die "could not unpack the tree"
    SRC="$WORK/annex-main"
    [ -f "$SRC/annex.qmd" ] || die "the downloaded tree has no annex.qmd — wrong tarball?"
    say "unpacked $TARBALL_URL"
fi

# COPYFILE_DISABLE and the excludes keep macOS AppleDouble files off the
# device: a `._annex.qmd` beside the real one is a file qmldiff tries to parse
# and fails on with "stream did not contain valid UTF-8". deploy.sh has the
# same two lines for the same reason.
export COPYFILE_DISABLE=1
push() {  # push <dest-dir> <path>...
    dest="$1"; shift
    tar --exclude='._*' --exclude='.DS_Store' -cf - -C "$SRC" "$@" \
        | dev_stdin "tar xf - -C $dest"
}

# The tools are pushed here, ahead of the rest of Annex, because the drop-in
# below has to go *under* the overlay and annex-extension is what knows how.
dev "mkdir -p $ROOT/apps $ROOT/lib $ROOT/tools $ROOT/run $ROOT/systemd $ROOT/vendor"
push "$ROOT" tools
dev "chmod +x $ROOT/tools/*"

# The drop-in itself. Two lines, and both matter: LD_PRELOAD is what gets xovi
# into xochitl, XOVI_ROOT is what points it at the per-service tree created
# above.
cat > "$WORK/00-xovi.conf" <<EOF
[Service]
Environment="LD_PRELOAD=$XOVI/xovi.so"
Environment="XOVI_ROOT=$XOVI/services/xochitl.service/"
EOF

if dev_stdin "cmp -s - $XOVI_DROPIN" < "$WORK/00-xovi.conf"; then
    say "$XOVI_DROPIN already current"
else
    dev_stdin "mkdir -p $(dirname "$XOVI_DROPIN") && cat > $XOVI_DROPIN" < "$WORK/00-xovi.conf" \
        || die "could not write $XOVI_DROPIN"
    say "installed $XOVI_DROPIN"
fi

# Always, even when the live copy was already current: /etc being right says
# nothing about what is underneath the overlay, and the overlay is what the
# reboot throws away.
dev "cp $XOVI_DROPIN $ROOT/systemd/00-xovi.conf" || true
dev "$ROOT/tools/annex-extension persist $ROOT/systemd/00-xovi.conf $XOVI_DROPIN" \
    || warn "could not persist the xovi drop-in; it may not survive a reboot"
dev "systemctl daemon-reload || true"

# ---------------------------------------------------------------------------
# 5. Annex itself
#
# The same work deploy.sh does, over the shared connection. The device-side
# half of it — permissions, the index, backend services, the extension safety
# copy and the units — is one script, `tools/annex-apply`, which both this and
# deploy.sh call, so there is a single definition of what "installed" means.

step "Annex"

push "$ROOT" lib tools systemd README.md
dev "mkdir -p $QMD_DIR"
push "$QMD_DIR" annex.qmd

# A stale AppleDouble from an older deploy made before those excludes existed.
dev "rm -f $QMD_DIR/._*.qmd $ROOT/._* $ROOT/*/._* $ROOT/apps/*/._* 2>/dev/null; true"

dev "$ROOT/tools/annex-apply" || die "annex-apply failed on the device"

# ---------------------------------------------------------------------------
# 6. Restart and verify
#
# Three checks, because each of the three ways this fails is silent:
#   * LD_PRELOAD in the running process   — the drop-in took effect
#   * "Loading file annex.qmd"            — the extension found the patch
#   * "app(s) installed"                  — the host ran and read the index

step "restarting xochitl"

dev "systemctl restart xochitl" || die "could not restart xochitl"

# No `timeout` on the device and none assumed here either. The wait is on this
# side, one ssh round trip per second, which is also a liveness check on the
# connection.
say "waiting for xochitl to come up"
n=0
while [ "$n" -lt 30 ]; do
    if dev "pidof xochitl >/dev/null 2>&1"; then break; fi
    n=$((n + 1))
    sleep 1
done
sleep 4   # the QML is loaded and the host discovers apps after the process exists

ok=1

preload=$(dev "pid=\$(pidof xochitl | cut -d' ' -f1); [ -n \"\$pid\" ] && tr '\\0' '\\n' < /proc/\$pid/environ | grep '^LD_PRELOAD=' || true")
if [ -n "$preload" ]; then
    say "check: xochitl is running with $preload"
else
    warn "check: xochitl is NOT running with LD_PRELOAD — xovi did not load"
    ok=0
fi

log=$(dev "journalctl -u xochitl --no-pager -n 400 2>/dev/null || true")

case "$log" in
*"Loading file annex.qmd"*)
    say "check: qmldiff loaded annex.qmd" ;;
*)
    warn "check: no '[qmldiff]: Loading file annex.qmd' in xochitl's journal"
    warn "       the extension did not read the patch"
    ok=0 ;;
esac

case "$log" in
*"app(s) installed"*)
    say "check: $(printf '%s\n' "$log" | grep 'app(s) installed' | tail -n 1 | sed 's/.*\[annex\] //')" ;;
*)
    warn "check: the Annex host did not report its app count"
    warn "       it did not run, or it could not read $ROOT/apps.index"
    ok=0 ;;
esac

echo
if [ "$ok" -eq 1 ]; then
    say "installed. Open the sidebar on the tablet; apps appear under the"
    say "stock entries."
    echo
    # Only claim the device has no apps when it actually has none. This said
    # "There are no apps yet" unconditionally, which it cheerfully printed on a
    # device that had just reported "1 app(s) installed" two lines earlier.
    installed_apps=$(dev "ls $ROOT/apps 2>/dev/null | wc -l" | tr -d ' ')
    [ -z "$installed_apps" ] && installed_apps=0
    if [ "$installed_apps" -gt 0 ]; then
        say "$installed_apps app(s) installed in $ROOT/apps."
        say "docs/APPS.md covers writing your own."
    else
        say "There are no apps yet — Annex is the framework, not an app. An app"
        say "is a directory with a manifest and a QML file, copied into"
        say "$ROOT/apps/. The smallest one that works is examples/hello in the"
        say "repository, and docs/APPS.md walks through it."
    fi
    echo
    say "After adding an app:"
    say "    ssh $DEV_USER@$HOST '$ROOT/tools/annex-index && systemctl restart xochitl'"
    say "To check Annex is healthy at any time:"
    say "    ssh $DEV_USER@$HOST '$ROOT/tools/annex-extension check'"
    say "To remove Annex again:  sh install.sh --uninstall"
else
    say "installed, but at least one check above failed."
    say "Ask the device what is wrong, in one command:"
    say "    ssh $DEV_USER@$HOST '$ROOT/tools/annex-extension check'"
    say "It reports the extension, the safety copy, annex.qmd, the boot-ordering"
    say "drop-in and the self-heal unit, and exits non-zero when Annex is broken."
    echo
    say "The tablet is usable either way: a failed patch means no Annex, not a"
    say "dead UI. 'sh install.sh --uninstall' removes what this put there."
    exit 1
fi
