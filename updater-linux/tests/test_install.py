"""Install, rollback, atomicity, resource failures, state/policy robustness."""
import errno
import fcntl
import json
import os
import stat
import threading

import pytest

from fixtures import Release, make_appimage
from moonlight_posture_update import fsio, policy as pol, state as st, versioning
from moonlight_posture_update.errors import ConfigError

pytestmark = pytest.mark.skipif(__import__("platform").machine() != "x86_64", reason="x86-64 fixture ELF")


def path_of(fh):
    n = getattr(fh, "name", "")
    return os.readlink("/proc/self/fd/%d" % n) if isinstance(n, int) else str(n)


def tags_on_disk(env):
    return sorted(n for n in os.listdir(env.paths.opt_dir) if versioning.is_tag(n))


# ---- smoke test / health --------------------------------------------------------------------------------------------

def test_smoke_wrong_version_refuses_install(env):
    r = env.fake.add(Release(203, version="6.2.0-daily.99999"))      # binary reports another version
    res = env.run()
    assert res.result == "failed" and res.exit_code == 5 and "did not report" in res.detail
    assert env.current() is None and os.listdir(env.paths.opt_dir) == []
    assert env.state()["attempts"][r.tag]["install"] == 1


def test_smoke_crash_keeps_previous_version(env):
    env.fake.add(Release(203))
    assert env.run().result == "updated"
    env.fake.add(Release(204, exit_code=3))
    res = env.run()
    assert res.exit_code == 5
    assert env.current() == "v6.2.0-daily.203-vp.1" and tags_on_disk(env) == ["v6.2.0-daily.203-vp.1"]


def test_two_install_failures_deny_the_tag(env):
    r = env.fake.add(Release(203, exit_code=1))
    assert env.run().exit_code == 5
    s = env.state(); s["attempts"][r.tag]["not_before"] = 0; json.dump(s, open(env.paths.state_file, "w"))
    assert env.run().exit_code == 5
    assert r.tag in env.state()["deny"]


def test_no_display_defers_in_display_mode(env):
    env.fake.add(Release(203))
    env.display = None
    res = env.run()
    assert res.result == "deferred" and res.exit_code == 0 and "display" in res.detail
    assert env.current() is None and not os.path.exists(env.paths.opt_dir)
    assert not any("/dl/" in p for p in env.fake.requests)          # decided BEFORE downloading anything
    assert env.state()["attempts"] == {}


def test_static_smoke_mode_rejects_stub_without_payload(env):
    env.fake.add(Release(203))
    env.display = None
    env.set_policy(smoke_test="static")
    res = env.run()
    assert res.exit_code == 5 and "extract" in res.detail


REAL = os.path.expanduser("~/src/stream-posture-sync/appimage-test/Moonlight.AppImage")


@pytest.mark.skipif(not os.path.exists(REAL), reason="real 6.2.0-daily.202 AppImage not on this machine")
def test_static_smoke_on_a_real_appimage(tmp_path):
    from moonlight_posture_update import smoke
    smoke.run_smoke(REAL, "6.2.0-daily.202", "static", str(tmp_path), None)
    with pytest.raises(Exception):
        smoke.run_smoke(REAL, "6.2.0-daily.99999", "static", str(tmp_path / "b"), None)


def test_post_switch_health_failure_restores_previous(env, monkeypatch):
    from moonlight_posture_update import updater as up
    env.fake.add(Release(203))
    assert env.run().result == "updated"
    env.fake.add(Release(204))
    real = up.smoke.run_smoke
    n = {"c": 0}

    def flaky(*a, **k):
        n["c"] += 1
        if n["c"] == 2:                                   # the check through `current`
            from moonlight_posture_update.errors import InstallError
            raise InstallError("boom")
        return real(*a, **k)
    monkeypatch.setattr(up.smoke, "run_smoke", flaky)
    res = env.run()
    assert res.exit_code == 5 and "previous version restored" in res.detail
    assert env.current() == "v6.2.0-daily.203-vp.1"
    assert tags_on_disk(env) == ["v6.2.0-daily.203-vp.1"]
    assert env.state()["installed"]["tag"] == "v6.2.0-daily.203-vp.1"


# ---- resources ---------------------------------------------------------------------------------------------------------

def test_disk_full_while_staging_keeps_old_version(env, monkeypatch):
    env.fake.add(Release(203))
    assert env.run().result == "updated"
    env.fake.add(Release(204))
    real = fsio.write_chunk

    def full(fh, data):
        if ".stage-" in path_of(fh):
            raise OSError(errno.ENOSPC, "No space left on device")
        return real(fh, data)
    monkeypatch.setattr(fsio, "write_chunk", full)
    res = env.run()
    assert res.exit_code == 5 and "filesystem error" in res.detail
    assert env.current() == "v6.2.0-daily.203-vp.1" and tags_on_disk(env) == ["v6.2.0-daily.203-vp.1"]
    assert [n for n in os.listdir(env.paths.opt_dir) if n.startswith(".stage")] == []
    # disk-full is transient: counted, never denied
    assert env.state()["attempts"]["v6.2.0-daily.204-vp.1"].get("transient") == 1
    assert "v6.2.0-daily.204-vp.1" not in env.state()["deny"]


