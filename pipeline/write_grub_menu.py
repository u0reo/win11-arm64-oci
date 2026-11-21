#!/usr/bin/env python3
"""Write the GRUB menu that boots Windows 11 and the recovery Ubuntu.

GRUB is the disk's first loader.  The firmware starts shim at
\\EFI\\BOOT\\BOOTAA64.EFI; shim starts the signed GRUB, which reads
\\EFI\\ubuntu\\grub.cfg (the built-in prefix) and shows this menu on the EFI
console.  The firmware mirrors the EFI console to the OCI serial console, so
the arrow keys and Enter work there as well as on VNC.

Windows is the default entry.  GRUB first makes the ESP the root, then
chainloads \\EFI\\Microsoft\\Boot\\bootmgfw.efi.  Ubuntu is booted directly
from the recovery ext4 partition so the menu does not depend on a second
GRUB configuration.

Usage:
    write_grub_menu.py ESP_MNT UBUNTU_MNT ROOT_DEV [--timeout 1] [--diagnostics]

--diagnostics adds boot-stage markers in EFI/ubuntu/grubenv and, when
EFI/Microsoft/Boot/bootmgfw-dbg.efi exists, a second Windows entry that
chainloads that copy.

Both filesystems must already be mounted.  Run as root (or with sudo) so the
menu can be written to the ESP.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

WINDOWS_LABEL = "Windows 11"
UBUNTU_LABEL = "Ubuntu (recovery)"


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def root_uuid(dev: str) -> str:
    try:
        out = subprocess.check_output(
            ["blkid", "-o", "value", "-s", "UUID", dev],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        out = ""
    return out


def fstab_uuid(ubuntu_mnt: str) -> str:
    """Fallback for a blkid failure: read the UUID from the root entry."""
    path = os.path.join(ubuntu_mnt, "etc/fstab")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                fields = line.split()
                if len(fields) < 2 or fields[1] != "/":
                    continue
                if fields[0].startswith("UUID="):
                    return fields[0][5:]
    except OSError:
        pass
    return ""


def version_key(name: str) -> list[object]:
    """Natural sort key: 7.0.0-30 sorts after 7.0.0-9."""
    return [int(part) if part.isdigit() else part
            for part in re.split(r"(\d+)", name)]


def symlink_target(ubuntu_mnt: str, name: str, prefix: str) -> str:
    """Return /boot/<target> for a /boot/<name> symlink, or an empty string.

    The versioned file is used instead of the symlink so the GRUB menu keeps
    working even if /boot is not searched with symlink support.
    """
    link = os.path.join(ubuntu_mnt, "boot", name)
    if not os.path.lexists(link):
        return ""
    real = os.path.realpath(link)
    base = os.path.basename(real)
    if os.path.isfile(real) and base.startswith(prefix):
        return "/boot/" + base
    return ""


def newest_file(ubuntu_mnt: str, prefix: str) -> str:
    boot = os.path.join(ubuntu_mnt, "boot")
    try:
        names = [n for n in os.listdir(boot) if n.startswith(prefix)]
    except OSError:
        return ""
    names = [n for n in names if os.path.isfile(os.path.join(boot, n))]
    if not names:
        return ""
    names.sort(key=version_key)
    return "/boot/" + names[-1]


def find_boot_files(ubuntu_mnt: str) -> tuple[str, str]:
    kernel = symlink_target(ubuntu_mnt, "vmlinuz", "vmlinuz-")
    if not kernel:
        kernel = newest_file(ubuntu_mnt, "vmlinuz-")
    if not kernel:
        die(f"no /boot/vmlinuz-* in {ubuntu_mnt}")

    version = kernel[len("/boot/vmlinuz-"):]
    initrd = f"/boot/initrd.img-{version}"
    if not os.path.isfile(os.path.join(ubuntu_mnt, initrd.lstrip("/"))):
        initrd = symlink_target(ubuntu_mnt, "initrd.img", "initrd.img-")
    if not initrd:
        initrd = newest_file(ubuntu_mnt, "initrd.img-")
    if not initrd:
        die(f"no /boot/initrd.img-* in {ubuntu_mnt}")
    return kernel, initrd


def menu_text(timeout: int, uuid: str, kernel: str, initrd: str,
              diagnostics: bool = False, debug_copy: bool = False) -> str:
    diag_top = ""
    win_body = """    insmod part_gpt
    insmod fat
    insmod chain
    # bootmgfw.efi reads \\EFI\\Microsoft\\Boot\\BCD from its own device.  If
    # $root is still the Ubuntu partition, Windows fails with 0xc00000bb.
    search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
"""
    dbg_entry = ""
    ubuntu_body = """    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root {uuid}
    linux {kernel} root=UUID={uuid} ro console=ttyAMA0,115200 console=tty1
    initrd {initrd}
""".format(uuid=uuid, kernel=kernel, initrd=initrd)

    if diagnostics:
        diag_top = """
