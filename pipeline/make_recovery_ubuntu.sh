#!/usr/bin/env bash
# Install a small Ubuntu Server (recovery only) into the ext4 recovery
# partition created by host_apply.sh.
#
#   sudo ./pipeline/make_recovery_ubuntu.sh /dev/sdb
#
# The recovery partition must already exist and be formatted ext4
# (host_apply.sh does that in FRESH_UBUNTU mode).  Both it and the ESP are
# found by their GPT type.  The ESP is left untouched apart from the GRUB
# files, which land in \EFI\ubuntu.  In the offline path the signed shim
# (shimaa64.efi) is installed there too, so finish_winpe.sh can make
# \EFI\Boot\BOOTAA64.EFI a shim that starts signed GRUB.
#
# The point is a login you can fall back to when Windows misbehaves, so the
# network install is deliberately minimal: no snapd, no cloud-init, no
# firmware.  The offline path reuses the ISO's minimal server rootfs, which
# already carries those files.
#
# Only two things are taken from the Ubuntu that runs this build:
#   - /etc/netplan/*.yaml
#   - an authorized_keys file (the ubuntu user first, then /home/*, then
#     /root)
# Password hashes, user accounts, SSH host keys and sudoers are not copied;
# the recovery system gets a new ubuntu account with a generated password.
#
# Two installers are supported:
#
#   OFFLINE=auto (default)
#       When the live ISO is mounted (/cdrom/casper/*.squashfs and
#       /cdrom/pool), unpack the ISO's minimal server rootfs instead of
#       downloading packages.  The ISO is self-contained and this also works
#       on networks where ports.ubuntu.com stalls.  openssh-server, GRUB and
#       the initramfs tools are taken from the ISO pool / the live host.
#   OFFLINE=0
#       Classic debootstrap from MIRROR.  Used when no live ISO is mounted.
#
# Requires debootstrap on the builder for the network path
# (scripts/setup.sh installs it), and unsquashfs for the offline path.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"
DISK=${1:?usage: $0 <disk>}

MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
RELEASE=${RELEASE:-}
RECOVERY_PASSWORD=${RECOVERY_PASSWORD:-}
OFFLINE=${OFFLINE:-auto}
SQUASHFS=${SQUASHFS:-}
ISO_POOL=${ISO_POOL:-/cdrom/pool}
GRUB_SIGNED_DEB=${GRUB_SIGNED_DEB:-}
GRUB_MODULES_DEB=${GRUB_MODULES_DEB:-}
SHIM_SIGNED_DEB=${SHIM_SIGNED_DEB:-}

[ -b "$DISK" ] || { echo "recovery: $DISK is not a block device" >&2; exit 1; }

if [ "$OFFLINE" = auto ]; then
    if [ -n "$SQUASHFS" ] || compgen -G '/cdrom/casper/*.squashfs' >/dev/null; then
        OFFLINE=1
    else
        OFFLINE=0
    fi
fi
case "$OFFLINE" in
    0|1) ;;
    *) echo "recovery: OFFLINE must be auto, 0 or 1" >&2; exit 2 ;;
esac

