#!/usr/bin/env bash
# Prepare an Ubuntu 22.04/24.04 ARM64 host (for example an OCI Ampere A1
# instance) for building the Windows 11 ARM64 image.
#
#   ./scripts/bootstrap-ubuntu.sh
#
# It is idempotent: running it twice only re-checks the packages.
set -euo pipefail

MIN_FREE_GB=${MIN_FREE_GB:-100}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo -n"
    if ! $SUDO true 2>/dev/null; then
        echo "bootstrap: passwordless sudo is required" >&2
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

echo "== packages =="
PKGS=(
    qemu-system-arm qemu-utils qemu-efi-aarch64
    wimtools libhivex-bin python3-hivex python3-pefile
    mtools dosfstools ntfs-3g xorriso gdisk zstd
    curl rclone oathtool age jq
    libxml2-utils shellcheck
)
$SUDO apt-get update -qq
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
echo "  installed ${#PKGS[@]} package(s)"

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

echo "== disk =="
mkdir -p "$ROOT/build"
FREE_GB=$(df -Pk "$ROOT/build" | awk 'NR==2 {printf "%d", $4/1024/1024}')
echo "  $ROOT/build: ${FREE_GB} GiB free (need >= ${MIN_FREE_GB} GiB)"
if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
    echo "  ERROR: enlarge the boot volume or attach a block volume." >&2
    echo "  OCI: 100 GB boot volume is enough; Always Free allows 200 GB total." >&2
    exit 1
fi

echo "== firmware =="
FW_CODE=${FW_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
FW_VARS=${FW_VARS_SRC:-/usr/share/AAVMF/AAVMF_VARS.fd}
for f in "$FW_CODE" "$FW_VARS"; do
    [ -f "$f" ] && echo "  ok $f" || { echo "  MISSING $f" >&2; exit 1; }
done

echo "== oci cli =="
if command -v oci >/dev/null 2>&1; then
    echo "  $(oci --version 2>/dev/null || echo 'oci present')"
else
    echo "  not installed (only needed for --deliver image)"
    echo "  install: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm"
fi

echo
echo "bootstrap: OK"
echo "next: put the Windows ISO on the host, then"
echo "  sudo ./scripts/oci-run.sh --iso /path/to/Win11_ARM64_26H2.iso --deliver ssh"
