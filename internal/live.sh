#!/usr/bin/env bash
# Helpers for the Ubuntu live system booted with `toram`.
#
# The live root is an overlay and /dev/shm is a tmpfs.  These helpers are
# shared by setup.sh, build.sh, preflight.sh and build-image.sh so that the
# RAM-only build defaults stay in one place.  Source this file; do not run it.

# True when this is the casper live system booted with `toram`.
# findmnt needs -T: the live media can mount a tmpfs whose *source* is
# /dev/shm (e.g. at /cdrom), and a bare /dev/shm would match that first.
is_live_ram() {
    grep -qw toram /proc/cmdline 2>/dev/null || return 1
    [ "$(findmnt -no FSTYPE -T / 2>/dev/null || true)" = overlay ] || return 1
    [ "$(findmnt -no FSTYPE -T /dev/shm 2>/dev/null || true)" = tmpfs ] ||
        return 1
}

# Validate a tmpfs size for mount(8): 100%, 16G, 1024, ...
valid_shm_size() {
    [[ ${1:-} =~ ^[0-9]+([kKmMgGtT]|%)?$ ]]
}

shm_total_kb() {
    local kb
    kb=$(df -Pk /dev/shm 2>/dev/null | awk 'NR == 2 { print $2 + 0 }')
    echo "${kb:-0}"
}

mem_total_kb() {
    local kb
    kb=$(awk '/^MemTotal:/ { print $2 + 0 }' /proc/meminfo 2>/dev/null)
    echo "${kb:-0}"
}

# shm_size_kb SIZE MEM_TOTAL_KB
# Convert a mount(8) size (100%, 16G, 1024) to KiB.  A bare number is bytes,
# as in mount(8).
shm_size_kb() {
    local size=$1 mem=$2 num
    valid_shm_size "$size" || return 1
    case "$size" in
        *%)
            num=${size%\%}
            echo $(( mem * num / 100 ))
            ;;
        *[kK])
            num=${size%?}
            echo $(( num ))
            ;;
        *[mM])
            num=${size%?}
            echo $(( num * 1024 ))
            ;;
        *[gG])
            num=${size%?}
            echo $(( num * 1024 * 1024 ))
            ;;
        *[tT])
            num=${size%?}
            echo $(( num * 1024 * 1024 * 1024 ))
            ;;
        *)
            echo $(( size / 1024 ))
            ;;
    esac
}

# shm_meets [SIZE]
# True when /dev/shm is already at least SIZE (default: $SHM_SIZE).
# The kernel rounds a percentage down to pages, so accept 1% slack.
shm_meets() {
    local want=${1:-${SHM_SIZE:-100%}}
    local total mem target

    [ -d /dev/shm ] || return 1
    valid_shm_size "$want" || return 1
    total=$(shm_total_kb)
    mem=$(mem_total_kb)
    target=$(shm_size_kb "$want" "$mem")
    [ "$target" -gt 0 ] &&
        [ "$total" -ge $(( target - target / 100 )) ]
}

# live_shm_max [SIZE]
#
# Remount /dev/shm at SIZE (default: $SHM_SIZE, or 100% of RAM).  A larger
# tmpfs cap does not reserve memory: it only lets the ISO/build files grow
# into RAM that QEMU is not using.  A target that is already met is a no-op,
# so this is safe to call more than once.
live_shm_max() {
    local want=${1:-${SHM_SIZE:-100%}}

    [ -d /dev/shm ] || return 0
    [ "$(findmnt -no FSTYPE -T /dev/shm 2>/dev/null || true)" = tmpfs ] ||
        return 0
    valid_shm_size "$want" || return 1
    shm_meets "$want" && return 0

    if [ "$(id -u)" -eq 0 ]; then
        mount -o remount,size="$want" /dev/shm
    else
        sudo -n mount -o remount,size="$want" /dev/shm
    fi
}

# default_build_dir FALLBACK
#
# BUILD_DIR wins.  On live/toram the staging files default to /dev/shm/build
# so that they do not consume the overlay's RAM-backed copy-on-write layer.
default_build_dir() {
    local fallback=$1
    if [ -n "${BUILD_DIR:-}" ]; then
        printf '%s\n' "$BUILD_DIR"
    elif is_live_ram && [ -d /dev/shm ]; then
        printf '%s\n' /dev/shm/build
    else
        printf '%s\n' "$fallback"
    fi
}
