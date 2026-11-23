#!/usr/bin/env bash
# Finish the WinPE pass from the host, after QEMU has stopped.
#
# WinPE cannot use the PL011 serial port, so its COM1 markers never reach the
# host.  manual_finish.cmd writes the same markers to \manual-finish.log on
# the Windows volume instead.  This script checks that log, then repairs the
# ESP:
#
#   1. make GRUB the first loader.  \EFI\Boot\BOOTAA64.EFI is the signed
#      Ubuntu shim, \EFI\Boot\grubaa64.efi is the signed GRUB, and
#      \EFI\ubuntu\grub.cfg is the menu:
#          Windows 11        (default)
#          Ubuntu (recovery)
#      The EFI console carries the menu to the OCI serial console, so the
#      arrow keys and Enter work there too.
#   2. remove the old Windows Boot Manager bootapp entry for Ubuntu.  ARM64
#      BootMgr cannot start a Linux EFI application, and GRUB now starts
#      Ubuntu instead.
#
# A Windows-only build (no \EFI\ubuntu\grubaa64.efi) keeps the Windows boot
# manager at \EFI\Boot\BOOTAA64.EFI so the firmware fallback starts Windows.
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
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$IMG" ] || { echo "too many arguments" >&2; exit 2; }
           IMG=$1; shift ;;
    esac
