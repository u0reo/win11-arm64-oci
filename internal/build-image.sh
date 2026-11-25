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
#   SMP                  guest vCPUs (default: host nproc)
#   FRESH_UBUNTU=1       erase the disk and create a new ESP, a recovery
#                        system and Windows from scratch.  The recovery
#                        system copies /etc/netplan/*.yaml and an
#                        authorized_keys file from the running Ubuntu.
#   RECOVERY_SIZE=4G     size of that recovery partition
#   WINRE_PARTITION=1    leave WINRE_SIZE at the end of the disk for a
#                        dedicated Windows RE partition (p4).  Needs
#                        FRESH_UBUNTU=1.
#   WINRE_SIZE=1G        size of the Windows RE partition (minimum 1G)
#   REUSE_UBUNTU=1       p2 is an installed Ubuntu; only use the free space
#   BOOT_MENU_TIMEOUT=1  seconds to show the boot menu (0 = off).  GRUB when
#                        a recovery Ubuntu is included, otherwise Windows
#                        Boot Manager
#   FIRST_BOOT_UBUNTU=1  write a one-time Ubuntu default into the GRUB
#                        environment.  The recovery system then runs once
#                        before Windows first boots, so it can create its own
#                        firmware entry instead of being hidden by the
#                        Windows Boot#### entry.  Default: 1 with
#                        --fresh-ubuntu, 0 otherwise (a reused Ubuntu may not
#                        have oci-ubuntu-boot-order.service).
#   TEST_RECOVERY_BOOT=1 boot the finished recovery Ubuntu in QEMU and fail
#                        if systemd enters emergency mode.  TCG needs up to
#                        1800s (BOOT_TIMEOUT); set to 0 to skip.
#   PACKAGE=1            compress the qcow2 when the build finishes
#   FROM_STEP=0          resume at step N, reusing the staging directory.
#                        FROM_STEP=6 continues after host_apply.sh has
#                        already wiped and populated the target.
#   READY_TIMEOUT        seconds to wait for the OEM setup markers.  Default:
#                        14400 * 4 / SMP (clamped to 3600..28800), because TCG
#                        OOBE time scales roughly inversely with vCPU count.
#                        An HTTP response alone is not enough: firstlogon can
#                        still be running and its credentials not usable yet.
#                        Keep polling until the markers exist; never fall back
#                        to HTTP-only readiness.
#   SHUTDOWN_TIMEOUT=2700
#                        seconds to wait for the guest to power down before
#                        exiting.  The VM is never killed; FROM_STEP=11
#                        reconnects to it through build/logs/qemu-install.pid.
#   SHUTDOWN_RETRY_INTERVAL=15   seconds between WinRM shutdown requests.
#   SHUTDOWN_ATTEMPT_TIMEOUT=60  per-request WinRM timeout (seconds).
#   SHUTDOWN_MAX_TRIES=5         accepted graceful requests before retrying
#                                with `shutdown /f`.
#   WINRM_TIMEOUT=120    per-request WinRM timeout for readiness checks.
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
# shellcheck source=../pipeline/partitions.sh
. "$PIPE/partitions.sh"

