#!/usr/bin/env bash
# Fast install path: apply install.wim/esd to a fresh disk with
# wimlib-imagex.  wimlib writes directly to the NTFS volume through
# libntfs-3g and preserves Windows ACLs, hard links, reparse points and
# timestamps.  This avoids the extremely slow DISM /apply-image under QEMU.
#
# The target can be a qcow2 file (created from scratch) or a raw block
# device such as /dev/sdb.  A block device is wiped completely, unless
# REUSE_UBUNTU=1 is set.
#
# FRESH_UBUNTU=1 builds the dual-boot layout from an empty disk.  It does not
# reuse the old ESP: p1 is a new 100 MiB ESP, p2 is the RECOVERY_SIZE ext4
# recovery system and p3 is Windows (the rest).  pipeline/make_recovery_ubuntu.sh
# fills the recovery partition afterwards.
#
# Usage: ./host_apply.sh <windows-arm64.iso> <disk.qcow2|/dev/sdX> [index]
#
# The ESP boot files and offline driver injection are done afterwards by
# booting WinPE with manual_start.finish.cmd, which detects the existing
# Windows and calls manual_finish.cmd.  The ESP partition number is written
# to OEM\esp-part.txt on the Windows partition for that script.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"
ISO=${1:?usage: $0 <iso> <disk.qcow2|/dev/sdX> [index]}
IMG=${2:?usage: $0 <iso> <disk.qcow2|/dev/sdX> [index]}
INDEX=${3:-1}
BUILD=${BUILD_DIR:-$ROOT/build}
MEDIA=${MEDIA:-$BUILD/media}
DRIVERS=${DRIVERS:-$BUILD/drivers}
DRIVERS_EXTRA=${DRIVERS_EXTRA:-$BUILD/drivers-extra}
SIZE=${SIZE:-50G}
SDB=${SDB:-/dev/nbd0}
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
FRESH_UBUNTU=${FRESH_UBUNTU:-0}
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}

if [ "$FRESH_UBUNTU" = 1 ] && [ "$REUSE_UBUNTU" = 1 ]; then
    echo "FRESH_UBUNTU cannot be combined with REUSE_UBUNTU" >&2
    exit 1
fi

RAW=0
if [ -b "$IMG" ]; then
    RAW=1
fi

esp_free_kb() {
    local mnt
    mnt=$(mktemp -d /tmp/hostapply-esp.XXXXXX)
    sudo -n mount -t vfat -o ro "$1" "$mnt"
    df -Pk "$mnt" | awk 'NR==2{print $4}'
    sudo -n umount "$mnt"
    rmdir "$mnt"
}

# GiB available after the last partition (the GPT backup takes 34 sectors).
free_gib() {
    local total last
    total=$(( $(sudo -n blockdev --getsize64 "$1") / 512 ))
    last=$(lsblk -lnbo NAME,START,SIZE "$1" |
        awk 'NF==3 && $2>0 {e=$2+int($3/512)-1; if(e>m)m=e} END{print m+0}')
    echo $(( (total - last - 34) * 512 / 1024 / 1024 / 1024 ))
}

# The ESP keeps its Windows and Ubuntu boot files; only its free space
# matters.  bcdboot needs about 30 MiB and GRUB about 15 MiB.
require_esp_free() {
    local kb
    kb=$(esp_free_kb "$1")
    echo "  ESP free: $(( kb / 1024 )) MiB"
    if [ "$kb" -lt 40960 ]; then
        echo "the ESP needs at least 40 MiB free for bcdboot and GRUB" >&2
        echo "free some space on $1 first" >&2
        exit 1
    fi
}

require_two_partitions() {
    local n
    n=$(lsblk -lnpo NAME,TYPE "$1" | awk '$2=="part"' | wc -l)
    if [ "$n" -ne 2 ]; then
        echo "expected 2 partitions (ESP + Ubuntu) on $1, found $n" >&2
        lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$1" >&2
        echo "the layout must be p1=ESP, p2=Ubuntu, and p3 must not exist" >&2
        exit 1
    fi
}

# Bytes for a size such as 4G.  A bare number is treated as bytes.
size_bytes() {
    case "$1" in
        *[Kk]) awk -v n="${1%[Kk]}" 'BEGIN{printf "%.0f", n*1024}' ;;
        *[Mm]) awk -v n="${1%[Mm]}" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
        *[Gg]) awk -v n="${1%[Gg]}" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
        *[Tt]) awk -v n="${1%[Tt]}" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

