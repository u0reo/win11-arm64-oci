#!/usr/bin/env bash
# Save the network and SSH configuration of an existing Ubuntu root so the
# recovery Ubuntu that replaces it keeps working without manual setup.
#
#   sudo ./pipeline/save_ubuntu_config.sh /dev/sdb build/ubuntu-config
#
# The output directory contains password hashes and SSH host keys, so keep it
# out of git (build/ is ignored) and delete it when the build is done.
set -euo pipefail

DISK=${1:?usage: $0 <disk> <out-dir>}
OUT=${2:?usage: $0 <disk> <out-dir>}

[ -b "$DISK" ] || { echo "save-config: $DISK is not a block device" >&2; exit 1; }

part() {
    if [[ "$1" =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2"
    else printf '%s%s' "$1" "$2"; fi
}

ROOTPART=$(lsblk -lnpbo NAME,FSTYPE,SIZE "$DISK" |
    awk '$2 ~ /^ext[234]$/ {print $3, $1}' | sort -n | tail -1 | awk '{print $2}')
[ -n "$ROOTPART" ] || { echo "save-config: no ext2/3/4 root on $DISK" >&2; exit 1; }
echo "save-config: reading $ROOTPART"

if [ -n "$(lsblk -no MOUNTPOINT "$ROOTPART" | tr -d ' ')" ]; then
    echo "save-config: $ROOTPART is already mounted; umount it first" >&2
    exit 1
fi

MNT=$(mktemp -d /tmp/save-config.XXXXXX)
trap 'mountpoint -q "$MNT" && sudo -n umount "$MNT"; rmdir "$MNT" 2>/dev/null' EXIT

# A toram boot can leave the source ext4 with a dirty journal.  The kernel
# then refuses a read-only mount ("would change RO state") because replaying
# the journal writes to the filesystem.  Mount it read-write once so ext4 can
# recover; the disk is about to be repartitioned anyway.
if ! sudo -n mount -o ro "$ROOTPART" "$MNT" 2>/dev/null; then
    echo "save-config: read-only mount failed; replaying the journal with a" \
        "temporary read-write mount" >&2
    sudo -n mount -o rw "$ROOTPART" "$MNT"
fi

mkdir -p "$OUT/netplan" "$OUT/ssh/hostkeys" "$OUT/users" "$OUT/etc"

copy() { [ -e "$MNT/$1" ] && sudo -n cp -a "$MNT/$1" "$OUT/$2" || true; }

echo "  netplan"
for f in "$MNT"/etc/netplan/*.yaml; do
    [ -f "$f" ] && sudo -n cp -a "$f" "$OUT/netplan/"
done
echo "  sshd config and host keys"
copy etc/ssh/sshd_config ssh/
[ -d "$MNT/etc/ssh/sshd_config.d" ] && sudo -n cp -a "$MNT/etc/ssh/sshd_config.d" "$OUT/ssh/"
for f in "$MNT"/etc/ssh/ssh_host_*; do
    [ -e "$f" ] && sudo -n cp -a "$f" "$OUT/ssh/hostkeys/"
done
echo "  authorized_keys"
for d in "$MNT"/home/*; do
    [ -d "$d" ] || continue
    u=$(basename "$d")
    [ -f "$d/.ssh/authorized_keys" ] && \
        sudo -n cp -a "$d/.ssh/authorized_keys" "$OUT/users/$u.authorized_keys"
done
[ -f "$MNT/root/.ssh/authorized_keys" ] && \
    sudo -n cp -a "$MNT/root/.ssh/authorized_keys" "$OUT/users/root.authorized_keys"

echo "  account and system files"
copy etc/passwd etc/
copy etc/shadow etc/
copy etc/group etc/
copy etc/gshadow etc/
[ -d "$MNT/etc/sudoers.d" ] && sudo -n cp -a "$MNT/etc/sudoers.d" "$OUT/etc/"
copy etc/hostname etc/
copy etc/hosts etc/
copy etc/timezone etc/
copy etc/localtime etc/
copy etc/os-release etc/
copy etc/default/keyboard etc/

sudo -n umount "$MNT"
sudo -n chown -R "$(id -u):$(id -g)" "$OUT"

{
    echo "saved from $ROOTPART"
    echo "netplan:   $(ls -1 "$OUT/netplan" | wc -l) file(s)"
    echo "ssh keys:  $(ls -1 "$OUT/ssh/hostkeys" | wc -l) file(s)"
    echo "users:     $(ls -1 "$OUT/users" | sed 's/\.authorized_keys$//' | tr '\n' ' ')"
} | tee "$OUT/MANIFEST.txt"

if [ -z "$(ls -A "$OUT/netplan")" ]; then
    echo "save-config: WARN: no netplan YAML; the recovery system will use DHCP"
fi