ISO=${ISO:?set ISO=/path/to/Win11_ARM64.iso}
IMAGE_INDEX=${IMAGE_INDEX:-1}
SIZE=${SIZE:-50G}
MEM=${MEM:-8192}
SMP=${SMP:-$(nproc 2>/dev/null || echo 1)}
SHM_SIZE=${SHM_SIZE:-100%}
WINRM_PORT=${WINRM_PORT:-15985}
DISK=${DISK:-$ROOT/build/win11-arm64.qcow2}
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
FRESH_UBUNTU=${FRESH_UBUNTU:-0}
FIRST_BOOT_UBUNTU=${FIRST_BOOT_UBUNTU:-$FRESH_UBUNTU}
export FIRST_BOOT_UBUNTU
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}
WINRE_PARTITION=${WINRE_PARTITION:-0}
WINRE_SIZE=${WINRE_SIZE:-1G}
# 1 s by default; any key press stops the countdown.  0 turns the menu off.
BOOT_MENU_TIMEOUT=${BOOT_MENU_TIMEOUT:-1}
case "$BOOT_MENU_TIMEOUT" in
    ''|*[!0-9]*) ;;   # render.py reports a proper error for non-numbers
    *) BOOT_MENU_TIMEOUT=$((10#$BOOT_MENU_TIMEOUT)) ;;
esac
if [ "$BOOT_MENU_TIMEOUT" = 0 ] &&
   { [ "$REUSE_UBUNTU" = 1 ] || [ "$FRESH_UBUNTU" = 1 ]; }; then
    echo "BOOT_MENU_TIMEOUT=0 would hide the Ubuntu recovery entry" >&2
    exit 1
fi
export BOOT_MENU_TIMEOUT

FROM_STEP=${FROM_STEP:-0}
case "$SMP" in
    ''|*[!0-9]*|0) echo "SMP must be a positive number of vCPUs" >&2; exit 2 ;;
esac
# TCG OOBE scales roughly inversely with the vCPU count: 4 CPUs needed about
# 2.5 h in this lab, so keep ~1.5x headroom and clamp to a sane range.
READY_DEFAULT=$(( 14400 * 4 / SMP ))
if [ "$READY_DEFAULT" -lt 3600 ]; then READY_DEFAULT=3600; fi
if [ "$READY_DEFAULT" -gt 28800 ]; then READY_DEFAULT=28800; fi
READY_TIMEOUT=${READY_TIMEOUT:-$READY_DEFAULT}
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-2700}
SHUTDOWN_RETRY_INTERVAL=${SHUTDOWN_RETRY_INTERVAL:-15}
SHUTDOWN_ATTEMPT_TIMEOUT=${SHUTDOWN_ATTEMPT_TIMEOUT:-60}
SHUTDOWN_MAX_TRIES=${SHUTDOWN_MAX_TRIES:-5}
WINRM_TIMEOUT=${WINRM_TIMEOUT:-120}
for v in READY_TIMEOUT SHUTDOWN_TIMEOUT SHUTDOWN_RETRY_INTERVAL \
         SHUTDOWN_ATTEMPT_TIMEOUT SHUTDOWN_MAX_TRIES WINRM_TIMEOUT; do
    case "${!v}" in
        ''|*[!0-9]*) echo "$v must be a number" >&2; exit 2 ;;
    esac
done
case "$FROM_STEP" in
    ''|*[!0-9]*) echo "FROM_STEP must be a number between 0 and 13" >&2; exit 2 ;;
esac
if [ "$FROM_STEP" -gt 13 ]; then
    echo "FROM_STEP must be a number between 0 and 13" >&2
    exit 2
fi
if [ "$FROM_STEP" -gt 0 ]; then
    echo "build: resuming at step $FROM_STEP; staging in $BUILD is reused"
fi

if is_live_ram && ! live_shm_max; then
    echo "build: warning: could not remount /dev/shm at $SHM_SIZE" >&2
fi

RAW=0
if [ -b "$DISK" ]; then
    RAW=1
    # A live ISO stored on the target keeps the old partition open through
    # its loop device, which makes the kernel refuse a partition table
    # reload.  Detach unattached media loops before anything is changed.
    release_media_loops "$DISK"
fi
# If DISK was left at the default under $ROOT/build but BUILD moved, keep them together.
if [ "$DISK" = "$ROOT/build/win11-arm64.qcow2" ] && [ "$BUILD" != "$ROOT/build" ]; then
    DISK="$BUILD/win11-arm64.qcow2"
fi
if [ "$FRESH_UBUNTU" = 1 ] && [ "$RAW" != 1 ]; then
    echo "FRESH_UBUNTU needs DISK=/dev/sdX (an empty or disposable disk)" >&2
    exit 1
fi
if [ "$REUSE_UBUNTU" = 1 ] && [ "$RAW" != 1 ]; then
    echo "REUSE_UBUNTU needs DISK=/dev/sdX (the installed Ubuntu disk)" >&2
    exit 1
fi
if [ "$FRESH_UBUNTU" = 1 ] && [ "$REUSE_UBUNTU" = 1 ]; then
    echo "FRESH_UBUNTU cannot be combined with REUSE_UBUNTU" >&2
    exit 1
fi
if [ "$WINRE_PARTITION" = 1 ] && [ "$FRESH_UBUNTU" != 1 ]; then
    echo "WINRE_PARTITION needs FRESH_UBUNTU=1" >&2
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
# Prefix every line with a UTC timestamp before it reaches the terminal and
# build.log.  Children inherit this stdout, so their output is stamped too.
exec > >(python3 "$HERE/timestamp-log.py" | tee -a "$LOG") 2>&1

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

