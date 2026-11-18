#!/usr/bin/env bash
# Boot the Windows 11 ARM64 installer / installed disk under QEMU TCG.
#
#   ISO=/path/to/Win11_ARM64.iso ./run-qemu.sh      # first boot from ISO
#   BOOT=disk ./run-qemu.sh                         # later boot from disk
#
# The target is a qcow2 file by default.  DISK=/dev/sdX uses a raw block
# device; the caller is responsible for what that device contains.
# QEMU options are single array elements that contain commas.
# shellcheck disable=SC2054,SC2206
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BUILD=${BUILD_DIR:-$ROOT/build}
NAME=${NAME:-install}
ISO=${ISO:-}
DISK=${DISK:-$BUILD/win11-arm64.qcow2}
OEMDRV=${OEMDRV-$BUILD/oemdrv.iso}
BOOTFAT=${BOOTFAT:-}
BOOTFAT_BUS=${BOOTFAT_BUS:-scsi}
MEM=${MEM:-8192}
SMP=${SMP:-4}
BOOT=${BOOT:-iso}
WITH_ISO=${WITH_ISO:-1}
ISO_BUS=${ISO_BUS:-scsi}
VNC_DISPLAY=${VNC_DISPLAY:-1}
RDP_PORT=${RDP_PORT:-13389}
WINRM_PORT=${WINRM_PORT:-15985}
FW_CODE=${FW_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
FW_VARS_SRC=${FW_VARS_SRC:-/usr/share/AAVMF/AAVMF_VARS.fd}
NVRAM=${NVRAM:-$BUILD/AAVMF_VARS.$NAME.fd}
SERIAL=$BUILD/logs/$NAME-serial.log
SERIAL_SOCK=${SERIAL_SOCK:-}
QEMU_LOG=$BUILD/logs/$NAME-qemu.log
QDBG=$BUILD/logs/$NAME-qdbg.log
QMP=$BUILD/$NAME.qmp
MON=$BUILD/$NAME.mon
PIDFILE=$BUILD/$NAME.pid

mkdir -p "$BUILD/logs" "$BUILD/shots"
[ -f "$FW_CODE" ] || { echo "missing firmware: $FW_CODE" >&2; exit 1; }
[ -f "$FW_VARS_SRC" ] || { echo "missing vars: $FW_VARS_SRC" >&2; exit 1; }
if [ "$WITH_ISO" = "1" ]; then
    [ -f "$ISO" ] || { echo "missing ISO: $ISO" >&2; exit 1; }
fi
if [ -n "$OEMDRV" ] && [ ! -f "$OEMDRV" ]; then
    echo "missing OEMDRV image: $OEMDRV" >&2
    exit 1
fi
if [ -n "$BOOTFAT" ]; then
    [ -f "$BOOTFAT" ] || { echo "missing BOOTFAT image: $BOOTFAT" >&2; exit 1; }
fi

DISK_FORMAT=qcow2
DISK_CACHE=""
if [ -b "$DISK" ]; then
    DISK_FORMAT=raw
    DISK_CACHE=",cache=none"
    [ -w "$DISK" ] || { echo "no write access to $DISK (run as root)" >&2; exit 1; }
elif [ ! -e "$DISK" ]; then
    echo "[disk] creating $DISK (50G qcow2)"
    qemu-img create -f qcow2 "$DISK" 50G >/dev/null
fi
if [ ! -f "$NVRAM" ]; then
    echo "[nvram] creating $NVRAM"
    cp "$FW_VARS_SRC" "$NVRAM"
fi

rm -f "$QMP" "$MON" "$PIDFILE"

# QEMU aarch64/virt has no -boot drive-order support.  A blank disk + ISO
# attached makes AAVMF boot the ISO; for the installed-disk phase use
# WITH_ISO=0 so the firmware falls through to the disk's boot entry.
# ACCEL=auto uses KVM when /dev/kvm is usable (OCI A1 with nested virt),
# otherwise TCG.  Override with ACCEL=kvm or ACCEL=tcg.
ACCEL=${ACCEL:-auto}
if [ "$ACCEL" = auto ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL=kvm
    else
        ACCEL=tcg
    fi
fi
case "$ACCEL" in
    kvm) ACCEL_ARGS=(-accel kvm -cpu host) ;;
    tcg) ACCEL_ARGS=(-accel tcg,thread=multi -cpu neoverse-n1) ;;
    *)   echo "ACCEL must be auto, kvm or tcg" >&2; exit 1 ;;
esac
echo "[qemu] accel=$ACCEL smp=$SMP mem=$MEM"