[ -f "$ISO" ] || { echo "missing ISO: $ISO" >&2; exit 1; }
[ -f "$MEDIA/autounattend.xml" ] || { echo "missing $MEDIA/autounattend.xml; run make_oemdrv.sh first" >&2; exit 1; }
[ -d "$MEDIA/oem" ] || { echo "missing $MEDIA/oem" >&2; exit 1; }
[ -d "$DRIVERS" ] || { echo "missing $DRIVERS; run internal/stage-drivers.sh" >&2; exit 1; }

if qemu_uses_disk "$IMG"; then
    echo "QEMU still references $IMG; stop it first" >&2
    exit 1
fi

if [ "$RAW" = 1 ]; then
    [ -w "$IMG" ] || { echo "no write access to $IMG (run as root)" >&2; exit 1; }
    if [ -n "$(lsblk -no MOUNTPOINT "$IMG" 2>/dev/null | tr -d ' ')" ]; then
        echo "$IMG has mounted partitions; refusing to wipe it" >&2
        exit 1
    fi
    ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [ -n "$ROOTDEV" ] && [[ "$ROOTDEV" == "$IMG"* ]]; then
        echo "$IMG is the running root device; refusing to wipe it" >&2
        exit 1
    fi
    # The live ISO may have been stored on this disk.  Its loop device keeps
    # the old partition open and makes the kernel refuse a partition table
    # reload.  The loop fallback in partition_dev handles the rest.
    release_media_loops "$IMG"
fi

ISO_MNT=$(mktemp -d /tmp/hostapply-iso.XXXXXX)
WIN_MNT=$(mktemp -d /tmp/hostapply-win.XXXXXX)
ISO_MOUNTED=0
WIN_MOUNTED=0
NBD=0
cleanup() {
    set +e
    [ "$WIN_MOUNTED" = 1 ] && sudo -n umount "$WIN_MNT" 2>/dev/null
    [ "$ISO_MOUNTED" = 1 ] && sudo -n umount "$ISO_MNT" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect "$SDB" >/dev/null 2>&1
    cleanup_part_loops
    rmdir "$WIN_MNT" "$ISO_MNT" 2>/dev/null
}
trap cleanup EXIT

echo "[1/6] mount ISO"
sudo -n mkdir -p "$ISO_MNT"
if ! sudo -n mount -t udf -o ro,loop "$ISO" "$ISO_MNT" 2>/dev/null; then
    sudo -n mount -t iso9660 -o ro,loop "$ISO" "$ISO_MNT"
fi
ISO_MOUNTED=1
WIM=""
for f in "$ISO_MNT/sources/install.wim" "$ISO_MNT/sources/install.esd"; do
    [ -f "$f" ] && { WIM=$f; break; }
done
[ -n "$WIM" ] || { echo "no install.wim/esd in ISO" >&2; exit 1; }
echo "  source: $WIM"

if [ "$RAW" = 1 ]; then
    echo "[2/6] target is the block device $IMG"
    DEV=$IMG
    echo "  size: $(sudo -n blockdev --getsize64 "$DEV") bytes"
