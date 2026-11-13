#!/usr/bin/env bash
# Prepare an Ubuntu 24.04/26.04 ARM64 host (for example an OCI Ampere A1
# instance) and check that it can build the Windows 11 ARM64 disk.
#
#   sudo ./scripts/setup.sh            # install packages, then check
#   ./scripts/setup.sh --check         # check only, changes nothing
#
# It is idempotent: running it twice only re-checks the packages.
#
# MIN_FREE_GB (default 20) is the space the check requires.  A direct write
# to a block device needs about 20 GiB for temporary files; a qcow2 build
# needs 80 GiB, so use MIN_FREE_GB=80 for that.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MIN_FREE_GB=${MIN_FREE_GB:-20}
CHECK=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "setup: unknown argument: $1" >&2; usage 1 ;;
    esac
done

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

if [ "$CHECK" = 0 ]; then
    echo "== packages =="
    PKGS=(
        qemu-system-arm qemu-utils qemu-efi-aarch64
        wimtools libhivex-bin python3-hivex python3-pefile
        mtools dosfstools ntfs-3g xorriso gdisk zstd
        debootstrap parted e2fsprogs
        curl rclone age jq
        libxml2-utils shellcheck
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
MIN_FREE_GB="$MIN_FREE_GB" "$HERE/../internal/preflight.sh" || {
    echo "setup: the host check failed; fix the items above and re-run" >&2
    exit 1
}

cat <<EOF

setup: OK
next: put the Windows ISO on the host, then

  sudo ./scripts/build.sh --disk /dev/sdb \\
    --iso /path/to/Win11_ARM64_26H2.iso --virtio /path/to/virtio-win.iso --yes

Need the ISO downloaded first?

  ./scripts/build.sh --fetch-iso https://host/Win11.iso build/iso/Win11.iso

Building method B (live ISO in RAM)?  See docs/OCI.md.
EOF
