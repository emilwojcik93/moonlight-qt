"""prepare_build_branch.py end-to-end against a local fake upstream and a local bare 'fork' remote."""
import argparse
import json
import os
import shutil
import subprocess
import sys

import pytest

import prepare_build_branch as pbb
from test_series_apply_assemble import BUILD_WF, GIT_ENV

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UP_TAG = "v6.2.0-daily.202"


def _g(cwd, *a):
    env = dict(os.environ)
    env.update(GIT_ENV)
    return subprocess.run(["git", "-C", str(cwd), "-c", "core.autocrlf=false", *a], capture_output=True, text=True,
                          check=True, env=env).stdout.strip()


@pytest.fixture()
def lab(tmp_path):
    """fake upstream (tag v6.2.0-daily.202), a bare 'fork' remote, an automation checkout with a real series."""
    up = tmp_path / "up"
    up.mkdir()
    _g(up, "init", "-q", "-b", "master")
    os.makedirs(up / ".github" / "workflows")
    (up / ".github" / "workflows" / "build-win-mac.yml").write_text(BUILD_WF)
    (up / ".github" / "workflows" / "daily.yml").write_text("on: push\njobs: {}\n")
    (up / "app").mkdir()
    (up / "app" / "a.txt").write_text("".join(f"line{i}\n" for i in range(1, 21)))
    _g(up, "add", "-A")
    _g(up, "commit", "-qm", "base")
    base = _g(up, "rev-parse", "HEAD")
    _g(up, "tag", UP_TAG)
    _g(up, "checkout", "-qb", "feat")
    (up / "app" / "a.txt").write_text("".join(f"line{i}\n" if i != 5 else "PATCHED\n" for i in range(1, 21)))
    _g(up, "commit", "-qam", "posture: patch line 5")
    pdir = tmp_path / "patches"
    pdir.mkdir()
    _g(up, "format-patch", "-o", str(pdir), f"{base}..feat")
    _g(up, "checkout", "-q", "master")
    name = os.listdir(pdir)[0]
    (pdir / "series").write_text("# group: posture-core\n" + name + "\n")

    bare = tmp_path / "fork.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "automation", str(bare)], check=True)
    auto = tmp_path / "auto"
    auto.mkdir()
    _g(auto, "init", "-q", "-b", "automation")
    shutil.copytree(os.path.join(ROOT, "ci"), auto / "ci", ignore=shutil.ignore_patterns("tests", "__pycache__"))
    shutil.copytree(pdir, auto / "patches")
    (auto / "policy.yml").write_text(
        "schema: 1\nallow_upstream_owners: [Nonary]\ncooling_off_hours: {stable: 24, canary: 0}\n"
        "hold: false\ndeny: []\nkeep_releases: 10\nx-supported_floor_tag: v6.2.0-daily.201\n")
    (auto / "upstream-seen.json").write_text("")
    _g(auto, "add", "-A")
    _g(auto, "commit", "-qm", "automation")
    # the ONLY remote is the local bare repository: nothing in this test can reach the network
    _g(auto, "remote", "add", "origin", str(bare))

    def get_json(url):
        if "/Nonary/moonlight-qt/releases?" in url:
            return [{"id": 454272425, "tag_name": UP_TAG, "draft": False, "prerelease": True,
                     "published_at": "2026-11-22T07:17:53Z"}]
        if url.endswith(f"/git/ref/tags/{UP_TAG}"):
            return {"ref": f"refs/tags/{UP_TAG}", "object": {"type": "commit", "sha": base}}
        if "/emilwojcik93/moonlight-qt/releases?" in url:
            return []
        if "/actions/workflows/" in url:
            return {"workflow_runs": []}
        raise AssertionError("unexpected url " + url)

    return {"up": up, "auto": auto, "bare": bare, "base": base, "get_json": get_json, "tmp": tmp_path}


def _args(lab, **kw):
    ns = argparse.Namespace(root=str(lab["auto"]), tag=None, remote="origin", fork_repo="emilwojcik93/moonlight-qt", dry_run=True,
                            override_hold=False, force_rebuild=False, allow_any_branch=False,
                            workdir=str(lab["tmp"] / "work"), upstream_url=str(lab["up"]))
    for k, val in kw.items():
        setattr(ns, k, val)
    return ns


