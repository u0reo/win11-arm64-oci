#!/usr/bin/env bash
# Patch the installed ESP's bootmgfw.efi for OCI A1, then verify the disk.
# QEMU must be stopped first.
#
# The target can be a qcow2 file or a raw block device.
# Usage: ./finish_disk.sh /path/to/disk.qcow2 | /dev/sdX
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"
IMG=${1:?usage: $0 <disk.qcow2|/dev/sdX>}

RAW=0
if [ -b "$IMG" ]; then
    RAW=1
elif [ ! -f "$IMG" ]; then
    echo "missing $IMG" >&2
    exit 1
fi

if qemu_uses_disk "$IMG"; then
    echo "QEMU still references $IMG" >&2
    exit 1
fi

ESP=$(mktemp -d /tmp/finish-esp.XXXXXX)
PATCH_LOG=$(mktemp /tmp/patch-bootmgfw.XXXXXX)
NBD=0
cleanup() {
    set +e
    sudo -n umount "$ESP" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    cleanup_part_loops
    rm -f "$PATCH_LOG"
    rmdir "$ESP" 2>/dev/null
}
trap cleanup EXIT

if [ "$RAW" = 1 ]; then
    echo "[1/4] raw device check"
    DEV=$IMG
    sudo -n blockdev --getsize64 "$DEV"
else
    echo "[1/4] qcow2 check"
    qemu-img check "$IMG"
    echo "[2/4] connect qcow2 read-write"
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    sudo -n qemu-nbd --connect=/dev/nbd0 --format=qcow2 "$IMG"
    NBD=1
    DEV=/dev/nbd0
fi

sudo -n partprobe "$DEV" 2>/dev/null || true
sleep 1
ESPDEV=$(find_esp "$DEV")
[ -n "$ESPDEV" ] || {
    echo "no EFI System partition found on $DEV" >&2
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV" >&2
    exit 1
}
echo "  ESP: $ESPDEV"
sudo -n mount -t vfat "$ESPDEV" "$ESP"

echo "[3/4] patch ESP boot managers"
for rel in EFI/Microsoft/Boot/bootmgfw.efi EFI/Boot/bootaa64.efi; do
    f="$ESP/$rel"
    [ -f "$f" ] || { echo "  $rel: missing" >&2; exit 1; }
    tmp=$(mktemp /tmp/bootmgfw.XXXXXX)
    cp "$f" "$tmp"
    if ! python3 "$HERE/patch_bootmgfw.py" "$tmp" "$tmp.patched" >"$PATCH_LOG" 2>&1; then
        echo "  $rel: patch failed" >&2
        sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
        rm -f "$tmp" "$tmp.patched"
        exit 1
    fi
    sudo -n cp "$tmp.patched" "$f"
    if ! python3 "$HERE/patch_bootmgfw.py" --dry-run --require-patched "$f" >"$PATCH_LOG" 2>&1; then
        echo "  $rel: verification failed after writing" >&2
        sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
        rm -f "$tmp" "$tmp.patched"
        exit 1
    fi
    echo "  $rel: patched and verified"
    sed -n '1,8p' "$PATCH_LOG" | sed 's/^/    /'
    rm -f "$tmp" "$tmp.patched"
done
sync
sudo -n umount "$ESP"
if [ "$NBD" = 1 ]; then
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    NBD=0
fi

echo "[4/4] final check"
if [ "$RAW" = 1 ]; then
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV"
else
    qemu-img info "$IMG" | sed -n '1,15p'
fi
echo "OK: patched $IMG"
