"""Detect a running Moonlight client (never replace a client mid-stream). Reads /proc only."""

from __future__ import annotations

import os
import re
from typing import List, Set, Tuple

_APPIMAGE_ARG0 = re.compile(r"moonlight[a-z0-9._-]*\.appimage", re.I)


def _read(path: str, limit: int = 4096) -> bytes:
    try:
        with open(path, "rb") as f:
            return f.read(limit)
    except OSError:
        return b""


def ancestors_and_self(proc_root: str = "/proc") -> Set[int]:
    pids = {os.getpid()}
    pid = os.getppid()
    for _ in range(32):
        if pid <= 1 or pid in pids:
            break
        pids.add(pid)
        stat = _read(os.path.join(proc_root, str(pid), "stat")).decode("utf-8", "replace")
        m = re.match(r"\d+ \(.*\) \S (\d+)", stat, re.S)
        pid = int(m.group(1)) if m else 0
    return pids


def is_client(comm: str, argv0: str, exe: str, opt_dir: str = "") -> bool:
    c = comm.strip().lower()
    a = os.path.basename(argv0).strip()
    e = os.path.basename(exe).strip().lower() if exe else ""
    if c == "moonlight" or c.startswith("moonlight.appim") or c == "moonlight-qt":
        return True
    if a.lower() in ("moonlight", "moonlight-qt") or _APPIMAGE_ARG0.fullmatch(a):
        return True
    if e in ("moonlight", "moonlight-qt"):
        return True
    if opt_dir and exe.startswith(opt_dir.rstrip("/") + "/"):
        return True
    return False


def find_clients(proc_root: str = "/proc", exclude: Set[int] = frozenset(), opt_dir: str = "") -> List[Tuple[int, str]]:
    """PIDs of running Moonlight clients (also the AppImage runtime and `--appimage-extract-and-run` children).
    Our own process chain is excluded. Unreadable /proc entries are skipped (a process we cannot see is not ours)."""
    out: List[Tuple[int, str]] = []
    try:
        names = os.listdir(proc_root)
    except OSError:
        return out
    for n in names:
        if not n.isdigit():
            continue
        pid = int(n)
        if pid in exclude:
            continue
        base = os.path.join(proc_root, n)
        comm = _read(os.path.join(base, "comm"), 64).decode("utf-8", "replace")
        if not comm:
            continue
        argv0 = _read(os.path.join(base, "cmdline"), 1024).split(b"\0")[0].decode("utf-8", "replace")
        try:
            exe = os.readlink(os.path.join(base, "exe"))
        except OSError:
            exe = ""
        if exe.endswith(" (deleted)"):
            exe = exe[:-10]
        if is_client(comm, argv0, exe, opt_dir):
            out.append((pid, comm.strip()))
    return out
