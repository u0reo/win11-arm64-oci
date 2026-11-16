#!/usr/bin/env bash
# Read-only inspection of an installed Windows ARM64 qcow2/raw image.
# Usage: ./inspect_image.sh /path/to/disk.qcow2 | /path/to/disk.raw | /dev/sdX
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=partitions.sh
. "$HERE/partitions.sh"
IMG=${1:?usage: $0 <disk.qcow2|disk.raw|/dev/sdX>}
[ -f "$IMG" ] || [ -b "$IMG" ] || { echo "missing $IMG" >&2; exit 1; }

ESP=$(mktemp -d /tmp/win-esp.XXXXXX)
WIN=$(mktemp -d /tmp/win-ntfs.XXXXXX)
NBD=0
LOOP=""
cleanup() {
    set +e
    sudo -n umount "$ESP" 2>/dev/null
    sudo -n umount "$WIN" 2>/dev/null
    [ "$NBD" = 1 ] && sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1
    [ -n "$LOOP" ] && sudo -n losetup -d "$LOOP" >/dev/null 2>&1
    cleanup_part_loops
    rmdir "$ESP" "$WIN" 2>/dev/null
}
trap cleanup EXIT

echo "=== image ==="
ls -lh "$IMG"
qemu-img info "$IMG" 2>/dev/null | sed -n '1,12p' || true

if [[ "$IMG" == *.qcow2 ]]; then
    sudo -n qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    sudo -n qemu-nbd --connect=/dev/nbd0 --format=qcow2 --read-only "$IMG"
    DEV=/dev/nbd0
    NBD=1
elif [ -b "$IMG" ]; then
    DEV=$IMG
else
    LOOP=$(sudo -n losetup --find --show --partscan --read-only "$IMG")
    DEV=$LOOP
fi
sudo -n partprobe "$DEV" 2>/dev/null || true
sleep 1

echo "=== partitions ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID "$DEV" || true
sudo -n sgdisk -p "$DEV" 2>/dev/null | sed -n '1,25p' || true

ESPDEV=$(find_esp "$DEV")
WINPART=$(find_windows "$DEV")
[ -n "$ESPDEV" ] || { echo "no EFI System partition found on $DEV" >&2; exit 1; }
[ -n "$WINPART" ] || { echo "no Windows/NTFS partition found on $DEV" >&2; exit 1; }
echo "ESP:      $ESPDEV"
echo "Windows:  $WINPART"

sudo -n mount -t vfat -o ro "$ESPDEV" "$ESP"
sudo -n mount -t ntfs-3g -o ro "$WINPART" "$WIN"

echo "=== ESP files ==="
find "$ESP/EFI" -maxdepth 3 -type f -printf '%10s %p\n' 2>/dev/null | sort -k2 | head -40 || true
BOOTMGFW="$ESP/EFI/Microsoft/Boot/bootmgfw.efi"
if [ -f "$BOOTMGFW" ]; then
    echo "bootmgfw size=$(stat -c %s "$BOOTMGFW") sha256=$(sha256sum "$BOOTMGFW" | awk '{print $1}')"
    python3 - "$BOOTMGFW" <<'PY' || true
import struct, sys, pefile
p=sys.argv[1]; data=open(p,'rb').read(); pe=pefile.PE(p,fast_load=True)
for s in pe.sections:
    if not (s.Characteristics & 0x20000000): continue
    b=data[s.PointerToRawData:s.PointerToRawData+s.SizeOfRawData]
    for i in range(0,len(b)-20,4):
        w=struct.unpack_from('<5I',b,i)
        if w[:4] in ((0x9101C3E3,0xD2800022,0x52800041,0x52800040),(0x9101C3E3,0xD2800022,0x52800041,0x52800020)):
            print(f"bootmgfw patch site rva={s.VirtualAddress+i+12:#x} alloc_type={w[3]&0xffff} (1=AnyPages patched, 2=stock)")
PY
fi

echo "=== Windows build / edition ==="
python3 - "$WIN/Windows/System32/config/SOFTWARE" <<'PY' 2>/dev/null || true
import sys, hivex
p=sys.argv[1]; h=hivex.Hivex(p,write=False); r=h.root()
def ch(n,name):
    try: return h.node_get_child(n,name)
    except Exception: return None
