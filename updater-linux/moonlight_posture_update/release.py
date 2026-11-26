"""Release list filtering, ordering, manifest.json / SHA256SUMS validation (CONTRACT v1 + v1.1 + Linux amendment v1.2).

Everything from the network is untrusted: every string is validated by regex before any further use.
"""

from __future__ import annotations

import calendar
import json
import re
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from . import versioning
from .errors import VerifyError

MAX_RELEASES = 100
MAX_MANIFEST = 256 * 1024
MAX_SUMS = 64 * 1024
MAX_BUNDLE = 1024 * 1024
MAX_ASSETS = 64

ASSET_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}")
BUNDLE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.(sigstore\.json|jsonl)")
OWNER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}")
PUBLISHED_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
SUMS_LINE_RE = re.compile(r"([0-9a-f]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]{0,99})")


def safe_asset_name(name: object, pattern: "re.Pattern[str]" = ASSET_NAME_RE) -> bool:
    return (isinstance(name, str) and ".." not in name and pattern.fullmatch(name) is not None)


def parse_published(value: object) -> float:
    """Strict `YYYY-MM-DDTHH:MM:SSZ` -> epoch seconds. Raises ValueError."""
    if not isinstance(value, str) or PUBLISHED_RE.fullmatch(value) is None:
        raise ValueError("unparseable published_at")
    return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))


@dataclass
class Candidate:
    release: Dict[str, Any]
    key: versioning.Key
    published: float
    assets: Dict[str, Dict[str, Any]]           # name -> {size, digest}
    reason: str = ""                            # why it is not eligible (informational)


