#!/usr/bin/env bash
# Keep the installed ESP's Windows boot manager stock and verify the GRUB
# first-loader layout.  QEMU must be stopped first.
#
# GRUB is the first loader in dual-boot builds: \EFI\Boot\BOOTAA64.EFI is
# the signed Ubuntu shim and \EFI\Boot\grubaa64.efi is GRUB.  GRUB chainloads
# \EFI\Microsoft\Boot\bootmgfw.efi.  A Windows-only build keeps a second
# bootmgfw copy at \EFI\Boot\BOOTAA64.EFI; it is left stock as well.  The
# shim must never be patched.
#
# Do not patch bootmgfw.efi by default.  The 0x102000 AllocatePages failure is
# only a firmware DEBUG() message: bootmgfw ignores the return status and
# continues.  A modified boot manager is a different image than the one named
# in boot.stl/CIPolicies, so a later integrity check can terminate the boot
# chain silently.  Local QEMU tests show the patched 26089 boot manager exits
# before the boot menu while the stock copy reaches the Windows lock screen.
#
# The stock copy is taken from the installed Windows volume whenever it is
# readable.  That keeps bootmgfw.efi consistent with the BCD, bootmgr.efi,
# boot.stl and CIPolicies that bcdboot wrote.  Mixing a 26089 boot manager
# with a 28000 boot chain is not supported and can fail before the boot menu
# on real firmware even though QEMU tolerates it.
# PATCH_BOOTMGFW=1 keeps the old #2 -> #1 patch available for experiments.
# STOCK_BOOTMGFW=/path/to/bootmgfw.efi forces a specific stock copy.
#
# GRUB's FAT driver cannot open a file whose first cluster is 65536 or above
# ("not a regular file").  That applies to the chainloaded bootmgfw.efi and
# to the GRUB menu itself.  The loader is written through mtools and its
# start cluster is checked; if it (or a menu file) lands too high, the ESP is
# rebuilt with esp_compact.sh so those files sit in the first clusters.
#
# The target can be a qcow2 file or a raw block device.
# Usage: ./finish_disk.sh /path/to/disk.qcow2 | /dev/sdX
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"
IMG=${1:?usage: $0 <disk.qcow2|/dev/sdX>}
PATCH_BOOTMGFW=${PATCH_BOOTMGFW:-0}
STOCK_BOOTMGFW=${STOCK_BOOTMGFW:-}
STOCK_BOOTMGR=${STOCK_BOOTMGR:-}
STOCK_BOOT_STL=${STOCK_BOOT_STL:-}

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
WIN=$(mktemp -d /tmp/finish-ntfs.XXXXXX)
WRE=$(mktemp -d /tmp/finish-winre.XXXXXX)
PATCH_LOG="$WORK/patch.log"
NBD=0
cleanup() {
    set +e
    sudo -n umount "$ESP" 2>/dev/null
    sudo -n umount "$WIN" 2>/dev/null
    sudo -n umount "$WRE" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    cleanup_part_loops
    rm -rf "$WORK"
    rmdir "$ESP" "$WIN" "$WRE" 2>/dev/null
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

# The ESP's bootmgfw.efi must come from the same Windows installation as the
# BCD, bootmgr.efi, boot.stl and CIPolicies.  bcdboot can leave an older
# stock copy after a servicing update, and a manual repair can leave an even
# older one.  Prefer the installed Windows copy so the signed boot chain is
# version-consistent; fall back to the ESP copy only when it cannot be read.
WINDOWS_BOOTMGFW=""
WINDOWS_BOOTMGR=""
WINDOWS_BOOT_STL=""
WINDEV=$(find_windows "$DEV" || true)
if [ -n "$WINDEV" ] && sudo -n mount -t ntfs-3g -o ro "$WINDEV" "$WIN" 2>/dev/null; then
    for pair in bootmgfw.efi:bootmgfw bootmgr.efi:bootmgr boot.stl:boot.stl; do
        src=${pair%%:*}
        dst=${pair#*:}
        [ -f "$WIN/Windows/Boot/EFI/$src" ] || continue
        sudo -n cp -f "$WIN/Windows/Boot/EFI/$src" "$WORK/$dst"
        echo "  installed Windows $src: $(stat -c %s "$WORK/$dst") bytes"
    done
    [ -f "$WORK/bootmgfw" ] && WINDOWS_BOOTMGFW="$WORK/bootmgfw"
    [ -f "$WORK/bootmgr" ] && WINDOWS_BOOTMGR="$WORK/bootmgr"
    [ -f "$WORK/boot.stl" ] && WINDOWS_BOOT_STL="$WORK/boot.stl"
    sudo -n umount "$WIN"
fi

# Read the first cluster of a file in the ESP's FAT filesystem.  mshowfat
# prints "::/path <start-end> <start-end> ..."; a fragmented file has more
# than one range, and GRUB looks at the first one.
fat_start() {
    local dev=$1 path=$2 start
    start=$(sudo -n mshowfat -i "$dev" "$path" 2>/dev/null |
        sed -n 's/^[^<]*<\([0-9][0-9]*\)-[0-9][0-9]*>.*/\1/p' | head -1)
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

echo "[3/4] verify and write the ESP boot manager"
BOOTMGR_REL=EFI/Microsoft/Boot/bootmgfw.efi
SRC="$WORK/bootmgfw.orig"
PATCHED="$WORK/bootmgfw.new"
CHECK="$WORK/bootmgfw.check"
mtools_copy_out "$ESPDEV" "/$BOOTMGR_REL" "$SRC" || {
    echo "  $BOOTMGR_REL: cannot read from the ESP" >&2
    exit 1
}
if [ "$PATCH_BOOTMGFW" = 1 ]; then
    python3 "$HERE/patch_bootmgfw.py" "$SRC" "$PATCHED" >"$PATCH_LOG" 2>&1 || {
        echo "  $BOOTMGR_REL: patch failed" >&2
        sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
        exit 1
    }
    echo "  PATCH_BOOTMGFW=1: writing the experimental patched boot manager"
else
    # Keep a signed Microsoft image.  The patch is only a diagnostic
    # workaround; a modified boot manager may fail boot.stl/CIPolicies
    # integrity checks later in the chain.
    if [ -n "$STOCK_BOOTMGFW" ]; then
        cp "$STOCK_BOOTMGFW" "$PATCHED"
        echo "  using STOCK_BOOTMGFW"
    elif [ -n "$WINDOWS_BOOTMGFW" ]; then
        cp "$WINDOWS_BOOTMGFW" "$PATCHED"
        echo "  using the installed Windows boot manager"
    elif python3 "$HERE/patch_bootmgfw.py" --dry-run --require-patched \
            "$SRC" >/dev/null 2>&1; then
        echo "  $BOOTMGR_REL on the ESP is patched; set STOCK_BOOTMGFW=<stock.efi>" >&2
        exit 1
    else
        cp "$SRC" "$PATCHED"
        echo "  keeping the stock bootmgfw.efi from the ESP"
    fi
fi

# Oracle AAVMF 20260902 stops before the Windows Boot Manager menu when the
# ESP carries a 26H2-era (28000.x) boot manager.  The 26100.1041 boot manager
# from 24H2/25H2 media boots the same 26100 Windows installation.  Keep this
# visible: a build that silently takes C:\Windows\Boot\EFI after a servicing
# update will reproduce the native hang.
BM_VER=$(strings -el "$PATCHED" 2>/dev/null |
    sed -n 's/^10\.0\.\([0-9][0-9]*\)\.[0-9].*/\1/p' | head -1)
case "$BM_VER" in
    ''|*[!0-9]*)
        echo "  WARNING: cannot read the boot manager version" >&2
        ;;
    *)
        echo "  boot manager build: 10.0.$BM_VER"
        if [ "$BM_VER" -ge 28000 ]; then
            echo "  WARNING: 28000-era bootmgfw hangs on OCI AAVMF 20260902." >&2
            echo "  Use a stock 26100.1041 boot manager (24H2/25H2 media) via" >&2
            echo "  STOCK_BOOTMGFW=<path> if the guest does not reach the menu." >&2
        fi
        ;;
esac

# Write under a temporary name so the original is still intact if the FAT
# allocation lands too high.
NEW_REL=EFI/Microsoft/Boot/bootmgfw.new
sudo -n mdel -i "$ESPDEV" "::/$NEW_REL" >/dev/null 2>&1 || true
sudo -n mcopy -o -i "$ESPDEV" "$PATCHED" "::/$NEW_REL"
START=$(fat_start "$ESPDEV" "::/$NEW_REL") || {
    echo "  cannot read the start cluster of $NEW_REL" >&2
    exit 1
}

# The GRUB menu is read by GRUB's own FAT driver as well, so it has the same
# 65536 limit.  finish_winpe.sh writes it after bcdboot, which can already
# put it past the limit.
COMPACT=0
[ "$START" -ge 65536 ] && COMPACT=1
for rel in /EFI/ubuntu/grub.cfg /EFI/BOOT/grub.cfg; do
    s=$(fat_start "$ESPDEV" "::$rel") || s=999999
    if [ "$s" -ge 65536 ]; then
        echo "  $rel starts at cluster $s (>= 65536)" >&2
        COMPACT=1
    fi
done

if [ "$COMPACT" = 1 ]; then
    # There may be no free cluster below 65536 left (bcdboot fills the ESP
    # from the start), so re-lay out the filesystem instead of shuffling
    # files around.  esp_compact.sh builds and checks a new image first.
    sudo -n mdel -i "$ESPDEV" "::/$NEW_REL" >/dev/null 2>&1 || true
    echo "  rebuilding the ESP with the GRUB-visible files in low clusters"
    sudo -n "$HERE/esp_compact.sh" "$ESPDEV" "$PATCHED" | sed 's/^/  /'
else
    sudo -n mdel -i "$ESPDEV" "::/$BOOTMGR_REL" >/dev/null 2>&1 || true
    sudo -n mren -i "$ESPDEV" "::/$NEW_REL" "::/$BOOTMGR_REL"
    sync
fi

mtools_copy_out "$ESPDEV" "/$BOOTMGR_REL" "$CHECK" || {
    echo "  $BOOTMGR_REL: cannot read back from the ESP" >&2
    exit 1
}
if [ "$PATCH_BOOTMGFW" = 1 ]; then
    if ! python3 "$HERE/patch_bootmgfw.py" --dry-run --require-patched \
            "$CHECK" >"$PATCH_LOG" 2>&1; then
        echo "  $BOOTMGR_REL: verification failed after writing" >&2
        sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
        exit 1
    fi
else
    if ! python3 "$HERE/patch_bootmgfw.py" --dry-run \
            "$CHECK" >"$PATCH_LOG" 2>&1; then
        echo "  $BOOTMGR_REL: cannot read back the stock boot manager" >&2
        sed -n '1,12p' "$PATCH_LOG" | sed 's/^/    /' >&2
        exit 1
    fi
    if grep -q '^state=patched' "$PATCH_LOG"; then
        echo "  $BOOTMGR_REL: expected stock but found the patched copy" >&2
        exit 1
    fi
    sed -n '1,8p' "$PATCH_LOG" | sed 's/^/    /'
fi
START=$(fat_start "$ESPDEV" "::/$BOOTMGR_REL") || START=999999
if [ "$START" -ge 65536 ]; then
    echo "  $BOOTMGR_REL starts at cluster $START after the rename" >&2
    exit 1
fi
if [ "$PATCH_BOOTMGFW" = 1 ]; then
    echo "  $BOOTMGR_REL: patched, verified, FAT start cluster $START (< 65536)"
else
    echo "  $BOOTMGR_REL: stock, verified, FAT start cluster $START (< 65536)"
fi
sed -n '1,8p' "$PATCH_LOG" | sed 's/^/    /'

# Keep bootmgr.efi and boot.stl in the same generation as bootmgfw.efi.
# bcdboot writes all three from the installed Windows, but replacing only
# bootmgfw with a media copy leaves a mixed chain (for example 26100 bootmgfw
# with 28000 bootmgr/boot.stl) that the OCI firmware can reject before the
# boot menu.  Use files next to an explicit STOCK_BOOTMGFW/STOCK_BOOTMGR, or
# the installed Windows copy, and verify that nothing is a 26H2 28000 image.
copy_to_esp_if_changed() {
    local dev=$1 rel=$2 src=$3 current=$WORK/esp-current
    rm -f "$current"
    if sudo -n mcopy -o -i "$dev" "::$rel" "$current" 2>/dev/null &&
       cmp -s "$src" "$current"; then
        echo "  $rel: already matches $(basename "$src")"
        return 0
    fi
    sudo -n mdel -i "$dev" "::/$rel" >/dev/null 2>&1 || true
    sudo -n mcopy -o -i "$dev" "$src" "::/$rel"
    echo "  $rel: updated from $(basename "$src")"
}

SRC_BOOTMGR=""
if [ -n "$STOCK_BOOTMGR" ]; then
    SRC_BOOTMGR=$STOCK_BOOTMGR
elif [ -n "$STOCK_BOOTMGFW" ] &&
     [ -f "$(dirname "$STOCK_BOOTMGFW")/bootmgr.efi" ]; then
    SRC_BOOTMGR=$(dirname "$STOCK_BOOTMGFW")/bootmgr.efi
elif [ -z "$STOCK_BOOTMGFW" ] && [ -n "$WINDOWS_BOOTMGR" ]; then
    # No pinned bootmgfw: the ESP is on the installed Windows generation, so
    # its bootmgr.efi matches.  With STOCK_BOOTMGFW set, copying the installed
    # Windows copy would reintroduce the 26100/28000 mix we are avoiding.
    SRC_BOOTMGR=$WINDOWS_BOOTMGR
fi
SRC_BOOT_STL=""
if [ -n "$STOCK_BOOT_STL" ]; then
    SRC_BOOT_STL=$STOCK_BOOT_STL
elif [ -n "$STOCK_BOOTMGFW" ] &&
     [ -f "$(dirname "$STOCK_BOOTMGFW")/boot.stl" ]; then
    SRC_BOOT_STL=$(dirname "$STOCK_BOOTMGFW")/boot.stl
elif [ -z "$STOCK_BOOTMGFW" ] && [ -n "$WINDOWS_BOOT_STL" ]; then
    SRC_BOOT_STL=$WINDOWS_BOOT_STL
fi
if [ -n "$SRC_BOOTMGR" ]; then
    copy_to_esp_if_changed "$ESPDEV" EFI/Microsoft/Boot/bootmgr.efi "$SRC_BOOTMGR"
elif [ -n "$STOCK_BOOTMGFW" ]; then
    echo "  warning: no bootmgr.efi from the pinned bootmgfw generation" >&2
    echo "  pass STOCK_BOOTMGR=<bootmgr.efi> to avoid a mixed boot chain" >&2
else
    echo "  warning: no bootmgr.efi source; leaving the ESP copy alone" >&2
fi
if [ -n "$SRC_BOOT_STL" ]; then
    copy_to_esp_if_changed "$ESPDEV" EFI/Microsoft/Boot/boot.stl "$SRC_BOOT_STL"
elif [ -n "$STOCK_BOOTMGFW" ]; then
    echo "  warning: no boot.stl from the pinned bootmgfw generation" >&2
    echo "  pass STOCK_BOOT_STL=<boot.stl> to avoid a mixed boot chain" >&2
else
    echo "  warning: no boot.stl source; leaving the ESP copy alone" >&2
fi

for pair in "bootmgfw:$PATCHED" "bootmgr:$SRC_BOOTMGR"; do
    label=${pair%%:*}
    file=${pair#*:}
    [ -n "$file" ] && [ -f "$file" ] || continue
    build=$(strings -el "$file" 2>/dev/null |
        sed -n 's/^10\.0\.\([0-9][0-9]*\)\.[0-9].*/\1/p' | head -1)
    case "$build" in
        ''|*[!0-9]*) ;;
        *)
            echo "  $label build: 10.0.$build"
            if [ "$build" -ge 28000 ]; then
                echo "  WARNING: $label is a 26H2 (28000) image." >&2
                echo "  Keep bootmgfw, bootmgr and boot.stl on 26100/26089 media" >&2
                echo "  via STOCK_BOOTMGFW/STOCK_BOOTMGR/STOCK_BOOT_STL." >&2
            fi
            ;;
    esac
