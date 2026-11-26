import json
import os
import stat

import pytest

import fixtures
from fixtures import Release, shim_calls

pytestmark = pytest.mark.skipif(__import__("platform").machine() != "x86_64", reason="x86-64 fixture ELF")


def test_good_feed_installs(env):
    r = env.fake.add(Release(203))
    res = env.run()
    assert res.result == "updated", env.out.getvalue()
    assert res.exit_code == 0 and res.tag == r.tag
    assert env.current() == r.tag
    app = os.path.join(env.paths.opt_dir, r.tag, "Moonlight.AppImage")
    assert stat.S_IMODE(os.stat(app).st_mode) == 0o755
    assert fixtures.sha(open(app, "rb").read()) == fixtures.sha(r.app)
    st = env.state()
    assert st["installed"]["tag"] == r.tag and st["installed"]["build"] == 60000 + 8 * 203
    # launcher + desktop entry
    launcher = open(env.paths.launcher).read()
    assert "current/Moonlight.AppImage" in launcher and "--appimage-extract-and-run" in launcher
    assert os.access(env.paths.launcher, os.X_OK)
    assert "Exec=" in open(env.paths.desktop_file).read()
    # gh invoked with the contract flags, offline root, no token, manifest first
    calls = [c["argv"] for c in shim_calls(env.gh)]
    assert calls[0] == ["attestation", "trusted-root"]
    verifies = [c for c in calls if c[:2] == ["attestation", "verify"]]
    assert len(verifies) == 3
    for v in verifies:
        for flag in ("--repo", "--bundle", "--signer-workflow", "--source-ref", "--deny-self-hosted-runners",
                     "--predicate-type", "--cert-oidc-issuer", "--custom-trusted-root", "--format"):
            assert flag in v
        assert v[v.index("--source-ref") + 1] == "refs/heads/build/v6.2.0-daily.203-n1"
        assert v[v.index("--signer-workflow") + 1] == fixtures.WORKFLOW
    assert os.path.basename(verifies[0][2]) == "manifest.json" and "--source-digest" not in verifies[0]
    assert os.path.basename(verifies[1][2]) == "SHA256SUMS" and "--source-digest" in verifies[1]
    assert "--source-digest" in verifies[2]
    assert not any(c["env_has_token"] for c in shim_calls(env.gh))
    # AppImage is only fetched after manifest + SUMS verification
    reqs = env.fake.requests
    assert reqs.index(next(p for p in reqs if p.endswith("Moonlight-6.2.0-daily.61624-x86_64.AppImage"))) > \
        reqs.index(next(p for p in reqs if p.endswith("attestation.sigstore.json")))
    assert "MLPU_RESULT=updated" in env.out.getvalue()


def test_second_run_is_noop_and_log_written(env):
    env.fake.add(Release(203))
    assert env.run().result == "updated"
    res = env.run()
    assert res.result == "noop"
    log = open(env.paths.log_file).read()
    assert "event=installed_ok" in log and "event=result" in log


def test_verify_only_installs_nothing(env):
    env.fake.add(Release(203, hours_old=0.1))     # cooling-off does not apply to verify-only
    res = env.run("verify-only")
    assert res.result == "verified", env.out.getvalue()
    assert env.current() is None
    assert not os.path.exists(env.paths.launcher)
    assert not os.path.exists(env.paths.opt_dir) or env.current() is None


def test_verify_only_explicit_tag(env):
    env.fake.add(Release(203))
    r2 = env.fake.add(Release(204))
    res = env.run("verify-only", r2.tag)
    assert res.result == "verified" and res.tag == r2.tag
    assert env.run("verify-only", "v6.2.0-daily.999-vp.1").result == "verify_failed"


def test_launcher_runs_the_installed_appimage(env):
    import subprocess
    r = env.fake.add(Release(203))
    assert env.run().result == "updated"
    out = subprocess.run([env.paths.launcher, "--version"], capture_output=True, text=True, timeout=30)
    assert out.returncode == 0 and "Moonlight 6.2.0-daily.61624" in out.stdout
    out = subprocess.run([env.paths.launcher, "--version"], capture_output=True, text=True, timeout=30,
                         env={"PATH": "/usr/bin:/bin", "MOONLIGHT_POSTURE_NO_FUSE": "1"})
    assert out.returncode == 0
    # no AppImage -> clear message, exit 127
    os.unlink(env.paths.current_link)
    out = subprocess.run([env.paths.launcher], capture_output=True, text=True)
    assert out.returncode == 127 and "no verified AppImage" in out.stderr
