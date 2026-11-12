#!/usr/bin/env bash
# Build a small bootable FAT32 image from a Windows ARM64 ISO's own boot
# manager + boot.wim.  This avoids depending on the firmware's ISO/UDF boot
# support.  The original ISO is still attached as a data CD so Setup can read
# sources/install.wim.
#
# Usage: ./make_bootfat.sh /path/to/windows-arm64.iso [size-mb]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BUILD=${BUILD_DIR:-$ROOT/build}
ISO=${1:?usage: $0 <windows-arm64.iso> [size-mb]}
SIZE_MB=${2:-1536}
IMG="$BUILD/bootfat.img"
# Optional: use an already-prepared boot.wim (e.g. one whose Setup image
# was switched to a plain cmd.exe shell for manual DISM installation).
BOOTWIM=${BOOTWIM:-}
MNT=$(mktemp -d /tmp/bootfat-iso.XXXXXX)
STAGE=$(mktemp -d /tmp/bootfat-stage.XXXXXX)
MOUNTED=0
LOOP=""
cleanup() {
    set +e
    [ -n "$LOOP" ] && sudo -n losetup -d "$LOOP" 2>/dev/null
    [ "$MOUNTED" = 1 ] && sudo -n umount "$MNT" 2>/dev/null
    sudo -n rm -rf "$STAGE" "$MNT"
}
trap cleanup EXIT

echo "[1/4] mount ISO"
sudo -n mkdir -p "$MNT"
if ! sudo -n mount -t udf -o ro,loop "$ISO" "$MNT" 2>/dev/null; then
    sudo -n mount -t iso9660 -o ro,loop "$ISO" "$MNT"
fi
MOUNTED=1

for p in efi boot sources/boot.wim; do
    [ -e "$MNT/$p" ] || { echo "missing $p in ISO" >&2; exit 1; }
done

echo "[2/4] stage boot files (boot.wim + efi + boot)"
cp -a "$MNT/efi" "$STAGE/"
cp -a "$MNT/boot" "$STAGE/"
mkdir -p "$STAGE/sources"
if [ -n "$BOOTWIM" ]; then
    cp -a "$BOOTWIM" "$STAGE/sources/boot.wim"
else
    cp -a "$MNT/sources/boot.wim" "$STAGE/sources/"
fi
# Some media keep boot.sdi in sources/ instead of boot/.
[ -f "$STAGE/boot/boot.sdi" ] || cp -a "$MNT/sources/boot.sdi" "$STAGE/boot/" 2>/dev/null || true

echo "[3/4] build MBR + FAT32 boot image (${SIZE_MB} MB)"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count="$SIZE_MB" status=none
# AAVMF gives a superfloppy FAT a "Non-Block Boot Device" path; bootmgfw.efi
# then fails with Invalid Parameter.  A real MBR partition yields a HardDrive
# device path, which is what bootmgfw expects.
echo 'label: dos
start=2048, type=0c, bootable' | sfdisk -q "$IMG"
LOOP=$(sudo -n losetup --find --show --partscan "$IMG")
sudo -n partprobe "$LOOP" 2>/dev/null || true
sleep 1
sudo -n mkfs.vfat -F 32 -n BOOTFAT "${LOOP}p1" >/dev/null
sudo -n mcopy -i "${LOOP}p1" -s "$STAGE"/* ::/
echo "  --- image root ---"
sudo -n mdir -i "${LOOP}p1" ::/ | sed -n '1,30p'
sudo -n losetup -d "$LOOP"
LOOP=""

echo "[4/4] done"
ls -lh "$IMG"
