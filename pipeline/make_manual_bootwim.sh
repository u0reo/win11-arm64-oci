#!/usr/bin/env bash
# Patch a Windows ARM64 boot.wim so the Setup image (index 2) runs
# manual_start.cmd instead of setup.exe.  Used by the manual DISM install
# path, which avoids the Setup DataImage hang seen with modified images.
#
# Usage: ./make_manual_bootwim.sh /path/to/boot.wim|/path/to/iso [out.wim]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BUILD=${BUILD_DIR:-$ROOT/build}
SRC=${1:?usage: $0 <boot.wim|iso> [out.wim]}
OUT=${2:-$BUILD/boot-manual.wim}
START_CMD=${START_CMD:-$HERE/manual_start.finish.cmd}
[ -f "$START_CMD" ] || { echo "missing START_CMD: $START_CMD" >&2; exit 1; }
START_NAME=$(basename "$START_CMD")

WORK=$(mktemp -d /tmp/manual-bootwim.XXXXXX)
MNT=""
MOUNTED=0
cleanup() {
    set +e
    [ "$MOUNTED" = 1 ] && sudo -n umount "$MNT" 2>/dev/null
    [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

case "$SRC" in
    *.iso|*.ISO)
        MNT=$(mktemp -d /tmp/manual-bootwim-iso.XXXXXX)
        sudo -n mkdir -p "$MNT"
        if ! sudo -n mount -t udf -o ro,loop "$SRC" "$MNT" 2>/dev/null; then
            sudo -n mount -t iso9660 -o ro,loop "$SRC" "$MNT"
        fi
        MOUNTED=1
        SRC="$MNT/sources/boot.wim"
        ;;
esac
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

echo "[1/4] extract image 2 SYSTEM hive"
wimlib-imagex extract "$SRC" 2 'Windows/System32/config/SYSTEM' --dest-dir="$WORK" >/dev/null
HIVE="$WORK/SYSTEM"
[ -f "$HIVE" ] || { echo "SYSTEM hive not extracted" >&2; exit 1; }

echo "[2/4] set HKLM\\SYSTEM\\Setup\\CmdLine"
# hivexregedit lives in libhivex-bin, which the live session does not carry.
# python3-hivex can write the value directly.
python3 - "$HIVE" "cmd.exe /c $START_NAME" <<'PY'
import sys

import hivex

path, value = sys.argv[1], sys.argv[2]
h = hivex.Hivex(path, write=True)
root = h.root()
try:
    setup = h.node_get_child(root, "Setup")
except RuntimeError:
    setup = None
if setup is None:
    setup = h.node_add_child(root, "Setup")
h.node_set_value(setup, {
    "key": "CmdLine",
    "t": 1,  # REG_SZ
    "value": value.encode("utf-16le") + b"\x00\x00",
})
h.commit(None)
PY
cmdline() {
    python3 - "$1" <<'PY'
import hivex, sys
h = hivex.Hivex(sys.argv[1])
setup = h.node_get_child(h.root(), 'Setup')
v = h.node_get_value(setup, 'CmdLine')
print(h.value_value(v)[1].decode('utf-16-le').rstrip('\0'))
PY
}
[ "$(cmdline "$HIVE")" = "cmd.exe /c $START_NAME" ] || {
    echo "CmdLine update failed" >&2; exit 1
}

echo "[3/4] build updated boot.wim"
cp -f "$SRC" "$OUT"
chmod u+w "$OUT"
cat > "$WORK/update.txt" <<EOF
add "$HIVE" /Windows/System32/config/SYSTEM
add "$START_CMD" "/Windows/System32/$START_NAME"
EOF
wimlib-imagex update "$OUT" 2 < "$WORK/update.txt" >/tmp/manual-bootwim-update.log 2>&1 || {
    echo "wimlib update failed; see /tmp/manual-bootwim-update.log" >&2
    tail -20 /tmp/manual-bootwim-update.log >&2
    exit 1
}

echo "[4/4] verify"
wimlib-imagex dir "$OUT" 2 > "$WORK/dir.txt"
grep -q "/Windows/System32/$START_NAME" "$WORK/dir.txt" || {
    echo "manual_start.cmd missing from output" >&2; exit 1
}
mkdir -p "$WORK/verify"
wimlib-imagex extract "$OUT" 2 'Windows/System32/config/SYSTEM' --dest-dir="$WORK/verify" >/dev/null
[ "$(cmdline "$WORK/verify/SYSTEM")" = "cmd.exe /c $START_NAME" ] || {
    echo "CmdLine missing from output" >&2; exit 1
}
ls -lh "$OUT"
echo "OK: $OUT"
