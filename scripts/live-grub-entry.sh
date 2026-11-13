#!/usr/bin/env bash
# Print a GRUB menu entry that boots an Ubuntu live ISO with `toram`, which
# is what method B needs before the disk is wiped.
#
#   ./scripts/live-grub-entry.sh /srv/iso/ubuntu-26.04-live-server-arm64.iso
#
# Append the output to /etc/grub.d/40_custom on the instance, then run
# `sudo update-grub`.  The ISO must live on a mounted filesystem (its UUID
# is used to find it again at boot).
set -euo pipefail

ISO=${1:?usage: $0 <live.iso> [--name NAME]}
NAME=${NAME:-Ubuntu live (toram)}
[ -f "$ISO" ] || { echo "grub-entry: missing $ISO" >&2; exit 1; }

ISO=$(realpath -e "$ISO")
MNT=$(findmnt -no TARGET --target "$ISO" 2>/dev/null || true)
UUID=$(findmnt -no UUID --target "$ISO" 2>/dev/null || true)
[ -n "$MNT" ] && [ -n "$UUID" ] || {
    echo "grub-entry: $ISO is not on a mounted filesystem with a UUID" >&2
    exit 1
}
REL=${ISO#"$MNT"}
case "$REL" in /*) ;; *) REL="/$REL" ;; esac

cat <<EOF
menuentry "$NAME" {
    insmod part_gpt
    insmod ext2
    insmod loopback
    insmod iso9660
    search --no-floppy --fs-uuid --set=root $UUID
    set isofile="$REL"
    loopback loop \$isofile
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=\$isofile \\
        toram console=ttyAMA0,115200 ---
    initrd (loop)/casper/initrd
}
EOF

cat >&2 <<EOF

# append to /etc/grub.d/40_custom, then:
#   sudo update-grub
#   sudo reboot
# after boot, check that the live system is in RAM:
#   losetup -a
EOF
