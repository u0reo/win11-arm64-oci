#!/usr/bin/env bash
# One-shot build on an OCI Ampere A1 Ubuntu instance.
#
#   sudo ./scripts/oci-run.sh --iso /srv/iso/Win11_ARM64_26H2.iso --deliver ssh
#
# Steps:
#   1. preflight (tools, disk, firmware)
#   2. resolve the ISO (local path, https URL or rclone remote)
#   3. run scripts/build-image.sh
#   4. deliver the result
#
# Delivery modes (--deliver):
#   ssh     leave the files in build/artifacts and print the scp command
#   mega    upload with scripts/upload-mega.sh   (MEGA_USER/MEGA_PASS_OBSCURED)
#   rclone  upload with rclone                   (RCLONE_TARGET=remote:path)
#   image   register as an OCI custom image      (scripts/oci-image.sh)
#   none    stop after the build
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BUILD=${BUILD_DIR:-$ROOT/build}
ART="$BUILD/artifacts"

ISO_SRC=${ISO:-}
ISO_SHA=${ISO_SHA256:-}
DELIVER=${DELIVER:-ssh}
IMAGE_INDEX=${IMAGE_INDEX:-1}
SIZE=${SIZE:-50G}
MEM=${MEM:-8192}
SMP=${SMP:-4}
SKIP_BUILD=0
OCI_ARGS=()

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iso) ISO_SRC=$2; shift 2 ;;
        --iso-sha256) ISO_SHA=$2; shift 2 ;;
        --deliver) DELIVER=$2; shift 2 ;;
        --image-index) IMAGE_INDEX=$2; shift 2 ;;
        --size) SIZE=$2; shift 2 ;;
        --mem) MEM=$2; shift 2 ;;
        --smp) SMP=$2; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage 0 ;;
        --) shift; OCI_ARGS+=("$@"); break ;;
        *) echo "oci-run: unknown argument: $1" >&2; usage 1 ;;
    esac
done

case "$DELIVER" in
    ssh|mega|rclone|image|none) ;;
    *) echo "oci-run: --deliver must be ssh, mega, rclone, image or none" >&2; exit 1 ;;
esac

step() { echo; echo "==== $* ===="; }

if [ "$SKIP_BUILD" = 0 ]; then
    step "1/4 preflight"
    if ! "$HERE/preflight.sh"; then
        echo "oci-run: preflight failed.  Run scripts/bootstrap-ubuntu.sh first." >&2
        exit 1
    fi

    step "2/4 resolve ISO"
    [ -n "$ISO_SRC" ] || { echo "oci-run: --iso is required" >&2; usage 1; }
    case "$ISO_SRC" in
        http://*|https://*|mega:*|gdrive:*|onedrive:*|s3:*)
            ISO_PATH="$BUILD/iso/$(basename "${ISO_SRC##*:}")"
            "$HERE/fetch-iso.sh" "$ISO_SRC" "$ISO_PATH" "$ISO_SHA"
            ;;
        *)
            ISO_PATH=$ISO_SRC
            if [ ! -f "$ISO_PATH" ]; then
                # maybe an rclone remote without a known prefix
                ISO_PATH="$BUILD/iso/$(basename "$ISO_SRC")"
                "$HERE/fetch-iso.sh" "$ISO_SRC" "$ISO_PATH" "$ISO_SHA"
            fi
            ;;
    esac
    [ -f "$ISO_PATH" ] || { echo "oci-run: missing ISO $ISO_PATH" >&2; exit 1; }
    if [ -n "$ISO_SHA" ]; then
        GOT=$(sha256sum "$ISO_PATH" | awk '{print $1}')
        [ "$GOT" = "$ISO_SHA" ] || { echo "oci-run: ISO sha256 mismatch" >&2; exit 1; }
    fi
    echo "  ISO $ISO_PATH"

    step "3/4 build"
    ISO="$ISO_PATH" IMAGE_INDEX="$IMAGE_INDEX" SIZE="$SIZE" MEM="$MEM" SMP="$SMP" \
        SKIP_UPLOAD=1 "$HERE/build-image.sh"
else
    step "1/4-3/4 skipped (--skip-build)"
fi

step "4/4 deliver ($DELIVER)"
QCOW2="$BUILD/win11-arm64.qcow2"
ZST=$(ls -1 "$ART"/*.qcow2.zst 2>/dev/null | head -1 || true)

case "$DELIVER" in
    none)
        echo "  artifacts left in $ART"
        ;;
    ssh)
        IP=$(curl -s -H 'Authorization: Bearer Oracle' -m 5 \
            http://169.254.169.254/opc/v2/vnics/0/publicIp 2>/dev/null || true)
        [ -n "$IP" ] || IP=$(curl -s -m 5 https://ifconfig.me 2>/dev/null || true)
        echo "  download from your workstation:"
        echo
        echo "    scp ${USER:-ubuntu}@${IP:-<public-ip>}:$ART/*.zst ."
        echo "    scp ${USER:-ubuntu}@${IP:-<public-ip>}:$ART/*.sha256 ."
        echo
        echo "  (12.8 GiB compressed; OCI egress is free up to 10 TB/month)"
        ;;
    mega)
        [ -n "${MEGA_USER:-}" ] || { echo "oci-run: MEGA_USER is not set" >&2; exit 1; }
        "$HERE/upload-mega.sh" "$ART"/*.zst "$ART"/*.sha256
        ;;
    rclone)
        : "${RCLONE_TARGET:?set RCLONE_TARGET=remote:path}"
        echo "  rclone copy $ART -> $RCLONE_TARGET"
        rclone copy "$ART" "$RCLONE_TARGET" --progress --transfers 1
        ;;
    image)
        [ -f "$QCOW2" ] || { echo "oci-run: missing $QCOW2" >&2; exit 1; }
        "$HERE/oci-image.sh" --image "$QCOW2" --name "win11-arm64-$(date +%Y%m%d-%H%M)" \
            "${OCI_ARGS[@]}"
        ;;
esac

echo
echo "oci-run: done"
ls -lh "$ART" 2>/dev/null || true
[ -n "$ZST" ] && echo "compressed: $ZST"
