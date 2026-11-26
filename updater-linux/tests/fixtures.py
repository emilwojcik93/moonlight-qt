"""Offline fixtures: a fake GitHub (API + downloads) on loopback, a `gh` shim that verifies the fixture bundles,
and a hand-assembled x86-64 ELF that stands in for the AppImage (prints `Moonlight <version>`)."""

from __future__ import annotations

import hashlib
import io
import json
import os
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional

from moonlight_posture_update import versioning
from moonlight_posture_update.net import HttpSettings
from moonlight_posture_update.paths import Paths
from moonlight_posture_update.updater import Deps

REPO = "emilwojcik93/moonlight-qt"
WORKFLOW = REPO + "/.github/workflows/patched-windows-release.yml"
SRC_SHA = "4ded6ac3b40ae5507545204f5abcb99a0c0720f2"
ELF_MIN = 1024 * 1024 + 4096


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def make_appimage(version: str, exit_code: int = 0, pad_to: int = ELF_MIN, salt: bytes = b"") -> bytes:
    """x86-64 ELF: write `Moonlight <version>\\n` to stdout, exit `exit_code`. Bytes 8..10 = AppImage type-2 magic."""
    msg = ("Moonlight %s\n" % version).encode()
    code_off = 64 + 56
    pre = b"\xb8\x01\x00\x00\x00" + b"\xbf\x01\x00\x00\x00"        # mov eax,1 ; mov edi,1
    lea_at = code_off + len(pre)
    post = b"\xba" + struct.pack("<I", len(msg)) + b"\x0f\x05"       # mov edx,len ; syscall
    post += b"\xb8\x3c\x00\x00\x00" + b"\xbf" + struct.pack("<I", exit_code) + b"\x0f\x05"
    msg_off = lea_at + 7 + len(post)
    lea = b"\x48\x8d\x35" + struct.pack("<i", msg_off - (lea_at + 7))
    code = pre + lea + post + msg
    total = code_off + len(code)
    ident = b"\x7fELF\x02\x01\x01\x00" + b"AI\x02" + b"\x00" * 5
    ehdr = ident + struct.pack("<HHIQQQIHHHHHH", 2, 0x3E, 1, 0x400000 + code_off, 64, 0, 0, 64, 56, 1, 64, 0, 0)
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, total, total, 0x1000)
    blob = ehdr + phdr + code
    body = salt + b"\x00" * max(0, pad_to - len(blob) - len(salt))
    return blob + body