if [ "$FROM_STEP" -le 1 ]; then
    step "1/13 render unattended media"
    python3 "$HERE/render.py" --out "$BUILD/media" --image-index "$IMAGE_INDEX"
fi

if [ "$FROM_STEP" -le 2 ]; then
    step "2/13 stage virtio-win drivers"
    "$HERE/stage-drivers.sh"
fi

if [ "$FROM_STEP" -le 3 ] || [ "${REBUILD_OEMDRV:-0}" = 1 ]; then
    step "3/13 build OEMDRV ISO"
    MEDIA="$BUILD/media" DRIVERS="$BUILD/drivers" DRIVERS_EXTRA="$BUILD/drivers-extra" \
        "$PIPE/make_oemdrv.sh" "$ISO" "$IMAGE_INDEX"
fi

if [ "$FROM_STEP" -le 4 ]; then
    step "4/13 check the live network and SSH settings"
    if [ "$FRESH_UBUNTU" = 1 ]; then
        netplan_count=$(find /etc/netplan -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | wc -l)
        echo "  netplan: $netplan_count file(s) in /etc/netplan"
        key_src=""
        for f in /home/ubuntu/.ssh/authorized_keys /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do
            [ -s "$f" ] || continue
            key_src=$f
            break
        done
        if [ -n "$key_src" ]; then
            echo "  authorized_keys: $key_src"
        else
            echo "  WARN: no authorized_keys found; the recovery login will" >&2
            echo "  use the generated password printed in step 6" >&2
        fi
        echo "  step 6 copies these into the recovery Ubuntu; nothing is staged"
    else
        echo "  skipped (no recovery Ubuntu requested)"
    fi
fi

if [ "$FROM_STEP" -le 5 ]; then
    step "5/13 apply install.wim to the target"
    MEDIA="$BUILD/media" DRIVERS="$BUILD/drivers" DRIVERS_EXTRA="$BUILD/drivers-extra" \
    SIZE="$SIZE" REUSE_UBUNTU="$REUSE_UBUNTU" \
    FRESH_UBUNTU="$FRESH_UBUNTU" RECOVERY_SIZE="$RECOVERY_SIZE" \
    WINRE_PARTITION="$WINRE_PARTITION" WINRE_SIZE="$WINRE_SIZE" \
    "$PIPE/host_apply.sh" "$ISO" "$DISK" "$IMAGE_INDEX"
fi

if [ "$FROM_STEP" -le 6 ]; then
    step "6/13 install the recovery Ubuntu"
    if [ "$FRESH_UBUNTU" = 1 ]; then
        "$PIPE/make_recovery_ubuntu.sh" "$DISK"
    else
        echo "  skipped (no recovery Ubuntu requested)"
    fi
fi

if [ "$FROM_STEP" -le 7 ]; then
    step "7/13 patch boot.wim to run the WinPE finish automatically"
    START_CMD="$PIPE/manual_start.finish.cmd" \
        "$PIPE/make_manual_bootwim.sh" "$ISO" "$BUILD/boot-manual.wim"
fi

if [ "$FROM_STEP" -le 8 ]; then
    step "8/13 build the boot FAT image"
    BOOTWIM="$BUILD/boot-manual.wim" "$PIPE/make_bootfat.sh" "$ISO"
fi

