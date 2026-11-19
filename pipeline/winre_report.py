#!/usr/bin/env python3
"""Report the Windows RE location stored in ReAgent.xml.

ReAgent.xml uses the partition start offset (in bytes) and the disk GUID,
not the partition number.  Passing the dedicated partition's offset lets
this script say whether Windows RE actually lives there.

Usage:
    winre_report.py ReAgent.xml [--offset BYTES] [--partition NUM]
"""

from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reagent_xml")
    parser.add_argument("--offset", type=int, default=0,
                        help="start offset of the dedicated RE partition")
    parser.add_argument("--partition", default="",
                        help="partition number for display")
    args = parser.parse_args()

    try:
        root = ET.parse(args.reagent_xml).getroot()
    except Exception as exc:  # missing file, not XML, ...
        print(f"ReAgent.xml: missing or unreadable ({exc})")
        return 0

    loc = root.find("WinreLocation")
    inst = root.find("InstallState")
    path = loc.get("path", "") if loc is not None else ""
    offset = 0
    if loc is not None:
        try:
            offset = int(loc.get("offset", "0") or 0)
        except ValueError:
            offset = 0
    state = inst.get("state", "?") if inst is not None else "?"

    print(f"ReAgent.xml: install_state={state} path={path or '?'} offset={offset}")
    where = f"p{args.partition}" if args.partition else "the dedicated partition"
    if args.offset:
        if offset == args.offset:
            print(f"Windows RE location: {where} (dedicated)")
        else:
            print(f"Windows RE location: NOT {where} "
                  f"(expected offset {args.offset})")
    elif offset:
        print("Windows RE location: Windows partition (C:), "
              "no dedicated partition")
    if state == "0":
        print("Windows RE is disabled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