def test_disk_full_while_downloading(env, monkeypatch):
    env.fake.add(Release(203))
    real = fsio.write_chunk
    n = {"c": 0}

    def full(fh, data):
        if "Moonlight-6.2.0" in path_of(fh):
            n["c"] += 1
            if n["c"] == 2:
                raise OSError(errno.ENOSPC, "No space left on device")
        return real(fh, data)
    monkeypatch.setattr(fsio, "write_chunk", full)
    res = env.run()
    assert res.exit_code == 5 and env.current() is None
    run_dirs = os.listdir(env.paths.runs_dir)
    for d in run_dirs:        # partial download removed
        assert not [f for f in os.listdir(os.path.join(env.paths.runs_dir, d)) if f.endswith(".AppImage")]


def test_state_write_failure_is_logged_not_fatal(env, monkeypatch):
    env.fake.add(Release(203, hours_old=1))
    monkeypatch.setattr(st, "save_state", lambda *a, **k: (_ for _ in ()).throw(OSError(errno.ENOSPC, "full")))
    assert env.run().result == "noop"


def test_interrupted_download_leaves_nothing_and_is_transient(env):
    r = env.fake.add(Release(203))
    env.fake.truncate = {r.appimage_name: 100_000}
    res = env.run()
    assert res.result == "deferred" and res.exit_code == 8 and "truncated" in res.detail
    assert env.current() is None
    for d in os.listdir(env.paths.runs_dir):
        assert not [f for f in os.listdir(os.path.join(env.paths.runs_dir, d)) if f.endswith(".AppImage")]
    a = env.state()["attempts"][r.tag]
    assert a["transient"] == 1 and r.tag not in env.state()["deny"]
    # server healthy again after the backoff: the next attempt installs
    env.fake.truncate = {}
    s = env.state(); s["attempts"][r.tag]["not_before"] = 0; json.dump(s, open(env.paths.state_file, "w"))
    assert env.run().result == "updated"


def test_oversize_asset_by_api_size(env):
    env.fake.add(Release(203))
    env.set_policy(max_appimage_mb=1)                  # fixture is 1.0x MiB
    res = env.run()
    assert res.result == "verify_failed" and "cap" in res.detail


def test_oversize_manifest_declared_size_above_cap(env):
    r = env.fake.add(Release(203))
    r.manifest_linux_overrides = {"size": 400 * 1024 * 1024}
    r.build()
    assert env.run().result == "verify_failed"


def test_oversize_body_without_content_length(env):
    """API/manifest sizes are lies; a chunked body larger than the cap is cut off at the cap."""
    r = env.fake.add(Release(203))
    big = make_appimage(r.build_version, pad_to=3 * 1024 * 1024)
    r.app = big; r.build()
    env.set_policy(max_appimage_mb=2)
    entry_sizes = r.api_entry()
    for a in entry_sizes["assets"]:
        if a["name"] == r.appimage_name:
            a["size"] = 1_500_000                          # API understates the size
    env.fake.raw_api = [entry_sizes]
    env.fake.chunked = {r.appimage_name}
    r.manifest_linux_overrides = {"size": 1_500_000}
    r.build()
    res = env.run()
    assert res.result == "verify_failed"
    assert env.current() is None


def test_oversize_small_asset_content_length(env):
    r = env.fake.add(Release(203))
    env.fake.served[r.tag + "/SHA256SUMS"] = b"x" * 200_000
    r.api_digest = False
    assert env.run().result == "verify_failed"


def test_api_size_differs_from_manifest(env):
    r = env.fake.add(Release(203))
    r.api_size_delta = 7
    assert env.run().result == "verify_failed"


def test_format_gate_refuses_non_appimage(env):
    r = env.fake.add(Release(203))
    r.app = b"#!/bin/sh\necho pwned\n" + b"\0" * (1024 * 1024 + 10)
    r.build()
    res = env.run()
    assert res.result == "verify_failed" and ("ELF" in res.detail or "AppImage" in res.detail)
    assert env.current() is None


# ---- atomic switch -----------------------------------------------------------------------------------------------------

