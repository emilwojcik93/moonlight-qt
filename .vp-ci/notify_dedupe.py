#!/usr/bin/env python3
"""Suppress a repeated alert: skip when the open alert issue already carries the same marker
(same kind + tag) in its body or a comment created less than ``--window-hours`` ago.

Input is ``gh issue view N --json createdAt,body,comments`` (untrusted JSON; only timestamps
and the exact marker substring are read).  ``--marker-file`` holds the marker written by
``notify_text.py``.  Output: ``suppress=true|false`` (``--github-output``).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from typing import Any, List, Tuple

import vpcommon as v

MARKER_RE = re.compile(r"<!-- ml-alert:kind=[a-z]{1,16};tag=[A-Za-z0-9._()-]{1,64} -->")


def _ts(value: Any) -> Any:
    if not isinstance(value, str) or v.ISO_TS_RE.fullmatch(value) is None:
        return None
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def entries(issue: Any) -> List[Tuple[Any, str]]:
    if not isinstance(issue, dict):
        raise v.ValidationError("issue payload is not an object")
    out = [(_ts(issue.get("createdAt")), str(issue.get("body") or ""))]
    comments = issue.get("comments") or []
    if not isinstance(comments, list):
        raise v.ValidationError("comments payload is not a list")
    for c in comments:
        if isinstance(c, dict):
            out.append((_ts(c.get("createdAt")), str(c.get("body") or "")))
    return out


def suppress(issue: Any, marker: str, now: dt.datetime, window_hours: float = 24.0) -> bool:
    if MARKER_RE.fullmatch(marker) is None:
        raise v.ValidationError("bad marker")
    newest = None
    for ts, body in entries(issue):
        if ts is not None and marker in body and (newest is None or ts > newest):
            newest = ts
    return newest is not None and (now - newest) < dt.timedelta(hours=window_hours)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--issue", required=True)
    ap.add_argument("--marker-file", required=True)
    ap.add_argument("--window-hours", type=float, default=24.0)
    ap.add_argument("--now", default="")
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args(argv)
    try:
        with open(args.issue, "r", encoding="utf-8") as fh:
            issue = json.load(fh)
        with open(args.marker_file, "r", encoding="utf-8") as fh:
            marker = fh.read().strip()
        now = _ts(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
        if now is None:
            raise v.ValidationError("bad --now")
        res = suppress(issue, marker, now, args.window_hours)
    except (v.ValidationError, OSError, json.JSONDecodeError) as exc:
        return v.fail(f"notify_dedupe: {exc}")
    if args.github_output:
        v.write_outputs({"suppress": "true" if res else "false"})
    else:
        print("suppress=" + ("true" if res else "false"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
