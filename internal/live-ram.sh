#!/usr/bin/env bash
# Force method B with memory only: no extra data volume for the ISO.
# This is internal; call it through scripts/build.sh.
#
#   sudo ./scripts/build.sh --to-ram --disk /dev/sda \
#     --iso /cdrom/Win11_ARM64_26H2.iso \
#     --virtio /cdrom/virtio-win.iso --mem 6144 --yes
#
# The live system must have booted with `toram`, because the partition that
# holds the Windows ISO is on the disk that is about to be wiped.  This
# script copies the ISO (and virtio-win.iso) into tmpfs first, unmounts
# everything on the target disk, then hands over to scripts/build.sh.
#
# --keep-ubuntu and --reuse-ubuntu are forwarded to scripts/build.sh.
# --reuse-ubuntu keeps p2, so nothing has to be copied into RAM.
#
# Memory budget on a 24 GB A1 (MEM=6144):
#   live ISO in RAM (toram)   2.5 GB
#   Windows ISO copy          6.2 GB
#   virtio-win copy           0.7 GB
#   QEMU guest                6.0 GB
#   live system + page cache  ~8 GB
# It fits, but there is no room for a 16 GB guest.  Use --mem 6144 (or
# --mem 4096) rather than the 8192 default.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DISK=""
ISO=""
VIRTIO=""
DRIVERS=""
IMAGE_INDEX=${IMAGE_INDEX:-1}
MEM=${MEM:-6144}
SMP=${SMP:-4}
KEEP_UBUNTU=0
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}
YES=0
RAMDIR=${RAMDIR:-/dev/shm}
MIN_FREE_MB=${MIN_FREE_MB:-2048}

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
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
        --to-ram) shift ;;
        --yes) YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "live-ram: unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -n "$DISK" ] || { echo "live-ram: --disk is required" >&2; usage 1; }
[ -n "$ISO" ] || { echo "live-ram: --iso is required" >&2; usage 1; }
[ -b "$DISK" ] || { echo "live-ram: $DISK is not a block device" >&2; exit 1; }
[ -f "$ISO" ] || { echo "live-ram: missing ISO $ISO" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "live-ram: run as root (sudo)" >&2; exit 1; }

ISO=$(realpath -e "$ISO")
[ -z "$VIRTIO" ] || VIRTIO=$(realpath -e "$VIRTIO")
[ -z "$DRIVERS" ] || DRIVERS=$(realpath -e "$DRIVERS")

dev_of() { findmnt -no SOURCE --target "$1" 2>/dev/null || true; }
on_target() {
    local d
    d=$(dev_of "$1")
    [ -n "$d" ] && [[ "$d" == "$DISK"* ]]
}

# With --reuse-ubuntu nothing on the disk is destroyed, so the ISO can stay
# where it is and no RAM copy is needed.
if [ "$REUSE_UBUNTU" = 1 ]; then
    echo "live-ram: --reuse-ubuntu keeps p2, so the ISO is used in place"
fi

# --- does this environment depend on the disk we are about to wipe? ------
ram_loop() {
    losetup -a 2>/dev/null | sed -n 's|.*(\(.*\)).*|\1|p' |
        grep -E "^($RAMDIR|/run|/tmp|/cow)/" || true
}

if [ "$REUSE_UBUNTU" != 1 ]; then
    LIVE_ON_DISK=0
    on_target / && LIVE_ON_DISK=1
    for _d in /run/live/medium /cdrom; do
        [ -d "$_d" ] && on_target "$_d" && LIVE_ON_DISK=1
    done
    on_target "$ISO" && LIVE_ON_DISK=1
    [ -n "$VIRTIO" ] && [ -f "$VIRTIO" ] && on_target "$VIRTIO" && LIVE_ON_DISK=1

    if [ "$LIVE_ON_DISK" = 1 ]; then
        RAM_LOOP=$(ram_loop)
        if [ -z "$RAM_LOOP" ]; then
            cat >&2 <<EOF
live-ram: this environment still depends on $DISK.
  Either an installed Ubuntu is running from it, or a live ISO on it was
  booted without 'toram'.  Wiping $DISK would kill the build halfway.
  Use --reuse-ubuntu to keep an installed Ubuntu, or boot the live ISO
  with 'toram' (scripts/prepare.sh) and try again.
EOF
            exit 1
        fi
        echo "live-ram: toram confirmed ($RAM_LOOP)"
    fi
fi

# --- RAM budget ----------------------------------------------------------
ISO_MB=$(( $(stat -c %s "$ISO") / 1024 / 1024 ))
NEED_MB=$ISO_MB
VIRTIO_MB=0
if [ "$REUSE_UBUNTU" != 1 ] && [ -n "$VIRTIO" ] && [ -f "$VIRTIO" ] && on_target "$VIRTIO"; then
    VIRTIO_MB=$(( $(stat -c %s "$VIRTIO") / 1024 / 1024 ))
    NEED_MB=$(( NEED_MB + VIRTIO_MB ))
fi
if [ "$REUSE_UBUNTU" != 1 ] && [ -n "$DRIVERS" ] && [ -d "$DRIVERS" ] && on_target "$DRIVERS"; then
    D_MB=$(du -sm "$DRIVERS" | awk '{print $1}')
    NEED_MB=$(( NEED_MB + D_MB ))
