#!/usr/bin/env bash
# Fast install path: apply install.wim/esd to a fresh qcow2 on the host with
# wimlib-imagex.  wimlib writes directly to the NTFS volume through libntfs-3g
# and preserves Windows ACLs, hard links, reparse points and timestamps.
# This avoids the extremely slow DISM /apply-image under QEMU TCG.
#
# The ESP boot files and offline driver injection are done afterwards by
# booting WinPE with manual_start.cmd, which detects the existing Windows and
# calls manual_finish.cmd.
#
# Usage: ./host_apply.sh /path/to/windows-arm64.iso /path/to/disk.qcow2 [index]
# The target qcow2 is recreated from scratch.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ISO=${1:?usage: $0 <iso> <disk.qcow2> [index]}
IMG=${2:?usage: $0 <iso> <disk.qcow2> [index]}
INDEX=${3:-1}
MEDIA=${MEDIA:-$ROOT/build/media}
DRIVERS=${DRIVERS:-$ROOT/build/drivers}
DRIVERS_EXTRA=${DRIVERS_EXTRA:-$ROOT/build/drivers-extra}
SIZE=${SIZE:-50G}
SDB=${SDB:-/dev/nbd0}

[ -f "$ISO" ] || { echo "missing ISO: $ISO" >&2; exit 1; }
[ -f "$MEDIA/autounattend.xml" ] || { echo "missing $MEDIA/autounattend.xml; run make_oemdrv.sh first" >&2; exit 1; }
[ -d "$MEDIA/oem" ] || { echo "missing $MEDIA/oem" >&2; exit 1; }
[ -d "$DRIVERS" ] || { echo "missing $DRIVERS; run scripts/stage-drivers.sh" >&2; exit 1; }

if pgrep -f "qemu-system-aarch64.*$IMG" >/dev/null 2>&1; then
    echo "QEMU still references $IMG; stop it first" >&2
    exit 1
fi

ISO_MNT=$(mktemp -d /tmp/hostapply-iso.XXXXXX)
WIN_MNT=$(mktemp -d /tmp/hostapply-win.XXXXXX)
ISO_MOUNTED=0
WIN_MOUNTED=0
NBD=0
cleanup() {
    set +e
    [ "$WIN_MOUNTED" = 1 ] && sudo -n umount "$WIN_MNT" 2>/dev/null
    [ "$ISO_MOUNTED" = 1 ] && sudo -n umount "$ISO_MNT" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect "$SDB" >/dev/null 2>&1
    rmdir "$WIN_MNT" "$ISO_MNT" 2>/dev/null
}
trap cleanup EXIT

echo "[1/6] mount ISO"
sudo -n mkdir -p "$ISO_MNT"
if ! sudo -n mount -t udf -o ro,loop "$ISO" "$ISO_MNT" 2>/dev/null; then
    sudo -n mount -t iso9660 -o ro,loop "$ISO" "$ISO_MNT"
fi
ISO_MOUNTED=1
WIM=""
for f in "$ISO_MNT/sources/install.wim" "$ISO_MNT/sources/install.esd"; do
    [ -f "$f" ] && { WIM=$f; break; }
done
[ -n "$WIM" ] || { echo "no install.wim/esd in ISO" >&2; exit 1; }
echo "  source: $WIM"

echo "[2/6] create fresh qcow2 ($SIZE)"
rm -f "$IMG"
qemu-img create -f qcow2 "$IMG" "$SIZE" >/dev/null

echo "[3/6] partition and format"
sudo -n qemu-nbd --disconnect "$SDB" >/dev/null 2>&1 || true
sleep 1
sudo -n qemu-nbd --connect="$SDB" --format=qcow2 "$IMG"
NBD=1
# The kernel updates the NBD capacity asynchronously after connect; sgdisk
# would otherwise see a zero-sized device and fail with EINVAL/ENOSPC.
for _ in $(seq 1 20); do
    NBD_SIZE=$(sudo -n blockdev --getsize64 "$SDB" 2>/dev/null || echo 0)
    [ "$NBD_SIZE" -gt 0 ] && break
    sleep 0.5
done
[ "$NBD_SIZE" -gt 0 ] || { echo "NBD device did not become ready" >&2; exit 1; }
echo "  NBD size: $NBD_SIZE bytes"
sudo -n sgdisk --zap-all "$SDB" >/dev/null
sudo -n sgdisk \
    -n 1:2048:+100M -t 1:ef00 -c 1:"System" \
    -n 2:0:+16M   -t 2:0c01 -c 2:"MSR" \
    -n 3:0:0      -t 3:0700 -c 3:"Windows" \
    "$SDB" >/dev/null
sudo -n partprobe "$SDB" 2>/dev/null || true
sleep 2
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$SDB"
P3START=$(lsblk -no START "${SDB}p3" | tr -d ' ')
[ -n "$P3START" ] || { echo "cannot determine p3 start sector" >&2; exit 1; }
# -f is a quick format: without it mkntfs zeroes the whole 50G volume, which
# balloons the qcow2 and is extremely slow over NBD.  -p/-H/-S give the NTFS
# BPB the same geometry Windows uses, so Windows can boot from the volume.
sudo -n mkfs.vfat -F32 -n SYSTEM "${SDB}p1" >/dev/null
sudo -n mkntfs -f -F -L Windows -p "$P3START" -H 255 -S 63 "${SDB}p3" >/dev/null
echo "  formatted (p3 starts at sector $P3START)"

echo "[4/6] apply image $INDEX with wimlib-imagex"
time sudo -n wimlib-imagex apply "$WIM" "$INDEX" "${SDB}p3"

echo "[5/6] stage unattend, OEM scripts and drivers"
sudo -n mount -t ntfs-3g "${SDB}p3" "$WIN_MNT"
WIN_MOUNTED=1
sudo -n mkdir -p "$WIN_MNT/Windows/Panther"
sudo -n cp "$MEDIA/autounattend.xml" "$WIN_MNT/Windows/Panther/unattend.xml"
sudo -n cp -a "$MEDIA/oem" "$WIN_MNT/OEM"
sudo -n cp -a "$DRIVERS" "$WIN_MNT/drivers"
[ -d "$DRIVERS_EXTRA" ] && sudo -n cp -a "$DRIVERS_EXTRA" "$WIN_MNT/drivers-extra"
sudo -n sync
sudo -n umount "$WIN_MNT"
WIN_MOUNTED=0
echo "  staged"

echo "[5b/6] clear the NTFS dirty flag (avoids a forced autochk on first boot)"
sudo -n ntfsfix -d "${SDB}p3" || true

echo "[6/6] verify and disconnect"
sudo -n qemu-nbd --disconnect "$SDB" >/dev/null
NBD=0
qemu-img info "$IMG" | sed -n '1,12p'
ls -lh "$IMG"
echo "OK: $IMG"
echo "Next: boot WinPE with the manual bootfat; manual_start.cmd detects the"
echo "existing Windows and runs manual_finish.cmd (drivers + bcdboot)."
