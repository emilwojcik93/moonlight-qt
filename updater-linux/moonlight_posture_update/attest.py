"""Offline attestation verification with the `gh` CLI (CONTRACT 4.5), mirroring the Windows Verify.ps1.

Result of the experiment (see docs/LINUX-UPDATER.md): `gh attestation verify --bundle` works with no login and no
token. It still needs the network to refresh the Sigstore TUF trusted root, so we fetch the root explicitly once per
run (`gh attestation trusted-root`) and verify every subject with `--custom-trusted-root`: one clearly separated
network step, then purely offline verification. Any problem = failure (fail closed).
"""

from __future__ import annotations

import json
import os
import re
import signal
import stat
import subprocess
from typing import Dict, List, Optional

from . import versioning
from .errors import NetworkDeferral, VerifyError

GH_CANDIDATES = ("/usr/bin/gh", "/usr/local/bin/gh")
PREDICATE_TYPE = "https://slsa.dev/provenance/v1"
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
TRUSTED_ROOT_TIMEOUT = 120
VERIFY_TIMEOUT = 180
MAX_OUT = 4 * 1024 * 1024


def find_gh() -> str:
    """Fixed absolute locations only (no PATH lookup); the binary must be root-owned and not group/world-writable."""
    for p in GH_CANDIDATES:
        try:
            st = os.stat(p)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode) or not os.access(p, os.X_OK):
            continue
        if st.st_uid != 0 or st.st_mode & 0o022:
            continue
        return p
    raise VerifyError("gh not found at a trusted location (%s); install the `github-cli` package" % ", ".join(GH_CANDIDATES))


def gh_environment(gh_dir: str) -> Dict[str, str]:
    """Child environment: no GH_*/GITHUB_* ambient credentials, private config + cache (TUF) dirs, no prompts."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GH_", "GITHUB_")) and k not in ("GIT_ASKPASS", "SSH_ASKPASS")}
    cfg = os.path.join(gh_dir, "config")
    cache = os.path.join(gh_dir, "cache")
    tmp = os.path.join(gh_dir, "tmp")
    for d in (cfg, cache, tmp):
        os.makedirs(d, mode=0o700, exist_ok=True)
    env.update({
        "GH_CONFIG_DIR": cfg,
        "XDG_CONFIG_HOME": os.path.join(gh_dir, "xdg-config"),
        "XDG_CACHE_HOME": cache,
        "TMPDIR": tmp,
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED": "1",
        "NO_COLOR": "1",
        "HOME": os.environ.get("HOME", gh_dir),
    })
    return env


def _run(argv: List[str], env: Dict[str, str], timeout: int):
    """No shell, new session so a timeout kills the whole group. Returns (rc, stdout_bytes, stderr_text, timed_out)."""
    p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out[:MAX_OUT], err[:2000].decode("utf-8", "replace"), False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=10)
        except Exception:
            pass
        return -1, b"", "timeout", True


class Attestor:
    def __init__(self, gh_path: str, gh_dir: str, repo: str, signer_workflow: str, run_dir: str, log=None) -> None:
        self.gh = gh_path
        self.repo = repo
        self.signer = signer_workflow
        self.run_dir = run_dir
        self.log = log
        self.env = gh_environment(gh_dir)
        self.root: Optional[str] = None

    def fetch_trusted_root(self) -> None:
        """Network step: TUF-verified Sigstore trusted roots (public-good + GitHub) into the private run dir."""
        rc, out, err, timed_out = _run([self.gh, "attestation", "trusted-root"], self.env, TRUSTED_ROOT_TIMEOUT)
        if rc != 0 or not out.strip():
            raise NetworkDeferral("could not fetch the Sigstore trusted root (%s)" % ("timeout" if timed_out else "rc=%s" % rc))
        path = os.path.join(self.run_dir, "trusted-root.jsonl")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(out)
        self.root = path
        if self.log:
            self.log.info("trusted_root_ok", bytes=len(out))

    def verify(self, file_path: str, bundle_path: str, source_ref: str, source_digest: Optional[str],
               expected_sha256: str, expected_name: str) -> str:
        """One subject. Returns the (verified) certificate source repository digest. Flags exactly as the Windows updater + `--custom-trusted-root` (offline). Then re-check the
        verified JSON ourselves (defense in depth: do not rely on the exit code alone)."""
        if self.root is None:
            raise VerifyError("trusted root not loaded")
        if not re.fullmatch(r"refs/heads/build/v6\.2\.0-daily\.[1-9][0-9]{0,4}-n[1-8]", source_ref):
            raise VerifyError("source ref not allowed")
        if source_digest is not None and not versioning.SHA1_RE.fullmatch(source_digest):
            raise VerifyError("source digest invalid")
        argv = [self.gh, "attestation", "verify", file_path, "--repo", self.repo, "--bundle", bundle_path,
                "--signer-workflow", self.signer, "--source-ref", source_ref, "--deny-self-hosted-runners",
                "--predicate-type", PREDICATE_TYPE, "--cert-oidc-issuer", OIDC_ISSUER,
                "--custom-trusted-root", self.root, "--format", "json"]
        if source_digest:
            argv += ["--source-digest", source_digest]
        rc, out, err, timed_out = _run(argv, self.env, VERIFY_TIMEOUT)
        if rc != 0:
            raise VerifyError("attestation verification failed for %s (rc=%s%s)" % (
                expected_name, rc, ", timeout" if timed_out else ""))
        cert_digest = self._recheck(out, source_ref, source_digest, expected_sha256, expected_name)
        if self.log:
            self.log.info("attestation_ok", subject=expected_name, source_ref=source_ref)
        return cert_digest

    def _recheck(self, out: bytes, source_ref: str, source_digest: Optional[str], sha256: str, name: str) -> str:
        try:
            data = json.loads(out.decode("utf-8"))
        except ValueError:
            raise VerifyError("gh produced unparseable verification output")
        if not isinstance(data, list) or not data:
            raise VerifyError("gh produced no verification result")
        repo_url = "https://github.com/" + self.repo
        for entry in data:
            try:
                vr = entry["verificationResult"]
                cert = vr["signature"]["certificate"]
                stmt = vr["statement"]
                subjects = stmt["subject"]
                if stmt.get("predicateType") != PREDICATE_TYPE:
                    continue
                if cert.get("sourceRepositoryURI") != repo_url:
                    continue
                if cert.get("sourceRepositoryRef") != source_ref:
                    continue
                if source_digest and cert.get("sourceRepositoryDigest") != source_digest:
                    continue
                if cert.get("issuer") != OIDC_ISSUER or cert.get("runnerEnvironment") != "github-hosted":
                    continue
                san = cert.get("subjectAlternativeName", "")
                if not isinstance(san, str) or not san.startswith("https://github.com/%s@" % self.signer):
                    continue
                # the digest is what binds the bytes; the subject name is informational (a producer may rename)
                if any(isinstance(s, dict) and isinstance(s.get("digest"), dict) and s["digest"].get("sha256") == sha256
                       for s in subjects):
                    cd = cert.get("sourceRepositoryDigest")
                    if isinstance(cd, str) and versioning.SHA1_RE.fullmatch(cd):
                        return cd
            except (KeyError, TypeError, AttributeError):
                continue
        raise VerifyError("verified attestation does not cover %s (sha256) with the expected identity" % name)
