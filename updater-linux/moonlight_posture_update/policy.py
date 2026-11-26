"""Local policy: ~/.config/moonlight-posture-updater/policy.json with defaults baked in.

Strict: unknown key, wrong type or an out-of-range value makes the whole file invalid (fail closed, exit 3).
There is no test mode: paths, endpoints and executables are constants of the code (tests substitute them in memory).
The local file can only NARROW the baked-in allow-lists (it can never add a repository or an upstream owner).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Tuple

from . import fsio, versioning
from .errors import ConfigError

# Baked-in allow-lists. Widening them means editing the code (reviewed commit), not a config file.
ALLOWED_REPOS = ("emilwojcik93/moonlight-qt",)
ALLOWED_UPSTREAM_OWNERS = ("Nonary",)
SIGNER_WORKFLOW_PATH = ".github/workflows/patched-windows-release.yml"
CHANNEL_COOLING = {"canary": 0, "stable": 24}   # CONTRACT section 5 defaults

DEFAULTS: Dict[str, Any] = {
    "repo": ALLOWED_REPOS[0],
    "upstream_owners": list(ALLOWED_UPSTREAM_OWNERS),
    "channel": "canary",
    "cooling_off_hours": 2,
    "min_cooling_off_hours": 2,     # local FLOOR; the owner may lower it deliberately
    "min_build": 0,                 # never install a build below this number
    "hold": False,
    "deny": [],
    "smoke_test": "display",        # "display": run `--version` (needs a display) | "static": extract + inspect
    "max_appimage_mb": 250,
    "keep_previous": 1,
}

REPO_RE_PARTS = ("[A-Za-z0-9][A-Za-z0-9-]{0,38}", "[A-Za-z0-9._-]{1,100}")


@dataclass
class Policy:
    repo: str = DEFAULTS["repo"]
    upstream_owners: List[str] = field(default_factory=lambda: list(ALLOWED_UPSTREAM_OWNERS))
    channel: str = "canary"
    cooling_off_hours: float = 2
    min_cooling_off_hours: float = 2
    min_build: int = 0
    hold: bool = False
    deny: List[str] = field(default_factory=list)
    smoke_test: str = "display"
    max_appimage_mb: int = 250
    keep_previous: int = 1

    @property
    def signer_workflow(self) -> str:
        return "%s/%s" % (self.repo, SIGNER_WORKFLOW_PATH)

    def effective_cooling_hours(self) -> float:
        return max(float(self.min_cooling_off_hours), float(self.cooling_off_hours),
                   float(CHANNEL_COOLING[self.channel]))

    def to_dict(self) -> Dict[str, Any]:
        return {k: getattr(self, k) for k in DEFAULTS}


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v: Any) -> bool:
    return (isinstance(v, (int, float)) and not isinstance(v, bool)) and v == v and v not in (float("inf"), float("-inf"))


def _no_dups(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    d: Dict[str, Any] = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key")
        d[k] = v
    return d


def _bad_const(_c: str) -> Any:
    raise ValueError("non-finite number")


def parse_policy(data: Dict[str, Any]) -> Policy:
    """Validate a decoded policy mapping (keys optional; unknown keys invalid)."""
    if not isinstance(data, dict):
        raise ConfigError("policy must be a JSON object")
    unknown = sorted(set(data) - set(DEFAULTS) - {"schema"})
    if unknown:
        raise ConfigError("policy has unknown key(s): %s" % ", ".join(unknown)[:120])
    if "schema" in data and data["schema"] != 1:
        raise ConfigError("policy schema must be 1")
    p = Policy()
    if "repo" in data:
        if data["repo"] not in ALLOWED_REPOS:
            raise ConfigError("policy repo is not in the baked-in allow-list")
        p.repo = data["repo"]
    if "upstream_owners" in data:
        v = data["upstream_owners"]
        if (not isinstance(v, list) or not v or not all(isinstance(x, str) for x in v)
                or any(x not in ALLOWED_UPSTREAM_OWNERS for x in v)):
            raise ConfigError("policy upstream_owners must be a non-empty subset of the baked-in list")
        p.upstream_owners = list(dict.fromkeys(v))
    if "channel" in data:
        if data["channel"] not in CHANNEL_COOLING:
            raise ConfigError("policy channel must be canary or stable")
        p.channel = data["channel"]
    for key, lo, hi in (("cooling_off_hours", 0, 24 * 90), ("min_cooling_off_hours", 0, 24 * 90)):
        if key in data:
            v = data[key]
            if not _is_num(v) or v < lo or v > hi:
                raise ConfigError("policy %s must be a number in %d..%d" % (key, lo, hi))
            setattr(p, key, v)
    if "min_build" in data:
        v = data["min_build"]
        if not _is_int(v) or v < 0 or v > versioning.MAX_BUILD:
            raise ConfigError("policy min_build out of range")
        p.min_build = v
    if "hold" in data:
        if not isinstance(data["hold"], bool):
            raise ConfigError("policy hold must be a boolean")
        p.hold = data["hold"]
    if "deny" in data:
        v = data["deny"]
        if not isinstance(v, list) or len(v) > 200 or not all(versioning.is_tag(x) for x in v):
            raise ConfigError("policy deny must be a list of canonical tags")
        p.deny = list(dict.fromkeys(v))
    if "smoke_test" in data:
        if data["smoke_test"] not in ("display", "static"):
            raise ConfigError("policy smoke_test must be display or static")
        p.smoke_test = data["smoke_test"]
    if "max_appimage_mb" in data:
        v = data["max_appimage_mb"]
        if not _is_int(v) or v < 1 or v > 1024:
            raise ConfigError("policy max_appimage_mb must be 1..1024")
        p.max_appimage_mb = v
    if "keep_previous" in data:
        v = data["keep_previous"]
        if not _is_int(v) or v < 1 or v > 3:
            raise ConfigError("policy keep_previous must be 1..3")
        p.keep_previous = v
    return p


def load_policy(path: str) -> Policy:
    """Missing file = baked-in defaults. Anything wrong with an existing file = ConfigError."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return Policy()
    except OSError as e:
        raise ConfigError("policy file not accessible: %s" % e.strerror)
    try:
        fsio.check_private_file(path)
        with open(path, "rb") as f:
            raw = f.read(64 * 1024 + 1)
        if len(raw) > 64 * 1024:
            raise ConfigError("policy file too large")
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dups, parse_constant=_bad_const)
    except ConfigError:
        raise
    except (OSError, ValueError) as e:
        raise ConfigError("policy file invalid: %s" % str(e)[:120])
    return parse_policy(data)


def write_hold(path: str, hold: bool) -> None:
    """Set `hold` in the local policy file (creates it when missing). Keeps other keys; refuses an invalid file."""
    data: Dict[str, Any] = {}
    if os.path.lexists(path):
        load_policy(path)  # validates (raises on invalid)
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    data["schema"] = 1
    data["hold"] = bool(hold)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fsio.atomic_write_json(path, data)
