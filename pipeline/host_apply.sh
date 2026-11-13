#!/usr/bin/env bash
# Fast install path: apply install.wim/esd to a fresh disk with
# wimlib-imagex.  wimlib writes directly to the NTFS volume through
# libntfs-3g and preserves Windows ACLs, hard links, reparse points and
# timestamps.  This avoids the extremely slow DISM /apply-image under QEMU.
#
# The target can be a qcow2 file (created from scratch) or a raw block
# device such as /dev/sdb.  A block device is wiped completely, unless
# KEEP_UBUNTU=1 is set: then the ESP is kept and partition 2 is recreated as
# a small ext4 recovery system (RECOVERY_SIZE, default 4G) instead of being
# deleted.  pipeline/make_recovery_ubuntu.sh fills it afterwards.
#
# Usage: ./host_apply.sh <windows-arm64.iso> <disk.qcow2|/dev/sdX> [index]
#
# The ESP boot files and offline driver injection are done afterwards by
# booting WinPE with manual_start.finish.cmd, which detects the existing
# Windows and calls manual_finish.cmd.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ISO=${1:?usage: $0 <iso> <disk.qcow2|/dev/sdX> [index]}
IMG=${2:?usage: $0 <iso> <disk.qcow2|/dev/sdX> [index]}
INDEX=${3:-1}
MEDIA=${MEDIA:-$ROOT/build/media}
DRIVERS=${DRIVERS:-$ROOT/build/drivers}
DRIVERS_EXTRA=${DRIVERS_EXTRA:-$ROOT/build/drivers-extra}
SIZE=${SIZE:-50G}
SDB=${SDB:-/dev/nbd0}
KEEP_UBUNTU=${KEEP_UBUNTU:-0}
REUSE_UBUNTU=${REUSE_UBUNTU:-0}
RECOVERY_SIZE=${RECOVERY_SIZE:-4G}

RAW=0
if [ -b "$IMG" ]; then
    RAW=1
fi

# /dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1
part() {
    if [[ "$1" =~ [0-9]$ ]]; then
        printf '%sp%s' "$1" "$2"
    else
        printf '%s%s' "$1" "$2"
    fi
}

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

[ -f "$ISO" ] || { echo "missing ISO: $ISO" >&2; exit 1; }
[ -f "$MEDIA/autounattend.xml" ] || { echo "missing $MEDIA/autounattend.xml; run make_oemdrv.sh first" >&2; exit 1; }
[ -d "$MEDIA/oem" ] || { echo "missing $MEDIA/oem" >&2; exit 1; }
[ -d "$DRIVERS" ] || { echo "missing $DRIVERS; run scripts/stage-drivers.sh" >&2; exit 1; }

if pgrep -f "qemu-system-aarch64.*$IMG" >/dev/null 2>&1; then
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
    if [ "$KEEP_UBUNTU" = 1 ]; then
        echo "[2/6] reuse the existing qcow2 ($IMG)"
        [ -f "$IMG" ] || { echo "KEEP_UBUNTU needs an existing qcow2: $IMG" >&2; exit 1; }
    else
        echo "[2/6] create fresh qcow2 ($SIZE)"
        rm -f "$IMG"
        qemu-img create -f qcow2 "$IMG" "$SIZE" >/dev/null
    fi
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
    [ "$(lsblk -no FSTYPE "$P1" | tr -d ' ')" = vfat ] || {
        echo "$P1 is not FAT32; the ESP must stay as it is" >&2; exit 1; }
    case "$(lsblk -no FSTYPE "$P2" | tr -d ' ')" in
        ext2|ext3|ext4) ;;
        *) echo "$P2 is not ext4; refusing to build next to it" >&2; exit 1 ;;
    esac
    require_two_partitions "$DEV"
    require_esp_free "$P1"

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
    P3=$(part "$DEV" 3)
    [ -b "$P3" ] || { echo "partition 3 did not appear" >&2; exit 1; }
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV"
    P3START=$(lsblk -no START "$P3" | tr -d ' ')
    [ -n "$P3START" ] || { echo "cannot determine p3 start sector" >&2; exit 1; }
    sudo -n mkntfs -f -F -L Windows -p "$P3START" -H 255 -S 63 "$P3" >/dev/null
    echo "  formatted (p3 starts at sector $P3START)"
