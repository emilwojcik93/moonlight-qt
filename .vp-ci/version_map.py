#!/usr/bin/env python3
"""Version mapper (CONTRACT v1.1 section 3b, research/02 section 3).

Upstream daily tag ``v6.2.0-daily.U`` and rebuild number ``N`` (1..8) map to

    release tag       v6.2.0-daily.U-vp.N
    build branch      build/v6.2.0-daily.U-nN
    build number B    60000 + 8*U + (N-1)
    ci_version        6.2.0-daily.B           (input of upstream build-win-mac.yml)
    FileVersion       6.2.B.0                 (Moonlight.exe, MoonlightSetup bundle, embedded MSIs)

(``scripts/vrr-pe-version.ps1`` maps ``6.2.0-daily.B`` to ``6.2.B``; the PE/MSI fourth field is 0.)

Why: Windows Installer compares only major.minor.build, so every rebuild needs a distinct B to
upgrade; B is strictly monotonic in (U, N) (``B(U,8) = B(U+1,1) - 1``), always above upstream's own
``6.2.U`` (so the in-app updater of Nonary never offers a downgrade) and above the legacy fork
builds ``6.2.60002..60006`` for every U >= 1.  Hard limits: B <= 65535 (16-bit field) => U <= 691,
N <= 8.
"""
from __future__ import annotations

import argparse
from typing import Dict, Tuple

import vpcommon as v


def _check_n(n: object) -> int:
    if not isinstance(n, int) or isinstance(n, bool) or not (1 <= n <= v.MAX_BUILD_N):
        raise v.ValidationError("build number must be an integer in 1..8")
    return n


def _check_u(u: int) -> int:
    if not (1 <= u <= v.MAX_DAILY):
        raise v.ValidationError("upstream daily number exceeds the build number encoding (max 691)")
    return u


def build_number(tag: str, n: int) -> int:
    u = _check_u(v.daily_number(tag))
    b = v.BUILD_BASE + 8 * u + (_check_n(n) - 1)
    if b > v.MAX_BUILD_NUMBER:  # unreachable for u <= 691, kept as a second guard
        raise v.ValidationError("build number exceeds 65535")
    return b


def build_version(tag: str, n: int) -> str:
    return f"6.2.0-daily.{build_number(tag, n)}"


def file_version(tag: str, n: int) -> str:
    """Expected PE / MSI version (``msi_product_version`` in the manifest)."""
    return f"6.2.{build_number(tag, n)}.0"


def upstream_file_version(tag: str) -> str:
    """FileVersion upstream itself ships for the plain tag: ``6.2.U.0``."""
    return f"6.2.{_check_u(v.daily_number(tag))}.0"


def from_build_number(b: int) -> Tuple[int, int]:
    """Inverse mapping ``B -> (U, N)`` (consumers derive the installed (U, N) the same way)."""
    if not isinstance(b, int) or isinstance(b, bool) or not (v.BUILD_BASE + 8 <= b <= v.MAX_BUILD_NUMBER):
        raise v.ValidationError("not a pipeline build number")
    q, r = divmod(b - v.BUILD_BASE, 8)
    return q, r + 1


def version_tuple(version: str) -> Tuple[int, int, int, int]:
    """Parse a 3- or 4-part numeric version into a 4-tuple (``6.2.61616`` == ``6.2.61616.0``)."""
    parts = version.split(".")
    if not (3 <= len(parts) <= 4) or not all(p.isascii() and p.isdigit() and len(p) <= 5 for p in parts):
        raise v.ValidationError("not a numeric version")
    nums = [int(p) for p in parts] + [0] * (4 - len(parts))
    return tuple(nums)  # type: ignore[return-value]


def compute(tag: str, n: int) -> Dict[str, str]:
    v.upstream_tag(tag)
    b = build_number(tag, n)
    out = {
        "release_tag": f"{tag}-vp.{n}",
        "build_number": str(b),
        "build_version": f"6.2.0-daily.{b}",
        "file_version": f"6.2.{b}.0",
        "upstream_file_version": upstream_file_version(tag),
        "branch": v.branch_name(tag, n),
    }
    v.release_tag(out["release_tag"])
    return out


def check_window(actual: str, tag: str, n: int) -> None:
    """Mandatory release gate: ``actual`` must equal the expected 6.2.B.0 and exceed upstream's 6.2.U.0."""
    a = version_tuple(actual)
    if a != version_tuple(file_version(tag, n)):
        raise v.ValidationError(f"version {actual[:30]!r} differs from the expected {file_version(tag, n)}")
    if not a > version_tuple(upstream_file_version(tag)):
        raise v.ValidationError(f"version {actual[:30]!r} is not above upstream {upstream_file_version(tag)}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True, help="upstream tag v6.2.0-daily.U")
    ap.add_argument("--n", required=True, type=int, help="rebuild number 1..8")
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args(argv)
    try:
        result = compute(args.tag, args.n)
    except v.ValidationError as exc:
        return v.fail(f"version_map: {exc}")
    if args.github_output:
        v.write_outputs(result)
    else:
        for key, value in result.items():
            print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
