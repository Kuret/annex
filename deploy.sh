#!/usr/bin/env bash
# Install Annex and its apps onto the tablet.
#
#   ./deploy.sh [host]        host defaults to $ANNEX_DEVICE, then 10.11.99.1
#
# Deliberately does not restart xochitl: the caller decides when the screen is
# allowed to go away. It prints the command.
#
# Device-side requirements are busybox and an ssh server. Nothing is built —
# apps are plain files, which is the point.
#
# **This is the developer path.** It assumes the device already has xovi,
# qt-resource-rebuilder and an Annex install, and it only pushes the tree.
# `install.sh` is the user path: it runs from a `curl | sh` one-liner with no
# checkout, installs xovi and the drop-in from nothing, and holds one ssh
# connection open so a device with no key asks for its password once. The two
# share the device-side half (`tools/annex-apply`) and nothing else.
set -euo pipefail

HOST="${1:-${ANNEX_DEVICE:-10.11.99.1}}"
USER="${ANNEX_DEVICE_USER:-root}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=/home/root/annex
QMD_DIR=/home/root/xovi/exthome/qt-resource-rebuilder

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$USER@$HOST")

"${SSH[@]}" true || { echo "deploy: cannot ssh to $USER@$HOST" >&2; exit 1; }
"${SSH[@]}" "[ -d $QMD_DIR ]" || {
    echo "deploy: $QMD_DIR missing — is xovi installed with qt-resource-rebuilder?" >&2
    exit 1
}

echo "deploy: $USER@$HOST"

# lib, tools and apps go under $ROOT; the injection goes where the resource
# rebuilder looks. tar over ssh keeps it to one round trip and preserves modes.
#
# COPYFILE_DISABLE and the excludes keep macOS AppleDouble files out of the
# tarball. Without them the tablet gets a `._annex.qmd` beside the real one,
# qmldiff tries to parse it and fails with "stream did not contain valid
# UTF-8". It skips the file and carries on, so this cost nothing but a
# confusing line in the log — but a `._` copy of every app manifest is also a
# `._` entry qmldiff and the indexer both have to ignore, and that will not
# stay harmless.
export COPYFILE_DISABLE=1
TAR_EXCLUDE=(--exclude='._*' --exclude='.DS_Store')

# **`examples/` is not deployed, and that is the whole reason it is a separate
# directory.** The hello app is documentation: it is how a developer sees the
# smallest thing that works, and it belongs in the repository. It does not
# belong in somebody's sidebar, where it is a stray entry they have to wonder
# about. Copy it into `apps/` on the device to try it; nothing here does that
# for you.
"${SSH[@]}" "mkdir -p $ROOT/apps $ROOT/lib $ROOT/tools $ROOT/run $ROOT/systemd $ROOT/vendor"
tar "${TAR_EXCLUDE[@]}" -cf - -C "$HERE" lib tools systemd README.md | "${SSH[@]}" "tar xf - -C $ROOT"
tar "${TAR_EXCLUDE[@]}" -cf - -C "$HERE" annex.qmd | "${SSH[@]}" "tar xf - -C $QMD_DIR"

# A stale AppleDouble from an earlier deploy is still sitting there.
"${SSH[@]}" "rm -f $QMD_DIR/._*.qmd $ROOT/._* $ROOT/*/._* $ROOT/apps/*/._* 2>/dev/null; true"

# Permissions, the app index, backend services, the extension safety copy and
# the units — all of it is `annex-apply` on the device, so that "installed"
# means one thing and is defined in one place. install.sh calls the same
# script; see the note at the top of this file.
"${SSH[@]}" "chmod +x $ROOT/tools/*"
"${SSH[@]}" "$ROOT/tools/annex-apply"

echo
echo "deploy: installed. To load the UI:"
echo "    ssh $USER@$HOST 'systemctl restart xochitl'"
echo
echo "deploy: if the sidebar entry does not appear, ask why in one command:"
echo "    ssh $USER@$HOST '$ROOT/tools/annex-extension check'"
echo
echo "deploy: backend status:"
echo "    ssh $USER@$HOST '$ROOT/tools/annex-service status'"
echo
echo "deploy: to remove it again:"
echo "    ssh $USER@$HOST '$ROOT/tools/annex-disable'"