done
sync

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
    for rel in /EFI/ubuntu/grub.cfg /EFI/BOOT/grub.cfg; do
        s=$(fat_start "$ESPDEV" "::$rel") || s=999999
        if [ "$s" -ge 65536 ]; then
            echo "  $rel starts at cluster $s (>= 65536); GRUB cannot read it" >&2
            exit 1
        fi
    done
    echo "  GRUB menu has Windows 11 and Ubuntu (recovery)"
else
    # Windows-only build: EFI/Boot/BOOTAA64.EFI is a second bootmgfw copy.
    # Keep it stock; the firmware fallback must not carry the diagnostic
    # patch.  GRUB is not involved here, so the start-cluster limit does not
    # apply to this copy.
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
    if [ "$PATCH_BOOTMGFW" = 0 ]; then
        if python3 "$HERE/patch_bootmgfw.py" --dry-run --require-patched \
                "$BOOTAA64" >/dev/null 2>&1; then
            sudo -n mdel -i "$ESPDEV" "::/$BOOTAA64_REL" >/dev/null 2>&1 || true
            sudo -n mcopy -o -i "$ESPDEV" "$SRC" "::/$BOOTAA64_REL"
            sync
            echo "  $BOOTAA64_REL: patched copy replaced with stock bootmgfw"
        else
            echo "  $BOOTAA64_REL: stock (left as-is)"
        fi
    elif [ "$BOOT_SHA" = "$ORIG_SHA" ]; then
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

