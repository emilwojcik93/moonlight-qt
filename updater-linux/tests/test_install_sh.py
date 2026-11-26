"""install.sh / uninstall.sh in a temp prefix, unit files, entry point, CLI. Nothing here touches the real home."""
import json
import os
import shutil
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, timeout=120, **kw)


@pytest.fixture
def prefix(tmp_path):
    p = tmp_path / "pfx"
    cfg = p / ".config" / "Moonlight Game Streaming Project"
    cfg.mkdir(parents=True)
    (cfg / "Moonlight.conf").write_text("[General]\nuniqueid=SENTINEL\n")
    return p


def snapshot(d):
    out = {}
    for root, _dirs, files in os.walk(d):
        for f in files:
            fp = os.path.join(root, f)
            out[fp] = (os.stat(fp).st_mtime_ns, open(fp, "rb").read())
    return out


def test_install_into_prefix_leaves_moonlight_config_alone(prefix, tmp_path):
    cfg = prefix / ".config" / "Moonlight Game Streaming Project"
    before = snapshot(cfg)
    fakebin = tmp_path / "fakebin"; fakebin.mkdir()
    marker = tmp_path / "systemctl-called"
    (fakebin / "systemctl").write_text('#!/bin/sh\necho "$@" >> %s\n' % marker)
    (fakebin / "systemctl").chmod(0o755)
    env = dict(os.environ, PATH="%s:%s" % (fakebin, os.environ["PATH"]))
    r = sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix)], env=env)
    assert r.returncode == 0, r.stderr
    assert not marker.exists(), "install.sh must not start or enable anything without --enable"
    assert snapshot(cfg) == before
    assert (prefix / ".local/bin/moonlight-posture-update").stat().st_mode & 0o111
    # ~/.local/bin holds only symlinks; the code and the entry script live in the (read-only for the job) lib dir
    assert (prefix / ".local/bin/moonlight-posture-update").is_symlink() and (prefix / ".local/bin/moonlight-posture").is_symlink()
    assert (prefix / ".local/lib/moonlight-posture-updater/bin/moonlight-posture-update").is_file()
    # first install starts in report-only
    pol = json.loads((prefix / ".config/moonlight-posture-updater/policy.json").read_text())
    assert pol == {"schema": 1, "mode": "report-only"}
    unit = (prefix / ".config/systemd/user/moonlight-posture-update.service").read_text()
    assert "%h" not in unit and str(prefix) in unit              # absolute paths for a non-home prefix
    # nothing outside the documented locations
    for root, _d, files in os.walk(prefix):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), prefix)
            assert rel.startswith((".local/", ".config/systemd/user/", ".config/moonlight-posture-updater/",
                                   ".config/Moonlight Game Streaming Project/")), rel
    # idempotent
    assert sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix)], env=env).returncode == 0
    assert snapshot(cfg) == before


def test_install_keeps_an_existing_policy(prefix):
    d = prefix / ".config/moonlight-posture-updater"; d.mkdir(parents=True)
    (d / "policy.json").write_text('{"schema": 1, "mode": "install", "hold": true}')
    assert sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix)]).returncode == 0
    assert json.loads((d / "policy.json").read_text())["mode"] == "install"


@pytest.mark.parametrize("bad", ["/tmp/a b", "/tmp/a&b", "/tmp/a$(id)", "/tmp/a;b", "/tmp/a|b", "/tmp/a\\b", "/tmp/a\nb",
                                 "/tmp/a'b", "/tmp/\u00e4", "/tmp/a`id`", "/tmp/a*"])
def test_prefix_with_unusual_characters_rejected(bad, tmp_path):
    for script in ("install.sh", "uninstall.sh"):
        r = sh([os.path.join(ROOT, script), "--prefix", bad])
        assert r.returncode == 2 and "may only contain" in r.stderr, (script, bad, r.stderr)


def test_enable_refused_for_foreign_prefix(prefix):
    r = sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix), "--enable"])
    assert r.returncode == 2 and "only allowed" in r.stderr


def test_bad_arguments():
    assert sh([os.path.join(ROOT, "install.sh"), "--prefix", "relative/path"]).returncode == 2
    assert sh([os.path.join(ROOT, "install.sh"), "--nope"]).returncode == 2


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze missing")
def test_units_verify(prefix):
    assert sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix)]).returncode == 0
    d = prefix / ".config/systemd/user"
    r = sh(["systemd-analyze", "--user", "verify", str(d / "moonlight-posture-update.service"),
            str(d / "moonlight-posture-update.timer")], env=dict(os.environ, HOME=str(prefix)))
    assert r.returncode == 0, r.stdout + r.stderr


