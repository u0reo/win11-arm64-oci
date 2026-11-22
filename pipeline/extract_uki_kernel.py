#!/usr/bin/env python3
"""Extract a plain arm64 kernel Image from a Ubuntu UKI (PE/COFF) file.

Ubuntu 24.04 and later install ``/boot/vmlinuz-<version>`` as a Unified
Kernel Image on arm64.  The ``.linux`` section of that UKI is an EFI zboot
image: a PE/COFF application whose payload is a zstd (sometimes gzip)
compressed arm64 ``Image``.  GRUB's ``linux`` command cannot start either
the UKI (its entry point is stubble) or the zboot PE (it has no
``ARM\\x64`` boot header), so this script writes the decompressed Image to
``<input>.raw``.

Why this matters:

* stubble, started from the EFI shell, treats the shell arguments as the
  command line.  With no arguments it reads the UKI's empty ``.cmdline``,
  gets NULL, and asserts in ``measure.c:246@tpm_log_ipl_event``.
* The decompressed arm64 Image follows the normal arm64 boot protocol.
  GRUB loads it directly, so NVRAM, firmware fallback and EFI shell boots
  all take the same path.  Secure Boot is off in this project, so the
  unmeasured kernel is acceptable; see docs/DUALBOOT.md.

Usage:
    extract_uki_kernel.py /boot/vmlinuz-6.8.0-31-generic [OUTPUT]

The default OUTPUT is INPUT + ".raw".  A non-UKI input (no ``.linux``
section) is left alone and the script exits 0 without creating OUTPUT, so
the caller can keep using the original kernel.  A ``.linux`` section that
is already a plain arm64 Image is copied as-is.

zstd decompression uses libzstd through ctypes.  If the library is not
available, the ``zstd`` command line tool is used instead.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import gzip
import os
import struct
import subprocess
import sys

PE_MACHINE_ARM64 = 0xAA64
ARM64_MAGIC = b"ARM\x64"
MAGIC_OFFSET = 0x38
ZBOOT_MAGIC_OFFSET = 4
ZBOOT_PAYLOAD_OFFSET = 0x08
ZBOOT_PAYLOAD_SIZE = 0x0C
ZBOOT_COMPRESSION = 0x18
ZBOOT_COMPRESSION_SIZE = 0x20
MAX_COMPRESSED_SIZE = 256 * 1024 * 1024
MAX_IMAGE_SIZE = 512 * 1024 * 1024
CHUNK = 1 << 20


def die(message: str) -> None:
    print(f"extract-uki-kernel: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_at(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    data = f.read(size)
    if len(data) != size:
        raise EOFError
    return data


class Section:
    def __init__(self, name: str, raw_size: int, raw_offset: int) -> None:
        self.name = name
        self.raw_size = raw_size
        self.raw_offset = raw_offset


def pe_sections(path: str) -> list[Section]:
    """Return the PE sections of an ARM64 image, or [] if it is not one."""
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
                _vsize, _vaddr, rawsize, rawoff = struct.unpack_from(
                    "<IIII", header, 8)
                sections.append(Section(name, rawsize, rawoff))
        except EOFError:
            return []
        return sections


class InBuffer(ctypes.Structure):
    _fields_ = [("src", ctypes.c_void_p),
                ("size", ctypes.c_size_t),
                ("pos", ctypes.c_size_t)]


class OutBuffer(ctypes.Structure):
    _fields_ = [("dst", ctypes.c_void_p),
                ("size", ctypes.c_size_t),
                ("pos", ctypes.c_size_t)]


class ZstdUnavailable(Exception):
    pass


def load_zstd():
    name = ctypes.util.find_library("zstd")
    if not name:
        raise ZstdUnavailable
    try:
        lib = ctypes.CDLL(name)
    except OSError:
        raise ZstdUnavailable from None
    lib.ZSTD_createDStream.restype = ctypes.c_void_p
    lib.ZSTD_freeDStream.argtypes = [ctypes.c_void_p]
    lib.ZSTD_initDStream.argtypes = [ctypes.c_void_p]
    lib.ZSTD_initDStream.restype = ctypes.c_size_t
    lib.ZSTD_decompressStream.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(OutBuffer),
        ctypes.POINTER(InBuffer)]
    lib.ZSTD_decompressStream.restype = ctypes.c_size_t
    lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
    lib.ZSTD_isError.restype = ctypes.c_uint
    lib.ZSTD_getErrorName.argtypes = [ctypes.c_size_t]
    lib.ZSTD_getErrorName.restype = ctypes.c_char_p
    return lib


def zstd_decompress(payload: bytes, write) -> int:
    try:
        lib = load_zstd()
    except ZstdUnavailable:
        return zstd_decompress_cli(payload, write)

    source = ctypes.create_string_buffer(payload)
    inbuf = InBuffer(ctypes.cast(source, ctypes.c_void_p), len(payload), 0)
    stream = lib.ZSTD_createDStream()
    if not stream:
        die("libzstd could not allocate a decompression stream")
    outchunk = ctypes.create_string_buffer(CHUNK)
    total = 0
    try:
        result = lib.ZSTD_initDStream(stream)
        if lib.ZSTD_isError(result):
            die("libzstd init failed: " +
                lib.ZSTD_getErrorName(result).decode("ascii", "replace"))
        while True:
            outbuf = OutBuffer(ctypes.cast(outchunk, ctypes.c_void_p),
                               CHUNK, 0)
            result = lib.ZSTD_decompressStream(
                stream, ctypes.byref(outbuf), ctypes.byref(inbuf))
            if lib.ZSTD_isError(result):
                die("zstd decompression failed: " +
                    lib.ZSTD_getErrorName(result).decode("ascii", "replace"))
            if outbuf.pos:
                write(outchunk.raw[:outbuf.pos])
                total += outbuf.pos
                if total > MAX_IMAGE_SIZE:
                    die("decompressed kernel exceeds the size limit")
            if result == 0 and inbuf.pos == inbuf.size:
                break
            if inbuf.pos == inbuf.size and outbuf.pos == 0:
                die("truncated zstd payload")
    finally:
        lib.ZSTD_freeDStream(stream)
    return total


def zstd_decompress_cli(payload: bytes, write) -> int:
    try:
        proc = subprocess.run(
            ["zstd", "-d", "-c", "-q"], input=payload,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        die("neither libzstd nor the zstd command is available")
    if proc.returncode != 0:
        die("zstd -d failed: " +
            proc.stderr.decode("utf-8", "replace").strip())
    if len(proc.stdout) > MAX_IMAGE_SIZE:
        die("decompressed kernel exceeds the size limit")
    write(proc.stdout)
    return len(proc.stdout)


def write_image(source: str, section: Section, output: str,
                zboot: bool) -> None:
    tmp = output + ".tmp"
    total = 0

    with open(source, "rb") as src:
        if not zboot:
            size = section.raw_size
            if size <= 0 or size > MAX_IMAGE_SIZE:
                die(f"unexpected .linux size {size} in {source}")
            with open(tmp, "wb") as dst:
                src.seek(section.raw_offset)
                remaining = size
                while remaining:
                    chunk = src.read(min(remaining, CHUNK))
                    if not chunk:
                        die(f"truncated .linux section in {source}")
                    dst.write(chunk)
                    remaining -= len(chunk)
            total = size
        else:
            src.seek(section.raw_offset)
            header = src.read(0x40)
            if len(header) != 0x40:
                die(f"truncated zboot header in {source}")
            payload_offset, payload_size = struct.unpack_from(
                "<II", header, ZBOOT_PAYLOAD_OFFSET)
            compression = header[
                ZBOOT_COMPRESSION:ZBOOT_COMPRESSION + ZBOOT_COMPRESSION_SIZE]
            compression = compression.split(b"\0", 1)[0].decode(
                "ascii", "replace")
            if payload_offset + payload_size > section.raw_size:
                die(f"zboot payload outside .linux in {source}")
            if payload_size > MAX_COMPRESSED_SIZE:
                die(f"zboot payload is too large ({payload_size} bytes)")
            src.seek(section.raw_offset + payload_offset)
            payload = src.read(payload_size)
            if len(payload) != payload_size:
                die(f"truncated zboot payload in {source}")

            with open(tmp, "wb") as dst:
                if compression == "zstd":
                    total = zstd_decompress(payload, dst.write)
                elif compression in ("gzip", "gz"):
                    try:
                        data = gzip.decompress(payload)
                    except OSError as error:
                        die(f"gzip decompression failed: {error}")
                    if len(data) > MAX_IMAGE_SIZE:
                        die("decompressed kernel exceeds the size limit")
                    dst.write(data)
                    total = len(data)
                else:
                    die(f"unsupported zboot compression {compression!r}")

    try:
        with open(tmp, "rb") as check:
            check.seek(MAGIC_OFFSET)
            magic = check.read(4)
    except OSError as error:
        die(f"cannot read back {tmp}: {error}")
    if magic != ARM64_MAGIC:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"no arm64 Image magic at 0x38 in the extracted kernel "
            f"({source})")

    try:
        os.chmod(tmp, 0o600)
        os.replace(tmp, output)
    except OSError as error:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"cannot write {output}: {error}")
    print(f"  raw kernel: {output} ({total} bytes)")


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

    linux = next((item for item in sections if item.name == ".linux"), None)
    if not linux:
        print(f"PE image without a .linux section; keeping it as-is: {source}")
        return 0

    # Reuse an up-to-date output.  A zboot payload has no decompressed size
    # in its header, so a mtime check is cheaper than decompressing again.
    if os.path.isfile(output):
        try:
            fresh = os.path.getmtime(output) >= os.path.getmtime(source)
            with open(output, "rb") as check:
                check.seek(MAGIC_OFFSET)
                magic = check.read(4)
        except OSError:
            fresh = False
            magic = b""
        if fresh and magic == ARM64_MAGIC:
            print(f"raw kernel is current: {output}")
            return 0

    with open(source, "rb") as f:
        header = read_at(f, linux.raw_offset, 0x40)
    zboot = (header[0:2] == b"MZ" and
             header[ZBOOT_MAGIC_OFFSET:ZBOOT_MAGIC_OFFSET + 4] == b"zimg")
    if zboot:
        print(f"EFI zboot in {source}")
        print(f"  .linux section: {linux.raw_size} bytes, "
              f"payload at {struct.unpack_from('<I', header, 8)[0]}")
    elif header[MAGIC_OFFSET:MAGIC_OFFSET + 4] != ARM64_MAGIC:
        print(f"error: .linux is not an arm64 Image or an EFI zboot: {source}",
              file=sys.stderr)
        return 1

    write_image(source, linux, output, zboot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
