#!/usr/bin/env bash
# Rebuild an ESP so GRUB can open its menu and the Windows chainloader.
#
#   sudo ./pipeline/esp_compact.sh /dev/sdb1 /tmp/bootmgfw.patched
#
# GRUB's FAT driver refuses a file whose first cluster is 65536 or above
# ("not a regular file").  A 100 MiB ESP uses 512-byte clusters, so it has
# about 204k clusters; bcdboot writes enough files before
# \EFI\Microsoft\Boot\bootmgfw.efi (and finish_winpe.sh writes the GRUB menu
# after bcdboot) that both can start past that limit.
#
# This script formats the same partition again and copies the files back in
# a fixed order, so the files GRUB opens land in the first clusters.  The
# new filesystem is built in a temporary image and verified before it is
# written to the partition; a failure leaves the ESP untouched.  The label
# and hidden-sector count are kept, the volume serial number changes.
set -euo pipefail

ESPDEV=${1:?usage: $0 <esp-partition> <patched-bootmgfw>}
PATCHED=${2:?usage: $0 <esp-partition> <patched-bootmgfw>}
[ "$(id -u)" = 0 ] || { echo "esp-compact: run as root (sudo)" >&2; exit 1; }
[ -s "$PATCHED" ] || { echo "esp-compact: missing $PATCHED" >&2; exit 1; }

# Files that must start below cluster 65536, in the order they are written.
# bootmgfw.efi is chainloaded by GRUB; the GRUB menu is read by GRUB itself;
# BCD is read by bootmgfw and is small, so keeping it low costs nothing.
# The ESP mixes "Boot" and "ubuntu", so match every path case-insensitively
# and keep the spelling found on disk.
PRIORITY_WANT=(
    EFI/ubuntu/grub.cfg
    EFI/Boot/grub.cfg
    EFI/Microsoft/Boot/bootmgfw.efi
    EFI/Microsoft/Boot/BCD
)
PRIORITY=()

WORK=$(mktemp -d /tmp/esp-compact.XXXXXX)
MNT=$WORK/mnt
IMG_MNT=$WORK/img-mnt
TREE=$WORK/tree
PRIO=$WORK/prio
IMG=$WORK/esp.img
mkdir -p "$MNT" "$IMG_MNT" "$TREE" "$PRIO"
cleanup() {
    set +e
    mountpoint -q "$MNT" && umount "$MNT"
    mountpoint -q "$IMG_MNT" && umount "$IMG_MNT"
    rm -rf "$WORK"
}
trap cleanup EXIT

start_of() {
    local image=$1 rel=$2 start
    start=$(mshowfat -i "$image" "::/$rel" 2>/dev/null |
        sed -n 's/^[^<]*<\([0-9][0-9]*\)-[0-9][0-9]*>.*/\1/p' | head -1)
    case "$start" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$start"
}

echo "[1/5] read the current ESP"
mount -t vfat -o ro "$ESPDEV" "$MNT"
cp -a "$MNT/." "$TREE/"
umount "$MNT"
LABEL=$(LC_ALL=C mlabel -s -i "$ESPDEV" :: 2>/dev/null |
    sed -n 's/^Volume label is //p' | tr -d '\r')
LABEL=${LABEL:-SYSTEM}
SIZE=$(if [ -b "$ESPDEV" ]; then blockdev --getsize64 "$ESPDEV";
       else stat -c %s "$ESPDEV"; fi)
# The BPB hidden-sector field is informational for UEFI; keep it when the
# partition offset is known.
HIDDEN=$(lsblk -no START "$ESPDEV" 2>/dev/null | tr -d ' ' || true)
HIDDEN=${HIDDEN:-0}

# Resolve one path against the copied tree without depending on case.
resolve_ci() {
    local want=$1
    find "$TREE" -type f -ipath "$TREE/$want" -print -quit
}

for want in "${PRIORITY_WANT[@]}"; do
    real=$(resolve_ci "$want")
    if [ -n "$real" ]; then
        rel=${real#"$TREE"/}
        mkdir -p "$PRIO/$(dirname "$rel")"
        mv "$real" "$PRIO/$rel"
    elif [ "${want,,}" = efi/microsoft/boot/bootmgfw.efi ]; then
        echo "esp-compact: $want is missing; using the patched copy" >&2
        rel=$want
        mkdir -p "$PRIO/$(dirname "$rel")"
    else
        echo "esp-compact: $want is missing from the ESP" >&2
        exit 1
    fi
    PRIORITY+=("$rel")
done
# The Windows loader is already patched; put the patched copy in its place.
for rel in "${PRIORITY[@]}"; do
    case "${rel,,}" in
        */bootmgfw.efi) cp -f "$PATCHED" "$PRIO/$rel" ;;
    esac
done

echo "[2/5] build a new filesystem in $IMG ($SIZE bytes)"
truncate -s "$SIZE" "$IMG"
mkfs.vfat -F32 -n "$LABEL" -h "$HIDDEN" "$IMG" >/dev/null
mount -o loop -t vfat "$IMG" "$IMG_MNT"

echo "[3/5] copy the GRUB-visible files first"
for rel in "${PRIORITY[@]}"; do
    mkdir -p "$IMG_MNT/$(dirname "$rel")"
    cp -f "$PRIO/$rel" "$IMG_MNT/$rel"
done
sync
cp -a "$TREE/." "$IMG_MNT/"
sync
umount "$IMG_MNT"

echo "[4/5] verify the new image"
for rel in "${PRIORITY[@]}"; do
    start=$(start_of "$IMG" "$rel") || {
        echo "esp-compact: cannot read the start cluster of $rel" >&2
        exit 1
    }
    if [ "$start" -ge 65536 ]; then
        echo "esp-compact: $rel still starts at cluster $start" >&2
        exit 1
    fi
    printf '  %-36s cluster %s\n' "$rel" "$start"
done
mcopy -o -i "$IMG" ::/EFI/Microsoft/Boot/bootmgfw.efi "$WORK/check.efi"
cmp -s "$WORK/check.efi" "$PATCHED" || {
    echo "esp-compact: bootmgfw.efi did not survive the copy" >&2
    exit 1
}

echo "[5/5] write the ESP"
dd if="$IMG" of="$ESPDEV" bs=1M conv=fsync status=none
sync
echo "OK: rebuilt the ESP on $ESPDEV"
