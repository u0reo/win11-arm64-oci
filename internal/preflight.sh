#!/usr/bin/env bash
# Check the host before a build.  Read-only.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MIN_FREE_GB=${MIN_FREE_GB:-80}
BUILD=${BUILD_DIR:-$ROOT/build}

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
mkdir -p "$BUILD"
FREE_GB=$(df -Pk "$BUILD" | awk 'NR==2 {printf "%d", $4/1024/1024}')
echo "  $BUILD: ${FREE_GB} GiB free (need >= ${MIN_FREE_GB} GiB)"
[ "$FREE_GB" -ge "$MIN_FREE_GB" ] && ok "disk space" || bad "not enough disk space"

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
