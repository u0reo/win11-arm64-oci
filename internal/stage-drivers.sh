#!/usr/bin/env bash
# Stage the virtio-win ARM64 drivers used by the unattended install.
#
# Sources:
#   DRIVERS_DIR=/path/to/dir             already extracted (flat or per-driver)
#   VIRTIO_RPM=/path/to/virtio-win.rpm   extract the by-driver tree from the RPM
#   VIRTIO_ISO=/path/to/virtio-win.iso   mount the ISO and read the same tree
#
# Output (OUT_DIR or BUILD_DIR; live defaults to /dev/shm/build):
#   drivers/        vioscsi + netkvm  (PnP customization)
#   drivers-extra/  viogpudo          (DISM only, OCI A1 has no GPU)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=live.sh
. "$HERE/live.sh"
OUT=${OUT_DIR:-$(default_build_dir "$ROOT/build")}
DEST="$OUT/drivers"
EXTRA="$OUT/drivers-extra"
VIRTIO_ISO=${VIRTIO_ISO:-}
VIRTIO_RPM=${VIRTIO_RPM:-}
DRIVERS_DIR=${DRIVERS_DIR:-}
MEDIA=${VIRTIO_RPM:-$VIRTIO_ISO}

rm -rf "$DEST" "$EXTRA"
mkdir -p "$DEST" "$EXTRA"

MNT=""
MOUNTED=0
RPM_DIR=""
cleanup() {
    set +e
    [ "$MOUNTED" = 1 ] && sudo -n umount "$MNT" 2>/dev/null
    [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
    [ -n "$RPM_DIR" ] && rm -rf "$RPM_DIR"
}
trap cleanup EXIT

copy_set() {
    local src=$1 dst=$2
    # netkvm.inf lists netkvmp.exe in SourceDisksFiles; DISM rejects the
    # whole package when it is absent, leaving the Windows image without a
    # network driver.  Copy executables along with inf/sys/cat.
    find "$src" -maxdepth 1 -type f \
        \( -iname '*.inf' -o -iname '*.sys' -o -iname '*.cat' \
           -o -iname '*.exe' \) \
        -exec cp -f -t "$dst" {} +
}

# An RPM carries the same by-driver/<name>/<os>/<arch> tree as the ISO, so the
# lookup below works for both.  Only by-driver is extracted: the payload also
# holds the whole 837 MiB ISO, which we do not need.
extract_rpm() {
    local rpm=$1 out=$2
    mkdir -p "$out"
    if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
        ( cd "$out" && rpm2cpio "$rpm" |
            cpio -idm --quiet --no-absolute-filenames '*/by-driver/*' )
    elif command -v bsdtar >/dev/null 2>&1; then
        ( cd "$out" && bsdtar -xf "$rpm" --include '*/by-driver/*' )
    else
        echo "[drivers] cannot read an RPM: install rpm2cpio and cpio" >&2
        echo "  sudo apt-get install -y rpm2cpio cpio" >&2
        echo "  (or install bsdtar from libarchive-tools)" >&2
        exit 1
    fi
    if [ -z "$(find "$out" -type d -name by-driver -print -quit)" ]; then
        echo "[drivers] no drivers/by-driver tree in $rpm" >&2
        echo "  is this a virtio-win noarch RPM?" >&2
        exit 1
    fi
}

if [ -n "$DRIVERS_DIR" ]; then
    [ -d "$DRIVERS_DIR" ] || { echo "missing DRIVERS_DIR: $DRIVERS_DIR" >&2; exit 1; }
    echo "[drivers] copying from $DRIVERS_DIR"
    # Accept a flat directory or per-driver subdirectories.
    for pat in vioscsi netkvm; do
        if find "$DRIVERS_DIR" -maxdepth 1 -iname "${pat}*.inf" | grep -q .; then
            find "$DRIVERS_DIR" -maxdepth 1 -type f \
                \( -iname "${pat}*.inf" -o -iname "${pat}*.sys" \
                   -o -iname "${pat}*.cat" -o -iname "${pat}*.exe" \) \
                -exec cp -f -t "$DEST" {} +
        else
            find "$DRIVERS_DIR" -type d -iname "${pat}*" -print0 |
                while IFS= read -r -d '' d; do copy_set "$d" "$DEST"; done
        fi
    done
    find "$DRIVERS_DIR" -type d -iname 'viogpudo*' -print0 |
        while IFS= read -r -d '' d; do copy_set "$d" "$EXTRA"; done
elif [ -n "$MEDIA" ]; then
    [ -f "$MEDIA" ] || { echo "missing virtio-win media: $MEDIA" >&2; exit 1; }
    case "$MEDIA" in
        *.rpm|*.RPM)
            RPM_DIR=$(mktemp -d /tmp/virtio-rpm.XXXXXX)
            echo "[drivers] extracting ARM64 drivers from $MEDIA"
            extract_rpm "$MEDIA" "$RPM_DIR"
            SRC=$RPM_DIR
            ;;
        *)
            MNT=$(mktemp -d /tmp/virtio.XXXXXX)
            echo "[drivers] mounting $MEDIA"
            sudo -n mkdir -p "$MNT"
            if ! sudo -n mount -t udf -o ro,loop "$MEDIA" "$MNT" 2>/dev/null; then
                sudo -n mount -t iso9660 -o ro,loop "$MEDIA" "$MNT"
            fi
            MOUNTED=1
            SRC=$MNT
            ;;
    esac

    # ISO: <root>/<driver>/<os>/<arch>.  RPM: .../drivers/by-driver/<driver>/<os>/<arch>.
    for pat in vioscsi netkvm; do
        src=$(find "$SRC" -type d -ipath "*/${pat}/*/arm64" | head -1)
        [ -n "$src" ] || { echo "no arm64 ${pat} set in $MEDIA" >&2; exit 1; }
        echo "  $pat <- ${src#"$SRC"/}"
        copy_set "$src" "$DEST"
    done
    src=$(find "$SRC" -type d -ipath '*/viogpudo/*/arm64' | head -1)
    if [ -n "$src" ]; then
        echo "  viogpudo <- ${src#"$SRC"/}"
        copy_set "$src" "$EXTRA"
    fi
else
    echo "set VIRTIO_RPM, VIRTIO_ISO or DRIVERS_DIR" >&2
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
