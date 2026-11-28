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
#   boot    next boot only (one-shot; no persistent GRUB change)
#   ssh     on: cloud-init seed on the ESP, relabelled CIDATA (/dev/shm 100%)
#
# Mode standard (OCI's standard Ubuntu image, plain GRUB):
#   writes the entry to /etc/grub.d/40_custom, runs update-grub and boots it
#   once with grub-reboot.
# Mode recovery (this project's recovery Ubuntu):
#   writes the ESP's own \EFI\ubuntu\grub.cfg with write_grub_menu.py and
#   selects the live entry once via next_entry.  No update-grub needed.
#
# Options:
#   --mode auto|standard|recovery  override mode detection
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

# cloud-init seed for the live session.  Writes user-data/meta-data to the
# ESP, relabels it CIDATA and saves the old label.  The seed creates the
# user `ubuntu` with this machine's authorized_keys, passwordless sudo and
# sshd, makes /dev/shm/iso and /dev/shm/build, and remounts /dev/shm at 100%
# of RAM.  runcmd restores the ESP label after cloud-init has read the seed
# (best-effort: the live image may not have fatlabel).
SEED_KEYS=""
seed_add_keys() {
    [ -f "$1" ] || return 0
    # Keep only "type base64 [comment]".  authorized_keys lines may carry
    # options, and cloud images guard the root key with a command= option;
    # passing that to ssh_authorized_keys would not start a shell.
    SEED_KEYS+=$(awk '
        NF && $1 !~ /^#/ {
            for (i = 1; i < NF; i++) {
                if ($i ~ /^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[^,]+|sk-[^,]+)$/ &&
                    length($(i + 1)) > 40) {
                    line = $i
                    for (j = i + 1; j <= NF; j++) line = line " " $j
                    print line
                    break
                }
            }
        }' "$1")$'\n'
}

