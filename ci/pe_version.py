#!/usr/bin/env python3
"""Read the version resource (``VS_VERSIONINFO``) of a Windows PE file with the stdlib only.

The files are UNTRUSTED (built by the upstream workflow): the reader never executes anything,
seeks inside the file, bounds every length and offset, and raises ``ValidationError`` on anything
unexpected.  It exists so the release gate can run on an Ubuntu runner (no PowerShell /
``FileVersionInfo``) and in an unprivileged job.

``read(path)`` returns ``{"fixed": (a, b, c, d), "file_version": str|None, "product_version": str|None}``:
``fixed`` is the numeric ``dwFileVersion`` of ``VS_FIXEDFILEINFO``; the strings are the
``StringFileInfo`` values (what ``FileVersionInfo.FileVersion`` shows on Windows).
"""
from __future__ import annotations

import os
import struct
import sys
from typing import Any, Dict, Optional, Tuple

import vpcommon as v

RT_VERSION = 16
MAX_SECTIONS = 96
MAX_RES_DEPTH_ENTRIES = 4096
MAX_VERSION_BLOCK = 64 * 1024
FIXED_SIG = 0xFEEF04BD


class _File:
    def __init__(self, path: str) -> None:
        self.fh = open(path, "rb")
        self.size = os.fstat(self.fh.fileno()).st_size

    def read(self, offset: int, length: int) -> bytes:
        if offset < 0 or length < 0 or length > 4 * 1024 * 1024 or offset + length > self.size:
            raise v.ValidationError("pe: read outside the file")
        self.fh.seek(offset)
        data = self.fh.read(length)
        if len(data) != length:
            raise v.ValidationError("pe: short read")
        return data

    def close(self) -> None:
        self.fh.close()


def _u16(b: bytes, o: int) -> int:
    return struct.unpack_from("<H", b, o)[0]


def _u32(b: bytes, o: int) -> int:
    return struct.unpack_from("<I", b, o)[0]


def _sections(f: _File, lfanew: int) -> Tuple[Any, int, int]:
    coff = f.read(lfanew + 4, 20)
    nsec = _u16(coff, 2)
    opt_size = _u16(coff, 16)
    if not (1 <= nsec <= MAX_SECTIONS) or not (96 <= opt_size <= 1024):
        raise v.ValidationError("pe: implausible header")
    opt = f.read(lfanew + 24, opt_size)
    magic = _u16(opt, 0)
    if magic == 0x10B:
        dd_off = 96
    elif magic == 0x20B:
        dd_off = 112
    else:
        raise v.ValidationError("pe: unknown optional header magic")
    if dd_off + 8 * 3 > opt_size:
        raise v.ValidationError("pe: no data directories")
    rsrc_rva, rsrc_size = struct.unpack_from("<II", opt, dd_off + 8 * 2)
    table = f.read(lfanew + 24 + opt_size, 40 * nsec)
    secs = []
    for i in range(nsec):
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", table, 40 * i + 8)
        secs.append((va, max(vsize, rawsize), rawptr, rawsize))
    return secs, rsrc_rva, rsrc_size


def _rva_to_off(secs, rva: int) -> int:
    for va, span, rawptr, rawsize in secs:
        if va <= rva < va + span:
            off = rawptr + (rva - va)
            if rva - va >= rawsize:
                raise v.ValidationError("pe: rva beyond raw section data")
            return off
    raise v.ValidationError("pe: rva not in any section")


def _dir_entries(f: _File, base: int, rel: int):
    head = f.read(base + rel, 16)
    nnamed, nid = _u16(head, 12), _u16(head, 14)
    total = nnamed + nid
    if total > MAX_RES_DEPTH_ENTRIES:
        raise v.ValidationError("pe: resource directory too large")
    raw = f.read(base + rel + 16, 8 * total)
    out = []
    for i in range(total):
        name, data = struct.unpack_from("<II", raw, 8 * i)
        out.append((name, data))
    return out