# Remove the old Windows Boot Manager bootapp entry for Ubuntu and any
# explicit EMS settings left by boot.ps1.  The BCD is small, so a
# mount/write/unmount cycle is simpler than moving it through mtools.
sudo -n mount -t vfat "$ESPDEV" "$ESP"
sudo -n python3 "$HERE/bcd_remove_ubuntu.py" "$ESP/EFI/Microsoft/Boot/BCD" \
    | sed 's/^/  /'
# boot.ps1 may have written explicit EMS port/baud into the BCD during OOBE.
# On OCI ARM64 those point at x86 COM1 and make bootmgr hang silently.  The
# normaliser also disables the two EMS writers that duplicate every bootmgr
# character on the PL011, and re-adds nointegritychecks, which this modified
# installation needs (0xc0000428 otherwise).  See WORKLOG 22.46.
sudo -n python3 "$HERE/bcd_normalize.py" "$ESP/EFI/Microsoft/Boot/BCD" \
    | sed 's/^/  /'
sudo -n rm -f "$ESP/EFI/Microsoft/Boot/BCD.LOG" \
              "$ESP/EFI/Microsoft/Boot/BCD.LOG1" \
              "$ESP/EFI/Microsoft/Boot/BCD.LOG2"
sync
sudo -n umount "$ESP"

