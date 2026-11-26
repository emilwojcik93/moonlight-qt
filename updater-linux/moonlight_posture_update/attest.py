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

from . import fsio, versioning
from .errors import ConfigError, NetworkDeferral, VerifyError

GH_CANDIDATES = ("/usr/bin/gh", "/usr/local/bin/gh")
PREDICATE_TYPE = "https://slsa.dev/provenance/v1"
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
TRUSTED_ROOT_TIMEOUT = 120
VERIFY_TIMEOUT = 180
MAX_OUT = 4 * 1024 * 1024


# gh 2.68.0 added --source-ref / --source-digest to `attestation verify`; 2.67.x could exit 0 when no attestation matched
# (fixed later, and re-checked here by parsing the verified JSON); 2.58.0 removed the auth requirement of
# `attestation trusted-root`. 2.105.0 is the version this code was tested with.
GH_MIN_VERSION = (2, 68, 0)
GH_TESTED_VERSION = (2, 105, 0)
VERSION_RE = re.compile(r"gh version ([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})")

# environment variables gh may see (everything else is dropped); proxies and CA settings are the user's network setup
ENV_ALLOW = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ",
             "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "no_proxy", "all_proxy",
             "SSL_CERT_FILE", "SSL_CERT_DIR")


def _dir_ok(path: str) -> bool:
    st = os.stat(path)
    return stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022


def find_gh() -> str:
    """Fixed absolute locations only (no PATH lookup). The binary and every parent directory must be root-owned and
    not group/world-writable. Raises ConfigError (not a verification failure: nothing is wrong with a release)."""
    for p in GH_CANDIDATES:
        try:
            st = os.stat(p)
            if not stat.S_ISREG(st.st_mode) or not os.access(p, os.X_OK):
                continue
            if st.st_uid != 0 or st.st_mode & 0o022:
                continue
            parent = os.path.dirname(p)
            ok = True
            while True:
                if not _dir_ok(parent):
                    ok = False
                    break
                if parent == "/":
                    break
                parent = os.path.dirname(parent)
            if ok:
                return p
        except OSError:
            continue
    raise ConfigError("gh not found at a trusted root-owned location (%s); install the `github-cli` package"
                      % ", ".join(GH_CANDIDATES))


def gh_environment(gh_dir: str) -> Dict[str, str]:
    """Child environment by ALLOWLIST: a few harmless variables, the user's proxy/CA settings, and private
    HOME/config/cache/tmp directories under the state directory (no stored login or keyring token is ever used)."""
    env = {k: os.environ[k] for k in ENV_ALLOW if k in os.environ}
    d = {n: os.path.join(gh_dir, n) for n in ("home", "config", "xdg-config", "cache", "tmp")}
    for p in d.values():
        os.makedirs(p, mode=0o700, exist_ok=True)
    env.update({
        "HOME": d["home"], "GH_CONFIG_DIR": d["config"], "XDG_CONFIG_HOME": d["xdg-config"],
        "XDG_CACHE_HOME": d["cache"], "TMPDIR": d["tmp"],
        "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED": "1", "NO_COLOR": "1",
    })
    return env


def prepare_gh(path: Optional[str], gh_dir: str, log=None) -> str:
    """Locate (unless injected), then probe `gh --version` against the floor. ConfigError when unusable."""
    gh = path or find_gh()
    rc, out, err, timed_out = _run([gh, "--version"], gh_environment(gh_dir), 15)
    m = VERSION_RE.match(out.decode("utf-8", "replace")) if rc == 0 else None
    if not m:
        raise ConfigError("`gh --version` failed or is not recognised")
    ver = tuple(int(x) for x in m.groups())
    if ver < GH_MIN_VERSION:
        raise ConfigError("gh %s is older than the required %s (tested with %s)" % (
            ".".join(map(str, ver)), ".".join(map(str, GH_MIN_VERSION)), ".".join(map(str, GH_TESTED_VERSION))))
    if log:
        log.info("gh_ok", path=gh, version=".".join(map(str, ver)))
    return gh


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
        if timed_out:
            raise NetworkDeferral("gh attestation verify timed out for %s" % expected_name)
        if rc != 0:
            raise VerifyError("attestation verification failed for %s (rc=%s%s)" % (
                expected_name, rc, ", timeout" if timed_out else ""))
        # read-once discipline: the bytes gh looked at must still be the bytes we hashed and parsed
        if fsio.sha256_file(file_path) != expected_sha256:
            raise VerifyError("%s changed while it was being verified" % expected_name)
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