if [ "$FROM_STEP" -le 9 ]; then
    step "9/13 WinPE finish (drivers + bcdboot), automatic"
    # The patched boot.wim runs manual_start.finish.cmd, which calls
    # manual_finish.cmd and then shuts the VM down.  WinPE has no PL011
    # driver, so COM1 stays empty; manual_finish.cmd writes its markers to
    # \manual-finish.log on the Windows volume.  Wait for the guest to power
    # down, then let the host check that log and finish the ESP.
    SERIAL="$BUILD/logs/finish-serial.log"
    PIDFILE="$BUILD/logs/qemu-finish.pid"
    mkdir -p "$BUILD/logs"
    if [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        QEMU_PID=$(cat "$PIDFILE")
        cmdline=$(tr '\0' ' ' < "/proc/$QEMU_PID/cmdline")
        case "$cmdline" in
            *"$DISK"*) echo "reusing qemu finish pid=$QEMU_PID" ;;
            *) echo "pid $QEMU_PID does not use $DISK; refusing to reuse it" >&2
               exit 1 ;;
        esac
    else
        rm -f "$PIDFILE" "$SERIAL"
        NAME=finish WITH_ISO=0 BOOTFAT="$BUILD/bootfat.img" OEMDRV="$BUILD/oemdrv.iso" \
            DISK="$DISK" NVRAM="$BUILD/AAVMF_VARS.finish.fd" MEM="$MEM" SMP="$SMP" \
            "$PIPE/run-qemu.sh" &
        QEMU_PID=$!
        printf '%s\n' "$QEMU_PID" > "$PIDFILE"
        echo "qemu finish pid=$QEMU_PID"
    fi

    if ! timeout 2700 tail --pid="$QEMU_PID" -f /dev/null; then
        echo "WinPE finish timed out after 45 minutes; leaving QEMU running" >&2
        echo "check the guest, then rerun FROM_STEP=9 to reuse pid=$QEMU_PID" >&2
        sed 's/\r$//' "$SERIAL" 2>/dev/null | tail -40 >&2 || true
        exit 1
    fi
    wait "$QEMU_PID" 2>/dev/null || true
    rm -f "$PIDFILE"

    if ! "$PIPE/finish_winpe.sh" "$DISK" --timeout "$BOOT_MENU_TIMEOUT"; then
        echo "WinPE finish failed; see $SERIAL and the finish log above" >&2
        sed 's/\r$//' "$SERIAL" 2>/dev/null | tail -40 >&2 || true
        exit 1
    fi
    echo "WinPE finish completed"
fi

if [ "$FROM_STEP" -le 10 ]; then
    step "10/13 first Windows boot and readiness check"
    # A stale NVRAM from an earlier attempt can still select the Ubuntu
    # shim by UUID, even after the ESP has a Windows boot manager.  Start
    # from the firmware defaults so it scans \EFI\Boot\BOOTAA64.EFI.
    rm -f "$BUILD/AAVMF_VARS.install.fd"
    NAME=install WITH_ISO=0 BOOTFAT="" OEMDRV="" \
        DISK="$DISK" NVRAM="$BUILD/AAVMF_VARS.install.fd" MEM="$MEM" SMP="$SMP" \
        "$PIPE/run-qemu.sh" &
    QEMU_PID=$!
    echo "qemu install pid=$QEMU_PID"
    mkdir -p "$BUILD/logs"
    printf '%s\n' "$QEMU_PID" > "$BUILD/logs/qemu-install.pid"

    ready=0
    deadline=$(( $(date +%s) + READY_TIMEOUT ))
    last_marker=''
    last_code=''
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            rm -f "$BUILD/logs/qemu-install.pid"
            echo "QEMU exited before the guest became ready" >&2
            exit 1
        fi
        # QEMU's hostfwd listener accepts immediately, so probe WinRM with HTTP.
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
            "http://127.0.0.1:${WINRM_PORT}/wsman" 2>/dev/null || true)
        if [ -z "$code" ] || [ "$code" = "000" ]; then
            sleep 15
            continue
        fi
        if [ "$code" != "$last_code" ]; then
            echo "WinRM responded with HTTP $code"
            last_code=$code
        fi

        # The service can accept HTTP while firstlogon.ps1 / boot.ps1 are still
        # configuring the guest.  Do not power down until their markers exist.
        if out=$(timeout "$((WINRM_TIMEOUT + 10))" \
                 python3 "$HERE/winrm-guest.py" ready 2>&1); then
            rc=0
        else
            rc=$?
        fi
        # A rejected login is normal while firstlogon.ps1 is still setting up
        # the account.  Never fall back to the HTTP response: it only proves
        # http.sys accepted a connection, not that setup finished.
        if [ "$rc" = 0 ]; then
            echo "$out"
            ready=1
            break
        fi
        if [ "$out" != "$last_marker" ]; then
            echo "$out"
            last_marker=$out
        fi
        sleep 15
    done
    [ "$ready" = 1 ] || {
        echo "guest did not become ready; see $BUILD/logs/install-serial.log" >&2
        exit 1
    }
fi

