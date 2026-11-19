#!/usr/bin/env bash
# Build the Windows 11 ARM64 disk: a block device (--disk) or a qcow2 (--image).
#
#   sudo ./scripts/build.sh --disk /dev/sdb \
#     --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
#     --virtio /dev/shm/iso/virtio-win.iso --yes
#
#   sudo ./scripts/build.sh --image build/win11-arm64.qcow2 \
#     --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
#     --virtio /dev/shm/iso/virtio-win.iso --yes
#
# --virtio accepts virtio-win.iso or virtio-win-*.noarch.rpm.  The RPM is about
# a third of the size and is read without mounting (rpm2cpio + cpio).
#
# Add --fresh-ubuntu to build a small Ubuntu recovery system on an empty (or
# disposable) disk: p1=ESP (100 MiB), p2=Ubuntu (RECOVERY_SIZE, default 4G)
# and p3=Windows (the rest).  Nothing from the old disk is reused, not even
# the ESP.  When a saved netplan/SSH configuration exists in the staging
# directory it is reused; otherwise the recovery system starts with defaults.
#
# Add --keep-ubuntu to keep the existing ESP on a disk that already has an
# Ubuntu install (ESP shim/GRUB boots first, and its menu chainloads
# Windows).  The old Ubuntu root is replaced by a fresh minimal install; its
# netplan and SSH settings are copied over.
# The ESP is found by GPT type, so the OCI ARM64 layout (p1=root, p13=BOOT,
# p15=ESP) works as well as the older p1=ESP, p2=ubuntu layout.
#
# Add --reuse-ubuntu instead when you already installed a small Ubuntu on
# partition 2 and booted it: partition 2 is left alone and only the free
# space is used for Windows.  This is the only mode that tolerates the
# target disk being the running root, because nothing on p2 is written.
#
# ARM64 Windows does not implement EMS/SAC: bcdedit accepts the commands but
# writes nothing.  Use RDP or WinRM for Windows recovery.
#
# Add --boot-menu SECONDS to show the boot menu (serial and VNC) for that
# many seconds.  With a recovery Ubuntu this is the GRUB menu; otherwise it
# is the Windows Boot Manager menu.  The default is 1; any key press stops
# the countdown.  --boot-menu 0 turns the menu off (rejected when a recovery
# Ubuntu is included).
#
# If a build stopped after the disk was repartitioned, set FROM_STEP=7 (or 6
# for just the recovery Ubuntu) to resume without running host_apply.sh:
#
#   sudo env FROM_STEP=7 ./scripts/build.sh ... --yes
#
# Pass the same --fresh-ubuntu / --keep-ubuntu flags you started with.
#
# The target must not be the running root (except with --reuse-ubuntu).  Boot
# the Ubuntu live ISO with `toram` first (scripts/prepare.sh).  Media that
# still lives on the target disk is copied into RAM before anything is
# written, so the ISO may sit on the disk that is about to be wiped.
#
# On live (toram), /dev/shm is remounted at SHM_SIZE (default 100% of RAM),
# BUILD_DIR defaults to /dev/shm/build and the ISO/virtio-win belong in
# /dev/shm/iso.  That keeps the media and staging out of the overlay's
# RAM-backed copy-on-write layer.  --shm-size SIZE overrides SHM_SIZE.
#
# Nothing is packaged and nothing is uploaded: the target itself becomes the
# Windows disk.  On OCI, detach the volume and reattach it as the boot volume
# of the target instance afterwards.
#
# WARNING: take a boot volume backup first.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../internal/live.sh
. "$HERE/../internal/live.sh"

