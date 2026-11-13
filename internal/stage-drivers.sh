#!/usr/bin/env bash
# Stage the virtio-win ARM64 drivers used by the unattended install.
#
# Two sources are supported:
#   VIRTIO_ISO=/path/to/virtio-win.iso   (extract w11/arm64 sets)
#   DRIVERS_DIR=/path/to/flat/dir        (already extracted)
#
# Output:
#   build/drivers/        vioscsi + netkvm  (PnP customization)
#   build/drivers-extra/  viogpudo          (DISM only, OCI A1 has no GPU)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=${OUT_DIR:-$ROOT/build}
DEST="$OUT/drivers"
EXTRA="$OUT/drivers-extra"
VIRTIO_ISO=${VIRTIO_ISO:-}
DRIVERS_DIR=${DRIVERS_DIR:-}

rm -rf "$DEST" "$EXTRA"
mkdir -p "$DEST" "$EXTRA"

copy_set() {
    local src=$1 dst=$2
    find "$src" -maxdepth 1 -type f \
        \( -iname '*.inf' -o -iname '*.sys' -o -iname '*.cat' \) \
        -exec cp -f -t "$dst" {} +
}

if [ -n "$DRIVERS_DIR" ]; then
    [ -d "$DRIVERS_DIR" ] || { echo "missing DRIVERS_DIR: $DRIVERS_DIR" >&2; exit 1; }
    echo "[drivers] copying from $DRIVERS_DIR"
    # Accept a flat directory or per-driver subdirectories.
    for pat in vioscsi netkvm; do
        if find "$DRIVERS_DIR" -maxdepth 1 -iname "${pat}*.inf" | grep -q .; then
            find "$DRIVERS_DIR" -maxdepth 1 -type f \
                \( -iname "${pat}*.inf" -o -iname "${pat}*.sys" -o -iname "${pat}*.cat" \) \
                -exec cp -f -t "$DEST" {} +
        else
            find "$DRIVERS_DIR" -type d -iname "${pat}*" -print0 |
                while IFS= read -r -d '' d; do copy_set "$d" "$DEST"; done
        fi
    done
    find "$DRIVERS_DIR" -type d -iname 'viogpudo*' -print0 |
        while IFS= read -r -d '' d; do copy_set "$d" "$EXTRA"; done
elif [ -n "$VIRTIO_ISO" ]; then
    [ -f "$VIRTIO_ISO" ] || { echo "missing VIRTIO_ISO: $VIRTIO_ISO" >&2; exit 1; }
    MNT=$(mktemp -d /tmp/virtio.XXXXXX)
    MOUNTED=0
    cleanup() {
        set +e
        [ "$MOUNTED" = 1 ] && sudo -n umount "$MNT" 2>/dev/null
        rmdir "$MNT" 2>/dev/null
    }
    trap cleanup EXIT
    echo "[drivers] mounting $VIRTIO_ISO"
    sudo -n mkdir -p "$MNT"
    if ! sudo -n mount -t udf -o ro,loop "$VIRTIO_ISO" "$MNT" 2>/dev/null; then
        sudo -n mount -t iso9660 -o ro,loop "$VIRTIO_ISO" "$MNT"
    fi
    MOUNTED=1
    # Typical layout: virtio-win/<driver>/w11/arm64/*.{inf,sys,cat}
    for pat in vioscsi netkvm; do
        src=$(find "$MNT" -type d -ipath "*/${pat}/*/arm64" | head -1)
        [ -n "$src" ] || { echo "no arm64 ${pat} set in ISO" >&2; exit 1; }
        echo "  $pat <- ${src#$MNT/}"
        copy_set "$src" "$DEST"
    done
    src=$(find "$MNT" -type d -ipath '*/viogpudo/*/arm64' | head -1)
    if [ -n "$src" ]; then
        echo "  viogpudo <- ${src#$MNT/}"
        copy_set "$src" "$EXTRA"
    fi
else
    echo "set VIRTIO_ISO or DRIVERS_DIR" >&2
    exit 1
fi

for f in vioscsi.inf netkvm.inf; do
    find "$DEST" -maxdepth 1 -iname "$f" | grep -q . || {
        echo "missing $f in $DEST" >&2
        exit 1
    }
done

echo "[drivers] $(find "$DEST" -maxdepth 1 -type f | wc -l) files in drivers/, $(find "$EXTRA" -maxdepth 1 -type f | wc -l) in drivers-extra/"
ls -1 "$DEST" | head -20