fi
AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
SHM_AVAIL_MB=$(( $(df -Pm "$RAMDIR" | awk 'NR==2{print $4}') ))
echo "live-ram: ISO ${ISO_MB} MiB, virtio ${VIRTIO_MB} MiB, copy ${NEED_MB} MiB"
echo "live-ram: MemAvailable ${AVAIL_MB} MiB, $RAMDIR free ${SHM_AVAIL_MB} MiB"

if [ "$NEED_MB" -gt 0 ]; then
    if [ "$SHM_AVAIL_MB" -lt $(( NEED_MB + MIN_FREE_MB )) ]; then
        echo "live-ram: $RAMDIR is too small for the copy." >&2
        echo "  enlarge it: mount -o remount,size=10G $RAMDIR" >&2
        exit 1
    fi
    if [ "$AVAIL_MB" -lt $(( NEED_MB + MEM + MIN_FREE_MB )) ]; then
        echo "live-ram: not enough RAM: need ${NEED_MB} + ${MEM} + ${MIN_FREE_MB} MiB" >&2
        echo "  free ${AVAIL_MB} MiB.  Lower --mem (4096 works for Windows 11)." >&2
        exit 1
    fi
fi

# --- copy the media into tmpfs -------------------------------------------
ISO_RAM=$ISO
if [ "$REUSE_UBUNTU" != 1 ] && on_target "$ISO"; then
    ISO_RAM="$RAMDIR/$(basename "$ISO")"
    echo "live-ram: copying the Windows ISO to $ISO_RAM (this takes a few minutes)"
    cp "$ISO" "$ISO_RAM"
    sync
    [ "$(stat -c %s "$ISO")" = "$(stat -c %s "$ISO_RAM")" ] || {
        echo "live-ram: copy size mismatch" >&2; exit 1; }
    echo "live-ram: copied $(stat -c %s "$ISO_RAM") bytes"
fi

VIRTIO_RAM=$VIRTIO
if [ "$REUSE_UBUNTU" != 1 ] && [ -n "$VIRTIO" ] && [ -f "$VIRTIO" ] && on_target "$VIRTIO"; then
    VIRTIO_RAM="$RAMDIR/$(basename "$VIRTIO")"
    echo "live-ram: copying virtio-win to $VIRTIO_RAM"
    cp "$VIRTIO" "$VIRTIO_RAM"
    sync
fi

DRIVERS_RAM=$DRIVERS
if [ "$REUSE_UBUNTU" != 1 ] && [ -n "$DRIVERS" ] && [ -d "$DRIVERS" ] && on_target "$DRIVERS"; then
    DRIVERS_RAM="$RAMDIR/$(basename "$DRIVERS")"
    echo "live-ram: copying drivers to $DRIVERS_RAM"
    rm -rf "$DRIVERS_RAM"
    cp -a "$DRIVERS" "$DRIVERS_RAM"
fi

# --- release the target disk ---------------------------------------------
if [ "$REUSE_UBUNTU" = 1 ]; then
    # p2 is the running root and must stay mounted; --reuse-ubuntu only
    # touches the free space and the ESP.
    echo "live-ram: --reuse-ubuntu keeps $DISK mounted; nothing is released"
else
    mapfile -t MOUNTS < <(lsblk -lnpo MOUNTPOINT "$DISK" | sed '/^$/d' | sort -r)
    for mp in "${MOUNTS[@]}"; do
        echo "live-ram: umount $mp"
        umount "$mp" || umount -l "$mp" || true
    done
    if [ -n "$(lsblk -no MOUNTPOINT "$DISK" | tr -d ' ')" ]; then
        echo "live-ram: $DISK still has mounted partitions:" >&2
        lsblk -o NAME,SIZE,MOUNTPOINT "$DISK" >&2
        exit 1
    fi
    swapoff -a 2>/dev/null || true
    sync
fi

AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
echo "live-ram: after the copy, MemAvailable ${AVAIL_MB} MiB"
if [ "$AVAIL_MB" -lt $(( MEM + MIN_FREE_MB )) ]; then
    echo "live-ram: WARN: little headroom left.  If QEMU is killed, lower --mem." >&2
fi

# --- hand over -----------------------------------------------------------
ARGS=(--disk "$DISK" --iso "$ISO_RAM" --mem "$MEM" --smp "$SMP"
      --image-index "$IMAGE_INDEX")
[ -n "$VIRTIO_RAM" ] && ARGS+=(--virtio "$VIRTIO_RAM")
[ -n "$DRIVERS_RAM" ] && ARGS+=(--drivers "$DRIVERS_RAM")
[ "$KEEP_UBUNTU" = 1 ] && ARGS+=(--keep-ubuntu --ubuntu-size "$RECOVERY_SIZE")
[ "$REUSE_UBUNTU" = 1 ] && ARGS+=(--reuse-ubuntu)
[ "$YES" = 1 ] && ARGS+=(--yes)

echo "live-ram: running scripts/build.sh ${ARGS[*]}"
exec "$HERE/../scripts/build.sh" "${ARGS[@]}"
