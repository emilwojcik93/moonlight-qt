#!/usr/bin/env python3
"""Stage the build artifacts into the release ``dist`` directory.

``--release-dir`` is the contents of upstream's artifact ``Moonlight-Windows-Release-<ci_version>``:
it must hold exactly ``MoonlightSetup-<ci_version>.exe`` and ``MoonlightPortable-x64-<ci_version>.zip``.
Only the bundle is released; it is staged under the contract name ``MoonlightSetup.exe``
(the portable zip is never published).  With ``--gate-summary`` the staged bytes must hash to the
value the unprivileged ``package`` job recorded when it ran the version gate on that same artifact
(closes the gap between the file that was inspected and the file that is attested).

Files are only hashed / copied, never executed.  Symlinks, unexpected files and oversized files
are rejected.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from typing import List

import vpcommon as v

INSTALLER = "MoonlightSetup.exe"
MAX_BYTES = 400 * 1024 * 1024
MIN_BYTES = 1024 * 1024  # a real Burn bundle is ~50 MB
CI_VERSION_RE = re.compile(r"6\.2\.0-daily\.[1-9][0-9]{4}")


def bundle_name(ci_version: str) -> str:
    v.require(CI_VERSION_RE, ci_version, "ci_version")
    return f"MoonlightSetup-{ci_version}.exe"


def portable_name(ci_version: str) -> str:
    v.require(CI_VERSION_RE, ci_version, "ci_version")
    return f"MoonlightPortable-x64-{ci_version}.zip"


def _regular_files(directory: str) -> List[str]:
    out = []
    for root, dirs, files in os.walk(directory):
        for name in files + dirs:
            p = os.path.join(root, name)
            if os.path.islink(p):
                raise v.ValidationError("symlink in artifact")
        for name in files:
            out.append(os.path.relpath(os.path.join(root, name), directory).replace("\\", "/"))
    return sorted(out)


def check_release_dir(release_dir: str, ci_version: str) -> str:
    """Validate the artifact content and return the path of the bundle."""
    files = _regular_files(release_dir)
    expected = {bundle_name(ci_version), portable_name(ci_version)}
    if set(files) != expected or len(files) != 2:
        raise v.ValidationError("release artifact content is not exactly the expected set")
    path = os.path.join(release_dir, bundle_name(ci_version))
    size = os.path.getsize(path)
    if not (MIN_BYTES <= size <= MAX_BYTES):
        raise v.ValidationError("unexpected installer size")
    with open(path, "rb") as fh:
        if fh.read(2) != b"MZ":
            raise v.ValidationError("installer is not a PE file")
    return path


def stage(release_dir: str, dist: str, ci_version: str, gate_summary: str = "") -> List[str]:
    path = check_release_dir(release_dir, ci_version)
    os.makedirs(dist, exist_ok=True)
    target = os.path.join(dist, INSTALLER)
    shutil.copyfile(path, target)
    if gate_summary:
        with open(gate_summary, "r", encoding="utf-8") as fh:
            summary = json.load(fh)
        h = hashlib.sha256()
        with open(target, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        recorded = summary.get("bundle", {}).get("sha256") if isinstance(summary, dict) else None
        if recorded != h.hexdigest():
            raise v.ValidationError("staged installer differs from the file the version gate inspected")
    return [INSTALLER]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--release-dir", required=True)
    ap.add_argument("--dist", required=True)
    ap.add_argument("--ci-version", required=True)
    ap.add_argument("--gate-summary", default="")
    args = ap.parse_args(argv)
    try:
        staged = stage(args.release_dir, args.dist, args.ci_version, args.gate_summary)
    except (v.ValidationError, OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        return v.fail(f"stage_assets: {type(exc).__name__}: {str(exc)[:200]}")
    print("staged: " + ", ".join(staged))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
