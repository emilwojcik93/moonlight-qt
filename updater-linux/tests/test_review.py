"""Second review round: remote policy, gh trust/classification, report-only, sandbox, kill safety, slow drip, rollback persistence."""
import json
import os
import shutil
import subprocess
import sys
import time

import pytest

from fixtures import POLICY_YML, Release
from moonlight_posture_update import attest, net, remote_policy, versioning

pytestmark = pytest.mark.skipif(__import__("platform").machine() != "x86_64", reason="x86-64 fixture ELF")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def set_remote(env, text):
    """New policy.yml content = new commit on `automation` (the client caches per sha)."""
    env.fake.policy_yml = text
    env.fake.branch_sha = "%040x" % (int(env.fake.branch_sha, 16) + 1)


def downloads(env):
    return [p for p in env.fake.requests if "/dl/" in p]


# ---- remote policy (branch automation) -----------------------------------------------------------------------------------

def test_remote_hold_stops_before_the_release_list(env):
    env.fake.add(Release(203))
    env.fake.policy_yml = POLICY_YML.replace("hold: false", "hold: true")
    res = env.run()
    assert res.result == "held" and res.exit_code == 0
    assert not any("/releases?" in p for p in env.fake.requests) and env.current() is None


def test_remote_deny_list_is_honoured(env):
    env.fake.add(Release(203)); env.fake.add(Release(204))
    env.fake.policy_yml = POLICY_YML.replace("deny: []", "deny: [v6.2.0-daily.204-vp.1]")
    assert env.run().tag == "v6.2.0-daily.203-vp.1"


def test_remote_policy_can_only_narrow(env):
    r = env.fake.add(Release(203, owner="Mallory"))
    # widening the owner list remotely does not help: the local (baked-in) list still decides
    set_remote(env, POLICY_YML.replace("[Nonary]", "[Nonary, Mallory]"))
    assert env.run().result == "verify_failed"
    # a remote list without any locally allowed owner stops everything
    set_remote(env, POLICY_YML.replace("[Nonary]", "[Mallory]"))
    res = env.run()
    assert res.exit_code == 3 and env.current() is None
    # remote cooling-off floor raises the wait
    env.fake.releases.clear(); env.fake.add(Release(204, hours_old=10))
    set_remote(env, POLICY_YML.replace("canary: 0", "canary: 30"))
    env.set_policy(min_cooling_off_hours=0)
    res = env.run()
    assert res.result == "noop" and "cooling-off" in res.detail
    set_remote(env, POLICY_YML.replace("canary: 0", "canary: 5"))
    assert env.run().result == "updated"
    assert r.tag != env.current()


@pytest.mark.parametrize("status", [500, 404, 403])
def test_remote_policy_unavailable_defers_and_never_installs(env, status):
    env.fake.add(Release(203))
    env.fake.policy_status = status
    res = env.run()
    assert res.exit_code == 8 and res.result == "deferred"
    assert env.current() is None and downloads(env) == []
    assert env.state()["attempts"] == {}


@pytest.mark.parametrize("text", [
    "schema: 1\nallow_upstream_owners: &a [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\ndeny: []\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\ndeny: []\nhold: true\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours:\n  stable: 24\n  canary: 0\nhold: false\n",
    "schema: 1\nallow_upstream_owners: ['Nonary']\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: maybe\n",
    "schema: 1\nallow_upstream_owners: []\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\n",
    "schema: 1\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\n",
    "schema: 2\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\nbogus: 1\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: false\ndeny: [../x]\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: -1}\nhold: false\n",
    "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\nhold: !!bool false\n",
    "",
    "\x00\x01",
])
def test_remote_policy_parse_errors_fail_closed(env, text):
    env.fake.add(Release(203))
    env.fake.policy_yml = text
    res = env.run()
    assert res.exit_code == 3 and env.current() is None and downloads(env) == []


def test_remote_policy_size_cap(env):
    env.fake.add(Release(203))
    env.fake.policy_yml = POLICY_YML + "# " + "x" * 70000 + "\n"
    assert env.run().exit_code == 3


def test_remote_policy_is_cached_per_sha_and_branch_is_conditional(env):
    env.fake.add(Release(203, hours_old=1))
    assert env.run().result == "noop"
    assert env.run().result == "noop"
    assert len(env.fake.contents_requests) == 1 and env.fake.branch_conditional == 1
    assert "ref=" + "a" * 40 in env.fake.contents_requests[0]            # pinned to the commit sha
    env.fake.branch_sha = "b" * 40
    env.fake.policy_yml = POLICY_YML.replace("keep_releases: 10", "keep_releases: 11")
    assert env.run().result == "noop"
    assert len(env.fake.contents_requests) == 2 and "ref=" + "b" * 40 in env.fake.contents_requests[1]