DISK=""
IMG=""
FILE_TARGET=0
SIZE=${SIZE:-50G}
ISO=""
VIRTIO=""
VIRTIO_KIND=""
DRIVERS=""
IMAGE_INDEX=${IMAGE_INDEX:-1}
MEM=${MEM:-6144}
SMP=${SMP:-4}
KEEP_UBUNTU=0
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
FRESH_UBUNTU=${FRESH_UBUNTU:-0}
UBUNTU_SIZE_SET=0
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}
BOOT_MENU=${BOOT_MENU_TIMEOUT:-}
FROM_STEP=${FROM_STEP:-0}
BUILD_DIR=${BUILD_DIR:-}
MIN_FREE_GB=${MIN_FREE_GB:-}
SHM_SIZE=${SHM_SIZE:-100%}
LIVE=0
YES=0

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk) DISK=$2; shift 2 ;;
        --image) IMG=$2; shift 2 ;;
        --size) SIZE=$2; shift 2 ;;
        --iso) ISO=$2; shift 2 ;;
        --virtio) VIRTIO=$2; shift 2 ;;
        --drivers) DRIVERS=$2; shift 2 ;;
        --image-index) IMAGE_INDEX=$2; shift 2 ;;
        --mem) MEM=$2; shift 2 ;;
        --smp) SMP=$2; shift 2 ;;
        --build-dir) BUILD_DIR=$2; shift 2 ;;
        --min-free-gb) MIN_FREE_GB=$2; shift 2 ;;
        --shm-size) SHM_SIZE=$2; shift 2 ;;
        --keep-ubuntu) KEEP_UBUNTU=1; shift ;;
        --fresh-ubuntu) FRESH_UBUNTU=1; shift ;;
        --ubuntu-size) RECOVERY_SIZE=$2; UBUNTU_SIZE_SET=1; shift 2 ;;
        --reuse-ubuntu) REUSE_UBUNTU=1; shift ;;
        --boot-menu) BOOT_MENU=$2; shift 2 ;;
        --to-ram)
            echo "build: --to-ram is gone; it is detected automatically." >&2
            echo "  boot the live ISO with 'toram' (scripts/prepare.sh) and" >&2
            echo "  run build.sh without --to-ram" >&2
            exit 1 ;;
        --yes) YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "build: unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --ubuntu-size alone keeps the old meaning: resize the kept recovery system.
# With --fresh-ubuntu it only changes the new partition's size.
if [ "$UBUNTU_SIZE_SET" = 1 ] &&
   [ "$KEEP_UBUNTU" != 1 ] && [ "$FRESH_UBUNTU" != 1 ]; then
    KEEP_UBUNTU=1
fi
if [ "$FRESH_UBUNTU" = 1 ] && [ "$KEEP_UBUNTU" = 1 ]; then
    echo "build: --fresh-ubuntu and --keep-ubuntu are mutually exclusive" >&2
    exit 1
fi

valid_shm_size "$SHM_SIZE" || {
    echo "build: --shm-size must be 100%, 16G, 1024, ..." >&2
    exit 1
}

if is_live_ram; then
    LIVE=1
    [ -n "$BUILD_DIR" ] || BUILD_DIR=/dev/shm/build
fi

if [ -z "$BOOT_MENU" ]; then
    BOOT_MENU=1
fi
case "$BOOT_MENU" in
    ''|*[!0-9]*)
        echo "build: --boot-menu needs a number of seconds (0-999)" >&2
        exit 1 ;;
