#!/usr/bin/env python3
"""Remove Ubuntu boot applications from a Windows Boot Manager BCD hive.

ARM64 Windows Boot Manager cannot start an EFI application through a bootapp
entry; selecting one makes the firmware stop before Windows paints a screen.
GRUB is the first loader and starts Ubuntu instead, so the Windows Boot
Manager must not offer an Ubuntu entry any more.

This script is idempotent.  It removes every object whose description is
"Ubuntu (recovery)" or whose path is under \\EFI\\ubuntu, deletes references
to those objects from every display order, repairs the Windows Boot Manager's
default entry, and verifies the result.

Windows also mirrors firmware boot options into the BCD (under
``{fwbootmgr}``).  Deleting an object without deleting its reference there
would leave a dangling GUID, so the reference cleanup below is intentionally
not limited to the Windows Boot Manager object.

Usage:
    bcd_remove_ubuntu.py EFI/Microsoft/Boot/BCD

The BCD must be writable and must not be in use.  Call it after QEMU has
stopped and while the ESP is mounted read-write.
"""
from __future__ import annotations

import argparse
import sys

import hivex

BOOTMGR_GUID = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
WINDOWS_LOADER_SUFFIX = r"\windows\system32\winload.efi"
UBUNTU_DESCRIPTION = "Ubuntu (recovery)"

ELEM_PATH = "12000002"
ELEM_DESCRIPTION = "12000004"
ELEM_DEFAULT = "23000003"
ELEM_DISPLAY_ORDER = "24000001"

REG_SZ = 1
REG_MULTI_SZ = 7


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
    if vtype not in (REG_SZ, REG_MULTI_SZ):
        return ""
    return data.decode("utf-16le", "replace").rstrip("\0")


def get_string_list(h: hivex.Hivex, obj: int, name: str) -> list[str]:
    got = get_element(h, obj, name)
    if got is None:
        return []
    vtype, data = got
    if vtype not in (REG_SZ, REG_MULTI_SZ):
        return []
    return [item for item in data.decode("utf-16le", "replace").split("\0")
            if item]


def set_string(h: hivex.Hivex, obj: int, name: str, value: str) -> None:
    elements = h.node_get_child(obj, "Elements")
    if not elements:
        elements = h.node_add_child(obj, "Elements")
    element = h.node_get_child(elements, name)
    if not element:
        element = h.node_add_child(elements, name)
    h.node_set_value(element, {
        "key": "Element",
        "t": REG_SZ,
        "value": value.encode("utf-16le") + b"\0\0",
    })


def set_multi_string(h: hivex.Hivex, obj: int, name: str,
                     values: list[str]) -> None:
    elements = h.node_get_child(obj, "Elements")
    if not elements:
        elements = h.node_add_child(obj, "Elements")
    element = h.node_get_child(elements, name)
    if not element:
        element = h.node_add_child(elements, name)
    h.node_set_value(element, {
        "key": "Element",
        "t": REG_MULTI_SZ,
        "value": ("\0".join(values) + "\0\0").encode("utf-16le"),
    })


def find_bootmgr(h: hivex.Hivex, objects: int) -> int:
    for obj in h.node_children(objects):
        if get_string(h, obj, ELEM_DESCRIPTION) == "Windows Boot Manager":
            return obj
    node = h.node_get_child(objects, BOOTMGR_GUID)
    if node:
        return node
    raise SystemExit("no Windows Boot Manager object in the BCD")


def is_ubuntu(h: hivex.Hivex, obj: int) -> bool:
    if get_string(h, obj, ELEM_DESCRIPTION) == UBUNTU_DESCRIPTION:
        return True
    path = get_string(h, obj, ELEM_PATH).lower()
    return path.startswith("\\efi\\ubuntu\\")


def object_guids(h: hivex.Hivex, objects: int) -> set[str]:
    return {h.node_name(obj) for obj in h.node_children(objects)
            if h.node_name(obj).startswith("{")}


