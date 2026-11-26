"""policy.yml on branch `automation` (CONTRACT section 5), fetched like the Windows updater:
GET /repos/<repo>/branches/automation -> commit sha (ETag, 304 is free), GET /repos/<repo>/contents/policy.yml?ref=<sha>
(pinned to that commit), cached per sha, 64 KB cap. Strict YAML subset: top-level `key: value`, plain scalars,
flow lists and flow maps, comments; anchors, tags, quotes, block scalars, nesting, duplicate keys are rejected.

It can only NARROW behaviour (hold, deny, owner intersection, higher cooling-off). Network trouble = NetworkDeferral,
anything unparseable = ConfigError: in both cases nothing is installed.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from . import fsio, versioning
from .errors import ConfigError
from .release import OWNER_RE

BRANCH = "automation"
PATH = "policy.yml"
MAX_BYTES = 64 * 1024
KEYS = {"schema", "allow_upstream_owners", "cooling_off_hours", "hold", "deny", "keep_releases"}
PLAIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,100}")
LINE = re.compile(r"([A-Za-z0-9_-]{1,64}):(?: +(.*))?")


@dataclass
class RemotePolicy:
    sha: str
    hold: bool
    deny: List[str]
    owners: List[str]
    cooling: Dict[str, float]
    has_deny_key: bool = True


def _scalar(tok: str) -> Any:
    tok = tok.strip()
    if tok == "true":
        return True
    if tok == "false":
        return False
    if re.fullmatch(r"-?[0-9]{1,6}", tok):
        return int(tok)
    if re.fullmatch(r"-?[0-9]{1,6}\.[0-9]{1,4}", tok):
        return float(tok)
    if PLAIN.fullmatch(tok):
        return tok
    raise ConfigError("policy.yml: unsupported scalar")


def _flow_list(txt: str) -> List[Any]:
    inner = txt[1:-1].strip()
    if inner == "":
        return []
    if "[" in inner or "{" in inner:
        raise ConfigError("policy.yml: nested flow collections are not supported")
    return [_scalar(x) for x in inner.split(",")]


def _flow_map(txt: str) -> Dict[str, Any]:
    inner = txt[1:-1].strip()
    out: Dict[str, Any] = {}
    if inner == "":
        return out
    if "[" in inner or "{" in inner:
        raise ConfigError("policy.yml: nested flow collections are not supported")
    for part in inner.split(","):
        k, sep, v = part.partition(":")
        k = k.strip()
        if not sep or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", k) or k in out:
            raise ConfigError("policy.yml: malformed flow map")
        out[k] = _scalar(v)
    return out


def parse_yaml(text: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for i, raw in enumerate(text.split("\n")):
        line = raw.rstrip("\r")
        if i == 0 and line == "---":
            continue
        if any(ord(c) < 32 and c != "\t" for c in line) or "\t" in line:
            raise ConfigError("policy.yml: control character or tab")
        body = re.sub(r"(^|\s)#.*$", "", line).rstrip()
        if body == "":
            continue
        m = LINE.fullmatch(body)
        if not m:
            raise ConfigError("policy.yml: unsupported line %d" % (i + 1))
        key, val = m.group(1), m.group(2)
        if key in out:
            raise ConfigError("policy.yml: duplicate key")
        if val is None or val.strip() == "":
            raise ConfigError("policy.yml: empty or nested value for %s" % key[:30])
        val = val.strip()
        if val[0] == "[" and val[-1] == "]":
            out[key] = _flow_list(val)
        elif val[0] == "{" and val[-1] == "}":
            out[key] = _flow_map(val)
        elif val[0] in "&*!|>'\"%@`[{" or val[-1] in "]}":
            raise ConfigError("policy.yml: unsupported value syntax for %s" % key[:30])
        else:
            out[key] = _scalar(val)
    return out


def _num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= 24 * 90


def validate(d: Dict[str, Any], sha: str) -> RemotePolicy:
    for k in d:
        if k not in KEYS and not k.startswith("x-"):
            raise ConfigError("policy.yml: unknown key %s" % k[:30])
    if d.get("schema") != 1 or isinstance(d.get("schema"), bool):
        raise ConfigError("policy.yml: schema must be 1")
    owners = d.get("allow_upstream_owners")
    if (not isinstance(owners, list) or not owners or len(owners) > 20
            or not all(isinstance(o, str) and OWNER_RE.fullmatch(o) for o in owners)):
        raise ConfigError("policy.yml: allow_upstream_owners must be a non-empty list of owners")
    cool = d.get("cooling_off_hours")
    if not isinstance(cool, dict) or set(cool) != {"stable", "canary"} or not all(_num(v) for v in cool.values()):
        raise ConfigError("policy.yml: cooling_off_hours must be {stable, canary} numbers")
    hold = d.get("hold")
    if not isinstance(hold, bool):
        raise ConfigError("policy.yml: hold must be a boolean")
    has_deny = "deny" in d
    deny = d.get("deny", [])
    if not isinstance(deny, list) or len(deny) > 200 or not all(versioning.is_tag(t) for t in deny):
        raise ConfigError("policy.yml: deny must be a list of canonical tags")
    ko = d.get("keep_releases", 10)
    if not isinstance(ko, int) or isinstance(ko, bool) or not 1 <= ko <= 1000:
        raise ConfigError("policy.yml: keep_releases invalid")
    return RemotePolicy(sha=sha, hold=hold, deny=list(dict.fromkeys(deny)), owners=list(dict.fromkeys(owners)),
                        cooling={"stable": float(cool["stable"]), "canary": float(cool["canary"])}, has_deny_key=has_deny)


def _to_json(r: RemotePolicy) -> Dict[str, Any]:
    return {"sha": r.sha, "hold": r.hold, "deny": r.deny, "owners": r.owners, "cooling": r.cooling,
            "has_deny_key": r.has_deny_key}


def _from_json(d: Any) -> Optional[RemotePolicy]:
    try:
        if (isinstance(d, dict) and versioning.SHA1_RE.fullmatch(d["sha"]) and isinstance(d["hold"], bool)
                and all(versioning.is_tag(t) for t in d["deny"]) and d["owners"]
                and all(OWNER_RE.fullmatch(o) for o in d["owners"]) and set(d["cooling"]) == {"stable", "canary"}):
            return RemotePolicy(d["sha"], d["hold"], list(d["deny"]), list(d["owners"]),
                                {k: float(v) for k, v in d["cooling"].items()}, bool(d.get("has_deny_key", True)))
    except (KeyError, TypeError, ValueError):
        pass
    return None


def _read_json(path: str) -> Any:
    try:
        with open(path, "rb") as f:
            return json.loads(f.read(256 * 1024).decode("utf-8"))
    except (OSError, ValueError):
        return None


def fetch(http, repo: str, cache_dir: str, log=None) -> RemotePolicy:
    bpath = os.path.join(cache_dir, "branch.json")
    ppath = os.path.join(cache_dir, "policy.json")
    bc = _read_json(bpath)
    etag = bc.get("etag") if isinstance(bc, dict) and isinstance(bc.get("etag"), str) and re.fullmatch(
        r'(W/)?"[A-Za-z0-9._:/=+-]{1,120}"', bc["etag"]) and versioning.SHA1_RE.fullmatch(str(bc.get("sha"))) else None
    status, body, h = http.get_json("/repos/%s/branches/%s" % (repo, BRANCH), etag)
    if status == 304:
        sha = bc["sha"]
    else:
        try:
            sha = body["commit"]["sha"]
        except (KeyError, TypeError):
            raise ConfigError("branch response has no commit sha")
        if not isinstance(sha, str) or not versioning.SHA1_RE.fullmatch(sha):
            raise ConfigError("branch commit sha invalid")
        new_etag = h.get("etag")
        if new_etag and re.fullmatch(r'(W/)?"[A-Za-z0-9._:/=+-]{1,120}"', new_etag):
            try:
                fsio.atomic_write_json(bpath, {"etag": new_etag, "sha": sha})
            except OSError:
                pass
    cached = _from_json(_read_json(ppath))
    if cached is not None and cached.sha == sha:
        if log:
            log.info("remote_policy", sha=sha, source="cache")
        return cached
    status, body, _h = http.get_json("/repos/%s/contents/%s?ref=%s" % (repo, PATH, sha))
    if (not isinstance(body, dict) or body.get("type") != "file" or body.get("encoding") != "base64"
            or not isinstance(body.get("content"), str) or not isinstance(body.get("size"), int)):
        raise ConfigError("contents response is not a base64 file")
    if body["size"] > MAX_BYTES or len(body["content"]) > MAX_BYTES * 2:
        raise ConfigError("policy.yml larger than 64 KB")
    try:
        raw = base64.b64decode(body["content"].replace("\n", ""), validate=True)
        text = raw.decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        raise ConfigError("policy.yml is not valid base64/utf-8")
    if len(raw) > MAX_BYTES or len(raw) != body["size"]:
        raise ConfigError("policy.yml size mismatch")
    rp = validate(parse_yaml(text), sha)
    if not rp.has_deny_key and log:
        log.warn("remote_policy_no_deny_key")
    try:
        fsio.atomic_write_json(ppath, _to_json(rp))
    except OSError:
        pass
    if log:
        log.info("remote_policy", sha=sha, source="network", hold=rp.hold, deny=len(rp.deny))
    return rp
