#!/usr/bin/env bash
# Build the small "OEMDRV" ISO used by the unattended Windows 11 ARM64
# install.  It contains the rendered autounattend.xml, the OEM scripts and
# the virtio-win ARM64 drivers staged by internal/stage-drivers.sh.
#
# Usage:
#   ./make_oemdrv.sh /path/to/Windows11_ARM64.iso [image-index]
#
# Environment:
#   MEDIA          rendered media dir          (default: build/media)
#   DRIVERS        PnP driver dir              (default: build/drivers)
#   DRIVERS_EXTRA  optional extra driver dir   (default: build/drivers-extra)
#   OUT_DIR        output dir                  (default: build)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ISO=${1:?usage: $0 <windows-arm64.iso> [image-index]}
INDEX=${2:-${IMAGE_INDEX:-1}}
BUILD=${BUILD_DIR:-$ROOT/build}
MEDIA=${MEDIA:-$BUILD/media}
DRIVERS=${DRIVERS:-$BUILD/drivers}
DRIVERS_EXTRA=${DRIVERS_EXTRA:-$BUILD/drivers-extra}
OUT_DIR=${OUT_DIR:-$BUILD}
IMG="$OUT_DIR/oemdrv.iso"
STAGE="$OUT_DIR/oemdrv.stage"

[ -f "$ISO" ] || { echo "missing ISO: $ISO" >&2; exit 1; }
[ -f "$MEDIA/autounattend.xml" ] || {
    echo "missing $MEDIA/autounattend.xml; run internal/render.py first" >&2
    exit 1
}
[ -d "$MEDIA/oem" ] || { echo "missing $MEDIA/oem" >&2; exit 1; }
[ -d "$DRIVERS" ] || { echo "missing $DRIVERS; run internal/stage-drivers.sh" >&2; exit 1; }
find "$DRIVERS" -maxdepth 1 -iname '*.inf' | grep -q . || {
    echo "no .inf in $DRIVERS" >&2
    exit 1
}

MNT=$(mktemp -d /tmp/winiso.XXXXXX)
MOUNTED=0
cleanup() {
    set +e
    [ "$MOUNTED" = 1 ] && sudo -n umount "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

echo "[1/4] mount ISO: $ISO"
sudo -n mkdir -p "$MNT"
if ! sudo -n mount -t udf -o ro,loop "$ISO" "$MNT" 2>/dev/null; then
    sudo -n mount -t iso9660 -o ro,loop "$ISO" "$MNT"
fi
MOUNTED=1

WIM=""
for cand in "$MNT/sources/install.wim" "$MNT/sources/install.esd"; do
    [ -f "$cand" ] && WIM=$cand && break
done
[ -n "$WIM" ] || { echo "no sources/install.wim|esd in ISO" >&2; exit 1; }

echo "[2/4] inspect install image"
INFO=$(wimlib-imagex info "$WIM" "$INDEX")
echo "$INFO" | sed -n '1,20p'
ARCH=$(echo "$INFO" | awk -F': *' '/^Architecture:/{print $2; exit}')
EDITION=$(echo "$INFO" | awk -F': *' '/^Edition ID:/{print $2; exit}')
NAME=$(echo "$INFO" | awk -F': *' '/^Name:/{print $2; exit}')
LANG=$(echo "$INFO" | awk -F': *' '/^Languages:/{print $2; exit}')
[ "$ARCH" = "ARM64" ] || { echo "not ARM64: $ARCH" >&2; exit 1; }
echo "  arch=$ARCH edition=$EDITION name=$NAME lang=$LANG index=$INDEX"

echo "[3/4] stage OEM files"
rm -rf "$STAGE"
mkdir -p "$STAGE/oem" "$STAGE/drivers" "$STAGE/drivers-extra"
cp -a "$MEDIA/oem/." "$STAGE/oem/"
if [ -d "$HERE/manual" ]; then cp -a "$HERE/manual/." "$STAGE/"; fi
cp -a "$MEDIA/autounattend.xml" "$STAGE/autounattend.xml"
find "$DRIVERS" -maxdepth 1 -type f -exec cp -t "$STAGE/drivers" {} +
if [ -d "$DRIVERS_EXTRA" ]; then
    find "$DRIVERS_EXTRA" -maxdepth 1 -type f -exec cp -t "$STAGE/drivers-extra" {} +
fi
printf '%s\n' "$INDEX" > "$STAGE/image-index.txt"
INFCOUNT=$(find "$STAGE/drivers" -maxdepth 1 -iname '*.inf' | wc -l)
[ "$INFCOUNT" -gt 0 ] || { echo "no .inf staged in drivers/" >&2; exit 1; }
echo "  staged $INFCOUNT INF driver(s), $(find "$STAGE/drivers-extra" -maxdepth 1 -iname '*.inf' | wc -l) extra"

echo "[4/4] build OEMDRV ISO (Joliet)"
mkdir -p "$OUT_DIR"
rm -f "$IMG"
xorriso -as mkisofs -J -R -V OEMDRV -o "$IMG" "$STAGE" >/dev/null
SHA=$(sha256sum "$IMG" | awk '{print $1}')
python3 - "$OUT_DIR/oemdrv.json" "$ISO" "$INDEX" "$ARCH" "$EDITION" "$NAME" "$LANG" "$SHA" <<'PY'
import json, sys, time
p, iso, idx, arch, edition, name, lang, sha = sys.argv[1:]
json.dump({
    "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "iso": iso, "image_index": int(idx), "architecture": arch,
    "edition": edition, "name": name, "language": lang,
    "sha256": sha, "image": "oemdrv.iso",
}, open(p, "w"), ensure_ascii=False, indent=2)
PY
ls -lh "$IMG" "$OUT_DIR/oemdrv.json"
echo "OK: $IMG"
