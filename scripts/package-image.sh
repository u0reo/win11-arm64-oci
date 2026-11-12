#!/usr/bin/env bash
# Compress a qcow2 for storage.  Encryption is optional and off by default.
#
#   IMAGE=build/win11-arm64.qcow2 ./package-image.sh
#
# Environment:
#   IMAGE          input qcow2 (required)
#   OUT_DIR        output dir (default: build/artifacts)
#   AGE_RECIPIENT  if set, encrypt with age (recommended before cloud upload)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
IMAGE=${IMAGE:?set IMAGE=/path/to/disk.qcow2}
OUT_DIR=${OUT_DIR:-$ROOT/build/artifacts}
mkdir -p "$OUT_DIR"

[ -f "$IMAGE" ] || { echo "missing image: $IMAGE" >&2; exit 1; }
BASE=$(basename "$IMAGE" .qcow2)
ZST="$OUT_DIR/$BASE.qcow2.zst"

echo "[1/3] compressing with zstd -3 -T0"
zstd -3 -T0 -f "$IMAGE" -o "$ZST"
sha256sum "$ZST" > "$ZST.sha256"

if [ -n "${AGE_RECIPIENT:-}" ]; then
    echo "[2/3] encrypting with age"
    age -e -r "$AGE_RECIPIENT" -o "$ZST.age" "$ZST"
    sha256sum "$ZST.age" > "$ZST.age.sha256"
    echo "  $ZST.age"
    ls -lh "$ZST.age" "$ZST.age.sha256"
else
    echo "[2/3] encryption skipped (AGE_RECIPIENT not set)"
fi

echo "[3/3] done"
ls -lh "$ZST" "$ZST.sha256"
