"""Fail-closed behaviour of the verification chain: every case must install nothing and exit non-zero (or defer)."""
import json
import os

import pytest

import fixtures
from fixtures import Release, make_appimage, sha, shim_calls

pytestmark = pytest.mark.skipif(__import__("platform").machine() != "x86_64", reason="x86-64 fixture ELF")


def nothing_installed(env):
    assert env.current() is None
    assert not os.path.exists(env.paths.launcher)
    leftovers = [n for n in (os.listdir(env.paths.opt_dir) if os.path.isdir(env.paths.opt_dir) else [])]
    assert leftovers == [], leftovers


def test_tampered_appimage_caught_by_api_digest(env):
    r = env.fake.add(Release(203))
    t = bytearray(r.app); t[5000] ^= 0xFF
    env.fake.served[r.tag + "/" + r.appimage_name] = bytes(t)
    res = env.run()
    assert res.result == "verify_failed" and res.exit_code == 4
    assert "API digest" in res.detail
    nothing_installed(env)


def test_tampered_appimage_caught_by_attestation_when_api_has_no_digest(env):
    r = env.fake.add(Release(203))
    r.api_digest = False
    t = bytearray(r.app); t[5000] ^= 0xFF
    env.fake.served[r.tag + "/" + r.appimage_name] = bytes(t)
    res = env.run()
    assert res.result == "verify_failed" and "attestation verification failed" in res.detail
    nothing_installed(env)


def test_tampered_appimage_without_attestation_would_still_fail_hash(env):
    """manifest and SHA256SUMS are attested and say X; the bytes are Y: also refused when the bundle covers Y."""
    r = env.fake.add(Release(203))
    r.api_digest = False
    t = bytearray(r.app); t[5000] ^= 0xFF
    r.app = bytes(t)           # served bytes differ from what manifest/SUMS list
    r.seal()                   # attacker re-signs ONLY the AppImage subject
    res = env.run()
    assert res.result == "verify_failed" and "does not match SHA256SUMS" in res.detail
    nothing_installed(env)


def test_sha_mismatch_manifest_vs_sums(env):
    r = env.fake.add(Release(203))
    r.api_digest = False
    r.sums = r.sums.replace(sha(r.app).encode(), b"0" * 64)
    r.seal()
    res = env.run()
    assert res.result == "verify_failed" and "SHA256SUMS" in res.detail
    nothing_installed(env)


def test_sums_vs_manifest_disagree_but_file_matches_sums(env):
    r = env.fake.add(Release(203))
    r.api_digest = False
    r.manifest_linux_overrides = {"sha256": "0" * 64}
    r.build()
    r.sums = ("%s  %s\n" % (sha(r.app), r.appimage_name)).encode()
    r.seal()
    res = env.run()
    assert res.result == "verify_failed" and "manifest.json" in res.detail
    nothing_installed(env)


def test_manifest_hash_in_sums_must_match(env):
    r = env.fake.add(Release(203))
    r.sums = r.sums.replace(sha(r.manifest).encode(), b"a" * 64)
    r.seal()
    assert env.run().result == "verify_failed"
    nothing_installed(env)


@pytest.mark.parametrize("claim,value", [
    ("workflow", "emilwojcik93/moonlight-qt/.github/workflows/evil.yml"),
    ("repo", "evil/moonlight-qt"),
    ("ref", "refs/heads/automation"),
    ("digest", "1" * 40),
])
def test_wrong_signer_identity(env, claim, value):
    r = env.fake.add(Release(203))
    r.bundle_claims[claim] = value
    r.seal()
    res = env.run()
    assert res.result == "verify_failed" and res.exit_code == 4
    nothing_installed(env)
    # the AppImage must not even be downloaded when manifest/SUMS fail
    assert not any(p.endswith(".AppImage") for p in env.fake.requests)


@pytest.mark.parametrize("liar", ["subject", "cert"])
def test_gh_exit_zero_but_output_does_not_match_is_refused(env, liar):
    r = env.fake.add(Release(203))
    r.bundle_claims["liar"] = liar
    r.seal()
    res = env.run()
    assert res.result == "verify_failed"
    assert "does not cover" in res.detail or "differs from manifest" in res.detail
    nothing_installed(env)


def test_trusted_root_unavailable_defers(env):
    env.fake.add(Release(203))
    open(os.path.join(os.path.dirname(env.gh), "root_fail"), "w").close()
    res = env.run()
    assert res.result == "deferred" and res.exit_code == 8
    nothing_installed(env)
    assert not any(p.endswith(".AppImage") for p in env.fake.requests)


@pytest.mark.parametrize("name,over", [
    ("owner", {"upstream": {"owner": "Mallory", "repo": "x", "tag": "t", "commit": "9" * 40, "release_id": 1}}),
    ("tag", {"tag": "v6.2.0-daily.204-vp.1"}),
    ("schema", {"schema": 2}),
    ("product", {"product": "vibepollo"}),
    ("source_ref", {"build": {"n": 1, "version": "6.2.0-daily.61624", "source_ref": "refs/heads/automation", "source_sha": fixtures.SRC_SHA}}),
    ("build_version", {"build": {"n": 1, "version": "6.2.0-daily.61625", "source_ref": "refs/heads/build/v6.2.0-daily.203-n1", "source_sha": fixtures.SRC_SHA}}),
    ("source_sha", {"build": {"n": 1, "version": "6.2.0-daily.61624", "source_ref": "refs/heads/build/v6.2.0-daily.203-n1", "source_sha": "XYZ"}}),
    ("no_attestation", {"attestation": []}),
    ("attestation_traversal", {"attestation": ["../evil.sigstore.json"]}),
    ("linux_not_object", {"linux": "x"}),
])
def test_manifest_violations(env, name, over):
    r = env.fake.add(Release(203))
    r.manifest_overrides = over
    r.build()
    res = env.run()
    assert res.result == "verify_failed", (name, res)
    nothing_installed(env)