def clean_references(h: hivex.Hivex, objects: int) -> None:
    """Drop references to missing objects from every display order/default.

    Windows keeps firmware boot options in ``{fwbootmgr}``.  Removing an
    Ubuntu object from ``Objects`` but leaving its GUID in that display order
    is invalid BCD, so clean every object, not just the Windows Boot Manager.
    """
    existing = object_guids(h, objects)
    for obj in list(h.node_children(objects)):
        guid = h.node_name(obj)
        if not guid.startswith("{"):
            continue

        order = get_string_list(h, obj, ELEM_DISPLAY_ORDER)
        seen: set[str] = set()
        new_order = []
        for item in order:
            if item not in existing or item in seen:
                continue
            seen.add(item)
            new_order.append(item)
        if new_order != order:
            set_multi_string(h, obj, ELEM_DISPLAY_ORDER, new_order)

        default = get_string(h, obj, ELEM_DEFAULT)
        if default and default not in existing:
            set_string(h, obj, ELEM_DEFAULT,
                       new_order[0] if new_order else "")


def find_windows_loader(h: hivex.Hivex, objects: int) -> str:
    for obj in h.node_children(objects):
        path = get_string(h, obj, ELEM_PATH).lower()
        if path.endswith(WINDOWS_LOADER_SUFFIX):
            return h.node_name(obj)
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bcd")
    args = parser.parse_args()

    h = hivex.Hivex(args.bcd, write=True)
    objects = h.node_get_child(h.root(), "Objects")
    if not objects:
        raise SystemExit("BCD has no Objects key")
    bootmgr = find_bootmgr(h, objects)

    removed: list[str] = []
    for obj in list(h.node_children(objects)):
        guid = h.node_name(obj)
        if not guid.startswith("{"):
            continue
        if is_ubuntu(h, obj):
            removed.append(guid)
            h.node_delete_child(obj)

    # Drop the removed GUIDs and any reference that was already dangling.
    clean_references(h, objects)

    order = get_string_list(h, bootmgr, ELEM_DISPLAY_ORDER)
    seen: set[str] = set()
    order = [item for item in order
             if not (item in seen or seen.add(item))]

    default = get_string(h, bootmgr, ELEM_DEFAULT)
    if default not in order:
        windows_loader = find_windows_loader(h, objects)
        if windows_loader and windows_loader in order:
            default = windows_loader
        elif order:
            default = order[0]
        else:
            default = ""

    if default:
        set_string(h, bootmgr, ELEM_DEFAULT, default)
    set_multi_string(h, bootmgr, ELEM_DISPLAY_ORDER, order)
    h.commit(None)

    # Reopen and verify.  A commit that silently failed must not look healthy.
    check = hivex.Hivex(args.bcd)
    objects = check.node_get_child(check.root(), "Objects")
    bootmgr = find_bootmgr(check, objects)
    remaining = [check.node_name(obj) for obj in check.node_children(objects)
                 if check.node_name(obj).startswith("{")
                 and is_ubuntu(check, obj)]
    if remaining:
        raise SystemExit("Ubuntu BCD entries remain: " + " ".join(remaining))

    existing = object_guids(check, objects)
    for obj in check.node_children(objects):
        guid = check.node_name(obj)
        if not guid.startswith("{"):
            continue
        dangling = [item for item in
                    get_string_list(check, obj, ELEM_DISPLAY_ORDER)
                    if item not in existing]
        if dangling:
            raise SystemExit(
                f"{guid} has dangling displayorder entries: "
                + " ".join(dangling))
        default = get_string(check, obj, ELEM_DEFAULT)
        if default and default not in existing:
            raise SystemExit(f"{guid} has a dangling default: {default}")

    checked_order = get_string_list(check, bootmgr, ELEM_DISPLAY_ORDER)
    checked_default = get_string(check, bootmgr, ELEM_DEFAULT)
    if checked_default and checked_default not in checked_order:
        raise SystemExit("BCD default is not in the display order")
    if removed:
        print("removed Ubuntu BCD entries: " + " ".join(removed))
    else:
        print("no Ubuntu BCD entries")
    print("default:      " + (checked_default or "<none>"))
    print("displayorder: " + " ".join(checked_order))
    print(f"OK: {args.bcd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