if [ "$FROM_STEP" -le 11 ]; then
    step "11/13 graceful shutdown over WinRM"
    PIDFILE="$BUILD/logs/qemu-install.pid"
    # FROM_STEP=11 does not rerun step 10, so recover the PID that started
    # the Windows VM.  This lets a timed-out build keep waiting on the same
    # guest instead of starting a second QEMU.
    if [ -z "${QEMU_PID:-}" ] && [ -f "$PIDFILE" ]; then
        QEMU_PID=$(cat "$PIDFILE")
    fi
    if [ -n "${QEMU_PID:-}" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        cmdline=$(tr '\0' ' ' < "/proc/$QEMU_PID/cmdline")
        case "$cmdline" in
            *"$DISK"*) ;;
            *) echo "pid $QEMU_PID does not use $DISK; refusing to wait on it" >&2
               exit 1 ;;
        esac
        # A child that exited but was not reaped still answers kill -0.
        qemu_running() {
            [ -r "/proc/$QEMU_PID/stat" ] || return 1
            [ "$(awk '{print $3}' "/proc/$QEMU_PID/stat" 2>/dev/null)" != Z ]
        }
        echo "waiting for qemu pid=$QEMU_PID (up to ${SHUTDOWN_TIMEOUT}s)"
        shutdown_deadline=$(( $(date +%s) + SHUTDOWN_TIMEOUT ))
        accepted=0
        forced=0
        while [ "$(date +%s)" -lt "$shutdown_deadline" ] && qemu_running; do
            if [ -z "${WIN_USERNAME:-}" ] || [ -z "${WIN_PASSWORD:-}" ]; then
                echo "WIN_USERNAME/WIN_PASSWORD are not set; cannot shut down over WinRM" >&2
            else
                force_arg=""
                [ "$forced" = 1 ] && force_arg="--force"
                if out=$(timeout "$SHUTDOWN_ATTEMPT_TIMEOUT" \
                         python3 "$HERE/winrm-guest.py" shutdown $force_arg 2>&1); then
                    rc=0
                else
                    rc=$?
                fi
                if [ -n "$out" ]; then echo "$out"; fi
                case "$rc" in
                    0)
                        if [ "$forced" = 0 ]; then
                            accepted=$(( accepted + 1 ))
                            echo "  graceful shutdown request $accepted/$SHUTDOWN_MAX_TRIES accepted"
                            if [ "$accepted" -ge "$SHUTDOWN_MAX_TRIES" ]; then
                                forced=1
                                echo "  guest is still running; retrying with shutdown /f"
                            fi
                        fi
                        ;;
                    3)
                        echo "  connection closed; the guest may already be powering down"
                        ;;
                    *)
                        echo "  WinRM shutdown error (rc=$rc); retrying" >&2
                        ;;
                esac
            fi
            sleep "$SHUTDOWN_RETRY_INTERVAL"
        done
        if qemu_running; then
            echo "guest did not power down within ${SHUTDOWN_TIMEOUT}s; refusing to hard-reset" >&2
            echo "the VM was left running on purpose.  Check it, then rerun with" >&2
            echo "  FROM_STEP=11 ... --yes" >&2
            echo "to keep waiting without starting a second QEMU." >&2
            exit 1
        fi
        wait "$QEMU_PID" 2>/dev/null || true
        echo "guest powered down"
    else
        if [ -n "${QEMU_PID:-}" ]; then
            echo "qemu pid=$QEMU_PID is no longer running"
        else
            echo "no QEMU pid recorded; assuming the guest already powered down"
        fi
    fi
    rm -f "$PIDFILE"
fi

