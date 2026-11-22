#!/usr/bin/env python3
"""``upstream-seen.json`` reader / updater (PLAN R-TRK-3).

Format (JSON, schema 1; an absent or empty file means "nothing seen yet")::

    {
      "schema": 1,
      "upstream": "Nonary/moonlight-qt",
      "entries": {
        "v6.2.0-daily.202": {
          "commit": "<40 hex>", "release_id": 123,
          "published_at": "2026-11-22T07:17:53Z", "first_seen": "2026-11-22T07:23:00Z",
          "builds": [{"n": 1, "series_sha256": "<64 hex>", "branch": "build/v6.2.0-daily.202-n1",
                      "source_sha": "<40 hex>"}]
        }
      }
    }

The *first* commit recorded for a tag is authoritative.  If the tag later
resolves to a different commit, ``record`` raises :class:`TagMoved` and the
caller must halt, alert, and never build (upstream re-pointed a tag).

CLI:
  lock_update.py record     --lock F --repo S --tag T --commit C --release-id N --published-at TS --now TS
  lock_update.py add-build  --lock F --tag T --n N --series-sha H --source-sha C
  lock_update.py check      --lock F --tag T --commit C       (exit 3 = moved)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from typing import Any, Dict

import vpcommon as v

EXIT_MOVED = 3


class TagMoved(Exception):
    """A known upstream tag now resolves to a different commit."""


def empty(repo: str = "Nonary/moonlight-qt") -> Dict[str, Any]:
    return {"schema": 1, "upstream": repo, "entries": {}}


def validate(lock: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(lock, dict) or lock.get("schema") != 1:
        raise v.ValidationError("upstream-seen.json: unsupported schema")
    v.require(v.REPO_SLUG_RE, lock.get("upstream"), "lock upstream")
    entries = lock.get("entries")
    if not isinstance(entries, dict):
        raise v.ValidationError("upstream-seen.json: entries must be an object")
    for tag, ent in entries.items():
        v.upstream_tag(tag)
        if not isinstance(ent, dict):
            raise v.ValidationError("upstream-seen.json: bad entry")
        v.sha1(ent.get("commit"), "lock commit")
        if not isinstance(ent.get("release_id"), int):
            raise v.ValidationError("upstream-seen.json: release_id must be an integer")
        builds = ent.get("builds", [])
        if not isinstance(builds, list):
            raise v.ValidationError("upstream-seen.json: builds must be a list")
        for b in builds:
            n = b.get("n") if isinstance(b, dict) else None
            if not isinstance(n, int) or isinstance(n, bool) or not (1 <= n <= v.MAX_BUILD_N):
                raise v.ValidationError("upstream-seen.json: bad build record")
            v.sha256(b.get("series_sha256"), "lock series sha")
            v.sha1(b.get("source_sha"), "lock source sha")
    return lock


def load(path: str, default_repo: str = "Nonary/moonlight-qt") -> Dict[str, Any]:
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return empty(default_repo)
    with open(path, "r", encoding="utf-8") as fh:
        return validate(json.load(fh))


def dumps(lock: Dict[str, Any]) -> str:
    return json.dumps(lock, indent=2, sort_keys=True) + "\n"


def save(lock: Dict[str, Any], path: str) -> None:
    validate(lock)
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".lock-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(dumps(lock))
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def reference_pin(path: str):
    """Read the Patch Engineer's ``upstream.lock`` and return ``(tag, commit)`` or None.

    The moonlight file is flat ``key: value`` lines (``tag``, ``commit``, ...); the nested
    Vibepollo layout (keys indented under ``upstream:``) is accepted as well.  Anything
    malformed raises.
    """
    if not path or not os.path.exists(path):
        return None
    tag = commit = None
    in_upstream = False
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            if not line.startswith(" "):
                key, _, val = line.strip().partition(":")
                if key == "upstream" and not val.strip():
                    in_upstream = True
                    continue
                in_upstream = False
            elif not in_upstream:
                continue
            key, _, val = line.strip().partition(":")
            if key == "tag":
                tag = val.strip()
            elif key == "commit":
                commit = val.strip()
    if tag is None and commit is None:
        return None
    return v.upstream_tag(tag), v.sha1(commit, "pinned commit")


def last_built_before(lock: Dict[str, Any], tag: str) -> str:
    """Highest tag below ``tag`` that has at least one recorded build ('' if none)."""
    t = v.tag_tuple(tag)
    cands = [k for k, ent in lock["entries"].items() if ent.get("builds") and v.tag_tuple(k) < t]
    return max(cands, key=v.tag_tuple) if cands else ""


def check(lock: Dict[str, Any], tag: str, commit: str) -> str:
    """Return ``'new'`` or ``'same'``; raise :class:`TagMoved` if re-pointed."""
    v.upstream_tag(tag)
    v.sha1(commit)
    ent = lock["entries"].get(tag)
    if ent is None:
        return "new"
    if ent["commit"] != commit:
        raise TagMoved(f"upstream tag {tag} moved: locked {ent['commit']}, now {commit}")
    return "same"


def record(lock: Dict[str, Any], tag: str, commit: str, release_id: int,
           published_at: str, now: str) -> str:
    status = check(lock, tag, commit)
    if status == "new":
        v.require(v.ISO_TS_RE, published_at, "published_at")
        v.require(v.ISO_TS_RE, now, "now")
        lock["entries"][tag] = {"commit": commit, "release_id": int(release_id),
                                "published_at": published_at, "first_seen": now, "builds": []}
    return status


def add_build(lock: Dict[str, Any], tag: str, n: int, series_sha: str, source_sha: str) -> None:
    ent = lock["entries"].get(tag)
    if ent is None:
        raise v.ValidationError("cannot add build for an unrecorded tag")
    for b in ent["builds"]:
        if b["n"] == n:
            raise v.ValidationError("build number already recorded")
    ent["builds"].append({"n": int(n), "series_sha256": v.sha256(series_sha),
                          "branch": v.branch_name(tag, n), "source_sha": v.sha1(source_sha)})
    ent["builds"].sort(key=lambda b: b["n"])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    lb = sub.add_parser("last-built")
    lb.add_argument("--lock", required=True)
    lb.add_argument("--tag", required=True)
    for name in ("record", "add-build", "check"):
        sp = sub.add_parser(name)
        sp.add_argument("--lock", required=True)
        sp.add_argument("--tag", required=True)
        if name in ("record", "check"):
            sp.add_argument("--commit", required=True)
        if name == "record":
            sp.add_argument("--repo", default="Nonary/moonlight-qt")
            sp.add_argument("--release-id", required=True, type=int)
            sp.add_argument("--published-at", required=True)
            sp.add_argument("--now", required=True)
        if name == "add-build":
            sp.add_argument("--n", required=True, type=int)
            sp.add_argument("--series-sha", required=True)
            sp.add_argument("--source-sha", required=True)
    args = ap.parse_args(argv)
    try:
        lock = load(args.lock, getattr(args, "repo", "Nonary/moonlight-qt"))
        if args.cmd == "last-built":
            print(last_built_before(lock, args.tag))
            return 0
        if args.cmd == "check":
            print(check(lock, args.tag, args.commit))
            return 0
        if args.cmd == "record":
            status = record(lock, args.tag, args.commit, args.release_id, args.published_at, args.now)
            if status == "new":
                save(lock, args.lock)
            print(status)
            return 0
        add_build(lock, args.tag, args.n, args.series_sha, args.source_sha)
        save(lock, args.lock)
        return 0
    except TagMoved as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return EXIT_MOVED
    except (v.ValidationError, OSError, json.JSONDecodeError) as exc:
        return v.fail(f"lock_update: {exc}")


if __name__ == "__main__":
    raise SystemExit(main())