if [ "$OFFLINE" = 1 ]; then
    if [ -z "$SQUASHFS" ]; then
        for f in /cdrom/casper/*.squashfs /run/casper/*.squashfs; do
            [ -f "$f" ] || continue
            SQUASHFS=$f
            break
        done
    fi
    [ -n "$SQUASHFS" ] && [ -f "$SQUASHFS" ] || {
        echo "recovery: no live rootfs found; set SQUASHFS=/path/to/*.squashfs" >&2
        exit 1
    }
    [ -d "$ISO_POOL" ] || {
        echo "recovery: missing ISO package pool $ISO_POOL" >&2
        exit 1
    }
    command -v unsquashfs >/dev/null || {
        echo "recovery: unsquashfs is not installed" >&2
        exit 1
    }
    command -v dpkg-deb >/dev/null || {
        echo "recovery: dpkg-deb is not installed" >&2
        exit 1
    }
    [ -n "$GRUB_SIGNED_DEB" ] || GRUB_SIGNED_DEB=$(find "$ISO_POOL" \
        -name 'grub-efi-arm64-signed_*.deb' -print -quit)
    [ -n "$GRUB_MODULES_DEB" ] || GRUB_MODULES_DEB=$(find "$ISO_POOL" \
        -name 'grub-efi-arm64-bin_*.deb' -print -quit)
    [ -n "$SHIM_SIGNED_DEB" ] || SHIM_SIGNED_DEB=$(find "$ISO_POOL" \
        -name 'shim-signed_*.deb' -print -quit)
    [ -f "$GRUB_SIGNED_DEB" ] || {
        echo "recovery: grub-efi-arm64-signed .deb not found in $ISO_POOL" >&2
        exit 1
    }
    [ -f "$GRUB_MODULES_DEB" ] || {
        echo "recovery: grub-efi-arm64-bin .deb not found in $ISO_POOL" >&2
        exit 1
    }
    if [ -z "$SHIM_SIGNED_DEB" ] || [ ! -f "$SHIM_SIGNED_DEB" ]; then
        echo "recovery: WARN: shim-signed .deb not found in $ISO_POOL" >&2
        echo "  EFI/ubuntu/shimaa64.efi will be missing; Secure Boot must be off" >&2
    fi
else
    command -v debootstrap >/dev/null || {
        echo "recovery: debootstrap is not installed (run scripts/setup.sh)" >&2
        exit 1
    }
fi

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo -n); fi

ESPDEV=$(find_esp "$DISK")
ROOTDEV=$(find_ubuntu_root "$DISK")
[ -n "$ESPDEV" ] || { echo "recovery: no EFI System partition on $DISK" >&2; exit 1; }
[ -n "$ROOTDEV" ] || { echo "recovery: no ext2/3/4 recovery partition on $DISK" >&2; exit 1; }
[ "$ESPDEV" != "$ROOTDEV" ] || {
    echo "recovery: the ESP and the recovery root are the same partition" >&2
    exit 1
}

if [ -z "$RELEASE" ]; then
    for f in /etc/os-release /usr/lib/os-release; do
        [ -f "$f" ] || continue
        RELEASE=$(sed -n 's/^VERSION_CODENAME=//p' "$f" | tr -d '"' | head -1)
        [ -n "$RELEASE" ] && break
    done
fi
if [ "$OFFLINE" = 1 ]; then
    echo "recovery: offline install from $SQUASHFS"
else
    [ -n "$RELEASE" ] || {
        echo "recovery: cannot determine the Ubuntu release; set RELEASE=noble" >&2
        exit 1
    }
    echo "recovery: release $RELEASE, mirror $MIRROR"
fi

MNT=$(mktemp -d /tmp/recovery.XXXXXX)
TMPDIRS=()
BINDS=()
cleanup() {
    set +e
    # -R because /sys and /dev bring nested submounts (efivarfs, devpts);
    # a plain umount leaves the whole tree behind when the guest has EFI
    # variables mounted.
    for (( i=${#BINDS[@]}-1; i>=0; i-- )); do
        "${SUDO[@]}" umount -R "$MNT/${BINDS[$i]}" 2>/dev/null
    done
    mountpoint -q "$MNT/boot/efi" && "${SUDO[@]}" umount "$MNT/boot/efi" 2>/dev/null
    mountpoint -q "$MNT" && "${SUDO[@]}" umount -R "$MNT" 2>/dev/null
    cleanup_part_loops
    for d in "${TMPDIRS[@]}"; do
        "${SUDO[@]}" rm -rf "$d" 2>/dev/null
    done
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

TMP=$(mktemp -d /tmp/recovery-work.XXXXXX)
TMPDIRS+=("$TMP")

"${SUDO[@]}" mount "$ROOTDEV" "$MNT"
ROOT_UUID=$("${SUDO[@]}" blkid -s UUID -o value "$ROOTDEV")
ESP_UUID=$("${SUDO[@]}" blkid -s UUID -o value "$ESPDEV")
[ -n "$ROOT_UUID" ] || { echo "recovery: $ROOTDEV has no UUID" >&2; exit 1; }
[ -n "$ESP_UUID" ] || { echo "recovery: $ESPDEV has no UUID" >&2; exit 1; }

if [ "$OFFLINE" = 1 ]; then
    echo "[1/6] unpack the live ISO rootfs"
    # The image was built for the live session, so overwrite anything that
    # is already there (normally only lost+found).  -xattrs keeps file
    # capabilities such as ping's.
    "${SUDO[@]}" unsquashfs -no-progress -xattrs -f -d "$MNT" "$SQUASHFS"
    if [ -f "$MNT/etc/os-release" ]; then
        RELEASE=$(sed -n 's/^VERSION_CODENAME=//p' "$MNT/etc/os-release" | tr -d '"' | head -1)
    fi
    RELEASE=${RELEASE:-resolute}

    # The live image has no sshd.  Every dependency of the server package
    # is already part of the minimal rootfs, so dpkg can install it offline.
    echo "[2/6] add openssh-server from the ISO pool"
    DEBS=()
    for name in libwrap0 openssh-server openssh-sftp-server; do
        deb=$(find "$ISO_POOL" -name "${name}_*.deb" -print -quit)
        [ -n "$deb" ] || {
            echo "recovery: ${name} .deb not found in $ISO_POOL" >&2
            exit 1
        }
        "${SUDO[@]}" cp "$deb" "$MNT/var/tmp/"
        DEBS+=("/var/tmp/$(basename "$deb")")
    done
    printf '#!/bin/sh\nexit 101\n' > "$TMP/policy-rc.d"
    "${SUDO[@]}" install -m 755 "$TMP/policy-rc.d" "$MNT/usr/sbin/policy-rc.d"

    # The minimal image ships 3cpio and the kernel, but not the mkinitramfs
    # wrapper.  Copy the two packages' files from the running live system;
    # the casper hook is not among them, so the generated initramfs boots a
    # normal root instead of looking for a live medium.
    for pkg in initramfs-tools initramfs-tools-core; do
        while IFS= read -r f; do
            case "$f" in
                /etc|/etc/*|/usr/share/doc*|/usr/share/man*|/usr/share/bug*|/usr/share/bash-completion*) continue ;;
            esac
            if [ -d "$f" ] && [ ! -L "$f" ]; then continue; fi
            [ -e "$f" ] || [ -L "$f" ] || continue
            "${SUDO[@]}" cp -a --parents "$f" "$MNT/"
        done < <(dpkg-query -L "$pkg" 2>/dev/null)
    done
else
    echo "[1/6] debootstrap $RELEASE"
    # debootstrap refuses a non-empty target, so the ESP is mounted only
    # after the base system exists (see [3/6]).
    "${SUDO[@]}" debootstrap --arch=arm64 --variant=minbase \
        --components=main,universe "$RELEASE" "$MNT" "$MIRROR"
fi

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
# Replace, do not write through, a symlink to /run (the live image uses one).
"${SUDO[@]}" rm -f "$MNT/etc/resolv.conf"
"${SUDO[@]}" cp /etc/resolv.conf "$MNT/etc/resolv.conf"

run() { "${SUDO[@]}" chroot "$MNT" env DEBIAN_FRONTEND=noninteractive "$@"; }

# Write the fstab before building the initramfs: mkinitramfs and its resume
# hook read /etc/fstab, and the live rootfs ships without one.
"${SUDO[@]}" tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077         0 1
EOF

if [ "$OFFLINE" = 1 ]; then
    echo "[2/6] install the offline package set"
    run dpkg -i "${DEBS[@]}"
    "${SUDO[@]}" rm -f "$MNT/usr/sbin/policy-rc.d"

    KVER=$(find "$MNT/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort -V | tail -1)
    [ -n "$KVER" ] || { echo "recovery: no kernel modules in the ISO rootfs" >&2; exit 1; }
    [ -e "$MNT/boot/vmlinuz-$KVER" ] || {
        echo "recovery: no /boot/vmlinuz-$KVER in the ISO rootfs" >&2
        exit 1
    }
    echo "  generating initramfs for $KVER (inside the target)"
    run mkinitramfs -o "/boot/initrd.img-$KVER" "$KVER"
    "${SUDO[@]}" ln -sfn "initrd.img-$KVER" "$MNT/boot/initrd.img"
else
    echo "[2/6] install the minimal package set"
    run apt-get update
    # --no-install-recommends keeps linux-firmware and snapd out; the whole
    # rootfs has to fit in 4 GiB.
    run apt-get install -y --no-install-recommends \
        linux-image-generic initramfs-tools systemd-sysv \
        openssh-server netplan.io sudo ca-certificates \
        iproute2 iputils-ping less vim-tiny e2fsprogs kmod
fi

echo "[3/6] GRUB (EFI)"
"${SUDO[@]}" mkdir -p "$MNT/boot/efi"
mountpoint -q "$MNT/boot/efi" || "${SUDO[@]}" mount "$ESPDEV" "$MNT/boot/efi"

if [ "$OFFLINE" = 1 ]; then
    # Use the signed image from the ISO pool and put the signed shim next to
    # it.  No grub-install (and no NVRAM write) is needed; finish_winpe.sh
    # installs the shim/GRUB pair in EFI/BOOT and GRUB reads the menu from
    # EFI/ubuntu/grub.cfg.
    "${SUDO[@]}" dpkg-deb -x "$GRUB_SIGNED_DEB" "$TMP/grub-signed"
    "${SUDO[@]}" dpkg-deb -x "$GRUB_MODULES_DEB" "$TMP/grub-bin"
    "${SUDO[@]}" install -D -m 644 \
        "$TMP/grub-signed/usr/lib/grub/arm64-efi-signed/grubaa64.efi.signed" \
        "$MNT/boot/efi/EFI/ubuntu/grubaa64.efi"
    if [ -n "$SHIM_SIGNED_DEB" ] && [ -f "$SHIM_SIGNED_DEB" ]; then
        "${SUDO[@]}" dpkg-deb -x "$SHIM_SIGNED_DEB" "$TMP/shim-signed"
        if [ -f "$TMP/shim-signed/usr/lib/shim/shimaa64.efi" ]; then
            "${SUDO[@]}" install -D -m 644 \
                "$TMP/shim-signed/usr/lib/shim/shimaa64.efi" \
                "$MNT/boot/efi/EFI/ubuntu/shimaa64.efi"
        else
            echo "  WARN: shimaa64.efi is not in $SHIM_SIGNED_DEB" >&2
        fi
    fi
    "${SUDO[@]}" mkdir -p "$MNT/boot/grub"
    "${SUDO[@]}" cp -a "$TMP/grub-bin/usr/lib/grub/arm64-efi" "$MNT/boot/grub/"

    # The signed binary's built-in prefix is /EFI/ubuntu.  Its first config
    # only finds the recovery root and hands over to the menu below.
    "${SUDO[@]}" tee "$MNT/boot/efi/EFI/ubuntu/grub.cfg" >/dev/null <<EOF
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
EOF
    # The EFI console is already the OCI serial console; GRUB's own serial
    # driver is an x86 COM-port driver and errors out on ARM64.
    "${SUDO[@]}" tee "$MNT/boot/grub/grub.cfg" >/dev/null <<EOF
set timeout=5
set default=0

menuentry "Ubuntu (recovery)" {
    insmod ext2
    insmod part_gpt
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro console=ttyAMA0,115200 console=tty1
    initrd /boot/initrd.img-$KVER
}
EOF
else
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
GRUB_TERMINAL="console"
GRUB_DISABLE_OS_PROBER=true
EOF
    run update-grub || echo "  WARN: update-grub failed"
fi

echo "[4/6] create the ubuntu account and install authorized_keys"
[ -e "$MNT/etc/localtime" ] || \
    "${SUDO[@]}" ln -sf /usr/share/zoneinfo/UTC "$MNT/etc/localtime"

PASSWORD_GENERATED=0
if [ -z "$RECOVERY_PASSWORD" ]; then
    # head closes the pipe early, so swallow the SIGPIPE status.
    RECOVERY_PASSWORD=$( (tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16) || true )
    PASSWORD_GENERATED=1
fi
if run id -u ubuntu >/dev/null 2>&1; then
    run usermod -aG sudo ubuntu
else
    run useradd -m -s /bin/bash -G sudo ubuntu
fi
echo "ubuntu:$RECOVERY_PASSWORD" | "${SUDO[@]}" chroot "$MNT" chpasswd
CREATED=" ubuntu"

KEY_SRC=""
for f in /home/ubuntu/.ssh/authorized_keys /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do
    "${SUDO[@]}" test -s "$f" || continue
    KEY_SRC=$f
    break
done
if [ -n "$KEY_SRC" ]; then
    TARGET_UID=$(run id -u ubuntu)
    TARGET_GID=$(run id -g ubuntu)
    "${SUDO[@]}" install -d -m 700 -o "$TARGET_UID" -g "$TARGET_GID" \
        "$MNT/home/ubuntu/.ssh"
    "${SUDO[@]}" install -m 600 -o "$TARGET_UID" -g "$TARGET_GID" \
        "$KEY_SRC" "$MNT/home/ubuntu/.ssh/authorized_keys"
    echo "  authorized_keys from $KEY_SRC"
else
    echo "  WARN: no non-empty authorized_keys found; use the password above" >&2
fi

echo "[5/6] netplan, SSH, fstab"
"${SUDO[@]}" mkdir -p "$MNT/etc/netplan"
"${SUDO[@]}" rm -f "$MNT"/etc/netplan/*.yaml
if compgen -G '/etc/netplan/*.yaml' >/dev/null; then
    "${SUDO[@]}" cp -a /etc/netplan/*.yaml "$MNT/etc/netplan/"
    echo "  copied $(ls -1 /etc/netplan/*.yaml | wc -l) netplan file(s) from /etc/netplan"
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
    echo "  no netplan on the running system; wrote a DHCP match for en*"
fi
"${SUDO[@]}" chmod 600 "$MNT"/etc/netplan/*.yaml

# New host keys on first boot are expected: this is a fresh recovery system,
# not a copy of the machine that ran the build.
run ssh-keygen -A >/dev/null 2>&1 || echo "  WARN: ssh-keygen -A failed" >&2

run systemctl enable systemd-networkd >/dev/null 2>&1 || true
run systemctl enable ssh >/dev/null 2>&1 || true
run systemctl enable serial-getty@ttyAMA0 >/dev/null 2>&1 || true
"${SUDO[@]}" rm -f "$MNT/etc/resolv.conf"
"${SUDO[@]}" tee "$MNT/etc/resolv.conf" >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "[6/6] clean up and verify"
run apt-get clean || true
"${SUDO[@]}" rm -rf "$MNT/var/lib/apt/lists"/* "$MNT/var/cache/apt/archives"/*.deb "$MNT/tmp"/*
"${SUDO[@]}" mkdir -p "$MNT/var/lib/apt/lists/partial"
if [ "$OFFLINE" = 0 ]; then
    run update-initramfs -u -k all >/dev/null 2>&1 || echo "  WARN: update-initramfs failed"
fi
"${SUDO[@]}" sync

"${SUDO[@]}" df -h "$MNT" | sed -n '1,2p'
"${SUDO[@]}" test -f "$MNT/boot/efi/EFI/ubuntu/grubaa64.efi" || \
    echo "  WARN: \\EFI\\ubuntu\\grubaa64.efi is missing on the ESP" >&2
"${SUDO[@]}" test -f "$MNT/boot/efi/EFI/ubuntu/shimaa64.efi" || \
    echo "  WARN: \\EFI\\ubuntu\\shimaa64.efi is missing on the ESP" >&2
if [ "$OFFLINE" = 1 ]; then
    "${SUDO[@]}" test -f "$MNT/boot/grub/grub.cfg" || \
        echo "  WARN: /boot/grub/grub.cfg is missing" >&2
    "${SUDO[@]}" test -f "$MNT/boot/initrd.img-$KVER" || \
        echo "  WARN: /boot/initrd.img-$KVER is missing" >&2
fi

echo
echo "OK: recovery Ubuntu installed on $ROOTDEV"
echo "    accounts:$CREATED"
if [ -n "$KEY_SRC" ]; then
    echo "    SSH: ubuntu with authorized_keys from $KEY_SRC"
else
    echo "    SSH: no authorized_keys; use the serial console"
fi
[ "$PASSWORD_GENERATED" = 1 ] && \
    echo "    generated password for ubuntu: $RECOVERY_PASSWORD"
echo "    GRUB is the first loader; Windows 11 is chainloaded from it"
