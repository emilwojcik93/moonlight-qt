"""Install store: ~/.local/opt/moonlight-posture/<tag>/Moonlight.AppImage, `current` symlink, launcher, desktop entry.

Atomicity: the AppImage is copied (hashing while copying) into a staging directory on the same file system, smoke
tested there, and the directory is renamed into place; `current` is switched by symlink + rename (never a window in
which it is missing or dangling). Only directories whose name is a canonical tag are ever touched or pruned.
"""

from __future__ import annotations

import json
import os
import shlex
import stat
import time
from typing import Any, Dict, List, Optional, Set

from . import fsio, versioning
from .errors import InstallError, RollbackError
from .paths import Paths

APPIMAGE_NAME = "Moonlight.AppImage"
META_NAME = "INSTALL.json"


class Store:
    def __init__(self, paths: Paths, log=None) -> None:
        self.p = paths
        self.log = log

    # ---- inspection -------------------------------------------------------------------------------------------
    def tag_dir(self, tag: str) -> str:
        if not versioning.is_tag(tag):
            raise ValueError("invalid tag")
        return os.path.join(self.p.opt_dir, tag)

    def appimage_path(self, tag: str) -> str:
        return os.path.join(self.tag_dir(tag), APPIMAGE_NAME)

    def current_tag(self) -> Optional[str]:
        """The tag `current` points at, only when it is a bare canonical tag name (anything else = unusable)."""
        t = fsio.read_link(self.p.current_link)
        return t if t is not None and versioning.is_tag(t) else None

    def installed_tags(self) -> List[str]:
        try:
            names = os.listdir(self.p.opt_dir)
        except OSError:
            return []
        out = []
        for n in names:
            if versioning.is_tag(n):
                try:
                    st = os.lstat(os.path.join(self.p.opt_dir, n))
                except OSError:
                    continue
                if stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode):
                    out.append(n)
        return sorted(out, key=lambda t: versioning.parse_tag(t).build)

    def read_meta(self, tag: str) -> Optional[Dict[str, Any]]:
        try:
            with open(os.path.join(self.tag_dir(tag), META_NAME), "rb") as f:
                m = json.loads(f.read(65536).decode("utf-8"))
        except (OSError, ValueError):
            return None
        if (not isinstance(m, dict) or m.get("tag") != tag
                or not isinstance(m.get("sha256"), str) or not versioning.SHA256_RE.fullmatch(m["sha256"])):
            return None
        return m

    # ---- staging + commit -----------------------------------------------------------------------------------------
    def stage(self, src: str, tag: str, expected_sha256: str, run_id: str, meta: Dict[str, Any]) -> str:
        """Copy `src` into <opt>/.stage-<run>/, hashing during the copy; the copy must equal `expected_sha256`."""
        os.makedirs(self.p.opt_dir, mode=0o755, exist_ok=True)
        sd = os.path.join(self.p.opt_dir, ".stage-%s" % run_id)
        if os.path.lexists(sd):
            fsio.rmtree_quiet(sd)
        os.mkdir(sd, 0o700)
        try:
            import hashlib
            h = hashlib.sha256()
            dst = os.path.join(sd, APPIMAGE_NAME)
            fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
            with os.fdopen(fd, "wb") as out, open(src, "rb") as inp:
                while True:
                    b = inp.read(fsio.CHUNK)
                    if not b:
                        break
                    h.update(b)
                    fsio.write_chunk(out, b)
                out.flush()
                os.fsync(out.fileno())
            if h.hexdigest() != expected_sha256:
                raise InstallError("copy does not match the verified hash (file changed after verification)")
            os.chmod(dst, 0o755)
            m = dict(meta, tag=tag, sha256=expected_sha256, build=versioning.parse_tag(tag).build,
                     installed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            fsio.atomic_write_json(os.path.join(sd, META_NAME), m, 0o644)
            os.chmod(sd, 0o755)
        except BaseException:
            fsio.rmtree_quiet(sd)
            raise
        return sd

    def commit(self, stage_dir: str, tag: str, run_id: str) -> str:
        """Rename the staging dir to <opt>/<tag>. A leftover directory of the same tag (failed earlier attempt) is
        moved aside first and deleted; the directory `current` points at is never replaced."""
        final = self.tag_dir(tag)
        if os.path.lexists(final):
            if self.current_tag() == tag:
                raise InstallError("target tag is the current version")
            aside = os.path.join(self.p.opt_dir, ".trash-%s" % run_id)
            os.rename(final, aside)
            fsio.rmtree_quiet(aside)
        os.rename(stage_dir, final)
        fsio.fsync_dir(self.p.opt_dir)
        return final

    def switch(self, tag: str) -> None:
        if not os.path.isfile(self.appimage_path(tag)):
            raise InstallError("cannot switch: AppImage missing for %s" % tag)
        fsio.switch_symlink(self.p.current_link, tag)

    def discard(self, tag: str) -> None:
        if self.current_tag() == tag:
            return
        fsio.rmtree_quiet(self.tag_dir(tag))

    # ---- rollback -----------------------------------------------------------------------------------------------
    def verify_installed(self, tag: str, expected_sha256: Optional[str] = None) -> str:
        """Re-hash an installed AppImage against INSTALL.json (and `expected_sha256` when given). Returns the hash."""
        meta = self.read_meta(tag)
        if meta is None:
            raise RollbackError("no valid INSTALL.json for %s" % tag)
        path = self.appimage_path(tag)
        try:
            st = os.lstat(path)
        except OSError:
            raise RollbackError("AppImage missing for %s" % tag)
        if not stat.S_ISREG(st.st_mode):
            raise RollbackError("AppImage for %s is not a regular file" % tag)
        got = fsio.sha256_file(path)
        if got != meta["sha256"] or (expected_sha256 and got != expected_sha256):
            raise RollbackError("AppImage for %s does not match its recorded hash" % tag)
        return got

    # ---- pruning --------------------------------------------------------------------------------------------------
    def prune(self, keep: Set[str]) -> List[str]:
        removed = []
        for t in self.installed_tags():
            if t not in keep:
                fsio.rmtree_quiet(self.tag_dir(t))
                removed.append(t)
        try:
            names = os.listdir(self.p.opt_dir)
        except OSError:
            names = []
        now = time.time()
        for n in names:
            if n.startswith((".stage-", ".trash-", ".link-")):
                fp = os.path.join(self.p.opt_dir, n)
                try:
                    if now - os.lstat(fp).st_mtime > 3600:
                        if os.path.isdir(fp) and not os.path.islink(fp):
                            fsio.rmtree_quiet(fp)
                        else:
                            os.unlink(fp)
                except OSError:
                    pass
        return removed

    # ---- launcher + desktop entry ----------------------------------------------------------------------------------
    def launcher_text(self) -> str:
        app = os.path.join(self.p.opt_dir, "current", APPIMAGE_NAME)
        return (
            "#!/bin/sh\n"
            "# Generated by moonlight-posture-update. Rewritten on every install; do not edit.\n"
            "APP=%s\n"
            "if [ ! -x \"$APP\" ]; then\n"
            "  echo \"moonlight-posture: no verified AppImage installed (see: moonlight-posture-update status)\" >&2\n"
            "  exit 127\n"
            "fi\n"
            "# Use FUSE only when it clearly works; otherwise extract to a temp dir and run from there.\n"
            "if [ -z \"$MOONLIGHT_POSTURE_NO_FUSE\" ] && [ -c /dev/fuse ] && [ -r /dev/fuse ] && [ -w /dev/fuse ] \\\n"
            "   && { command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1; }; then\n"
            "  exec \"$APP\" \"$@\"\n"
            "fi\n"
            "exec \"$APP\" --appimage-extract-and-run \"$@\"\n"
        ) % shlex.quote(app)

    def desktop_text(self) -> str:
        exe = self.p.launcher
        if any(c in exe for c in ' \t"\'\\$`<>~|&;*?#()'):
            exe = '"%s"' % exe.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
        return (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Moonlight (posture build)\n"
            "Comment=Patched Moonlight client installed by moonlight-posture-update\n"
            "Exec=%s\n"
            "Icon=moonlight\n"
            "Terminal=false\n"
            "Categories=Game;Network;\n"
            "StartupNotify=false\n"
        ) % exe

    def write_launcher_and_desktop(self) -> None:
        os.makedirs(self.p.launcher_dir, mode=0o755, exist_ok=True)
        os.makedirs(self.p.apps_dir, mode=0o755, exist_ok=True)
        fsio.atomic_write(self.p.launcher, self.launcher_text().encode(), 0o755)
        fsio.atomic_write(self.p.desktop_file, self.desktop_text().encode(), 0o644)
