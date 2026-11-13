#!/usr/bin/env bash
# Write Windows 11 ARM64 directly onto a block device.
#
#   sudo ./scripts/direct-run.sh \
#     --disk /dev/sdb \
#     --iso /srv/iso/Win11_ARM64_26H2.iso \
#     --virtio /srv/iso/virtio-win.iso --yes
#
# Add --keep-ubuntu to keep a small Ubuntu recovery system on the same disk
# (Windows Boot Manager chainloads its GRUB).  The old Ubuntu is replaced by
# a fresh minimal install; its netplan and SSH settings are copied over.
#
# Add --reuse-ubuntu instead when you already installed a small Ubuntu on
# partition 2 and booted it: partition 2 is left alone and only the free
# space is used for Windows.  This is the only mode that tolerates the
# target disk being the running root, because nothing on p2 is written.
#
# Add --to-ram to copy the ISOs into RAM first (needed when the ISO lives on
# the disk that is about to be wiped).  It hands over to live-ram-run.sh.
#
# The device is wiped.  Nothing is packaged and nothing is uploaded: the
# device itself becomes the Windows disk.  On OCI, detach the volume and
# reattach it as the boot volume of the target instance afterwards.
#
# WARNING: take a boot volume backup first.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# --to-ram is implemented by live-ram-run.sh; strip it and hand over.
for _a in "$@"; do
    if [ "$_a" = "--to-ram" ]; then
        _args=()
        for _x in "$@"; do [ "$_x" = "--to-ram" ] || _args+=("$_x"); done
        exec "$HERE/live-ram-run.sh" "${_args[@]}"
    fi
done
DISK=""
ISO=""
VIRTIO=""
DRIVERS=""
IMAGE_INDEX=${IMAGE_INDEX:-1}
MEM=${MEM:-8192}
SMP=${SMP:-4}
KEEP_UBUNTU=0
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}
YES=0

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk) DISK=$2; shift 2 ;;
        --iso) ISO=$2; shift 2 ;;
        --virtio) VIRTIO=$2; shift 2 ;;
        --drivers) DRIVERS=$2; shift 2 ;;
        --image-index) IMAGE_INDEX=$2; shift 2 ;;
        --mem) MEM=$2; shift 2 ;;
        --smp) SMP=$2; shift 2 ;;
        --keep-ubuntu) KEEP_UBUNTU=1; shift ;;
        --ubuntu-size) RECOVERY_SIZE=$2; KEEP_UBUNTU=1; shift 2 ;;
        --reuse-ubuntu) REUSE_UBUNTU=1; shift ;;
        --yes) YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "direct-run: unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -n "$DISK" ] || { echo "direct-run: --disk is required" >&2; usage 1; }
