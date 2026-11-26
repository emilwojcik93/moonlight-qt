"""Tag validation, build-number scheme (CONTRACT v1.1 section 3b), ordering.

B = 60000 + 8*U + (N-1), N in 1..8, B <= 65535. Ordering is numeric on B (equivalent to (U, N)).
Everything that depends on the scheme lives in this file.
"""

from __future__ import annotations

import re
from typing import NamedTuple, Optional

OFFSET = 60000
PER_U = 8
MAX_BUILD = 65535
MAX_TAG_LEN = 40

# Canonical: no leading zeros, N >= 1. [0-9] (not \d) so unicode digits never match; fullmatch (not `$`)
# so a trailing newline never matches.
TAG_RE = re.compile(r"v6\.2\.0-daily\.([1-9][0-9]{0,4})-vp\.([1-9][0-9]{0,2})")
APPIMAGE_RE = re.compile(r"Moonlight-6\.2\.0-daily\.([0-9]{5})-x86_64\.AppImage")
BUILD_VERSION_RE = re.compile(r"6\.2\.0-daily\.([0-9]{5})")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
SHA1_RE = re.compile(r"[0-9a-f]{40}")


class Key(NamedTuple):
    u: int
    n: int
    build: int
    tag: str


def is_tag(value: object) -> bool:
    return isinstance(value, str) and len(value) <= MAX_TAG_LEN and TAG_RE.fullmatch(value) is not None


def build_number(u: int, n: int) -> int:
    if u < 1:
        raise ValueError("U must be >= 1")
    if n < 1 or n > PER_U:
        raise ValueError("N must be 1..%d" % PER_U)
    b = OFFSET + PER_U * u + (n - 1)
    if b > MAX_BUILD:
        raise ValueError("build number %d exceeds the limit" % b)
    return b


def from_build(build: int) -> Optional[tuple]:
    if build < OFFSET or build > MAX_BUILD:
        return None
    d = build - OFFSET
    return d // PER_U, d % PER_U + 1


def parse_tag(tag: object) -> Key:
    """Tag -> Key. Raises ValueError for non-canonical tags and for N > 8 / B > 65535 (not installable)."""
    if not is_tag(tag):
        raise ValueError("invalid moonlight tag")
    m = TAG_RE.fullmatch(tag)  # type: ignore[arg-type]
    u, n = int(m.group(1)), int(m.group(2))
    return Key(u, n, build_number(u, n), tag)  # type: ignore[arg-type]


def tag_for_build(build: int) -> Optional[str]:
    un = from_build(build)
    if un is None:
        return None
    return "v6.2.0-daily.%d-vp.%d" % un


def source_ref_for(key: Key) -> str:
    """The attestation source ref is derived from the tag, never trusted from the manifest."""
    return "refs/heads/build/v6.2.0-daily.%d-n%d" % (key.u, key.n)


def build_version_for(key: Key) -> str:
    return "6.2.0-daily.%d" % key.build


def appimage_name_for(key: Key) -> str:
    return "Moonlight-6.2.0-daily.%d-x86_64.AppImage" % key.build
