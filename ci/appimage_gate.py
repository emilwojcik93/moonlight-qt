#!/usr/bin/env python3
"""Mandatory release gate for the built Linux AppImage (CONTRACT v1.2, Linux amendment).

Upstream's reusable ``build-appimage.yml`` publishes ``Moonlight-<ci_version>-x86_64.AppImage`` in
the artifact ``Moonlight-LinuxAppImage-<ci_version>``.  The file is produced by the untrusted build
job, so the unprivileged ``package`` job inspects it before anything is staged or attested.  The
image is NEVER executed (no ``--appimage-extract``, no ``--version``); it is only parsed.

Gate (all must hold; ``ci_version`` = ``version_map.build_version(tag, n)``):

1. the file name is exactly ``Moonlight-<ci_version>-x86_64.AppImage`` and the file is a regular
   file (no symlink) with a size inside the sanity bounds;
2. ELF header: 64-bit little-endian, machine x86-64, and the AppImage type-2 magic ``AI\\x02`` at
   offset 8;
3. the squashfs payload starts where the ELF ends (``e_shoff + e_shentsize * e_shnum``), carries the
   ``hsqs`` magic, is squashfs 4.x and ends inside the file (at most 1 MiB of trailing bytes);
4. the payload is read with ``unsquashfs`` (preferred; explicit offset) or ``7z`` (7-Zip >= 24.01 is
   needed for zstd squashfs) and contains
   * ``com.moonlight_stream.Moonlight.desktop`` whose ``X-AppImage-Version`` equals ``ci_version``
     (written by linuxdeploy from ``$VERSION`` = ``$CI_VERSION``), and
   * ``usr/bin/moonlight``, an x86-64 ELF that holds the delimited string ``ci_version`` (the
     ``VERSION_STR`` define compiled in from ``$CI_VERSION``).  Other ``6.2.0-daily.<n>`` strings
     are recorded in the summary and fail the gate only when ``n`` is higher than the expected one.

The embedded binary version is the same string ``moonlight --version`` prints, which upstream's own
in-build check compares; reading it from the bytes gives the identical guarantee without running the
untrusted file.  The gate is a pipeline-consistency check (wrong artifact, stale cache, mislabelled
build), not a defence against a malicious build job: the same trust boundary as ``bundle_gate.py``.

The summary written to ``--out`` is plain JSON; ``manifest_gen.sanitize_linux_gate_summary``
re-validates it in the publish job and ``stage_assets.py`` re-binds the staged bytes to its sha256.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import threading
from typing import Any, Dict, List, Optional, Tuple

import version_map
import vpcommon as v

CI_VERSION_RE = re.compile(r"6\.2\.0-daily\.[1-9][0-9]{4}")
ANY_DAILY_RE = re.compile(r"6\.2\.0-daily\.[0-9]{1,6}")
MIN_BYTES = 16 * 1024 * 1024    # the real image is ~75 MB
MAX_BYTES = 400 * 1024 * 1024   # same ceiling as the Windows bundle
MAX_TRAILER = 1024 * 1024       # bytes allowed after the squashfs payload
MAX_DESKTOP_BYTES = 64 * 1024
MIN_BINARY_BYTES = 1024 * 1024
MAX_BINARY_BYTES = 512 * 1024 * 1024
MAX_LISTING_BYTES = 16 * 1024   # only the archive header block of ``7z l -slt`` is read
DEADLINE_SECONDS = 300          # wall-clock limit for one reader process (it is killed afterwards)
MAX_OTHER_VERSIONS = 16

DESKTOP_ENTRY = "com.moonlight_stream.Moonlight.desktop"
BINARY_ENTRY = "usr/bin/moonlight"
SQUASHFS_COMPRESSION = {1: "gzip", 2: "lzma", 3: "lzo", 4: "xz", 5: "lz4", 6: "zstd"}
ELF_MACHINE_X86_64 = 62
UNSQUASHFS_NAMES = ("unsquashfs",)
SEVEN_ZIP_NAMES = ("7zz", "7z", "7za", "7zr")
MEMBER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,60}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,60}){0,6}")
# A version-like string inside the binary: not glued to a longer token on the left (``v`` and
# ``Moonlight/`` prefixes are fine) and not continued on the right.
VERSION_STRING_RE = re.compile(rb"(?<![0-9A-Za-z_.\-])v?(6\.2\.0-daily\.([0-9]{1,6}))(?![0-9A-Za-z_\-])(?!\.[0-9])")


def image_name(ci_version: str) -> str:
    v.require(CI_VERSION_RE, ci_version, "ci_version")
    return f"Moonlight-{ci_version}-x86_64.AppImage"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_header(path: str) -> Dict[str, Any]:
    """Validate ELF + AppImage type-2 magic + squashfs superblock; never reads beyond 96 bytes + header."""
    if os.path.islink(path) or not os.path.isfile(path):
        raise v.ValidationError("AppImage is not a regular file")
    size = os.path.getsize(path)
    if not (MIN_BYTES <= size <= MAX_BYTES):
        raise v.ValidationError("unexpected AppImage size")
    with open(path, "rb") as fh:
        head = fh.read(64)
        if len(head) < 64 or head[:4] != b"\x7fELF":
            raise v.ValidationError("AppImage is not an ELF file")
        if head[4] != 2 or head[5] != 1:
            raise v.ValidationError("AppImage runtime is not a 64-bit little-endian ELF")
        if head[8:11] != b"AI\x02":
            raise v.ValidationError("AppImage type-2 magic missing at offset 8")
        (machine,) = struct.unpack_from("<H", head, 18)
        if machine != ELF_MACHINE_X86_64:
            raise v.ValidationError("AppImage runtime is not x86-64")
        (shoff,) = struct.unpack_from("<Q", head, 0x28)
        shentsize, shnum = struct.unpack_from("<HH", head, 0x3A)
        if shentsize != 64 or not (1 <= shnum <= 4096):
            raise v.ValidationError("unexpected ELF section table")
        offset = shoff + shentsize * shnum
        if not (64 <= offset <= size - 96):
            raise v.ValidationError("squashfs offset outside the file")
        fh.seek(offset)
        sb = fh.read(96)
    if len(sb) < 96 or sb[:4] != b"hsqs":
        raise v.ValidationError("no squashfs payload at the end of the ELF runtime")
    compression, = struct.unpack_from("<H", sb, 20)
    major, = struct.unpack_from("<H", sb, 28)
    bytes_used, = struct.unpack_from("<Q", sb, 40)
    if major != 4 or compression not in SQUASHFS_COMPRESSION:
        raise v.ValidationError("unsupported squashfs version or compression")
    end = offset + bytes_used
    if bytes_used < 4096 or end > size or size - end > MAX_TRAILER:
        raise v.ValidationError("squashfs payload does not fill the file")
    return {"size": size, "squashfs_offset": offset, "squashfs_bytes": bytes_used,
            "compression": SQUASHFS_COMPRESSION[compression]}


# --- reading the payload without running anything ------------------------------------------------------

def find_reader() -> Tuple[str, str]:
    """Return ``(kind, executable)``; ``unsquashfs`` first (explicit offset, zstd since 4.4)."""
    for name in UNSQUASHFS_NAMES:
        path = shutil.which(name)
        if path:
            return "unsquashfs", path
    for name in SEVEN_ZIP_NAMES:
        path = shutil.which(name)
        if path:
            return "7z", path
    raise v.ValidationError("neither unsquashfs nor 7-Zip found")


def _capture(cmd: List[str], limit: int, truncate: bool = False) -> bytes:
    """Run ``cmd`` (never through a shell) and return its stdout, bounded in size AND time.

    A reader thread drains stdout; the caller waits at most ``DEADLINE_SECONDS`` for it.  When the
    deadline passes, or more than ``limit`` bytes arrive, the process is killed.  ``truncate``
    returns the first ``limit`` bytes instead of failing (used for the 7-Zip header block, where the
    exit status is irrelevant because the process is stopped on purpose).
    """
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    except OSError as exc:
        raise v.ValidationError("cannot run the squashfs reader") from exc
    chunks: List[bytes] = []
    state = {"size": 0, "over": False}

    def pump() -> None:
        try:
            while True:
                chunk = proc.stdout.read1(1 << 20)  # type: ignore[union-attr]
                if not chunk:
                    return
                state["size"] += len(chunk)
                if state["size"] > limit:
                    state["over"] = True
                    chunks.append(chunk[: max(0, len(chunk) - (state["size"] - limit))])
                    return
                chunks.append(chunk)
        except (OSError, ValueError):
            return

    thread = threading.Thread(target=pump, daemon=True)
    thread.start()
    thread.join(DEADLINE_SECONDS)
    timed_out = thread.is_alive()
    rc: Optional[int] = None
    try:
        if timed_out or state["over"]:
            proc.kill()
        try:
            rc = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=30)
        thread.join(10)
    finally:
        if proc.stdout:
            proc.stdout.close()
    if timed_out:
        raise v.ValidationError("squashfs reader timed out")
    data = b"".join(chunks)
    if truncate:
        return data[:limit]
    if state["over"]:
        raise v.ValidationError("squashfs member larger than allowed")
    if rc != 0:
        raise v.ValidationError("squashfs reader failed")
    return data


def check_seven_zip_layout(exe: str, image: str, offset: int) -> None:
    """7-Zip auto-locates the payload: make sure it found the squashfs we validated by hand."""
    text = _head(exe, image).decode("utf-8", errors="replace")
    block = text.split("----------", 1)[0]
    ty = re.search(r"(?m)^Type = (\S+)\s*$", block)
    off = re.search(r"(?m)^Offset = ([0-9]{1,12})\s*$", block)
    if not ty or ty.group(1) != "SquashFS" or not off or int(off.group(1)) != offset:
        raise v.ValidationError("7-Zip did not open the squashfs payload at the expected offset")


def _head(exe: str, image: str) -> bytes:
    """First bytes of ``7z l -slt`` (the archive header block); the process is stopped afterwards."""
    return _capture([exe, "l", "-slt", "-bd", "-y", "-tsquashfs", "--", image], MAX_LISTING_BYTES, truncate=True)


def read_member(reader: Tuple[str, str], image: str, offset: int, member: str, limit: int) -> bytes:
    """Bytes of one regular file inside the squashfs payload (stdout of the reader, size-capped)."""
    if image.startswith("-") or not MEMBER_RE.fullmatch(member):
        raise v.ValidationError("refusing an unsafe path")
    kind, exe = reader
    if kind == "unsquashfs":
        cmd = [exe, "-n", "-o", str(offset), "-cat", image, member]
    elif kind == "7z":
        cmd = [exe, "e", "-so", "-bd", "-y", "-tsquashfs", "--", image, member]
    else:
        raise v.ValidationError("unknown reader")
    data = _capture(cmd, limit)
    if not data:
        raise v.ValidationError("squashfs member missing or empty")
    return data


def parse_desktop_version(data: bytes) -> str:
    """``X-AppImage-Version`` of the desktop entry (strict: ASCII, exactly one such key)."""
    if len(data) > MAX_DESKTOP_BYTES:
        raise v.ValidationError("desktop entry too large")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        text = data.decode("utf-8", errors="replace")
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "[Desktop Entry]":
        raise v.ValidationError("desktop entry does not start with [Desktop Entry]")
    found = [ln.split("=", 1)[1].strip() for ln in lines if ln.startswith("X-AppImage-Version=")]
    if len(found) != 1:
        raise v.ValidationError("desktop entry has no single X-AppImage-Version")
    return v.require(ANY_DAILY_RE, found[0], "desktop X-AppImage-Version")


def binary_versions(data: bytes) -> List[str]:
    """Every delimited ``6.2.0-daily.<n>`` string in the executable (unique, ordered by ``n``)."""
    return sorted({m.group(1).decode("ascii") for m in VERSION_STRING_RE.finditer(data)},
                  key=lambda x: int(x.rsplit(".", 1)[1]))


def check_binary(data: bytes, ci_version: str) -> Dict[str, Any]:
    """The expected version string must be present; other version-like strings are only recorded
    and fail the gate when one of them is HIGHER than ``ci_version`` (a newer build's string)."""
    if len(data) < MIN_BINARY_BYTES or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise v.ValidationError("usr/bin/moonlight is not a 64-bit little-endian ELF")
    (machine,) = struct.unpack_from("<H", data, 18)
    if machine != ELF_MACHINE_X86_64:
        raise v.ValidationError("usr/bin/moonlight is not x86-64")
    found = binary_versions(data)
    if ci_version not in found:
        raise v.ValidationError("expected version string of usr/bin/moonlight missing or not delimited")
    number = int(ci_version.rsplit(".", 1)[1])
    others = [f for f in found if f != ci_version]
    if any(int(f.rsplit(".", 1)[1]) > number for f in others):
        raise v.ValidationError("usr/bin/moonlight carries a 6.2.0-daily.<n> string above the expected ci_version")
    if len(others) > MAX_OTHER_VERSIONS:
        raise v.ValidationError("implausible number of version strings in usr/bin/moonlight")
    return {"binary_version": ci_version, "binary_machine": "x86_64", "other_versions": others}


def run_gate(tag: str, n: int, image: str, reader: Optional[Tuple[str, str]] = None) -> Dict[str, Any]:
    ci_version = version_map.build_version(tag, n)
    name = image_name(ci_version)
    if os.path.basename(image) != name:
        raise v.ValidationError("AppImage file name differs from Moonlight-<ci_version>-x86_64.AppImage")
    hdr = read_header(image)
    reader = reader or find_reader()
    if reader[0] == "7z":
        check_seven_zip_layout(reader[1], image, hdr["squashfs_offset"])
    desktop = parse_desktop_version(read_member(reader, image, hdr["squashfs_offset"], DESKTOP_ENTRY, MAX_DESKTOP_BYTES))
    if desktop != ci_version:
        raise v.ValidationError("desktop X-AppImage-Version differs from the expected ci_version")
    binary = check_binary(read_member(reader, image, hdr["squashfs_offset"], BINARY_ENTRY, MAX_BINARY_BYTES),
                          ci_version)
    return {
        "status": "ok", "tool": "appimage_gate",
        "ci_version": ci_version,
        "image": {"name": name, "sha256": sha256_file(image), "size": hdr["size"]},
        "elf": {"machine": "x86_64", "appimage_type": 2, "squashfs_offset": hdr["squashfs_offset"]},
        "squashfs": {"compression": hdr["compression"], "bytes_used": hdr["squashfs_bytes"]},
        "embedded": {"desktop_version": desktop, **binary},
        "reader": reader[0],
    }


def markdown(summary: Dict[str, Any]) -> str:
    """Run-summary text (all values are validated versions / names, never raw upstream text)."""
    return "\n".join([
        "### AppImage gate passed",
        f"* expected ci_version: `{summary['ci_version']}`",
        f"* image: `{summary['image']['name']}`, {summary['image']['size']} bytes, sha256 `{summary['image']['sha256']}`",
        f"* ELF x86-64, AppImage type 2, squashfs {summary['squashfs']['compression']} at offset {summary['elf']['squashfs_offset']}",
        f"* desktop X-AppImage-Version `{summary['embedded']['desktop_version']}`; "
        f"moonlight binary string `{summary['embedded']['binary_version']}`; other version strings: "
        f"{', '.join('`' + x + '`' for x in summary['embedded']['other_versions']) or 'none'} "
        f"(read with {summary['reader']}, nothing executed)",
        ""])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True, help="upstream tag v6.2.0-daily.U")
    ap.add_argument("--n", required=True, type=int)
    ap.add_argument("--image", required=True, help="Moonlight-<ci_version>-x86_64.AppImage")
    ap.add_argument("--out", required=True)
    ap.add_argument("--markdown", default="", help="also write a run-summary snippet here")
    args = ap.parse_args(argv)
    try:
        v.upstream_tag(args.tag)
        summary = run_gate(args.tag, args.n, args.image)
    except (v.ValidationError, OSError, subprocess.SubprocessError, struct.error) as exc:
        return v.fail(f"appimage_gate: {type(exc).__name__}: {str(exc)[:200]}")
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
        fh.write("\n")
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(markdown(summary))
    print(f"gate passed: {summary['image']['name']} is an x86-64 AppImage type 2 whose embedded version is "
          f"{summary['ci_version']} (read with {summary['reader']}, not executed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
