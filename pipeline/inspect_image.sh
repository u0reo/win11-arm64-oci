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
            # MOVZ W0, #imm16 keeps the immediate in bits 20:5.
            alloc = (w[3] >> 5) & 0xffff
            print(f"bootmgfw patch site rva={s.VirtualAddress+i+12:#x} alloc_type={alloc} (1=AnyPages patched, 2=stock)")
PY
fi

echo "=== boot layout ==="
BOOTMGFW="$ESP/EFI/Microsoft/Boot/bootmgfw.efi"
if [ -f "$ESP/EFI/ubuntu/grubaa64.efi" ]; then
    echo "first loader: GRUB (EFI/ubuntu/grubaa64.efi)"
    SHA_BOOT=$(sha256sum "$ESP/EFI/BOOT/BOOTAA64.EFI" 2>/dev/null | awk '{print $1}')
    SHA_SHIM=$(sha256sum "$ESP/EFI/ubuntu/shimaa64.efi" 2>/dev/null | awk '{print $1}')
    SHA_GRUB=$(sha256sum "$ESP/EFI/ubuntu/grubaa64.efi" 2>/dev/null | awk '{print $1}')
    SHA_BOOTMGR=$(sha256sum "$BOOTMGFW" 2>/dev/null | awk '{print $1}')
    if [ -n "$SHA_BOOT" ] && [ "$SHA_BOOT" = "$SHA_SHIM" ]; then
        echo "EFI/BOOT/BOOTAA64.EFI = shim"
    elif [ -n "$SHA_BOOT" ] && [ "$SHA_BOOT" = "$SHA_GRUB" ]; then
        echo "EFI/BOOT/BOOTAA64.EFI = GRUB (no shim; Secure Boot must be off)"
    elif [ -n "$SHA_BOOT" ] && [ "$SHA_BOOT" = "$SHA_BOOTMGR" ]; then
        echo "EFI/BOOT/BOOTAA64.EFI = Windows boot manager (GRUB is not first!)"
    else
        echo "EFI/BOOT/BOOTAA64.EFI = unknown (sha256 ${SHA_BOOT:-missing})"
    fi
    if command -v mshowfat >/dev/null 2>&1; then
        for rel in /EFI/Microsoft/Boot/bootmgfw.efi \
                   /EFI/ubuntu/grub.cfg /EFI/BOOT/grub.cfg; do
            START=$(sudo -n mshowfat -i "$ESPDEV" "::$rel" 2>/dev/null |
                sed -n 's/^[^<]*<\([0-9][0-9]*\)-[0-9][0-9]*>.*/\1/p' | head -1)
            [ -n "$START" ] || continue
            if [ "$START" -lt 65536 ]; then
                echo "$rel FAT start cluster: $START (OK, < 65536)"
            else
                echo "$rel FAT start cluster: $START (TOO HIGH for GRUB)"
            fi
        done
    fi
    echo "--- EFI/ubuntu/grub.cfg ---"
    sed -n '1,40p' "$ESP/EFI/ubuntu/grub.cfg" 2>/dev/null || true
else
    echo "first loader: Windows Boot Manager (no EFI/ubuntu/grubaa64.efi)"
fi

echo "=== Windows Boot Manager BCD ==="
python3 - "$ESP/EFI/Microsoft/Boot/BCD" <<'PY' 2>/dev/null || true
import sys
import hivex

h = hivex.Hivex(sys.argv[1])
objects = h.node_get_child(h.root(), 'Objects')


def element(obj, name):
    elements = h.node_get_child(obj, 'Elements')
    if not elements:
        return None
    node = h.node_get_child(elements, name)
    if not node:
        return None
    value = h.node_get_value(node, 'Element')
    if not value:
        return None
    return h.value_value(value)


def text(obj, name):
    got = element(obj, name)
    if not got:
        return ''
    vtype, data = got
    if vtype not in (1, 7):
        return ''
    return data.decode('utf-16le', 'replace').rstrip('\0')


def text_list(obj, name):
    got = element(obj, name)
    if not got:
        return []
    vtype, data = got
    if vtype not in (1, 7):
        return []
    return [x for x in data.decode('utf-16le', 'replace').split('\0') if x]