[ -n "$ISO" ] || { echo "direct-run: --iso is required" >&2; usage 1; }
[ -b "$DISK" ] || { echo "direct-run: $DISK is not a block device" >&2; exit 1; }
[ -f "$ISO" ] || { echo "direct-run: missing ISO $ISO" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "direct-run: run as root (sudo)" >&2
    exit 1
fi

# --- safety checks -------------------------------------------------------
ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_ON_DISK=0
if [ -n "$ROOTDEV" ] && [[ "$ROOTDEV" == "$DISK"* ]]; then
    ROOT_ON_DISK=1
fi

if [ "$ROOT_ON_DISK" = 1 ] && [ "$REUSE_UBUNTU" != 1 ]; then
    echo "direct-run: $DISK is the running root device" >&2
    echo "  boot a RAM-resident live environment (--to-ram), or use" >&2
    echo "  --reuse-ubuntu when p2 is a small Ubuntu that must survive" >&2
    exit 1
fi

if [ "$ROOT_ON_DISK" = 1 ]; then
    # Only the root itself may be mounted; the ESP has to be free because
    # WinPE writes bcdboot output to it.
    ROOT_MP=$(findmnt -no TARGET /)
    BUSY=""
    while read -r mp; do
        [ -z "$mp" ] && continue
        [ "$mp" = "$ROOT_MP" ] && continue
        BUSY="$BUSY $mp"
    done < <(lsblk -no MOUNTPOINT "$DISK")
    if [ -n "$BUSY" ]; then
        echo "direct-run: umount these before building:$BUSY" >&2
        lsblk -o NAME,SIZE,MOUNTPOINT "$DISK" >&2
        exit 1
    fi
    echo "direct-run: $DISK is the running disk; only $ROOT_MP stays mounted"
    swapoff -a 2>/dev/null || true
elif [ -n "$(lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | tr -d ' ')" ]; then
    echo "direct-run: $DISK has mounted partitions" >&2
    lsblk -o NAME,SIZE,MOUNTPOINT "$DISK" >&2
    exit 1
fi

SIZE_BYTES=$(blockdev --getsize64 "$DISK")
SIZE_GB=$(( SIZE_BYTES / 1024 / 1024 / 1024 ))
if [ "$SIZE_GB" -lt 40 ]; then
    echo "direct-run: $DISK is only ${SIZE_GB} GiB; Windows needs at least 40" >&2
    exit 1
fi

MODEL=$(lsblk -dno MODEL "$DISK" 2>/dev/null | sed 's/ *$//' || true)
SERIAL=$(lsblk -dno SERIAL "$DISK" 2>/dev/null | sed 's/ *$//' || true)

cat <<EOF

  target   $DISK
  model    ${MODEL:-unknown}
  serial   ${SERIAL:-unknown}
  size     ${SIZE_GB} GiB
  iso      $ISO
  drivers  ${DRIVERS:-$VIRTIO}
  index    $IMAGE_INDEX
  memory   ${MEM} MiB
  cpus     $SMP
  ubuntu   $([ "$REUSE_UBUNTU" = 1 ] && echo 'reuse the installed p2' || \
              { [ "$KEEP_UBUNTU" = 1 ] && echo "keep ${RECOVERY_SIZE} recovery system" || echo 'no (whole disk Windows)'; })

EOF

if [ "$REUSE_UBUNTU" = 1 ]; then
    cat <<EOF
  Partition 2 (the running Ubuntu) is NOT touched.  Windows goes into the
  unallocated space as partition 3, and the existing ESP keeps both boot
  loaders.  Nothing outside the free space is written.
  THE FREE SPACE AND THE ESP WILL BE MODIFIED.
EOF
elif [ "$KEEP_UBUNTU" = 1 ]; then
    cat <<EOF
  The ESP and the partition table stay.  Partition 2 is recreated as a
  ${RECOVERY_SIZE} ext4 recovery Ubuntu (fresh minimal install) and
  partition 3 takes the rest for Windows.  Its netplan and SSH settings
  are copied from the current Ubuntu before it is erased.
  EVERYTHING ELSE ON $DISK WILL BE DESTROYED.
EOF
else
    cat <<EOF
  ALL DATA ON $DISK WILL BE DESTROYED.
EOF
fi
cat <<EOF
  The QEMU guest will boot from this device twice: WinPE, then Windows.
  Do not interrupt the guest; a hard reset corrupts the SOFTWARE hive.
EOF

if [ "$YES" != 1 ]; then
    echo
    echo "Re-run with --yes to continue."
    exit 1
fi

# --- build ---------------------------------------------------------------
export DISK
export ISO
export IMAGE_INDEX MEM SMP
export KEEP_UBUNTU RECOVERY_SIZE REUSE_UBUNTU
if [ -n "$DRIVERS" ]; then
    export DRIVERS_DIR="$DRIVERS"
else
    export VIRTIO_ISO="$VIRTIO"
fi

"$HERE/build-image.sh"

cat <<EOF

== done ==
$DISK now contains Windows 11 ARM64.
EOF

if [ "$KEEP_UBUNTU" = 1 ]; then
    cat <<EOF
The ${RECOVERY_SIZE} recovery Ubuntu is on partition 2.  The Windows Boot
Manager menu shows it as "Ubuntu (recovery)" (5 second timeout).
EOF
elif [ "$REUSE_UBUNTU" = 1 ]; then
    cat <<EOF
The installed Ubuntu on partition 2 is untouched.  The Windows Boot Manager
menu should show it as "Ubuntu (recovery)" (5 second timeout).
EOF
fi

cat <<EOF

On OCI (detach/attach method):
  1. stop the builder instance
  2. detach this volume
  3. attach it to the target instance as the BOOT volume
  4. start the target instance and connect with RDP

If this is the live-CD method (you wrote to the disk the live system booted
from), no detach is needed: run 'sudo reboot' and the Windows install starts.

The Windows account and password are the ones rendered into the image
(see config/defaults.env or the GitHub Secrets used for the build).
EOF
