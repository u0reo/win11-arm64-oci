#!/usr/bin/env bash
# Install a small Ubuntu Server (recovery only) into partition 2.
#
#   sudo ./pipeline/make_recovery_ubuntu.sh /dev/sdb build/ubuntu-config
#
# Partition 2 must already exist and be formatted ext4 (host_apply.sh does
# that in KEEP_UBUNTU mode).  Partition 1 is the ESP and is left untouched
# apart from the GRUB files, which land in \EFI\ubuntu.
#
# The point is a login you can fall back to when Windows misbehaves, so the
# install is deliberately minimal: no snapd, no cloud-init, no firmware.
# The netplan and SSH configuration saved by save_ubuntu_config.sh is copied
# in, so the same keys and the same DHCP setup work.
#
# Requires debootstrap on the builder (scripts/setup.sh installs it).
set -euo pipefail

DISK=${1:?usage: $0 <disk> <config-dir>}
CONFIG=${2:?usage: $0 <disk> <config-dir>}

MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
RELEASE=${RELEASE:-}
RECOVERY_PASSWORD=${RECOVERY_PASSWORD:-}

[ -b "$DISK" ] || { echo "recovery: $DISK is not a block device" >&2; exit 1; }
[ -d "$CONFIG" ] || { echo "recovery: missing config dir $CONFIG" >&2; exit 1; }
command -v debootstrap >/dev/null || {
    echo "recovery: debootstrap is not installed (run scripts/setup.sh)" >&2
    exit 1
}

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo -n); fi

