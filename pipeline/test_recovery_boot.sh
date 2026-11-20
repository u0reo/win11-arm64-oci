#!/usr/bin/env bash
# Boot the recovery Ubuntu from the finished disk and fail if systemd falls
# into emergency mode.  This is the end-to-end counterpart of the fstab/ESP
# comparison in inspect_image.sh.
#
#   ./pipeline/test_recovery_boot.sh /path/to/disk.qcow2 | /dev/sdX
#
# GRUB is bypassed on purpose: QEMU loads the kernel and initrd named in the
# final GRUB menu directly, so no keystrokes have to be injected through the
# serial console.  systemd still reads /etc/fstab from the root filesystem,
# which is exactly what this test needs to exercise.  Only console=ttyAMA0 is
# passed, so the emergency shell and the login prompt both appear on serial.
#
# TCG is slow (a full boot can take ~15 minutes), so BOOT_TIMEOUT defaults to
# 1800s.  Temporary kernel/initrd files live in /tmp (use a tmpfs if the build
# host is short on disk).  The disk is opened read-only by QEMU.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"
IMG=${1:?usage: $0 <disk.qcow2|disk.raw|/dev/sdX>}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1800}
MEM=${MEM:-2048}
SMP=${SMP:-2}

[ -f "$IMG" ] || [ -b "$IMG" ] || { echo "missing $IMG" >&2; exit 1; }
if [ -b "$IMG" ] && [ ! -r "$IMG" ]; then
    echo "test-recovery-boot: no read access to $IMG (run as root)" >&2
    exit 1
fi
command -v qemu-system-aarch64 >/dev/null 2>&1 || {
    echo "test-recovery-boot: qemu-system-aarch64 not found" >&2
    exit 1
}

WORK=$(mktemp -d /tmp/recovery-boot.XXXXXX)
NBD=0
LOOP=""
QEMU_PID=""
cleanup() {
    set +e
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "$QEMU_PID" ] && wait "$QEMU_PID" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    [ -n "$LOOP" ] && sudo -n losetup -d "$LOOP" >/dev/null 2>&1
    cleanup_part_loops
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "[boot-test] examining $IMG"
if [[ "$IMG" == *.qcow2 ]]; then
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    sudo -n qemu-nbd --connect=/dev/nbd0 --format=qcow2 --read-only "$IMG"
    DEV=/dev/nbd0
    NBD=1
    FMT=qcow2
elif [ -b "$IMG" ]; then
    DEV=$IMG
    FMT=raw
else
    LOOP=$(sudo -n losetup --find --show --partscan --read-only "$IMG")
    DEV=$LOOP
    FMT=raw
fi
sudo -n partprobe "$DEV" 2>/dev/null || true
sleep 1

ESPDEV=$(find_esp "$DEV")
ROOTDEV=$(find_ubuntu_root "$DEV")
[ -n "$ESPDEV" ] || { echo "no ESP found on $DEV" >&2; exit 1; }
[ -n "$ROOTDEV" ] || { echo "no Ubuntu recovery root found on $DEV" >&2; exit 1; }

ESP=$WORK/esp
ROOT=$WORK/root
mkdir -p "$ESP" "$ROOT"
sudo -n mount -t vfat -o ro,umask=000 "$ESPDEV" "$ESP"
sudo -n mount -t ext4 -o ro "$ROOTDEV" "$ROOT"

MENU="$ESP/EFI/ubuntu/grub.cfg"
[ -f "$MENU" ] || { echo "no $MENU; cannot find the recovery kernel" >&2; exit 1; }
KERNEL=$(sed -n 's/^[[:space:]]*linux[[:space:]]\+\/boot\/\(vmlinuz-[^[:space:]]*\).*/\1/p' "$MENU" | head -1)
INITRD=$(sed -n 's/^[[:space:]]*initrd[[:space:]]\+\/boot\/\(initrd.img-[^[:space:]]*\).*/\1/p' "$MENU" | head -1)
ROOT_UUID=$(sed -n 's/.*root=UUID=\([^[:space:]]*\).*/\1/p' "$MENU" | head -1)
if [ -z "$KERNEL" ] || [ -z "$INITRD" ] || [ -z "$ROOT_UUID" ]; then
    echo "test-recovery-boot: cannot parse the Ubuntu entry from $MENU" >&2
    exit 1
fi
for f in "$KERNEL" "$INITRD"; do
    [ -f "$ROOT/boot/$f" ] || {
        echo "test-recovery-boot: $ROOT/boot/$f is missing" >&2
        exit 1
    }
done
# The kernel is mode 0600 in the recovery image, so copy it as root.
sudo -n cp "$ROOT/boot/$KERNEL" "$WORK/vmlinuz"
sudo -n cp "$ROOT/boot/$INITRD" "$WORK/initrd"
sudo -n umount "$ROOT"
sudo -n umount "$ESP"
if [ "$NBD" = 1 ]; then
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    NBD=0
fi

SERIAL=$WORK/serial.log
: > "$SERIAL"
ACCEL_ARGS=(-accel tcg,thread=multi -cpu neoverse-n1)
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_ARGS=(-accel kvm -cpu host)
fi
QEMU=(qemu-system-aarch64
    -name recovery-boot-test
    -machine virt,gic-version=3
    "${ACCEL_ARGS[@]}"
    -smp "$SMP" -m "$MEM"
    -kernel "$WORK/vmlinuz"
    -initrd "$WORK/initrd"
    -append "root=UUID=$ROOT_UUID ro console=ttyAMA0,115200"
    -drive "if=none,id=disk0,format=$FMT,file=$IMG,readonly=on"
    -device virtio-scsi-pci,id=scsi0
    -device scsi-hd,drive=disk0,bus=scsi0.0
    -display none
    -serial "file:$SERIAL")

echo "[boot-test] starting QEMU (timeout ${BOOT_TIMEOUT}s)"
"${QEMU[@]}" >"$WORK/qemu.log" 2>&1 &
QEMU_PID=$!

deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
result=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        result=exited
        break
    fi
    if grep -qE 'Welcome to emergency mode|dependency failed for|Failed to mount /boot/efi' "$SERIAL"; then
        result=emergency
        break
    fi
    if grep -qE '^[^ ]+ login:| login: $' "$SERIAL"; then
        result=login
        break
    fi
    sleep 5
done

case "$result" in
    login)
        echo "[boot-test] OK: recovery Ubuntu reached login: with no emergency mode"
        ;;
    emergency)
        echo "[boot-test] FAIL: recovery Ubuntu entered emergency mode" >&2
        tail -40 "$SERIAL" >&2
        exit 1
        ;;
    exited)
        echo "[boot-test] FAIL: QEMU exited before the login prompt" >&2
        tail -40 "$SERIAL" >&2
        tail -20 "$WORK/qemu.log" >&2
        exit 1
        ;;
    *)
        echo "[boot-test] FAIL: no login prompt within ${BOOT_TIMEOUT}s" >&2
        tail -40 "$SERIAL" >&2
        exit 1
        ;;
esac
