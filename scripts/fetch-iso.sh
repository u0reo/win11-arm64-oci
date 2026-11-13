#!/usr/bin/env bash
# Download the Windows 11 ARM64 ISO from a URL or an rclone remote.
#
#   ./scripts/fetch-iso.sh https://host/Win11.iso build/iso/Win11.iso [sha256]
#   ./scripts/fetch-iso.sh mega:win11/Win11.iso build/iso/Win11.iso
#
# A local file is linked/copied without network access.
set -euo pipefail

SRC=${1:?usage: $0 <path|https-url|rclone-remote> <dest> [sha256]}
DEST=${2:?usage: $0 <path|https-url|rclone-remote> <dest> [sha256]}
WANT_SHA=${3:-}

mkdir -p "$(dirname "$DEST")"
PART="$DEST.part"

case "$SRC" in
    http://*|https://*)
        echo "[iso] curl $SRC"
        curl -fL --retry 3 --retry-delay 5 --continue-at - -o "$PART" "$SRC"
        ;;
    *)
        if [ -f "$SRC" ]; then
            echo "[iso] local file $SRC"
            if [ "$(stat -c %d "$SRC")" = "$(stat -c %d "$(dirname "$DEST")")" ]; then
                ln -f "$SRC" "$PART" 2>/dev/null || cp -f "$SRC" "$PART"
            else
                cp -f "$SRC" "$PART"
            fi
        elif [[ "$SRC" == *:* ]]; then
            command -v rclone >/dev/null 2>&1 || {
                echo "fetch-iso: rclone is required for $SRC" >&2
                exit 1
            }
            echo "[iso] rclone copyto $SRC"
            rclone copyto "$SRC" "$PART" --stats 30s --stats-one-line
        else
            echo "fetch-iso: no such file and not a remote: $SRC" >&2
            exit 1
        fi
        ;;
esac

if [ -n "$WANT_SHA" ]; then
    echo "[iso] verifying sha256"
    GOT=$(sha256sum "$PART" | awk '{print $1}')
    if [ "$GOT" != "$WANT_SHA" ]; then
        echo "fetch-iso: sha256 mismatch" >&2
        echo "  expected $WANT_SHA" >&2
        echo "  actual   $GOT" >&2
        exit 1
    fi
fi

mv -f "$PART" "$DEST"
echo "[iso] ready: $DEST ($(stat -c %s "$DEST") bytes)"
