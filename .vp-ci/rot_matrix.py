#!/usr/bin/env python3
"""Patch-rot matrix (PLAN R-PAT-3): dry-run the series against the last N upstream dailies.

For each candidate tag: resolve the commit (annotated-tag aware), fetch it into a
scratch clone, ``git am --3way`` the whole series, record pass/fail, reset.  A
markdown table goes to ``--summary``; the exit status is 1 when any tag that is
*not* listed in the known-fail file fails to apply (AC-PAT-2).  Tags below the policy
``x-supported_floor_tag`` are never candidates (``select_release.py --floor``).

Known-fail file: one upstream tag per line, ``#`` comments (``ci/rot-known-fail.txt``).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any, Dict, List

import apply_series as aps
import deref_commit
import vpcommon as v


def read_known_fail(path: str) -> List[str]:
    if not path or not os.path.exists(path):
        return []
    tags = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            tok = line.split("#", 1)[0].strip()
            if tok:
                tags.append(v.upstream_tag(tok))
    return tags


def run(src: str, slug: str, tags: List[str], series_path: str, patches_dir: str,
        known_fail: List[str], fetch_factory=deref_commit.gh_fetcher,
        remote: str = "") -> List[Dict[str, Any]]:
    fetch = fetch_factory(slug)
    remote = remote or f"https://github.com/{slug}.git"
    results = []
    for tag in tags:
        v.upstream_tag(tag)
        row: Dict[str, Any] = {"tag": tag, "commit": "", "status": "error", "known_fail": tag in known_fail}
        try:
            commit = deref_commit.deref(fetch, tag)
            row["commit"] = commit
            aps.git(src, "fetch", "-q", "--no-tags", remote,
                    f"refs/tags/{tag}:refs/tags/rot-{tag}")
            got = aps.git(src, "rev-parse", f"refs/tags/rot-{tag}^{{commit}}").stdout.strip()
            if got != commit:
                row["status"] = "moved"
            else:
                aps.git(src, "checkout", "-q", "--detach", commit)
                aps.git(src, "reset", "-q", "--hard", commit)
                report = os.path.join(src, "..", f"rot-{tag}.md")
                rc = aps.apply(src, commit, series_path, patches_dir, report_path=report)
                row["status"] = {0: "pass", 2: "conflict"}.get(rc, "error")
                aps.git(src, "reset", "-q", "--hard", commit, check=False)
        except (v.ValidationError, subprocess.SubprocessError, OSError, json.JSONDecodeError) as exc:
            row["detail"] = type(exc).__name__
        results.append(row)
    return results


def render(results: List[Dict[str, Any]]) -> str:
    lines = ["| upstream tag | commit | result | note |", "|---|---|---|---|"]
    for r in results:
        note = "known failure" if r["known_fail"] and r["status"] != "pass" else ""
        lines.append(f"| `{r['tag']}` | `{r['commit'][:10]}` | {r['status']} | {note} |")
    return "\n".join(lines) + "\n"


def failing(results: List[Dict[str, Any]]) -> List[str]:
    return [r["tag"] for r in results if r["status"] != "pass" and not r["known_fail"]]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="scratch git repo (any history) used for apply tests")
    ap.add_argument("--repo", default="Nonary/moonlight-qt")
    ap.add_argument("--candidates", required=True, help="JSON from select_release.py --top N")
    ap.add_argument("--series", required=True)
    ap.add_argument("--patches-dir", required=True)
    ap.add_argument("--known-fail", default="")
    ap.add_argument("--summary", required=True)
    args = ap.parse_args(argv)
    try:
        with open(args.candidates, "r", encoding="utf-8") as fh:
            cands = json.load(fh)["candidates"]
        tags = [c["tag"] for c in cands]
        results = run(args.src, args.repo, tags, args.series, args.patches_dir,
                      read_known_fail(args.known_fail))
    except (v.ValidationError, OSError, KeyError, json.JSONDecodeError) as exc:
        return v.fail(f"rot_matrix: {type(exc).__name__}: {str(exc)[:200]}")
    table = render(results)
    with open(args.summary, "a", encoding="utf-8", newline="\n") as fh:
        fh.write("### Patch rot matrix\n\n" + table)
    print(table)
    bad = failing(results)
    if bad:
        return v.fail("series does not apply to: " + ", ".join(bad[:5]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