def test_unit_contents():
    svc = open(os.path.join(ROOT, "systemd/moonlight-posture-update.service")).read()
    tmr = open(os.path.join(ROOT, "systemd/moonlight-posture-update.timer")).read()
    assert "Type=oneshot" in svc and "NoNewPrivileges=yes" in svc and "ProtectSystem=strict" in svc
    assert "ExecStart=%h/.local/lib/moonlight-posture-updater/bin/moonlight-posture-update update" in svc
    rw = [l for l in svc.splitlines() if l.startswith("ReadWritePaths=")][0]
    assert ".local/bin" not in rw and ".local/lib" not in rw           # entry script + code are read-only for the job
    assert "Moonlight Game Streaming Project" not in svc          # the client's config is not even writable
    assert "OnCalendar=*-*-* 04:17:00" in tmr and "Persistent=true" in tmr
    assert "RandomizedDelaySec=" in tmr and "OnStartupSec=10min" in tmr and "WantedBy=timers.target" in tmr


def test_installed_entry_point_runs_isolated(prefix):
    assert sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix)]).returncode == 0
    exe = str(prefix / ".local/bin/moonlight-posture-update")
    env = {"PATH": os.environ["PATH"], "HOME": str(prefix), "PYTHONPATH": "/nonexistent-evil"}
    r = sh([exe, "--version"], env=env)
    assert r.returncode == 0 and "moonlight-posture-update" in r.stdout
    r = sh([exe, "status"], env=env)
    assert r.returncode == 0
    s = json.loads(r.stdout)
    assert s["current"]["tag"] is None and s["held"] is False


def test_uninstall_keeps_client_and_moonlight_config(prefix):
    assert sh([os.path.join(ROOT, "install.sh"), "--prefix", str(prefix)]).returncode == 0
    (prefix / ".local/opt/moonlight-posture/v6.2.0-daily.203-vp.1").mkdir(parents=True)
    r = sh([os.path.join(ROOT, "uninstall.sh"), "--prefix", str(prefix)])
    assert r.returncode == 0
    assert not (prefix / ".local/bin/moonlight-posture-update").exists()
    assert (prefix / ".local/opt/moonlight-posture/v6.2.0-daily.203-vp.1").is_dir()
    r = sh([os.path.join(ROOT, "uninstall.sh"), "--prefix", str(prefix), "--purge"])
    assert not (prefix / ".local/bin/moonlight-posture").is_symlink()
    assert not (prefix / ".local/opt/moonlight-posture").exists()
    assert (prefix / ".config/Moonlight Game Streaming Project/Moonlight.conf").read_text().endswith("SENTINEL\n")


def run_cli(home, *args):
    env = {"PATH": os.environ["PATH"], "HOME": str(home)}
    return subprocess.run([sys.executable, "-I", "-c",
                           "import sys; sys.path.insert(0, %r); from moonlight_posture_update.cli import main; sys.exit(main())" % ROOT,
                           *args], capture_output=True, text=True, env=env, timeout=60)


def test_cli_hold_unhold_status(tmp_path):
    h = tmp_path / "h"; h.mkdir()
    assert run_cli(h, "hold").returncode == 0
    assert json.loads(run_cli(h, "status").stdout)["held"] is True
    r = run_cli(h, "update")
    assert r.returncode == 0 and "MLPU_RESULT=held" in r.stdout
    assert run_cli(h, "unhold").returncode == 0
    assert json.loads(run_cli(h, "status").stdout)["held"] is False
    p = h / ".config/moonlight-posture-updater/policy.json"
    assert oct(p.stat().st_mode & 0o777) == "0o600"


def test_cli_invalid_policy_exit_3_and_rollback_without_install(tmp_path):
    h = tmp_path / "h"; (h / ".config/moonlight-posture-updater").mkdir(parents=True)
    p = h / ".config/moonlight-posture-updater/policy.json"
    p.write_text('{"repo": "evil/repo"}'); p.chmod(0o600)
    r = run_cli(h, "update")
    assert r.returncode == 3 and "MLPU_RESULT=failed" in r.stdout
    assert run_cli(h, "hold").returncode == 3                     # refuses to edit an invalid policy
    p.unlink()
    assert run_cli(h, "rollback").returncode == 6


def test_cli_unusable_home(tmp_path):
    env = {"PATH": os.environ["PATH"], "HOME": "/nonexistent-home-dir"}
    r = subprocess.run([sys.executable, "-I", "-c", "import sys; sys.path.insert(0, %r); from moonlight_posture_update.cli import main; sys.exit(main())" % ROOT, "update"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 3


def test_launcher_and_desktop_text(tmp_path):
    from moonlight_posture_update.paths import Paths
    from moonlight_posture_update.store import Store
    s = Store(Paths(str(tmp_path / "a b $x")))
    sh_text = s.launcher_text()
    assert subprocess.run(["sh", "-n"], input=sh_text, text=True, capture_output=True).returncode == 0
    assert "'" in sh_text and "--appimage-extract-and-run" in sh_text
    d = s.desktop_text()
    assert d.startswith("[Desktop Entry]\n") and 'Exec="' in d and "Type=Application" in d
    if shutil.which("desktop-file-validate"):
        f = tmp_path / "x.desktop"; f.write_text(d)
        assert subprocess.run(["desktop-file-validate", str(f)], capture_output=True).returncode == 0
