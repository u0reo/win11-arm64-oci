#!/usr/bin/env bash
# End-to-end image build.  This is internal: normal use goes through
# scripts/build.sh, which adds the safety checks and the confirmation.
#
# The target is a qcow2 file by default:
#
#   ISO=/srv/iso/Win11_ARM64_26H2.iso VIRTIO_ISO=/srv/iso/virtio-win.iso \
#     internal/build-image.sh
#
# To write straight onto a block device instead (no qcow2, no packaging):
#
#   sudo DISK=/dev/sdb ISO=... VIRTIO_ISO=... internal/build-image.sh
#
# A block device is wiped.  scripts/build.sh is the supported entry point.
#
# Required:
#   ISO=/path/to/Win11_ARM64.iso
#   VIRTIO_ISO=/path/to/virtio-win.iso   (or VIRTIO_RPM=/path/to/virtio-win.rpm,
#                                         or DRIVERS_DIR=/path/to/drivers)
#
# Optional:
#   DISK=/dev/sdX        target block device (default: build/win11-arm64.qcow2)
#   IMAGE_INDEX=1        WIM index
#   SIZE=50G             qcow2 virtual size (ignored for a block device)
#   MEM=8192             guest RAM in MiB
#   SMP=4                guest vCPUs
#   KEEP_UBUNTU=1        keep the ESP (found by GPT type) and replace the
#                        Ubuntu root/BOOT with a recovery system + Windows
#   RECOVERY_SIZE=4G     size of that recovery partition
#   REUSE_UBUNTU=1       p2 is an installed Ubuntu; only use the free space
#   BOOT_MENU_TIMEOUT=1  seconds to show the Windows boot menu (0 = off)
#   PACKAGE=1            compress the qcow2 when the build finishes
#   WIN_USERNAME / WIN_PASSWORD / COMPUTER_NAME   (render.py overrides)
#
# On live (toram), BUILD_DIR defaults to /dev/shm/build and /dev/shm is
# remounted at SHM_SIZE (default 100% of RAM) when possible.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=live.sh
. "$HERE/live.sh"
BUILD=$(default_build_dir "$ROOT/build")
PIPE="$ROOT/pipeline"

