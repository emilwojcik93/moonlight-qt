#!/usr/bin/env python3
"""Validate untrusted tag / branch / id strings.  Exit 0 = valid, 1 = invalid.

Usage:
  validate_tag.py upstream-tag  <value>
  validate_tag.py release-tag   <value>
  validate_tag.py build-branch  <value>
  validate_tag.py sha1          <value>
  validate_tag.py run-id        <value>
  validate_tag.py repo-slug     <value>

The value is a positional argument (callers pass it from an ``env:`` variable
inside double quotes, never via ``${{ }}`` interpolation).  Nothing is printed
on success; on failure a short annotation without the raw value is printed.
"""
from __future__ import annotations

import sys

import vpcommon as v

KINDS = {
    "upstream-tag": v.UPSTREAM_TAG_RE,
    "release-tag": v.RELEASE_TAG_RE,
    "build-branch": v.BUILD_BRANCH_RE,
    "sha1": v.SHA1_RE,
    "sha256": v.SHA256_RE,
    "run-id": v.RUN_ID_RE,
    "repo-slug": v.REPO_SLUG_RE,
    "asset-name": v.ASSET_NAME_RE,
}


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] not in KINDS:
        return v.fail("usage: validate_tag.py <%s> <value>" % "|".join(KINDS), 2)
    try:
        v.require(KINDS[argv[0]], argv[1], argv[0])
    except v.ValidationError as exc:
        return v.fail(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