part() {
    if [[ "$1" =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2"
    else printf '%s%s' "$1" "$2"; fi
}

P1=$(part "$DISK" 1)
P2=$(part "$DISK" 2)
[ -b "$P1" ] || { echo "recovery: no ESP at $P1" >&2; exit 1; }
[ -b "$P2" ] || { echo "recovery: no root partition at $P2" >&2; exit 1; }

if [ -z "$RELEASE" ] && [ -f "$CONFIG/etc/os-release" ]; then
    RELEASE=$(sed -n 's/^VERSION_CODENAME=//p' "$CONFIG/etc/os-release" | tr -d '"')
fi
[ -n "$RELEASE" ] || {
    echo "recovery: cannot determine the Ubuntu release; set RELEASE=noble" >&2
    exit 1
}
echo "recovery: release $RELEASE, mirror $MIRROR"

MNT=$(mktemp -d /tmp/recovery.XXXXXX)
BINDS=()
cleanup() {
    set +e
    for (( i=${#BINDS[@]}-1; i>=0; i-- )); do
        "${SUDO[@]}" umount "$MNT/${BINDS[$i]}" 2>/dev/null
    done
    mountpoint -q "$MNT/boot/efi" && "${SUDO[@]}" umount "$MNT/boot/efi" 2>/dev/null
    mountpoint -q "$MNT" && "${SUDO[@]}" umount "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

"${SUDO[@]}" mount "$P2" "$MNT"

echo "[1/6] debootstrap $RELEASE"
# debootstrap refuses a non-empty target, so the ESP is mounted only after
# the base system exists (see [3/6]).
"${SUDO[@]}" debootstrap --arch=arm64 --variant=minbase \
    --components=main,universe "$RELEASE" "$MNT" "$MIRROR"

"${SUDO[@]}" tee "$MNT/etc/apt/sources.list" >/dev/null <<EOF
deb $MIRROR $RELEASE main universe restricted multiverse
deb $MIRROR $RELEASE-updates main universe restricted multiverse
deb $MIRROR $RELEASE-security main universe restricted multiverse
EOF

for d in dev dev/pts proc sys run; do
    "${SUDO[@]}" mkdir -p "$MNT/$d"
    "${SUDO[@]}" mount --bind "/$d" "$MNT/$d"
    BINDS+=("$d")
done
"${SUDO[@]}" cp /etc/resolv.conf "$MNT/etc/resolv.conf"

run() { "${SUDO[@]}" chroot "$MNT" env DEBIAN_FRONTEND=noninteractive "$@"; }

echo "[2/6] install the minimal package set"
run apt-get update
# --no-install-recommends keeps linux-firmware and snapd out; the whole
# rootfs has to fit in 4 GiB.
run apt-get install -y --no-install-recommends \
    linux-image-generic initramfs-tools systemd-sysv \
    openssh-server netplan.io sudo ca-certificates \
    iproute2 iputils-ping less vim-tiny e2fsprogs kmod

echo "[3/6] GRUB (EFI)"
"${SUDO[@]}" mkdir -p "$MNT/boot/efi"
"${SUDO[@]}" mount "$P1" "$MNT/boot/efi"
run apt-get install -y --no-install-recommends grub-efi-arm64 || \
    echo "  WARN: grub-efi-arm64 postinst failed; retrying by hand"
run grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --bootloader-id=ubuntu --no-nvram --recheck || \
    echo "  WARN: grub-install failed; Windows still boots, Ubuntu may not"

"${SUDO[@]}" tee "$MNT/etc/default/grub" >/dev/null <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=Ubuntu
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyAMA0,115200 console=tty1"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
GRUB_DISABLE_OS_PROBER=true
EOF
run update-grub || echo "  WARN: update-grub failed"

echo "[4/6] hostname, timezone, accounts"
for f in hostname hosts timezone localtime; do
    [ -e "$CONFIG/etc/$f" ] && "${SUDO[@]}" cp -a "$CONFIG/etc/$f" "$MNT/etc/$f"
done
if [ ! -e "$CONFIG/etc/timezone" ]; then
    "${SUDO[@]}" ln -sf /usr/share/zoneinfo/UTC "$MNT/etc/localtime"
fi

if [ -f "$CONFIG/etc/group" ]; then
    for g in $(awk -F: '$3>=1000 && $3<60000 {print $1}' "$CONFIG/etc/group"); do
        run groupadd -f -g "$(awk -F: -v n="$g" '$1==n{print $3}' "$CONFIG/etc/group")" "$g" || true
    done
fi

CREATED=""
[ -f "$CONFIG/etc/passwd" ] || echo "  WARN: no saved passwd; no accounts to copy"
while IFS=: read -r name _ uid gid gecos home shell; do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ "$uid" -lt 60000 ] || continue
    case "$shell" in */nologin|*/false) continue ;; esac
    run id -u "$name" >/dev/null 2>&1 && continue
    run useradd -u "$uid" -g "$gid" -m -d "$home" -s "$shell" -c "$gecos" "$name" || continue
    hash=$(awk -F: -v n="$name" '$1==n{print $2}' "$CONFIG/etc/shadow" 2>/dev/null || true)
    if [ -n "$hash" ] && [ "$hash" != "!" ] && [ "$hash" != "*" ]; then
        run usermod -p "$hash" "$name"
    fi
    run usermod -aG sudo "$name" || true
    if [ -f "$CONFIG/users/$name.authorized_keys" ]; then
        "${SUDO[@]}" install -d -m 700 -o "$uid" -g "$gid" "$MNT$home/.ssh"
        "${SUDO[@]}" install -m 600 -o "$uid" -g "$gid" \
            "$CONFIG/users/$name.authorized_keys" "$MNT$home/.ssh/authorized_keys"
    fi
    CREATED="$CREATED $name"
done < <(cat "$CONFIG/etc/passwd" 2>/dev/null || true)

if [ -f "$CONFIG/users/root.authorized_keys" ]; then
    "${SUDO[@]}" install -d -m 700 -o 0 -g 0 "$MNT/root/.ssh"
    "${SUDO[@]}" install -m 600 -o 0 -g 0 \
        "$CONFIG/users/root.authorized_keys" "$MNT/root/.ssh/authorized_keys"
fi

if [ -d "$CONFIG/etc/sudoers.d" ]; then
    "${SUDO[@]}" cp -a "$CONFIG/etc/sudoers.d/." "$MNT/etc/sudoers.d/" 2>/dev/null || true
    "${SUDO[@]}" chown -R root:root "$MNT/etc/sudoers.d"
    "${SUDO[@]}" chmod 0440 "$MNT"/etc/sudoers.d/* 2>/dev/null || true
fi

if [ -z "$CREATED" ]; then
    if [ -z "$RECOVERY_PASSWORD" ]; then
        # head closes the pipe early, so swallow the SIGPIPE status.
        RECOVERY_PASSWORD=$( (tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16) || true )
        echo "  note: no account could be copied; created 'ubuntu' with a random password"
    fi
    run useradd -m -s /bin/bash -G sudo ubuntu
    echo "ubuntu:$RECOVERY_PASSWORD" | "${SUDO[@]}" chroot "$MNT" chpasswd
    CREATED=" ubuntu"
fi

echo "[5/6] netplan, SSH, fstab"
if compgen -G "$CONFIG/netplan/*.yaml" >/dev/null; then
    "${SUDO[@]}" cp -a "$CONFIG"/netplan/*.yaml "$MNT/etc/netplan/"
    echo "  copied $(ls -1 "$CONFIG"/netplan/*.yaml | wc -l) netplan file(s)"
else
    "${SUDO[@]}" tee "$MNT/etc/netplan/01-recovery.yaml" >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
EOF
    echo "  no saved netplan; wrote a DHCP match for en*"
fi
"${SUDO[@]}" chmod 600 "$MNT"/etc/netplan/*.yaml

if [ -f "$CONFIG/ssh/sshd_config" ]; then
    "${SUDO[@]}" cp -a "$CONFIG/ssh/sshd_config" "$MNT/etc/ssh/sshd_config"
fi
if [ -d "$CONFIG/ssh/sshd_config.d" ]; then
    "${SUDO[@]}" cp -a "$CONFIG/ssh/sshd_config.d/." "$MNT/etc/ssh/sshd_config.d/"
fi
if compgen -G "$CONFIG/ssh/hostkeys/*" >/dev/null; then
    "${SUDO[@]}" cp -a "$CONFIG"/ssh/hostkeys/. "$MNT/etc/ssh/"
    "${SUDO[@]}" chmod 600 "$MNT"/etc/ssh/ssh_host_*_key 2>/dev/null || true
    "${SUDO[@]}" chmod 644 "$MNT"/etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
    echo "  reused the SSH host keys"
fi

ROOT_UUID=$("${SUDO[@]}" blkid -s UUID -o value "$P2")
ESP_UUID=$("${SUDO[@]}" blkid -s UUID -o value "$P1")
"${SUDO[@]}" tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077         0 1
EOF

run systemctl enable systemd-networkd >/dev/null 2>&1 || true
run systemctl enable ssh >/dev/null 2>&1 || true
run systemctl enable serial-getty@ttyAMA0 >/dev/null 2>&1 || true
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/recovery-resolv.conf
"${SUDO[@]}" cp /tmp/recovery-resolv.conf "$MNT/etc/resolv.conf"
rm -f /tmp/recovery-resolv.conf

echo "[6/6] clean up and verify"
run apt-get clean
"${SUDO[@]}" rm -rf "$MNT/var/lib/apt/lists"/* "$MNT/var/cache/apt/archives"/*.deb "$MNT/tmp"/*
"${SUDO[@]}" mkdir -p "$MNT/var/lib/apt/lists/partial"
run update-initramfs -u -k all >/dev/null 2>&1 || echo "  WARN: update-initramfs failed"
"${SUDO[@]}" sync

"${SUDO[@]}" df -h "$MNT" | sed -n '1,2p'
"${SUDO[@]}" test -f "$MNT/boot/efi/EFI/ubuntu/grubaa64.efi" || \
    echo "  WARN: \\EFI\\ubuntu\\grubaa64.efi is missing on the ESP" >&2

echo
echo "OK: recovery Ubuntu $RELEASE installed on $P2"
echo "    accounts:$CREATED"
[ -n "$RECOVERY_PASSWORD" ] && echo "    password for ubuntu: $RECOVERY_PASSWORD"
echo "    Windows Boot Manager will chainload \\EFI\\ubuntu\\grubaa64.efi"
