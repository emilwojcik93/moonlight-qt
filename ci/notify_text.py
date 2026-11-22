#!/usr/bin/env python3
"""Build sanitized alert text for GChat and the single alert issue.

Nothing attacker-controlled (tag names, run names, commit subjects, API text) is
ever placed in a message verbatim: structured fields are regex-validated; the
free-text ``detail`` is reduced to a conservative ASCII charset and length-capped.
The GChat body is produced with ``json.dumps`` (never string concatenation).

Every issue body carries a hidden marker ``<!-- ml-alert:kind=K;tag=T -->`` that
``notify_dedupe.py`` uses to suppress repeats of the same alert within 24 hours
(a stuck build would otherwise comment on every hourly poll).

Environment (``env:`` in the workflow):
  KIND      failure | success | halt | stuck | deadman | moved
  TAG       optional upstream tag or release tag
  RUN_ID    optional numeric run id
  REPO      owner/repo of this fork (``github.repository``)
  DETAIL    optional short free text (sanitized)
Output files: --gchat FILE (JSON), --issue-body FILE, --marker FILE.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Dict

import vpcommon as v

KINDS = {
    "failure": ("Build failed", True),
    "success": ("Release published", False),
    "halt": ("HALT: upstream tag moved", True),
    "moved": ("HALT: upstream tag moved", True),
    "stuck": ("Build stuck, manual action required", True),
    "deadman": ("Dead-man: no successful upstream check recently", True),
}
FREE_RE = re.compile(r"[^A-Za-z0-9 ._:/#,=+()\-]")
ISSUE_LABEL = "automation-alert"
ISSUE_TITLE = "[automation] moonlight-qt patch pipeline needs attention"
PRODUCT = "moonlight-qt patch pipeline"


def free_text(s: str, limit: int = 200) -> str:
    return FREE_RE.sub("?", s.replace("\r", " ").replace("\n", " "))[:limit]


def marker(kind: str, tag: str) -> str:
    return f"<!-- ml-alert:kind={kind};tag={tag or 'none'} -->"


def compose(env: Dict[str, str]) -> Dict[str, str]:
    kind = env.get("KIND", "")
    if kind not in KINDS:
        raise v.ValidationError("unknown notification kind")
    title, is_alert = KINDS[kind]
    repo = v.require(v.REPO_SLUG_RE, env.get("REPO", ""), "repo")
    tag = env.get("TAG", "")
    if tag:
        if not (v.UPSTREAM_TAG_RE.fullmatch(tag) or v.RELEASE_TAG_RE.fullmatch(tag)):
            tag = "(invalid tag)"
    run_id = env.get("RUN_ID", "")
    run_url = ""
    if run_id:
        v.require(v.RUN_ID_RE, run_id, "run id")
        run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    detail = free_text(env.get("DETAIL", ""))
    parts = [f"{PRODUCT}: {title}"]
    if tag:
        parts.append(f"tag {tag}")
    if detail:
        parts.append(detail)
    if run_url:
        parts.append(run_url)
    text = " | ".join(parts)
    body = [f"**{title}**", ""]
    if tag:
        body.append(f"* tag: `{tag}`")
    if detail:
        body.append(f"* detail: {detail}")
    if run_url:
        body.append(f"* run: {run_url}")
    mark = marker(kind, tag if tag and tag != "(invalid tag)" else "")
    body += ["", "_Automated message; text derived from untrusted sources is sanitized._", "", mark]
    return {"text": text, "issue_title": ISSUE_TITLE, "issue_body": "\n".join(body),
            "alert": "true" if is_alert else "false", "marker": mark}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gchat", required=True)
    ap.add_argument("--issue-body", required=True)
    ap.add_argument("--marker", required=True)
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args(argv)
    env = {k: os.environ.get(k, "") for k in ("KIND", "TAG", "RUN_ID", "REPO", "DETAIL")}
    try:
        out = compose(env)
    except v.ValidationError as exc:
        return v.fail(f"notify_text: {exc}")
    with open(args.gchat, "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"text": out["text"]}, fh)
    with open(args.issue_body, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(out["issue_body"] + "\n")
    with open(args.marker, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(out["marker"] + "\n")
    if args.github_output:
        v.write_outputs({"alert": out["alert"]})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