def _find_version_data(f: _File, secs, rsrc_rva: int, rsrc_size: int) -> bytes:
    if rsrc_rva == 0 or rsrc_size == 0:
        raise v.ValidationError("pe: no resource section")
    base = _rva_to_off(secs, rsrc_rva)
    entries = _dir_entries(f, base, 0)
    sub = None
    for name, data in entries:
        if name == RT_VERSION and data & 0x80000000:
            sub = data & 0x7FFFFFFF
            break
    if sub is None:
        raise v.ValidationError("pe: no RT_VERSION resource")
    ids = _dir_entries(f, base, sub)
    if not ids or not ids[0][1] & 0x80000000:
        raise v.ValidationError("pe: malformed version resource tree")
    langs = _dir_entries(f, base, ids[0][1] & 0x7FFFFFFF)
    if not langs or langs[0][1] & 0x80000000:
        raise v.ValidationError("pe: malformed version resource tree")
    entry = f.read(base + langs[0][1], 16)
    data_rva, size = struct.unpack_from("<II", entry, 0)
    if not (16 <= size <= MAX_VERSION_BLOCK):
        raise v.ValidationError("pe: implausible version block size")
    return f.read(_rva_to_off(secs, data_rva), size)


def _utf16_value(block: bytes, key: str) -> Optional[str]:
    """Value of ``StringFileInfo`` entry ``key`` (best effort, strict about bounds)."""
    needle = key.encode("utf-16-le") + b"\x00\x00"
    pos = block.find(needle)
    while pos != -1:
        start = pos - 6  # wLength, wValueLength, wType precede the key
        if start >= 0:
            wlen, wvallen = struct.unpack_from("<HH", block, start)
            val_off = start + ((6 + len(needle) + 3) & ~3)
            if wvallen > 0 and val_off + 2 * wvallen <= len(block) and wlen >= 6 + len(needle):
                raw = block[val_off:val_off + 2 * wvallen]
                text = raw.decode("utf-16-le", errors="replace").split("\x00", 1)[0]
                if 0 < len(text) <= 64 and all(32 <= ord(c) < 127 for c in text):
                    return text
        pos = block.find(needle, pos + 1)
    return None


def parse_version_block(block: bytes) -> Dict[str, Any]:
    idx = block.find(struct.pack("<I", FIXED_SIG), 0, 256)
    if idx < 0 or idx + 52 > len(block):
        raise v.ValidationError("pe: VS_FIXEDFILEINFO not found")
    ms, ls = struct.unpack_from("<II", block, idx + 8)
    fixed = (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)
    return {"fixed": fixed,
            "file_version": _utf16_value(block, "FileVersion"),
            "product_version": _utf16_value(block, "ProductVersion")}


def read(path: str) -> Dict[str, Any]:
    f = _File(path)
    try:
        if f.size < 512:
            raise v.ValidationError("pe: file too small")
        dos = f.read(0, 64)
        if dos[:2] != b"MZ":
            raise v.ValidationError("pe: not an MZ file")
        lfanew = _u32(dos, 0x3C)
        if not (64 <= lfanew <= min(f.size - 24, 1 << 20)):
            raise v.ValidationError("pe: bad e_lfanew")
        if f.read(lfanew, 4) != b"PE\x00\x00":
            raise v.ValidationError("pe: bad signature")
        secs, rsrc_rva, rsrc_size = _sections(f, lfanew)
        block = _find_version_data(f, secs, rsrc_rva, rsrc_size)
        return parse_version_block(block)
    except struct.error as exc:
        raise v.ValidationError("pe: malformed structure") from exc
    finally:
        f.close()


def dotted(fixed: Tuple[int, int, int, int]) -> str:
    return ".".join(str(p) for p in fixed)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        return v.fail("usage: pe_version.py <file.exe>", 2)
    try:
        info = read(argv[0])
    except (v.ValidationError, OSError) as exc:
        return v.fail(str(exc))
    print(f"fixed={dotted(info['fixed'])} file_version={info['file_version']} product_version={info['product_version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
