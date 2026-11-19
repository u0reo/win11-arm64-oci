#!/usr/bin/env bash
# Print or install a GRUB entry that boots an Ubuntu live ISO with `toram`.
#
#   ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso
#   sudo ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso --write
#   sudo ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso --write --ssh
#   sudo ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso --write --once
#   sudo ./scripts/prepare.sh /srv/iso/ubuntu-live-server-arm64.iso --write --default
#
# `toram` copies the whole live system into RAM, so /dev/sda can be wiped
# while it runs.  After the reboot, boot the entry (--once / --default, or
# pick it in the menu) and run
#
#   sudo ./scripts/build.sh --disk /dev/sda ...
#
# The live system keeps the build in RAM: setup.sh remounts /dev/shm at
# SHM_SIZE (default 100% of RAM), stages in /dev/shm/build and expects the
# Windows ISO and virtio-win in /dev/shm/iso.  With --ssh, the cloud-init
# seed also performs the /dev/shm setup at boot.
#
# build.sh copies the Windows ISO and virtio-win into /dev/shm/iso if they
# are still on /dev/sda.  The live ISO itself must already be in RAM (toram).
#
# Add --fresh-ubuntu to that command for a 4 GiB recovery Ubuntu with a new
# ESP, or leave it out for Windows only.  The recovery system copies only
# /etc/netplan/*.yaml and authorized_keys from the running live system.
#
# --ssh        write a cloud-init seed (user-data + meta-data) to the ESP and
#             label the ESP `CIDATA`.  The live session then creates the user
#             `ubuntu` (passwordless sudo, /bin/bash) with the authorized_keys
#             of this machine, and starts sshd.  Needs --write.  The Ubuntu
#             Server live ISO already contains cloud-init and openssh-server;
#             if sshd does not come up, check `sudo cloud-init status --long`
#             on the serial console.  ESP_MNT (default /boot/efi) selects the
#             mounted ESP.  The original ESP label is saved to
#             win11-arm64-oci-esp-label.
#
# --once      boot the live entry on the next boot only (grub-reboot).  The
#             id is used, not a menu number, so the order of the generated
#             menu does not matter.  If the live session fails to boot, the
#             next power cycle returns to Ubuntu.  Needs --write.
# --default   make the live entry the persistent GRUB default.  Writes
#             GRUB_DEFAULT=<id> (not an index) to /etc/default/grub, so
#             `update-grub` can add or remove entries without breaking it.
#             The previous file is saved to
#             /etc/default/grub.win11-arm64-oci.bak.  Needs --write.
# --id ID     id of the menu entry (default win11-live-toram).  It is also the
#             value of GRUB_DEFAULT, so it must not start with a digit.
#
# --write      install the entry into /etc/grub.d/40_custom and run update-grub
# --name NAME  override the GRUB menu label
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../internal/live.sh
. "$HERE/../internal/live.sh"

ISO_ARG=${1:-}
NAME=""
WRITE=0
WANT_SSH=0
WANT_DEFAULT=0
WANT_ONCE=0
SHM_SIZE=${SHM_SIZE:-100%}
ID=${ID:-win11-live-toram}
GRUB_CUSTOM=${GRUB_CUSTOM:-/etc/grub.d/40_custom}
GRUB_CFG=${GRUB_CFG:-/boot/grub/grub.cfg}
GRUB_DEFAULT_FILE=${GRUB_DEFAULT_FILE:-/etc/default/grub}
GRUB_DEFAULT_BACKUP=${GRUB_DEFAULT_BACKUP:-/etc/default/grub.win11-arm64-oci.bak}
ESP_MNT=${ESP_MNT:-/boot/efi}

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
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
        --id) ID=${2:?--id needs a value}; shift 2 ;;
        --write) WRITE=1; shift ;;
        --ssh) WANT_SSH=1; shift ;;
        --default) WANT_DEFAULT=1; shift ;;
        --once) WANT_ONCE=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "prepare: unknown argument: $1" >&2; usage 1 ;;
    esac
done

valid_shm_size "$SHM_SIZE" || {
    echo "prepare: SHM_SIZE must be 100%, 16G, 1024, ..." >&2
    exit 1
}

