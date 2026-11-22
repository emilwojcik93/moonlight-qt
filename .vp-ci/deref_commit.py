#!/usr/bin/env python3
"""Resolve an upstream tag to the commit SHA it points at (annotated tags too).

``target_commitish`` of a release is NOT authoritative (it can name a branch, not the built
commit).  The authoritative value is the git ref ``refs/tags/<tag>``; if that is an annotated tag object we dereference it
until we reach an object of type ``commit`` (PLAN R-TRK-2).

Library use: ``deref(fetch, tag)`` where ``fetch(path) -> dict`` performs a
GitHub REST ``GET`` (so tests can inject fixtures).

CLI (calls ``gh api``; token comes from the environment, never the command line):
  deref_commit.py --repo Nonary/moonlight-qt --tag v6.2.0-daily.202 [--expect <sha>] [--github-output]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any, Callable, Dict

import vpcommon as v

MAX_DEPTH = 5


def deref(fetch: Callable[[str], Dict[str, Any]], tag: str) -> str:
    v.upstream_tag(tag)
    ref = fetch(f"git/ref/tags/{tag}")
    if not isinstance(ref, dict) or not isinstance(ref.get("object"), dict):
        raise v.ValidationError("unexpected ref payload")
    # The ref name must be exactly what we asked for (defends against a fuzzy
    # prefix match such as the list endpoint returning refs/tags/2.20.0-rc1).
    if ref.get("ref") != f"refs/tags/{tag}":
        raise v.ValidationError("ref payload does not match requested tag")
    obj = ref["object"]
    for _ in range(MAX_DEPTH):
        otype = obj.get("type")
        sha = v.sha1(obj.get("sha"), "object sha")
        if otype == "commit":
            return sha
        if otype != "tag":
            raise v.ValidationError(f"tag points at unsupported object type {otype!r}"[:80])
        tag_obj = fetch(f"git/tags/{sha}")
        if not isinstance(tag_obj, dict) or not isinstance(tag_obj.get("object"), dict):
            raise v.ValidationError("unexpected tag object payload")
        obj = tag_obj["object"]
    raise v.ValidationError("tag chain too deep")


def gh_fetcher(slug: str) -> Callable[[str], Dict[str, Any]]:
    v.require(v.REPO_SLUG_RE, slug, "repo")

    def fetch(path: str) -> Dict[str, Any]:
        proc = subprocess.run(["gh", "api", f"repos/{slug}/{path}"], check=True,
                              capture_output=True, text=True, timeout=60)
        return json.loads(proc.stdout)

    return fetch


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--expect", help="fail unless the commit equals this SHA (lock check)")
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args(argv)
    try:
        sha = deref(gh_fetcher(args.repo), args.tag)
        if args.expect is not None and sha != v.sha1(args.expect, "expected sha"):
            return v.fail("tag no longer resolves to the expected commit")
    except (v.ValidationError, subprocess.SubprocessError, json.JSONDecodeError, OSError) as exc:
        return v.fail(f"deref_commit: {type(exc).__name__}: {str(exc)[:200]}")
    if args.github_output:
        v.write_outputs({"commit": sha})
    else:
        print(sha)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
