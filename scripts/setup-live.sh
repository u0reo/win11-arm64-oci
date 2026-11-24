#!/usr/bin/env bash
# Minimal preparation for a RAM-only (toram) build host.
#
# setup.sh installs a superset for CI, packaging and optional features
# (rclone, age, jq, shellcheck, libxml2-utils, debootstrap, ...).  None of
# those are used by build.sh.  This script installs only what the build and
# preflight actually need, works around the broken file:/cdrom apt source,
# and puts the media/staging directories on the tmpfs.
#
#   sudo ./scripts/setup-live.sh                 # install + check
#   ./scripts/setup-live.sh --check              # check only, changes nothing
#   sudo ./scripts/setup-live.sh --shm-size 16G  # override tmpfs size
#
# It is idempotent.  --check never remounts or installs anything.
# SHM_SIZE (default 100%) and BUILD_DIR are honoured.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../internal/live.sh
. "$HERE/../internal/live.sh"
# shellcheck source=../internal/apt.sh
. "$HERE/../internal/apt.sh"

SHM_SIZE=${SHM_SIZE:-100%}
CHECK=0

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        --shm-size) SHM_SIZE=${2:?--shm-size needs a size}; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "setup-live: unknown argument: $1" >&2; usage 1 ;;
    esac
done

valid_shm_size "$SHM_SIZE" || {
    echo "setup-live: --shm-size must be 100%, 16G, 1024, ..." >&2
    exit 1
}

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo -n"
    if ! $SUDO true 2>/dev/null; then
        echo "setup-live: passwordless sudo is required" >&2
        exit 1
    fi
fi

# shellcheck disable=SC1091
. /etc/os-release
echo "== system =="
echo "  $PRETTY_NAME ($(uname -m))"

echo "== live (toram) =="
if is_live_ram; then
    if [ "$CHECK" = 1 ]; then
        echo "  /dev/shm: $(df -h /dev/shm | awk 'NR == 2 { print $2 }')" \
            "(target $SHM_SIZE; check only)"
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
    echo "  tip: boot the live ISO with 'toram' before building"
fi

# Only the tools referenced by build.sh / pipeline/*.sh / preflight.sh.
PKGS=(
    qemu-system-arm qemu-utils qemu-efi-aarch64
    wimtools xorriso gdisk dosfstools ntfs-3g mtools parted zstd
    python3-hivex python3-pefile python3-winrm python3-requests-ntlm
    curl
)

if [ "$CHECK" = 1 ]; then
    echo "== packages (check only) =="
    MISSING=0
    for spec in "${PKGS[@]}"; do
        # map package names to the binary preflight checks
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
    [ "$MISSING" -eq 0 ] || echo "  $MISSING item(s) missing; run: sudo $0"
else
    echo "== packages =="
    $SUDO bash "$HERE/../internal/apt.sh" disable_cdrom_source
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
    echo "  installed/verified ${#PKGS[@]} package(s)"
fi

echo
PREFLIGHT_ENV=(TARGET_MODE=raw SHM_SIZE="$SHM_SIZE")
[ -n "${BUILD_DIR:-}" ] && PREFLIGHT_ENV+=(BUILD_DIR="$BUILD_DIR")
env "${PREFLIGHT_ENV[@]}" "$HERE/../internal/preflight.sh" || {
    echo "setup-live: preflight failed; fix the items above" >&2
    exit 1
}

cat <<EOF

setup-live: OK
next: put the Windows ISO in /dev/shm/iso (or /srv/iso before the reboot), then

  sudo ./scripts/build.sh --disk /dev/sda \\
    --iso /dev/shm/iso/Win11_ARM64_26H2.iso \\
    --virtio /dev/shm/iso/virtio-win.iso --yes
EOF