x=r
for k in ['Microsoft','Windows NT','CurrentVersion']: x=ch(x,k)
for name in ['CurrentVersion','CurrentBuild','CurrentBuildNumber','UBR','DisplayVersion','ProductName','EditionID','BuildLabEx']:
    try:
        t,b=h.value_value(h.node_get_value(x,name))
        if t in (1,2,7): print(name,'=',b.decode('utf-16le','replace').rstrip('\x00'))
        elif t==4: print(name,'=',int.from_bytes(b,'little'))
    except Exception: pass
PY

echo "=== core display / RDP files ==="
for f in Windows/System32/dwm.exe Windows/System32/dwmredir.dll Windows/System32/rdpidd.dll; do
    [ -e "$WIN/$f" ] && echo "$f size=$(stat -c %s "$WIN/$f") mtime=$(stat -c %y "$WIN/$f")" || echo "$f MISSING"
done
find "$WIN/Windows/System32/DriverStore/FileRepository" -maxdepth 2 -iname 'RdpIdd.dll' -printf '%s %p\n' 2>/dev/null || true

echo "=== virtio drivers ==="
for f in vioscsi netkvm viogpudo viostor balloon; do
    if [ -e "$WIN/Windows/System32/drivers/$f.sys" ]; then
        echo "$f.sys size=$(stat -c %s "$WIN/Windows/System32/drivers/$f.sys")"
    else
        echo "$f.sys MISSING"
    fi
done
find "$WIN/Windows/System32/DriverStore/FileRepository" -maxdepth 1 -type d \( -iname 'vioscsi*' -o -iname 'netkvm*' -o -iname 'viogpudo*' \) -printf '%f\n' 2>/dev/null || true

echo "=== RDP / WinRM registry ==="
python3 - "$WIN/Windows/System32/config/SYSTEM" <<'PY' 2>/dev/null || true
import sys, hivex
p=sys.argv[1]; h=hivex.Hivex(p,write=False); r=h.root()
def ch(n,name):
    try: return h.node_get_child(n,name)
    except Exception: return None
def val(n,name):
    try:
        t,b=h.value_value(h.node_get_value(n,name))
        if t in (1,2,7): return b.decode('utf-16le','replace').rstrip('\x00')
        if t==4: return int.from_bytes(b,'little')
        return b.hex()
    except Exception: return None
paths=[
 ('RDP fDenyTSConnections',['ControlSet001','Control','Terminal Server','fDenyTSConnections']),
 ('RDP UserAuthentication',['ControlSet001','Control','Terminal Server','WinStations','RDP-Tcp','UserAuthentication']),
 ('RDP SecurityLayer',['ControlSet001','Control','Terminal Server','WinStations','RDP-Tcp','SecurityLayer']),
 ('TermService Start',['ControlSet001','Services','TermService','Start']),
 ('WinRM Start',['ControlSet001','Services','WinRM','Start']),
]
for label,path in paths:
    n=r
    for x in path: n=ch(n,x)
    print(label,'=',val(n,path[-1]) if n is not None else '?')
PY

echo "=== OEM files / logs ==="
find "$WIN/OEM" -maxdepth 2 -type f -printf '%10s %p\n' 2>/dev/null | sort || true
for f in specialize.log firstlogon.log boot.log done.txt firstlogon.done; do
    if [ -e "$WIN/OEM/$f" ]; then
        echo "--- $f ---"
        tail -40 "$WIN/OEM/$f" 2>/dev/null || true
    fi
done

echo "=== serial (SAC) / boot menu ==="
if grep -q 'sac-configured' "$WIN/OEM/specialize.log" 2>/dev/null; then
    echo "SAC/EMS: $(grep -h 'sac-configured' "$WIN/OEM/specialize.log" | tail -1)"
else
    echo "SAC/EMS: NOT configured (no sac-configured in specialize.log)"
fi
if grep -q 'boot-menu-configured' "$WIN/OEM/specialize.log" 2>/dev/null; then
    grep -h 'boot-menu-configured' "$WIN/OEM/specialize.log" | tail -1
else
    echo "boot menu: off"
fi

echo "=== disk usage ==="
df -h "$WIN" "$ESP" | sed -n '1,5p'
echo "=== inspect done ==="