# Boot diagnostics: each step is saved to EFI/ubuntu/grubenv before control
# leaves GRUB.  After a failed boot, run:
#   grub-editenv /boot/efi/EFI/ubuntu/grubenv list
# A missing marker shows how far the boot got.  Use --diagnostics only while
# investigating a native boot failure.
set grub_menu_seen=1
save_env grub_menu_seen
"""
        win_body = """    insmod part_gpt
    insmod fat
    insmod chain
    set win_entry=1
    save_env win_entry
    echo "GRUB diag: searching for bootmgfw.efi"
    search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
    echo "GRUB diag: root=$root"
    ls -l /EFI/Microsoft/Boot/bootmgfw.efi
    set win_chainload=1
    save_env win_chainload
    echo "GRUB diag: starting the Windows boot manager"
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
    set win_returned=1
    save_env win_returned
    echo "GRUB diag: bootmgfw.efi returned; Windows did not start"
    sleep 10
"""
        ubuntu_body = """    insmod part_gpt
    insmod ext2
    set ubuntu_entry=1
    save_env ubuntu_entry
    search --no-floppy --fs-uuid --set=root {uuid}
    linux {kernel} root=UUID={uuid} ro console=ttyAMA0,115200 console=tty1
    initrd {initrd}
""".format(uuid=uuid, kernel=kernel, initrd=initrd)

    if diagnostics and debug_copy:
        dbg_entry = f"""
menuentry "{WINDOWS_LABEL} (debug copy)" {{
    insmod part_gpt
    insmod fat
    insmod chain
    set dbg_entry=1
    save_env dbg_entry
    echo "GRUB diag: searching for the debug copy"
    search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw-dbg.efi
    echo "GRUB diag: root=$root"
    ls -l /EFI/Microsoft/Boot/bootmgfw-dbg.efi
    set dbg_chainload=1
    save_env dbg_chainload
    echo "GRUB diag: starting the debug copy"
    chainloader /EFI/Microsoft/Boot/bootmgfw-dbg.efi
    set dbg_returned=1
    save_env dbg_returned
    echo "GRUB diag: debug copy returned; Windows did not start"
    sleep 10
}}
"""

    return f"""# Generated by pipeline/write_grub_menu.py.  Do not edit by hand.
#
# GRUB is the first loader.  The firmware exposes the EFI console on both the
# video console and the serial port, so this menu and its arrow keys work
# over the OCI serial console.  Do not load GRUB's own "serial" module here:
# it is an x86 COM-port driver and fails on ARM64.
set timeout={timeout}
set default=0
set timeout_style=menu
{diag_top}
menuentry "{WINDOWS_LABEL}" {{
{win_body}}}

{dbg_entry}menuentry "{UBUNTU_LABEL}" {{
{ubuntu_body}}}
"""


def write_file(path: str, data: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
    os.chmod(path, 0o644)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("esp", help="mounted EFI System partition")
    parser.add_argument("ubuntu", help="mounted Ubuntu recovery root")
    parser.add_argument("root_dev", help="Ubuntu root block device (for blkid)")
    parser.add_argument("--timeout", type=int, default=1,
                        help="GRUB menu timeout in seconds (default: 1)")
    parser.add_argument("--diagnostics", action="store_true",
                        help="record boot stages in EFI/ubuntu/grubenv and "
                             "add a debug-copy Windows entry")
    args = parser.parse_args()

    if args.timeout < 0:
        die("--timeout must be zero or more")

    esp = os.path.abspath(args.esp)
    ubuntu = os.path.abspath(args.ubuntu)
    if not os.path.isfile(os.path.join(esp, "EFI/Microsoft/Boot/bootmgfw.efi")):
        die(f"no Windows boot manager under {esp}")
    if not os.path.isdir(os.path.join(ubuntu, "boot")):
        die(f"no /boot under {ubuntu}")

    uuid = root_uuid(args.root_dev) or fstab_uuid(ubuntu)
    if not uuid:
        die(f"cannot determine the UUID of {args.root_dev}")
    kernel, initrd = find_boot_files(ubuntu)
    debug_copy = os.path.isfile(
        os.path.join(esp, "EFI/Microsoft/Boot/bootmgfw-dbg.efi"))
    text = menu_text(args.timeout, uuid, kernel, initrd, args.diagnostics,
                     debug_copy)

    # GRUB's built-in prefix is /EFI/ubuntu, so that is the file it really
    # reads.  EFI/BOOT/grub.cfg is a copy for a GRUB installed with the
    # EFI/BOOT prefix; keeping it identical avoids a second source of truth.
    paths = [os.path.join(esp, "EFI/ubuntu/grub.cfg"),
             os.path.join(esp, "EFI/BOOT/grub.cfg")]
    for path in paths:
        write_file(path, text)

    for path in paths:
        with open(path, encoding="utf-8") as f:
            got = f.read()
        for label in (WINDOWS_LABEL, UBUNTU_LABEL):
            if f'menuentry "{label}"' not in got:
                die(f"{path}: {label} entry is missing after writing")

    print(f"root UUID:   {uuid}")
    print(f"kernel:      {kernel}")
    print(f"initrd:      {initrd}")
    print(f"timeout:     {args.timeout}s (default: {WINDOWS_LABEL})")
    for path in paths:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
