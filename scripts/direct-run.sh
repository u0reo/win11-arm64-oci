#!/usr/bin/env bash
# Write Windows 11 ARM64 directly onto a block device.
#
#   sudo ./scripts/direct-run.sh \
#     --disk /dev/sdb \
#     --iso /srv/iso/Win11_ARM64_26H2.iso \
#     --virtio /srv/iso/virtio-win.iso --yes
#
# The device is wiped.  Nothing is packaged and nothing is uploaded: the
# device itself becomes the Windows disk.  On OCI, detach the volume and
# reattach it as the boot volume of the target instance afterwards.
#
# WARNING: if this device is the running root device the script refuses to
# continue.  Take a boot volume backup first.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DISK=""
ISO=""
VIRTIO=""
DRIVERS=""
IMAGE_INDEX=${IMAGE_INDEX:-1}
MEM=${MEM:-8192}
SMP=${SMP:-4}
YES=0

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
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
if [ -n "$(lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | tr -d ' ')" ]; then
    echo "direct-run: $DISK has mounted partitions" >&2
    lsblk -o NAME,SIZE,MOUNTPOINT "$DISK" >&2
    exit 1
fi

ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$ROOTDEV" ] && [[ "$ROOTDEV" == "$DISK"* ]]; then
    echo "direct-run: $DISK is the running root device" >&2
    echo "  boot a RAM-resident live environment, or use the detach/attach" >&2
    echo "  method in docs/OCI.md" >&2
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

  ALL DATA ON $DISK WILL BE DESTROYED.
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
if [ -n "$DRIVERS" ]; then
    export DRIVERS_DIR="$DRIVERS"
else
    export VIRTIO_ISO="$VIRTIO"
fi

"$HERE/build-image.sh"

cat <<EOF

== done ==
$DISK now contains Windows 11 ARM64.

On OCI (detach/attach method):
  1. stop the builder instance
  2. detach this volume
  3. attach it to the target instance as the BOOT volume
  4. start the target instance and connect with RDP

The Windows account and password are the ones rendered into the image
(see config/defaults.env or the GitHub Secrets used for the build).
EOF
