#!/bin/sh
# Put the Ubuntu EFI application first in the firmware boot order.
#
# The firmware's NVRAM is not part of a disk image.  On OCI the first Windows
# boot creates its own Boot#### entry and can put it in front of the generic
# block-device entry, so the next power-on starts Windows Boot Manager
# directly and GRUB is never reached.  Ubuntu is still installed and bootable;
# only the firmware order is wrong.
#
# This script runs from oci-ubuntu-boot-order.service on every Ubuntu boot.
# It verifies that the existing Ubuntu entry points at the current ESP (the
# GPT GUID in its device path), deletes it if an older image's GUID is still
# there, creates a fresh entry when needed, and moves it to the front.
# Duplicate Ubuntu entries are removed; every other entry, including Windows,
# stays selectable from the firmware menu.  It is safe to run by hand:
#
#     sudo /usr/local/sbin/oci-ubuntu-boot-order
#
# Requires efibootmgr (installed by make_recovery_ubuntu.sh where possible).
# If the tool, efivarfs, or the ESP is missing, the script explains why and
# exits successfully so it can never block a recovery boot.
set -eu

log() {
    echo "oci-ubuntu-boot-order: $*"
}

[ -d /sys/firmware/efi/efivars ] || {
    log "not booted with EFI; nothing to do"
    exit 0
}
if ! command -v efibootmgr >/dev/null 2>&1; then
    log "efibootmgr is not installed; leaving the firmware order alone"
    exit 0
fi
ESP=${ESP:-/boot/efi}
if [ ! -f "$ESP/EFI/ubuntu/grubaa64.efi" ]; then
    log "no $ESP/EFI/ubuntu/grubaa64.efi; nothing to do"
    exit 0
fi
if [ -f "$ESP/EFI/ubuntu/shimaa64.efi" ]; then
    LOADER='\EFI\ubuntu\shimaa64.efi'
else
    LOADER='\EFI\ubuntu\grubaa64.efi'
fi

# The ESP partition and its parent disk, for "efibootmgr --create".
SRC=$(findmnt -no SOURCE "$ESP" 2>/dev/null || true)
[ -n "$SRC" ] || {
    log "$ESP is not mounted; nothing to do"
    exit 0
}
SRC=$(readlink -f "$SRC")
DISK_NAME=$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1)
PART=$(cat "/sys/class/block/$(basename "$SRC")/partition" 2>/dev/null || true)
if [ -z "$DISK_NAME" ] || [ -z "$PART" ]; then
    log "cannot find the disk and partition for $SRC; nothing to do"
    exit 0
fi
DISK=/dev/$DISK_NAME
ESP_PARTUUID=$(lsblk -no PARTUUID "$SRC" 2>/dev/null | tr -d ' \r\n' | tr 'A-Z' 'a-z')
if [ -z "$ESP_PARTUUID" ]; then
    log "no PARTUUID for $SRC; cannot verify the Ubuntu entry device path"
fi

# One line per Ubuntu entry: "<boot number> <ESP GPT GUID>".  The GUID comes
# from the HD(...) part of the device path.  Matching only on the loader path
# (the old behaviour) kept entries that still pointed at an earlier image's
# ESP, so the firmware BootMenu offered Ubuntu but could not load it.
find_ubuntu_entries() {
    efibootmgr -v 2>/dev/null | awk '
        /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            line = $0
            if (index(line, "\\EFI\\ubuntu\\shimaa64.efi") == 0 &&
                index(line, "\\EFI\\ubuntu\\grubaa64.efi") == 0) next
            num = substr(line, 5, 4)
            guid = ""
            if (match(line, /HD\([0-9]+,GPT,[0-9a-fA-F][0-9a-fA-F-]*/)) {
                guid = substr(line, RSTART, RLENGTH)
                sub(/^HD\([0-9]+,GPT,/, "", guid)
                guid = tolower(guid)
            }
            print num, guid
        }'
}

NUM=
while read -r num guid; do
    [ -n "$num" ] || continue
    if [ -n "$ESP_PARTUUID" ] && [ -n "$guid" ] && [ "$guid" != "$ESP_PARTUUID" ]; then
        log "Boot$num points at old ESP $guid (current $ESP_PARTUUID); deleting"
        efibootmgr -b "$num" -B >/dev/null 2>&1 || log "could not delete Boot$num"
        continue
    fi
    if [ -n "$NUM" ]; then
        log "Boot$num is a second Ubuntu entry; deleting the duplicate"
        efibootmgr -b "$num" -B >/dev/null 2>&1 || true
        continue
    fi
    NUM=$num
done <<EOF
$(find_ubuntu_entries)
EOF

if [ -z "$NUM" ]; then
    if ! efibootmgr --create --disk "$DISK" --part "$PART" \
            --label Ubuntu --loader "$LOADER" >/dev/null 2>&1; then
        log "efibootmgr could not add the Ubuntu entry (read-only NVRAM?)"
        exit 0
    fi
    NUM=$(find_ubuntu_entries | awk 'NR == 1 { print $1 }')
    if [ -z "$NUM" ]; then
        log "the new Ubuntu entry did not appear in efibootmgr"
        exit 0
    fi
    log "created Boot$NUM for $LOADER on $DISK partition $PART"
fi

ORDER=$(efibootmgr 2>/dev/null | awk -F': ' '/^BootOrder:/{print $2; exit}')
if [ -z "$ORDER" ]; then
    log "cannot read BootOrder"
    exit 0
fi

# Put NUM first, keep every other entry in its existing relative order.
NEW=$(printf '%s\n' "$ORDER" | tr ',' '\n' | awk -v first="$NUM" '
    $0 != "" && $0 != first { rest = (rest == "" ? $0 : rest "," $0) }
    END { if (rest == "") print first; else print first "," rest }')
if [ "$ORDER" = "$NEW" ]; then
    log "Boot$NUM is already first (BootOrder: $ORDER)"
    exit 0
fi
if ! efibootmgr --bootorder "$NEW" >/dev/null 2>&1; then
    log "could not write BootOrder (read-only NVRAM?)"
    exit 0
fi
log "BootOrder: $ORDER -> $NEW (Ubuntu via $LOADER)"
