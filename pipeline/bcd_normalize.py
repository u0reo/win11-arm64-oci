#!/usr/bin/env python3
"""Normalise a Windows BCD hive for Oracle OCI ARM64.

This image is built from a modified Windows installation whose boot files do
not pass the signed-image checks that Windows would normally perform.  It
also runs on firmware that exposes a PL011 serial console, where the Windows
Boot Manager and EMS both write to the same UART.

The script combines the findings from WORKLOG 22.21-22.23 and the known-good
``/dev/sdb`` comparison in 22.44:

* Explicit EMS settings (``EmsPort``/``EmsBaudRate``) point at the x86 COM1
  I/O port 0x3F8.  The OCI serial port is a PL011 at MMIO 0x09000000, so an
  explicit port is invalid and was observed to hang bootmgr silently.
* ``bootems`` (16000020) and ``EmsEnable`` (260000b0) make Windows write boot
  messages to the same PL011 that its normal ConOut already uses.  On the OCI
  console every character is then printed twice ("WWiinnddoowwss").  Disable
  both; GRUB and the firmware still show their own menus on serial.
* ``nointegritychecks`` (16000048) must stay enabled on this image.  Removing
  it brings back 0xc0000428 ("The digital signature for this file could not
  be verified").  Earlier revisions of this pipeline removed it as a debug
  leftover; that was the regression fixed in WORKLOG 22.46.
* ``graphicsmodedisabled`` (16000046) and ``bootuxdisabled`` (1600006c) keep
  bootmgr on the text console instead of initialising a GOP path that the OCI
  virtio-gpu firmware does not always provide.  The working /dev/sdb has both
  set and boots on real hardware.
* ``bootlog`` (26000090) and ``sos`` (26000091) add verbose driver output to
  the serial console.  They are diagnostic leftovers, not needed for boot.

The script is idempotent.  It edits the ``{bootmgr}`` object and every object
whose path is ``\\Windows\\system32\\winload.efi``.  It removes the explicit
EMS port/baud elements from every object in the hive.

Usage:
    bcd_normalize.py EFI/Microsoft/Boot/BCD

The BCD must be writable and must not be in use.  finish_disk.sh calls it
while the ESP is mounted read-write.  bcd_disable_ems.py is kept as a
deprecated alias.
"""
from __future__ import annotations

import argparse
import sys

import hivex

BOOTMGR_GUID = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
ELEM_PATH = "12000002"
ELEM_DESCRIPTION = "12000004"
WINLOAD_SUFFIX = r"\windows\system32\winload.efi"

# Elements that must never be present: an explicit x86 COM port or its baud
# rate.  Windows on UEFI is supposed to read the serial port from SPCR.
REMOVE_ELEMENTS = {
    "15000022",  # EmsPort
    "15000023",  # EmsBaudRate
    "25000006",  # bootmgr bootems (alternate id)
    "26000000",  # loader EMS enabled
    "26000001",  # loader EmsPort
    "26000002",  # loader EmsBaudRate
    # Verbose diagnostic output.  It is not harmful, but it makes the OCI
    # serial console unreadable and is not part of a normal boot.
    "26000090",  # bootlog
    "26000091",  # sos
}

# Explicitly off.  Deleting these would fall back to the firmware/SPCR
# default, which is exactly the second serial writer seen on OCI.
DISABLED_ELEMENTS = {
    "16000020": "bootems",
    "260000b0": "EmsEnable",
}

# Applied to {bootmgr} and every Windows loader object.
SET_ELEMENTS = {
    "16000046": (b"\x01", "graphicsmodedisabled"),
    "16000048": (b"\x01", "nointegritychecks"),
    "1600006c": (b"\x01", "bootuxdisabled"),
}

REG_BINARY = 3
REG_SZ = 1


def get_element(h: hivex.Hivex, obj: int, name: str):
    elements = h.node_get_child(obj, "Elements")
    if not elements:
        return None
    element = h.node_get_child(elements, name)
    if not element:
        return None
    value = h.node_get_value(element, "Element")
    if not value:
        return None
    return h.value_value(value)


def get_string(h: hivex.Hivex, obj: int, name: str) -> str:
    got = get_element(h, obj, name)
    if got is None:
        return ""
    vtype, data = got
    if vtype not in (REG_SZ, 7):
        return ""
    return data.decode("utf-16le", "replace").rstrip("\0")