def test_symlink_switch_is_atomic(tmp_path):
    link = str(tmp_path / "current")
    os.mkdir(tmp_path / "a"); os.mkdir(tmp_path / "b")
    fsio.switch_symlink(link, "a")
    stop = threading.Event()
    bad = []

    def reader():
        while not stop.is_set():
            try:
                t = os.readlink(link)
                if t not in ("a", "b") or not os.path.isdir(link):
                    bad.append(t)
            except OSError as e:
                bad.append(repr(e))
    ths = [threading.Thread(target=reader) for _ in range(4)]
    [t.start() for t in ths]
    for i in range(1500):
        fsio.switch_symlink(link, "b" if i % 2 == 0 else "a")
    stop.set(); [t.join() for t in ths]
    assert bad == []
    assert [n for n in os.listdir(tmp_path) if n.startswith(".link-")] == []


def test_switch_failure_leaves_old_link(tmp_path, monkeypatch):
    link = str(tmp_path / "current")
    os.mkdir(tmp_path / "a")
    fsio.switch_symlink(link, "a")
    monkeypatch.setattr(os, "replace", lambda *a: (_ for _ in ()).throw(OSError(errno.EIO, "io")))
    with pytest.raises(OSError):
        fsio.switch_symlink(link, "b")
    monkeypatch.undo()
    assert os.readlink(link) == "a" and [n for n in os.listdir(tmp_path) if n.startswith(".link-")] == []


# ---- upgrade chain, previous kept, pruning -----------------------------------------------------------------------------

def test_previous_kept_older_pruned(env):
    for u in (201, 202, 203):
        env.fake.add(Release(u))
        env.fake.releases = [r for r in env.fake.releases if r.key.u == u]
        assert env.run().result == "updated"
    assert tags_on_disk(env) == ["v6.2.0-daily.202-vp.1", "v6.2.0-daily.203-vp.1"]
    s = env.state()
    assert s["installed"]["tag"].endswith("203-vp.1") and s["previous"]["tag"].endswith("202-vp.1")


def test_prune_never_touches_foreign_dirs(env):
    os.makedirs(os.path.join(env.paths.opt_dir, "notes"))
    os.makedirs(os.path.join(env.paths.opt_dir, "v6.2.0-daily.1-vp.1.bak"))
    env.fake.add(Release(203))
    assert env.run().result == "updated"
    assert os.path.isdir(os.path.join(env.paths.opt_dir, "notes"))
    assert os.path.isdir(os.path.join(env.paths.opt_dir, "v6.2.0-daily.1-vp.1.bak"))


# ---- rollback ----------------------------------------------------------------------------------------------------------

def two_versions(env):
    env.fake.add(Release(203)); assert env.run().result == "updated"
    env.fake.releases = []; env.fake.add(Release(204)); assert env.run().result == "updated"
    assert env.current() == "v6.2.0-daily.204-vp.1"


def test_rollback_switches_back_and_denies(env):
    two_versions(env)
    res = env.updater().rollback()
    assert res.result == "rolled_back" and res.exit_code == 0
    assert env.current() == "v6.2.0-daily.203-vp.1"
    s = env.state()
    assert s["installed"]["tag"].endswith("203-vp.1") and "v6.2.0-daily.204-vp.1" in s["deny"]
    # the denied release is not installed again
    res = env.run()
    assert res.result == "noop" and env.current() == "v6.2.0-daily.203-vp.1"
    # a newer one is
    env.fake.add(Release(205))
    assert env.run().result == "updated"


def test_rollback_refused_while_client_runs(env):
    two_versions(env)
    env.fake_client()
    res = env.updater().rollback()
    assert res.exit_code == 6 and env.current() == "v6.2.0-daily.204-vp.1"


def test_rollback_refuses_tampered_previous(env):
    two_versions(env)
    p = os.path.join(env.paths.opt_dir, "v6.2.0-daily.203-vp.1", "Moonlight.AppImage")
    os.chmod(p, 0o755)
    with open(p, "r+b") as f:
        f.seek(3000); f.write(b"EVIL")
    res = env.updater().rollback()
    assert res.exit_code == 6 and "recorded hash" in res.detail
    assert env.current() == "v6.2.0-daily.204-vp.1"


def test_rollback_without_previous(env):
    env.fake.add(Release(203)); env.run()
    assert env.updater().rollback().exit_code == 6
    assert env.current() == "v6.2.0-daily.203-vp.1"


def test_rollback_with_nothing_installed(env):
    assert env.updater().rollback().exit_code == 6


# ---- state robustness ---------------------------------------------------------------------------------------------------

def test_corrupt_state_is_moved_aside_and_symlink_prevents_downgrade(env):
    env.fake.add(Release(203)); env.run()
    open(env.paths.state_file, "w").write("{ this is not json")
    env.fake.releases.clear(); env.fake.add(Release(202))
    res = env.run()
    assert res.result == "noop" and env.current() == "v6.2.0-daily.203-vp.1"
    assert [n for n in os.listdir(env.paths.state_dir) if n.startswith("state.json.corrupt-")]
    assert env.state()["schema"] == 1