@pytest.mark.parametrize("name,over", [
    ("traversal", {"installer": "../../etc/passwd"}),
    ("bad_pattern", {"installer": "Moonlight-6.2.0-daily.61624-aarch64.AppImage"}),
    ("wrong_build", {"installer": "Moonlight-6.2.0-daily.61625-x86_64.AppImage"}),
    ("bad_sha", {"sha256": "ABC"}),
    ("zero_size", {"size": 0}),
    ("huge_size", {"size": 10 ** 12}),
    ("bool_size", {"size": True}),
])
def test_manifest_linux_violations(env, name, over):
    r = env.fake.add(Release(203))
    r.manifest_linux_overrides = over
    r.build()
    assert env.run().result == "verify_failed", name
    nothing_installed(env)


def test_manifest_without_linux_key_is_not_a_candidate_for_downloads(env):
    """Releases before v1.2 have no AppImage asset: skipped from the API list, nothing is downloaded."""
    r = Release(203)
    r.manifest_overrides = {}
    entry = r.api_entry()
    entry["assets"] = [a for a in entry["assets"] if not a["name"].endswith(".AppImage")]
    env.fake.raw_api = [entry]
    res = env.run()
    assert res.result == "noop" and "no AppImage" in res.detail
    assert not any("/dl/" in p for p in env.fake.requests)


def test_manifest_duplicate_keys_and_garbage(env):
    r = env.fake.add(Release(203))
    r.manifest = r.manifest.replace(b'"schema": 1', b'"schema": 1, "schema": 1')
    r.seal()
    assert env.run().result == "verify_failed"
    env.updater().clear_deny(None)       # forget the backoff of the first failure
    r.manifest = b"\xff\xfe not json"
    r.seal()
    assert env.run().result == "verify_failed"


def test_sums_malformed_and_duplicate(env):
    r = env.fake.add(Release(203))
    r.sums = r.sums + b"zzz not a sums line\n"
    r.seal()
    assert env.run().result == "verify_failed"
    env.updater().clear_deny(None)
    r.sums = (b"%s  %s\n" % (sha(r.app).encode(), r.appimage_name.encode())) * 2
    r.seal()
    assert env.run().result == "verify_failed"


def test_not_immutable_or_draft_never_chosen(env):
    env.fake.add(Release(203, immutable=False))
    env.fake.add(Release(204, immutable=None))
    d = env.fake.add(Release(205)); d.draft = True
    res = env.run()
    assert res.result == "noop"
    assert not any("/dl/" in p for p in env.fake.requests)


def test_gh_wrong_location_is_refused(monkeypatch, tmp_path):
    from moonlight_posture_update import attest
    from moonlight_posture_update.errors import VerifyError
    f = tmp_path / "gh"; f.write_text("#!/bin/sh\n"); f.chmod(0o755)
    monkeypatch.setattr(attest, "GH_CANDIDATES", (str(f),))      # owned by us, not root -> refused
    with pytest.raises(VerifyError):
        attest.find_gh()


def test_redirect_inside_allowlist_works_and_evil_redirect_refused(env):
    r = env.fake.add(Release(203))
    env.fake.redirect = {"manifest.json", r.appimage_name}
    assert env.run().result == "updated"
    # new sandbox state: evil redirect to a host that is not allow-listed
    env.fake.releases.clear()
    r2 = env.fake.add(Release(204))
    env.fake.redirect = set()
    env.fake.evil_redirect = {"manifest.json"}
    res = env.run()
    assert res.result == "verify_failed" and "host not allowed" in res.detail
    assert env.current() == r.tag


def test_rate_limit_defers(env):
    env.fake.add(Release(203))
    env.fake.rate_limit = True
    res = env.run()
    assert res.result == "deferred" and res.exit_code == 8
    nothing_installed(env)
    assert env.state()["attempts"] == {}


def test_failures_back_off_then_deny(env):
    r = env.fake.add(Release(203))
    r.bundle_claims["workflow"] = "x/y/.github/workflows/z.yml"
    r.seal()
    assert env.run().result == "verify_failed"
    assert env.state()["attempts"][r.tag]["verify"] == 1
    # backoff: the next run does not even download
    n = len(env.fake.requests)
    res = env.run()
    assert res.result == "noop" and "backoff" in res.detail
    # after the backoff expires, two more failures deny the tag
    for _ in range(2):
        s = env.state(); s["attempts"][r.tag]["not_before"] = 0
        json.dump(s, open(env.paths.state_file, "w"))
        assert env.run().result == "verify_failed"
    assert r.tag in env.state()["deny"]
    res = env.run()
    assert res.result == "noop" and "denied" in res.detail
