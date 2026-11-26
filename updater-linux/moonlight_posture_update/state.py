"""state.json under ~/.local/state/moonlight-posture-updater/.

Never trusted blindly: it is validated on load, a corrupt file is moved aside (not deleted) and rebuilt, and the
installed build used for ordering is max(state, `current` symlink) so a damaged state can never cause a downgrade.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any, Dict, List, Optional

from . import fsio, versioning

SCHEMA = 1
MAX_ATTEMPT_TAGS = 50


def empty_state() -> Dict[str, Any]:
    return {"schema": SCHEMA, "installed": None, "previous": None, "deny": [], "attempts": {},
            "last_check": None, "last_success": None, "last_result": None}


def _valid_record(r: Any) -> bool:
    if r is None:
        return True
    if not isinstance(r, dict):
        return False
    tag = r.get("tag")
    if not versioning.is_tag(tag):
        return False
    try:
        key = versioning.parse_tag(tag)
    except ValueError:
        return False
    if r.get("build") != key.build:
        return False
    sha = r.get("sha256")
    return isinstance(sha, str) and versioning.SHA256_RE.fullmatch(sha) is not None


def validate_state(s: Any) -> bool:
    if not isinstance(s, dict) or s.get("schema") != SCHEMA:
        return False
    if not _valid_record(s.get("installed")) or not _valid_record(s.get("previous")):
        return False
    deny = s.get("deny")
    if not isinstance(deny, list) or not all(versioning.is_tag(x) for x in deny):
        return False
    att = s.get("attempts")
    if not isinstance(att, dict) or len(att) > MAX_ATTEMPT_TAGS:
        return False
    for tag, a in att.items():
        if not versioning.is_tag(tag) or not isinstance(a, dict):
            return False
        for k in ("transient", "verify", "install"):
            if not isinstance(a.get(k, 0), int) or isinstance(a.get(k, 0), bool) or a.get(k, 0) < 0:
                return False
        if not isinstance(a.get("not_before", 0), (int, float)) or isinstance(a.get("not_before", 0), bool):
            return False
    for k in ("last_check", "last_success", "last_result"):
        if s.get(k) is not None and not isinstance(s.get(k), (str, dict)):
            return False
    return True


def load_state(path: str, log=None):
    """Returns (state, corrupt_flag). A corrupt/invalid file is renamed to state.json.corrupt-<ts>."""
    try:
        with open(path, "rb") as f:
            raw = f.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError("state too large")
        s = json.loads(raw.decode("utf-8"))
        if not validate_state(s):
            raise ValueError("state failed validation")
        return s, False
    except FileNotFoundError:
        return empty_state(), False
    except (OSError, ValueError) as e:
        if log:
            log.warn("state_corrupt", detail=str(e)[:100])
        try:
            os.replace(path, "%s.corrupt-%d" % (path, int(time.time())))
        except OSError:
            pass
        return empty_state(), True


def save_state(path: str, state: Dict[str, Any]) -> None:
    if not validate_state(state):
        raise ValueError("refusing to write an invalid state")
    fsio.atomic_write_json(path, state)


def record_for(tag: str, sha256: str) -> Dict[str, Any]:
    key = versioning.parse_tag(tag)
    return {"tag": tag, "build": key.build, "sha256": sha256, "installed_at": None}


# ---- attempts / backoff / deny (Windows P2-6) ---------------------------------------------------------------
# transient (network, gh timeouts): never denies, backoff 15 min * 2^(n-1) up to 6 h
# verify  (hash, attestation, manifest): same backoff, deny after 3
# install (smoke, disk, switch): backoff 1 h * 2^(n-1) up to 6 h, deny after 2
DENY_AFTER = {"verify": 3, "install": 2}


def backoff_seconds(kind: str, n: int) -> int:
    base = 3600 if kind == "install" else 900
    return min(6 * 3600, base * (2 ** max(0, n - 1)))


def in_backoff(state: Dict[str, Any], tag: str, now: float) -> bool:
    a = state["attempts"].get(tag)
    return bool(a) and float(a.get("not_before", 0)) > now


def count_failure(state: Dict[str, Any], tag: str, kind: str, now: float) -> bool:
    """Record a failed attempt; returns True when the tag became denied."""
    atts = state["attempts"]
    a = atts.setdefault(tag, {"transient": 0, "verify": 0, "install": 0, "not_before": 0})
    a[kind] = int(a.get(kind, 0)) + 1
    a["not_before"] = now + backoff_seconds(kind, a[kind])
    denied = False
    if kind in DENY_AFTER and a[kind] >= DENY_AFTER[kind]:
        if tag not in state["deny"]:
            state["deny"].append(tag)
        denied = True
    while len(atts) > MAX_ATTEMPT_TAGS:
        atts.pop(next(iter(atts)))
    return denied


def clear_attempts(state: Dict[str, Any], tag: str) -> None:
    state["attempts"].pop(tag, None)


def denied_tags(state: Dict[str, Any], policy_deny: List[str]) -> set:
    return set(state["deny"]) | set(policy_deny)


def installed_build(state: Dict[str, Any], link_tag: Optional[str]) -> Optional[int]:
    """max(state.installed.build, build derived from the `current` symlink target). None = nothing installed."""
    vals = []
    inst = state.get("installed")
    if inst:
        vals.append(inst["build"])
    if link_tag and versioning.is_tag(link_tag):
        try:
            vals.append(versioning.parse_tag(link_tag).build)
        except ValueError:
            pass
    return max(vals) if vals else None
