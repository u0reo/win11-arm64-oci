#!/usr/bin/env python3
"""Patch Windows ARM64 bootmgfw.efi to avoid EfiAllocateAddress at 0x102000.

The OCI A1 firmware rejects the boot manager's request to allocate the fixed
low page 0x102000, producing "ConvertPages: failed to find range".  Changing
the allocation type from EfiAllocateAddress (2) to EfiAllocateAnyPages (1)
makes the same call succeed.  The requested address is written to the stack
but never read afterwards, so the allocation target does not matter.

This scanner is build-independent: it finds the five-instruction sequence

    add  x3, sp, #0x70
    mov  x2, #1
    mov  w1, #2
    mov  w0, #2          <-- patch to #1
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
MOV_W0_2 = 0x52800040
LDR_X8_28 = 0xF9401508
MOV_W0_1 = 0x52800020


def find_site(data: bytes, pe: pefile.PE) -> tuple[int, int, int]:
    """Return (file_offset, rva, section_va) for the target mov w0,#2."""
    hits = []
    for s in pe.sections:
        if not (s.Characteristics & 0x20000000):  # IMAGE_SCN_MEM_EXECUTE
            continue
        blob = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]
        for i in range(0, len(blob) - 20, 4):
            words = struct.unpack_from("<5I", blob, i)
            if words == (ADD_X3_SP_70, MOV_X2_1, MOV_W1_2, MOV_W0_2, LDR_X8_28):
                hits.append((s.PointerToRawData + i + 12, s.VirtualAddress + i + 12, s.VirtualAddress))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one bootmgfw site, found {len(hits)}: {hits}")
    return hits[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    data = bytearray(open(a.src, "rb").read())
    pe = pefile.PE(a.src, fast_load=True)
    off, rva, _ = find_site(data, pe)
    cur = struct.unpack_from("<I", data, off)[0]
    if cur != MOV_W0_2:
        raise SystemExit(f"unexpected instruction at {off:#x}: {cur:#010x}")
    struct.pack_into("<I", data, off, MOV_W0_1)

    def dis(w: int) -> str:
        # Only the two mov immediates matter here; keeping capstone out of
        # the dependency list lets the patch run on a stock live system.
        if w == MOV_W0_2:
            return "mov w0, #2"
        if w == MOV_W0_1:
            return "mov w0, #1"
        return "?"

    print(f"file={a.src}")
    print(f"imagebase={pe.OPTIONAL_HEADER.ImageBase:#x}")
    print(f"site: file_offset={off:#x} rva={rva:#x}")
    print(f"  {cur:#010x}  {dis(cur)}  ->  {MOV_W0_1:#010x}  {dis(MOV_W0_1)}")
    if a.dry_run:
        print("dry-run: not writing")
        return 0
    dst = a.dst or a.src
    open(dst, "wb").write(bytes(data))
    orig = open(a.src, "rb").read()
    new = open(dst, "rb").read()
    diff = [i for i in range(len(orig)) if orig[i] != new[i]]
    if not diff or set(diff) - set(range(off, off + 4)):
        raise SystemExit(f"unexpected diff: {diff[:10]}")
    print(f"changed_bytes={diff}")
    print(f"sha256={hashlib.sha256(new).hexdigest()}")
    print(f"wrote={dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
