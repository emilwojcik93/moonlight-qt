#!/usr/bin/env python3
"""Turn "upstream commit + applied patches" into the pushable build branch tip.

Run after ``apply_series.py``.  Steps (all on the already-patched work tree):

1. guard: the patches must not touch submodule gitlinks, ``.gitmodules``, ``.github/``, the
   installer / packaging / dependency-fetch surface (``wix/``, ``scripts/``, ``app/deploy/``,
   ``setup-deps.*``)
   or the version file (PLAN R-PAT-2: the pipeline owns every version and CI file);
2. strip EVERYTHING under ``.github/`` except upstream's reusable ``build-win-mac.yml`` and
   ``build-appimage.yml`` (upstream ``push``/``schedule`` workflows would otherwise run inside
   *our* repository on every pushed build branch) and remove their ``workflow_dispatch`` trigger,
   so each kept file is ``workflow_call`` only (fail closed if it is not);
3. install the wrapper workflow template and the ``ci/`` helper scripts
   (as ``.vp-ci/``) and write ``.vp-ci/build-meta.json``;
4. make one deterministic commit.

Exit 0 and prints the new tip SHA; exit 1 on guard/validation failure.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from typing import Any, Dict, List

import apply_series as ap_mod
import vpcommon as v
import workflow_check

BUILD_WORKFLOW = "build-win-mac.yml"
APPIMAGE_WORKFLOW = "build-appimage.yml"  # Linux AppImage, kept next to the Windows build (CONTRACT v1.2)
KEEP_WORKFLOWS = {BUILD_WORKFLOW, APPIMAGE_WORKFLOW}
WRAPPER_NAME = "patched-windows-release.yml"
FORBIDDEN_PATCH_PATHS = (
    ".github/", ".gitmodules", "wix/", "scripts/", "setup-deps.ps1", "setup-deps.py", "libs/",
    "app/version.txt",
    # app/deploy/linux/appimage/*.patch is applied to a dependency checkout by build-appimage.yml
    "app/deploy/",
    # submodule work trees (gitlinks are rejected independently of the path)
    "moonlight-common-c/", "qmdnsengine/", "h264bitstream/", "app/SDL_GameControllerDB",
)


def guard_patch_paths(repo: str, base: str) -> List[str]:
    """Return offending paths touched between ``base`` and HEAD."""
    out = ap_mod.git(repo, "diff", "--raw", "--no-renames", "-z", f"{base}", "HEAD").stdout
    bad: List[str] = []
    fields = out.split("\0")
    i = 0
    while i + 1 < len(fields) and fields[i]:
        meta, path = fields[i], fields[i + 1]
        i += 2
        modes = meta.lstrip(":").split(" ")[:2]
        if "160000" in modes or path.startswith(FORBIDDEN_PATCH_PATHS) or path in FORBIDDEN_PATCH_PATHS:
            bad.append(path)
    return bad


def strip_github(repo: str) -> List[str]:
    """Remove every tracked file below ``.github/`` except the reusable build workflows."""
    keep = {f".github/workflows/{name}" for name in KEEP_WORKFLOWS}
    listed = ap_mod.git(repo, "ls-files", "-z", "--", ".github").stdout.split("\0")
    removed: List[str] = []
    for path in sorted(p for p in listed if p):
        if path in keep:
            continue
        ap_mod.git(repo, "rm", "-q", "-f", "--", path)
        removed.append(path)
    # ignored / untracked leftovers (e.g. an empty directory) must not survive either
    gh = os.path.join(repo, ".github")
    keep_abs = {os.path.join(repo, k).replace("\\", "/") for k in keep}
    if os.path.isdir(gh):
        for root, dirs, files in os.walk(gh):
            for name in files:
                if os.path.join(root, name).replace("\\", "/") not in keep_abs:
                    os.unlink(os.path.join(root, name))
    return removed


def prepare_build_workflow(repo: str) -> None:
    """Drop ``workflow_dispatch`` from each kept reusable workflow and require ``workflow_call`` only."""
    for name in sorted(KEEP_WORKFLOWS):
        path = os.path.join(repo, ".github", "workflows", name)
        if not os.path.isfile(path) or os.path.islink(path):
            raise v.ValidationError(f"upstream {name} is missing")
        with open(path, "r", encoding="utf-8", newline="") as fh:
            text = fh.read()
        new = workflow_check.drop_workflow_dispatch(text)
        if new != text:
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(new)
        workflow_check.require_workflow_call_only(path)  # fail closed on any other trigger


def sensitive_block(args: argparse.Namespace) -> Dict[str, Any]:
    """Sanitized list of sensitive upstream paths touched since the previous release."""
    paths: List[str] = []
    if getattr(args, "sensitive_file", ""):
        with open(args.sensitive_file, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                p = line.strip()
                if p.startswith("- `") and p.endswith("`"):
                    p = p[3:-1]
                if p and not p.startswith("- ..."):
                    paths.append("".join(c if 32 <= ord(c) < 127 else "?" for c in p)[:200])
    since = getattr(args, "sensitive_since", "") or ""
    if since:
        v.upstream_tag(since)
    return {"since": since, "count": int(args.sensitive_count), "paths": paths[:50],
            "enforced": args.gate == "approval"}


def build_meta(args: argparse.Namespace, patch_commits: int) -> Dict[str, Any]:
    import version_map

    tag = v.upstream_tag(args.tag)
    n_eff = max(args.n, 1)
    ver = version_map.compute(tag, n_eff)
    return {
        "schema": 1,
        "upstream": {"owner": args.repo_slug.split("/")[0], "repo": args.repo_slug.split("/")[1],
                     "tag": tag, "commit": v.sha1(args.base), "release_id": int(args.release_id),
                     "published_at": v.require(v.ISO_TS_RE, args.published_at, "published_at")},
        "build": {"n": n_eff, "release_tag": ver["release_tag"], "version": ver["build_version"],
                  "build_number": int(ver["build_number"]), "file_version": ver["file_version"],
                  "branch": args.branch, "trial": bool(args.trial)},
        "patches": {"series_sha256": v.sha256(args.series_sha), "count": int(args.patch_count),
                    "groups": [g for g in args.groups.split(",") if g]},
        "patch_commits": patch_commits,
        "gate": args.gate,
        "sensitive_count": int(args.sensitive_count),
        "sensitive": sensitive_block(args),
    }


def assemble(args: argparse.Namespace) -> int:
    repo = args.repo
    v.require(v.REPO_SLUG_RE, args.repo_slug, "upstream repo")
    if args.gate not in ("auto", "approval"):
        return v.fail("gate must be auto or approval")
    bad = guard_patch_paths(repo, args.base)
    if bad:
        return v.fail("patch series touches protected paths: " + ", ".join(bad[:5]))
    patch_commits = int(ap_mod.git(repo, "rev-list", "--count", f"{args.base}..HEAD").stdout.strip())

    strip_github(repo)
    wf_dir = os.path.join(repo, ".github", "workflows")
    prepare_build_workflow(repo)
    os.makedirs(wf_dir, exist_ok=True)
    template = os.path.join(args.ci_dir, "wrapper", WRAPPER_NAME)
    if not os.path.isfile(template):
        return v.fail("wrapper template missing")
    shutil.copyfile(template, os.path.join(wf_dir, WRAPPER_NAME))

    vp = os.path.join(repo, ".vp-ci")
    if os.path.exists(vp):
        shutil.rmtree(vp)
    os.makedirs(vp)
    for name in sorted(os.listdir(args.ci_dir)):
        if name.endswith(".py"):
            shutil.copyfile(os.path.join(args.ci_dir, name), os.path.join(vp, name))
    meta = build_meta(args, patch_commits)
    with open(os.path.join(vp, "build-meta.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(meta, fh, indent=2, sort_keys=True)
        fh.write("\n")

    ap_mod.git(repo, "add", "-A", "--", ".github", ".vp-ci")
    date = ap_mod.commit_date(repo, args.base)
    env = ap_mod.identity_env(date)
    msg = (f"build: wrapper workflow and metadata for {args.tag}-vp.{max(args.n, 1)}\n\n"
           f"upstream-commit: {args.base}\nseries-sha256: {args.series_sha}\n")
    ap_mod.git(repo, "commit", "--no-gpg-sign", "-q", "-m", msg, env=env)
    tip = ap_mod.git(repo, "rev-parse", "HEAD").stdout.strip()
    present = set(os.listdir(wf_dir))
    if present != KEEP_WORKFLOWS | {WRAPPER_NAME}:
        return v.fail("unexpected workflow set after stripping")
    leftovers = [p for p in ap_mod.git(repo, "ls-files", "--", ".github").stdout.split("\n") if p]
    if sorted(leftovers) != sorted(f".github/workflows/{n}" for n in KEEP_WORKFLOWS | {WRAPPER_NAME}):
        return v.fail("unexpected files below .github after stripping")
    print(tip)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--ci-dir", required=True, help="directory holding ci/*.py and ci/wrapper/")
    ap.add_argument("--base", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--n", required=True, type=int)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--repo-slug", default="Nonary/moonlight-qt")
    ap.add_argument("--release-id", required=True, type=int)
    ap.add_argument("--published-at", required=True)
    ap.add_argument("--series-sha", required=True)
    ap.add_argument("--patch-count", required=True, type=int)
    ap.add_argument("--groups", default="posture-core")
    ap.add_argument("--gate", default="auto")
    ap.add_argument("--sensitive-count", default="0")
    ap.add_argument("--sensitive-file", default="", help="file listing sensitive upstream paths (one per line)")
    ap.add_argument("--sensitive-since", default="", help="previous upstream tag the diff was taken against")
    ap.add_argument("--trial", action="store_true")
    args = ap.parse_args(argv)
    try:
        return assemble(args)
    except (v.ValidationError, subprocess.SubprocessError, OSError, ValueError) as exc:
        return v.fail(f"assemble_build: {type(exc).__name__}: {str(exc)[:200]}")


if __name__ == "__main__":
    raise SystemExit(main())
