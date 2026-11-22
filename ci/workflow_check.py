#!/usr/bin/env python3
"""Minimal trigger inspection of a GitHub Actions workflow file (no YAML library needed).

Used to prove that the upstream ``build-win-mac.yml`` we keep in every build branch is a pure
reusable workflow: its ``on:`` block may contain ``workflow_call`` and nothing else.  An upstream
edit adding ``push`` / ``pull_request`` / ``schedule`` would otherwise run unattended upstream code
in our repository (fail closed instead).

Upstream ships ``build-win-mac.yml`` with BOTH ``workflow_call`` and ``workflow_dispatch``;
``drop_workflow_dispatch`` removes the dispatch block (a deterministic text transform applied by
``assemble_build.py``) so that the kept file ends up ``workflow_call`` only.

Supported shapes of the top-level ``on`` key::

    on: push                      on: [push, workflow_call]
    on: {push: {}, workflow_call: {}}
    on:
      workflow_call:
        inputs: ...
      push:
"""
from __future__ import annotations

import re
import sys
from typing import Set

import vpcommon as v

KEY_RE = re.compile(r"""^(?:on|"on"|'on'|true)\s*:\s*(.*)$""")


def triggers(text: str) -> Set[str]:
    lines = text.replace("\r\n", "\n").split("\n")
    for i, raw in enumerate(lines):
        m = KEY_RE.match(raw)  # top-level key: no indentation allowed
        if not m:
            continue
        inline = m.group(1).split("#", 1)[0].strip()
        if inline:
            if inline.startswith("[") and inline.endswith("]"):
                return {p.strip().strip("'\"") for p in inline[1:-1].split(",") if p.strip()}
            if inline.startswith("{") and inline.endswith("}"):
                return {p.split(":", 1)[0].strip().strip("'\"") for p in _split_flow(inline[1:-1])}
            return {inline.strip("'\"")}
        found: Set[str] = set()
        indent = None
        for nxt in lines[i + 1:]:
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                continue
            cur = len(nxt) - len(nxt.lstrip(" "))
            if cur == 0:
                break
            if indent is None:
                indent = cur
            if cur == indent:
                km = re.match(r"""\s*(?:-\s*)?['"]?([A-Za-z_][A-Za-z0-9_-]*)['"]?\s*:""", nxt)
                if km:
                    found.add(km.group(1))
                else:
                    lm = re.match(r"\s*-\s*['\"]?([A-Za-z_][A-Za-z0-9_-]*)['\"]?\s*$", nxt)
                    if lm:
                        found.add(lm.group(1))
        return found
    raise v.ValidationError("workflow has no top-level on: block")


def _split_flow(body: str):
    depth, cur, out = 0, "", []
    for ch in body:
        if ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def drop_workflow_dispatch(text: str) -> str:
    """Remove the ``workflow_dispatch:`` child of a block-style top-level ``on:`` mapping.

    Returns the text unchanged when there is nothing to remove or the ``on:`` block is not in
    block style (callers re-check with ``triggers`` and fail closed on anything unexpected).
    """
    lines = text.replace("\r\n", "\n").split("\n")
    for i, raw in enumerate(lines):
        m = KEY_RE.match(raw)
        if not m or m.group(1).split("#", 1)[0].strip():
            continue
        out = lines[:i + 1]
        child_indent = None
        skipping = False
        for nxt in lines[i + 1:]:
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                if not skipping:
                    out.append(nxt)
                continue
            cur = len(nxt) - len(nxt.lstrip(" "))
            if cur == 0:  # next top-level key: the on: block ended
                skipping = False
                child_indent = -1
                out.append(nxt)
                continue
            if child_indent == -1:  # after the on: block
                out.append(nxt)
                continue
            if child_indent is None:
                child_indent = cur
            if cur == child_indent:
                skipping = bool(re.match(r"""\s*['"]?workflow_dispatch['"]?\s*:""", nxt))
            if not skipping:
                out.append(nxt)
        return "\n".join(out)
    return text


def require_workflow_call_only(path: str) -> None:
    with open(path, "r", encoding="utf-8") as fh:
        found = triggers(fh.read())
    if found != {"workflow_call"}:
        shown = ",".join(sorted(t for t in found if re.fullmatch(r"[a-z_]{1,40}", t))) or "unrecognised"
        raise v.ValidationError(f"upstream reusable workflow triggers must be workflow_call only, found: {shown}")


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        return v.fail("usage: workflow_check.py <workflow.yml>", 2)
    try:
        require_workflow_call_only(argv[0])
    except (v.ValidationError, OSError) as exc:
        return v.fail(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
