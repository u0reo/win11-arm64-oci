#!/usr/bin/env bash
# Shared GPT partition helpers.  Source this file; do not execute it.
#
# The stock OCI Ubuntu ARM64 image does not use the usual p1=ESP, p2=root
# layout.  It can have p1=Ubuntu root, p13=BOOT and p15=ESP, so consumers
# must find a partition by its GPT type instead of by a fixed number.

ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
LINUX_BOOT_GUID=bc13c2ff-59e6-4262-a352-b275fd6f7172
WINDOWS_GUID=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7

# /dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1
part() {
    if [[ "$1" =~ [0-9]$ ]]; then
        printf '%sp%s' "$1" "$2"
    else
        printf '%s%s' "$1" "$2"
    fi
}

part_number() {
    local n
    n=$(cat "/sys/class/block/$(basename "$1")/partition" 2>/dev/null || true)
    [ -n "$n" ] || return 1
    printf '%s\n' "$n"
}

# Filesystem type of a partition.  lsblk can lag behind a fresh mkfs on a
# loop/NBD device, so fall back to probing with blkid.
fs_type() {
    local t
    t=$(lsblk -no FSTYPE "$1" 2>/dev/null | tr -d ' ')
    if [ -z "$t" ]; then
        t=$(sudo -n blkid -o value -s TYPE "$1" 2>/dev/null || true)
    fi
    printf '%s\n' "$t"
}

# Print the ESP device.  Prefer the EFI System partition type; fall back to
# the first FAT partition when the type GUID is missing (e.g. an old MBR
# disk).
find_esp() {
    local disk=$1 dev
    dev=$(lsblk -lnpo NAME,PARTTYPE,FSTYPE "$disk" |
        awk -v g="$ESP_GUID" 'tolower($2) == g { print $1; exit }')
    if [ -z "$dev" ]; then
        while read -r d; do
            if [ "$(fs_type "$d")" = vfat ]; then
                dev=$d
                break
            fi
        done < <(lsblk -lnpo NAME,TYPE "$disk" | awk '$2 == "part" { print $1 }')
    fi
    if [ -n "$dev" ]; then printf '%s\n' "$dev"; fi
}

# Largest ext2/3/4 partition.  On the stock OCI layout this is the 49 GiB
# root (BOOT is 923 MiB); after host_apply.sh has replaced it, the only
# ext4 partition left is the small recovery root.
find_ubuntu_root() {
    local disk=$1 dev size best="" best_size=0
    while read -r dev size; do
        [ -n "$dev" ] || continue
        case "$(fs_type "$dev")" in
            ext2|ext3|ext4)
                if [ "$size" -gt "$best_size" ]; then
                    best=$dev
                    best_size=$size
                fi
                ;;
        esac
    done < <(lsblk -lnpbo NAME,TYPE,SIZE "$disk" |
        awk '$2 == "part" { print $1, $3 }')
    if [ -n "$best" ]; then printf '%s\n' "$best"; fi
}

# The separate /boot partition used by the stock OCI ARM64 image.
find_linux_boot() {
    lsblk -lnpo NAME,PARTTYPE,FSTYPE "$1" |
        awk -v g="$LINUX_BOOT_GUID" 'tolower($2) == g { print $1; exit }'
}

# Windows NTFS partition.  Prefer the Microsoft basic-data type, then fall
# back to the largest NTFS filesystem.
find_windows() {
    local disk=$1 dev
    dev=$(lsblk -lnpo NAME,PARTTYPE,FSTYPE "$disk" |
        awk -v g="$WINDOWS_GUID" 'tolower($2) == g { print $1; exit }')
    if [ -z "$dev" ]; then
        dev=$(lsblk -lnpbo NAME,TYPE,FSTYPE,SIZE "$disk" |
            awk 'tolower($3) == "ntfs" { print $4, $1 }' |
            sort -n | tail -1 | awk 'NF == 2 { print $2 }')
    fi
    if [ -n "$dev" ]; then printf '%s\n' "$dev"; fi
}
