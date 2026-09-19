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

"${SSH[@]}" "chmod +x $ROOT/tools/* && find $ROOT/apps -name run -path '*/backend/*' -exec chmod +x {} +"
"${SSH[@]}" "$ROOT/tools/annex-index"

# Backends are systemd services, so they start here and not when xochitl does.
# This is also what reinstalls the unit template after an OS update, which
# wipes /etc.
"${SSH[@]}" "$ROOT/tools/annex-service sync"

# Take a safety copy of the extension that applies annex.qmd, and install the
# unit that puts it back.
#
# Annex depends on qt-resource-rebuilder and nothing on the device records
# that, because Annex is not a vellum package — so a package manager removing
# whatever *does* own it takes Annex with it, silently. That happened on
# 2026-09-19. tools/annex-extension has the log and the reasoning.
#
# The copy is made on the device and stays there: it is a 9 MB third-party GPL
# binary and it is not going in this repository. /home has tens of gigabytes
# free; the rootfs, where the unit and drop-in go, has tens of megabytes, which
# is why only those two tiny files are persisted under the /etc overlay.
"${SSH[@]}" "$ROOT/tools/annex-extension vendor"
"${SSH[@]}" "$ROOT/tools/annex-extension install"

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
