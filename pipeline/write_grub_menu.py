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
    write_grub_menu.py ESP_MNT UBUNTU_MNT ROOT_DEV [--timeout 1]
                       [--diagnostics] [--first-boot-ubuntu]
                       [--live-iso ISO [--live-seed] [--first-boot-live]]

--diagnostics adds boot-stage markers in EFI/ubuntu/grubenv and, when
EFI/Microsoft/Boot/bootmgfw-dbg.efi exists, a second Windows entry that
chainloads that copy.

--live-iso adds a menuentry that boots an Ubuntu live ISO with `toram`.
--live-seed adds ds=nocloud to its command line (use with the CIDATA ESP
written by `scripts/prepare.sh --ssh`).  --first-boot-live selects the live
entry once via next_entry.

--first-boot-ubuntu writes next_entry="Ubuntu (recovery)" to
EFI/ubuntu/grubenv.  GRUB consumes it on the next power-on, so the recovery
Ubuntu runs once before Windows can create its own firmware entry and take
the first slot.  oci-ubuntu-boot-order.service then adds the Ubuntu entry
and moves it to the front; later boots use the normal Windows default.

Both filesystems must already be mounted.  Run as root (or with sudo) so the
menu can be written to the ESP.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

from grubenv import GrubenvError, read as read_grubenv, write as write_grubenv

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

    # make_recovery_ubuntu.sh extracts .linux from a UKI to <kernel>.raw.
    # Prefer that plain arm64 Image: GRUB's linux command then enters the
    # kernel EFI stub instead of stubble, which asserts when GRUB itself was
    # started from the EFI shell (see pipeline/extract_uki_kernel.py).
    raw = kernel + ".raw"
    if os.path.isfile(os.path.join(ubuntu_mnt, raw.lstrip("/"))):
        kernel = raw

    name = os.path.basename(kernel)
    if name.endswith(".raw"):
        name = name[:-4]
    version = name[len("vmlinuz-"):]
    initrd = f"/boot/initrd.img-{version}"
    if not os.path.isfile(os.path.join(ubuntu_mnt, initrd.lstrip("/"))):
        initrd = symlink_target(ubuntu_mnt, "initrd.img", "initrd.img-")
    if not initrd:
        initrd = newest_file(ubuntu_mnt, "initrd.img-")
    if not initrd:
        die(f"no /boot/initrd.img-* in {ubuntu_mnt}")
    return kernel, initrd


def live_entry(iso_path: str, label: str, seed: bool) -> tuple[str, str]:
    """Build a GRUB menu entry that boots a live ISO with `toram`.

    The ISO must live on a mounted filesystem with a UUID; GRUB finds it by
    that UUID and uses loopback to read /casper/vmlinuz and /casper/initrd.
    `toram` copies the live root into RAM so the underlying disk can be
    wiped.  Returns (entry_text, label).
    """
    path = os.path.abspath(iso_path)
    if not os.path.isfile(path):
        die(f"live ISO not found: {path}")
    try:
        mnt = subprocess.check_output(
            ["findmnt", "-no", "TARGET", "--target", path],
            text=True, stderr=subprocess.DEVNULL).strip()
        iso_uuid = subprocess.check_output(
            ["findmnt", "-no", "UUID", "--target", path],
            text=True, stderr=subprocess.DEVNULL).strip()
        fstype = subprocess.check_output(
            ["findmnt", "-no", "FSTYPE", "--target", path],
            text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        die(f"cannot find the mounted filesystem for {path}")
    if not mnt or not iso_uuid:
        die(f"{path} is not on a mounted filesystem with a UUID")
    if fstype in ("tmpfs", "ramfs"):
        die(f"{path} is on {fstype}; GRUB cannot read it after a reboot")
    rel = path[len(mnt):] or "/"
    if not rel.startswith("/"):
        rel = "/" + rel
    cmdline = ("toram ip=dhcp console=ttyAMA0,115200" +
               (" ds=nocloud" if seed else ""))
    text = f"""menuentry "{label}" {{
    insmod part_gpt
    insmod ext2
    insmod loopback
    insmod iso9660
    search --no-floppy --fs-uuid --set=root {iso_uuid}
    set isofile="{rel}"
    loopback loop $isofile
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile \\
        {cmdline} ---
    initrd (loop)/casper/initrd
}}
"""
    return text, label


def menu_text(timeout: int, uuid: str, kernel: str, initrd: str,
              diagnostics: bool = False, debug_copy: bool = False,
              live_entry: str = "") -> str:
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
# leaves GRUB.  After a failed boot, read the block with:
#   grub-editenv /boot/efi/EFI/ubuntu/grubenv list
# The minimal recovery image has no grub-editenv; this needs only coreutils:
#   sudo cat /boot/efi/EFI/ubuntu/grubenv | tr '\\0' '\\n' | grep -E '^(grub_|win_|dbg_|ubuntu_)'
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
    # Reaching this line is normal when the user presses ESC=Exit (or F8 and
    # then exits) in the Windows menu.  It only means Windows did not take
    # over this time; it is not proof that the loader is broken.
    set win_returned=1
    save_env win_returned
    echo "GRUB diag: bootmgfw.efi returned to GRUB (Exit/F8, or Windows failed to start)"
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
    echo "GRUB diag: debug copy returned to GRUB (Exit/F8, or Windows failed to start)"
    sleep 10
}}
"""

    return f"""# Generated by pipeline/write_grub_menu.py.  Do not edit by hand.