def asset_map(release: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {}
    assets = release.get("assets")
    if not isinstance(assets, list):
        return out
    for a in assets[:MAX_ASSETS]:
        if not isinstance(a, dict):
            continue
        name = a.get("name")
        if not safe_asset_name(name):
            continue
        size = a.get("size")
        size = size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else None
        dg = a.get("digest")
        dg = dg if isinstance(dg, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", dg) else None
        out[name] = {"size": size, "digest": dg}
    return out


def filter_releases(releases: Any, log=None) -> List[Candidate]:
    """Strict tag regex, non-draft, immutable == true (strict: absent or false is refused), installable (N<=8, B<=65535).
    Returns candidates sorted newest first by (U, N). Never raises on garbage entries."""
    out: List[Candidate] = []
    if not isinstance(releases, list):
        return out
    seen = set()
    for r in releases[:MAX_RELEASES]:
        if not isinstance(r, dict):
            continue
        tag = r.get("tag_name")
        if not versioning.is_tag(tag):
            continue
        try:
            key = versioning.parse_tag(tag)
        except ValueError:
            continue
        if tag in seen:
            continue
        if r.get("draft") is not False:
            continue
        if r.get("immutable") is not True:
            if log:
                log.warn("release_not_immutable", tag=tag)
            continue
        try:
            pub = parse_published(r.get("published_at"))
        except ValueError:
            if log:
                log.warn("release_bad_published_at", tag=tag)
            continue
        seen.add(tag)
        out.append(Candidate(r, key, pub, asset_map(r)))
    out.sort(key=lambda c: (c.key.u, c.key.n), reverse=True)
    return out


# ---- manifest -------------------------------------------------------------------------------------------------

def _no_dups(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key %r" % k)
        d[k] = v
    return d


def _bad_const(c):
    raise ValueError("non-finite number")


def _is_uint(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


@dataclass
class Manifest:
    tag: str
    key: versioning.Key
    build_version: str
    source_ref: str
    source_sha: str
    owner: str
    bundles: List[str]
    appimage: str
    appimage_sha256: str
    appimage_size: int
    manifest_sha256: str = ""


def parse_manifest(raw: bytes, expected_tag: str, allow_owners: List[str], max_appimage: int) -> Manifest:
    if len(raw) > MAX_MANIFEST:
        raise VerifyError("manifest too large")
    try:
        m = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dups, parse_constant=_bad_const)
    except (ValueError, UnicodeDecodeError):
        raise VerifyError("manifest is not valid JSON")
    if not isinstance(m, dict):
        raise VerifyError("manifest is not an object")
    for req in ("schema", "product", "tag", "upstream", "build", "attestation", "linux"):
        if req not in m:
            raise VerifyError("manifest missing '%s'" % req)
    if m["schema"] != 1 or isinstance(m["schema"], bool):
        raise VerifyError("manifest schema unsupported")
    if m["product"] != "moonlight":
        raise VerifyError("manifest product is not moonlight")
    if m["tag"] != expected_tag:
        raise VerifyError("manifest tag does not match release tag")
    try:
        key = versioning.parse_tag(expected_tag)
    except ValueError:
        raise VerifyError("tag not installable")
    b = m["build"]
    if not isinstance(b, dict):
        raise VerifyError("manifest build is not an object")
    ver = b.get("version")
    vm = versioning.BUILD_VERSION_RE.fullmatch(ver) if isinstance(ver, str) else None
    if not vm:
        raise VerifyError("manifest build.version invalid")
    if int(vm.group(1)) != key.build:
        raise VerifyError("manifest build.version does not match tag per version scheme")
    sha = b.get("source_sha")
    if not isinstance(sha, str) or not versioning.SHA1_RE.fullmatch(sha):
        raise VerifyError("manifest build.source_sha invalid")
    ref = b.get("source_ref")
    if ref != versioning.source_ref_for(key):
        raise VerifyError("manifest build.source_ref does not match the tag")
    up = m["upstream"]
    owner = up.get("owner") if isinstance(up, dict) else None
    if not isinstance(owner, str) or not OWNER_RE.fullmatch(owner):
        raise VerifyError("manifest upstream.owner invalid")
    if owner not in allow_owners:
        raise VerifyError("manifest upstream owner not in the allow-list")
    att = m["attestation"]
    if not isinstance(att, list) or not att or len(att) > 8:
        raise VerifyError("manifest lists no attestation bundle")
    bundles = []
    for x in att:
        if not safe_asset_name(x, BUNDLE_NAME_RE):
            raise VerifyError("manifest attestation name invalid")
        bundles.append(x)
    lin = m["linux"]
    if not isinstance(lin, dict):
        raise VerifyError("manifest linux is not an object")
    name = lin.get("installer")
    if not isinstance(name, str) or not versioning.APPIMAGE_RE.fullmatch(name):
        raise VerifyError("manifest linux.installer name invalid")
    if name != versioning.appimage_name_for(key):
        raise VerifyError("manifest linux.installer does not match the tag's build number")
    lsha = lin.get("sha256")
    if not isinstance(lsha, str) or not versioning.SHA256_RE.fullmatch(lsha):
        raise VerifyError("manifest linux.sha256 invalid")
    lsize = lin.get("size")
    if not _is_uint(lsize) or lsize < 1 or lsize > max_appimage:
        raise VerifyError("manifest linux.size invalid or above the cap")
    # the Windows installer fields are optional for a Linux consumer, but when present they must be well-formed
    # and an entry for the AppImage in assets[] must agree.
    assets = m.get("assets")
    if assets is not None:
        if not isinstance(assets, list) or len(assets) > MAX_ASSETS:
            raise VerifyError("manifest assets invalid")
        for a in assets:
            if (not isinstance(a, dict) or not safe_asset_name(a.get("name"))
                    or not isinstance(a.get("sha256"), str) or not versioning.SHA256_RE.fullmatch(a["sha256"])):
                raise VerifyError("manifest asset entry invalid")
            if a["name"] == name and a["sha256"] != lsha:
                raise VerifyError("manifest assets[] disagrees with linux.sha256")
            if "size" in a and (not _is_uint(a["size"])):
                raise VerifyError("manifest asset size invalid")
            if a["name"] == name and "size" in a and a["size"] != lsize:
                raise VerifyError("manifest assets[] disagrees with linux.size")
    return Manifest(tag=expected_tag, key=key, build_version=ver, source_ref=ref, source_sha=sha, owner=owner,
                    bundles=bundles, appimage=name, appimage_sha256=lsha, appimage_size=lsize)


def parse_sums(raw: bytes) -> Dict[str, str]:
    if len(raw) > MAX_SUMS:
        raise VerifyError("SHA256SUMS too large")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise VerifyError("SHA256SUMS is not utf-8")
    out: Dict[str, str] = {}
    for line in text.split("\n"):
        line = line.rstrip("\r")
        if line.strip() == "":
            continue
        m = SUMS_LINE_RE.fullmatch(line)
        if not m:
            raise VerifyError("SHA256SUMS contains a malformed line")
        if m.group(2) in out:
            raise VerifyError("SHA256SUMS has a duplicate entry")
        out[m.group(2)] = m.group(1)
    return out


def check_hashes(computed: str, name: str, sums: Dict[str, str], man: Manifest,
                 api_digest: Optional[str], api_size: Optional[int], size: int) -> None:
    """AppImage hash computed from the file == SHA256SUMS == manifest == API digest (when the API shows it)."""
    if name not in sums:
        raise VerifyError("SHA256SUMS has no entry for the AppImage")
    if sums[name] != computed:
        raise VerifyError("AppImage hash does not match SHA256SUMS")
    if man.appimage_sha256 != computed:
        raise VerifyError("AppImage hash does not match manifest.json")
    if sums[name] != man.appimage_sha256:
        raise VerifyError("manifest.json and SHA256SUMS disagree about the AppImage")
    if api_digest is not None and api_digest != "sha256:" + computed:
        raise VerifyError("AppImage hash does not match the release API digest")
    if size != man.appimage_size:
        raise VerifyError("AppImage size does not match manifest.json")
    if api_size is not None and api_size != size:
        raise VerifyError("AppImage size does not match the release API")