if [ "$FROM_STEP" -le 12 ]; then
    step "12/13 patch ESP and inspect"
    # Prefer the boot manager from the installation media over the copy on
    # the installed Windows volume.  A servicing update replaces
    # C:\Windows\Boot\EFI\bootmgfw.efi (for example with the 28000.367 26H2
    # build), and that version hangs on Oracle AAVMF before the boot menu.
    # The ISO keeps the boot manager that matches the media generation.
    # Take bootmgr.efi and boot.stl from the same tree when they are present,
    # so finish_disk.sh does not pair a 26100 bootmgfw with the installed
    # Windows 28000 boot chain.
    MEDIA_BOOTMGFW=""
    MEDIA_BOOTMGR=""
    MEDIA_BOOT_STL=""
    if [ -z "${STOCK_BOOTMGFW:-}" ] && [ -f "$ISO" ]; then
        ISO_MNT=$(mktemp -d "$BUILD/iso-mnt.XXXXXX")
        if mount -o loop,ro "$ISO" "$ISO_MNT" 2>/dev/null; then
            if [ -f "$ISO_MNT/efi/boot/bootaa64.efi" ]; then
                cp -f "$ISO_MNT/efi/boot/bootaa64.efi" \
                    "$BUILD/bootmgfw-media.efi"
                MEDIA_BOOTMGFW="$BUILD/bootmgfw-media.efi"
                echo "  media boot manager: $(stat -c %s "$MEDIA_BOOTMGFW") bytes"
            fi
            if [ -f "$ISO_MNT/efi/microsoft/boot/bootmgr.efi" ]; then
                cp -f "$ISO_MNT/efi/microsoft/boot/bootmgr.efi" \
                    "$BUILD/bootmgr-media.efi"
                MEDIA_BOOTMGR="$BUILD/bootmgr-media.efi"
                echo "  media bootmgr: $(stat -c %s "$MEDIA_BOOTMGR") bytes"
            elif [ -f "$ISO_MNT/bootmgr.efi" ]; then
                # Windows ISO keeps the UEFI copy at the media root as well.
                cp -f "$ISO_MNT/bootmgr.efi" "$BUILD/bootmgr-media.efi"
                MEDIA_BOOTMGR="$BUILD/bootmgr-media.efi"
                echo "  media bootmgr (root): $(stat -c %s "$MEDIA_BOOTMGR") bytes"
            fi
            if [ -f "$ISO_MNT/efi/microsoft/boot/boot.stl" ]; then
                cp -f "$ISO_MNT/efi/microsoft/boot/boot.stl" \
                    "$BUILD/boot.stl-media"
                MEDIA_BOOT_STL="$BUILD/boot.stl-media"
                echo "  media boot.stl: $(stat -c %s "$MEDIA_BOOT_STL") bytes"
            fi
            umount "$ISO_MNT"
        else
            echo "  warning: cannot mount $ISO; using the installed boot manager" >&2
        fi
        rmdir "$ISO_MNT" 2>/dev/null || true
    fi
    STOCK_BOOTMGR=${STOCK_BOOTMGR:-$MEDIA_BOOTMGR}
    STOCK_BOOT_STL=${STOCK_BOOT_STL:-$MEDIA_BOOT_STL}
    if [ -n "${STOCK_BOOTMGFW:-}" ]; then
        STOCK_BOOTMGFW="$STOCK_BOOTMGFW" STOCK_BOOTMGR="$STOCK_BOOTMGR" \
            STOCK_BOOT_STL="$STOCK_BOOT_STL" \
            "$PIPE/finish_disk.sh" "$DISK"
    elif [ -n "$MEDIA_BOOTMGFW" ]; then
        STOCK_BOOTMGFW="$MEDIA_BOOTMGFW" STOCK_BOOTMGR="$STOCK_BOOTMGR" \
            STOCK_BOOT_STL="$STOCK_BOOT_STL" \
            "$PIPE/finish_disk.sh" "$DISK"
    else
        STOCK_BOOTMGR="$STOCK_BOOTMGR" STOCK_BOOT_STL="$STOCK_BOOT_STL" \
            "$PIPE/finish_disk.sh" "$DISK"
    fi
    "$PIPE/inspect_image.sh" "$DISK" | tee "$BUILD/logs/inspect.log"
    # finish_disk.sh can rebuild the ESP after the recovery fstab was
    # written.  inspect_image.sh checks the identifiers; this boots the
    # final image so a regression in the boot path is caught too.
    if [ "${TEST_RECOVERY_BOOT:-1}" = 1 ]; then
        if [ "${FRESH_UBUNTU:-0}" = 1 ] || [ "${REUSE_UBUNTU:-0}" = 1 ]; then
            "$PIPE/test_recovery_boot.sh" "$DISK"
        else
            echo "  recovery boot test skipped (no Ubuntu in this build)"
        fi
    fi
fi

if [ "$FROM_STEP" -le 13 ]; then
    step "13/13 package"
    if [ "$RAW" = 1 ]; then
        echo "raw target: nothing to package"
    elif [ "${PACKAGE:-0}" = "1" ]; then
        IMAGE="$DISK" "$HERE/package-image.sh"
    else
        echo "packaging skipped (set PACKAGE=1 to compress the qcow2)"
    fi
fi

echo
echo "build complete: $DISK"
if [ "$RAW" = 1 ]; then
    echo "Next: detach the volume, reattach it as the boot volume, start the"
    echo "instance.  See docs/OCI.md."
else
    ls -lh "$DISK"
fi
