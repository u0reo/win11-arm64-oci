#!/usr/bin/env bash
# Prepare an Ubuntu 24.04/26.04 ARM64 host (for example an OCI Ampere A1
# instance) and check that it can build the Windows 11 ARM64 disk.
#
#   sudo ./scripts/setup.sh                  # install packages, then check
#   ./scripts/setup.sh --check               # check only, changes nothing
#   ./scripts/setup.sh --check --disk /dev/sdb
#   ./scripts/setup.sh --check --image build/win11-arm64.qcow2
#
# It is idempotent: running it twice only re-checks the packages.
#
# The default is a direct write (build.sh --disk): only the staging files
# (boot.wim, bootfat.img, OEMDRV) go in the build directory, so 8 GiB is
# enough.  A qcow2 build (--image) keeps the whole disk in a file and needs
# 80 GiB.  --build-dir moves the staging directory; --min-free-gb overrides
# the requirement.
#
# On the live ISO booted with `toram`, /dev/shm is remounted at SHM_SIZE
# (default 100% of RAM), staging defaults to /dev/shm/build and /dev/shm/iso
# is created for the Windows ISO and virtio-win.  --check never remounts.
# --shm-size SIZE or SHM_SIZE=SIZE accepts 100%, 16G, 1024, ...
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../internal/live.sh
. "$HERE/../internal/live.sh"

MODE=raw
TARGET=""
BUILD_DIR=${BUILD_DIR:-}
MIN_FREE_GB=${MIN_FREE_GB:-}
SHM_SIZE=${SHM_SIZE:-100%}
CHECK=0
LIVE=0

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        --disk) MODE=raw; TARGET=${2:?--disk needs a device}; shift 2 ;;
        --image) MODE=qcow2; TARGET=${2:?--image needs a path}; shift 2 ;;
        --build-dir) BUILD_DIR=${2:?--build-dir needs a path}; shift 2 ;;
        --min-free-gb) MIN_FREE_GB=${2:?--min-free-gb needs a number}; shift 2 ;;
        --shm-size) SHM_SIZE=${2:?--shm-size needs a size}; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "setup: unknown argument: $1" >&2; usage 1 ;;
    esac
done

valid_shm_size "$SHM_SIZE" || {
    echo "setup: --shm-size must be 100%, 16G, 1024, ..." >&2
    exit 1
}

if is_live_ram; then
    LIVE=1
    [ -n "$BUILD_DIR" ] || BUILD_DIR=/dev/shm/build
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo -n"
    if ! $SUDO true 2>/dev/null; then
        echo "setup: passwordless sudo is required" >&2
        exit 1
    fi
fi

echo "== system =="
# shellcheck disable=SC1091
. /etc/os-release
echo "  $PRETTY_NAME ($(uname -m))"
if [ "$(uname -m)" != "aarch64" ]; then
    echo "  note: this is not aarch64; the guest still runs under TCG"
fi

echo "== live (toram) =="
if [ "$LIVE" = 1 ]; then
    if [ "$CHECK" = 1 ]; then
        echo "  /dev/shm: $(df -h /dev/shm | awk 'NR == 2 { print $2 }')" \
            "(target $SHM_SIZE; check only, not remounted)"
        shm_meets || echo "  run without --check to remount at $SHM_SIZE"
        echo "  staging would be $BUILD_DIR; media in /dev/shm/iso"
    else
        if live_shm_max; then
            echo "  /dev/shm: $(df -h /dev/shm | awk 'NR == 2 { print $2 }')" \
                "(target $SHM_SIZE)"
            $SUDO install -d -m 1777 /dev/shm/iso /dev/shm/build
            echo "  media:   /dev/shm/iso"
            echo "  staging: $BUILD_DIR"
        else
            echo "  warn: could not remount /dev/shm at $SHM_SIZE" >&2
            echo "  run: sudo mount -o remount,size=$SHM_SIZE /dev/shm" >&2
        fi
    fi
else
    echo "  not live (toram); /dev/shm is left unchanged"
fi

if [ "$CHECK" = 0 ]; then
    echo "== packages =="
    PKGS=(
        qemu-system-arm qemu-utils qemu-efi-aarch64
        wimtools libhivex-bin python3-hivex python3-pefile
        mtools dosfstools ntfs-3g xorriso gdisk zstd
        debootstrap parted e2fsprogs
        curl rclone age jq
        libxml2-utils shellcheck
        cpio rpm2cpio
    )
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
    echo "  installed ${#PKGS[@]} package(s)"
fi

echo "== virtualisation =="
if [ -e /dev/kvm ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo "  /dev/kvm: usable -> QEMU will use KVM (fast)"
    else
        echo "  /dev/kvm: present but not writable by $(id -un)"
        echo "  fix: sudo usermod -aG kvm $(id -un) && re-login"
    fi
else
    echo "  /dev/kvm: absent -> QEMU will use TCG (slow, hours)"
    echo "  A1 may not expose nested virtualisation; the build still works."
fi

echo
PREFLIGHT_ENV=(TARGET_MODE="$MODE" SHM_SIZE="$SHM_SIZE")
[ -n "$TARGET" ] && PREFLIGHT_ENV+=(TARGET="$TARGET")
[ -n "$BUILD_DIR" ] && PREFLIGHT_ENV+=(BUILD_DIR="$BUILD_DIR")
[ -n "$MIN_FREE_GB" ] && PREFLIGHT_ENV+=(MIN_FREE_GB="$MIN_FREE_GB")
env "${PREFLIGHT_ENV[@]}" "$HERE/../internal/preflight.sh" || {
    echo "setup: the host check failed; fix the items above and re-run" >&2
    exit 1
}

if [ "$LIVE" = 1 ]; then
    MEDIA_DIR=/dev/shm/iso
else
    MEDIA_DIR=/path/to
fi

cat <<EOF

setup: OK
next: put the Windows ISO in $MEDIA_DIR, then
EOF
if [ "$MODE" = qcow2 ]; then
    cat <<EOF

  sudo ./scripts/build.sh --image ${TARGET:-build/win11-arm64.qcow2} \\
    --iso $MEDIA_DIR/Win11_ARM64_26H2.iso \\
    --virtio $MEDIA_DIR/virtio-win.iso --yes
EOF
else
    cat <<EOF

  sudo ./scripts/build.sh --disk ${TARGET:-/dev/sdb} \\
    --iso $MEDIA_DIR/Win11_ARM64_26H2.iso \\
    --virtio $MEDIA_DIR/virtio-win.iso --yes
EOF
fi
if [ "$LIVE" = 1 ]; then
    cat <<EOF

live (toram): /dev/shm is the recommended place for the media.
  media:   $MEDIA_DIR
  staging: ${BUILD_DIR:-/dev/shm/build}
EOF
fi
cat <<EOF

--virtio accepts virtio-win.iso or virtio-win-*.noarch.rpm.

Need the Ubuntu or virtio-win ISO?  See stage 1 in README.md.

Building method B (live ISO in RAM)?  See docs/OCI.md.
EOF
