#!/usr/bin/env bash
# Helpers for apt on the small recovery Ubuntu.
#
# The live-server installer leaves a deb822 source pointing at file:///cdrom.
# On the installed system /cdrom does not exist, so `apt-get update` fails with
# "The repository 'file:/cdrom ... Release' does not have a Release file".
# Source this file; do not run it.

# Disable the cdrom source if it is present and /cdrom is not a mounted ISO.
# Idempotent: renames cdrom.sources to cdrom.sources.disabled once.
disable_cdrom_source() {
    local f

    if [ -d /cdrom ]; then
        return 0
    fi

    for f in /etc/apt/sources.list.d/cdrom.sources \
             /etc/apt/sources.list.d/cdrom.list; do
        [ -f "$f" ] || continue
        [ -f "$f.disabled" ] && continue
        mv -f "$f" "$f.disabled"
        echo "apt: disabled $f (no /cdrom on this system)"
    done

    if [ -f /etc/apt/sources.list ] &&
       grep -qE '^[[:space:]]*deb[[:space:]]+cdrom:' /etc/apt/sources.list; then
        if [ ! -f /etc/apt/sources.list.win11-arm64-oci.bak ]; then
            cp -p /etc/apt/sources.list /etc/apt/sources.list.win11-arm64-oci.bak
        fi
        sed -i 's|^[[:space:]]*deb[[:space:]]\+cdrom:|# disabled by win11-arm64-oci: deb cdrom:|' \
            /etc/apt/sources.list
        echo "apt: commented out cdrom entries in /etc/apt/sources.list"
    fi

    return 0
}

# Allow `sudo bash internal/apt.sh disable_cdrom_source` for callers that do
# not source this file.  Sourcing it has no side effects.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "disable_cdrom_source" ]; then
    disable_cdrom_source
fi
