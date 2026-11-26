"""Orchestrator. Order (every step fails closed):

  lock -> policy -> state -> hold -> idle check 1 -> release list (ETag) -> filter/select (tag regex, immutable,
  deny, floor, build > installed, cooling-off, backoff) -> manifest + SHA256SUMS + bundle -> manifest checks ->
  trusted root -> attest manifest and SHA256SUMS -> AppImage (size == manifest == API) -> format gate -> attest
  AppImage -> SHA-256 == SUMS == manifest == API digest   (verify-only stops here)
  -> idle check 2 -> stage copy (hash while copying) -> smoke test -> idle check 3 -> commit -> launcher/desktop ->
  switch `current` -> smoke test again via `current` (rollback on failure) -> state -> prune.
"""

from __future__ import annotations

import datetime
import email.utils
import errno
import fcntl
import json
import os
import re
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from . import attest, fsio, procs, release, smoke, state as st, versioning
from .errors import (ConfigError, Deferred, InstallError, LockedError, NetworkDeferral, RollbackError,
                     UpdaterError, VerifyError)
from .logutil import Logger
from .net import Http, HttpSettings
from .paths import Paths
from .policy import Policy, load_policy, write_hold
from .store import Store

RUN_DIRS_KEEP = 3
SKEW_LIMIT = 300.0


@dataclass
class Result:
    result: str
    tag: str = ""
    detail: str = ""
    exit_code: int = 0

    def line(self) -> str:
        d = re.sub(r"\s+", " ", self.detail)[:200]
        return "MLPU_RESULT=%s MLPU_TAG=%s MLPU_DETAIL=%s" % (self.result, self.tag or "-", d or "-")


@dataclass
class Deps:
    """Everything environment-specific. Production builds it in cli.py; tests build their own in memory."""
    paths: Paths
    http: HttpSettings = field(default_factory=HttpSettings)
    gh_path: Optional[str] = None
    now: Callable[[], float] = time.time
    proc_root: str = "/proc"
    display: Optional[Callable[[], Optional[Dict[str, str]]]] = None
    run_id: str = ""
    stream: Any = None

    def display_env(self) -> Optional[Dict[str, str]]:
        return self.display() if self.display else smoke.find_display(dict(os.environ))


