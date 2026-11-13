#!/usr/bin/env bash
# Stage an Ubuntu ISO in the GRUB menu of an Oracle Cloud Ubuntu instance,
# so the Windows build can start from a clean environment.
#
#   sudo ./scripts/prepare.sh --toram /srv/iso/ubuntu-live-server-arm64.iso --write
#   sudo ./scripts/prepare.sh --installer /srv/iso/ubuntu-live-server-arm64.iso --write
#
# Without --write the menu entry is printed to stdout.
#
# --toram      boot the ISO with `toram`: the whole live system runs in RAM,
#              so /dev/sda can be wiped while it is running.  After the
#              reboot, pick the entry and run
#                sudo ./scripts/build.sh --to-ram --disk /dev/sda ...
#              Add --keep-ubuntu to that command to also create the 4 GiB
#              recovery Ubuntu.
#
# --installer  boot the Ubuntu Server installer (also with toram, because the
#              installer repartitions the disk it booted from).  Install with
#              p1 = ESP, p2 = 4 GiB /, and leave the rest unallocated, then
#              reboot into the new system and run
#                sudo ./scripts/build.sh --reuse-ubuntu --disk /dev/sda ...
#
# --name NAME  override the GRUB menu label.
# --write      append or replace the entry in /etc/grub.d/40_custom and run
#              update-grub.  Without it the entry is only printed.
set -euo pipefail

MODE=""
ISO=""
NAME=""
WRITE=0
GRUB_CUSTOM=${GRUB_CUSTOM:-/etc/grub.d/40_custom}

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --toram) MODE=toram; ISO=${2:?--toram needs an ISO}; shift 2 ;;
        --installer) MODE=installer; ISO=${2:?--installer needs an ISO}; shift 2 ;;
        --name) NAME=${2:?--name needs a label}; shift 2 ;;
        --write) WRITE=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "prepare: unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -n "$MODE" ] || { echo "prepare: choose --toram or --installer" >&2; usage 1; }
[ -f "$ISO" ] || { echo "prepare: missing $ISO" >&2; exit 1; }

ISO=$(realpath -e "$ISO")
MNT=$(findmnt -no TARGET --target "$ISO" 2>/dev/null || true)
UUID=$(findmnt -no UUID --target "$ISO" 2>/dev/null || true)
FSTYPE=$(findmnt -no FSTYPE --target "$ISO" 2>/dev/null || true)
[ -n "$MNT" ] && [ -n "$UUID" ] || {
    echo "prepare: $ISO is not on a mounted filesystem with a UUID" >&2
    exit 1
}
case "$FSTYPE" in
    tmpfs|ramfs)
        echo "prepare: $ISO is on $FSTYPE; GRUB cannot read it after a reboot" >&2
        echo "  move it to a real filesystem (for example /srv/iso)" >&2
        exit 1
        ;;
esac

REL=${ISO#"$MNT"}
case "$REL" in /*) ;; *) REL="/$REL" ;; esac

ISO_TYPE=$(blkid -p -s TYPE -o value "$ISO" 2>/dev/null || true)
case "$ISO_TYPE" in
    iso9660|udf) ;;
    *) echo "prepare: warning: $ISO does not look like an ISO image ($ISO_TYPE)" >&2 ;;
esac

if [ "$MODE" = installer ]; then
    DEFAULT_NAME="Ubuntu Server installer (toram)"
    KEY=installer
else
    DEFAULT_NAME="Ubuntu live (toram)"
    KEY=toram
fi
NAME=${NAME:-$DEFAULT_NAME}
BEGIN="# BEGIN win11-arm64-oci:$KEY"
END="# END win11-arm64-oci:$KEY"

entry() {
    cat <<EOF
$BEGIN
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
$END
EOF
}

if [ "$WRITE" = 0 ]; then
    entry
    cat >&2 <<EOF

# add --write to install this entry into $GRUB_CUSTOM:
#   sudo ./scripts/prepare.sh --$MODE "$ISO" --write
EOF
    exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo -n"
    $SUDO true 2>/dev/null || { echo "prepare: run as root (sudo)" >&2; exit 1; }
fi

TMP=$(mktemp /tmp/prepare-grub.XXXXXX)
trap 'rm -f "$TMP"' EXIT

if $SUDO test -f "$GRUB_CUSTOM"; then
    $SUDO awk -v b="$BEGIN" -v e="$END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
    ' "$GRUB_CUSTOM" > "$TMP"
else
    cat > "$TMP" <<'EOF'
#!/bin/sh
exec tail -n +3 $0
# Custom entries added by win11-arm64-oci.
EOF
fi

entry >> "$TMP"
$SUDO install -m 0755 "$TMP" "$GRUB_CUSTOM"
echo "prepare: wrote $GRUB_CUSTOM ($KEY)"

if command -v update-grub >/dev/null 2>&1; then
    $SUDO update-grub
    echo "prepare: update-grub done"
else
    echo "prepare: update-grub not found; run it yourself" >&2
fi

if $SUDO test -f /etc/default/grub; then
    TIMEOUT=$($SUDO sed -n 's/^GRUB_TIMEOUT=//p' /etc/default/grub | tail -1)
    case "$TIMEOUT" in
        0|0.0)
            echo "prepare: warning: GRUB_TIMEOUT is 0, so the menu may not appear." >&2
            echo "  set GRUB_TIMEOUT=10 and GRUB_TIMEOUT_STYLE=menu in" >&2
            echo "  /etc/default/grub, then run sudo update-grub" >&2
            ;;
    esac
fi

cat <<EOF

prepare: reboot and pick "$NAME" in the GRUB menu.

EOF

if [ "$MODE" = installer ]; then
    cat <<'EOF'
In the installer:
  - p1  ESP       keep it as it is (about 100 MiB - 1 GiB)
  - p2  /         4 GiB, ext4
  - the rest      leave UNALLOCATED (Windows goes there later)
Do not create a swap partition: it would take space from Windows.

Then reboot into the new system and run:

  sudo ./scripts/build.sh --reuse-ubuntu --disk /dev/sda \
    --iso /path/to/Win11_ARM64_26H2.iso --yes
EOF
else
    cat <<'EOF'
After the reboot, check that the live system is in RAM:

  losetup -a        # the loop should point at /dev/shm, /run or /tmp

Then build.  Windows only:

  sudo ./scripts/build.sh --to-ram --disk /dev/sda \
    --iso /path/to/Win11_ARM64_26H2.iso --yes

Windows plus a 4 GiB recovery Ubuntu:

  sudo ./scripts/build.sh --to-ram --keep-ubuntu --disk /dev/sda \
    --iso /path/to/Win11_ARM64_26H2.iso --yes
EOF
fi
