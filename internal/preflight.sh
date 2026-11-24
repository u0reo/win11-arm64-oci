#!/usr/bin/env bash
# Check the host before a build.  Read-only.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=live.sh
. "$HERE/live.sh"
TARGET_MODE=${TARGET_MODE:-qcow2}
BUILD=$(default_build_dir "$ROOT/build")
TARGET=${TARGET:-}
MEM=${MEM:-6144}
SHM_SIZE=${SHM_SIZE:-100%}

case "$TARGET_MODE" in
    raw)   DEFAULT_MIN_FREE_GB=3 ;;    # staging only (boot.wim/bootfat/OEMDRV); target written in place
    qcow2) DEFAULT_MIN_FREE_GB=80 ;;   # the image grows to the Windows install size
    *)
        echo "preflight: TARGET_MODE must be raw or qcow2" >&2
        exit 2
        ;;
esac
MIN_FREE_GB=${MIN_FREE_GB:-$DEFAULT_MIN_FREE_GB}

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

disk_free_gb() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'
}

size_mb() {
    local p=$1
    [ -n "$p" ] || { echo 0; return; }
    if [ -d "$p" ]; then du -sm "$p" 2>/dev/null | awk '{print $1+0}'
    elif [ -f "$p" ]; then stat -c %s "$p" 2>/dev/null | awk '{printf "%d", $1/1024/1024}'
    else echo 0; fi
}

echo "== tools =="
for t in qemu-system-aarch64 qemu-img qemu-nbd wimlib-imagex xorriso sgdisk \
         mkfs.vfat mkntfs ntfsfix mcopy sfdisk partprobe zstd python3; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not found"; fi
done
# Upload/packaging tools are not used by build.sh.  They are optional here.
for t in rclone age; do
    command -v "$t" >/dev/null 2>&1 && ok "$t" || warn "$t not found (upload/packaging only)"
done
command -v shellcheck >/dev/null 2>&1 && ok "shellcheck" || warn "shellcheck not found (CI only)"
command -v rpm2cpio >/dev/null 2>&1 && ok "rpm2cpio" ||
    warn "rpm2cpio not found (only needed for --virtio *.rpm)"
command -v cpio >/dev/null 2>&1 && ok "cpio" ||
    warn "cpio not found (only needed for --virtio *.rpm)"

echo "== python modules =="
python3 - <<'PY' || fail=1
import sys

required = ["hivex", "pefile", "winrm", "requests_ntlm"]
missing = []
for m in required:
    try:
        __import__(m)
        print(f"  ok    {m}")
    except Exception:
        print(f"  FAIL  {m} is required; install with scripts/setup-live.sh")
        missing.append(m)
if missing:
    sys.exit(1)
PY

echo "== privileges =="
if sudo -n true 2>/dev/null; then ok "sudo -n"; else bad "passwordless sudo is required for qemu-nbd/mount"; fi

echo "== virtualisation =="
if [ -e /dev/kvm ]; then
    ok "/dev/kvm present (QEMU uses KVM acceleration)"
else
    warn "/dev/kvm absent: guest runs under TCG (slow)"
fi
echo "  arch=$(uname -m) cpus=$(nproc)"

echo "== disk =="
if mkdir -p "$BUILD" 2>/dev/null; then
    FREE_GB=$(disk_free_gb "$BUILD")
else
    bad "cannot create $BUILD"
    FREE_GB=0
fi
if [ "$TARGET_MODE" = raw ]; then
    echo "  $BUILD: ${FREE_GB} GiB free (staging only, need >= ${MIN_FREE_GB} GiB)"
else
    echo "  $BUILD: ${FREE_GB} GiB free (qcow2, need >= ${MIN_FREE_GB} GiB)"
fi
if [ "$FREE_GB" -ge "$MIN_FREE_GB" ]; then
    ok "disk space"
else
    bad "not enough disk space"
    echo "  candidates with free space (BUILD_DIR):"
    for cand in /dev/shm /tmp /run/user/0 /run; do
        [ -d "$cand" ] || continue
        cg=$(disk_free_gb "$cand")
        [ "${cg:-0}" -ge "$MIN_FREE_GB" ] && printf '    %s  (%s GiB free)\n' "$cand" "$cg"
    done
    echo "  rerun with: sudo BUILD_DIR=/dev/shm/build ./scripts/build.sh ..."
    echo "  or lower the check: --min-free-gb <N> (staging is usually ~2 GiB)"
fi

if [ -n "$TARGET" ]; then
    if [ "$TARGET_MODE" = raw ]; then
        if [ -b "$TARGET" ]; then
            TARGET_BYTES=$(lsblk -bno SIZE "$TARGET" | head -1 || true)
            TARGET_GB=$(( ${TARGET_BYTES:-0} / 1024 / 1024 / 1024 ))
            echo "  target $TARGET: ${TARGET_GB} GiB"
            [ "$TARGET_GB" -ge 40 ] && ok "target size" ||
                bad "target is only ${TARGET_GB} GiB; Windows needs at least 40"
            ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
            if [ -n "$ROOTDEV" ] && [[ "$ROOTDEV" == "$TARGET"* ]]; then
                warn "$TARGET is the running root; boot live toram or use --reuse-ubuntu"
            fi
        else
            bad "$TARGET is not a block device"
        fi
    else
        TARGET_DIR=$(dirname "$TARGET")
        if [ -d "$TARGET_DIR" ]; then
            if [ "$(stat -c %d "$TARGET_DIR")" = "$(stat -c %d "$BUILD")" ]; then
                echo "  image $TARGET: same filesystem as $BUILD"
            else
                IMG_FREE_GB=$(df -Pk "$TARGET_DIR" | awk 'NR==2 {printf "%d", $4/1024/1024}')
                echo "  image $TARGET_DIR: ${IMG_FREE_GB} GiB free"
                [ "$IMG_FREE_GB" -ge "$MIN_FREE_GB" ] && ok "image space" ||
                    bad "not enough space for the qcow2 in $TARGET_DIR"
            fi
        else
            bad "$TARGET_DIR does not exist"
        fi
    fi