class Updater:
    def __init__(self, deps: Deps) -> None:
        self.d = deps
        self.p = deps.paths
        self.run_id = deps.run_id or "%s-%s" % (time.strftime("%Y%m%dT%H%M%S", time.gmtime(deps.now())), os.urandom(3).hex())
        self.log: Logger = Logger(self.run_id, self.p.log_file, deps.stream, clock=deps.now)
        self.store = Store(self.p, self.log)
        self.http = Http(deps.http)
        self._lock_fd = -1
        self._tag = ""

    # ---- infrastructure ------------------------------------------------------------------------------------------
    def _prepare_dirs(self) -> None:
        os.makedirs(self.p.state_dir, mode=0o700, exist_ok=True)
        for d in (self.p.state_dir, self.p.cache_dir, self.p.runs_dir, self.p.gh_dir):
            if d != self.p.state_dir:
                os.makedirs(d, mode=0o700, exist_ok=True)
            fsio.ensure_private_dir(d)

    def _acquire(self) -> None:
        fd = os.open(self.p.lock_file, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise LockedError("another instance is running")
        self._lock_fd = fd

    def _release(self) -> None:
        if self._lock_fd >= 0:
            try:
                os.close(self._lock_fd)
            except OSError:
                pass
            self._lock_fd = -1

    def _now(self) -> float:
        return self.d.now()

    def _idle_check(self, label: str) -> None:
        excl = procs.ancestors_and_self(self.d.proc_root)
        hits = procs.find_clients(self.d.proc_root, excl, self.p.opt_dir)
        if hits:
            self.log.info("client_running", check=label, pids=",".join(str(p) for p, _ in hits[:5]))
            raise Deferred("Moonlight is running (%s); not replacing a client mid-stream" % label)

    # ---- public entry points -------------------------------------------------------------------------------------
    def run(self, mode: str = "update", tag: Optional[str] = None) -> Result:
        """mode: update | verify-only. Never raises UpdaterError; returns the Result."""
        try:
            self._prepare_dirs()
            self._acquire()
        except UpdaterError as e:
            return self._finish(e, None)
        except OSError as e:
            return self._finish(ConfigError("state directory unusable: %s" % e.strerror), None)
        state: Optional[Dict[str, Any]] = None
        run_dir = os.path.join(self.p.runs_dir, self.run_id)
        try:
            self.log.info("start", mode=mode, pid=os.getpid())
            policy = load_policy(self.p.policy_file)
            state, _corrupt = st.load_state(self.p.state_file, self.log)
            res = self._run(mode, tag, policy, state, run_dir)
            return self._finish_ok(res, state)
        except UpdaterError as e:
            return self._finish(e, state, self._tag or e.tag)
        except OSError as e:
            code = e.errno
            transient = code in (errno.ENOSPC, errno.EDQUOT, errno.EIO)
            err = InstallError("filesystem error: %s" % (e.strerror or e))
            r = self._finish(err, state, self._tag, kind="transient" if transient else "install")
            return r
        except Exception as e:  # noqa: BLE001 - last resort, still fail closed
            self.log.error("internal_error", error=type(e).__name__, detail=str(e)[:200])
            return Result("failed", self._tag, "internal error: %s" % type(e).__name__, 1)
        finally:
            self._cleanup_runs(run_dir)
            self._release()

    # ---- the main flow --------------------------------------------------------------------------------------------
    def _run(self, mode: str, force_tag: Optional[str], policy: Policy, state: Dict[str, Any], run_dir: str) -> Result:
        verify_only = mode == "verify-only"
        if force_tag is not None and not verify_only:
            raise ConfigError("--tag is only allowed with verify-only")
        if policy.hold and not verify_only:
            self.log.info("held")
            return Result("held", "", "policy hold is set")
        link_tag = self.store.current_tag()
        installed = st.installed_build(state, link_tag)
        self.log.info("installed", build=installed if installed is not None else "none", link=link_tag or "none")
        if not verify_only:
            self._idle_check("start")

        releases, server_now = self._release_list(policy, state)
        now = self._now()
        if server_now is not None and abs(server_now - now) > SKEW_LIMIT:
            self.log.warn("clock_skew", local=int(now), server=int(server_now))
            now = server_now
        cands = release.filter_releases(releases, self.log)
        denied = st.denied_tags(state, policy.deny)
        cooling = policy.effective_cooling_hours()
        chosen: Optional[release.Candidate] = None
        reasons: List[str] = []
        for c in cands:
            tag = c.key.tag
            if force_tag is not None and tag != force_tag:
                continue
            if tag in denied:
                reasons.append("%s denied" % tag)
                continue
            if c.key.build < policy.min_build:
                reasons.append("%s below floor" % tag)
                continue
            if not any(versioning.APPIMAGE_RE.fullmatch(n) for n in c.assets):
                self.log.info("no_linux_asset", tag=tag)
                reasons.append("%s has no AppImage" % tag)
                continue
            if not verify_only:
                if installed is not None and c.key.build <= installed:
                    reasons.append("%s not newer" % tag)
                    continue
                age_h = (now - c.published) / 3600.0
                if age_h < cooling:
                    self.log.info("cooling_off", tag=tag, age_hours="%.2f" % age_h, required=cooling)
                    reasons.append("%s cooling-off %.1f/%sh" % (tag, age_h, cooling))
                    continue
                if st.in_backoff(state, tag, now):
                    self.log.info("backoff", tag=tag)
                    reasons.append("%s in backoff" % tag)
                    continue
            chosen = c
            break
        if chosen is None:
            if force_tag is not None:
                raise VerifyError("requested tag is not an eligible release", force_tag)
            return Result("noop", "", "; ".join(reasons[:4]) or "no eligible release")
        tag = chosen.key.tag
        self._tag = tag
        self.log.info("selected", tag=tag, build=chosen.key.build)

        os.makedirs(run_dir, mode=0o700, exist_ok=True)
        fsio.ensure_private_dir(run_dir)
        ver = self._download_and_verify(policy, chosen, run_dir)
        if verify_only:
            self.log.info("verified", tag=tag, sha256=ver["sha256"])
            return Result("verified", tag, "chain verified, nothing installed")
        return self._install(policy, state, chosen, ver, run_dir)

    # ---- release list --------------------------------------------------------------------------------------------
    def _release_list(self, policy: Policy, state: Dict[str, Any]):
        cache_path = os.path.join(self.p.cache_dir, "releases.json")
        etag = None
        cached = None
        try:
            with open(cache_path, "rb") as f:
                c = json.loads(f.read(8 * 1024 * 1024).decode("utf-8"))
            if (isinstance(c, dict) and isinstance(c.get("etag"), str) and isinstance(c.get("body"), list)
                    and c.get("repo") == policy.repo and re.fullmatch(r'(W/)?"[A-Za-z0-9._:/=+-]{1,120}"', c["etag"])):
                etag, cached = c["etag"], c["body"]
        except (OSError, ValueError):
            pass
        status, body, h = self.http.get_json("/repos/%s/releases?per_page=30" % policy.repo, etag)
        server_now = None
        if "date" in h:
            try:
                server_now = email.utils.parsedate_to_datetime(h["date"]).timestamp()
            except (TypeError, ValueError):
                server_now = None
        if status == 304:
            if cached is None:
                raise NetworkDeferral("304 without a cache")
            self.log.info("releases", source="cache-304", count=len(cached))
            return cached, server_now
        if not isinstance(body, list):
            raise VerifyError("release list is not an array")
        new_etag = h.get("etag")
        if new_etag and re.fullmatch(r'(W/)?"[A-Za-z0-9._:/=+-]{1,120}"', new_etag):
            try:
                fsio.atomic_write_json(cache_path, {"repo": policy.repo, "etag": new_etag, "body": body})
            except OSError:
                self.log.warn("cache_write_failed")
        self.log.info("releases", source="network", count=len(body))
        return body, server_now

    # ---- download + verification ------------------------------------------------------------------------------------
    def _fetch(self, policy: Policy, tag: str, name: str, run_dir: str, cap: int, api: Dict[str, Any],
               expected_size: Optional[int] = None, big: bool = False) -> str:
        if name not in api:
            raise VerifyError("release has no asset '%s'" % name, tag)
        meta = api[name]
        size_hint = expected_size if expected_size is not None else meta["size"]
        if meta["size"] is not None and expected_size is not None and meta["size"] != expected_size:
            raise VerifyError("API size of %s differs from the manifest" % name, tag)
        if meta["size"] is not None and meta["size"] > cap:
            raise VerifyError("asset %s is larger than the cap" % name, tag)
        dest = os.path.join(run_dir, name)
        url = self.http.asset_url(policy.repo, tag, name)
        timeout = self.http.s.big_timeout if big else self.http.s.small_timeout
        size, _h = self.http.download(url, dest, cap, size_hint, timeout)
        digest = fsio.sha256_file(dest)
        if meta["digest"] is not None and meta["digest"] != "sha256:" + digest:
            raise VerifyError("%s does not match the release API digest" % name, tag)
        self.log.info("downloaded", asset=name, bytes=size)
        return dest

    def _download_and_verify(self, policy: Policy, c: release.Candidate, run_dir: str) -> Dict[str, Any]:
        tag = c.key.tag
        api = c.assets
        cap_app = policy.max_appimage_mb * 1024 * 1024
        mp = self._fetch(policy, tag, "manifest.json", run_dir, release.MAX_MANIFEST, api)
        sp = self._fetch(policy, tag, "SHA256SUMS", run_dir, release.MAX_SUMS, api)
        with open(mp, "rb") as f:
            raw_manifest = f.read()
        man = release.parse_manifest(raw_manifest, tag, policy.upstream_owners, cap_app)
        man.manifest_sha256 = fsio.sha256_file(mp)
        with open(sp, "rb") as f:
            sums = release.parse_sums(f.read())
        if "manifest.json" in sums and sums["manifest.json"] != man.manifest_sha256:
            raise VerifyError("manifest.json does not match SHA256SUMS", tag)
        bundles = [self._fetch(policy, tag, b, run_dir, release.MAX_BUNDLE, api) for b in man.bundles]
        self.log.info("manifest_ok", tag=tag, build=man.build_version, source_sha=man.source_sha)

        ref = versioning.source_ref_for(man.key)
        att = attest.Attestor(self.d.gh_path or attest.find_gh(), self.p.gh_dir, policy.repo, policy.signer_workflow,
                              run_dir, self.log)
        att.fetch_trusted_root()                       # the only network step of the attestation chain

        def verify_with_any(path: str, digest: Optional[str], sha: str, name: str) -> str:
            last: Optional[VerifyError] = None
            for b in bundles:
                try:
                    return att.verify(path, b, ref, digest, sha, name)
                except VerifyError as e:
                    last = e
            raise last or VerifyError("no attestation bundle")

        # manifest first: it authenticates source_sha. No --source-digest yet, but the verified certificate must carry it.
        cert_digest = verify_with_any(mp, None, man.manifest_sha256, "manifest.json")
        if cert_digest != man.source_sha:
            raise VerifyError("attested source digest differs from manifest build.source_sha", tag)
        if "SHA256SUMS" not in api:
            raise VerifyError("release has no SHA256SUMS", tag)
        verify_with_any(sp, man.source_sha, fsio.sha256_file(sp), "SHA256SUMS")

        # the AppImage is downloaded only after manifest + SUMS are attested
        ap = self._fetch(policy, tag, man.appimage, run_dir, cap_app, api, expected_size=man.appimage_size, big=True)
        smoke.check_format(ap, cap_app)
        sha = fsio.sha256_file(ap)
        verify_with_any(ap, man.source_sha, sha, man.appimage)
        meta = api[man.appimage]
        release.check_hashes(sha, man.appimage, sums, man, meta["digest"], meta["size"], os.path.getsize(ap))
        self.log.info("hash_ok", asset=man.appimage, sha256=sha)
        return {"manifest": man, "appimage": ap, "sha256": sha}

    # ---- install -----------------------------------------------------------------------------------------------------
    def _install(self, policy: Policy, state: Dict[str, Any], c: release.Candidate, ver: Dict[str, Any],
                 run_dir: str) -> Result:
        tag = c.key.tag
        man: release.Manifest = ver["manifest"]
        self._idle_check("before-install")
        prev_tag = self.store.current_tag()
        meta = {"source_sha": man.source_sha, "build_version": man.build_version, "size": man.appimage_size}
        stage_dir = self.store.stage(ver["appimage"], tag, ver["sha256"], self.run_id, meta)
        committed = False
        switched = False
        try:
            smoke_tmp = os.path.join(run_dir, "smoke")
            os.makedirs(smoke_tmp, mode=0o700, exist_ok=True)
            how = smoke.run_smoke(os.path.join(stage_dir, "Moonlight.AppImage"), man.build_version,
                                  policy.smoke_test, smoke_tmp, self.d.display_env())
            self.log.info("smoke_ok", stage="staged", how=how)
            self._idle_check("before-switch")
            self.store.commit(stage_dir, tag, self.run_id)
            committed = True
            self.store.write_launcher_and_desktop()
            self.store.switch(tag)
            switched = True
            fsio.fsync_dir(self.p.opt_dir)
            try:
                smoke_tmp2 = os.path.join(run_dir, "smoke2")
                os.makedirs(smoke_tmp2, mode=0o700, exist_ok=True)
                smoke.run_smoke(os.path.join(self.p.current_link, "Moonlight.AppImage"), man.build_version,
                                policy.smoke_test, smoke_tmp2, self.d.display_env())
            except UpdaterError as e:
                self.log.error("post_switch_smoke_failed", detail=str(e))
                self._undo_switch(prev_tag, tag)
                switched = False
                raise InstallError("post-switch health check failed; previous version restored: %s" % e, tag)
        except BaseException:
            if not committed:
                fsio.rmtree_quiet(stage_dir)
            elif not switched:
                self.store.discard(tag)
            raise
        # success: state, prune
        prev_rec = None
        if prev_tag and prev_tag != tag:
            pm = self.store.read_meta(prev_tag)
            if pm:
                prev_rec = {"tag": prev_tag, "build": versioning.parse_tag(prev_tag).build, "sha256": pm["sha256"],
                            "installed_at": pm.get("installed_at")}
        rec = {"tag": tag, "build": c.key.build, "sha256": ver["sha256"],
               "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self._now()))}
        state["installed"] = rec
        state["previous"] = prev_rec
        st.clear_attempts(state, tag)
        state["last_success"] = rec["installed_at"]
        keep = {tag} | ({prev_tag} if prev_tag else set())
        try:
            removed = self.store.prune(keep)
            if removed:
                self.log.info("pruned", tags=",".join(removed))
        except OSError:
            self.log.warn("prune_failed")
        self.log.info("installed_ok", tag=tag, previous=prev_tag or "none")
        return Result("updated", tag, "installed %s (previous %s)" % (tag, prev_tag or "none"))

    def _undo_switch(self, prev_tag: Optional[str], bad_tag: str) -> None:
        if prev_tag and os.path.isfile(self.store.appimage_path(prev_tag)):
            fsio.switch_symlink(self.p.current_link, prev_tag)
        else:
            try:
                os.unlink(self.p.current_link)
            except OSError:
                pass
        self.store.discard(bad_tag)

    # ---- outcome / state -----------------------------------------------------------------------------------------
    def _finish_ok(self, res: Result, state: Dict[str, Any]) -> Result:
        state["last_check"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self._now()))
        state["last_result"] = res.result
        self._save(state)
        return self._emit(res)

    def _finish(self, err: UpdaterError, state: Optional[Dict[str, Any]], tag: str = "", kind: Optional[str] = None) -> Result:
        tag = tag or err.tag
        if kind is None:
            if isinstance(err, VerifyError):
                kind = "verify"
            elif isinstance(err, NetworkDeferral):
                kind = "transient"
            elif isinstance(err, InstallError):
                kind = "install"
        if state is not None and tag and kind and not isinstance(err, Deferred):
            denied = st.count_failure(state, tag, kind, self._now())
            if denied:
                self.log.error("tag_denied", tag=tag, kind=kind)
        if state is not None:
            state["last_check"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self._now()))
            state["last_result"] = err.result
            self._save(state)
        level = self.log.info if isinstance(err, Deferred) else self.log.error
        level("failed" if not isinstance(err, Deferred) else "deferred", tag=tag or "-", detail=str(err)[:200])
        return self._emit(Result(err.result, tag, str(err), err.exit_code))

    def _save(self, state: Dict[str, Any]) -> None:
        try:
            st.save_state(self.p.state_file, state)
        except (OSError, ValueError) as e:
            self.log.error("state_write_failed", detail=str(e)[:100])

    def _emit(self, res: Result) -> Result:
        line = res.line()
        try:
            (self.d.stream or __import__("sys").stdout).write(line + "\n")
        except (OSError, ValueError):
            pass
        self.log.info("result", result=res.result, tag=res.tag or "-", detail=res.detail)
        return res

    def _cleanup_runs(self, run_dir: str) -> None:
        # the big AppImage copy is never kept; small files of the newest runs stay for forensics
        try:
            for n in os.listdir(run_dir):
                if versioning.APPIMAGE_RE.fullmatch(n):
                    os.unlink(os.path.join(run_dir, n))
        except OSError:
            pass
        try:
            names = sorted(os.listdir(self.p.runs_dir))
            for n in names[:-RUN_DIRS_KEEP]:
                fsio.rmtree_quiet(os.path.join(self.p.runs_dir, n))
        except OSError:
            pass

    # ---- operator commands ---------------------------------------------------------------------------------------------
    def _locked(self, fn):
        try:
            self._prepare_dirs()
            self._acquire()
        except UpdaterError as e:
            return self._finish(e, None)
        except OSError as e:
            return self._finish(ConfigError("state directory unusable: %s" % e.strerror), None)
        try:
            return fn()
        except UpdaterError as e:
            return self._finish(e, None, e.tag)
        except OSError as e:
            return self._finish(RollbackError("filesystem error: %s" % (e.strerror or e)), None)
        finally:
            self._release()

    def rollback(self) -> Result:
        """Switch `current` back to the previous verified version, deny the version rolled back from."""
        def go() -> Result:
            state, _ = st.load_state(self.p.state_file, self.log)
            cur = self.store.current_tag()
            if cur is None:
                raise RollbackError("no current version installed")
            cur_build = versioning.parse_tag(cur).build
            prev = (state.get("previous") or {}).get("tag")
            if not prev or prev == cur or versioning.parse_tag(prev).build >= cur_build or prev not in self.store.installed_tags():
                older = [t for t in self.store.installed_tags() if versioning.parse_tag(t).build < cur_build]
                prev = older[-1] if older else None
            if not prev:
                raise RollbackError("no previous version available")
            self._idle_check_rollback()
            sha = self.store.verify_installed(prev, (state.get("previous") or {}).get("sha256") if (state.get("previous") or {}).get("tag") == prev else None)
            smoke.check_format(self.store.appimage_path(prev), 1024 * 1024 * 1024)
            self.store.write_launcher_and_desktop()
            self.store.switch(prev)
            if cur not in state["deny"]:
                state["deny"].append(cur)
            meta = self.store.read_meta(prev) or {}
            state["installed"] = {"tag": prev, "build": versioning.parse_tag(prev).build, "sha256": sha,
                                  "installed_at": meta.get("installed_at")}
            state["previous"] = None
            state["last_result"] = "rolled_back"
            state["last_check"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self._now()))
            self._save(state)
            self.log.info("rolled_back", frm=cur, to=prev)
            return self._emit(Result("rolled_back", prev, "current %s -> %s; %s is denied" % (cur, prev, cur)))
        return self._locked(go)

    def _idle_check_rollback(self) -> None:
        try:
            self._idle_check("rollback")
        except Deferred as e:
            raise RollbackError(str(e))

    def status(self) -> Dict[str, Any]:
        """No network, no lock, read-only. JSON-serialisable."""
        out: Dict[str, Any] = {"schema": 1}
        try:
            pol = load_policy(self.p.policy_file)
            out["policy"] = pol.to_dict()
            out["policy"]["effective_cooling_off_hours"] = pol.effective_cooling_hours()
            out["policy_error"] = None
        except ConfigError as e:
            out["policy"] = None
            out["policy_error"] = str(e)
        try:
            with open(self.p.state_file, "rb") as f:
                s = json.loads(f.read(1024 * 1024).decode("utf-8"))
            valid = st.validate_state(s)
        except FileNotFoundError:
            s, valid = st.empty_state(), True
        except (OSError, ValueError):
            s, valid = None, False
        out["state_valid"] = valid
        link = self.store.current_tag()
        out["current"] = {"tag": link, "path": os.path.join(self.p.current_link, "Moonlight.AppImage") if link else None,
                          "meta": self.store.read_meta(link) if link else None}
        out["installed_tags"] = self.store.installed_tags()
        if valid and s is not None:
            out["installed"] = s["installed"]
            out["previous"] = s["previous"]
            out["deny"] = s["deny"]
            out["attempts"] = s["attempts"]
            out["last_check"] = s["last_check"]
            out["last_success"] = s["last_success"]
            out["last_result"] = s["last_result"]
        out["held"] = bool(out["policy"] and out["policy"]["hold"])
        out["client_running"] = bool(procs.find_clients(self.d.proc_root, procs.ancestors_and_self(self.d.proc_root), self.p.opt_dir))
        out["launcher"] = self.p.launcher if os.path.exists(self.p.launcher) else None
        try:
            out["gh"] = self.d.gh_path or attest.find_gh()
        except UpdaterError:
            out["gh"] = None
        return out

    def set_hold(self, on: bool) -> Result:
        write_hold(self.p.policy_file, on)
        self.log.info("hold_set", hold=on)
        return self._emit(Result("held" if on else "noop", "", "hold %s" % ("on" if on else "off")))

    def clear_deny(self, tag: Optional[str]) -> Result:
        def go() -> Result:
            state, _ = st.load_state(self.p.state_file, self.log)
            if tag is not None and not versioning.is_tag(tag):
                raise ConfigError("not a valid tag")
            before = len(state["deny"])
            state["deny"] = [t for t in state["deny"] if tag is not None and t != tag]
            for t in ([tag] if tag else list(state["attempts"])):
                state["attempts"].pop(t, None)
            self._save(state)
            return self._emit(Result("noop", tag or "", "removed %d local deny entries" % (before - len(state["deny"]))))
        return self._locked(go)