def test_remote_policy_missing_deny_key_is_tolerated_and_extensions_ignored(env):
    env.fake.add(Release(203))
    env.fake.policy_yml = POLICY_YML.replace("deny: []\n", "") + "x-supported_floor_tag: v6.2.0-daily.201\n"
    assert env.run().result == "updated"
    assert "remote_policy_no_deny_key" in open(env.paths.log_file).read()


def test_verify_only_ignores_remote_hold(env):
    env.fake.add(Release(203))
    env.fake.policy_yml = POLICY_YML.replace("hold: false", "hold: true")
    assert env.run("verify-only").result == "verified"


def test_yaml_subset_unit():
    d = remote_policy.parse_yaml(POLICY_YML)
    assert d["cooling_off_hours"] == {"stable": 24, "canary": 0} and d["deny"] == [] and d["hold"] is False


# ---- gh trust and error classification ------------------------------------------------------------------------------------

def test_gh_missing_is_a_config_error_and_never_counts(env, monkeypatch):
    env.fake.add(Release(203))
    monkeypatch.setattr(attest, "GH_CANDIDATES", ())
    deps = env.deps(); deps.gh_path = None
    from moonlight_posture_update.updater import Updater
    for _ in range(4):
        res = Updater(deps).run()
        assert res.exit_code == 3 and res.result == "failed" and "gh not found" in res.detail
    s = env.state()
    assert s["attempts"] == {} and s["deny"] == [] and downloads(env) == []


@pytest.mark.parametrize("out", ["gh version 2.67.0 (2025-01-01)", "gh version 1.9.0", "something else", ""])
def test_gh_too_old_or_unrecognised_is_a_config_error(env, out):
    env.fake.add(Release(203))
    open(os.path.join(os.path.dirname(env.gh), "version"), "w").write(out)
    for _ in range(3):
        res = env.run()
        assert res.exit_code == 3, res
    assert env.state()["attempts"] == {} and env.state()["deny"] == [] and downloads(env) == []


def test_gh_floor_constants():
    assert attest.GH_MIN_VERSION == (2, 68, 0) and attest.GH_TESTED_VERSION == (2, 105, 0)


def test_trusted_root_failure_is_transient_only(env):
    r = env.fake.add(Release(203))
    open(os.path.join(os.path.dirname(env.gh), "root_fail"), "w").close()
    for _ in range(5):
        s = env.state() if os.path.exists(env.paths.state_file) else None
        if s and s["attempts"]:
            s["attempts"][r.tag]["not_before"] = 0
            json.dump(s, open(env.paths.state_file, "w"))
        assert env.run().exit_code == 8
    a = env.state()["attempts"][r.tag]
    assert a["transient"] == 5 and a["verify"] == 0 and env.state()["deny"] == []


def test_gh_verify_timeout_is_transient(env, monkeypatch):
    r = env.fake.add(Release(203))
    open(os.path.join(os.path.dirname(env.gh), "verify_hang"), "w").close()
    monkeypatch.setattr(attest, "VERIFY_TIMEOUT", 1)
    res = env.run()
    assert res.exit_code == 8 and "timed out" in res.detail
    a = env.state()["attempts"][r.tag]
    assert a["transient"] == 1 and a["verify"] == 0


def test_real_verification_failure_still_counts(env):
    r = env.fake.add(Release(203))
    r.bundle_claims["workflow"] = "a/b/.github/workflows/c.yml"; r.seal()
    assert env.run().exit_code == 4
    assert env.state()["attempts"][r.tag]["verify"] == 1


def test_file_changing_after_gh_looked_at_it_is_refused(env):
    env.fake.add(Release(203))
    open(os.path.join(os.path.dirname(env.gh), "mutate_after"), "w").close()
    res = env.run()
    assert res.exit_code == 4 and "changed while" in res.detail and env.current() is None


def test_gh_environment_is_an_allowlist(monkeypatch, tmp_path):
    for k, v in (("FOO_SECRET", "s"), ("AWS_SECRET_ACCESS_KEY", "k"), ("GH_TOKEN", "t"), ("LD_PRELOAD", "/evil.so"),
                 ("HTTPS_PROXY", "http://p:1"), ("LANG", "C"), ("PATH", "/usr/bin")):
        monkeypatch.setenv(k, v)
    env = attest.gh_environment(str(tmp_path / "gh"))
    assert set(env) <= set(attest.ENV_ALLOW) | {"HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR",
                                                "GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER",
                                                "GH_NO_EXTENSION_UPDATE_NOTIFIER", "GH_SPINNER_DISABLED", "NO_COLOR"}
    assert env["HTTPS_PROXY"] == "http://p:1" and "FOO_SECRET" not in env and "LD_PRELOAD" not in env
    assert env["HOME"].startswith(str(tmp_path))


