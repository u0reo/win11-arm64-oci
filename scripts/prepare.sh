#!/usr/bin/env bash
# Print or install a GRUB entry that boots an Ubuntu live ISO with `toram`.
#
#   ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso
#   sudo ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso --write
#   sudo ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso --write --ssh
#
# `toram` copies the whole live system into RAM, so /dev/sda can be wiped
# while it runs.  After the reboot, pick the entry and run
#
#   sudo ./scripts/build.sh --to-ram --disk /dev/sda ...
#
# Add --keep-ubuntu to that command for a 4 GiB recovery Ubuntu, or leave it
# out for Windows only.
#
# --ssh   write a cloud-init seed (user-data + meta-data) to the ESP and label
#         the ESP `CIDATA`, so the live session starts sshd with the
#         authorized_keys of this machine.  Needs --write.  The Ubuntu Server
#         ISO ships cloud-init; if sshd still does not come up, use the serial
#         console and run: sudo apt-get install -y openssh-server
#         ESP_MNT (default /boot/efi) selects the mounted ESP.  The original
#         ESP label is saved to win11-arm64-oci-esp-label on the ESP.
#
# --write      install the entry into /etc/grub.d/40_custom and run update-grub
# --name NAME  override the GRUB menu label
set -euo pipefail

ISO_ARG=${1:-}
NAME=""
WRITE=0
WANT_SSH=0
GRUB_CUSTOM=${GRUB_CUSTOM:-/etc/grub.d/40_custom}
ESP_MNT=${ESP_MNT:-/boot/efi}

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[ -n "$ISO_ARG" ] || usage 1
case "$ISO_ARG" in
    -h|--help) usage 0 ;;
esac
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME=${2:?--name needs a label}; shift 2 ;;
        --write) WRITE=1; shift ;;
        --ssh) WANT_SSH=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "prepare: unknown argument: $1" >&2; usage 1 ;;
    esac
done

[ -f "$ISO_ARG" ] || { echo "prepare: missing $ISO_ARG" >&2; exit 1; }
ISO=$(realpath -e "$ISO_ARG")
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

NAME=${NAME:-Ubuntu live (toram)}
BEGIN="# BEGIN win11-arm64-oci:toram"
END="# END win11-arm64-oci:toram"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo -n"
fi
if [ "$WRITE" = 1 ] || [ "$WANT_SSH" = 1 ]; then
    $SUDO true 2>/dev/null || { echo "prepare: run as root (sudo)" >&2; exit 1; }
fi

# --- optional cloud-init seed for SSH in the live session ----------------
DS_ARG=""
if [ "$WANT_SSH" = 1 ]; then
    [ "$WRITE" = 1 ] || { echo "prepare: --ssh needs --write" >&2; exit 1; }
    ESP=$(findmnt -no SOURCE --target "$ESP_MNT" 2>/dev/null || true)
    ESPDIR=$(findmnt -no TARGET --target "$ESP_MNT" 2>/dev/null || true)
    ESPDIR=$(realpath -e "$ESPDIR" 2>/dev/null || true)
    ESP_WANT=$(realpath -e "$ESP_MNT" 2>/dev/null || true)
    [ -n "$ESP" ] && [ -n "$ESPDIR" ] && [ "$ESPDIR" = "$ESP_WANT" ] || {
        echo "prepare: $ESP_MNT is not mounted; mount the ESP first" >&2
        exit 1
    }
    KEYS=""
    add_keys() {
        [ -f "$1" ] || return 0
        KEYS+=$(awk 'NF && $1 !~ /^#/' "$1")$'\n'
    }
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        add_keys "/home/$SUDO_USER/.ssh/authorized_keys"
    fi
    add_keys /root/.ssh/authorized_keys
    for f in /home/*/.ssh/authorized_keys; do
        [ -e "$f" ] && add_keys "$f"
    done
    KEYS=$(printf '%s' "$KEYS" | awk 'NF && !seen[$0]++')
    [ -n "$KEYS" ] || {
        echo "prepare: no authorized_keys found in /home/*/.ssh or /root/.ssh" >&2
        exit 1
    }

    {
        echo "#cloud-config"
        echo "ssh_pwauth: false"
        echo "ssh_authorized_keys:"
        printf '%s\n' "$KEYS" | sed 's/^/  - /'
        echo "packages:"
        echo "  - openssh-server"
        echo "runcmd:"
        echo "  - systemctl enable --now ssh"
    } | $SUDO tee "$ESPDIR/user-data" >/dev/null
    printf 'instance-id: win11-arm64-oci-live\nlocal-hostname: win11-live\n' |
        $SUDO tee "$ESPDIR/meta-data" >/dev/null

    # cloud-init's NoCloud datasource auto-detects a vfat filesystem labelled
    # CIDATA.  A block device path is not a valid seedfrom URI, so relabel the
    # ESP instead of passing ds=nocloud;s=...
    OLD_LABEL=$($SUDO fatlabel "$ESP" 2>/dev/null) || {
        echo "prepare: fatlabel failed for $ESP (install dosfstools)" >&2
        exit 1
    }
    if [ "$OLD_LABEL" != CIDATA ]; then
        printf '%s\n' "${OLD_LABEL:-}" | $SUDO tee "$ESPDIR/win11-arm64-oci-esp-label" >/dev/null
        $SUDO fatlabel "$ESP" CIDATA
        echo "prepare: labelled the ESP CIDATA (was '${OLD_LABEL:-none}')"
        echo "  restore later with: sudo fatlabel $ESP '${OLD_LABEL:-}'"
    fi

    DS_ARG="ds=nocloud"
    echo "prepare: wrote $ESPDIR/user-data and meta-data (ssh keys: $(printf '%s\n' "$KEYS" | wc -l))"
fi

CMDLINE="toram ip=dhcp console=ttyAMA0,115200"
[ -n "$DS_ARG" ] && CMDLINE="$CMDLINE $DS_ARG"

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
        $CMDLINE ---
    initrd (loop)/casper/initrd
}
$END
EOF
}

if [ "$WRITE" = 0 ]; then
    entry
    cat >&2 <<EOF

# add --write to install this entry into $GRUB_CUSTOM:
#   sudo ./scripts/prepare.sh "$ISO" --write
EOF
    exit 0
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
echo "prepare: wrote $GRUB_CUSTOM"

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

if [ "$WANT_SSH" = 1 ]; then
    cat <<EOF
SSH: log in as the live user (ubuntu) with your usual key once the
network is up.  The address is printed on the serial console, or check
the OCI console.

EOF
fi

cat <<'EOF'
After the reboot, check that the live system is in RAM:

  losetup -a        # the loop should point at /dev/shm, /run or /tmp

Then build.  Windows only:

  sudo ./scripts/build.sh --to-ram --disk /dev/sda \
    --iso /dev/shm/Win11_ARM64_26H2.iso \
    --virtio /dev/shm/virtio-win.iso --mem 6144 --yes

Windows plus a 4 GiB recovery Ubuntu:

  sudo ./scripts/build.sh --to-ram --keep-ubuntu --disk /dev/sda \
    --iso /dev/shm/Win11_ARM64_26H2.iso \
    --virtio /dev/shm/virtio-win.iso --mem 6144 --yes
EOF