bootmgr = None
for obj in h.node_children(objects):
    if text(obj, '12000004') == 'Windows Boot Manager':
        bootmgr = obj
        break
if bootmgr is None:
    bootmgr = h.node_get_child(objects, '{9dea862c-5cdd-4e70-acc1-f32b344d4795}')
order = text_list(bootmgr, '24000001') if bootmgr else []
if bootmgr:
    print('default:        ', text(bootmgr, '23000003') or '<none>')
    timeout = element(bootmgr, '25000004')
    if timeout:
        print('timeout:        ', int.from_bytes(timeout[1], 'little'))
    print('displayorder:   ', ' '.join(order))
    menu = element(bootmgr, '25000005')
    print('displaybootmenu:', menu[1][0] if menu and menu[1] else '?')
print('entries with a description or path:')
for obj in h.node_children(objects):
    guid = h.node_name(obj)
    if not guid.startswith('{'):
        continue
    desc = text(obj, '12000004')
    path = text(obj, '12000002')
    if not desc and not path:
        continue
    mark = ''
    if path.lower().startswith('\\efi\\ubuntu\\') or desc == 'Ubuntu (recovery)':
        if guid in order:
            mark = '  <-- Ubuntu bootapp in Windows displayorder (should be gone)'
        else:
            mark = '  (Ubuntu firmware mirror, not in Windows displayorder)'
    print(f'  {guid}  {desc!r}  {path}{mark}')
