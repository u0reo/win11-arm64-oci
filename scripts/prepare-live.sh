#!/usr/bin/env bash
# Prepare the next boot to run an Ubuntu live ISO from RAM (toram) on the
# recovery Ubuntu installed on this disk.
#
# Why not `scripts/prepare.sh --write --once`?  That script relies on
# /etc/grub.d/40_custom, update-grub and grub-reboot.  The recovery Ubuntu
# has none of them, and the GRUB that actually runs reads \EFI\ubuntu\grub.cfg
# on the ESP.  This script writes the seed via prepare.sh --seed-only and
# then regenerates the ESP's own menu with write_grub_menu.py.
#
#   sudo ./scripts/prepare-live.sh [ISO] [--timeout SECONDS] [--no-first-boot]
#
# Defaults:
#   ISO       /srv/iso/ubuntu-26.04.1-live-server-arm64.iso
#   ESP       /boot/efi
#   ROOT      the device mounted at / (for the Ubuntu recovery entry)
#
# The ESP is relabelled CIDATA so cloud-init can find user-data/meta-data.
# Restore the label later with: sudo fatlabel /dev/sda1 SYSTEM
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ESP=${ESP:-/boot/efi}
ISO=${1:-/srv/iso/ubuntu-26.04.1-live-server-arm64.iso}
TIMEOUT=30
FIRST_BOOT=1

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[ -n "$ISO" ] || usage 1
case "$ISO" in -h|--help) usage 0 ;; esac
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT=${2:?--timeout needs seconds}; shift 2 ;;
        --no-first-boot) FIRST_BOOT=0; shift ;;
        -h|--help) usage 0 ;;
        *) echo "prepare-live: unknown argument: $1" >&2; usage 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo -n"
fi
$SUDO true || { echo "prepare-live: passwordless sudo is required" >&2; exit 1; }

[ -f "$ISO" ] || { echo "prepare-live: missing $ISO" >&2; exit 1; }
ISO=$(realpath -e "$ISO")
[ -d "$ESP/EFI/ubuntu" ] || { echo "prepare-live: $ESP is not the ESP" >&2; exit 1; }
command -v fatlabel >/dev/null 2>&1 || {
    echo "prepare-live: fatlabel is missing (dosfstools)" >&2
    echo "  run: sudo ./scripts/setup-live.sh" >&2
    exit 1
}
ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
[ -n "$ROOTDEV" ] || { echo "prepare-live: cannot find the root device" >&2; exit 1; }

echo "== cloud-init seed (ESP -> CIDATA) =="
"$HERE/prepare.sh" "$ISO" --write --ssh --seed-only

echo "== ESP GRUB menu =="
CMD=(python3 "$HERE/../pipeline/write_grub_menu.py" "$ESP" / "$ROOTDEV"
     --timeout "$TIMEOUT" --live-iso "$ISO" --live-seed)
[ "$FIRST_BOOT" = 1 ] && CMD+=(--first-boot-live)
$SUDO "${CMD[@]}"

echo
echo "prepare-live: reboot to boot '$ISO' with toram."
if [ "$FIRST_BOOT" = 1 ]; then
    echo "  next_entry is set; after that boot the menu returns to Windows 11."
fi
echo "  restore the ESP label later with: sudo fatlabel $ESP SYSTEM"