write_live_seed() {
    local esp=$1 esp_dev espdir esp_want keys_yaml old_label label_restore

    esp_dev=$(findmnt -no SOURCE --target "$esp" 2>/dev/null || true)
    espdir=$(findmnt -no TARGET --target "$esp" 2>/dev/null || true)
    espdir=$(realpath -e "$espdir" 2>/dev/null || true)
    esp_want=$(realpath -e "$esp" 2>/dev/null || true)
    [ -n "$esp_dev" ] && [ -n "$espdir" ] && [ "$espdir" = "$esp_want" ] ||
        die "$esp is not mounted; mount the ESP first"

    SEED_KEYS=""
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        seed_add_keys "/home/$SUDO_USER/.ssh/authorized_keys"
    fi
    seed_add_keys /root/.ssh/authorized_keys
    local f
    for f in /home/*/.ssh/authorized_keys; do
        [ -e "$f" ] && seed_add_keys "$f"
    done
    SEED_KEYS=$(printf '%s' "$SEED_KEYS" | awk 'NF && !seen[$0]++')
    [ -n "$SEED_KEYS" ] ||
        die "no authorized_keys found in /home/*/.ssh or /root/.ssh"

    keys_yaml=$(printf '%s\n' "$SEED_KEYS" | sed 's/^/      - /')
    # blkid reads the label without fatlabel's "boot sector and its backup"
    # warning on stdout.
    old_label=$(blkid -s LABEL -o value "$esp_dev" 2>/dev/null || true)
    label_restore=""
    if [ -n "$old_label" ] && [ "$old_label" != CIDATA ]; then
        label_restore=$(printf "  - sh -c 'command -v fatlabel >/dev/null 2>&1 && { umount %s 2>/dev/null || true; fatlabel %s %q || true; } || true'\n" \
            "$esp_dev" "$esp_dev" "$old_label")
    fi

    cat > "$espdir/user-data" <<EOF
#cloud-config
ssh_pwauth: false
users:
  - default
  - name: ubuntu
    gecos: Ubuntu
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
$keys_yaml
runcmd:
  - systemctl enable --now ssh
  - sh -c 'mkdir -p /dev/shm/iso /dev/shm/build && chmod 1777 /dev/shm/iso /dev/shm/build'
  - sh -c 'mount -o remount,size=100% /dev/shm || true'
$label_restore
EOF
    printf 'instance-id: win11-arm64-oci-live\nlocal-hostname: win11-live\n' |
        tee "$espdir/meta-data" >/dev/null

    # NoCloud finds a vfat filesystem labelled CIDATA.  A block device path
    # is not a valid seedfrom URI, so relabel the ESP.
    if [ "$old_label" != CIDATA ]; then
        printf '%s\n' "${old_label:-}" | tee "$espdir/win11-arm64-oci-esp-label" >/dev/null
        fatlabel "$esp_dev" CIDATA >/dev/null ||
            die "fatlabel failed for $esp_dev (install dosfstools)"
        echo "boot-live: labelled the ESP CIDATA (was '${old_label:-none}')"
        echo "  restore later with: fatlabel $esp_dev '${old_label:-}'"
    fi
    echo "boot-live: wrote $espdir/user-data and meta-data (ssh keys: $(printf '%s\n' "$SEED_KEYS" | wc -l))"
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

ISO=
MODE=auto
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
    write_live_seed "$ESP"
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

    CMDLINE="toram noprompt ip=dhcp console=ttyAMA0,115200"
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
    TMP3=""
    trap 'rm -f "$TMP" "${TMP3:-}"' EXIT
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

    # OCI's ARM64 firmware mirrors the EFI console to the serial console.
    # gfxterm binds to GOP instead, and GRUB's own serial driver is an x86
    # COM-port driver that fails on ARM64.  Force the EFI console so the menu
    # is visible and usable on the OCI serial console.  A drop-in overrides
    # whatever /etc/default/grub.d/50-cloudimg-settings.cfg sets.
    GRUB_CONSOLE_DROPIN=/etc/default/grub.d/99-win11-arm64-oci-console.cfg
    mkdir -p "$(dirname "$GRUB_CONSOLE_DROPIN")"
    cat > "$GRUB_CONSOLE_DROPIN" <<'EOF'
# Generated by scripts/boot-live.sh.  Do not edit by hand.
GRUB_TERMINAL_INPUT="console"
GRUB_TERMINAL_OUTPUT="console"
# OCI/cloud images may set GRUB_TIMEOUT=-1, which waits for a key forever.
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
EOF

    # OCI's Ubuntu mounts the ESP with LABEL=UEFI in /etc/fstab.  The seed
    # relabels the ESP to CIDATA, so a later boot would wait 90s for a device
    # that no longer exists.  Pin /boot/efi to the partition's PARTUUID and
    # add nofail so the label change cannot break the host's next boot.
    ESP_DEV=$(findmnt -no SOURCE --target "$ESP" 2>/dev/null || true)
    ESP_PARTUUID=$(blkid -s PARTUUID -o value "$ESP_DEV" 2>/dev/null || true)
    if [ -n "$ESP_PARTUUID" ] &&
        grep -qE '^[^#[:space:]]+[[:space:]]+/boot/efi/?[[:space:]]' /etc/fstab 2>/dev/null; then
        if ! test -f /etc/fstab.win11-arm64-oci.bak; then
            cp -p /etc/fstab /etc/fstab.win11-arm64-oci.bak ||
                die "cannot back up /etc/fstab"
        fi
        TMP3=$(mktemp /tmp/boot-live-fstab.XXXXXX)
        awk -v dev="PARTUUID=$ESP_PARTUUID" '
            $2 ~ /^\/boot\/efi\/?$/ {
                $1 = dev
                if ($4 == "") $4 = "defaults"
                if ($4 !~ /(^|,)nofail(,|$)/) $4 = $4 ",nofail"
                if ($4 !~ /(^|,)x-systemd[.]device-timeout=/)
                    $4 = $4 ",x-systemd.device-timeout=10s"
            }
            { print }
        ' /etc/fstab > "$TMP3"
        install -m 0644 "$TMP3" /etc/fstab
        echo "boot-live: pinned /boot/efi to PARTUUID=$ESP_PARTUUID in /etc/fstab"
    fi

    update-grub
    if ! grep -q -- "--id $ID" "$GRUB_CFG" 2>/dev/null; then
        echo "boot-live: warning: $ID is not in $GRUB_CFG" >&2
    fi
    if grep -qE 'gfxterm|insmod serial|terminal_output serial' "$GRUB_CFG" 2>/dev/null; then
        echo "boot-live: warning: $GRUB_CFG still has a non-console terminal" >&2
        echo "  check $GRUB_CONSOLE_DROPIN and the files in /etc/default/grub.d" >&2
    fi
    if ! test -f /boot/grub/grubenv; then
        grub-editenv - create
    fi
    grub-reboot "$ID"
    NEXT=$(grub-editenv - list 2>/dev/null |
        sed -n 's/^next_entry=//p' || true)
    [ "$NEXT" = "$ID" ] ||
        echo "boot-live: warning: next_entry is '${NEXT:-unset}', expected '$ID'" >&2
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
    CMD+=(--first-boot-live)
    "${CMD[@]}"
fi

echo
echo "boot-live: reboot to run '$NAME' ($ISO) with toram."
echo "  the live entry is selected once; the old default returns afterwards."
if [ "$SSH" = 1 ]; then
    ESP_DEV=$(findmnt -no SOURCE --target "$ESP" 2>/dev/null || printf '%s\n' "$ESP")
    echo "  ESP is labelled CIDATA.  Restore it later with:"
    echo "    fatlabel $ESP_DEV \"\$(cat $ESP/win11-arm64-oci-esp-label)\""
fi