def test_gh_parent_directories_must_be_root_owned_and_closed():
    assert not attest._dir_ok("/tmp")                   # world-writable
    assert attest._dir_ok("/usr/bin") or os.stat("/usr/bin").st_uid != 0


# ---- report-only (first run) -----------------------------------------------------------------------------------------------

def test_default_mode_is_report_only_and_downloads_nothing(env):
    env.fake.add(Release(203))
    os.unlink(env.paths.policy_file)                       # no policy at all
    res = env.run()
    assert res.result == "report-only" and res.exit_code == 0 and "would install" in res.detail
    assert env.current() is None and downloads(env) == [] and not os.path.exists(env.paths.launcher)
    assert env.run("verify-only").result == "verified"      # the rehearsal works in report-only
    env.updater().set_mode("install")
    assert env.run().result == "updated"


# ---- health / copy integrity ------------------------------------------------------------------------------------------------

def test_oserror_in_post_switch_check_restores_previous(env, monkeypatch):
    from moonlight_posture_update import updater as up
    env.fake.add(Release(203)); assert env.run().result == "updated"
    env.fake.add(Release(204))
    real = up.smoke.run_smoke
    n = {"c": 0}

    def flaky(*a, **k):
        n["c"] += 1
        if n["c"] == 2:
            raise OSError(5, "Input/output error")
        return real(*a, **k)
    monkeypatch.setattr(up.smoke, "run_smoke", flaky)
    res = env.run()
    assert res.exit_code == 5 and env.current() == "v6.2.0-daily.203-vp.1"


def test_stage_copy_that_differs_from_the_verified_hash_is_refused(env, monkeypatch):
    from moonlight_posture_update import store
    env.fake.add(Release(203))
    real = store.Store.stage

    def evil(self, src, *a, **k):
        with open(src, "r+b") as f:                          # file swapped after verification
            f.seek(4000); f.write(b"EVIL")
        return real(self, src, *a, **k)
    monkeypatch.setattr(store.Store, "stage", evil)
    res = env.run()
    assert res.exit_code == 5 and "verified hash" in res.detail
    assert env.current() is None and [n for n in os.listdir(env.paths.opt_dir) if n.startswith(".stage")] == []


# ---- slow drip ---------------------------------------------------------------------------------------------------------------

def test_slow_drip_hits_the_deadline(env):
    r = env.fake.add(Release(203))
    env.fake.drip = {r.appimage_name}
    env.fake.timeouts = {"big_timeout": 1.5}
    t0 = time.monotonic()
    res = env.run()
    assert time.monotonic() - t0 < 15
    assert res.exit_code == 8 and "deadline" in res.detail
    assert env.current() is None
    for d in os.listdir(env.paths.runs_dir):
        assert not [f for f in os.listdir(os.path.join(env.paths.runs_dir, d)) if f.endswith(".AppImage")]


@pytest.mark.parametrize("v,exp", [("123", 123), ("²", None), ("٣", None), ("", None), (None, None),
                                   ("1" * 40, None), (" 5", None), ("5 ", None), ("-1", None)])
def test_content_length_parsing_rejects_unicode_digits(v, exp):
    assert net.parse_len(v) == exp


# ---- rollback persistence ------------------------------------------------------------------------------------------------------

def two_versions(env):
    env.fake.add(Release(203)); assert env.run().result == "updated"
    env.fake.releases = []; env.fake.add(Release(204)); assert env.run().result == "updated"


def test_rollback_persists_deny_and_floor_in_policy_json(env):
    two_versions(env)
    assert env.updater().rollback().result == "rolled_back"
    pol = json.load(open(env.paths.policy_file))
    assert pol["deny"] == ["v6.2.0-daily.204-vp.1"]
    assert pol["min_build"] == versioning.parse_tag("v6.2.0-daily.204-vp.1").build + 1 and pol["mode"] == "install"
    # state.json lost: the denial and the floor survive
    open(env.paths.state_file, "w").write("garbage")
    env.fake.releases = []
    env.fake.add(Release(203, 2)); env.fake.add(Release(204))
    res = env.run()
    assert res.result == "noop", res        # 204-vp.1 denied, 203-vp.2 below the floor although newer than installed
    assert env.current() == "v6.2.0-daily.203-vp.1"
    env.fake.add(Release(204, 2))
    assert env.run().tag == "v6.2.0-daily.204-vp.2"


def test_rollback_with_unusable_policy_still_rolls_back_and_says_so(env):
    two_versions(env)
    open(env.paths.policy_file, "w").write("{broken"); os.chmod(env.paths.policy_file, 0o600)
    res = env.updater().rollback()
    assert res.result == "rolled_back" and "NOT updated" in res.detail
    assert env.current() == "v6.2.0-daily.203-vp.1"


