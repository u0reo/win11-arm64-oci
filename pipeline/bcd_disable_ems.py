#!/usr/bin/env python3
"""Remove explicit EMS and boot-debug overrides from a Windows BCD hive.

The build used to enable EMS/SAC from ``oem/boot.ps1`` and to disable the
graphics console while chasing an OCI A1 boot hang.  Both left BCD elements
behind that are wrong for normal operation:

* ARM64 Windows does not implement EMS/SAC, but ``bcdedit /ems`` and
  ``bcdedit /emssettings`` still write BCD elements and return success.  On
  OCI A1 an explicit ``emsport=1`` points at the x86 COM1 I/O port 0x3F8,
  while the platform serial port is a PL011 at MMIO 0x09000000.  WORKLOG
  22.21-22.22 shows that this makes bootmgr/winload hang silently with no
  video output and no Windows event log records.
* ``graphicsmodedisabled`` / ``bootuxdisabled`` suppress the boot menu and
  the Windows logo.  They were added for a diagnostic boot and make a normal
  boot look like a silent hang on VNC.  ``nointegritychecks``, ``bootlog``
  and ``sos`` are also debug leftovers that change the boot path.

Removing the elements restores the stock behaviour: firmware SPCR is used
when the platform provides it, and the normal graphical boot menu/logo are
shown.

The script is idempotent and removes the same elements from every BCD object:

    15000022  EmsPort
    15000023  EmsBaudRate
    16000020  bootems
    25000006  bootmgr bootems (alternate id)
    26000000  loader EMS enabled
    26000001  loader EmsPort
    26000002  loader EmsBaudRate
    260000b0  kernel EmsEnable
    16000046  graphicsmodedisabled
    1600006c  bootuxdisabled
    16000048  DisableIntegrityChecks (nointegritychecks)
    26000090  bootlog
    26000091  sos

Usage:
    bcd_disable_ems.py EFI/Microsoft/Boot/BCD

The BCD must be writable and must not be in use.  finish_disk.sh calls this
after bcd_remove_ubuntu.py while the ESP is mounted read-write.
"""
from __future__ import annotations

import argparse
import sys

import hivex

REMOVE_ELEMENTS = {
    # Explicit EMS/SAC settings.
    "15000022",  # EmsPort
    "15000023",  # EmsBaudRate
    "16000020",  # bootems
    "25000006",  # bootmgr bootems (alternate id)
    "26000000",  # loader EMS enabled
    "26000001",  # loader EmsPort
    "26000002",  # loader EmsBaudRate
    "260000b0",  # kernel EmsEnable
    # Diagnostic display / integrity overrides.
    "16000046",  # graphicsmodedisabled
    "1600006c",  # bootuxdisabled
    "16000048",  # DisableIntegrityChecks (nointegritychecks)
    "26000090",  # bootlog
    "26000091",  # sos
}


def remaining_elements(h: hivex.Hivex) -> list[str]:
    """Return 'guid/key' for every unwanted element still present."""
    objects = h.node_get_child(h.root(), "Objects")
    found: list[str] = []
    if not objects:
        return found
    for obj in h.node_children(objects):
        elements = h.node_get_child(obj, "Elements")
        if not elements:
            continue
        for element in h.node_children(elements):
            key = h.node_name(element).lower()
            if key in REMOVE_ELEMENTS:
                found.append(f"{h.node_name(obj)}/{key}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bcd")
    args = parser.parse_args()

    h = hivex.Hivex(args.bcd, write=True)
    objects = h.node_get_child(h.root(), "Objects")
    if not objects:
        raise SystemExit("BCD has no Objects key")

    removed: list[str] = []
    for obj in h.node_children(objects):
        elements = h.node_get_child(obj, "Elements")
        if not elements:
            continue
        for element in list(h.node_children(elements)):
            key = h.node_name(element).lower()
            if key in REMOVE_ELEMENTS:
                removed.append(f"{h.node_name(obj)}/{key}")
                # hivex takes the node, not its name (WORKLOG 22.21).
                h.node_delete_child(element)
    if removed:
        h.commit(None)

    # Reopen and verify a failed commit does not look healthy.
    check = hivex.Hivex(args.bcd)
    left = remaining_elements(check)
    if left:
        raise SystemExit("unwanted BCD elements remain: " + " ".join(left))

    if removed:
        print("removed BCD elements:")
        for item in removed:
            print("  " + item)
    else:
        print("no explicit EMS/debug BCD elements")
    print(f"OK: {args.bcd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
