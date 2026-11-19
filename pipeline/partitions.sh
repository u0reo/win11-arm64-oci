#!/usr/bin/env bash
# Shared GPT partition helpers.  Source this file; do not execute it.
#
# The stock OCI Ubuntu ARM64 image does not use the usual p1=ESP, p2=root
# layout.  It can have p1=Ubuntu root, p13=BOOT and p15=ESP, so consumers
# must find a partition by its GPT type instead of by a fixed number.
#
# The kernel can also refuse to re-read the partition table ("unable to
# inform the kernel of the change, probably because it/they are in use")
# when the live ISO was stored on the disk being rebuilt.  The helpers
# below read the GPT with sgdisk and, when /dev/sdXN does not match it,
# expose the exact range through a loop device.  Callers that may create
# such loops must call cleanup_part_loops from their EXIT trap.

ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
WINDOWS_GUID=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7
WINRE_GUID=de94bba4-06d1-4d40-a16a-bfd50179d6ac

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

# True when a running QEMU process has <disk> in its own command line.
# /proc/PID/comm is used instead of pgrep -f: it names the real executable,
# so a diagnostic shell command that merely mentions "qemu-system-aarch64"
# cannot produce a false positive.  comm is readable without root.
qemu_uses_disk() {
    local disk=$1 p pid
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        case "$(cat "$p/comm" 2>/dev/null)" in
            qemu-system-*) ;;
            *) continue ;;
        esac
        tr '\0' ' ' < "$p/cmdline" 2>/dev/null |
            grep -qF -- "$disk" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# GPT helpers.  These read the partition table from disk, so they work even
# when the kernel still has an old view of it.
# ---------------------------------------------------------------------------

gpt_part_numbers() {
    sudo -n sgdisk -p "$1" | awk '$1 ~ /^[0-9]+$/ { print $1 }'
}

# gpt_part_field <disk> <num> <label>   (e.g. "First sector")
gpt_part_field() {
    sudo -n sgdisk -i "$2" "$1" |
        awk -v label="$3:" '
            index($0, label) == 1 {
                s = substr($0, length(label) + 1)
                sub(/^ +/, "", s)
                split(s, a, " ")
                print a[1]
                exit
            }'
}

gpt_part_start() {
    gpt_part_field "$1" "$2" "First sector"
}

gpt_part_sectors() {
    gpt_part_field "$1" "$2" "Partition size"
}

gpt_part_type() {
    gpt_part_field "$1" "$2" "Partition GUID code" | tr 'A-Z' 'a-z'
}

# Cache of loop fallbacks, one "<disk> <num> <device>" per line.  Set at
# source time so command substitutions inherit the same file.
: "${PART_LOOP_CACHE:=$(mktemp /tmp/part-loops.XXXXXX)}"
export PART_LOOP_CACHE

cleanup_part_loops() {
    local _d _n dev
    [ -s "$PART_LOOP_CACHE" ] || { rm -f "$PART_LOOP_CACHE" 2>/dev/null; return 0; }
    while read -r _d _n dev; do
        case "$dev" in
            /dev/loop*) sudo -n losetup -d "$dev" 2>/dev/null || true ;;
        esac
    done < "$PART_LOOP_CACHE"
    rm -f "$PART_LOOP_CACHE"
}

# Print a block device for partition NUM.  Normally this is /dev/sdXN.  If
# the kernel has not picked up the current GPT (or has an old partition at
# the same number), map the exact GPT range with losetup instead.
partition_dev() {
    local disk=$1 num=$2 dev start sectors ssize kernel_start kernel_size loop
    start=$(gpt_part_start "$disk" "$num")
    sectors=$(gpt_part_sectors "$disk" "$num")
    [ -n "$start" ] && [ -n "$sectors" ] || return 1
    ssize=$(sudo -n blockdev --getss "$disk" 2>/dev/null || echo 512)

    dev=$(awk -v d="$disk" -v n="$num" '$1 == d && $2 == n { print $3; exit }' \
        "$PART_LOOP_CACHE" 2>/dev/null || true)
    if [ -n "$dev" ] && [ -b "$dev" ]; then
        if [ "$(sudo -n blockdev --getsize64 "$dev" 2>/dev/null || echo 0)" = \
             "$((sectors * ssize))" ]; then
            printf '%s\n' "$dev"
            return 0
        fi
        sudo -n losetup -d "$dev" 2>/dev/null || true
        awk -v d="$disk" -v n="$num" '!($1 == d && $2 == n)' \
            "$PART_LOOP_CACHE" > "$PART_LOOP_CACHE.new"
        mv "$PART_LOOP_CACHE.new" "$PART_LOOP_CACHE"
    fi

    dev=$(part "$disk" "$num")
    kernel_start=$(cat "/sys/class/block/$(basename "$dev")/start" 2>/dev/null || true)
    kernel_size=$(cat "/sys/class/block/$(basename "$dev")/size" 2>/dev/null || true)
    if [ -b "$dev" ] &&
       [ "$kernel_start" = "$((start * ssize / 512))" ] &&
       [ "$kernel_size" = "$((sectors * ssize / 512))" ]; then
        printf '%s\n' "$dev"
        return 0
    fi

    loop=$(sudo -n losetup --find --show \
        --offset "$((start * ssize))" --sizelimit "$((sectors * ssize))" \
        "$disk") || return 1
    printf '%s %s %s\n' "$disk" "$num" "$loop" >> "$PART_LOOP_CACHE"
    printf '%s\n' "$loop"
}

