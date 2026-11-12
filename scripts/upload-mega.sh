#!/usr/bin/env bash
# Upload build artifacts to MEGA with rclone.
#
# Required environment:
#   MEGA_USER            MEGA account e-mail
#   MEGA_PASS_OBSCURED   output of `rclone obscure 'password'`
# Optional:
#   MEGA_2FA_SECRET      base32 TOTP secret (only if 2FA is enabled)
#   MEGA_REMOTE_PATH     destination folder (default: win11-arm64)
#
# Usage: ./upload-mega.sh file1 [file2 ...]
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <file> [...]" >&2; exit 1; }
: "${MEGA_USER:?set MEGA_USER}"
: "${MEGA_PASS_OBSCURED:?set MEGA_PASS_OBSCURED (rclone obscure output)}"
REMOTE_PATH=${MEGA_REMOTE_PATH:-win11-arm64}

export RCLONE_CONFIG_MEGA_TYPE=mega
export RCLONE_CONFIG_MEGA_USER="$MEGA_USER"
export RCLONE_CONFIG_MEGA_PASS="$MEGA_PASS_OBSCURED"
export RCLONE_CONFIG_MEGA_HARD_DELETE=true

if [ -n "${MEGA_2FA_SECRET:-}" ]; then
    command -v oathtool >/dev/null 2>&1 || {
        echo "MEGA_2FA_SECRET is set but oathtool is not installed" >&2
        exit 1
    }
    MEGA_2FA_CODE=$(oathtool --totp -b "$MEGA_2FA_SECRET")
    export RCLONE_CONFIG_MEGA_2FA="$MEGA_2FA_CODE"
fi

echo "[mega] destination: mega:$REMOTE_PATH"
rclone mkdir "mega:$REMOTE_PATH"

for f in "$@"; do
    [ -f "$f" ] || { echo "missing file: $f" >&2; exit 1; }
    name=$(basename "$f")
    echo "[mega] uploading $name ($(stat -c %s "$f") bytes)"
    # One login per invocation; do not run many rclone commands in a loop.
    rclone copyto "$f" "mega:$REMOTE_PATH/$name" \
        --transfers 1 --checkers 1 \
        --retries 3 --low-level-retries 10 \
        --stats 30s --stats-one-line
    remote_size=$(rclone size --json "mega:$REMOTE_PATH/$name" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')
    local_size=$(stat -c %s "$f")
    if [ "$remote_size" != "$local_size" ]; then
        echo "[mega] size mismatch for $name: local=$local_size remote=$remote_size" >&2
        exit 1
    fi
    echo "[mega] ok $name ($remote_size bytes)"
    sleep 3
done
echo "[mega] done"
