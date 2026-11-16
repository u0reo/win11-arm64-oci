#!/usr/bin/env bash
# Check the host before a build.  Read-only.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TARGET_MODE=${TARGET_MODE:-qcow2}
BUILD=${BUILD_DIR:-$ROOT/build}
TARGET=${TARGET:-}

case "$TARGET_MODE" in
    raw)   DEFAULT_MIN_FREE_GB=8 ;;    # staging only; the target is written in place
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

echo "== tools =="
for t in qemu-system-aarch64 qemu-img qemu-nbd wimlib-imagex xorriso sgdisk \
         mkfs.vfat mkntfs ntfsfix mcopy sfdisk partprobe zstd rclone python3; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not found"; fi
done
command -v age >/dev/null 2>&1 && ok "age" || warn "age not found (optional)"
command -v shellcheck >/dev/null 2>&1 && ok "shellcheck" || warn "shellcheck not found (CI only)"
command -v rpm2cpio >/dev/null 2>&1 && ok "rpm2cpio" ||
    warn "rpm2cpio not found (only needed for --virtio *.rpm)"
command -v cpio >/dev/null 2>&1 && ok "cpio" ||
    warn "cpio not found (only needed for --virtio *.rpm)"

echo "== python modules =="
python3 - <<'PY' || fail=1
mods = ["hivex", "pefile"]
for m in mods:
    try:
        __import__(m)
        print(f"  ok    {m}")
    except Exception:
        print(f"  warn  {m} not installed (inspect_image.sh will skip some checks)")
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
    FREE_GB=$(df -Pk "$BUILD" | awk 'NR==2 {printf "%d", $4/1024/1024}')
else
    bad "cannot create $BUILD"
    FREE_GB=0
fi
if [ "$TARGET_MODE" = raw ]; then
    echo "  $BUILD: ${FREE_GB} GiB free (staging only, need >= ${MIN_FREE_GB} GiB)"
else
    echo "  $BUILD: ${FREE_GB} GiB free (qcow2, need >= ${MIN_FREE_GB} GiB)"
fi
[ "$FREE_GB" -ge "$MIN_FREE_GB" ] && ok "disk space" || bad "not enough disk space"

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