else
    echo "[2/6] create fresh qcow2 ($SIZE)"
    rm -f "$IMG"
    qemu-img create -f qcow2 "$IMG" "$SIZE" >/dev/null
    sudo -n qemu-nbd --disconnect "$SDB" >/dev/null 2>&1 || true
    sleep 1
    sudo -n qemu-nbd --connect="$SDB" --format=qcow2 "$IMG"
    NBD=1
    DEV=$SDB
    # The kernel updates the NBD capacity asynchronously after connect;
    # sgdisk would otherwise see a zero-sized device and fail.
    for _ in $(seq 1 20); do
        NBD_SIZE=$(sudo -n blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
        [ "$NBD_SIZE" -gt 0 ] && break
        sleep 0.5
    done
    [ "$NBD_SIZE" -gt 0 ] || { echo "NBD device did not become ready" >&2; exit 1; }
    echo "  NBD size: $NBD_SIZE bytes"
fi

if [ "$REUSE_UBUNTU" = 1 ]; then
    echo "[3/6] keep p1 and p2, create Windows in the free space"
    [ "$RAW" = 1 ] || { echo "REUSE_UBUNTU needs a block device" >&2; exit 1; }
    sudo -n partprobe "$DEV" 2>/dev/null || true
    sleep 1
    P1=$(part "$DEV" 1)
    P2=$(part "$DEV" 2)
    [ -b "$P1" ] || { echo "no ESP at $P1" >&2; exit 1; }
    [ -b "$P2" ] || { echo "no Ubuntu partition at $P2" >&2; exit 1; }
    [ "$(fs_type "$P1")" = vfat ] || {
        echo "$P1 is not FAT32; the ESP must stay as it is" >&2; exit 1; }
    case "$(fs_type "$P2")" in
        ext2|ext3|ext4) ;;
        *) echo "$P2 is not ext4; refusing to build next to it" >&2; exit 1 ;;
    esac
    require_two_partitions "$DEV"
    require_esp_free "$P1"
    ESP_N=$(part_number "$P1")

    FREE_GIB=$(free_gib "$DEV")
    echo "  free space: ${FREE_GIB} GiB"
    if [ "$FREE_GIB" -lt 40 ]; then
        echo "not enough free space for Windows (${FREE_GIB} GiB)" >&2
        echo "  shrink p2 from a live session first, or leave 40 GiB+" >&2
        echo "  unallocated when installing Ubuntu" >&2
        exit 1
    fi

    sudo -n sgdisk -n 3:0:0 -t 3:0700 -c 3:"Windows" "$DEV" >/dev/null
    sudo -n partprobe "$DEV" 2>/dev/null || true
    for _ in $(seq 1 10); do
        [ -b "$(part "$DEV" 3)" ] && break
        sudo -n partx -a "$DEV" 2>/dev/null || true
        sleep 1
    done
    WINPART=$(part "$DEV" 3)
    [ -b "$WINPART" ] || { echo "partition 3 did not appear" >&2; exit 1; }
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV"
    WIN_START=$(lsblk -no START "$WINPART" | tr -d ' ')
    [ -n "$WIN_START" ] || { echo "cannot determine the Windows start sector" >&2; exit 1; }
    sudo -n mkntfs -f -F -L Windows -p "$WIN_START" -H 255 -S 63 "$WINPART" >/dev/null
    echo "  formatted ($WINPART starts at sector $WIN_START)"
elif [ "$FRESH_UBUNTU" = 1 ]; then
    echo "[3/6] erase the disk and create ESP + $RECOVERY_SIZE Ubuntu + Windows"
    [ "$RAW" = 1 ] || { echo "FRESH_UBUNTU needs a block device" >&2; exit 1; }
    TOTAL_BYTES=$(sudo -n blockdev --getsize64 "$DEV")
    NEED_BYTES=$(( $(size_bytes "$RECOVERY_SIZE") + 40 * 1024 * 1024 * 1024 ))
    if [ "$TOTAL_BYTES" -lt "$NEED_BYTES" ]; then
        echo "not enough space: Windows needs 40 GiB plus $RECOVERY_SIZE" >&2
        echo "  $DEV has $((TOTAL_BYTES / 1024 / 1024 / 1024)) GiB" >&2
        exit 1
    fi
    sudo -n sgdisk --zap-all "$DEV" >/dev/null
    sudo -n sgdisk \
        -n 1:2048:+100M -t 1:ef00 -c 1:"System" \
        -n 2:0:+"$RECOVERY_SIZE" -t 2:8300 -c 2:"Ubuntu" \
        -n 3:0:0 -t 3:0700 -c 3:"Windows" \
        "$DEV" >/dev/null
    sudo -n partprobe "$DEV" 2>/dev/null || true
    sleep 2
    ESP_N=1
    ESPDEV=$(partition_dev "$DEV" 1) || { echo "ESP partition did not appear" >&2; exit 1; }
    RECPART=$(partition_dev "$DEV" 2) || { echo "Ubuntu partition did not appear" >&2; exit 1; }
    WINPART=$(partition_dev "$DEV" 3) || { echo "Windows partition did not appear" >&2; exit 1; }
    WIN_START=$(gpt_part_start "$DEV" 3)
    [ -n "$WIN_START" ] || { echo "cannot determine the Windows start sector" >&2; exit 1; }
    echo "  GPT:"
    sudo -n sgdisk -p "$DEV" | sed -n '/^Number/,$p'
    sudo -n wipefs -a "$ESPDEV" >/dev/null 2>&1 || true
    sudo -n wipefs -a "$RECPART" >/dev/null 2>&1 || true
    sudo -n wipefs -a "$WINPART" >/dev/null 2>&1 || true
    sudo -n mkfs.vfat -F32 -n SYSTEM "$ESPDEV" >/dev/null
    sudo -n mkfs.ext4 -F -L Ubuntu "$RECPART" >/dev/null
    sudo -n mkntfs -f -F -L Windows -p "$WIN_START" -H 255 -S 63 "$WINPART" >/dev/null
    echo "  formatted ($ESPDEV FAT32, $RECPART $RECOVERY_SIZE ext4,"
    echo "             $WINPART NTFS from sector $WIN_START)"
