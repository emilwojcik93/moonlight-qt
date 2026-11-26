"""AppImage format gate and smoke test.

Format gate (no execution): ELF64 little-endian x86-64, AppImage type-2 magic `AI\\x02` at offset 8, size bounds.
Smoke test (`display` mode): `<AppImage> --appimage-extract-and-run --version` with a throw-away HOME/XDG so the real
Moonlight configuration and paired identity are never touched; the output must contain exactly `Moonlight <ci_version>`.
`--version` needs a display (Qt creates the GUI application before it parses options; verified on 6.2.0-daily.202).
`static` mode (headless hosts): only the AppImage *runtime* runs (`--appimage-version`, `--appimage-extract usr/bin/moonlight`),
then the extracted binary must be an ELF that embeds the expected version string.
"""

from __future__ import annotations

import os
import re
import signal
import subprocess
from typing import Dict, Optional

from .errors import Deferred, InstallError, VerifyError

SMOKE_TIMEOUT = 60
MIN_APPIMAGE = 1024 * 1024


def check_format(path: str, max_bytes: int) -> None:
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError as e:
        raise VerifyError("cannot read the AppImage: %s" % e.strerror)
    if size < MIN_APPIMAGE or size > max_bytes:
        raise VerifyError("AppImage size out of bounds")
    if len(head) < 20 or head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1:
        raise VerifyError("AppImage is not a little-endian ELF64")
    if head[18:20] != b"\x3e\x00":
        raise VerifyError("AppImage is not x86-64")
    if head[8:11] != b"AI\x02":
        raise VerifyError("AppImage type-2 magic missing")


def find_display(env: Dict[str, str], uid: Optional[int] = None) -> Optional[Dict[str, str]]:
    """Environment entries that give a display, from the inherited env or by discovering a Wayland socket."""
    add: Dict[str, str] = {}
    rt = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % (os.getuid() if uid is None else uid)
    if os.path.isdir(rt):
        add["XDG_RUNTIME_DIR"] = rt
    if env.get("WAYLAND_DISPLAY"):
        add["WAYLAND_DISPLAY"] = env["WAYLAND_DISPLAY"]
        return add
    if env.get("DISPLAY"):
        add["DISPLAY"] = env["DISPLAY"]
        if env.get("XAUTHORITY"):
            add["XAUTHORITY"] = env["XAUTHORITY"]
        return add
    try:
        for n in sorted(os.listdir(rt)):
            if re.fullmatch(r"wayland-[0-9]{1,2}", n):
                st = os.stat(os.path.join(rt, n))
                if st.st_uid == os.geteuid():
                    add["WAYLAND_DISPLAY"] = n
                    return add
    except OSError:
        pass
    return None


def _run(argv, env, timeout, cwd=None):
    p = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out[:1024 * 1024].decode("utf-8", "replace"), False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=10)
        except Exception:
            pass
        return -1, "", True


def _sandbox_env(tmp: str, display: Optional[Dict[str, str]]) -> Dict[str, str]:
    """Throw-away HOME/XDG/TMPDIR: the smoke test must never see the real Moonlight settings. TMPDIR matters: the
    AppImage runtime extracts to $TMPDIR (verified), and under ProtectSystem=strict /tmp is read-only.
    XDG_RUNTIME_DIR is passed only when a display is needed (it comes with `display`); the static mode never gets it."""
    keep = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL")}
    for d in ("home", "config", "data", "cache", "tmp"):
        os.makedirs(os.path.join(tmp, d), mode=0o700, exist_ok=True)
    keep.update({
        "HOME": os.path.join(tmp, "home"), "XDG_CONFIG_HOME": os.path.join(tmp, "config"),
        "XDG_DATA_HOME": os.path.join(tmp, "data"), "XDG_CACHE_HOME": os.path.join(tmp, "cache"),
        "TMPDIR": os.path.join(tmp, "tmp"), "SDL_AUDIODRIVER": "dummy",
        "DBUS_SESSION_BUS_ADDRESS": "disabled:",          # no session bus: the smoke test must not talk to the desktop
    })
    if display:
        keep.update(display)
    return keep


def _contains(path: str, needle: bytes) -> bool:
    keep = len(needle) - 1
    tail = b""
    with open(path, "rb") as f:
        while True:
            b = f.read(4 * 1024 * 1024)
            if not b:
                return False
            if needle in tail + b:
                return True
            tail = (tail + b)[-keep:] if keep else b""


def run_smoke(appimage: str, expected_version: str, mode: str, tmp: str, display: Optional[Dict[str, str]]) -> str:
    """Raises InstallError on failure, Deferred when `display` mode has no display. Returns a short result string."""
    if mode == "display":
        if display is None:
            raise Deferred("no display available for the smoke test (set smoke_test=static for headless hosts)")
        env = _sandbox_env(tmp, display)
        rc, out, timed_out = _run([appimage, "--appimage-extract-and-run", "--version"], env, SMOKE_TIMEOUT, cwd=tmp)
        if timed_out:
            raise InstallError("smoke test timed out")
        if rc != 0:
            raise InstallError("smoke test exited with rc=%d" % rc)
        want = "Moonlight " + expected_version
        if not any(line.strip() == want for line in out.splitlines()):
            raise InstallError("smoke test did not report '%s'" % want)
        return "version"
    if mode == "static":
        env = _sandbox_env(tmp, None)
        rc, out, timed_out = _run([appimage, "--appimage-version"], env, 30, cwd=tmp)
        if rc != 0 or timed_out:
            raise InstallError("AppImage runtime does not start (rc=%s)" % rc)
        ex = os.path.join(tmp, "extract")
        os.makedirs(ex, mode=0o700, exist_ok=True)
        rc, out, timed_out = _run([appimage, "--appimage-extract", "usr/bin/moonlight"], env, SMOKE_TIMEOUT, cwd=ex)
        binp = os.path.join(ex, "squashfs-root", "usr", "bin", "moonlight")
        if rc != 0 or timed_out or os.path.islink(binp) or not os.path.isfile(binp):
            raise InstallError("could not extract usr/bin/moonlight from the AppImage")
        with open(binp, "rb") as f:
            if f.read(4) != b"\x7fELF":
                raise InstallError("usr/bin/moonlight is not an ELF")
        if not _contains(binp, expected_version.encode("ascii")):
            raise InstallError("usr/bin/moonlight does not embed version %s" % expected_version)
        return "static"
    raise InstallError("unknown smoke mode")