# ---------------------------------------------------------------------------
# Partition discovery by GPT type.
# ---------------------------------------------------------------------------

# Print the ESP device.  Prefer the EFI System partition type; fall back to
# a FAT filesystem when the type GUID is missing (e.g. an old MBR disk).
# Prints nothing when there is no ESP; callers test for empty output.
find_esp() {
    local disk=$1 n dev
    for n in $(gpt_part_numbers "$disk"); do
        if [ "$(gpt_part_type "$disk" "$n")" = "$ESP_GUID" ]; then
            partition_dev "$disk" "$n" && return 0
        fi
    done
    for n in $(gpt_part_numbers "$disk"); do
        dev=$(partition_dev "$disk" "$n") || continue
        if [ "$(fs_type "$dev")" = vfat ]; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 0
}

# Number of the Windows Recovery Environment partition.  Prints nothing
# when the disk has no dedicated WinRE partition (the usual layout keeps
# WinRE in C:).
find_winre_num() {
    local disk=$1 n
    for n in $(gpt_part_numbers "$disk"); do
        if [ "$(gpt_part_type "$disk" "$n")" = "$WINRE_GUID" ]; then
            printf '%s\n' "$n"
            return 0
        fi
    done
    return 0
}

# Device of the Windows Recovery Environment partition.
find_winre() {
    local disk=$1 n
    n=$(find_winre_num "$disk")
    [ -n "$n" ] || return 0
    partition_dev "$disk" "$n"
}

# Largest ext2/3/4 partition.  On the stock OCI layout this is the 49 GiB
# root (BOOT is 923 MiB); after host_apply.sh has replaced it, the only
# ext4 partition left is the small recovery root.
find_ubuntu_root() {
    local disk=$1 n dev size best="" best_size=0
    for n in $(gpt_part_numbers "$disk"); do
        dev=$(partition_dev "$disk" "$n") || continue
        case "$(fs_type "$dev")" in
            ext2|ext3|ext4) ;;
            *) continue ;;
        esac
        size=$(gpt_part_sectors "$disk" "$n")
        if [ "$size" -gt "$best_size" ]; then
            best=$dev
            best_size=$size
        fi
    done
    [ -n "$best" ] && printf '%s\n' "$best"
    return 0
}

# Windows NTFS partition.  Prefer the Microsoft basic-data type, then fall
# back to the largest NTFS filesystem.
find_windows() {
    local disk=$1 n dev size best="" best_size=0
    for n in $(gpt_part_numbers "$disk"); do
        if [ "$(gpt_part_type "$disk" "$n")" = "$WINDOWS_GUID" ]; then
            partition_dev "$disk" "$n" && return 0
        fi
    done
    for n in $(gpt_part_numbers "$disk"); do
        dev=$(partition_dev "$disk" "$n") || continue
        [ "$(fs_type "$dev")" = ntfs ] || continue
        size=$(gpt_part_sectors "$disk" "$n")
        if [ "$size" -gt "$best_size" ]; then
            best=$dev
            best_size=$size
        fi
    done
    [ -n "$best" ] && printf '%s\n' "$best"
    return 0
}

# Detach loop devices that still reference files on the target disk.  A
# toram boot can leave the live ISO loop attached even after /isodevice was
# unmounted, and that reference makes partprobe fail.  The backing file may
# no longer have a mount point, so match the loop's backing filesystem
# device number ([MAJ:MIN] in losetup -a) as well as the path.  Only loops
# that are not mounted are touched, so the running live root is never
# detached.
release_media_loops() {
    local disk=$1 line dev backing src fsdev nums sys major minor n
    nums=" "
    for sys in "/sys/class/block/$(basename "$disk")" \
               /sys/class/block/"$(basename "$disk")"[0-9]* \
               /sys/class/block/"$(basename "$disk")"p[0-9]*; do
        [ -r "$sys/dev" ] || continue
        IFS=: read -r major minor < "$sys/dev"
        nums+="$(( major * 256 + minor )) "
    done
    while IFS= read -r line; do
        dev=${line%%:*}
        backing=$(printf '%s\n' "$line" |
            sed -n 's/^[^:]*: \[[^]]*\]:[0-9]* (\(.*\))$/\1/p')
        fsdev=$(printf '%s\n' "$line" |
            sed -n 's/^[^:]*: \[\([0-9]*\)\].*/\1/p')
        [ -n "$backing" ] || continue
        [ -n "$(findmnt -S "$dev" -no TARGET 2>/dev/null)" ] && continue
        n=0
        if [ -n "$fsdev" ] && [[ "$nums" == *" $fsdev "* ]]; then
            n=1
        fi
        if [ "$n" = 0 ] && [ -e "$backing" ]; then
            src=$(findmnt -T "$backing" -no SOURCE 2>/dev/null || true)
            case "$src" in
                "$disk"|"$disk"p[0-9]*|"$disk"[0-9]*) n=1 ;;
            esac
        fi
        [ "$n" = 1 ] || continue
        echo "  detaching stale live-media loop $dev ($backing)"
        sudo -n losetup -d "$dev" 2>/dev/null || true
    done < <(sudo -n losetup -a)
}