else
    echo "[3/6] partition and format"
    sudo -n sgdisk --zap-all "$DEV" >/dev/null
    sudo -n sgdisk \
        -n 1:2048:+100M -t 1:ef00 -c 1:"System" \
        -n 2:0:+16M   -t 2:0c01 -c 2:"MSR" \
        -n 3:0:0      -t 3:0700 -c 3:"Windows" \
        "$DEV" >/dev/null
    sudo -n partprobe "$DEV" 2>/dev/null || true
    sleep 2
    ESPDEV=$(partition_dev "$DEV" 1)
    WINPART=$(partition_dev "$DEV" 3)
    ESP_N=1
    WIN_START=$(gpt_part_start "$DEV" 3)
    [ -n "$WIN_START" ] || { echo "cannot determine the Windows start sector" >&2; exit 1; }
    echo "  GPT:"
    sudo -n sgdisk -p "$DEV" | sed -n '/^Number/,$p'
    # -f is a quick format: without it mkntfs zeroes the whole volume, which
    # balloons the qcow2 and is extremely slow over NBD.  -p/-H/-S give the
    # NTFS BPB the same geometry Windows uses, so Windows can boot from it.
    sudo -n mkfs.vfat -F32 -n SYSTEM "$ESPDEV" >/dev/null
    sudo -n mkntfs -f -F -L Windows -p "$WIN_START" -H 255 -S 63 "$WINPART" >/dev/null
    echo "  formatted ($WINPART starts at sector $WIN_START)"
fi

[ -b "$WINPART" ] || { echo "no Windows partition to apply to" >&2; exit 1; }

echo "[4/6] apply image $INDEX with wimlib-imagex"
time sudo -n wimlib-imagex apply "$WIM" "$INDEX" "$WINPART"

echo "[5/6] stage unattend, OEM scripts and drivers"
sudo -n mount -t ntfs-3g "$WINPART" "$WIN_MNT"
WIN_MOUNTED=1
sudo -n mkdir -p "$WIN_MNT/Windows/Panther"
sudo -n cp "$MEDIA/autounattend.xml" "$WIN_MNT/Windows/Panther/unattend.xml"
sudo -n cp -a "$MEDIA/oem" "$WIN_MNT/OEM"
sudo -n cp -a "$DRIVERS" "$WIN_MNT/drivers"
[ -d "$DRIVERS_EXTRA" ] && sudo -n cp -a "$DRIVERS_EXTRA" "$WIN_MNT/drivers-extra"
# manual_finish.cmd runs in WinPE before it has mounted the ESP.  Record the
# partition number on the Windows volume (and in the staging dir for logs).
printf '%s\r\n' "$ESP_N" | sudo -n tee "$WIN_MNT/OEM/esp-part.txt" >/dev/null
printf '%s\n' "$ESP_N" > "$BUILD/esp-part.txt"
sudo -n sync
sudo -n umount "$WIN_MNT"
WIN_MOUNTED=0
echo "  staged (ESP is partition $ESP_N; WinPE reads OEM\\esp-part.txt)"

echo "[5b/6] clear the NTFS dirty flag (avoids a forced autochk on first boot)"
sudo -n ntfsfix -d "$WINPART" || true

echo "[6/6] verify and disconnect"
if [ "$NBD" = 1 ]; then
    sudo -n qemu-nbd --disconnect "$SDB" >/dev/null
    NBD=0
    qemu-img info "$IMG" | sed -n '1,12p'
    ls -lh "$IMG"
    echo "OK: $IMG"
else
    sudo -n blockdev --getsize64 "$DEV"
    echo "OK: $DEV"
fi
echo "Next: boot WinPE with the manual bootfat; manual_start.finish.cmd"
echo "detects the existing Windows and runs manual_finish.cmd (drivers +"
echo "bcdboot), then shuts the VM down."