@pytest.mark.parametrize("bad", [
    {"schema": 2},
    {"schema": 1, "installed": {"tag": "x", "build": 1, "sha256": "0"}, "previous": None, "deny": [], "attempts": {}},
    {"schema": 1, "installed": None, "previous": None, "deny": ["../x"], "attempts": {}},
    {"schema": 1, "installed": None, "previous": None, "deny": [], "attempts": {"v6.2.0-daily.203-vp.1": {"install": "many"}}},
    [], "str", None,
])
def test_invalid_state_shapes_rejected(env, bad):
    json.dump(bad, open(os.path.join(env.paths.state_dir, "state.json"), "w")) if os.path.isdir(env.paths.state_dir) else None
    os.makedirs(env.paths.state_dir, exist_ok=True)
    json.dump(bad, open(env.paths.state_file, "w"))
    env.fake.add(Release(203, hours_old=1))
    assert env.run().result == "noop"            # rebuilt, not crashed
    assert st.validate_state(env.state())


def test_state_dir_and_files_are_private(env):
    env.fake.add(Release(203)); env.run()
    assert stat.S_IMODE(os.stat(env.paths.state_dir).st_mode) == 0o700
    assert stat.S_IMODE(os.stat(env.paths.state_file).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(env.paths.log_file).st_mode) == 0o600
    for d in os.listdir(env.paths.runs_dir):
        assert stat.S_IMODE(os.stat(os.path.join(env.paths.runs_dir, d)).st_mode) == 0o700


def test_second_instance_exits_7(env):
    os.makedirs(env.paths.state_dir, mode=0o700, exist_ok=True)
    fd = os.open(env.paths.lock_file, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        res = env.run()
        assert res.exit_code == 7 and res.result == "deferred"
    finally:
        os.close(fd)


def test_old_run_dirs_pruned_and_no_appimage_kept(env):
    env.fake.add(Release(203, hours_old=1))
    for _ in range(6):
        env.run()
    env.fake.releases.clear(); env.fake.add(Release(204))
    env.run()
    assert len(os.listdir(env.paths.runs_dir)) <= 3


# ---- policy --------------------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("data", [
    {"unknown_key": 1},
    {"repo": "evil/moonlight-qt"},
    {"upstream_owners": ["Mallory"]},
    {"upstream_owners": []},
    {"upstream_owners": ["Nonary", "Mallory"]},
    {"channel": "nightly"},
    {"hold": "yes"},
    {"hold": 1},
    {"cooling_off_hours": -1},
    {"cooling_off_hours": "2"},
    {"cooling_off_hours": float("nan")},
    {"min_build": 70000},
    {"deny": ["not-a-tag"]},
    {"smoke_test": "skip"},
    {"max_appimage_mb": 0},
    {"schema": 2},
    [],
])
def test_policy_rejects(data):
    with pytest.raises(ConfigError):
        pol.parse_policy(data)


def test_policy_file_problems_fail_closed(env):
    env.fake.add(Release(203))
    os.makedirs(env.paths.config_dir, exist_ok=True)
    p = env.paths.policy_file
    open(p, "w").write("{nope"); os.chmod(p, 0o600)
    assert env.run().exit_code == 3
    open(p, "w").write('{"hold": false, "hold": true}'); os.chmod(p, 0o600)
    assert env.run().exit_code == 3
    open(p, "w").write('{"hold": false}'); os.chmod(p, 0o666)
    assert env.run().exit_code == 3                      # group/world-writable
    os.chmod(p, 0o600); os.unlink(p); os.symlink("/etc/hostname", p)
    assert env.run().exit_code == 3                      # symlink
    assert env.fake.requests == [] and env.current() is None


def test_policy_defaults_when_missing():
    p = pol.load_policy("/nonexistent/policy.json")
    assert p.repo == "emilwojcik93/moonlight-qt" and p.effective_cooling_hours() == 2 and not p.hold
    assert p.signer_workflow == "emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml"


# ---- status ----------------------------------------------------------------------------------------------------------------

def test_status_json(env):
    env.fake.add(Release(203)); env.run()
    s = env.updater().status()
    json.dumps(s)
    assert s["current"]["tag"] == "v6.2.0-daily.203-vp.1" and s["installed"]["build"] == 61624
    assert s["held"] is False and s["client_running"] is False and s["policy"]["channel"] == "canary"
    n = len(env.fake.requests)
    env.updater().status()
    assert len(env.fake.requests) == n                # no network


def test_log_scrubs_secrets():
    from moonlight_posture_update.logutil import scrub
    s = scrub("token ghp_" + "A" * 36 + " Bearer abcdefghijkl -----BEGIN PRIVATE KEY----- \x1b[31m\nline")
    assert "ghp_" not in s and "abcdefghijkl" not in s and "BEGIN" not in s and "\x1b" not in s and "\n" not in s
