#!/usr/bin/env bash
# Boot an Ubuntu live ISO with `toram`, whichever Ubuntu is on this disk.
#
#   sudo ./scripts/boot-live.sh [ISO] [options]
#
# Must be run as root; the script never calls sudo itself.
#
# Defaults:
#   ISO     the single /srv/iso/*live-server-arm64*.iso; pass the path when
#           there is no match or more than one (this is an error)
#   mode    auto: standard when update-grub + grub-reboot are available,
#           otherwise recovery
#   boot    --once (next boot only; --default is standard mode only)
#   ssh     on: cloud-init seed on the ESP, relabelled CIDATA (/dev/shm 100%)
#
# Mode standard (OCI's standard Ubuntu image, plain GRUB):
#   writes the entry to /etc/grub.d/40_custom, runs update-grub and boots it
#   once with grub-reboot (or persistently with --default).
# Mode recovery (this project's recovery Ubuntu):
#   writes the ESP's own \EFI\ubuntu\grub.cfg with write_grub_menu.py and
#   selects the live entry once via next_entry.  No update-grub needed.
#
# Options:
#   --mode auto|standard|recovery  override mode detection
#   --once           next boot only (default)
#   --default        standard mode only: make the live entry the GRUB default
#   --no-ssh         skip the seed and ds=nocloud
#   --timeout SEC    recovery mode only: ESP menu timeout (default 5)
#   -h, --help
#
# The ISO must be on a real filesystem with a UUID (not tmpfs / FUSE): GRUB
# reads it with loopback after the reboot.  toram then copies the live root
# into RAM so /dev/sda can be overwritten by build.sh.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() {
    echo "boot-live: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

ISO=
MODE=auto
ONCE=1
DEFAULT=0
SSH=1
TIMEOUT=5
ESP=${ESP:-/boot/efi}
NAME="Ubuntu live (toram)"

if [ $# -gt 0 ]; then
    case "$1" in
        -h|--help) usage 0 ;;
        -*) ;;
        *) ISO=$1; shift ;;
    esac
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE=${2:?--mode needs auto, standard or recovery}; shift 2 ;;
        --once) ONCE=1; DEFAULT=0; shift ;;
        --default) DEFAULT=1; ONCE=0; shift ;;
        --no-ssh) SSH=0; shift ;;
        --timeout) TIMEOUT=${2:?--timeout needs seconds}; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "boot-live: unknown argument: $1" >&2; usage 1 ;;
    esac
done

if [ -z "$ISO" ]; then
    mapfile -d '' -t MATCHES < <(
        find /srv/iso -maxdepth 1 -type f -name '*live-server-arm64*.iso' \
            -print0 2>/dev/null || true
    )
    [ "${#MATCHES[@]}" -eq 1 ] ||
        die "expected one /srv/iso/*live-server-arm64*.iso, found ${#MATCHES[@]}; pass the path explicitly"
    ISO=${MATCHES[0]}
    echo "boot-live: found $ISO"
fi
[[ $TIMEOUT =~ ^[0-9]+$ ]] || die "--timeout must be seconds (an integer)"
case "$MODE" in
    auto|AUTO) MODE=auto ;;
    standard|STANDARD) MODE=standard ;;
    recovery|RECOVERY) MODE=recovery ;;
    *) die "--mode must be auto, standard or recovery" ;;
esac
[ "$MODE" = recovery ] && [ "$DEFAULT" = 1 ] &&
    die "--default is only supported in standard mode"

# --- the ISO itself --------------------------------------------------------
[ -f "$ISO" ] || die "missing $ISO"
ISO=$(realpath -e "$ISO")
MNT=$(findmnt -no TARGET --target "$ISO" 2>/dev/null || true)
UUID=$(findmnt -no UUID --target "$ISO" 2>/dev/null || true)
FSTYPE=$(findmnt -no FSTYPE --target "$ISO" 2>/dev/null || true)
[ -n "$MNT" ] && [ -n "$UUID" ] ||
    die "$ISO is not on a mounted filesystem with a UUID"
case "$FSTYPE" in
    tmpfs|ramfs) die "$ISO is on $FSTYPE; GRUB cannot read it after a reboot" ;;
