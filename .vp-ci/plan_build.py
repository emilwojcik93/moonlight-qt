#!/usr/bin/env python3
"""Decide what ``upstream-watch`` must do for the selected upstream release.

Pure function of its inputs (all validated), so every branch is unit-tested.

Actions
-------
``hold``      policy.yml ``hold: true`` or repo variable HOLD=true (and no override)
``halt``      upstream tag moved vs ``upstream-seen.json``
``noop``      already built / build in flight / retries exhausted / older than latest seen /
              build counter exhausted (N would exceed 8: ``stuck`` alert, CONTRACT 3b)
``build``     create ``build/<tag>-n<N>`` and let its push start the wrapper
``rerun``     an earlier attempt for the same series failed: re-run the failed run

Inputs
------
lock          parsed ``upstream-seen.json`` (see lock_update.py)
our_releases  JSON array from ``GET /repos/<fork>/releases`` (drafts included)
runs          JSON array from ``gh run list --workflow patched-windows-release.yml
              --json databaseId,headBranch,status,conclusion``
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any, Dict, List, Optional

import vpcommon as v

IN_FLIGHT = {"queued", "in_progress", "waiting", "pending", "requested"}
# Total attempts per build branch (first run + automatic re-runs, counting the ``attempt``
# field of every run: ``gh run rerun`` re-uses the run id and only bumps ``attempt``).
MAX_TOTAL_ATTEMPTS = 3
RETRYABLE = {"failure", "timed_out", "startup_failure"}


def _published_ns(our_releases: Any, tag: str) -> List[int]:
    out: List[int] = []
    if not isinstance(our_releases, list):
        raise v.ValidationError("releases payload is not an array")
    pat = re.compile(re.escape(tag) + r"-vp\.([1-9][0-9]{0,2})")
    for rel in our_releases:
        if not isinstance(rel, dict) or rel.get("draft") is not False:
            continue
        name = rel.get("tag_name")
        if not isinstance(name, str):
            continue
        m = pat.fullmatch(name)
        if m:
            out.append(int(m.group(1)))
    return sorted(set(out))


def _clean(text: str, limit: int = 200) -> str:
    """Reduce free text to the charset accepted by ``$GITHUB_OUTPUT`` writers."""
    return re.sub(r"[^A-Za-z0-9._/@:+=, -]", " ", text)[:limit]


def total_attempts(branch_runs: List[Dict[str, Any]]) -> int:
    total = 0
    for r in branch_runs:
        try:
            att = int(r.get("attempt") or 1)
        except (TypeError, ValueError):
            att = 1
        total += max(1, min(att, 50))
    return total


def _runs_for(runs: Any, branch: str) -> List[Dict[str, Any]]:
    if not isinstance(runs, list):
        raise v.ValidationError("runs payload is not an array")
    return [r for r in runs if isinstance(r, dict) and r.get("headBranch") == branch]


def plan(*, tag: str, commit: str, lock: Dict[str, Any], our_releases: Any, runs: Any,
         series_sha: str, hold: bool = False, override_hold: bool = False,
         force_rebuild: bool = False, manual_tag: bool = False,
         pin: Any = None) -> Dict[str, Any]:
    v.upstream_tag(tag)
    v.sha1(commit)
    v.sha256(series_sha, "series sha")
    result: Dict[str, Any] = {"action": "noop", "n": 0, "reason": "", "record_lock": False,
                              "rerun_run_id": 0, "stuck": False}

    if hold and not override_hold:
        result.update(action="hold", reason="hold is set (policy.yml or HOLD variable)")
        return result

    if pin is not None and pin[0] == tag and pin[1] != commit:
        result.update(action="halt", reason="upstream tag moved relative to the pinned upstream.lock")
        return result

    entry = lock["entries"].get(tag)
    if entry is not None and entry["commit"] != commit:
        result.update(action="halt", reason="upstream tag moved relative to upstream-seen.json")
        return result

    if not manual_tag:
        newest = max((v.tag_tuple(t) for t in lock["entries"]), default=None)
        if newest is not None and v.tag_tuple(tag) < newest:
            result.update(reason="selected release is older than the newest release already seen")
            return result

    published = _published_ns(our_releases, tag)
    builds = list(entry["builds"]) if entry else []
    result["record_lock"] = entry is None

    if entry is None and published and not force_rebuild:
        result.update(stuck=True,
                      reason="a release for this upstream tag exists but upstream-seen.json has no entry - manual action required")
        return result

    same = [b for b in builds if b["series_sha256"] == series_sha]
    if same and not force_rebuild:
        latest = max(same, key=lambda b: b["n"])
        if latest["n"] in published:
            result.update(n=latest["n"], reason="already built and published")
            return result
        branch = v.branch_name(tag, latest["n"])
        branch_runs = _runs_for(runs, branch)
        if any(r.get("status") in IN_FLIGHT for r in branch_runs):
            result.update(n=latest["n"], reason="build in flight")
            return result
        attempts = total_attempts(branch_runs)
        if attempts >= MAX_TOTAL_ATTEMPTS:
            result.update(n=latest["n"], stuck=True,
                          reason=f"build failed {attempts} times - manual action required")
            return result
        completed = [r for r in branch_runs if r.get("status") == "completed"]
        if not completed:
            # Branch recorded but no run was ever seen: the push did not trigger (or runs aged
            # out).  Treat as stuck rather than pushing again.
            result.update(n=latest["n"], stuck=True,
                          reason="build branch recorded but no run found - manual action required")
            return result
        last = max(completed, key=lambda r: int(r.get("databaseId", 0) or 0))
        if last.get("conclusion") not in RETRYABLE:
            result.update(n=latest["n"], stuck=True,
                          reason=f"last run ended {_clean(str(last.get('conclusion')), 20)} without a release - manual action required")
            return result
        result.update(action="rerun", n=latest["n"], rerun_run_id=int(last.get("databaseId", 0)),
                      reason=f"attempt {attempts} did not publish - re-running failed jobs")
        return result

    n = max([b["n"] for b in builds] + published + [0]) + 1
    if n > v.MAX_BUILD_N:
        # CONTRACT 3b: the build number encoding allows only N = 1..8 per upstream daily.  Never build
        # beyond it (the FileVersion would collide with the next daily); alert until the next upstream release.
        result.update(stuck=True, n=n - 1,
                      reason="rebuild counter exhausted for this upstream daily (max 8) - wait for the next upstream release")
        return result
    result.update(action="build", n=n,
                  reason="new upstream release" if not builds and not published
                  else "patch series changed or rebuild forced")
    return result


def _bool(s: str) -> bool:
    return s.strip().lower() == "true"


def main(argv=None) -> int:
    import lock_update

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--lock", required=True)
    ap.add_argument("--our-releases", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--series-sha", required=True)
    ap.add_argument("--hold", default="false")
    ap.add_argument("--override-hold", default="false")
    ap.add_argument("--force-rebuild", default="false")
    ap.add_argument("--manual-tag", default="false")
    ap.add_argument("--pin-file", default="", help="Patch Engineer's upstream.lock (reference pin)")
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args(argv)
    try:
        lock = lock_update.load(args.lock)
        pin = lock_update.reference_pin(args.pin_file)
        with open(args.our_releases, "r", encoding="utf-8") as fh:
            rels = json.load(fh)
        with open(args.runs, "r", encoding="utf-8") as fh:
            runs = json.load(fh)
        res = plan(tag=args.tag, commit=args.commit, lock=lock, our_releases=rels, runs=runs,
                   series_sha=args.series_sha, hold=_bool(args.hold),
                   override_hold=_bool(args.override_hold), force_rebuild=_bool(args.force_rebuild),
                   manual_tag=_bool(args.manual_tag), pin=pin)
        print(json.dumps(res, sort_keys=True))
        if args.github_output:
            v.write_outputs({"action": res["action"], "n": str(res["n"]),
                             "reason": _clean(res["reason"]),
                             "record_lock": "true" if res["record_lock"] else "false",
                             "rerun_run_id": str(res["rerun_run_id"]),
                             "stuck": "true" if res["stuck"] else "false"})
    except (v.ValidationError, OSError, json.JSONDecodeError) as exc:
        return v.fail(f"plan_build: {exc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