esac
BOOT_MENU=$((10#$BOOT_MENU))
if [ "$BOOT_MENU" -gt 999 ]; then
    echo "build: --boot-menu must be 999 seconds or less" >&2
    exit 1
fi
if [ "$BOOT_MENU" -eq 0 ] && { [ "$KEEP_UBUNTU" = 1 ] || [ "$REUSE_UBUNTU" = 1 ] || [ "$FRESH_UBUNTU" = 1 ]; }; then
    echo "build: --boot-menu 0 would hide the Ubuntu recovery entry." >&2
    echo "  Use --boot-menu 1 (or more) with --fresh-ubuntu / --keep-ubuntu / --reuse-ubuntu." >&2
    exit 1
fi
case "$FROM_STEP" in
    ''|*[!0-9]*)
        echo "build: FROM_STEP must be a number between 0 and 13" >&2
        exit 2 ;;
esac
if [ "$FROM_STEP" -gt 13 ]; then
    echo "build: FROM_STEP must be a number between 0 and 13" >&2
    exit 2
fi

if [ -n "$IMG" ] && [ -n "$DISK" ]; then
    echo "build: use either --disk or --image, not both" >&2
    exit 1
fi
if [ -n "$IMG" ]; then
    DISK=$IMG
    FILE_TARGET=1
fi
[ -n "$DISK" ] || { echo "build: --disk or --image is required" >&2; usage 1; }
[ -n "$ISO" ] || { echo "build: --iso is required" >&2; usage 1; }
[ -f "$ISO" ] || { echo "build: missing ISO $ISO" >&2; exit 1; }
[ -n "$DRIVERS" ] || [ -n "$VIRTIO" ] || {
    echo "build: --virtio or --drivers is required" >&2; usage 1; }
if [ "$FILE_TARGET" = 0 ]; then
    [ -b "$DISK" ] || { echo "build: $DISK is not a block device" >&2; exit 1; }
fi
if [ "$FILE_TARGET" = 1 ] && { [ "$KEEP_UBUNTU" = 1 ] || [ "$REUSE_UBUNTU" = 1 ] || [ "$FRESH_UBUNTU" = 1 ]; }; then
    echo "build: --fresh-ubuntu, --keep-ubuntu and --reuse-ubuntu need a block device (--disk)" >&2
    exit 1
fi

ISO=$(realpath -e "$ISO")
if [ -n "$VIRTIO" ]; then
    [ -f "$VIRTIO" ] || { echo "build: missing $VIRTIO" >&2; exit 1; }
    VIRTIO=$(realpath -e "$VIRTIO")
    case "$VIRTIO" in
        *.rpm|*.RPM) VIRTIO_KIND=rpm ;;
        *)           VIRTIO_KIND=iso ;;
    esac
fi
if [ -n "$DRIVERS" ]; then
    [ -e "$DRIVERS" ] || { echo "build: missing $DRIVERS" >&2; exit 1; }
    DRIVERS=$(realpath -e "$DRIVERS")
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "build: run as root (sudo)" >&2
    exit 1
fi

# --- RAM-only live environment -------------------------------------------
if [ "$LIVE" = 1 ]; then
    if live_shm_max; then
        echo "build: /dev/shm $(df -h /dev/shm | awk 'NR == 2 { print $2 }')" \
            "(target $SHM_SIZE)"
        echo "build: staging $BUILD_DIR"
    else
        echo "build: warning: could not remount /dev/shm at $SHM_SIZE" >&2
        echo "  run: sudo mount -o remount,size=$SHM_SIZE /dev/shm" >&2
    fi
fi

# --- safety checks -------------------------------------------------------
RAMDIR=${RAMDIR:-/dev/shm}
MIN_FREE_MB=${MIN_FREE_MB:-2048}

ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_ON_DISK=0
if [ "$FILE_TARGET" = 0 ] && [ -n "$ROOTDEV" ] && [[ "$ROOTDEV" == "$DISK"* ]]; then
    ROOT_ON_DISK=1
fi

on_target() {
    local src
    src=$(findmnt -no SOURCE --target "$1" 2>/dev/null || true)
    [ -n "$src" ] && [[ "$src" == "$DISK"* ]]
}

if [ "$ROOT_ON_DISK" = 1 ] && [ "$REUSE_UBUNTU" != 1 ]; then
    cat >&2 <<EOF
build: $DISK is the running root device.
  Reboot into the Ubuntu live entry with 'toram' (scripts/prepare.sh) and
  run this again, or use --reuse-ubuntu when p2 is a small Ubuntu that must
  survive.  Nothing has been written.
EOF
    exit 1
fi

if [ "$REUSE_UBUNTU" != 1 ] && [ "$FILE_TARGET" = 0 ]; then
    # A live ISO loop whose backing file is on the target means the live
    # system still depends on the disk: it was booted without toram.
    for f in $(losetup -a 2>/dev/null | sed -n 's|.*(\(.*\)).*|\1|p'); do
        [ -e "$f" ] || continue
        if on_target "$f"; then
            echo "build: the live system still reads $f from $DISK" >&2
            echo "  boot the live ISO with 'toram' (scripts/prepare.sh) first" >&2
            exit 1
        fi
    done
