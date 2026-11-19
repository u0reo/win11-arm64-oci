#!/usr/bin/env bash
# Patch the installed ESP's Windows boot manager for OCI A1 and verify the
# GRUB first-loader layout.  QEMU must be stopped first.
#
# GRUB is the first loader in dual-boot builds: \EFI\Boot\BOOTAA64.EFI is
# the signed Ubuntu shim and \EFI\Boot\grubaa64.efi is GRUB.  GRUB chainloads
# \EFI\Microsoft\Boot\bootmgfw.efi, so only that copy needs the OCI A1 patch
# there.  A Windows-only build keeps a second bootmgfw copy at
# \EFI\Boot\BOOTAA64.EFI; it gets the same patch so the firmware fallback also
# works on OCI.  The shim must never be patched.
#
# GRUB's FAT driver cannot open a chainloaded file whose first cluster is
# 65536 or above ("not a regular file").  The patched bootmgfw.efi is written
# through mtools, which allocates from the first free cluster, and its start
# cluster is checked before the old file is replaced.
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

WORK=$(mktemp -d /tmp/finish-disk.XXXXXX)
ESP=$(mktemp -d /tmp/finish-esp.XXXXXX)
PATCH_LOG="$WORK/patch.log"
NBD=0
cleanup() {
    set +e
    sudo -n umount "$ESP" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    cleanup_part_loops
    rm -rf "$WORK"
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

# Read the start cluster of a file in the ESP's FAT filesystem.  mshowfat
# prints "::/path <start-end>" on stdout.
fat_start() {
    local dev=$1 path=$2 start
    start=$(sudo -n mshowfat -i "$dev" "$path" 2>/dev/null |
        sed -n 's/.*<\([0-9][0-9]*\)-[0-9][0-9]*>.*/\1/p' | tail -1)
    case "$start" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$start"
}

# Copy one ESP file to the host.  The destination is removed first: /tmp is
# often a sticky world-writable directory with fs.protected_regular=2, and
# root would otherwise refuse to overwrite a file owned by the build user.
mtools_copy_out() {
    local dev=$1 path=$2 dst=$3
    rm -f "$dst"
    sudo -n mcopy -o -i "$dev" "::$path" "$dst" 2>/dev/null
}

echo "[3/4] patch and verify the ESP"
BOOTMGR_REL=EFI/Microsoft/Boot/bootmgfw.efi
SRC="$WORK/bootmgfw.orig"
PATCHED="$WORK/bootmgfw.patched"
CHECK="$WORK/bootmgfw.check"
mtools_copy_out "$ESPDEV" "/$BOOTMGR_REL" "$SRC" || {
    echo "  $BOOTMGR_REL: cannot read from the ESP" >&2
    exit 1
}
python3 "$HERE/patch_bootmgfw.py" "$SRC" "$PATCHED" >"$PATCH_LOG" 2>&1 || {
    echo "  $BOOTMGR_REL: patch failed" >&2
    sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
    exit 1
}

# Write under a temporary name so the original is still intact if the FAT
# allocation lands too high.
NEW_REL=EFI/Microsoft/Boot/bootmgfw.new
sudo -n mdel -i "$ESPDEV" "::/$NEW_REL" >/dev/null 2>&1 || true
sudo -n mcopy -o -i "$ESPDEV" "$PATCHED" "::/$NEW_REL"
START=$(fat_start "$ESPDEV" "::/$NEW_REL") || {
    echo "  cannot read the start cluster of $NEW_REL" >&2
    exit 1
}
if [ "$START" -ge 65536 ]; then
    # The old file occupies low clusters.  Free them and retry; mtools scans
    # from the beginning of the FAT, so the new copy should reuse that space.
    sudo -n mdel -i "$ESPDEV" "::/$BOOTMGR_REL" >/dev/null 2>&1 || true
    sudo -n mdel -i "$ESPDEV" "::/$NEW_REL" >/dev/null 2>&1 || true
    sudo -n mcopy -o -i "$ESPDEV" "$PATCHED" "::/$NEW_REL"
    START=$(fat_start "$ESPDEV" "::/$NEW_REL") || START=999999
fi
if [ "$START" -ge 65536 ]; then
    # Keep a bootable Windows loader on disk even though GRUB cannot open it.
    sudo -n mdel -i "$ESPDEV" "::/$BOOTMGR_REL" >/dev/null 2>&1 || true
    sudo -n mren -i "$ESPDEV" "::/$NEW_REL" "::/$BOOTMGR_REL" >/dev/null 2>&1 || true
    echo "  $BOOTMGR_REL starts at cluster $START (>= 65536)" >&2
    echo "  GRUB cannot chainload it.  Free low clusters on the ESP and rerun." >&2
    exit 1
fi

sudo -n mdel -i "$ESPDEV" "::/$BOOTMGR_REL" >/dev/null 2>&1 || true
sudo -n mren -i "$ESPDEV" "::/$NEW_REL" "::/$BOOTMGR_REL"
sync

mtools_copy_out "$ESPDEV" "/$BOOTMGR_REL" "$CHECK" || {
    echo "  $BOOTMGR_REL: cannot read back from the ESP" >&2
    exit 1
}
if ! python3 "$HERE/patch_bootmgfw.py" --dry-run --require-patched \
        "$CHECK" >"$PATCH_LOG" 2>&1; then
    echo "  $BOOTMGR_REL: verification failed after writing" >&2
    sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
    exit 1
fi
START=$(fat_start "$ESPDEV" "::/$BOOTMGR_REL") || START=999999
if [ "$START" -ge 65536 ]; then
    echo "  $BOOTMGR_REL starts at cluster $START after the rename" >&2
    exit 1
fi
echo "  $BOOTMGR_REL: patched, verified, FAT start cluster $START (< 65536)"
sed -n '1,8p' "$PATCH_LOG" | sed 's/^/    /'

# The firmware fallback must start GRUB, not a second copy of bootmgfw.efi.
if sudo -n mtype -i "$ESPDEV" ::/EFI/ubuntu/grubaa64.efi >/dev/null 2>&1; then
    BOOTAA64="$WORK/BOOTAA64.EFI"
    mtools_copy_out "$ESPDEV" /EFI/BOOT/BOOTAA64.EFI "$BOOTAA64" || {
        echo "  EFI/Boot/BOOTAA64.EFI is missing" >&2
        exit 1
    }
    SHIM="$WORK/shimaa64.efi"
    SHIM_SHA=""
    if mtools_copy_out "$ESPDEV" /EFI/ubuntu/shimaa64.efi "$SHIM"; then
        SHIM_SHA=$(sha256sum "$SHIM" | awk '{print $1}')
    fi
    BOOT_SHA=$(sha256sum "$BOOTAA64" | awk '{print $1}')
    ORIG_SHA=$(sha256sum "$SRC" | awk '{print $1}')
    BOOTMGR_SHA=$(sha256sum "$CHECK" | awk '{print $1}')
    if [ -n "$SHIM_SHA" ] && [ "$BOOT_SHA" = "$SHIM_SHA" ]; then
        echo "  EFI/Boot/BOOTAA64.EFI = shim (GRUB is the first loader)"
    elif [ "$BOOT_SHA" = "$BOOTMGR_SHA" ] || [ "$BOOT_SHA" = "$ORIG_SHA" ]; then
        echo "  EFI/Boot/BOOTAA64.EFI is still the Windows boot manager" >&2
        echo "  rerun finish_winpe.sh to install GRUB as the first loader" >&2
        exit 1
    else
        echo "  EFI/Boot/BOOTAA64.EFI is neither shim nor bootmgfw" >&2
        echo "  sha256 $BOOT_SHA" >&2
        exit 1
    fi
    GRUB_CFG="$WORK/grub.cfg"
    mtools_copy_out "$ESPDEV" /EFI/ubuntu/grub.cfg "$GRUB_CFG" || {
        echo "  EFI/ubuntu/grub.cfg is missing" >&2
        exit 1
    }
    grep -q 'menuentry "Windows 11"' "$GRUB_CFG" || {
        echo "  GRUB menu has no Windows entry" >&2
        exit 1
    }
    grep -q 'menuentry "Ubuntu (recovery)"' "$GRUB_CFG" || {
        echo "  GRUB menu has no Ubuntu entry" >&2
        exit 1
    }
    echo "  GRUB menu has Windows 11 and Ubuntu (recovery)"
else
    # Windows-only build: EFI/Boot/BOOTAA64.EFI is a second copy of
    # bootmgfw.efi and needs the same patch.  GRUB is not involved here, so
    # the start-cluster limit does not apply to this copy.
    echo "  no EFI/ubuntu/grubaa64.efi; Windows-only ESP"
    BOOTAA64_REL=EFI/BOOT/BOOTAA64.EFI
    BOOTAA64="$WORK/BOOTAA64.EFI"
    mtools_copy_out "$ESPDEV" "/$BOOTAA64_REL" "$BOOTAA64" || {
        echo "  $BOOTAA64_REL is missing" >&2
        exit 1
    }
    BOOT_SHA=$(sha256sum "$BOOTAA64" | awk '{print $1}')
    ORIG_SHA=$(sha256sum "$SRC" | awk '{print $1}')
    PATCHED_SHA=$(sha256sum "$PATCHED" | awk '{print $1}')
    if [ "$BOOT_SHA" = "$ORIG_SHA" ]; then
        sudo -n mdel -i "$ESPDEV" "::/$BOOTAA64_REL" >/dev/null 2>&1 || true
        sudo -n mcopy -o -i "$ESPDEV" "$PATCHED" "::/$BOOTAA64_REL"
        sync
        echo "  $BOOTAA64_REL: patched (firmware fallback)"
    elif [ "$BOOT_SHA" = "$PATCHED_SHA" ]; then
        echo "  $BOOTAA64_REL: already patched"
    else
        echo "  warning: $BOOTAA64_REL is neither stock nor patched bootmgfw" >&2
        echo "  not touching it" >&2
    fi
fi

# Remove the old Windows Boot Manager bootapp entry for Ubuntu.  The BCD is
# small, so a mount/write/unmount cycle is simpler than moving it through
# mtools.
sudo -n mount -t vfat "$ESPDEV" "$ESP"
sudo -n python3 "$HERE/bcd_remove_ubuntu.py" "$ESP/EFI/Microsoft/Boot/BCD" \
    | sed 's/^/  /'
sudo -n rm -f "$ESP/EFI/Microsoft/Boot/BCD.LOG" \
              "$ESP/EFI/Microsoft/Boot/BCD.LOG1" \
              "$ESP/EFI/Microsoft/Boot/BCD.LOG2"
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
