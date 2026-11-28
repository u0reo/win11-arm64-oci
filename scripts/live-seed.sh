#!/usr/bin/env bash
# Write the cloud-init seed that makes the `toram` live session reachable by
# SSH.  Nothing else: this script never touches GRUB.
#
#   sudo ./scripts/live-seed.sh [--esp DIR]
#
# Defaults:
#   ESP   /boot/efi (or the ESP environment variable)
#   shm   RAM's 100% (fixed)
#
# It writes user-data / meta-data to the ESP, relabels the ESP to `CIDATA`
# so cloud-init's NoCloud datasource finds it, and saves the old label in
# win11-arm64-oci-esp-label.  The seed creates the user `ubuntu` with the
# authorized_keys of this machine, passwordless sudo and sshd, then makes
# /dev/shm/iso and /dev/shm/build and remounts /dev/shm at 100% of RAM.
#
# Must be run as root; the script never calls sudo itself.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() {
    echo "live-seed: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

ESP=${ESP:-/boot/efi}
while [ $# -gt 0 ]; do
    case "$1" in
        --esp) ESP=${2:?--esp needs a mount point}; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "live-seed: unknown argument: $1" >&2; usage 1 ;;
    esac
done

ESP_DEV=$(findmnt -no SOURCE --target "$ESP" 2>/dev/null || true)
ESPDIR=$(findmnt -no TARGET --target "$ESP" 2>/dev/null || true)
ESPDIR=$(realpath -e "$ESPDIR" 2>/dev/null || true)
ESP_WANT=$(realpath -e "$ESP" 2>/dev/null || true)
[ -n "$ESP_DEV" ] && [ -n "$ESPDIR" ] && [ "$ESPDIR" = "$ESP_WANT" ] ||
    die "$ESP is not mounted; mount the ESP first"

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
[ -n "$KEYS" ] ||
    die "no authorized_keys found in /home/*/.ssh or /root/.ssh"

# The Server live ISO's default user is 'installer', whose shell runs the
# installer UI.  Create a normal login user for SSH instead.
# /dev/shm must be enlarged before the build starts: the live system has to
# keep the ISO, staging files and QEMU guest in RAM at the same time.
KEYS_YAML=$(printf '%s\n' "$KEYS" | sed 's/^/      - /')
cat > "$ESPDIR/user-data" <<EOF
#cloud-config
ssh_pwauth: false
users:
  - default
  - name: ubuntu
    gecos: Ubuntu
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
$KEYS_YAML
runcmd:
  - systemctl enable --now ssh
  - sh -c 'mkdir -p /dev/shm/iso /dev/shm/build && chmod 1777 /dev/shm/iso /dev/shm/build'
  - sh -c 'mount -o remount,size=100% /dev/shm || true'
EOF
printf 'instance-id: win11-arm64-oci-live\nlocal-hostname: win11-live\n' |
    tee "$ESPDIR/meta-data" >/dev/null

# cloud-init's NoCloud datasource auto-detects a vfat filesystem labelled
# CIDATA.  A block device path is not a valid seedfrom URI, so relabel the
# ESP instead of passing ds=nocloud;s=...
# fatlabel prints its "boot sector and its backup" warning on stdout, so
# reading the label with it would capture that noise.  blkid reads the label
# without running the check that emits the warning.
OLD_LABEL=$(blkid -s LABEL -o value "$ESP_DEV" 2>/dev/null || true)
if [ "$OLD_LABEL" != CIDATA ]; then
    printf '%s\n' "${OLD_LABEL:-}" | tee "$ESPDIR/win11-arm64-oci-esp-label" >/dev/null
    fatlabel "$ESP_DEV" CIDATA >/dev/null ||
        die "fatlabel failed for $ESP_DEV (install dosfstools)"
    echo "live-seed: labelled the ESP CIDATA (was '${OLD_LABEL:-none}')"
    echo "  restore later with: fatlabel $ESP_DEV '${OLD_LABEL:-}'"
fi

echo "live-seed: wrote $ESPDIR/user-data and meta-data (ssh keys: $(printf '%s\n' "$KEYS" | wc -l))"
