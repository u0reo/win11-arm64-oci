#!/usr/bin/env python3
"""Add the recovery Ubuntu entry to a Windows Boot Manager BCD hive.

The WinPE pass runs bcdboot, which knows how to describe the Windows volume
but has no idea about the Ubuntu loader.  bcdedit can create a bootapp entry
there, yet on this image ``bcdedit /set <id> device partition=S:`` fails and
leaves an entry with only a description.  This script writes the missing
elements directly with hivex, using the same device element as the Windows
Boot Manager itself (the ESP), so the result does not depend on bcdedit's
partition-name resolution.

It is idempotent: an existing "Ubuntu (recovery)" entry (or one whose path is
already the Ubuntu loader) is reused, and duplicate entries are removed.

Usage:
    bcd_add_ubuntu.py EFI/Microsoft/Boot/BCD [--timeout 1]

The BCD must be writable and must not be in use.  Call it after QEMU has
stopped and while the ESP is mounted read-write.
"""
from __future__ import annotations

import argparse
import struct
import sys
import uuid

import hivex

DESCRIPTION = "Ubuntu (recovery)"
GRUB_PATH = r"\EFI\ubuntu\grubaa64.efi"

# BCD library elements (the numeric names are the registry value names).
ELEM_DEVICE = "11000001"
ELEM_PATH = "12000002"
ELEM_DESCRIPTION = "12000004"
ELEM_LOCALE = "12000005"
ELEM_DISPLAY_ORDER = "24000001"
ELEM_TIMEOUT = "25000004"
ELEM_DISPLAY_BOOT_MENU = "25000005"

APP_TYPE_BOOTAPP = 0x1020000A

REG_SZ = 1
REG_BINARY = 3
REG_DWORD = 4
REG_MULTI_SZ = 7


def get_element(h: hivex.Hivex, obj: int, name: str):
    """Return (type, data) for one BCD element, or None."""
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


def set_element(h: hivex.Hivex, obj: int, name: str, vtype: int,
                data: bytes) -> None:
    elements = h.node_get_child(obj, "Elements")
    if not elements:
        elements = h.node_add_child(obj, "Elements")
    element = h.node_get_child(elements, name)
    if not element:
        element = h.node_add_child(elements, name)
    h.node_set_value(element, {"key": "Element", "t": vtype, "value": data})


def get_string(h: hivex.Hivex, obj: int, name: str) -> str | None:
    got = get_element(h, obj, name)
    if got is None:
        return None
    vtype, data = got
    if vtype not in (REG_SZ, REG_MULTI_SZ):
        return None
    return data.decode("utf-16le", "replace").rstrip("\0")


def get_string_list(h: hivex.Hivex, obj: int, name: str) -> list[str]:
    got = get_element(h, obj, name)
    if got is None:
        return []
    vtype, data = got
    if vtype not in (REG_SZ, REG_MULTI_SZ):
        return []
    raw = data.decode("utf-16le", "replace")
    return [item for item in raw.split("\0") if item]


def set_string(h: hivex.Hivex, obj: int, name: str, value: str) -> None:
    set_element(h, obj, name, REG_SZ,
                value.encode("utf-16le") + b"\0\0")


def set_multi_string(h: hivex.Hivex, obj: int, name: str,
                     values: list[str]) -> None:
    data = "\0".join(values) + "\0\0"
    set_element(h, obj, name, REG_MULTI_SZ, data.encode("utf-16le"))


def set_binary(h: hivex.Hivex, obj: int, name: str, data: bytes) -> None:
    set_element(h, obj, name, REG_BINARY, data)


def object_guid(h: hivex.Hivex, node: int) -> str:
    return h.node_name(node)


def find_bootmgr(h: hivex.Hivex, objects: int) -> int:
    for obj in h.node_children(objects):
        if get_string(h, obj, ELEM_DESCRIPTION) == "Windows Boot Manager":
            return obj
    raise SystemExit("no Windows Boot Manager object in the BCD")


