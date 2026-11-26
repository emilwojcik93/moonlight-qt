"""Real `gh` + real public release v6.2.0-daily.202-vp.1 (Windows feed). Opt-in: MLPU_NETWORK_TESTS=1.

Reproduces the experiment behind the design: `gh attestation verify --bundle` needs no login and no token, only network
access for the Sigstore trusted root (fetched once with `gh attestation trusted-root`, then verification is offline).
"""
import hashlib
import os
import shutil
import urllib.request

import pytest

from moonlight_posture_update import attest
from moonlight_posture_update.errors import NetworkDeferral, VerifyError

pytestmark = [pytest.mark.network,
              pytest.mark.skipif(os.environ.get("MLPU_NETWORK_TESTS") != "1", reason="set MLPU_NETWORK_TESTS=1"),
              pytest.mark.skipif(not os.path.exists("/usr/bin/gh"), reason="gh not installed")]

BASE = "https://github.com/emilwojcik93/moonlight-qt/releases/download/v6.2.0-daily.202-vp.1/"
REPO = "emilwojcik93/moonlight-qt"
SIGNER = REPO + "/.github/workflows/patched-windows-release.yml"
REF = "refs/heads/build/v6.2.0-daily.202-n1"
SRC = "4ded6ac3b40ae5507545204f5abcb99a0c0720f2"


@pytest.fixture(scope="module")
def assets(tmp_path_factory):
    d = tmp_path_factory.mktemp("real")
    out = {}
    for n in ("manifest.json", "SHA256SUMS", "attestation.sigstore.json"):
        p = d / n
        with urllib.request.urlopen(BASE + n, timeout=60) as r:
            p.write_bytes(r.read())
        out[n] = str(p)
    out["dir"] = d
    return out


def make(assets, tmp_path, monkeypatch):
    for k in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))                  # throw-away HOME: no stored login anywhere
    a = attest.Attestor(attest.find_gh(), str(tmp_path / "gh"), REPO, SIGNER, str(tmp_path), None)
    a.fetch_trusted_root()
    return a


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def test_real_unauthenticated_offline_verify(assets, tmp_path, monkeypatch):
    a = make(assets, tmp_path, monkeypatch)
    m, s, b = assets["manifest.json"], assets["SHA256SUMS"], assets["attestation.sigstore.json"]
    assert a.verify(m, b, REF, None, sha(m), "manifest.json") == SRC
    assert a.verify(s, b, REF, SRC, sha(s), "SHA256SUMS") == SRC


def test_real_negatives(assets, tmp_path, monkeypatch):
    a = make(assets, tmp_path, monkeypatch)
    m, s, b = assets["manifest.json"], assets["SHA256SUMS"], assets["attestation.sigstore.json"]
    with pytest.raises(VerifyError):
        a.verify(m, b, "refs/heads/build/v6.2.0-daily.203-n1", None, sha(m), "manifest.json")
    with pytest.raises(VerifyError):
        a.verify(s, b, REF, "0" * 40, sha(s), "SHA256SUMS")
    bad = tmp_path / "tampered"; bad.write_bytes(open(s, "rb").read() + b"x")
    with pytest.raises(VerifyError):
        a.verify(str(bad), b, REF, SRC, sha(str(bad)), "SHA256SUMS")
    a2 = attest.Attestor(a.gh, str(tmp_path / "gh"), REPO, REPO + "/.github/workflows/evil.yml", str(tmp_path), None)
    a2.root = a.root
    with pytest.raises(VerifyError):
        a2.verify(m, b, REF, None, sha(m), "manifest.json")