elif [ "$KEEP_UBUNTU" = 1 ]; then
    echo "[3/6] keep the ESP, shrink Ubuntu to $RECOVERY_SIZE, add Windows"
    sudo -n partprobe "$DEV" 2>/dev/null || true
    sleep 1
    P1=$(part "$DEV" 1)
    P2=$(part "$DEV" 2)
    [ -b "$P1" ] || { echo "no ESP at $P1" >&2; exit 1; }
    [ -b "$P2" ] || { echo "no Ubuntu partition at $P2" >&2; exit 1; }
    ESP_FS=$(lsblk -no FSTYPE "$P1" | tr -d ' ')
    [ "$ESP_FS" = vfat ] || { echo "$P1 is not FAT32 ($ESP_FS)" >&2; exit 1; }
    require_two_partitions "$DEV"
    require_esp_free "$P1"

    P2START=$(cat "/sys/class/block/$(basename "$P2")/start")
    sudo -n sgdisk -d 2 "$DEV" >/dev/null
    sudo -n sgdisk \
        -n "2:${P2START}:+${RECOVERY_SIZE}" -t 2:8300 -c 2:"Ubuntu" \
        -n 3:0:0 -t 3:0700 -c 3:"Windows" \
        "$DEV" >/dev/null
    sudo -n partprobe "$DEV" 2>/dev/null || true
    sleep 2
    P2=$(part "$DEV" 2)
    P3=$(part "$DEV" 3)
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV"
    P3START=$(lsblk -no START "$P3" | tr -d ' ')
    [ -n "$P3START" ] || { echo "cannot determine p3 start sector" >&2; exit 1; }
    sudo -n mkfs.ext4 -F -L Ubuntu "$P2" >/dev/null
    sudo -n mkntfs -f -F -L Windows -p "$P3START" -H 255 -S 63 "$P3" >/dev/null
    echo "  formatted (p2 $RECOVERY_SIZE ext4, p3 starts at sector $P3START)"
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
    P1=$(part "$DEV" 1)
    P3=$(part "$DEV" 3)
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DEV"
    P3START=$(lsblk -no START "$P3" | tr -d ' ')
    [ -n "$P3START" ] || { echo "cannot determine p3 start sector" >&2; exit 1; }
    # -f is a quick format: without it mkntfs zeroes the whole volume, which
    # balloons the qcow2 and is extremely slow over NBD.  -p/-H/-S give the
    # NTFS BPB the same geometry Windows uses, so Windows can boot from it.
    sudo -n mkfs.vfat -F32 -n SYSTEM "$P1" >/dev/null
    sudo -n mkntfs -f -F -L Windows -p "$P3START" -H 255 -S 63 "$P3" >/dev/null
    echo "  formatted (p3 starts at sector $P3START)"
fi

echo "[4/6] apply image $INDEX with wimlib-imagex"
time sudo -n wimlib-imagex apply "$WIM" "$INDEX" "$P3"

echo "[5/6] stage unattend, OEM scripts and drivers"
sudo -n mount -t ntfs-3g "$P3" "$WIN_MNT"
WIN_MOUNTED=1
sudo -n mkdir -p "$WIN_MNT/Windows/Panther"
sudo -n cp "$MEDIA/autounattend.xml" "$WIN_MNT/Windows/Panther/unattend.xml"
sudo -n cp -a "$MEDIA/oem" "$WIN_MNT/OEM"
sudo -n cp -a "$DRIVERS" "$WIN_MNT/drivers"
[ -d "$DRIVERS_EXTRA" ] && sudo -n cp -a "$DRIVERS_EXTRA" "$WIN_MNT/drivers-extra"
sudo -n sync
sudo -n umount "$WIN_MNT"
WIN_MOUNTED=0
echo "  staged"

echo "[5b/6] clear the NTFS dirty flag (avoids a forced autochk on first boot)"
sudo -n ntfsfix -d "$P3" || true

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