# GRUB ids are alphanumeric, '_' and '-', and must not start with a digit.
case "$ID" in
    [A-Za-z_]*) ;;
    *) echo "prepare: --id must start with a letter or underscore" >&2; exit 1 ;;
esac
case "$ID" in
    *[!A-Za-z0-9_-]*)
        echo "prepare: --id may contain only letters, digits, '_' and '-'" >&2
        exit 1 ;;
esac

if [ "$WANT_DEFAULT" = 1 ] || [ "$WANT_ONCE" = 1 ]; then
    [ "$WRITE" = 1 ] || {
        echo "prepare: --default and --once need --write" >&2
        exit 1
    }
fi

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
DEF_BEGIN="# BEGIN win11-arm64-oci:default"
DEF_END="# END win11-arm64-oci:default"

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
    # Keep only "type base64 [comment]".  authorized_keys lines may carry
    # options, and Ubuntu cloud images guard the root key with a command=
    # option.  Passing that to ssh_authorized_keys would run the guard for the
    # live user instead of starting a shell.
    add_keys() {
        [ -f "$1" ] || return 0
        KEYS+=$(awk '
            NF && $1 !~ /^#/ {
                for (i = 1; i < NF; i++) {
                    if ($i ~ /^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[^,]+|sk-[^,]+)$/ &&
                        length($(i + 1)) > 40) {
                        line = $i
                        for (j = i + 1; j <= NF; j++) line = line " " $j
                        print line
                        break
                    }
                }
            }' "$1")$'\n'
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
        # The Server live ISO's default user is 'installer', whose shell runs
        # the installer UI.  Create a normal login user for SSH instead.
        echo "users:"
        echo "  - default"
        echo "  - name: ubuntu"
        echo "    gecos: Ubuntu"
        echo "    groups: [adm, sudo]"
        echo "    shell: /bin/bash"
        echo '    sudo: "ALL=(ALL) NOPASSWD:ALL"'
        echo "    ssh_authorized_keys:"
        printf '%s\n' "$KEYS" | sed 's/^/      - /'
        echo "runcmd:"
        echo "  - systemctl enable --now ssh"
        # Do this before the build starts.  The live system has to keep the
        # ISO, staging files and QEMU guest in RAM at the same time.
        echo "  - sh -c 'mkdir -p /dev/shm/iso /dev/shm/build && chmod 1777 /dev/shm/iso /dev/shm/build'"
        echo "  - sh -c 'mount -o remount,size=$SHM_SIZE /dev/shm || true'"
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
menuentry "$NAME" --id $ID {
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
TMP2=""
trap 'rm -f "$TMP" "${TMP2:-}"' EXIT

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

# --- optional auto-boot ---------------------------------------------------
OLD_DEFAULT=""
if [ "$WANT_DEFAULT" = 1 ]; then
    $SUDO test -f "$GRUB_DEFAULT_FILE" || {
        echo "prepare: $GRUB_DEFAULT_FILE not found" >&2
        exit 1
    }
    OLD_DEFAULT=$($SUDO sed -n 's/^[[:space:]]*GRUB_DEFAULT=//p' \
        "$GRUB_DEFAULT_FILE" | tail -n 1 || true)
    if ! $SUDO test -f "$GRUB_DEFAULT_BACKUP"; then
        $SUDO cp -p "$GRUB_DEFAULT_FILE" "$GRUB_DEFAULT_BACKUP"
    fi
    TMP2=$(mktemp /tmp/prepare-grub-default.XXXXXX)
    $SUDO awk -v b="$DEF_BEGIN" -v e="$DEF_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip    { next }
        /^[[:space:]]*GRUB_DEFAULT=/ { next }
        { print }
    ' "$GRUB_DEFAULT_FILE" > "$TMP2"
    {
        printf '%s\n' "$DEF_BEGIN"
        printf 'GRUB_DEFAULT=%s\n' "$ID"
        printf '%s\n' "$DEF_END"
    } >> "$TMP2"
    $SUDO install -m 0644 "$TMP2" "$GRUB_DEFAULT_FILE"
    echo "prepare: GRUB_DEFAULT=$ID (was '${OLD_DEFAULT:-unset}')"
fi

if $SUDO sh -c 'command -v update-grub >/dev/null 2>&1'; then
    $SUDO update-grub
    echo "prepare: update-grub done"
else
    echo "prepare: update-grub not found; run it yourself" >&2
fi

if ! $SUDO grep -q -- "--id $ID" "$GRUB_CFG" 2>/dev/null; then
    echo "prepare: warning: $ID is not in $GRUB_CFG" >&2
    echo "  check $GRUB_CUSTOM and run update-grub" >&2
fi

if [ "$WANT_ONCE" = 1 ]; then
    if ! $SUDO sh -c 'command -v grub-reboot >/dev/null 2>&1'; then
        echo "prepare: grub-reboot not found; install grub-common" >&2
        exit 1
    fi
    if ! $SUDO test -f /boot/grub/grubenv; then
        $SUDO grub-editenv - create
    fi
    $SUDO grub-reboot "$ID"
    if $SUDO sh -c 'command -v grub-editenv >/dev/null 2>&1'; then
        NEXT=$($SUDO grub-editenv - list 2>/dev/null |
            sed -n 's/^next_entry=//p' || true)
        [ "$NEXT" = "$ID" ] || {
            echo "prepare: warning: next_entry is '${NEXT:-unset}', expected '$ID'" >&2
        }
    fi
fi

if [ "$WANT_DEFAULT" = 0 ] && [ "$WANT_ONCE" = 0 ] &&
    $SUDO test -f "$GRUB_DEFAULT_FILE"; then
    TIMEOUT=$($SUDO sed -n 's/^GRUB_TIMEOUT=//p' "$GRUB_DEFAULT_FILE" | tail -1)
    case "$TIMEOUT" in
        0|0.0)
            echo "prepare: warning: GRUB_TIMEOUT is 0, so the menu may not appear." >&2
            echo "  use --once or --default to boot the live entry without the menu," >&2
            echo "  or set GRUB_TIMEOUT=10 and GRUB_TIMEOUT_STYLE=menu" >&2
            ;;
    esac
