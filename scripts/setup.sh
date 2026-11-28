#!/usr/bin/env bash
# Prepare the build host and check that build.sh can run.
#
#   sudo ./scripts/setup.sh                 # install packages, then check
#   sudo ./scripts/setup.sh --live          # same, for a live (toram) build
#   ./scripts/setup.sh --check              # check only, changes nothing
#   ./scripts/setup.sh --check --disk /dev/sdb
#   ./scripts/setup.sh --check --image build/win11-arm64.qcow2
#   sudo ./scripts/setup.sh --shm-size 16G
#
# One script for stage 2-A and 2-B.  --live only changes the target/media
# assumptions; a live (toram) session is detected automatically.
#
# Only the 16 packages that build.sh and preflight.sh actually use are
# installed.  CI/packaging tools (rclone, age, jq, shellcheck,
# libxml2-utils, debootstrap, ...) are not needed to build an image; the
# workflows install their own.  rpm2cpio/cpio are optional (RPM virtio-win
# only) -- install them by hand if needed.
#
# Idempotent.  --check never installs packages or remounts /dev/shm.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../internal/live.sh
. "$HERE/../internal/live.sh"
# shellcheck source=../internal/apt.sh
. "$HERE/../internal/apt.sh"

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
        --live) LIVE=1; MODE=raw; shift ;;
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

# shellcheck disable=SC1091
. /etc/os-release
echo "== system =="
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
        echo "  media:   /dev/shm/iso"
        echo "  staging: ${BUILD_DIR:-/dev/shm/build}"
    else
        live_shm_max "$SHM_SIZE"
        $SUDO install -d -m 1777 /dev/shm/iso /dev/shm/build
        echo "  /dev/shm: $(df -h /dev/shm | awk 'NR == 2 { print $2 }')"
        echo "  media:   /dev/shm/iso"
        echo "  staging: ${BUILD_DIR:-/dev/shm/build}"
    fi
else
    echo "  not live (toram); /dev/shm is left unchanged"
fi

# Only the tools referenced by build.sh / pipeline/*.sh / preflight.sh.
PKGS=(
    qemu-system-arm qemu-utils qemu-efi-aarch64
    wimtools xorriso gdisk dosfstools ntfs-3g mtools parted zstd
    python3-hivex python3-pefile python3-winrm python3-requests-ntlm
    curl
)

check_packages() {
    echo "== packages =="
    MISSING=0
    for spec in "${PKGS[@]}"; do
        case "$spec" in
            qemu-system-arm) bins=(qemu-system-aarch64) ;;
            qemu-utils) bins=(qemu-img qemu-nbd) ;;
            wimtools) bins=(wimlib-imagex) ;;
            gdisk) bins=(sgdisk) ;;
            dosfstools) bins=(mkfs.vfat fatlabel) ;;
            ntfs-3g) bins=(mkntfs ntfsfix) ;;
            mtools) bins=(mcopy) ;;
            parted) bins=(partprobe) ;;
            python3-requests-ntlm) bins=(requests_ntlm) ;;
            python3-hivex|python3-pefile|python3-winrm|curl) bins=("$spec") ;;
            *) bins=("$spec") ;;
        esac
        for b in "${bins[@]}"; do
            found=0
            command -v "$b" >/dev/null 2>&1 && found=1
            python3 -c "import ${b#python3-}" 2>/dev/null && found=1
            # qemu-efi-aarch64 is data, not a binary: check the firmware file.
            [ "$b" = qemu-efi-aarch64 ] &&
                [ -f /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd ] && found=1
            if [ "$found" = 1 ]; then
                printf '  ok    %s\n' "$b"
            else
                printf '  no    %s (%s)\n' "$b" "$spec"
                MISSING=$(( MISSING + 1 ))
            fi
        done
    done
    [ "$MISSING" -eq 0 ] ||
        echo "  $MISSING item(s) missing; run: sudo $0"
}

if [ "$CHECK" = 1 ]; then
    check_packages
else
    echo "== install =="
    $SUDO bash "$HERE/../internal/apt.sh" disable_cdrom_source
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
    echo "  installed/verified ${#PKGS[@]} package(s)"
    check_packages
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

echo
echo "setup: OK"