#
# GRUB is the first loader.  The firmware exposes the EFI console on both the
# video console and the serial port, so this menu and its arrow keys work
# over the OCI serial console.  Do not load GRUB's own "serial" module here:
# it is an x86 COM-port driver and fails on ARM64.
# Load EFI/ubuntu/grubenv first; save_env writes there and next_entry lives
# there.  Load it before setting timeout/default so the menu's own values win.
if [ -s $prefix/grubenv ]; then
    load_env
fi
set timeout={timeout}
set default=0
set timeout_style=menu
# grub-reboot and write_grub_menu.py --first-boot-ubuntu store a one-time
# selection in grubenv.  Consume it here so only the next boot uses it.
if [ -n "$next_entry" ]; then
    set default="$next_entry"
    set next_entry=
    save_env next_entry
fi
{diag_top}
menuentry "{WINDOWS_LABEL}" {{
{win_body}}}

{dbg_entry}{live_entry}menuentry "{UBUNTU_LABEL}" {{
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
    parser.add_argument("--first-boot-ubuntu", action="store_true",
                        help="run Ubuntu (recovery) on the next boot so it can "
                             "create its firmware boot entry before Windows "
                             "takes the first slot")
    parser.add_argument("--live-iso", metavar="ISO",
                        help="add a 'toram' live-ISO menuentry (the ISO must "
                             "be on a mounted filesystem with a UUID)")
    parser.add_argument("--live-label", default="Ubuntu live (toram)",
                        help="title of the live menuentry")
    parser.add_argument("--live-seed", action="store_true",
                        help="add ds=nocloud to the live kernel command line "
                             "(use with a CIDATA ESP from prepare.sh --ssh)")
    parser.add_argument("--first-boot-live", action="store_true",
                        help="run the live ISO on the next boot only")
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
    live = ""
    if args.live_iso:
        live, live_label = live_entry(args.live_iso, args.live_label,
                                      args.live_seed)
    else:
        live_label = args.live_label
    text = menu_text(args.timeout, uuid, kernel, initrd, args.diagnostics,
                     debug_copy, live)

    # GRUB's built-in prefix is /EFI/ubuntu, so that is the file it really
    # reads.  EFI/BOOT/grub.cfg is a copy for a GRUB installed with the
    # EFI/BOOT prefix; keeping it identical avoids a second source of truth.
    paths = [os.path.join(esp, "EFI/ubuntu/grub.cfg"),
             os.path.join(esp, "EFI/BOOT/grub.cfg")]
    for path in paths:
        write_file(path, text)

    labels = [WINDOWS_LABEL, UBUNTU_LABEL]
    if live:
        labels.append(live_label)
    for path in paths:
        with open(path, encoding="utf-8") as f:
            got = f.read()
        for label in labels:
            if f'menuentry "{label}"' not in got:
                die(f"{path}: {label} entry is missing after writing")

    env_path = os.path.join(esp, "EFI/ubuntu/grubenv")
    env_values: dict[str, str] | None
    try:
        env_values = read_grubenv(env_path)
    except GrubenvError as exc:
        if args.first_boot_ubuntu or args.first_boot_live or args.diagnostics:
            print(f"warning: {exc}; replacing it", file=sys.stderr)
            env_values = {}
        else:
            print(f"warning: {exc}; leaving it alone", file=sys.stderr)
            env_values = None
    if env_values is not None:
        if args.first_boot_live:
            if not live:
                die("--first-boot-live needs --live-iso")
            env_values["next_entry"] = live_label
        elif args.first_boot_ubuntu:
            env_values["next_entry"] = UBUNTU_LABEL
        if (args.first_boot_ubuntu or args.first_boot_live or
                args.diagnostics or env_values):
            # Create the block for --diagnostics (save_env needs it) and keep
            # any markers that are already there.
            try:
                write_grubenv(env_path, env_values)
            except (GrubenvError, OSError) as exc:
                die(str(exc))
            print(f"wrote {env_path}")

    print(f"root UUID:   {uuid}")
    print(f"kernel:      {kernel}")
    print(f"initrd:      {initrd}")
    print(f"timeout:     {args.timeout}s (default: {WINDOWS_LABEL})")
    if args.first_boot_ubuntu:
        print(f"first boot:  {UBUNTU_LABEL} once (next_entry)")
    if args.first_boot_live:
        print(f"first boot:  {live_label} once (next_entry)")
    if live:
        print(f"live ISO:    {args.live_iso}")
    for path in paths:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