def test_clear_deny_also_edits_policy_json(env):
    two_versions(env)
    env.updater().rollback()
    env.updater().clear_deny("v6.2.0-daily.204-vp.1")
    assert json.load(open(env.paths.policy_file))["deny"] == []
    assert "v6.2.0-daily.204-vp.1" not in env.state()["deny"]


# ---- kill safety -----------------------------------------------------------------------------------------------------------------

def run_runner(env, kill, tmp_path, probe=False, lib=ROOT, prefix_cmd=None):
    cfg = tmp_path / ("cfg-%s.json" % kill)
    cfg.write_text(json.dumps({"lib": lib, "home": env.home, "port": env.fake.port, "gh": env.gh, "proc": env.proc,
                               "kill": kill, "probe": probe}))
    cmd = (prefix_cmd or []) + [sys.executable, "-I", os.path.join(ROOT, "tests", "runner.py"), str(cfg)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180)


@pytest.mark.parametrize("point", ["before_commit", "before_switch", "after_switch"])
def test_kill_mid_install_leaves_a_valid_current(env, tmp_path, point):
    env.fake.add(Release(203)); assert env.run().result == "updated"
    env.fake.add(Release(204))
    r = run_runner(env, point, tmp_path)
    assert r.returncode == -9, (r.returncode, r.stdout[-300:], r.stderr[-300:])
    cur = env.current()
    want = "v6.2.0-daily.204-vp.1" if point == "after_switch" else "v6.2.0-daily.203-vp.1"
    assert cur == want
    assert os.path.isfile(os.path.join(env.paths.current_link, "Moonlight.AppImage"))       # never dangling
    res = env.run()                                                                         # next run recovers
    assert res.result in ("updated", "noop")
    assert env.current() == "v6.2.0-daily.204-vp.1"
    s = env.state()
    assert s["installed"]["tag"] == "v6.2.0-daily.204-vp.1"
    assert os.path.isfile(os.path.join(env.paths.opt_dir, "v6.2.0-daily.204-vp.1", "Moonlight.AppImage"))


# ---- the unit's real sandbox ---------------------------------------------------------------------------------------------------------

def user_manager_available():
    if not shutil.which("systemd-run") or not shutil.which("systemctl"):
        return False
    r = subprocess.run(["systemctl", "--user", "is-system-running"], capture_output=True, text=True)
    return r.stdout.strip() in ("running", "degraded")


def unit_sandbox_properties(prefix):
    keys = ("NoNewPrivileges", "ProtectSystem", "ProtectHome", "ReadWritePaths", "ProtectKernelTunables",
            "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups", "ProtectClock", "ProtectHostname",
            "RestrictSUIDSGID", "RestrictRealtime", "LockPersonality", "RestrictAddressFamilies", "SystemCallArchitectures",
            "UMask")
    props = []
    for line in open(os.path.join(ROOT, "systemd", "moonlight-posture-update.service")):
        k, _, v = line.strip().partition("=")
        if k in keys:
            props.append("-p%s=%s" % (k, v.replace("%h", prefix)))
    assert len(props) >= 12
    return props


@pytest.mark.skipif(not user_manager_available(), reason="no systemd user manager here")
def test_service_sandbox_acceptance(env, tmp_path):
    """The unit's own sandbox properties (ProtectSystem=strict, ProtectHome=read-only, ReadWritePaths=...) applied to a
    transient unit via systemd-run --user --wait --collect. Nothing persistent is installed or enabled."""
    prefix = env.home
    ins = subprocess.run([os.path.join(ROOT, "install.sh"), "--prefix", prefix], capture_output=True, text=True)
    assert ins.returncode == 0, ins.stderr
    env.fake.add(Release(203))
    lib = os.path.join(prefix, ".local/lib/moonlight-posture-updater")
    cmd = ["systemd-run", "--user", "--wait", "--collect", "--pipe", "-qG"] + unit_sandbox_properties(prefix)
    r = run_runner(env, None, tmp_path, probe=True, lib=lib, prefix_cmd=cmd)
    assert r.returncode == 0, (r.stdout[-800:], r.stderr[-800:])
    out = json.loads(r.stdout.strip().splitlines()[-1])
    assert out["result"] == "updated", out
    # the sandbox really was active: /tmp, the code dir and ~/.local/bin are read-only, the state dir is writable
    assert out["probe"] == {"tmp_writable": False, "lib_writable": False, "bin_writable": False, "state_writable": True}
    assert env.current() == "v6.2.0-daily.203-vp.1"
    assert os.path.exists(env.paths.launcher)


def test_acceptance_helper_reads_the_real_unit():
    props = unit_sandbox_properties("/x")
    assert "-pProtectSystem=strict" in props and any(p.startswith("-pReadWritePaths=/x/.local/state") for p in props)
