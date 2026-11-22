#!/usr/bin/env python3
"""Extract the plain arm64 kernel from a Ubuntu UKI (PE/COFF) image.

Ubuntu 24.04 and later install ``/boot/vmlinuz-<version>`` as a Unified
Kernel Image on arm64.  GRUB's ``linux`` command treats that PE image as an
arm64 kernel and jumps to its entry point, which is stubble, not the kernel
EFI stub.  Stubble then looks for a command line.  When GRUB itself was
started from the EFI shell, stubble's shell branch finds no arguments and
uses the UKI's built-in ``.cmdline`` section, which Ubuntu leaves empty:

    efi-log.c:34@efi_assert: stubble: Assertion
    'description || pcrindex == UINT32_MAX' failed at
    measure.c:246@tpm_log_ipl_event, halting.

Extracting the ``.linux`` section gives the same arm64 ``Image`` that a
distribution with a plain vmlinuz would ship.  GRUB loads it through the
normal arm64 boot protocol and stubble is not involved, so booting from the
EFI shell, from a firmware fallback, or from BCD/NVRAM all take the same
path.  Secure Boot is off in this project, so the unmeasured kernel is
acceptable; see docs/DUALBOOT.md.

Usage:
    extract_uki_kernel.py /boot/vmlinuz-6.8.0-31-generic [OUTPUT]

The default OUTPUT is INPUT + ".raw".  A non-UKI input (no .linux section)
is left alone and the script exits 0 without creating OUTPUT.  The caller
should keep using the original kernel in that case.
"""
from __future__ import annotations

import os
import struct
import sys

PE_MACHINE_ARM64 = 0xAA64
MAX_KERNEL_SIZE = 256 * 1024 * 1024


def die(message: str) -> None:
    print(f"extract-uki-kernel: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_at(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    data = f.read(size)
    if len(data) != size:
        raise EOFError
    return data


def pe_sections(path: str) -> list[tuple[str, int, int, int, int]]:
    """Return (name, virtual_size, virtual_address, raw_size, raw_offset)."""
    with open(path, "rb") as f:
        try:
            if read_at(f, 0, 2) != b"MZ":
                return []
            (pe_offset,) = struct.unpack("<I", read_at(f, 0x3C, 4))
            if read_at(f, pe_offset, 4) != b"PE\0\0":
                return []
            coff = read_at(f, pe_offset + 4, 20)
        except EOFError:
            return []
        machine, nsections = struct.unpack_from("<HH", coff, 0)
        (opt_size,) = struct.unpack_from("<H", coff, 16)
        if machine != PE_MACHINE_ARM64:
            return []
        table = pe_offset + 4 + 20 + opt_size
        sections = []
        try:
            for index in range(min(nsections, 96)):
                header = read_at(f, table + index * 40, 40)
                name = header[:8].split(b"\0", 1)[0].decode("ascii", "replace")
                vsize, vaddr, rawsize, rawoff = struct.unpack_from(
                    "<IIII", header, 8)
                sections.append((name, vsize, vaddr, rawsize, rawoff))
        except EOFError:
            return []
        return sections


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source = sys.argv[1]
    output = sys.argv[2] if len(sys.argv) == 3 else source + ".raw"

    try:
        sections = pe_sections(source)
    except OSError as error:
        die(f"cannot read {source}: {error}")
    if not sections:
        print(f"plain kernel (no PE/UKI sections): {source}")
        return 0

    linux = next((item for item in sections if item[0] == ".linux"), None)
    if not linux:
        print(f"PE image without a .linux section; keeping it as-is: {source}")
        return 0

    _, _vsize, _vaddr, rawsize, rawoff = linux
    if rawsize <= 0 or rawsize > MAX_KERNEL_SIZE:
        die(f"unexpected .linux size {rawsize} in {source}")

    if (os.path.isfile(output)
            and os.path.getsize(output) == rawsize
            and os.path.getmtime(output) >= os.path.getmtime(source)):
        print(f"raw kernel is current: {output}")
        return 0

    tmp = output + ".tmp"
    try:
        with open(source, "rb") as src, open(tmp, "wb") as dst:
            src.seek(rawoff)
            remaining = rawsize
            while remaining:
                chunk = src.read(min(remaining, 1 << 20))
                if not chunk:
                    die(f"truncated .linux section in {source}")
                dst.write(chunk)
                remaining -= len(chunk)
        os.chmod(tmp, 0o600)
        os.replace(tmp, output)
    except OSError as error:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"cannot write {output}: {error}")

    print(f"extracted .linux from {source}")
    print(f"  raw kernel: {output} ({rawsize} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
