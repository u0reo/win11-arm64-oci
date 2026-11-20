#!/usr/bin/env python3
"""Patch Windows ARM64 bootmgfw.efi to avoid EfiAllocateAddress at 0x102000.

The OCI A1 firmware rejects the boot manager's request to allocate the fixed
low page 0x102000, producing "ConvertPages: failed to find range".  The
requested address is written to the stack but never read afterwards, so the
allocation target does not matter; changing the allocation type is enough.

EFI_ALLOCATE_TYPE values (EDK2 UefiSpec.h) are:

    0  AllocateAnyPages
    1  AllocateMaxAddress   (allocate below the requested address)
    2  AllocateAddress      (stock; what bootmgfw uses)
    3  AllocateLast         (reserved)

The historical workaround changed #2 to #1; older notes call this
"AnyPages", which is a misnomer -- #1 is MaxAddress.  All four immediates are
selectable with --mode so the right value can be tested on a given firmware.

This scanner is build-independent: it finds the five-instruction sequence

    add  x3, sp, #0x70
    mov  x2, #1
    mov  w1, #2
    mov  w0, #2          <-- patch target
    ldr  x8, [x8, #0x28]  ; BS->AllocatePages

and changes only the mov w0 immediate.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys

import pefile

ADD_X3_SP_70 = 0x9101C3E3
MOV_X2_1 = 0xD2800022
MOV_W1_2 = 0x52800041
MOV_W0_0 = 0x52800000  # 0 = EfiAllocateAnyPages
MOV_W0_1 = 0x52800020  # 1 = EfiAllocateMaxAddress
MOV_W0_2 = 0x52800040  # 2 = EfiAllocateAddress (stock)
MOV_W0_3 = 0x52800060  # 3 = EfiAllocateLast
LDR_X8_28 = 0xF9401508

ALLOC_IMMEDIATES = {
    "max": MOV_W0_1,      # historical default: AllocateMaxAddress
    "any": MOV_W0_0,      # AllocateAnyPages
    "address": MOV_W0_2,  # stock
    "last": MOV_W0_3,     # reserved
}


def find_site(data: bytes, pe: pefile.PE) -> tuple[int, int, int, int]:
    """Return (file_offset, rva, section_va, current_alloc_type).

    The immediate is 2 (EfiAllocateAddress) in the stock boot manager and
    1 (EfiAllocateAnyPages) after patching.  Accept both so a second run
    verifies instead of failing.
    """
    hits = []
    accepted = (MOV_W0_0, MOV_W0_1, MOV_W0_2, MOV_W0_3)
    for s in pe.sections:
        if not (s.Characteristics & 0x20000000):  # IMAGE_SCN_MEM_EXECUTE
            continue
        blob = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]
        for i in range(0, len(blob) - 20, 4):
            words = struct.unpack_from("<5I", blob, i)
            if words[:3] == (ADD_X3_SP_70, MOV_X2_1, MOV_W1_2) and \
                    words[3] in accepted and \
                    words[4] == LDR_X8_28:
                hits.append((
                    s.PointerToRawData + i + 12,
                    s.VirtualAddress + i + 12,
                    s.VirtualAddress,
                    words[3],
                ))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one bootmgfw site, found {len(hits)}: {hits}")
    return hits[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--require-patched", action="store_true",
                    help="fail unless the site already uses the chosen mode")
    ap.add_argument("--mode", choices=sorted(ALLOC_IMMEDIATES),
                    default="max",
                    help="EFI_ALLOCATE_TYPE to write (default: max = #1)")
    a = ap.parse_args()

    target = ALLOC_IMMEDIATES[a.mode]
    data = bytearray(open(a.src, "rb").read())
    pe = pefile.PE(a.src, fast_load=True)
    off, rva, _, cur = find_site(data, pe)
    if cur not in (MOV_W0_0, MOV_W0_1, MOV_W0_2, MOV_W0_3):
        raise SystemExit(f"unexpected instruction at {off:#x}: {cur:#010x}")
    already = cur == target
    if not already:
        struct.pack_into("<I", data, off, target)

    def dis(w: int) -> str:
        # Only the three mov immediates matter here; keeping capstone out of
        # the dependency list lets the patch run on a stock live system.
        return {
            MOV_W0_0: "mov w0, #0 (AllocateAnyPages)",
            MOV_W0_1: "mov w0, #1 (AllocateMaxAddress)",
            MOV_W0_2: "mov w0, #2 (AllocateAddress)",
            MOV_W0_3: "mov w0, #3 (AllocateLast)",
        }.get(w, "?")

    print(f"file={a.src}")
    print(f"imagebase={pe.OPTIONAL_HEADER.ImageBase:#x}")
    print(f"site: file_offset={off:#x} rva={rva:#x}")
    print(f"  {cur:#010x}  {dis(cur)}  ->  {target:#010x}  {dis(target)}")
    if a.require_patched and not already:
        print("state=stock")
        return 3
    if a.dry_run:
        print(f"state={'patched' if already else 'stock'}")
        print("dry-run: not writing")
        return 0
    if already and not a.dst:
        print("state=patched")
        print("already patched; nothing to write")
        return 0

    dst = a.dst or a.src
    open(dst, "wb").write(bytes(data))
    new = open(dst, "rb").read()
    if already:
        print("state=patched")
        print("already patched; copied without changes")
    else:
        orig = open(a.src, "rb").read()
        diff = [i for i in range(len(orig)) if orig[i] != new[i]]
        if not diff or set(diff) - set(range(off, off + 4)):
            raise SystemExit(f"unexpected diff: {diff[:10]}")
        print(f"changed_bytes={diff}")
        print("state=patched")
    print(f"sha256={hashlib.sha256(new).hexdigest()}")
    print(f"wrote={dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