fi

echo "== memory =="
MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEDIA_MB=0
media_on_tmpfs() {
    local p=$1
    [ -n "$p" ] && [ -e "$p" ] || return 1
    findmnt -no FSTYPE --target "$p" 2>/dev/null | grep -qx tmpfs
}
for mp in "${ISO:-}" "${VIRTIO_ISO:-}" "${VIRTIO:-}" "${VIRTIO_RPM:-}" "${DRIVERS_DIR:-}" "${DRIVERS:-}"; do
    # Media already on a tmpfs lives in RAM and is not copied again;
    # adding it would count the same pages twice.
    if media_on_tmpfs "$mp"; then
        continue
    fi
    MEDIA_MB=$(( MEDIA_MB + $(size_mb "$mp") ))
done
STAGING_MB=2048
OVERHEAD_MB=1024
EST_MB=$(( MEM + STAGING_MB + OVERHEAD_MB ))
echo "  MemTotal ${MEM_TOTAL_MB} MiB, MemAvailable ${MEM_AVAIL_MB} MiB"
if [ "$MEDIA_MB" -gt 0 ]; then
    echo "  estimate: guest ${MEM} + staging ~${STAGING_MB} + media ~${MEDIA_MB} + overhead ~${OVERHEAD_MB} = ~$((EST_MB + MEDIA_MB)) MiB"
    NEED_RAM=$(( EST_MB + MEDIA_MB ))
else
    echo "  estimate: guest ${MEM} + staging ~${STAGING_MB} + overhead ~${OVERHEAD_MB} = ~${EST_MB} MiB (+ media if copied to RAM)"
    NEED_RAM=$EST_MB
fi
# FROM_STEP>=11 only reconnects to an already running guest.  Its RAM is
# already counted as used, so do not reject the resume for that reason.
skip_ram_fail=0
existing_pid=''
if [ "${FROM_STEP:-0}" -ge 11 ] && [ -f "$BUILD/logs/qemu-install.pid" ]; then
    existing_pid=$(cat "$BUILD/logs/qemu-install.pid" 2>/dev/null || true)
    case "$existing_pid" in
        ''|*[!0-9]*) existing_pid='' ;;
        *) kill -0 "$existing_pid" 2>/dev/null || existing_pid='' ;;
    esac
    if [ -n "$existing_pid" ]; then
        echo "  ok    existing qemu pid=$existing_pid (FROM_STEP>=11 starts no new guest)"
        skip_ram_fail=1
    fi
fi
if [ "$MEM_AVAIL_MB" -ge "$NEED_RAM" ]; then
    ok "memory headroom (estimate)"
elif [ "$skip_ram_fail" = 1 ]; then
    warn "memory is held by qemu pid=$existing_pid; no new guest is started at FROM_STEP>=11"
elif [ "$MEM_AVAIL_MB" -ge $(( MEM + OVERHEAD_MB )) ]; then
    warn "memory may be tight for build+guest (available ${MEM_AVAIL_MB} MiB, estimated ${NEED_RAM} MiB); consider lower --mem"
else
    bad "not enough RAM for guest (available ${MEM_AVAIL_MB} MiB, need >= guest ${MEM} + overhead)"
fi
if findmnt -no FSTYPE -T / 2>/dev/null | grep -q overlay; then
    cow_free=$(disk_free_gb / 2>/dev/null || echo 0)
    shm_free=$(disk_free_gb /dev/shm 2>/dev/null || echo 0)
    tmp_free=$(disk_free_gb /tmp 2>/dev/null || echo 0)
    echo "  live/overlay root: / ${cow_free} GiB free, /dev/shm ${shm_free} GiB, /tmp ${tmp_free} GiB (tmpfs mounts share RAM; use BUILD_DIR on a roomy tmpfs)"
fi
if is_live_ram; then
    SHM_KB=$(shm_total_kb)
    MEM_KB=$(mem_total_kb)
    SHM_GB=$(( SHM_KB / 1024 / 1024 ))
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    if shm_meets; then
        ok "/dev/shm ${SHM_GB} GiB (live/toram)"
    else
        warn "/dev/shm is ${SHM_GB} GiB of ${MEM_GB} GiB RAM; setup.sh/build.sh remounts it at $SHM_SIZE"
    fi
    echo "  staging default: /dev/shm/build (media: /dev/shm/iso)"
fi

echo "== firmware =="
FW_CODE=${FW_CODE:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}
FW_VARS=${FW_VARS_SRC:-/usr/share/AAVMF/AAVMF_VARS.fd}
[ -f "$FW_CODE" ] && ok "$FW_CODE" || bad "missing $FW_CODE"
[ -f "$FW_VARS" ] && ok "$FW_VARS" || bad "missing $FW_VARS"

if [ "$fail" -ne 0 ]; then
    echo "preflight: FAILED" >&2
    exit 1
fi
echo "preflight: OK"