QEMU=(qemu-system-aarch64
    -name "$NAME"
    -machine virt,gic-version=3
    "${ACCEL_ARGS[@]}"
    -smp "$SMP"
    -m "$MEM"
    -drive if=pflash,format=raw,readonly=on,file="$FW_CODE"
    -drive if=pflash,format=raw,file="$NVRAM"
    -device qemu-xhci,id=xhci
    -device usb-kbd
    -device usb-tablet
    -drive "if=none,id=disk0,format=$DISK_FORMAT,file=$DISK$DISK_CACHE"
    -device virtio-scsi-pci,id=scsi0
    -device scsi-hd,drive=disk0,bus=scsi0.0,channel=0,scsi-id=0,lun=0,bootindex=1
    -device virtio-net-pci,netdev=n0
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${RDP_PORT}-:3389,hostfwd=tcp:127.0.0.1:${WINRM_PORT}-:5985
    -device virtio-gpu-pci,id=gpu0
    -device ramfb,id=ramfb0
    -device virtio-rng-pci
    -display none
    -vnc 127.0.0.1:${VNC_DISPLAY}
    -monitor unix:"$MON",server,nowait
    -qmp unix:"$QMP",server,nowait
    -d guest_errors
    -D "$QDBG")

# Interactive serial for GRUB menu tests (SERIAL_SOCK=/path/to.sock).
# OCI's serial console is bidirectional; a plain file cannot send keys.
if [ -n "$SERIAL_SOCK" ]; then
    mkdir -p "$(dirname "$SERIAL_SOCK")"
    QEMU+=(-chardev "socket,id=ser0,path=$SERIAL_SOCK,server=on,wait=off,logfile=$SERIAL")
    QEMU+=(-serial chardev:ser0)
else
    QEMU+=(-serial file:"$SERIAL")
fi

# Optional FAT boot image carrying the ISO's own boot manager + boot.wim.
# It is attached before OEMDRV so AAVMF sees it first among USB disks.
if [ -n "$BOOTFAT" ]; then
    QEMU+=(-drive if=none,id=bootfat,format=raw,readonly=on,file="$BOOTFAT")
    case "$BOOTFAT_BUS" in
        # AAVMF's VirtioBlkDxe binds the modern device (0x1042), not the
        # transitional 0x1001 that plain virtio-blk-pci creates here.
        virtio) QEMU+=(-device virtio-blk-pci-non-transitional,drive=bootfat,bootindex=0) ;;
        scsi)   QEMU+=(-device scsi-hd,drive=bootfat,bus=scsi0.0,channel=0,scsi-id=2,lun=0,bootindex=0) ;;
        usb)    QEMU+=(-device usb-storage,drive=bootfat,bus=xhci.0,bootindex=0) ;;
        *)      echo "BOOTFAT_BUS must be virtio, scsi or usb" >&2; exit 1 ;;
    esac
fi
if [ -n "$OEMDRV" ]; then
    OEMDRV_MEDIA=${OEMDRV_MEDIA:-auto}
    if [ "$OEMDRV_MEDIA" = "auto" ]; then
        case "$OEMDRV" in
            *.iso) OEMDRV_MEDIA=cdrom ;;
            *)     OEMDRV_MEDIA=usb ;;
        esac
    fi
    case "$OEMDRV_MEDIA" in
        cdrom) QEMU+=(-drive if=none,id=oem,media=cdrom,readonly=on,file="$OEMDRV"
                      -device usb-storage,drive=oem,bus=xhci.0) ;;
        usb)   QEMU+=(-drive if=none,id=oem,format=raw,file="$OEMDRV"
                      -device usb-storage,drive=oem,bus=xhci.0) ;;
        *)     echo "OEMDRV_MEDIA must be cdrom or usb" >&2; exit 1 ;;
    esac
fi

if [ "$WITH_ISO" = "1" ]; then
    QEMU+=(-drive if=none,id=cd0,media=cdrom,readonly=on,file="$ISO")
    case "$ISO_BUS" in
        scsi)  QEMU+=(-device scsi-cd,drive=cd0,bus=scsi0.0,channel=0,scsi-id=1,lun=0) ;;
        usb)   QEMU+=(-device usb-storage,drive=cd0,bus=xhci.0) ;;
        *)     echo "ISO_BUS must be scsi or usb" >&2; exit 1 ;;
    esac
fi

echo "[qemu] disk=$DISK"
echo "[qemu] iso=$([ "$WITH_ISO" = 1 ] && echo "$ISO" || echo '<detached>')"
echo "[qemu] oemdrv=$OEMDRV"
echo "[qemu] boot=$BOOT with_iso=$WITH_ISO vnc=127.0.0.1:${VNC_DISPLAY} rdp=127.0.0.1:${RDP_PORT} winrm=127.0.0.1:${WINRM_PORT}"
echo "[qemu] serial=$SERIAL"
[ -n "$SERIAL_SOCK" ] && echo "[qemu] serial_sock=$SERIAL_SOCK"
echo "[qemu] qmp=$QMP monitor=$MON"
echo "$$" > "$PIDFILE"
exec "${QEMU[@]}" >"$QEMU_LOG" 2>&1