def utc(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class Release:
    """Everything one fixture release serves, plus the API entry. Tamper by editing attributes before `fake.add`."""

    def __init__(self, u: int, n: int = 1, *, hours_old: float = 48.0, immutable: Any = True, owner: str = "Nonary",
                 appimage: Optional[bytes] = None, version: Optional[str] = None, exit_code: int = 0,
                 now: Optional[float] = None) -> None:
        self.key = versioning.parse_tag("v6.2.0-daily.%d-vp.%d" % (u, n))
        self.tag = self.key.tag
        self.build_version = versioning.build_version_for(self.key)
        self.appimage_name = versioning.appimage_name_for(self.key)
        self.app = appimage if appimage is not None else make_appimage(version or self.build_version, exit_code)
        self.published = (now or time.time()) - hours_old * 3600
        self.immutable = immutable
        self.owner = owner
        self.source_sha = SRC_SHA
        self.ref = versioning.source_ref_for(self.key)
        self.bundle_claims: Dict[str, Any] = {"repo": REPO, "workflow": WORKFLOW, "ref": self.ref,
                                              "digest": self.source_sha}
        self.manifest_overrides: Dict[str, Any] = {}
        self.manifest_linux_overrides: Dict[str, Any] = {}
        self.sums_extra = ""
        self.api_digest = True          # publish `digest` in the API like GitHub does
        self.api_size_delta = 0
        self.draft = False
        self.build()

    def build(self) -> None:
        a_sha = sha(self.app)
        linux = {"installer": self.appimage_name, "sha256": a_sha, "size": len(self.app)}
        linux.update(self.manifest_linux_overrides)
        man = {
            "schema": 1, "product": "moonlight", "tag": self.tag,
            "upstream": {"owner": self.owner, "repo": "moonlight-qt", "tag": "v6.2.0-daily.%d" % self.key.u,
                         "commit": "9" * 40, "release_id": 1},
            "build": {"n": self.key.n, "version": self.build_version, "number": self.key.build,
                      "workflow": ".github/workflows/patched-windows-release.yml",
                      "source_ref": self.ref, "source_sha": self.source_sha},
            "installer": "MoonlightSetup.exe",
            "assets": [{"name": "MoonlightSetup.exe", "sha256": "1" * 64, "size": 10}],
            "attestation": ["attestation.sigstore.json"],
            "created_at": utc(self.published),
            "linux": linux,
        }
        man.update(self.manifest_overrides)
        self.manifest = json.dumps(man, indent=2).encode()
        self.sums = ("%s  %s\n%s  manifest.json\n%s  MoonlightSetup.exe\n" % (
            a_sha, self.appimage_name, sha(self.manifest), "1" * 64) + self.sums_extra).encode()
        self.seal()

    def seal(self) -> None:
        """(Re)compute the fixture bundle over the current manifest / SHA256SUMS / AppImage bytes."""
        claims = dict(self.bundle_claims)
        claims["subjects"] = [sha(self.manifest), sha(self.sums), sha(self.app)]
        self.bundle = json.dumps({"fixture_bundle": True, "claims": claims}).encode()

    def files(self) -> Dict[str, bytes]:
        return {"manifest.json": self.manifest, "SHA256SUMS": self.sums, "attestation.sigstore.json": self.bundle,
                self.appimage_name: self.app, "MoonlightSetup.exe": b"MZ" + b"\0" * 8}

    def api_entry(self) -> Dict[str, Any]:
        assets = []
        for name, data in self.files().items():
            a = {"name": name, "size": len(data) + (self.api_size_delta if name == self.appimage_name else 0)}
            if self.api_digest:
                a["digest"] = "sha256:" + sha(data)
            assets.append(a)
        e = {"tag_name": self.tag, "draft": self.draft, "prerelease": True, "published_at": utc(self.published),
             "assets": assets}
        if self.immutable is not None:
            e["immutable"] = self.immutable
        return e


class FakeGitHub:
    def __init__(self) -> None:
        self.releases: List[Release] = []
        self.raw_api: Optional[Any] = None          # replace the release list body
        self.served: Dict[str, bytes] = {}          # (tag/name) -> bytes override
        self.truncate: Dict[str, int] = {}          # name -> bytes to send before closing
        self.redirect: set = set()                  # names served through a 302 to /blob/
        self.evil_redirect: set = set()             # names redirected to a non-allow-listed host
        self.chunked: set = set()                   # names served without Content-Length
        self.rate_limit = False
        self.always_304 = False
        self.etag_override: Optional[str] = None
        self.requests: List[str] = []
        self.conditional_hits = 0
        self.server: Optional[ThreadingHTTPServer] = None
        self.port = 0

    def add(self, r: Release) -> Release:
        self.releases.append(r)
        return r

    # ---- http -----------------------------------------------------------------------------------------------------
    def start(self) -> None:
        fake = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):  # silence
                pass

            def _send(self, code, body=b"", headers=None, length=True):
                self.send_response(code)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                if length:
                    self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if body:
                    self.wfile.write(body)

            def do_GET(self):  # noqa: N802
                fake.requests.append(self.path)
                p = self.path
                if p.startswith("/repos/") and "/releases" in p:
                    if fake.rate_limit:
                        return self._send(403, b"{}", {"x-ratelimit-remaining": "0"})
                    body = json.dumps(fake.raw_api if fake.raw_api is not None
                                      else [r.api_entry() for r in fake.releases]).encode()
                    etag = fake.etag_override or '"%s"' % sha(body)[:16]
                    inm = self.headers.get("If-None-Match")
                    if fake.always_304 or (inm and inm == etag):
                        fake.conditional_hits += 1
                        return self._send(304, b"", {"ETag": etag})
                    return self._send(200, body, {"ETag": etag, "Content-Type": "application/json"})
                if p.startswith("/dl/"):
                    parts = p.split("/")
                    tag, name = parts[-2], parts[-1]
                    if name in fake.evil_redirect:
                        return self._send(302, b"", {"Location": "http://localhost:%d/blob/%s/%s" % (fake.port, tag, name)})
                    if name in fake.redirect:
                        return self._send(302, b"", {"Location": "/blob/%s/%s" % (tag, name)})
                    return self._serve(tag, name)
                if p.startswith("/blob/"):
                    parts = p.split("/")
                    return self._serve(parts[-2], parts[-1])
                self._send(404, b"nope")

            def _serve(self, tag, name):
                data = fake.served.get(tag + "/" + name)
                if data is None:
                    for r in fake.releases:
                        if r.tag == tag and name in r.files():
                            data = r.files()[name]
                if data is None:
                    return self._send(404, b"missing")
                if name in fake.truncate:
                    n = fake.truncate[name]
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data[:n])
                    self.wfile.flush()
                    self.close_connection = True
                    return
                if name in fake.chunked:
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    for i in range(0, len(data), 65536):
                        c = data[i:i + 65536]
                        self.wfile.write(b"%x\r\n" % len(c) + c + b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                    return
                self._send(200, data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self) -> None:
        if self.server:
            self.server.shutdown()
            self.server.server_close()

    def settings(self) -> HttpSettings:
        base = "http://127.0.0.1:%d" % self.port
        return HttpSettings(api_base=base, download_base=base + "/dl", allowed_hosts=frozenset({"127.0.0.1"}),
                            require_https=False, use_env_proxy=False, api_timeout=10, small_timeout=10,
                            big_timeout=20, socket_timeout=5)


GH_SHIM = r'''#!%(py)s
import hashlib, json, os, sys
a = sys.argv[1:]
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": a, "env_has_token": any(k.startswith(("GH_TOKEN", "GITHUB_")) for k in os.environ)}) + "\n")
if any(k in os.environ for k in ("GH_TOKEN", "GITHUB_TOKEN")):
    sys.stderr.write("ambient token leaked into gh\n"); sys.exit(9)
if a[:2] == ["attestation", "trusted-root"]:
    if os.path.exists(os.path.join(here, "root_fail")):
        sys.stderr.write("tuf down\n"); sys.exit(1)
    print(json.dumps({"mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1"})); sys.exit(0)
if a[:2] != ["attestation", "verify"]:
    sys.exit(2)
fp = a[2]
opts = {}
i = 3
while i < len(a):
    if a[i] == "--deny-self-hosted-runners":
        opts[a[i]] = True; i += 1
    else:
        opts[a[i]] = a[i + 1]; i += 2
for need in ("--repo", "--bundle", "--signer-workflow", "--source-ref", "--predicate-type", "--cert-oidc-issuer",
             "--custom-trusted-root", "--deny-self-hosted-runners", "--format"):
    if need not in opts:
        sys.stderr.write("missing flag " + need + "\n"); sys.exit(1)
if not os.path.exists(opts["--custom-trusted-root"]):
    sys.stderr.write("no trusted root\n"); sys.exit(1)
bundle = json.load(open(opts["--bundle"]))
c = bundle["claims"]
digest = hashlib.sha256(open(fp, "rb").read()).hexdigest()
if digest not in c["subjects"]:
    sys.stderr.write("no matching subject\n"); sys.exit(1)
if opts["--repo"] != c["repo"] or opts["--signer-workflow"] != c["workflow"] or opts["--source-ref"] != c["ref"]:
    sys.stderr.write("identity mismatch\n"); sys.exit(1)
if "--source-digest" in opts and opts["--source-digest"] != c["digest"]:
    sys.stderr.write("digest mismatch\n"); sys.exit(1)
lie = c.get("liar")
rep_digest = "f" * 64 if lie == "subject" else digest
cert_digest = "0" * 40 if lie == "cert" else c["digest"]
out = [{"verificationResult": {
    "signature": {"certificate": {
        "issuer": "https://token.actions.githubusercontent.com", "runnerEnvironment": "github-hosted",
        "sourceRepositoryURI": "https://github.com/" + c["repo"], "sourceRepositoryRef": c["ref"],
        "sourceRepositoryDigest": cert_digest,
        "subjectAlternativeName": "https://github.com/" + c["workflow"] + "@" + c["ref"]}},
    "statement": {"predicateType": "https://slsa.dev/provenance/v1",
                  "subject": [{"name": "x", "digest": {"sha256": rep_digest}}]}}}]
print(json.dumps(out)); sys.exit(0)
'''


def write_gh_shim(directory: str) -> str:
    os.makedirs(directory, exist_ok=True)
    p = os.path.join(directory, "gh")
    with open(p, "w") as f:
        f.write(GH_SHIM % {"py": sys.executable})
    os.chmod(p, 0o755)
    return p


def shim_calls(gh_path: str) -> List[Dict[str, Any]]:
    p = os.path.join(os.path.dirname(gh_path), "calls.jsonl")
    if not os.path.exists(p):
        return []
    return [json.loads(l) for l in open(p).read().splitlines() if l]


class Env:
    """One sandbox: fake home, fake GitHub, gh shim, fake /proc, injected Deps. Never touches the real home."""

    def __init__(self, tmp: str) -> None:
        self.tmp = str(tmp)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.paths = Paths(self.home)
        self.fake = FakeGitHub()
        self.fake.start()
        self.gh = write_gh_shim(os.path.join(self.tmp, "ghbin"))
        self.proc = os.path.join(self.tmp, "proc")
        os.makedirs(self.proc)
        self.out = io.StringIO()
        self.display: Optional[Dict[str, str]] = {"WAYLAND_DISPLAY": "wayland-test"}
        self.clock_offset = 0.0
        self._n = 0

    def deps(self) -> Deps:
        self._n += 1
        return Deps(paths=self.paths, http=self.fake.settings(), gh_path=self.gh,
                    now=lambda: time.time() + self.clock_offset, proc_root=self.proc,
                    display=lambda: self.display, run_id="t%04d-%d" % (self._n, os.getpid()), stream=self.out)

    def updater(self):
        from moonlight_posture_update.updater import Updater
        return Updater(self.deps())

    def run(self, mode: str = "update", tag: Optional[str] = None):
        return self.updater().run(mode, tag)

    def set_policy(self, **kw) -> None:
        os.makedirs(self.paths.config_dir, exist_ok=True)
        p = self.paths.policy_file
        with open(p, "w") as f:
            json.dump(kw, f)
        os.chmod(p, 0o600)

    def fake_client(self, pid: int = 4242, comm: str = "moonlight") -> None:
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "comm"), "w").write(comm + "\n")
        open(os.path.join(d, "cmdline"), "wb").write(b"/usr/bin/moonlight\0")

    def state(self) -> Dict[str, Any]:
        return json.load(open(self.paths.state_file))

    def current(self) -> Optional[str]:
        try:
            return os.readlink(self.paths.current_link)
        except OSError:
            return None

    def close(self) -> None:
        self.fake.stop()
