#!/usr/bin/env python3
"""Generate ``manifest.json`` (CONTRACT section 3, schema 1) and ``SHA256SUMS``.

Both files are written into the ``--dist`` directory next to the assets.

* ``assets[]`` lists the payload files (just ``MoonlightSetup.exe``) with sha256 + size.
* ``SHA256SUMS`` covers every payload asset **and** ``manifest.json`` (but not itself and not
  the attestation bundle) -- ``sha256  filename`` lines.
* ``build.version`` is ``6.2.0-daily.B`` (CONTRACT 3b), ``build.msi_product_version`` the expected
  FileVersion ``6.2.B.0``; consumers read the expected build from the attested ``build.version``.
* An optional ``--gate-summary`` JSON (from ``bundle_gate.py``, produced by an unprivileged job)
  is re-validated here and embedded under ``installer_checks`` (additive key; consumers ignore
  unknown keys).

``validate_manifest`` is the schema check used by the unit tests and by the publish job right
before attesting.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional

import vpcommon as v

WORKFLOW = ".github/workflows/patched-windows-release.yml"
INSTALLER_DEFAULT = "MoonlightSetup.exe"
BUNDLE = "attestation.sigstore.json"
SOURCE_REF_RE = re.compile(r"refs/heads/(build|ci-trial)/v6\.2\.0-daily\.[0-9]{1,5}-n[0-9]{1,3}")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def asset_entry(dist: str, name: str) -> Dict[str, Any]:
    v.require(v.ASSET_NAME_RE, name, "asset name")
    path = os.path.join(dist, name)
    if not os.path.isfile(path) or os.path.islink(path):
        raise v.ValidationError(f"asset missing or not a regular file: {name}")
    return {"name": name, "sha256": sha256_file(path), "size": os.path.getsize(path)}


def write_sums(dist: str, names: List[str]) -> str:
    lines = []
    for name in sorted(set(names)):
        v.require(v.ASSET_NAME_RE, name, "asset name")
        if name in ("SHA256SUMS", BUNDLE):
            raise v.ValidationError("SHA256SUMS must not list itself or the bundle")
        lines.append(f"{sha256_file(os.path.join(dist, name))}  {name}\n")
    text = "".join(lines)
    with open(os.path.join(dist, "SHA256SUMS"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(text)
    return text


def verify_sums(dist: str) -> List[str]:
    """Return a list of problems (empty = every listed file matches)."""
    problems: List[str] = []
    with open(os.path.join(dist, "SHA256SUMS"), "r", encoding="ascii") as fh:
        for ln in fh.read().splitlines():
            m = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]{0,99})", ln)
            if not m:
                problems.append("malformed line")
                continue
            path = os.path.join(dist, m.group(2))
            if not os.path.isfile(path):
                problems.append(f"missing {m.group(2)}")
            elif sha256_file(path) != m.group(1):
                problems.append(f"mismatch {m.group(2)}")
    return problems


def sanitize_gate_summary(raw: Any, expected_version: str = "") -> Optional[Dict[str, Any]]:
    """Re-validate the untrusted gate summary; return a normalised copy (or None)."""
    if not isinstance(raw, dict) or raw.get("status") != "ok":
        return None
    ver_re = re.compile(r"[0-9]{1,5}(?:\.[0-9]{1,5}){3}")
    out: Dict[str, Any] = {"tool": "bundle_gate"}
    exp = raw.get("expected_file_version")
    up = raw.get("upstream_file_version")
    if not isinstance(exp, str) or ver_re.fullmatch(exp) is None:
        return None
    if not isinstance(up, str) or ver_re.fullmatch(up) is None:
        return None
    if expected_version and exp != expected_version:
        return None
    out["expected_file_version"] = exp
    out["upstream_file_version"] = up
    bundle = raw.get("bundle")
    if not isinstance(bundle, dict):
        return None
    sha = bundle.get("sha256")
    size = bundle.get("size")
    fv = bundle.get("file_version")
    if not isinstance(sha, str) or v.SHA256_RE.fullmatch(sha) is None:
        return None
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        return None
    if not isinstance(fv, str) or ver_re.fullmatch(fv) is None or fv != exp:
        return None
    out["bundle"] = {"sha256": sha, "size": size, "file_version": fv}
    burn = raw.get("burn")
    if not isinstance(burn, dict):
        return None
    reg = burn.get("registration_version")
    pkgs = burn.get("msi_packages")
    if not isinstance(reg, str) or ver_re.fullmatch(reg) is None or reg != exp:
        return None
    if not isinstance(pkgs, list) or not (2 <= len(pkgs) <= 16):
        return None
    norm = []
    for p in pkgs:
        if not isinstance(p, dict):
            return None
        pid, pv = p.get("id"), p.get("version")
        if not isinstance(pid, str) or re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", pid) is None:
            return None
        if not isinstance(pv, str) or ver_re.fullmatch(pv) is None or pv != exp:
            return None
        norm.append({"id": pid, "version": pv})
    out["burn"] = {"registration_version": reg, "msi_packages": norm}
    execs = raw.get("executables")
    if not isinstance(execs, dict) or set(execs) != {"x64", "arm64"}:
        return None
    ex_out = {}
    for arch in ("x64", "arm64"):
        e = execs[arch]
        if not isinstance(e, dict) or not isinstance(e.get("file_version"), str) \
                or ver_re.fullmatch(e["file_version"]) is None or e["file_version"] != exp:
            return None
        ex_out[arch] = {"file_version": e["file_version"]}
    out["executables"] = ex_out
    return out


def sanitize_sensitive(block: Any) -> Dict[str, Any]:
    """Validate the ``sensitive`` block of build-meta.json (strict; raises on anything odd)."""
    if not isinstance(block, dict):
        raise v.ValidationError("bad sensitive block")
    since = block.get("since", "")
    if since != "":
        v.upstream_tag(since)
    count = block.get("count")
    if not isinstance(count, int) or isinstance(count, bool) or not (0 <= count <= 1000000):
        raise v.ValidationError("bad sensitive count")
    paths = block.get("paths")
    if not isinstance(paths, list) or len(paths) > 50:
        raise v.ValidationError("bad sensitive paths")
    for p in paths:
        if not isinstance(p, str) or re.fullmatch(r"[ -~]{1,200}", p) is None:
            raise v.ValidationError("bad sensitive path entry")
    enforced = block.get("enforced")
    if not isinstance(enforced, bool):
        raise v.ValidationError("bad sensitive enforced flag")
    return {"since": since, "count": count, "paths": list(paths), "enforced": enforced}


def validate_manifest(m: Dict[str, Any]) -> None:
    """Strict schema-1 validation (raises ``ValidationError``)."""
    import version_map

    if m.get("schema") != 1 or m.get("product") != "moonlight":
        raise v.ValidationError("bad schema/product")
    v.release_tag(m["tag"])
    up = m["upstream"]
    v.require(v.OWNER_RE, up["owner"], "upstream owner")
    v.require(v.REPO_RE, up["repo"], "upstream repo")
    v.upstream_tag(up["tag"])
    v.sha1(up["commit"], "upstream commit")
    if not isinstance(up["release_id"], int) or up["release_id"] <= 0:
        raise v.ValidationError("bad release_id")
    b = m["build"]
    if not isinstance(b["n"], int) or isinstance(b["n"], bool) or not (1 <= b["n"] <= v.MAX_BUILD_N):
        raise v.ValidationError("bad build n")
    if m["tag"] != f"{up['tag']}-vp.{b['n']}":
        raise v.ValidationError("tag does not match upstream tag + build n")
    ver = version_map.compute(up["tag"], b["n"])
    if b["version"] != ver["build_version"] or b["msi_product_version"] != ver["file_version"] \
            or b["number"] != int(ver["build_number"]):
        raise v.ValidationError("build version fields do not match the version mapper")
    v.require(v.RUN_ID_RE, str(b["run_id"]), "run id")
    if b["workflow"] != WORKFLOW:
        raise v.ValidationError("bad workflow path")
    v.require(SOURCE_REF_RE, b["source_ref"], "source_ref")
    v.sha1(b["source_sha"], "source sha")
    p = m["patches"]
    v.sha256(p["series_sha256"], "series sha")
    if not isinstance(p["count"], int) or p["count"] < 0:
        raise v.ValidationError("bad patch count")
    if not isinstance(p["groups"], list) or not all(
            isinstance(g, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,30}", g) for g in p["groups"]):
        raise v.ValidationError("bad patch groups")
    v.require(v.ASSET_NAME_RE, m["installer"], "installer name")
    if not re.fullmatch(r"MoonlightSetup[A-Za-z0-9._-]{0,40}\.exe", m["installer"]):
        raise v.ValidationError("installer name outside the contract")
    names = [a["name"] for a in m["assets"]]
    if m["installer"] not in names:
        raise v.ValidationError("installer is not listed in assets")
    for a in m["assets"]:
        v.require(v.ASSET_NAME_RE, a["name"], "asset name")
        v.sha256(a["sha256"], "asset sha256")
        if not isinstance(a["size"], int) or a["size"] <= 0:
            raise v.ValidationError("bad asset size")
    if m["attestation"] != [BUNDLE]:
        raise v.ValidationError("bad attestation list")
    v.require(v.ISO_TS_RE, m["created_at"], "created_at")
    chk = m.get("installer_checks")
    if chk is not None:
        if sanitize_gate_summary({**chk, "status": "ok"}, m["build"]["msi_product_version"]) is None:
            raise v.ValidationError("installer_checks inconsistent with the build version")
        inst = next(a for a in m["assets"] if a["name"] == m["installer"])
        if chk["bundle"]["sha256"] != inst["sha256"]:
            raise v.ValidationError("installer_checks describe a different file than the installer")
    if "sensitive_paths_touched" in m:
        sanitize_sensitive(m["sensitive_paths_touched"])


def build_manifest(args: argparse.Namespace) -> Dict[str, Any]:
    dist = args.dist
    names = [args.installer]
    manifest: Dict[str, Any] = {
        "schema": 1,
        "product": "moonlight",
        "tag": args.tag,
        "upstream": {"owner": args.upstream_owner, "repo": args.upstream_repo, "tag": args.upstream_tag,
                     "commit": args.upstream_commit, "release_id": args.release_id},
        "build": {"n": args.n, "version": args.build_version, "msi_product_version": args.file_version,
                  "number": int(args.build_version.rsplit(".", 1)[-1]),
                  "run_id": int(v.require(v.RUN_ID_RE, str(args.run_id), "run id")), "workflow": WORKFLOW,
                  "source_ref": args.source_ref, "source_sha": args.source_sha},
        "patches": {"series_sha256": args.series_sha, "count": args.patch_count,
                    "groups": [g for g in args.groups.split(",") if g]},
        "installer": args.installer,
        "assets": [asset_entry(dist, n) for n in names],
        "attestation": [BUNDLE],
        "created_at": args.created_at,
    }
    if getattr(args, "meta", None):
        with open(args.meta, "r", encoding="utf-8") as fh:
            meta = json.load(fh)
        manifest["sensitive_paths_touched"] = sanitize_sensitive(meta.get("sensitive"))
    if not args.gate_summary:
        raise v.ValidationError("the version gate summary is mandatory")
    with open(args.gate_summary, "r", encoding="utf-8") as fh:
        summary = sanitize_gate_summary(json.load(fh), args.file_version)
    if summary is None:
        raise v.ValidationError("gate summary failed validation")
    manifest["installer_checks"] = summary
    validate_manifest(manifest)
    return manifest


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--dist", required=True)
    g.add_argument("--installer", default=INSTALLER_DEFAULT)
    g.add_argument("--tag", required=True)
    g.add_argument("--upstream-owner", default="Nonary")
    g.add_argument("--upstream-repo", default="moonlight-qt")
    g.add_argument("--upstream-tag", required=True)
    g.add_argument("--upstream-commit", required=True)
    g.add_argument("--release-id", required=True, type=int)
    g.add_argument("--n", required=True, type=int)
    g.add_argument("--build-version", required=True)
    g.add_argument("--file-version", required=True)
    g.add_argument("--run-id", required=True)
    g.add_argument("--source-ref", required=True)
    g.add_argument("--source-sha", required=True)
    g.add_argument("--series-sha", required=True)
    g.add_argument("--patch-count", required=True, type=int)
    g.add_argument("--groups", default="posture-core")
    g.add_argument("--created-at", required=True)
    g.add_argument("--gate-summary")
    g.add_argument("--meta", help="build-meta.json (sensitive upstream paths)")
    sl = sub.add_parser("sensitive-line")
    sl.add_argument("--meta", required=True)
    vv = sub.add_parser("verify")
    vv.add_argument("--dist", required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "sensitive-line":
            with open(args.meta, "r", encoding="utf-8") as fh:
                sens = sanitize_sensitive(json.load(fh).get("sensitive"))
            if sens["count"] == 0:
                print("sensitive upstream paths touched: none")
            else:
                since = sens["since"] or "unknown"
                print(f"SENSITIVE UPSTREAM PATHS TOUCHED since {since}: {sens['count']} file(s) "
                      f"(gate enforced: {str(sens['enforced']).lower()}; list in manifest.json)")
            return 0
        if args.cmd == "verify":
            problems = verify_sums(args.dist)
            if problems:
                return v.fail("SHA256SUMS verification failed: " + "; ".join(problems[:5]))
            return 0
        manifest = build_manifest(args)
        with open(os.path.join(args.dist, "manifest.json"), "w", encoding="utf-8", newline="\n") as fh:
            json.dump(manifest, fh, indent=2)
            fh.write("\n")
        write_sums(args.dist, [a["name"] for a in manifest["assets"]] + ["manifest.json"])
    except (ValueError, KeyError, TypeError, OSError) as exc:
        return v.fail(f"manifest_gen: {type(exc).__name__}: {str(exc)[:200]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