ISO=${ISO:?set ISO=/path/to/Win11_ARM64.iso}
IMAGE_INDEX=${IMAGE_INDEX:-1}
SIZE=${SIZE:-50G}
MEM=${MEM:-8192}
SMP=${SMP:-4}
SHM_SIZE=${SHM_SIZE:-100%}
WINRM_PORT=${WINRM_PORT:-15985}
DISK=${DISK:-$ROOT/build/win11-arm64.qcow2}
KEEP_UBUNTU=${KEEP_UBUNTU:-0}
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}
# 1 s by default; any key press stops the countdown.  0 turns the menu off.
BOOT_MENU_TIMEOUT=${BOOT_MENU_TIMEOUT:-1}
case "$BOOT_MENU_TIMEOUT" in
    ''|*[!0-9]*) ;;   # render.py reports a proper error for non-numbers
    *) BOOT_MENU_TIMEOUT=$((10#$BOOT_MENU_TIMEOUT)) ;;
esac
if [ "$BOOT_MENU_TIMEOUT" = 0 ] && { [ "$KEEP_UBUNTU" = 1 ] || [ "$REUSE_UBUNTU" = 1 ]; }; then
    echo "BOOT_MENU_TIMEOUT=0 would hide the Ubuntu recovery entry" >&2
    exit 1
fi
export BOOT_MENU_TIMEOUT

if is_live_ram && ! live_shm_max; then
    echo "build: warning: could not remount /dev/shm at $SHM_SIZE" >&2
fi

RAW=0
if [ -b "$DISK" ]; then
    RAW=1
fi
# If DISK was left at the default under $ROOT/build but BUILD moved, keep them together.
if [ "$DISK" = "$ROOT/build/win11-arm64.qcow2" ] && [ "$BUILD" != "$ROOT/build" ]; then
    DISK="$BUILD/win11-arm64.qcow2"
fi
if [ "$KEEP_UBUNTU" = 1 ] && [ "$RAW" != 1 ]; then
    echo "KEEP_UBUNTU needs DISK=/dev/sdX (the Ubuntu volume itself)" >&2
    exit 1
fi
if [ "$REUSE_UBUNTU" = 1 ] && [ "$RAW" != 1 ]; then
    echo "REUSE_UBUNTU needs DISK=/dev/sdX (the installed Ubuntu disk)" >&2
    exit 1
fi
if [ "$REUSE_UBUNTU" = 1 ] && [ "$KEEP_UBUNTU" = 1 ]; then
    echo "REUSE_UBUNTU and KEEP_UBUNTU are mutually exclusive" >&2
    exit 1
fi

# Auto-select a roomy tmpfs for staging when the default build dir is tight.
if [ -z "${BUILD_DIR:-}" ]; then
    _need=${MIN_FREE_GB:-$([ "$RAW" = 1 ] && echo 3 || echo 80)}
    _parent=$(dirname "$BUILD")
    mkdir -p "$_parent" 2>/dev/null || true
    _free=$(df -Pk "$_parent" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
    _free=${_free:-0}
    if [ "$_free" -lt "$_need" ]; then
        for cand in /dev/shm /tmp; do
            [ -d "$cand" ] || continue
            _cfree=$(df -Pk "$cand" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
            _cfree=${_cfree:-0}
            if [ "$_cfree" -ge "$_need" ]; then
                echo "build: staging dir low on space (${_free} GiB < ${_need} GiB); using BUILD_DIR=$cand/build"
                BUILD="$cand/build"
                [ "$DISK" = "$ROOT/build/win11-arm64.qcow2" ] && DISK="$BUILD/win11-arm64.qcow2"
                break
            fi
        done
    fi
fi
if is_live_ram && [ -z "${BUILD_DIR:-}" ] && [ "$BUILD" = /dev/shm/build ]; then
    echo "build: live/toram: staging is $BUILD (media: /dev/shm/iso)"
fi
export BUILD_DIR="$BUILD"

mkdir -p "$BUILD/logs" "$BUILD/artifacts"
LOG="$BUILD/logs/build.log"
exec > >(tee -a "$LOG") 2>&1

step() { echo; echo "==== $* ===="; }

step "0/13 preflight"
PREFLIGHT_MEDIA=()
[ -n "${VIRTIO_ISO:-}" ] && PREFLIGHT_MEDIA+=(VIRTIO_ISO="$VIRTIO_ISO")
[ -n "${VIRTIO_RPM:-}" ] && PREFLIGHT_MEDIA+=(VIRTIO_RPM="$VIRTIO_RPM")
[ -n "${DRIVERS_DIR:-}" ] && PREFLIGHT_MEDIA+=(DRIVERS_DIR="$DRIVERS_DIR")
if [ "$RAW" = 1 ]; then
    env TARGET_MODE=raw TARGET="$DISK" MEM="$MEM" ISO="$ISO" "${PREFLIGHT_MEDIA[@]}" "$HERE/preflight.sh"
else
    env TARGET_MODE=qcow2 TARGET="$DISK" MEM="$MEM" ISO="$ISO" "${PREFLIGHT_MEDIA[@]}" "$HERE/preflight.sh"
fi
echo "  target: $DISK ($([ "$RAW" = 1 ] && echo 'raw block device' || echo 'qcow2'))"

step "1/13 render unattended media"
python3 "$HERE/render.py" --out "$BUILD/media" --image-index "$IMAGE_INDEX"

step "2/13 stage virtio-win drivers"
"$HERE/stage-drivers.sh"

step "3/13 build OEMDRV ISO"
MEDIA="$BUILD/media" DRIVERS="$BUILD/drivers" DRIVERS_EXTRA="$BUILD/drivers-extra" \
    "$PIPE/make_oemdrv.sh" "$ISO" "$IMAGE_INDEX"

step "4/13 save the Ubuntu network and SSH settings"
if [ "$KEEP_UBUNTU" = 1 ]; then
    "$PIPE/save_ubuntu_config.sh" "$DISK" "$BUILD/ubuntu-config"
else
    echo "  skipped (KEEP_UBUNTU is not 1)"
fi

step "5/13 apply install.wim to the target"
MEDIA="$BUILD/media" DRIVERS="$BUILD/drivers" DRIVERS_EXTRA="$BUILD/drivers-extra" \
SIZE="$SIZE" KEEP_UBUNTU="$KEEP_UBUNTU" REUSE_UBUNTU="$REUSE_UBUNTU" \
RECOVERY_SIZE="$RECOVERY_SIZE" \
"$PIPE/host_apply.sh" "$ISO" "$DISK" "$IMAGE_INDEX"

step "6/13 install the recovery Ubuntu"
if [ "$KEEP_UBUNTU" = 1 ]; then
    "$PIPE/make_recovery_ubuntu.sh" "$DISK" "$BUILD/ubuntu-config"
else
    echo "  skipped (KEEP_UBUNTU is not 1)"
fi

step "7/13 patch boot.wim to run the WinPE finish automatically"
START_CMD="$PIPE/manual_start.finish.cmd" \
    "$PIPE/make_manual_bootwim.sh" "$ISO" "$BUILD/boot-manual.wim"

step "8/13 build the boot FAT image"
BOOTWIM="$BUILD/boot-manual.wim" "$PIPE/make_bootfat.sh" "$ISO"

step "9/13 WinPE finish (drivers + bcdboot), automatic"
# The patched boot.wim runs manual_start.finish.cmd, which calls
# manual_finish.cmd and then shuts the VM down.  No VNC interaction.
NAME=finish WITH_ISO=0 BOOTFAT="$BUILD/bootfat.img" OEMDRV="$BUILD/oemdrv.iso" \
    DISK="$DISK" NVRAM="$BUILD/AAVMF_VARS.finish.fd" MEM="$MEM" SMP="$SMP" \
    "$PIPE/run-qemu.sh" &
QEMU_PID=$!
echo "qemu finish pid=$QEMU_PID"
if ! timeout 2700 tail --pid="$QEMU_PID" -f /dev/null; then
    echo "WinPE finish timed out; see $BUILD/logs/finish-serial.log" >&2
    exit 1
fi
wait "$QEMU_PID" || true
echo "WinPE finish completed"

step "10/13 first Windows boot and readiness check"
NAME=install WITH_ISO=0 BOOTFAT="" OEMDRV="" \
    DISK="$DISK" NVRAM="$BUILD/AAVMF_VARS.install.fd" MEM="$MEM" SMP="$SMP" \
    "$PIPE/run-qemu.sh" &
QEMU_PID=$!
echo "qemu install pid=$QEMU_PID"

ready=0
deadline=$(( $(date +%s) + 9000 ))   # 150 minutes
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "QEMU exited before the guest became ready" >&2
        exit 1
    fi
    # QEMU's hostfwd listener accepts immediately, so probe WinRM with HTTP.
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
        "http://127.0.0.1:${WINRM_PORT}/wsman" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        ready=1
        echo "WinRM responded with HTTP $code"
        break
    fi
    sleep 15
done
[ "$ready" = 1 ] || {
    echo "guest did not become ready; see $BUILD/logs/install-serial.log" >&2
    exit 1
}

step "11/13 graceful shutdown over QMP"
python3 "$HERE/qmp-powerdown.py" "$BUILD/install.qmp" --timeout 60
if ! timeout 900 tail --pid="$QEMU_PID" -f /dev/null; then
    echo "guest did not power down; refusing to hard-reset" >&2
    echo "shut it down manually, then rerun the packaging steps" >&2
    exit 1
fi
wait "$QEMU_PID" || true
echo "guest powered down"

step "12/13 patch ESP and inspect"
"$PIPE/finish_disk.sh" "$DISK"
"$PIPE/inspect_image.sh" "$DISK" | tee "$BUILD/logs/inspect.log"

step "13/13 package"
if [ "$RAW" = 1 ]; then
    echo "raw target: nothing to package"
elif [ "${PACKAGE:-0}" = "1" ]; then
    IMAGE="$DISK" "$HERE/package-image.sh"
else
    echo "packaging skipped (set PACKAGE=1 to compress the qcow2)"
fi

echo
echo "build complete: $DISK"
if [ "$RAW" = 1 ]; then
    echo "Next: detach the volume, reattach it as the boot volume, start the"
    echo "instance.  See docs/OCI.md."
else
    ls -lh "$DISK"
fi