def set_binary(h: hivex.Hivex, obj: int, name: str, value: bytes) -> None:
    elements = h.node_get_child(obj, "Elements")
    if not elements:
        elements = h.node_add_child(obj, "Elements")
    element = h.node_get_child(elements, name)
    if not element:
        element = h.node_add_child(elements, name)
    h.node_set_value(element, {"key": "Element", "t": REG_BINARY,
                               "value": value})


def delete_element(h: hivex.Hivex, obj: int, name: str) -> None:
    elements = h.node_get_child(obj, "Elements")
    if not elements:
        return
    element = h.node_get_child(elements, name)
    if element:
        h.node_delete_child(element)


def find_bootmgr(h: hivex.Hivex, objects: int) -> int:
    for obj in h.node_children(objects):
        if get_string(h, obj, ELEM_DESCRIPTION) == "Windows Boot Manager":
            return obj
    node = h.node_get_child(objects, BOOTMGR_GUID)
    if node:
        return node
    raise SystemExit("no Windows Boot Manager object in the BCD")


def find_windows_loaders(h: hivex.Hivex, objects: int) -> list[int]:
    loaders = []
    for obj in h.node_children(objects):
        if get_string(h, obj, ELEM_PATH).lower().endswith(WINLOAD_SUFFIX):
            loaders.append(obj)
    return loaders


def normalize(h: hivex.Hivex) -> tuple[list[str], list[str]]:
    objects = h.node_get_child(h.root(), "Objects")
    if not objects:
        raise SystemExit("BCD has no Objects key")
    bootmgr = find_bootmgr(h, objects)
    loaders = find_windows_loaders(h, objects)
    if not loaders:
        raise SystemExit("BCD has no \\Windows\\system32\\winload.efi object")

    removed: list[str] = []
    changed: list[str] = []
    targets = [bootmgr] + loaders

    for obj in h.node_children(objects):
        guid = h.node_name(obj)
        for name in REMOVE_ELEMENTS:
            if get_element(h, obj, name) is not None:
                removed.append(f"{guid}/{name}")
                delete_element(h, obj, name)

    for obj in targets:
        guid = h.node_name(obj)
        for name, label in DISABLED_ELEMENTS.items():
            if get_element(h, obj, name) is None:
                set_binary(h, obj, name, b"\x00")
                changed.append(f"{guid}/{name}=0 ({label})")
            else:
                vtype, data = get_element(h, obj, name)
                if data != b"\x00":
                    set_binary(h, obj, name, b"\x00")
                    changed.append(f"{guid}/{name}=0 ({label})")
        for name, (value, label) in SET_ELEMENTS.items():
            got = get_element(h, obj, name)
            if got is None or got[1] != value:
                set_binary(h, obj, name, value)
                changed.append(f"{guid}/{name}={value.hex()} ({label})")
    return removed, changed


def verify(h: hivex.Hivex) -> list[str]:
    problems: list[str] = []
    objects = h.node_get_child(h.root(), "Objects")
    bootmgr = find_bootmgr(h, objects)
    loaders = find_windows_loaders(h, objects)
    if not loaders:
        problems.append("no Windows loader object")

    for obj in h.node_children(objects):
        guid = h.node_name(obj)
        for name in REMOVE_ELEMENTS:
            if get_element(h, obj, name) is not None:
                problems.append(f"{guid}/{name} is still present")

    for obj in [bootmgr] + loaders:
        guid = h.node_name(obj)
        for name, label in DISABLED_ELEMENTS.items():
            got = get_element(h, obj, name)
            if got is not None and got[1] != b"\x00":
                problems.append(f"{guid}/{name} ({label}) is not 0")
        for name, (value, label) in SET_ELEMENTS.items():
            got = get_element(h, obj, name)
            if got is None:
                problems.append(f"{guid}/{name} ({label}) is missing")
            elif got[1] != value:
                problems.append(
                    f"{guid}/{name} ({label}) is {got[1].hex()!r}, not {value.hex()!r}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bcd")
    args = parser.parse_args()

    hive = hivex.Hivex(args.bcd, write=True)
    removed, changed = normalize(hive)
    if removed or changed:
        hive.commit(None)

    # Reopen and verify: a failed commit must not look healthy.
    check = hivex.Hivex(args.bcd)
    problems = verify(check)
    if problems:
        raise SystemExit("BCD is not normalized: " + "; ".join(problems))

    if removed:
        print("removed BCD elements:")
        for item in removed:
            print("  " + item)
    if changed:
        print("set BCD elements:")
        for item in changed:
            print("  " + item)
    if not removed and not changed:
        print("BCD already normalized")
    print(f"OK: {args.bcd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
