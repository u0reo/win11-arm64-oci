#!/usr/bin/env bash
# Finish the WinPE pass from the host, after QEMU has stopped.
#
# WinPE cannot use the PL011 serial port, so its COM1 markers never reach the
# host.  manual_finish.cmd writes the same markers to \manual-finish.log on
# the Windows volume instead.  This script checks that log, then repairs the
# two things that WinPE cannot do reliably:
#
#   1. add the recovery Ubuntu entry to the Windows Boot Manager BCD
#   2. put the Windows boot manager at \EFI\Boot\BOOTAA64.EFI, the path the
#      firmware uses on an empty boot order.  bcdboot leaves an existing
#      Ubuntu shim there, which would make the disk boot straight to GRUB.
#
# The target can be a qcow2 file or a raw block device.
# Usage: ./finish_winpe.sh <disk.qcow2|/dev/sdX> [--timeout N] [--skip-log-check]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"

IMG=""
TIMEOUT=${BOOT_MENU_TIMEOUT:-1}
CHECK_LOG=1
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
        --skip-log-check) CHECK_LOG=0; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$IMG" ] || { echo "too many arguments" >&2; exit 2; }
           IMG=$1; shift ;;
    esac
done
[ -n "$IMG" ] || { echo "usage: $0 <disk.qcow2|/dev/sdX> [--timeout N]" >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout must be a number" >&2; exit 2 ;; esac

RAW=0
if [ -b "$IMG" ]; then
    RAW=1
elif [ ! -f "$IMG" ]; then
    echo "missing $IMG" >&2
    exit 1
fi
if pgrep -f "qemu-system-aarch64.*$IMG" >/dev/null 2>&1; then
    echo "QEMU still references $IMG" >&2
    exit 1
fi

ESP=$(mktemp -d /tmp/finish-winpe-esp.XXXXXX)
WIN=$(mktemp -d /tmp/finish-winpe-ntfs.XXXXXX)
NBD=0
cleanup() {
    set +e
    sudo -n umount "$WIN" 2>/dev/null
    sudo -n umount "$ESP" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    cleanup_part_loops
    rmdir "$WIN" "$ESP" 2>/dev/null
}
trap cleanup EXIT

if [ "$RAW" = 1 ]; then
    echo "[1/5] raw device check"
    DEV=$IMG
    sudo -n blockdev --getsize64 "$DEV" >/dev/null
else
    echo "[1/5] qcow2 check"
    qemu-img check "$IMG"
    echo "[2/5] connect qcow2"
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    sudo -n qemu-nbd --connect=/dev/nbd0 --format=qcow2 "$IMG"
    NBD=1
    DEV=/dev/nbd0
fi

sudo -n partprobe "$DEV" 2>/dev/null || true
sleep 1
ESPDEV=$(find_esp "$DEV")
WINDEV=$(find_windows "$DEV")
[ -n "$ESPDEV" ] || { echo "no EFI System partition on $DEV" >&2; exit 1; }
[ -n "$WINDEV" ] || { echo "no Windows partition on $DEV" >&2; exit 1; }
echo "  ESP:     $ESPDEV"
echo "  Windows: $WINDEV"

echo "[3/5] check the WinPE finish log"
sudo -n mkdir -p "$WIN"
sudo -n mount -t ntfs-3g -o ro "$WINDEV" "$WIN"
LOG="$WIN/manual-finish.log"
if [ -f "$LOG" ]; then
    sed 's/\r$//' "$LOG" | tail -30 | sed 's/^/  /'
else
    echo "  $LOG is missing"
fi
if [ "$CHECK_LOG" = 1 ]; then
    [ -f "$LOG" ] || {
        echo "WinPE did not write its finish log; refusing to continue" >&2
        echo "  rerun step 9, or use --skip-log-check after checking the disk" >&2
        exit 1
    }
    if ! grep -q 'MANUAL_FINISH_OK' "$LOG"; then
        echo "WinPE finish did not complete:" >&2
        sed 's/\r$//' "$LOG" | tail -30 | sed 's/^/  /' >&2
        exit 1
    fi
    echo "  manual-finish.log reports success"
fi
sudo -n umount "$WIN"

echo "[4/5] repair the ESP"
sudo -n mkdir -p "$ESP"
sudo -n mount -t vfat "$ESPDEV" "$ESP"
BCD="$ESP/EFI/Microsoft/Boot/BCD"
BOOTMGR="$ESP/EFI/Microsoft/Boot/bootmgfw.efi"
[ -f "$BCD" ] || { echo "missing $BCD" >&2; exit 1; }
[ -f "$BOOTMGR" ] || { echo "missing $BOOTMGR" >&2; exit 1; }
if [ -f "$ESP/EFI/ubuntu/grubaa64.efi" ]; then
    python3 "$HERE/bcd_add_ubuntu.py" "$BCD" --timeout "$TIMEOUT"
    # hivex writes a clean base hive.  The logs from an older bcdedit session
    # must not be replayed over it on the next boot.
    rm -f "$ESP/EFI/Microsoft/Boot/BCD.LOG" \
          "$ESP/EFI/Microsoft/Boot/BCD.LOG1" \
          "$ESP/EFI/Microsoft/Boot/BCD.LOG2"
else
    echo "  \EFI\ubuntu\grubaa64.efi is absent; leaving the BCD alone"
fi

# Do not rely on bcdboot here: when the ESP already has an Ubuntu shim at
# this path, bcdboot leaves it in place.  Copy the Windows boot manager over
# it so an empty UEFI boot order starts Windows and its menu.
sudo -n mkdir -p "$ESP/EFI/Boot"
sudo -n cp -f "$BOOTMGR" "$ESP/EFI/Boot/BOOTAA64.EFI"
sync
a=$(sha256sum "$BOOTMGR" | awk '{print $1}')
b=$(sha256sum "$ESP/EFI/Boot/BOOTAA64.EFI" | awk '{print $1}')
[ "$a" = "$b" ] || { echo "fallback boot manager copy failed" >&2; exit 1; }
echo "  EFI/Boot/BOOTAA64.EFI = EFI/Microsoft/Boot/bootmgfw.efi"
echo "  sha256 $a"
sudo -n umount "$ESP"

echo "[5/5] done"
echo "OK: finished $IMG"
