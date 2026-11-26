"""Filesystem helpers: private directories, atomic writes, hashing, ownership checks, atomic symlink switch."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
from typing import Any, Optional

CHUNK = 1024 * 1024


def write_chunk(fh, data: bytes) -> None:
    """Single choke point for payload writes (disk-full tests replace it)."""
    fh.write(data)


def ensure_private_dir(path: str) -> None:
    """Create `path` (mode 0700) when missing; refuse symlinks and foreign owners; tighten loose modes."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise OSError("not a plain directory: %s" % path)
    if st.st_uid != os.geteuid():
        raise OSError("directory not owned by the current user: %s" % path)
    if st.st_mode & 0o077:
        os.chmod(path, 0o700)


def check_private_file(path: str) -> None:
    """A file we read as configuration/state: regular, owned by us, not writable by group/other, no symlink."""
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise OSError("not a regular file: %s" % path)
    if st.st_uid != os.geteuid():
        raise OSError("not owned by the current user: %s" % path)
    if st.st_mode & 0o022:
        raise OSError("writable by group or others: %s" % path)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def fsync_dir(path: str) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def atomic_write(path: str, data: bytes, mode: int = 0o600) -> None:
    """tmp file in the same directory + fsync + rename. On any failure the old file is untouched."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            write_chunk(f, data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    fsync_dir(d)


def atomic_write_json(path: str, obj: Any, mode: int = 0o600) -> None:
    atomic_write(path, (json.dumps(obj, indent=1, sort_keys=True) + "\n").encode("utf-8"), mode)


def switch_symlink(link: str, target: str) -> None:
    """Atomically point `link` at `target` (relative name): create a temp symlink then rename over it."""
    d = os.path.dirname(link)
    tmp = os.path.join(d, ".link-%d-%s" % (os.getpid(), os.urandom(4).hex()))
    os.symlink(target, tmp)
    try:
        os.replace(tmp, link)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    fsync_dir(d)


def read_link(link: str) -> Optional[str]:
    try:
        return os.readlink(link)
    except OSError:
        return None


def rmtree_quiet(path: str) -> None:
    import shutil
    shutil.rmtree(path, ignore_errors=True)
