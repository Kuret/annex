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

"${SSH[@]}" "mkdir -p $ROOT/apps $ROOT/lib $ROOT/tools $ROOT/run $ROOT/systemd"
tar "${TAR_EXCLUDE[@]}" -cf - -C "$HERE" lib tools apps systemd README.md | "${SSH[@]}" "tar xf - -C $ROOT"
tar "${TAR_EXCLUDE[@]}" -cf - -C "$HERE" annex.qmd | "${SSH[@]}" "tar xf - -C $QMD_DIR"

# A stale AppleDouble from an earlier deploy is still sitting there.
"${SSH[@]}" "rm -f $QMD_DIR/._*.qmd $ROOT/._* $ROOT/*/._* $ROOT/apps/*/._* 2>/dev/null; true"

"${SSH[@]}" "chmod +x $ROOT/tools/* && find $ROOT/apps -name run -path '*/backend/*' -exec chmod +x {} +"
"${SSH[@]}" "$ROOT/tools/annex-index"

# Backends are systemd services, so they start here and not when xochitl does.
# This is also what reinstalls the unit template after an OS update, which
# wipes /etc.
"${SSH[@]}" "$ROOT/tools/annex-service sync"

echo
echo "deploy: installed. To load the UI:"
echo "    ssh $USER@$HOST 'systemctl restart xochitl'"
echo
echo "deploy: backend status:"
echo "    ssh $USER@$HOST '$ROOT/tools/annex-service status'"
echo
echo "deploy: to remove it again:"
echo "    ssh $USER@$HOST '$ROOT/tools/annex-disable'"
