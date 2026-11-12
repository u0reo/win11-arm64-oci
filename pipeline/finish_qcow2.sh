#!/usr/bin/env bash
# Patch the installed ESP's bootmgfw.efi for OCI A1, then verify the qcow2.
# QEMU must be stopped first.
#
# Usage: ./finish_qcow2.sh /path/to/win11-26h2.qcow2
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${1:?usage: $0 <disk.qcow2>}
[ -f "$IMG" ] || { echo "missing $IMG" >&2; exit 1; }

NAME=$(basename "$IMG" .qcow2)
if [ -f "$HERE/$NAME.pid" ]; then
    PID=$(cat "$HERE/$NAME.pid")
    if kill -0 "$PID" 2>/dev/null; then
        echo "QEMU is still running (pid $PID); stop it first" >&2
        exit 1
    fi
fi
if pgrep -f "qemu-system-aarch64.*$IMG" >/dev/null 2>&1; then
    echo "QEMU still references $IMG" >&2
    exit 1
fi

echo "[1/4] qcow2 check"
qemu-img check "$IMG"

ESP=$(mktemp -d /tmp/finish-esp.XXXXXX)
NBD=0
cleanup() {
    set +e
    sudo -n umount "$ESP" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    rmdir "$ESP" 2>/dev/null
}
trap cleanup EXIT

echo "[2/4] connect qcow2 read-write"
sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
sudo -n qemu-nbd --connect=/dev/nbd0 --format=qcow2 "$IMG"
NBD=1
sudo -n partprobe /dev/nbd0 2>/dev/null || true
sleep 1
sudo -n mount -t vfat /dev/nbd0p1 "$ESP"

echo "[3/4] patch ESP boot managers"
for rel in EFI/Microsoft/Boot/bootmgfw.efi EFI/Boot/bootaa64.efi; do
    f="$ESP/$rel"
    [ -f "$f" ] || { echo "  $rel: absent"; continue; }
    tmp=$(mktemp /tmp/bootmgfw.XXXXXX)
    cp "$f" "$tmp"
    if python3 "$HERE/patch_bootmgfw.py" "$tmp" "$tmp.patched" >/tmp/patch.out 2>&1; then
        sudo -n cp "$tmp.patched" "$f"
        echo "  $rel: patched"
        sed -n '1,8p' /tmp/patch.out | sed 's/^/    /'
    else
        echo "  $rel: no patch site (left unchanged)"
        sed -n '1,4p' /tmp/patch.out | sed 's/^/    /'
    fi
    rm -f "$tmp" "$tmp.patched"
done
sync
sudo -n umount "$ESP"
sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
NBD=0

echo "[4/4] final image info"
qemu-img info "$IMG" | sed -n '1,15p'
echo "OK: patched $IMG"