done
[ -n "$IMG" ] || { echo "usage: $0 <disk.qcow2|/dev/sdX> [--timeout N]" >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout must be a number" >&2; exit 2 ;; esac
TIMEOUT=$((10#$TIMEOUT))

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

ESP=$(mktemp -d /tmp/finish-winpe-esp.XXXXXX)
WIN=$(mktemp -d /tmp/finish-winpe-ntfs.XXXXXX)
UB=$(mktemp -d /tmp/finish-winpe-ubuntu.XXXXXX)
WORK=$(mktemp -d /tmp/finish-winpe-work.XXXXXX)
WIN_BOOTMGFW=""
NBD=0
cleanup() {
    set +e
    sudo -n umount "$UB" 2>/dev/null
    sudo -n umount "$WIN" 2>/dev/null
    sudo -n umount "$ESP" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    cleanup_part_loops
    rm -rf "$WORK"
    rmdir "$UB" "$WIN" "$ESP" 2>/dev/null
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
# bcdboot copies the boot manager from the source Windows installation, but
# an interrupted servicing update or an older repair can leave a different
# stock bootmgfw.efi on the ESP.  Keep the installed Windows copy so
# bootmgfw.efi, bootmgr.efi, boot.stl and CIPolicies stay in one generation.
if [ -f "$WIN/Windows/Boot/EFI/bootmgfw.efi" ]; then
    WIN_BOOTMGFW="$WORK/bootmgfw.windows"
    sudo -n cp -f "$WIN/Windows/Boot/EFI/bootmgfw.efi" "$WIN_BOOTMGFW"
    echo "  installed Windows boot manager: $(stat -c %s "$WIN_BOOTMGFW") bytes"
fi
sudo -n umount "$WIN"

echo "[4/5] repair the ESP"
sudo -n mkdir -p "$ESP"
sudo -n mount -t vfat "$ESPDEV" "$ESP"
BCD="$ESP/EFI/Microsoft/Boot/BCD"
BOOTMGR="$ESP/EFI/Microsoft/Boot/bootmgfw.efi"
BOOTDIR="$ESP/EFI/BOOT"
GRUB="$ESP/EFI/ubuntu/grubaa64.efi"
SHIM="$ESP/EFI/ubuntu/shimaa64.efi"
[ -f "$BCD" ] || { echo "missing $BCD" >&2; exit 1; }
[ -f "$BOOTMGR" ] || { echo "missing $BOOTMGR" >&2; exit 1; }
if [ -n "$WIN_BOOTMGFW" ]; then
    sudo -n cp -f "$WIN_BOOTMGFW" "$BOOTMGR"
    echo "  EFI/Microsoft/Boot/bootmgfw.efi = installed Windows copy"
fi

# The old Windows Boot Manager bootapp entry cannot work on ARM64.  Remove it
# whether or not a recovery Ubuntu is included, so the Windows menu never
# offers it.
if ! sudo -n python3 "$HERE/bcd_remove_ubuntu.py" "$BCD"; then
    echo "could not clean the BCD" >&2
    exit 1
fi
# hivex writes a clean base hive.  The logs from an older bcdedit session
# must not be replayed over it on the next boot.
sudo -n rm -f "$ESP/EFI/Microsoft/Boot/BCD.LOG" \
              "$ESP/EFI/Microsoft/Boot/BCD.LOG1" \
              "$ESP/EFI/Microsoft/Boot/BCD.LOG2"

if [ -f "$GRUB" ]; then
    if [ "$TIMEOUT" = 0 ]; then
        echo "error: --timeout 0 would hide the Ubuntu recovery entry" >&2
        exit 2
    fi
    UBDEV=$(find_ubuntu_root "$DEV")
    [ -n "$UBDEV" ] || {
        echo "no ext2/3/4 Ubuntu root on $DEV" >&2
        exit 1
    }
    echo "  Ubuntu root: $UBDEV"
    sudo -n mount -t ext4 -o ro "$UBDEV" "$UB"

    # The firmware's fallback path should start GRUB, not Windows.  shim is
    # the signed first stage; it loads grubaa64.efi from its own directory.
    sudo -n mkdir -p "$BOOTDIR"
    if [ -f "$SHIM" ]; then
        sudo -n cp -f "$SHIM" "$BOOTDIR/BOOTAA64.EFI"
        sudo -n cp -f "$GRUB" "$BOOTDIR/grubaa64.efi"
        BOOT_SRC=$SHIM
        echo "  EFI/Boot/BOOTAA64.EFI = EFI/ubuntu/shimaa64.efi"
        echo "  EFI/Boot/grubaa64.efi = EFI/ubuntu/grubaa64.efi"
    else
        sudo -n cp -f "$GRUB" "$BOOTDIR/BOOTAA64.EFI"
        sudo -n rm -f "$BOOTDIR/grubaa64.efi"
        BOOT_SRC=$GRUB
        echo "  warning: no shimaa64.efi; EFI/Boot/BOOTAA64.EFI = GRUB"
        echo "           Secure Boot must be off in this configuration"
    fi

    sudo -n python3 "$HERE/write_grub_menu.py" \
        "$ESP" "$UB" "$UBDEV" --timeout "$TIMEOUT"
    # A stale next_entry would make the next boot (the Windows readiness
    # check in build-image.sh) start Ubuntu instead of Windows.  The real
    # first-boot marker is written by finish_disk.sh after that check.
    sudo -n rm -f "$ESP/EFI/ubuntu/grubenv"
    sudo -n umount "$UB"

    for f in "$ESP/EFI/ubuntu/grub.cfg" "$ESP/EFI/BOOT/grub.cfg"; do
        [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
    done
    grep -q 'menuentry "Windows 11"' "$ESP/EFI/ubuntu/grub.cfg" || {
        echo "GRUB menu has no Windows entry" >&2
        exit 1
    }
    grep -q 'menuentry "Ubuntu (recovery)"' "$ESP/EFI/ubuntu/grub.cfg" || {
        echo "GRUB menu has no Ubuntu entry" >&2
        exit 1
    }
    echo "  GRUB menu: Windows 11 (default, ${TIMEOUT}s), Ubuntu (recovery)"
else
    # Windows-only build: leave the firmware fallback on the Windows loader.
    sudo -n mkdir -p "$BOOTDIR"
    sudo -n cp -f "$BOOTMGR" "$BOOTDIR/BOOTAA64.EFI"
    BOOT_SRC=$BOOTMGR
    echo "  EFI/Boot/BOOTAA64.EFI = EFI/Microsoft/Boot/bootmgfw.efi"
fi

sync
a=$(sha256sum "$BOOTDIR/BOOTAA64.EFI" | awk '{print $1}')
b=$(sha256sum "$BOOT_SRC" | awk '{print $1}')
[ "$a" = "$b" ] || { echo "fallback loader copy failed" >&2; exit 1; }
echo "  sha256 $a"
sudo -n umount "$ESP"

echo "[5/5] done"
echo "OK: finished $IMG"