fi

if [ "$REUSE_UBUNTU" = 1 ]; then
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
        echo "build: umount these before building:$BUSY" >&2
        lsblk -o NAME,SIZE,MOUNTPOINT "$DISK" >&2
        exit 1
    fi
    echo "build: $DISK is the running disk; only $ROOT_MP stays mounted"
    swapoff -a 2>/dev/null || true
fi

SIZE_TEXT=$SIZE
MODEL=""
SERIAL=""
if [ "$FILE_TARGET" = 0 ]; then
    SIZE_BYTES=$(blockdev --getsize64 "$DISK")
    SIZE_GB=$(( SIZE_BYTES / 1024 / 1024 / 1024 ))
    if [ "$SIZE_GB" -lt 40 ]; then
        echo "build: $DISK is only ${SIZE_GB} GiB; Windows needs at least 40" >&2
        exit 1
    fi
    SIZE_TEXT="${SIZE_GB} GiB"
    MODEL=$(lsblk -dno MODEL "$DISK" 2>/dev/null | sed 's/ *$//' || true)
    SERIAL=$(lsblk -dno SERIAL "$DISK" 2>/dev/null | sed 's/ *$//' || true)
fi

VIRTIO_NOTE=""
if [ "$VIRTIO_KIND" = rpm ]; then
    VIRTIO_NOTE=" (rpm)"
fi

UBUNTU_MODE="no (whole disk Windows)"
if [ "$REUSE_UBUNTU" = 1 ]; then
    UBUNTU_MODE="reuse the installed p2"
elif [ "$KEEP_UBUNTU" = 1 ]; then
    UBUNTU_MODE="keep ${RECOVERY_SIZE} recovery system"
elif [ "$FRESH_UBUNTU" = 1 ]; then
    UBUNTU_MODE="create ${RECOVERY_SIZE} recovery system (fresh disk)"
fi

cat <<EOF

  target   $DISK
  model    ${MODEL:-qcow2 file}
  serial   ${SERIAL:-n/a}
  size     ${SIZE_TEXT}
  iso      $ISO
  drivers  ${DRIVERS:-$VIRTIO}$VIRTIO_NOTE
  staging  ${BUILD_DIR:-auto (build/ or a tmpfs)}
  index    $IMAGE_INDEX
  memory   ${MEM} MiB
  cpus     $SMP
  serial   ttyAMA0 (GRUB/Ubuntu; Windows has no EMS/SAC)
  bootmenu $([ "$BOOT_MENU" = 0 ] && echo 'off' || echo "${BOOT_MENU}s (serial + VNC)")
  ubuntu   $UBUNTU_MODE

EOF

if [ "$REUSE_UBUNTU" = 1 ]; then
    cat <<EOF
  Partition 2 (the running Ubuntu) is NOT touched.  Windows goes into the
  unallocated space as partition 3, and the existing ESP keeps both boot
  loaders.  Nothing outside the free space is written.
  THE FREE SPACE AND THE ESP WILL BE MODIFIED.
EOF
elif [ "$FROM_STEP" -ge 6 ]; then
    cat <<EOF
  Resuming at step ${FROM_STEP}; host_apply.sh (step 5) is skipped.
  The existing partitions, the Windows image and the ESP are left as they
  are.  No partition is created or formatted by this run.
EOF
elif [ "$KEEP_UBUNTU" = 1 ]; then
    cat <<EOF
  The ESP stays.  The old Ubuntu root (and the OCI BOOT partition, if
  present) is replaced by a ${RECOVERY_SIZE} ext4 recovery Ubuntu (fresh
  minimal install) and the rest becomes Windows.  Existing partition
  numbers are not assumed: the ESP is found by its GPT type and the new
  partitions use the next free numbers.  Its netplan and SSH settings are
  copied from the current Ubuntu before it is erased.
  EVERYTHING ELSE ON $DISK WILL BE DESTROYED.
