#!/usr/bin/env python3
"""Minimal, strict reader for ``policy.yml`` (CONTRACT section 5).

PyYAML is not guaranteed on runners, so this parses only the documented shape
(top-level ``key: value`` lines; values are bool / int / ``[a, b]`` flow
lists / ``{k: v}`` flow maps; ``#`` comments).  Anything else raises, i.e. the
pipeline fails closed on a malformed policy instead of ignoring it.
"""
from __future__ import annotations

import argparse
import re
from typing import Any, Dict, List

import vpcommon as v

# Extension keys ("x-" prefix, e.g. x-supported_floor_tag) are ignored by consumers; anything else must be a plain key.
KEY_RE = re.compile(r"(?:x-)?[a-z][a-z0-9_]{0,40}")
SCALAR_RE = re.compile(r"[A-Za-z0-9._-]{1,100}")


def _scalar(tok: str) -> Any:
    tok = tok.strip()
    if tok in ("true", "True"):
        return True
    if tok in ("false", "False"):
        return False
    if re.fullmatch(r"-?[0-9]{1,9}", tok):
        return int(tok)
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "'\"":
        tok = tok[1:-1]
    if SCALAR_RE.fullmatch(tok) is None:
        raise v.ValidationError("policy: unsupported scalar")
    return tok


def _split_top(body: str) -> List[str]:
    return [p for p in (s.strip() for s in body.split(",")) if p != ""]


def _value(text: str) -> Any:
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        return [_scalar(p) for p in _split_top(text[1:-1])]
    if text.startswith("{") and text.endswith("}"):
        out: Dict[str, Any] = {}
        for part in _split_top(text[1:-1]):
            if ":" not in part:
                raise v.ValidationError("policy: bad flow map")
            k, val = part.split(":", 1)
            k = k.strip()
            v.require(KEY_RE, k, "policy key")
            out[k] = _scalar(val)
        return out
    return _scalar(text)


def parse(text: str) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line[0] in " \t":
            raise v.ValidationError("policy: indented/nested YAML is not supported")
        if ":" not in line:
            raise v.ValidationError("policy: expected 'key: value'")
        key, val = line.split(":", 1)
        v.require(KEY_RE, key.strip(), "policy key")
        result[key.strip()] = _value(val)
    if result.get("schema") != 1:
        raise v.ValidationError("policy: unsupported schema")
    owners = result.get("allow_upstream_owners")
    if not isinstance(owners, list) or not owners:
        raise v.ValidationError("policy: allow_upstream_owners must be a non-empty list")
    for o in owners:
        v.require(v.OWNER_RE, o, "policy owner")
    if not isinstance(result.get("hold", False), bool):
        raise v.ValidationError("policy: hold must be a boolean")
    deny = result.get("deny", [])
    if not isinstance(deny, list):
        raise v.ValidationError("policy: deny must be a list")
    for t in deny:
        v.release_tag(t)
    floor = result.get("x-supported_floor_tag")
    if floor is not None:
        v.upstream_tag(floor)
    return result


def load(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        return parse(fh.read())


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--policy", default="policy.yml")
    ap.add_argument("--github-output", action="store_true")
    args = ap.parse_args(argv)
    try:
        pol = load(args.policy)
    except (v.ValidationError, OSError) as exc:
        return v.fail(f"policy: {exc}")
    outs = {"hold": "true" if pol.get("hold") else "false",
            "allow_owners": ",".join(pol["allow_upstream_owners"]),
            "keep_releases": str(pol.get("keep_releases", 10)),
            "floor_tag": str(pol.get("x-supported_floor_tag", ""))}
    if args.github_output:
        v.write_outputs(outs)
    else:
        for k, val in outs.items():
            print(f"{k}={val}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
