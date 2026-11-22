#!/usr/bin/env python3
"""Mandatory release gate for the built Windows bundle (CONTRACT 3b, AC-BLD-3 analogue).

The bundle ``MoonlightSetup-<ci_version>.exe`` is a WiX Burn bootstrapper.  Upstream's workflow
emits NO standalone MSI (the x64 and arm64 MSIs sit inside the bundle's attached container), so
"MSI ProductVersion" is read from the Burn manifest (``0`` inside the bootstrapper's UX cabinet,
extracted with 7-Zip) where WiX records the exact ``Version`` of every ``MsiPackage`` and of the
bundle registration at build time.

Gate (all must hold, expected = ``version_map.file_version(tag, n)`` = ``6.2.B.0``):

1. expected == 6.2.(60000 + 8*U + N - 1).0 and expected > upstream's own ``6.2.U.0``;
2. bundle PE FileVersion (numeric and string) == expected;
3. Burn manifest: registration ``Version`` and every ``MsiPackage`` ``Version`` == expected, and at
   least two MSI packages (x64 + arm64) exist;
4. ``Moonlight.exe`` FileVersion (numeric and string) == expected for x64 and arm64.

The inputs are untrusted upstream-built binaries: they are only parsed (PE resources with the stdlib,
the Burn manifest with a bounded ``7z e -so`` read and strict regexes, never an XML parser), never
executed.  The summary written to ``--out`` is plain JSON (re-validated by the publish job).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Optional

import pe_version
import version_map
import vpcommon as v

MAX_MANIFEST_BYTES = 2 * 1024 * 1024
SEVEN_ZIP_NAMES = ("7zz", "7z", "7za", "7zr")
VERSION_RE = re.compile(r"[0-9]{1,5}(?:\.[0-9]{1,5}){3}")
PKG_ID_RE = re.compile(r"[A-Za-z0-9_.-]{1,64}")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def find_seven_zip() -> str:
    for name in SEVEN_ZIP_NAMES:
        path = shutil.which(name)
        if path:
            return path
    raise v.ValidationError("7-Zip not found (7zz/7z/7za)")


def extract_burn_manifest(bundle: str, seven_zip: Optional[str] = None) -> str:
    """Return the text of the BurnManifest XML (file ``0`` of the UX cabinet), size-bounded."""
    exe = seven_zip or find_seven_zip()
    try:
        proc = subprocess.Popen([exe, "e", "-so", "-bd", "-y", "--", bundle, "0"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    except OSError as exc:
        raise v.ValidationError("cannot run 7-Zip") from exc
    try:
        data = proc.stdout.read(MAX_MANIFEST_BYTES + 1) if proc.stdout else b""
    finally:
        proc.kill()
        proc.wait(timeout=30)
        if proc.stdout:
            proc.stdout.close()
    if not data or len(data) > MAX_MANIFEST_BYTES:
        raise v.ValidationError("burn manifest missing or oversized")
    text = data.decode("utf-8-sig", errors="replace")
    if "<BurnManifest" not in text[:4096]:
        raise v.ValidationError("burn manifest not found in the bundle")
    return text


def parse_burn_versions(text: str) -> Dict[str, Any]:
    """Strict regex extraction of the bundle registration and every MsiPackage version."""
    reg = re.search(r"<Registration\b[^>]{0,4000}?(?<![A-Za-z])Version=\"([0-9.]{1,40})\"", text)
    pkgs: List[Dict[str, str]] = []
    for m in re.finditer(r"<MsiPackage\b([^>]{0,4000})>", text):
        attrs = m.group(1)
        pid = re.search(r"(?<![A-Za-z])Id=\"([^\"]{1,80})\"", attrs)
        ver = re.search(r"(?<![A-Za-z])Version=\"([^\"]{1,40})\"", attrs)
        if not pid or not ver:
            raise v.ValidationError("burn manifest: MsiPackage without Id or Version")
        v.require(PKG_ID_RE, pid.group(1), "msi package id")
        v.require(VERSION_RE, ver.group(1), "msi package version")
        pkgs.append({"id": pid.group(1), "version": ver.group(1)})
    if len(pkgs) > 16:
        raise v.ValidationError("burn manifest: implausible package count")
    return {"registration_version": reg.group(1) if reg else None, "msi_packages": pkgs}


def _check_exe(label: str, path: str, expected: str) -> Dict[str, Any]:
    info = pe_version.read(path)
    got = pe_version.dotted(info["fixed"])
    if version_map.version_tuple(got) != version_map.version_tuple(expected):
        raise v.ValidationError(f"{label}: numeric FileVersion {got} != expected {expected}")
    fv = info["file_version"]
    if fv is not None and version_map.version_tuple(fv) != version_map.version_tuple(expected):
        raise v.ValidationError(f"{label}: FileVersion string differs from the expected version")
    if fv is None:
        raise v.ValidationError(f"{label}: no FileVersion string in the version resource")
    return {"file_version": got}


def run_gate(tag: str, n: int, bundle: str, x64_exe: str, arm64_exe: str,
             seven_zip: Optional[str] = None) -> Dict[str, Any]:
    expected = version_map.file_version(tag, n)
    version_map.check_window(expected, tag, n)  # also proves expected > upstream 6.2.U.0
    summary: Dict[str, Any] = {
        "status": "ok", "tool": "bundle_gate",
        "expected_file_version": expected,
        "upstream_file_version": version_map.upstream_file_version(tag),
        "bundle": {"sha256": sha256_file(bundle), "size": os.path.getsize(bundle)},
    }
    summary["bundle"].update(_check_exe("bundle", bundle, expected))
    burn = parse_burn_versions(extract_burn_manifest(bundle, seven_zip))
    reg = burn["registration_version"]
    if reg is None or version_map.version_tuple(reg) != version_map.version_tuple(expected):
        raise v.ValidationError("burn manifest registration version differs from the expected version")
    if len(burn["msi_packages"]) < 2:
        raise v.ValidationError("burn manifest lists fewer than two MSI packages (x64 + arm64 expected)")
    for pkg in burn["msi_packages"]:
        if version_map.version_tuple(pkg["version"]) != version_map.version_tuple(expected):
            raise v.ValidationError("an embedded MSI ProductVersion differs from the expected version")
    summary["burn"] = burn
    summary["executables"] = {"x64": _check_exe("x64 Moonlight.exe", x64_exe, expected),
                              "arm64": _check_exe("arm64 Moonlight.exe", arm64_exe, expected)}
    return summary


def markdown(summary: Dict[str, Any]) -> str:
    """Run-summary text (all values are validated versions / ids, never raw upstream text)."""
    pk = ", ".join(f"{p['id']} {p['version']}" for p in summary["burn"]["msi_packages"])
    ex = ", ".join(f"{k} {x['file_version']}" for k, x in sorted(summary["executables"].items()))
    return "\n".join([
        "### Version gate passed",
        f"* expected FileVersion: `{summary['expected_file_version']}` (upstream's own: `{summary['upstream_file_version']}`)",
        f"* bundle: `{summary['bundle']['file_version']}`, sha256 `{summary['bundle']['sha256']}`",
        f"* Burn registration `{summary['burn']['registration_version']}`; embedded MSIs: {pk}",
        f"* Moonlight.exe: {ex}",
        ""])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True, help="upstream tag v6.2.0-daily.U")
    ap.add_argument("--n", required=True, type=int)
    ap.add_argument("--bundle", required=True, help="MoonlightSetup-<ci_version>.exe")
    ap.add_argument("--x64-exe", required=True)
    ap.add_argument("--arm64-exe", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--markdown", default="", help="also write a run-summary snippet here")
    args = ap.parse_args(argv)
    try:
        v.upstream_tag(args.tag)
        summary = run_gate(args.tag, args.n, args.bundle, args.x64_exe, args.arm64_exe)
    except (v.ValidationError, OSError, subprocess.SubprocessError) as exc:
        return v.fail(f"bundle_gate: {type(exc).__name__}: {str(exc)[:200]}")
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
        fh.write("\n")
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(markdown(summary))
    print(f"gate passed: bundle, {len(summary['burn']['msi_packages'])} embedded MSIs and both Moonlight.exe "
          f"are {summary['expected_file_version']} (upstream {summary['upstream_file_version']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
