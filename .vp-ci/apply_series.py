#!/usr/bin/env python3
"""Apply ``patches/series`` onto the currently checked-out upstream commit.

Strict by design (research/04 threat 4):

* the checkout must be clean and ``HEAD`` must equal ``--base``;
* every patch is applied with ``git am --3way --keep-cr`` (as ``tools/apply-series.sh``) in series
  order, one at a time;
* commit identity and dates are pinned so the resulting tip SHA is reproducible
  (same upstream commit + same patches => same SHA);
* on the first failure the work tree is restored (``git am --abort``), a
  markdown conflict report is written (for the alert issue) and the script exits 2;
* ``--expect-tree`` checks the final tree hash (AC-PAT-1).

Exit codes: 0 applied, 2 conflict (report written), 1 usage/validation/git error.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from typing import List, Optional

import series as series_mod
import vpcommon as v

BOT_NAME = "ml-automation"
BOT_EMAIL = "ml-automation@users.noreply.github.com"
MAX_REPORT_BYTES = 60_000


def git(repo: str, *args: str, env: Optional[dict] = None, check: bool = True) -> subprocess.CompletedProcess:
    full_env = dict(os.environ)
    full_env.update({"GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"})
    if env:
        full_env.update(env)
    # Deterministic, platform independent: no CRLF conversion, no hooks, no signing.
    return subprocess.run(["git", "-C", repo, "-c", "core.autocrlf=false", "-c", "core.safecrlf=false",
                           "-c", "commit.gpgsign=false", *args], capture_output=True, text=True,
                          env=full_env, check=check, timeout=900)


def commit_date(repo: str, commit: str) -> str:
    return git(repo, "show", "-s", "--format=%cI", commit).stdout.strip()


def identity_env(date: str) -> dict:
    return {
        "GIT_COMMITTER_NAME": BOT_NAME, "GIT_COMMITTER_EMAIL": BOT_EMAIL,
        "GIT_AUTHOR_NAME": BOT_NAME, "GIT_AUTHOR_EMAIL": BOT_EMAIL,
        "GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date,
    }


def conflict_report(repo: str, patch: str, applied: List[str], stderr: str) -> str:
    status = git(repo, "status", "--porcelain", check=False).stdout
    conflicted = [ln[3:] for ln in status.splitlines() if ln[:2] in ("UU", "AA", "DU", "UD", "AU", "UA")]
    lines = ["# Patch series failed to apply", "",
             f"* failing patch: `{patch}`",
             f"* patches applied before it: {len(applied)}",
             f"* conflicted files: {', '.join('`%s`' % c for c in conflicted) or '(none reported)'}", "",
             "## git am output", "```", stderr.strip()[:4000], "```", ""]
    for path in conflicted[:10]:
        try:
            with open(os.path.join(repo, path), "r", encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except OSError:
            continue
        hunks = [seg for seg in body.split("<<<<<<<")[1:]][:5]
        lines += [f"## Conflict hunks in `{path}`", "```diff"]
        for h in hunks:
            lines.append("<<<<<<<" + h[:1500])
        lines += ["```", ""]
    text = "\n".join(lines)
    # Markdown fences must not be closable by attacker-controlled upstream text.
    text = text.replace("````", "``` `")
    return text[:MAX_REPORT_BYTES]


def apply(repo: str, base: str, series_path: str, patches_dir: str,
          report_path: Optional[str] = None, expect_tree: Optional[str] = None) -> int:
    v.sha1(base, "base commit")
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    if head != base:
        return v.fail("HEAD is not the expected upstream commit")
    if git(repo, "status", "--porcelain").stdout.strip():
        return v.fail("work tree is not clean")
    entries = [name for name, _ in series_mod.parse(series_path)]
    date = commit_date(repo, base)
    env = identity_env(date)
    applied: List[str] = []
    for name in entries:
        full = os.path.join(patches_dir, name)
        if not os.path.isfile(full):
            return v.fail(f"patch missing: {name}")
        proc = git(repo, "am", "--3way", "--keep-cr", "--no-gpg-sign", "--keep-non-patch", os.path.abspath(full),
                   env=env, check=False)
        if proc.returncode != 0:
            report = conflict_report(repo, name, applied, proc.stderr + proc.stdout)
            abort = git(repo, "am", "--abort", check=False)
            if abort.returncode != 0:
                detail = " ".join(abort.stderr.split())[:300]
                print("::warning::git am --abort failed: " + detail, file=sys.stderr)
            git(repo, "reset", "--hard", base, check=False)
            git(repo, "clean", "-fdq", check=False)
            # Belt and braces: a leftover rebase-apply directory would break the next run.
            leftover = git(repo, "rev-parse", "--git-path", "rebase-apply", check=False).stdout.strip()
            if leftover:
                leftover = leftover if os.path.isabs(leftover) else os.path.join(repo, leftover)
                if os.path.isdir(leftover):
                    shutil.rmtree(leftover, ignore_errors=True)
            if report_path:
                with open(report_path, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(report)
            print(f"::error::patch {name} failed to apply (see conflict report)", file=sys.stderr)
            return 2
        applied.append(name)
    tree = git(repo, "rev-parse", "HEAD^{tree}").stdout.strip()
    if expect_tree is not None and tree != v.sha1(expect_tree, "expected tree"):
        return v.fail("resulting tree differs from the expected reference tree")
    print(f"applied {len(applied)} patches; tip={git(repo, 'rev-parse', 'HEAD').stdout.strip()} tree={tree}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, help="upstream work tree (HEAD == --base)")
    ap.add_argument("--base", required=True, help="upstream commit SHA")
    ap.add_argument("--series", required=True)
    ap.add_argument("--patches-dir", required=True)
    ap.add_argument("--report")
    ap.add_argument("--expect-tree")
    args = ap.parse_args(argv)
    try:
        return apply(args.repo, args.base, args.series, args.patches_dir, args.report, args.expect_tree)
    except (v.ValidationError, subprocess.SubprocessError, OSError) as exc:
        return v.fail(f"apply_series: {type(exc).__name__}: {str(exc)[:200]}")


if __name__ == "__main__":
    raise SystemExit(main())