EOF
elif [ "$FRESH_UBUNTU" = 1 ]; then
    cat <<EOF
  The disk is repartitioned from scratch, including a new 100 MiB ESP:
  p1=ESP, p2=${RECOVERY_SIZE} ext4 recovery Ubuntu, p3=Windows (the rest).
  The old partition table is erased.  If a saved netplan/SSH configuration
  already exists in the staging directory it is reused; otherwise the
  recovery Ubuntu starts with defaults.
  ALL DATA ON $DISK WILL BE DESTROYED.
EOF
elif [ "$FILE_TARGET" = 1 ]; then
    cat <<EOF
  $DISK will be created or replaced with a ${SIZE} qcow2.  Nothing outside
  that file is touched.
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

# --- free the target disk ------------------------------------------------
# Media that still lives on the target is copied into RAM first.  This is
# the only reason build.sh needs /dev/shm; if the ISO is already elsewhere
# (a data volume, /dev/shm, the live medium) nothing is copied.
STAGED=""
stage_to_ram() {
    local src=$1 dst
    mkdir -p "$RAMDIR/iso"
    dst="$RAMDIR/iso/$(basename "$src")"
    echo "build: copying $src -> $dst" >&2
    if [ -d "$src" ]; then rm -rf "$dst"; fi
    cp -a "$src" "$dst"
    sync
    if [ -f "$src" ] && [ "$(stat -c %s "$src")" != "$(stat -c %s "$dst")" ]; then
        echo "build: copy size mismatch: $dst" >&2
        exit 1
    fi
    STAGED=$dst
}

if [ "$FILE_TARGET" = 0 ] && [ "$REUSE_UBUNTU" != 1 ]; then
    NEED_COPY=0
    NEED_MB=0
    for _p in "$ISO" "$VIRTIO"; do
        if [ -n "$_p" ] && [ -f "$_p" ] && on_target "$_p"; then
            NEED_COPY=1
            NEED_MB=$(( NEED_MB + $(stat -c %s "$_p") / 1024 / 1024 ))
        fi
    done
    if [ -n "$DRIVERS" ] && [ -e "$DRIVERS" ] && on_target "$DRIVERS"; then
        NEED_COPY=1
        NEED_MB=$(( NEED_MB + $(du -sm "$DRIVERS" | awk '{print $1}') ))
    fi
    if [ "$NEED_COPY" = 1 ]; then
        SHM_AVAIL_MB=$(df -Pm "$RAMDIR" | awk 'NR==2{print $4}')
        AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
        if [ "$SHM_AVAIL_MB" -lt $(( NEED_MB + MIN_FREE_MB )) ]; then
            echo "build: $RAMDIR is too small for the copy." >&2
            echo "  need ${NEED_MB} + ${MIN_FREE_MB} MiB, have ${SHM_AVAIL_MB} MiB" >&2
            echo "  enlarge it: sudo mount -o remount,size=${SHM_SIZE} $RAMDIR" >&2
            exit 1
        fi
        if [ "$AVAIL_MB" -lt $(( NEED_MB + MEM + MIN_FREE_MB )) ]; then
            echo "build: not enough RAM for the media and the guest." >&2
            echo "  need ${NEED_MB} (media) + ${MEM} (guest) + ${MIN_FREE_MB} MiB," >&2
            echo "  ${AVAIL_MB} MiB available.  Lower --mem or free some memory." >&2
            exit 1
        fi
        echo "build: copying ${NEED_MB} MiB of media into $RAMDIR"
        if on_target "$ISO"; then stage_to_ram "$ISO"; ISO=$STAGED; fi
        if [ -n "$VIRTIO" ] && [ -f "$VIRTIO" ] && on_target "$VIRTIO"; then
            stage_to_ram "$VIRTIO"; VIRTIO=$STAGED
        fi
        if [ -n "$DRIVERS" ] && [ -e "$DRIVERS" ] && on_target "$DRIVERS"; then
            stage_to_ram "$DRIVERS"; DRIVERS=$STAGED
        fi
    fi

    while read -r sw; do
        [ -n "$sw" ] || continue
        if [[ "$sw" == "$DISK"* ]] || on_target "$sw"; then
            echo "build: swapoff $sw"
            swapoff "$sw" 2>/dev/null || true
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
    mapfile -t MOUNTS < <(lsblk -lnpo MOUNTPOINT "$DISK" | sed '/^$/d' | sort -r)
    for mp in "${MOUNTS[@]}"; do
        echo "build: umount $mp"
        if ! umount "$mp"; then
            echo "build: cannot unmount $mp; close anything using it" >&2
            echo "  (fuser -vm $mp) and run again.  Nothing has been written." >&2
            exit 1
        fi
    done
    if [ -n "$(lsblk -no MOUNTPOINT "$DISK" | tr -d ' ')" ]; then
        echo "build: $DISK still has mounted partitions:" >&2
        lsblk -o NAME,SIZE,MOUNTPOINT "$DISK" >&2
        exit 1
    fi
