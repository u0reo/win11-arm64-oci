#!/usr/bin/env bash
# End-to-end image build.  Run on a self-hosted runner, not on GitHub-hosted
# runners (no /dev/kvm, ~14 GB disk, 6 h job limit).
#
# Required:
#   ISO=/path/to/Win11_ARM64.iso
#   VIRTIO_ISO=/path/to/virtio-win.iso   (or DRIVERS_DIR=/path/to/drivers)
#
# Optional:
#   IMAGE_INDEX=1        WIM index (default 1)
#   SIZE=50G             qcow2 virtual size
#   MEM=8192             guest RAM in MiB
#   SMP=4                guest vCPUs
#   WIN_USERNAME / WIN_PASSWORD / COMPUTER_NAME   (render.py overrides)
#   SKIP_UPLOAD=1        do not upload to MEGA
#
# Outputs:
#   build/win11-arm64.qcow2
#   build/artifacts/win11-arm64.qcow2.zst{,.sha256}
#   build/logs/*.log
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BUILD=${BUILD_DIR:-$ROOT/build}
export BUILD_DIR="$BUILD"
PIPE="$ROOT/pipeline"

ISO=${ISO:?set ISO=/path/to/Win11_ARM64.iso}
IMAGE_INDEX=${IMAGE_INDEX:-1}
SIZE=${SIZE:-50G}
MEM=${MEM:-8192}
SMP=${SMP:-4}
WINRM_PORT=${WINRM_PORT:-15985}
DISK="$BUILD/win11-arm64.qcow2"

mkdir -p "$BUILD/logs" "$BUILD/artifacts"
LOG="$BUILD/logs/build.log"
exec > >(tee -a "$LOG") 2>&1

step() { echo; echo "==== $* ===="; }

step "0/11 preflight"
MIN_FREE_GB=${MIN_FREE_GB:-80} "$HERE/preflight.sh"

step "1/11 render unattended media"
python3 "$HERE/render.py" --out "$BUILD/media" --image-index "$IMAGE_INDEX"

step "2/11 stage virtio-win drivers"
"$HERE/stage-drivers.sh"

step "3/11 build OEMDRV ISO"
MEDIA="$BUILD/media" DRIVERS="$BUILD/drivers" DRIVERS_EXTRA="$BUILD/drivers-extra" \
    "$PIPE/make_oemdrv.sh" "$ISO" "$IMAGE_INDEX"

step "4/11 apply install.wim to a fresh qcow2"
MEDIA="$BUILD/media" DRIVERS="$BUILD/drivers" DRIVERS_EXTRA="$BUILD/drivers-extra" \
SIZE="$SIZE" "$PIPE/host_apply.sh" "$ISO" "$DISK" "$IMAGE_INDEX"

step "5/11 patch boot.wim to run the WinPE finish automatically"
START_CMD="$PIPE/manual_start.finish.cmd" \
    "$PIPE/make_manual_bootwim.sh" "$ISO" "$BUILD/boot-manual.wim"

step "6/11 build the boot FAT image"
BOOTWIM="$BUILD/boot-manual.wim" "$PIPE/make_bootfat.sh" "$ISO"

step "7/11 WinPE finish (drivers + bcdboot), automatic"
# The patched boot.wim runs manual_start.finish.cmd, which calls
# manual_finish.cmd and then shuts the VM down.  No VNC interaction.
NAME=finish WITH_ISO=0 BOOTFAT="$BUILD/bootfat.img" OEMDRV="$BUILD/oemdrv.iso" \
    NVRAM="$BUILD/AAVMF_VARS.finish.fd" MEM="$MEM" SMP="$SMP" \
    "$PIPE/run-qemu.sh" &
QEMU_PID=$!
echo "qemu finish pid=$QEMU_PID"
if ! timeout 2700 tail --pid="$QEMU_PID" -f /dev/null; then
    echo "WinPE finish timed out; see $BUILD/logs/finish-serial.log" >&2
    exit 1
fi
wait "$QEMU_PID" || true
echo "WinPE finish completed"

step "8/11 first Windows boot and readiness check"
NAME=install WITH_ISO=0 BOOTFAT="" OEMDRV="" \
    NVRAM="$BUILD/AAVMF_VARS.install.fd" MEM="$MEM" SMP="$SMP" \
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

step "8b/11 graceful shutdown over QMP"
python3 "$HERE/qmp-powerdown.py" "$BUILD/install.qmp" --timeout 60
if ! timeout 900 tail --pid="$QEMU_PID" -f /dev/null; then
    echo "guest did not power down; refusing to hard-reset" >&2
    echo "shut it down manually, then rerun the packaging steps" >&2
    exit 1
fi
wait "$QEMU_PID" || true
echo "guest powered down"

step "9/11 patch ESP and inspect"
"$PIPE/finish_qcow2.sh" "$DISK"
"$PIPE/inspect_image.sh" "$DISK" | tee "$BUILD/logs/inspect.log"

step "10/11 package"
IMAGE="$DISK" "$HERE/package-image.sh"

if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
    echo "upload skipped (SKIP_UPLOAD=1)"
elif [ -n "${MEGA_USER:-}" ] && [ -n "${MEGA_PASS_OBSCURED:-}" ]; then
    step "11/11 upload to MEGA"
    "$HERE/upload-mega.sh" "$BUILD"/artifacts/*.zst "$BUILD"/artifacts/*.sha256
else
    echo "upload skipped (MEGA_USER / MEGA_PASS_OBSCURED not set)"
fi

echo
echo "build complete: $DISK"
ls -lh "$BUILD/artifacts"