PY

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
# Windows may load a driver straight from the DriverStore, so checking only
# System32\drivers reports a false MISSING for vioscsi/netkvm on this image.
for f in vioscsi netkvm viogpudo viostor balloon; do
    found=""
    for c in "$WIN/Windows/System32/drivers/$f.sys" \
             "$WIN"/Windows/System32/DriverStore/FileRepository/"$f".inf_*/*.sys; do
        if [ -e "$c" ]; then found=$c; break; fi
    done
    if [ -n "$found" ]; then
        echo "$f.sys size=$(stat -c %s "$found") path=${found#"$WIN"}"
    else
        echo "$f.sys MISSING"
    fi
done

echo "=== RDP / WinRM / OOBE registry ==="
python3 - "$WIN/Windows/System32/config/SYSTEM" "$WIN/Windows/System32/config/SOFTWARE" <<'PY' 2>/dev/null || true
import sys, hivex

def open_hive(path):
    return hivex.Hivex(path, write=False)

def ch(h, n, name):
    try: return h.node_get_child(n, name)
    except Exception: return None

def val(h, n, name):
    try:
        t, b = h.value_value(h.node_get_value(n, name))
        if t in (1, 2, 7): return b.decode('utf-16le', 'replace').rstrip('\x00')
        if t == 4: return int.from_bytes(b, 'little')
        return b.hex()
    except Exception:
        return None

def lookup(h, path):
    n = h.root()
    for x in path[:-1]:
        n = ch(h, n, x)
        if n is None:
            return None, None
    return n, path[-1]

h = open_hive(sys.argv[1])
for label, path in [
 ('RDP fDenyTSConnections', ['ControlSet001','Control','Terminal Server','fDenyTSConnections']),
 ('RDP UserAuthentication', ['ControlSet001','Control','Terminal Server','WinStations','RDP-Tcp','UserAuthentication']),
 ('RDP SecurityLayer', ['ControlSet001','Control','Terminal Server','WinStations','RDP-Tcp','SecurityLayer']),
 ('TermService Start', ['ControlSet001','Services','TermService','Start']),
 ('WinRM Start', ['ControlSet001','Services','WinRM','Start']),
 ('HiberbootEnabled', ['ControlSet001','Control','Session Manager','Power','HiberbootEnabled']),
 ('HibernateEnabled', ['ControlSet001','Control','Power','HibernateEnabled']),
 ('Time RealTimeIsUniversal', ['ControlSet001','Control','TimeZoneInformation','RealTimeIsUniversal']),
 ('Setup OOBEInProgress', ['Setup','OOBEInProgress']),
 ('Setup SystemSetupInProgress', ['Setup','SystemSetupInProgress']),
]:
    n, name = lookup(h, path)
    print(label, '=', val(h, n, name) if n is not None else '?')

h = open_hive(sys.argv[2])
for label, path in [
 ('OOBE SkipMachineOOBE', ['Microsoft','Windows','CurrentVersion','OOBE','SkipMachineOOBE']),
 ('OOBE SkipUserOOBE', ['Microsoft','Windows','CurrentVersion','OOBE','SkipUserOOBE']),
 ('OOBE LaunchUserOOBE', ['Microsoft','Windows','CurrentVersion','OOBE','LaunchUserOOBE']),
 ('OOBE RecoveryOOBEEnabled', ['Microsoft','Windows','CurrentVersion','OOBE','RecoveryOOBEEnabled']),
 ('Winlogon AutoAdminLogon', ['Microsoft','Windows NT','CurrentVersion','Winlogon','AutoAdminLogon']),
 ('Winlogon DefaultUserName', ['Microsoft','Windows NT','CurrentVersion','Winlogon','DefaultUserName']),
]:
    n, name = lookup(h, path)
    print(label, '=', val(h, n, name) if n is not None else '?')
PY

echo "=== OEM files / logs ==="
find "$WIN/OEM" -maxdepth 2 -type f -printf '%10s %p\n' 2>/dev/null | sort || true
for f in specialize.log firstlogon.log boot.log done.txt firstlogon.done; do
    if [ -e "$WIN/OEM/$f" ]; then
        echo "--- $f ---"
        tail -40 "$WIN/OEM/$f" 2>/dev/null || true
    fi
done

echo "=== serial console / EMS ==="
# The old check grepped specialize.log, but that log can lose lines when two
# PowerShell instances append to it.  Read the BCD elements directly instead.
python3 - "$ESP/EFI/Microsoft/Boot/BCD" <<'PY' 2>/dev/null || true
import sys
import hivex

h = hivex.Hivex(sys.argv[1])
objects = h.node_get_child(h.root(), 'Objects')


def element(obj, name):
    elements = h.node_get_child(obj, 'Elements')
    if not elements:
        return None
    node = h.node_get_child(elements, name)
    if not node:
        return None
    value = h.node_get_value(node, 'Element')
    if not value:
        return None
    return h.value_value(value)


def text(obj, name):
    got = element(obj, name)
    if not got:
        return ''
    vtype, data = got
    if vtype not in (1, 7):
        return ''
    return data.decode('utf-16le', 'replace').rstrip('\0')


def boolean(obj, name):
    got = element(obj, name)
    return bool(got[1][0]) if got and got[1] else None


def integer(obj, name):
    got = element(obj, name)
    return int.from_bytes(got[1], 'little') if got and got[1] else None


bootmgr = None
for obj in h.node_children(objects):
    if text(obj, '12000004') == 'Windows Boot Manager':
        bootmgr = obj
        break

if bootmgr:
    print('Windows Boot Manager: timeout=%ss displaybootmenu=%s' % (
        integer(bootmgr, '25000004'), boolean(bootmgr, '25000005')))
    bootems = boolean(bootmgr, '25000006')
    default = text(bootmgr, '23000003')
    loader = h.node_get_child(objects, default) if default.startswith('{') else None
else:
    bootems = None
    loader = None

if loader:
    ems = boolean(loader, '26000000')
    port = integer(loader, '26000001')
    baud = integer(loader, '26000002')
else:
    ems = port = baud = None

if ems:
    print('EMS/SAC: enabled emsport=%s emsbaudrate=%s bootems=%s' % (
        port, baud, bootems))
else:
    # bcdedit on this ARM64 image prints an error saying EMS is x64-only and
    # returns 0, so the absence of the elements is expected, not a failure.
    print('EMS/SAC: unavailable (ARM64 Windows does not support EMS; '
          'no EMS elements in the BCD)')
PY

echo "=== disk usage ==="
df -h "$WIN" "$ESP" | sed -n '1,5p'
echo "=== inspect done ==="