echo "[4/4] final check"
# qemu-nbd stays connected until after the Windows RE check below.
# Windows RE is informative here, not fatal: a failed move still leaves a
# working WinRE on C:.  inspect_image.sh shows the same data read-only.
WINRE_N=$(find_winre_num "$DEV")
if [ -n "$WINRE_N" ]; then
    WINREPART=$(partition_dev "$DEV" "$WINRE_N" || true)
    if [ -n "$WINREPART" ] &&
       sudo -n mount -t ntfs-3g -o ro "$WINREPART" "$WRE"; then
        if [ -s "$WRE/Recovery/WindowsRE/Winre.wim" ]; then
            echo "  Windows RE: p$WINRE_N has Winre.wim ($(stat -c %s "$WRE/Recovery/WindowsRE/Winre.wim") bytes)"
            WINPART=$(find_windows "$DEV" || true)
            if [ -n "$WINPART" ] &&
               sudo -n mount -t ntfs-3g -o ro "$WINPART" "$WIN"; then
                WINRE_START=$(gpt_part_start "$DEV" "$WINRE_N")
                if [ -n "$WINRE_START" ]; then
                    WINRE_SSIZE=$(sudo -n blockdev --getss "$DEV" 2>/dev/null || echo 512)
                    WINRE_OFFSET=$(( WINRE_START * WINRE_SSIZE ))
                    python3 "$HERE/winre_report.py" \
                        "$WIN/Windows/System32/Recovery/ReAgent.xml" \
                        --offset "$WINRE_OFFSET" --partition "$WINRE_N" |
                        sed 's/^/    /'
                fi
                sudo -n umount "$WIN"
            fi
        else
            echo "  warning: p$WINRE_N has no Winre.wim; Windows RE is still on C:" >&2
            echo "  see C:\\OEM\\winre.log and C:\\OEM\\winre.failed in the image" >&2
        fi
        sudo -n umount "$WRE"
    else
        echo "  warning: cannot mount the Windows RE partition read-only" >&2
    fi
else
    echo "  no dedicated Windows RE partition (WinRE stays on C:)"
fi

if [ "$NBD" = 1 ]; then
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    NBD=0
fi
if [ "$RAW" = 1 ]; then
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV"
else
    qemu-img info "$IMG" | sed -n '1,15p'
fi
echo "OK: patched $IMG"