def find_ubuntu_entries(h: hivex.Hivex, objects: int) -> list[int]:
    found = []
    for obj in h.node_children(objects):
        desc = get_string(h, obj, ELEM_DESCRIPTION)
        path = get_string(h, obj, ELEM_PATH)
        if desc == DESCRIPTION or path == GRUB_PATH:
            found.append(obj)
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bcd")
    parser.add_argument("--timeout", type=int, default=1)
    args = parser.parse_args()

    h = hivex.Hivex(args.bcd, write=True)
    root = h.root()
    objects = h.node_get_child(root, "Objects")
    if not objects:
        raise SystemExit("BCD has no Objects key")

    bootmgr = find_bootmgr(h, objects)
    device = get_element(h, bootmgr, ELEM_DEVICE)
    if device is None or device[0] != REG_BINARY or not device[1]:
        raise SystemExit("the Windows Boot Manager has no device element")
    device_type, device_data = device

    entries = find_ubuntu_entries(h, objects)
    removed = []
    if entries:
        ubuntu = entries[0]
        for extra in entries[1:]:
            removed.append(object_guid(h, extra))
            h.node_delete_child(objects, extra)
    else:
        guid = str(uuid.uuid4())
        ubuntu = h.node_add_child(objects, guid)
        desc = h.node_add_child(ubuntu, "Description")
        h.node_set_value(desc, {
            "key": "Type",
            "t": REG_DWORD,
            "value": struct.pack("<I", APP_TYPE_BOOTAPP),
        })

    # The application type lives in the Description\Type value.  Repair it
    # for an entry that bcdedit created but could not finish.
    desc = h.node_get_child(ubuntu, "Description")
    if not desc:
        desc = h.node_add_child(ubuntu, "Description")
    h.node_set_value(desc, {
        "key": "Type",
        "t": REG_DWORD,
        "value": struct.pack("<I", APP_TYPE_BOOTAPP),
    })

    set_binary(h, ubuntu, ELEM_DEVICE, device_data)
    set_string(h, ubuntu, ELEM_PATH, GRUB_PATH)
    set_string(h, ubuntu, ELEM_DESCRIPTION, DESCRIPTION)
    set_string(h, ubuntu, ELEM_LOCALE, "en-us")

    guid = object_guid(h, ubuntu)
    order = get_string_list(h, bootmgr, ELEM_DISPLAY_ORDER)
    order = [item for item in order if item not in removed and item != guid]
    order.append(guid)
    set_multi_string(h, bootmgr, ELEM_DISPLAY_ORDER, order)
    set_binary(h, bootmgr, ELEM_TIMEOUT, struct.pack("<Q", args.timeout))
    # Without DisplayBootMenu the 1-second timeout is never shown and the
    # Ubuntu entry is unreachable from the console.
    set_binary(h, bootmgr, ELEM_DISPLAY_BOOT_MENU, b"\x01")

    h.commit(None)

    # Reopen and verify; a commit that silently failed must not look healthy.
    check = hivex.Hivex(args.bcd)
    objects = check.node_get_child(check.root(), "Objects")
    bootmgr = find_bootmgr(check, objects)
    matches = []
    for obj in check.node_children(objects):
        if get_string(check, obj, ELEM_PATH) == GRUB_PATH:
            matches.append(obj)
    if len(matches) != 1:
        raise SystemExit(f"expected one Ubuntu entry after write, found {len(matches)}")
    ubuntu = matches[0]
    ver = {
        "guid": object_guid(check, ubuntu),
        "path": get_string(check, ubuntu, ELEM_PATH),
        "description": get_string(check, ubuntu, ELEM_DESCRIPTION),
        "device": get_element(check, ubuntu, ELEM_DEVICE)[1].hex(),
        "order": get_string_list(check, bootmgr, ELEM_DISPLAY_ORDER),
        "timeout": int.from_bytes(get_element(check, bootmgr, ELEM_TIMEOUT)[1], "little"),
        "displaymenu": get_element(check, bootmgr, ELEM_DISPLAY_BOOT_MENU),
    }
    if ver["device"] != device_data.hex():
        raise SystemExit("the Ubuntu device element does not match the boot manager")
    if ver["guid"] not in ver["order"]:
        raise SystemExit("the Ubuntu entry is missing from the display order")
    if not ver["displaymenu"] or ver["displaymenu"][1] != b"\x01":
        raise SystemExit("DisplayBootMenu is not enabled")

    print(f"ubuntu entry: {ver['guid']}")
    print(f"  path:        {ver['path']}")
    print(f"  description: {ver['description']}")
    print(f"  device:      ESP (copied from the Windows Boot Manager)")
    print(f"  displayorder:{' '.join(ver['order'])}")
    print(f"  timeout:     {ver['timeout']}s (menu shown)")
    if removed:
        print(f"removed duplicate entries: {' '.join(removed)}")
    print(f"OK: {args.bcd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