esac
REL=${ISO#"$MNT"}
case "$REL" in /*) ;; *) REL="/$REL" ;; esac
ISO_TYPE=$(blkid -p -s TYPE -o value "$ISO" 2>/dev/null || true)
case "$ISO_TYPE" in
    iso9660|udf) ;;
    *) echo "boot-live: warning: $ISO does not look like an ISO ($ISO_TYPE)" >&2 ;;
esac

# --- detect which GRUB actually boots this disk ----------------------------
if [ "$MODE" = auto ]; then
    if command -v update-grub >/dev/null 2>&1 &&
        command -v grub-reboot >/dev/null 2>&1 &&
        test -f /boot/grub/grub.cfg; then
        MODE=standard
    else
        MODE=recovery
    fi
fi
echo "== mode $MODE =="
echo "  ISO: $ISO"
echo "  fs:  $MNT (UUID $UUID), path $REL"

# --- cloud-init seed for SSH in the live session ---------------------------
if [ "$SSH" = 1 ]; then
    echo "== cloud-init seed (ESP -> CIDATA) =="
    "$HERE/live-seed.sh" --esp "$ESP"
else
    echo "== no cloud-init seed (--no-ssh) =="
fi

if [ "$MODE" = standard ]; then
    # --- plain Ubuntu GRUB: /etc/grub.d/40_custom --------------------------
    ID=win11-live-toram
    BEGIN="# BEGIN win11-arm64-oci:toram"
    END="# END win11-arm64-oci:toram"
    GRUB_CUSTOM=${GRUB_CUSTOM:-/etc/grub.d/40_custom}
    GRUB_CFG=${GRUB_CFG:-/boot/grub/grub.cfg}
    GRUB_DEFAULT_FILE=${GRUB_DEFAULT_FILE:-/etc/default/grub}
    GRUB_DEFAULT_BACKUP=${GRUB_DEFAULT_BACKUP:-/etc/default/grub.win11-arm64-oci.bak}

    CMDLINE="toram ip=dhcp console=ttyAMA0,115200"
    [ "$SSH" = 1 ] && CMDLINE="$CMDLINE ds=nocloud"

    entry() {
        cat <<EOF
$BEGIN
menuentry "$NAME" --id $ID {
    insmod part_gpt
    insmod ext2
    insmod loopback
    insmod iso9660
    search --no-floppy --fs-uuid --set=root $UUID
    set isofile="$REL"
    loopback loop \$isofile
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=\$isofile \\
        $CMDLINE ---
    initrd (loop)/casper/initrd
}
$END
EOF
    }

    echo "== GRUB entry ($GRUB_CUSTOM) =="
    TMP=$(mktemp /tmp/boot-live-grub.XXXXXX)
    TMP2=""
    trap 'rm -f "$TMP" "${TMP2:-}"' EXIT
    if test -f "$GRUB_CUSTOM"; then
        awk -v b="$BEGIN" -v e="$END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$GRUB_CUSTOM" > "$TMP"
    else
        cat > "$TMP" <<'EOF'
#!/bin/sh
exec tail -n +3 $0
# Custom entries added by win11-arm64-oci.
EOF
    fi
    entry >> "$TMP"
    install -m 0755 "$TMP" "$GRUB_CUSTOM"

    if [ "$DEFAULT" = 1 ]; then
        test -f "$GRUB_DEFAULT_FILE" ||
            die "$GRUB_DEFAULT_FILE not found"
        if ! test -f "$GRUB_DEFAULT_BACKUP"; then
            cp -p "$GRUB_DEFAULT_FILE" "$GRUB_DEFAULT_BACKUP"
        fi
        TMP2=$(mktemp /tmp/boot-live-default.XXXXXX)
        awk -v b="# BEGIN win11-arm64-oci:default" \
                  -v e="# END win11-arm64-oci:default" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            skip    { next }
            /^[[:space:]]*GRUB_DEFAULT=/ { next }
            { print }
        ' "$GRUB_DEFAULT_FILE" > "$TMP2"
        {
            printf '%s\n' "# BEGIN win11-arm64-oci:default"
            printf 'GRUB_DEFAULT=%s\n' "$ID"
            printf '%s\n' "# END win11-arm64-oci:default"
        } >> "$TMP2"
        install -m 0644 "$TMP2" "$GRUB_DEFAULT_FILE"
    fi

    update-grub
    if ! grep -q -- "--id $ID" "$GRUB_CFG" 2>/dev/null; then
        echo "boot-live: warning: $ID is not in $GRUB_CFG" >&2
    fi
    if [ "$ONCE" = 1 ]; then
        if ! test -f /boot/grub/grubenv; then
            grub-editenv - create
        fi
        grub-reboot "$ID"
        NEXT=$(grub-editenv - list 2>/dev/null |
            sed -n 's/^next_entry=//p' || true)
        [ "$NEXT" = "$ID" ] ||
            echo "boot-live: warning: next_entry is '${NEXT:-unset}', expected '$ID'" >&2
    elif [ "$DEFAULT" = 0 ] && test -f "$GRUB_DEFAULT_FILE"; then
        TIMEOUT_VALUE=$(sed -n 's/^GRUB_TIMEOUT=//p' \
            "$GRUB_DEFAULT_FILE" | tail -1)
        case "$TIMEOUT_VALUE" in
            0|0.0)
                echo "boot-live: warning: GRUB_TIMEOUT is 0, so the menu may not appear." >&2
                echo "  use --once or --default to select the live entry." >&2
                ;;
        esac
    fi
else
    # --- recovery Ubuntu: the ESP's own grub.cfg ---------------------------
    [ -d "$ESP/EFI/ubuntu" ] || die "$ESP is not the ESP"
    # write_grub_menu.py writes the Windows entry first and chainloads this
    # file; it refuses to run when it is missing.  It only exists after a
    # build has installed Windows on this disk.
    [ -f "$ESP/EFI/Microsoft/Boot/bootmgfw.efi" ] ||
        die "$ESP/EFI/Microsoft/Boot/bootmgfw.efi not found; the recovery menu chainloads it (use --mode standard for a not-yet-built disk)"
    ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
    [ -n "$ROOTDEV" ] || die "cannot find the root device"

    echo "== ESP GRUB menu ($ESP/EFI/ubuntu/grub.cfg) =="
    CMD=(python3 "$HERE/../pipeline/write_grub_menu.py" "$ESP" / "$ROOTDEV"
         --timeout "$TIMEOUT" --live-iso "$ISO" --live-label "$NAME")
    [ "$SSH" = 1 ] && CMD+=(--live-seed)
    [ "$ONCE" = 1 ] && CMD+=(--first-boot-live)
    "${CMD[@]}"
fi

echo
echo "boot-live: reboot to run '$NAME' ($ISO) with toram."
if [ "$ONCE" = 1 ]; then
    echo "  the live entry is selected once; the old default returns afterwards."
fi
if [ "$SSH" = 1 ]; then
    echo "  ESP is labelled CIDATA.  Restore it later with:"
    echo "    fatlabel $ESP \"\$(cat $ESP/win11-arm64-oci-esp-label)\""
fi