fi

if [ "$WANT_ONCE" = 1 ]; then
    cat <<EOF

prepare: reboot.  The next boot uses "$NAME" once (grub-reboot $ID).
EOF
    if [ "$WANT_DEFAULT" = 1 ]; then
        cat <<EOF
  GRUB_DEFAULT=$ID is set for the boots after that.
EOF
    fi
    cat <<EOF
  If the live session fails to boot, power-cycle and Ubuntu boots again.
EOF
elif [ "$WANT_DEFAULT" = 1 ]; then
    cat <<EOF

prepare: reboot.  "$NAME" boots automatically from now on
(GRUB_DEFAULT=$ID).  Restore the old default with:

  sudo cp -p $GRUB_DEFAULT_BACKUP $GRUB_DEFAULT_FILE
  sudo update-grub
EOF
else
    cat <<EOF

prepare: reboot and pick "$NAME" in the GRUB menu.
EOF
fi

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
  df -h /dev/shm    # setup.sh remounts it (default 100% of RAM)
  ls -ld /dev/shm/iso /dev/shm/build

Put the media in /dev/shm/iso (RAM):

  mkdir -p /dev/shm/iso
  cp /path/to/Win11_ARM64_26H2.iso /dev/shm/iso/
  cp /path/to/virtio-win.iso /dev/shm/iso/

Then build.  Windows only:

  sudo ./scripts/build.sh --disk /dev/sda \
    --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
    --virtio /dev/shm/iso/virtio-win.iso --mem 6144 --yes

Windows plus a 4 GiB recovery Ubuntu (new ESP):

  sudo ./scripts/build.sh --fresh-ubuntu --disk /dev/sda \
    --iso /dev/shm/iso/Win11_ARM64_26H2.iso \
    --virtio /dev/shm/iso/virtio-win.iso --mem 6144 --yes

The recovery Ubuntu copies /etc/netplan and authorized_keys from this live
session (with --ssh, the keys seeded into the ESP).  No other account or SSH
settings are copied.

The staging directory defaults to /dev/shm/build.
--virtio also accepts virtio-win-*.noarch.rpm (283 MiB instead of 837 MiB).
EOF