fi

# --- build ---------------------------------------------------------------
export DISK
export ISO
export IMAGE_INDEX MEM SMP SIZE
export KEEP_UBUNTU RECOVERY_SIZE REUSE_UBUNTU FRESH_UBUNTU
export BOOT_MENU_TIMEOUT="$BOOT_MENU"
export FROM_STEP
export SHM_SIZE
[ -n "$BUILD_DIR" ] && export BUILD_DIR
[ -n "$MIN_FREE_GB" ] && export MIN_FREE_GB
if [ -n "$DRIVERS" ]; then
    export DRIVERS_DIR="$DRIVERS"
elif [ "$VIRTIO_KIND" = rpm ]; then
    export VIRTIO_RPM="$VIRTIO"
else
    export VIRTIO_ISO="$VIRTIO"
fi

"$HERE/../internal/build-image.sh"

cat <<EOF

== done ==
$DISK now contains Windows 11 ARM64.
EOF

if [ "$KEEP_UBUNTU" = 1 ]; then
    cat <<EOF
The ${RECOVERY_SIZE} recovery Ubuntu is installed on the same disk.  The
GRUB menu shows "Ubuntu (recovery)" next to "Windows 11" (${BOOT_MENU}
second timeout, Windows 11 is the default).
EOF
elif [ "$FRESH_UBUNTU" = 1 ]; then
    cat <<EOF
A new ESP (p1) and a ${RECOVERY_SIZE} recovery Ubuntu (p2) are installed on
the same disk; Windows is p3.  The GRUB menu shows "Ubuntu (recovery)" next
to "Windows 11" (${BOOT_MENU} second timeout, Windows 11 is the default).
EOF
elif [ "$REUSE_UBUNTU" = 1 ]; then
    cat <<EOF
The installed Ubuntu on partition 2 is untouched.  The GRUB menu should
show it as "Ubuntu (recovery)" (${BOOT_MENU} second timeout, Windows 11
is the default).
EOF
fi

if [ "$FILE_TARGET" = 1 ]; then
    cat <<EOF

To test the qcow2 locally:

  BOOT=disk DISK=$DISK pipeline/run-qemu.sh
EOF
else
    cat <<EOF

On OCI (detach/attach method):
  1. stop the builder instance
  2. detach this volume
  3. attach it to the target instance as the BOOT volume
  4. start the target instance and connect with RDP

If this is the live-CD method (you wrote to the disk the live system booted
from), no detach is needed: run 'sudo reboot' and the Windows install starts.
EOF
fi

cat <<EOF

The Windows account and password are the ones rendered into the image
(from WIN_USERNAME / WIN_PASSWORD / COMPUTER_NAME / TIMEZONE).

Serial console: ARM64 Windows does not support EMS/SAC.  Use RDP (3389) or
WinRM (5985) for Windows recovery.  With a recovery Ubuntu the OCI serial
console shows the GRUB menu and the Ubuntu login prompt.
EOF