def test_dry_run_prints_branch_tip_tree_and_changes_nothing(lab, capsys):
    before = _g(lab["auto"], "rev-parse", "HEAD")
    assert pbb.prepare(_args(lab), get_json=lab["get_json"]) == 0
    out = capsys.readouterr().out
    assert f"BRANCH build/{UP_TAG}-n1" in out and "TIP " in out and "TREE " in out
    assert "B=61616" in out and "ci_version=6.2.0-daily.61616" in out and "release tag v6.2.0-daily.202-vp.1" in out
    assert "dry run: nothing recorded, nothing pushed" in out and "refs/heads/automation" in out
    assert _g(lab["auto"], "rev-parse", "HEAD") == before and _g(lab["auto"], "status", "--porcelain") == ""
    assert subprocess.run(["git", "-C", str(lab["bare"]), "branch", "-a"], capture_output=True,
                          text=True).stdout.strip() == ""
    src = str(lab["tmp"] / "work" / "src")
    assert _g(src, "ls-files", ".github").splitlines() == [".github/workflows/build-win-mac.yml",
                                                           ".github/workflows/patched-windows-release.yml"]
    assert "workflow_dispatch" not in open(os.path.join(src, ".github", "workflows", "build-win-mac.yml")).read()
    meta = json.load(open(os.path.join(src, ".vp-ci", "build-meta.json")))
    assert meta["build"]["version"] == "6.2.0-daily.61616" and meta["patches"]["groups"] == ["posture-core"]


def test_real_run_records_lock_then_pushes_both_refs(lab, capsys):
    assert pbb.prepare(_args(lab, dry_run=False), get_json=lab["get_json"], now="2026-11-22T08:00:00Z") == 0
    bare = str(lab["bare"])
    tip = [ln.split()[1] for ln in capsys.readouterr().out.splitlines() if ln.startswith("TIP ")][0]
    assert _g(bare, "rev-parse", f"refs/heads/build/{UP_TAG}-n1") == tip
    ent = json.loads(_g(bare, "show", "automation:upstream-seen.json"))["entries"][UP_TAG]
    assert ent["commit"] == lab["base"] and ent["builds"][0]["n"] == 1 and ent["builds"][0]["source_sha"] == tip


def test_second_run_never_pushes_a_second_branch(lab):
    assert pbb.prepare(_args(lab, dry_run=False), get_json=lab["get_json"]) == 0
    # the build is recorded but has no run/release yet: plan answers stuck (non-zero), nothing is pushed again
    assert pbb.prepare(_args(lab, dry_run=False, workdir=str(lab["tmp"] / "work2")), get_json=lab["get_json"]) != 0
    branches = subprocess.run(["git", "-C", str(lab["bare"]), "branch", "--list", "build/*"], capture_output=True,
                              text=True).stdout
    assert branches.count("build/") == 1


def test_explicit_tag_must_be_valid_and_mappable(lab):
    assert pbb.main(["--root", str(lab["auto"]), "--tag", "$(id)", "--dry-run"]) == 1
    assert pbb.main(["--root", str(lab["auto"]), "--tag", "v6.2.0-daily.692", "--dry-run"]) == 1


def test_script_has_no_token_handling():
    text = open(os.path.join(ROOT, "ci", "prepare_build_branch.py"), encoding="utf-8").read()
    assert 'UP_REPO = "Nonary/moonlight-qt"' in text and "GH_TOKEN" not in text and "GITHUB_TOKEN" not in text


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
def test_shell_wrapper_skips_a_broken_python3_alias(tmp_path):
    """A python3 that exists but fails (Microsoft Store alias) is skipped; python is used next."""
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "python3").write_text("#!/bin/sh\nexit 9\n")
    (fake / "python3").chmod(0o755)
    real = tmp_path / "real"
    real.mkdir()
    exe = sys.executable.replace(os.sep, "/")
    (real / "python").write_text(f'#!/bin/sh\nexec "{exe}" "$@"\n')
    (real / "python").chmod(0o755)
    script = os.path.join(ROOT, "tools", "prepare-build-branch.sh").replace(os.sep, "/")
    env = dict(os.environ)
    env["PATH"] = f"{fake.as_posix()}:{real.as_posix()}:" + env["PATH"]
    proc = subprocess.run(["bash", script, "--tag", "bad tag", "--dry-run"], capture_output=True, text=True, env=env)
    # reached the python script (it rejects the tag with rc 1): not 127 (no interpreter) and not 9 (broken alias)
    assert proc.returncode == 1 and "::error::" in proc.stderr


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
def test_shell_wrapper_reports_when_no_python_works(tmp_path):
    fake = tmp_path / "bin"
    fake.mkdir()
    for name in ("python3", "python", "py"):
        (fake / name).write_text("#!/bin/sh\nexit 9\n")
        (fake / name).chmod(0o755)
    script = os.path.join(ROOT, "tools", "prepare-build-branch.sh").replace(os.sep, "/")
    bash = shutil.which("bash")
    env = {"PATH": fake.as_posix() + ":/usr/bin:/bin", "HOME": str(tmp_path)}
    proc = subprocess.run([bash, script], capture_output=True, text=True, env=env)
    assert proc.returncode == 127 and "no working Python" in proc.stderr
