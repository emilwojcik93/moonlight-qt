import argparse
import json
import os
import subprocess

import pytest

import apply_series as aps
import assemble_build as asb
import series as sr
import vpcommon as v
import workflow_check as wc

HERE = os.path.dirname(os.path.abspath(__file__))
CI_DIR = os.path.dirname(HERE)
ROOT = os.path.dirname(CI_DIR)
S1 = "1" * 64
TAG = "v6.2.0-daily.202"
TS = "2026-11-22T07:17:53Z"

GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
           "GIT_AUTHOR_DATE": "2026-11-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-11-01T00:00:00Z"}

BUILD_WF = """---
name: Build - Windows and macOS
permissions:
  contents: read

on:
  workflow_call:
    inputs:
      ci_version:
        required: true
        type: string
  workflow_dispatch:
    inputs:
      ci_version:
        description: Version string
        required: true
        type: string

jobs:
  build:
    runs-on: windows-2025
    steps:
      - run: echo hi
"""


def git(repo, *args, check=True):
    env = dict(os.environ)
    env.update(GIT_ENV)
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=env, check=check)


def write(repo, rel, text):
    p = os.path.join(str(repo), rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


@pytest.fixture()
def world(tmp_path):
    """upstream repo with a base commit; two format-patch files; a conflicting variant."""
    repo = tmp_path / "up"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "commit.gpgsign", "false")
    write(repo, "app/a.txt", "".join(f"line{i}\n" for i in range(1, 21)))
    write(repo, "README.md", "hello\n")
    write(repo, ".github/workflows/build-win-mac.yml", BUILD_WF)
    write(repo, ".github/workflows/build.yml", "name: CI\non: push\njobs: {}\n")
    write(repo, ".github/workflows/daily-prerelease.yml", "name: daily\non:\n  schedule:\n    - cron: '47 6 * * *'\njobs: {}\n")
    write(repo, ".github/dependabot.yml", "version: 2\n")
    write(repo, ".github/ISSUE_TEMPLATE/bug.md", "x\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")
    base = git(repo, "rev-parse", "HEAD").stdout.strip()

    git(repo, "checkout", "-qb", "feature")
    write(repo, "app/a.txt", "".join(f"line{i}\n" if i != 5 else "LINE5 changed\n" for i in range(1, 21)))
    git(repo, "commit", "-qam", "posture: change line 5")
    write(repo, "app/new.txt", "new file\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "touch-menu: add new file")
    patches = tmp_path / "patches"
    patches.mkdir()
    git(repo, "format-patch", "-o", str(patches), f"{base}..feature")
    names = sorted(os.listdir(patches))
    (patches / "series").write_text("# group: posture-core\n" + names[0] + "\n# group: touch-menu\n" + names[1] + "\n")
    ref_tree = git(repo, "rev-parse", "feature^{tree}").stdout.strip()
    git(repo, "checkout", "-q", "main")
    return {"repo": repo, "base": base, "patches": patches, "names": names, "ref_tree": ref_tree,
            "tmp": tmp_path}


def clone_at_base(world, name):
    dest = world["tmp"] / name
    subprocess.run(["git", "-c", "core.autocrlf=false", "clone", "-q", str(world["repo"]), str(dest)], check=True,
                   capture_output=True)
    git(dest, "checkout", "-q", "--detach", world["base"])
    return dest


# --- series ---------------------------------------------------------------------------

def test_series_parse_and_fingerprint(world):
    series = world["patches"] / "series"
    entries = sr.parse(str(series))
    assert [e[0] for e in entries] == world["names"] and [e[1] for e in entries] == ["posture-core", "touch-menu"]
    fp = sr.fingerprint(str(series), str(world["patches"]))
    assert fp["count"] == 2 and fp["groups"] == ["posture-core", "touch-menu"] and len(fp["series_sha256"]) == 64
    # fingerprint changes when a patch BODY changes, even if series is identical
    first = world["patches"] / world["names"][0]
    first.write_text(first.read_text() + "\n")
    assert sr.fingerprint(str(series), str(world["patches"]))["series_sha256"] != fp["series_sha256"]


@pytest.mark.parametrize("line", ["../evil.patch", "/abs.patch", "a b.patch", "x.patch;id", "a/../b.patch",
                                  "$(id).patch", "x.txt", "a\\b.patch", "-rf.patch"])
def test_series_rejects_bad_entries(tmp_path, line):
    p = tmp_path / "series"
    p.write_text(line + "\n")
    with pytest.raises(v.ValidationError):
        sr.parse(str(p))


def test_series_missing_patch(tmp_path):
    d = tmp_path / "p"
    d.mkdir()
    (d / "series").write_text("0001-missing.patch\n")
    with pytest.raises(v.ValidationError):
        sr.fingerprint(str(d / "series"), str(d))


# --- apply ----------------------------------------------------------------------------

def test_apply_reproduces_reference_tree_and_is_deterministic(world):
    a = clone_at_base(world, "a")
    b = clone_at_base(world, "b")
    for repo in (a, b):
        rc = aps.apply(str(repo), world["base"], str(world["patches"] / "series"), str(world["patches"]),
                       expect_tree=world["ref_tree"])
        assert rc == 0
    assert git(a, "rev-parse", "HEAD").stdout == git(b, "rev-parse", "HEAD").stdout  # reproducible tip
    assert git(a, "log", "-1", "--format=%cn %ce").stdout.strip() == f"{aps.BOT_NAME} {aps.BOT_EMAIL}"


def test_apply_wrong_expected_tree_fails(world):
    a = clone_at_base(world, "a")
    rc = aps.apply(str(a), world["base"], str(world["patches"] / "series"), str(world["patches"]),
                   expect_tree="f" * 40)
    assert rc == 1


def test_apply_requires_clean_head_at_base(world):
    a = clone_at_base(world, "a")
    write(a, "dirty.txt", "x")
    git(a, "add", "-A")
    assert aps.apply(str(a), world["base"], str(world["patches"] / "series"), str(world["patches"])) == 1
    git(a, "reset", "-q", "--hard")
    write(a, "x.txt", "x")
    git(a, "add", "-A")
    git(a, "commit", "-qm", "moved")
    assert aps.apply(str(a), world["base"], str(world["patches"] / "series"), str(world["patches"])) == 1


def test_apply_conflict_writes_report_and_restores_tree(world):
    a = clone_at_base(world, "a")
    # Upstream "moves on": base tree is changed on the same line the patch touches.
    write(a, "app/a.txt", "".join(f"line{i}\n" if i != 5 else "UPSTREAM EDIT\n" for i in range(1, 21)))
    git(a, "commit", "-qam", "upstream edit")
    new_base = git(a, "rev-parse", "HEAD").stdout.strip()
    report = world["tmp"] / "conflict.md"
    rc = aps.apply(str(a), new_base, str(world["patches"] / "series"), str(world["patches"]), report_path=str(report))
    assert rc == 2
    text = report.read_text()
    assert world["names"][0] in text and "app/a.txt" in text
    assert git(a, "rev-parse", "HEAD").stdout.strip() == new_base
    assert git(a, "status", "--porcelain").stdout.strip() == ""
    assert not os.path.exists(os.path.join(str(a), ".git", "rebase-apply"))


# --- assemble -------------------------------------------------------------------------

def make_ci_dir(tmp_path):
    ci = tmp_path / "ci"
    (ci / "wrapper").mkdir(parents=True, exist_ok=True)
    (ci / "wrapper" / "patched-windows-release.yml").write_text("name: wrapper\non: workflow_dispatch\njobs: {}\n")
    (ci / "vpcommon.py").write_text("# helper\n")
    (ci / "tests").mkdir(exist_ok=True)
    (ci / "tests" / "test_x.py").write_text("# must not be copied\n")
    return ci


def assemble_args(world, ci, repo, **over):
    ns = argparse.Namespace(repo=str(repo), ci_dir=str(ci), base=world["base"], tag=TAG, n=1,
                            branch="build/v6.2.0-daily.202-n1", repo_slug="Nonary/moonlight-qt", release_id=454272425,
                            published_at=TS, series_sha=S1, patch_count=2,
                            groups="posture-core,touch-menu", gate="auto", sensitive_count="0", trial=False)
    for k, val in over.items():
        setattr(ns, k, val)
    return ns


def test_assemble_strips_everything_but_the_reusable_workflow(world):
    a = clone_at_base(world, "a")
    ci = make_ci_dir(world["tmp"])
    assert aps.apply(str(a), world["base"], str(world["patches"] / "series"), str(world["patches"])) == 0
    assert asb.assemble(assemble_args(world, ci, a)) == 0
    files = sorted(f for f in git(a, "ls-files").stdout.split() if f.startswith(".github"))
    assert files == [".github/workflows/build-win-mac.yml", ".github/workflows/patched-windows-release.yml"]
    assert sorted(os.listdir(os.path.join(str(a), ".vp-ci"))) == ["build-meta.json", "vpcommon.py"]
    # the kept upstream workflow is workflow_call ONLY (dispatch removed by the pipeline)
    kept = os.path.join(str(a), ".github", "workflows", "build-win-mac.yml")
    wc.require_workflow_call_only(kept)
    text = open(kept, encoding="utf-8").read()
    assert "workflow_dispatch" not in text and "workflow_call:" in text and "runs-on: windows-2025" in text
    meta = json.load(open(os.path.join(str(a), ".vp-ci", "build-meta.json")))
    assert meta["build"]["version"] == "6.2.0-daily.61616" and meta["build"]["file_version"] == "6.2.61616.0"
    assert meta["build"]["build_number"] == 61616 and meta["build"]["n"] == 1
    assert meta["patch_commits"] == 2 and meta["upstream"]["commit"] == world["base"]
    assert meta["patches"]["groups"] == ["posture-core", "touch-menu"]
    assert git(a, "rev-list", "--count", f"{world['base']}..HEAD").stdout.strip() == "3"
    assert git(a, "status", "--porcelain").stdout.strip() == ""


def test_assemble_is_reproducible(world):
    tips = []
    for name in ("a", "b"):
        repo = clone_at_base(world, name)
        ci = make_ci_dir(world["tmp"])
        aps.apply(str(repo), world["base"], str(world["patches"] / "series"), str(world["patches"]))
        asb.assemble(assemble_args(world, ci, repo))
        tips.append(git(repo, "rev-parse", "HEAD").stdout.strip())
    assert tips[0] == tips[1]


@pytest.mark.parametrize("forbidden", [".github/workflows/evil.yml", ".gitmodules", "wix/Moonlight/Product.wxs",
                                       "scripts/generate-bundle.bat", "setup-deps.ps1", "setup-deps.py",
                                       "app/version.txt", "libs/windows/x.dll", "moonlight-common-c/x.c"])
def test_assemble_guard_rejects_protected_paths(world, forbidden):
    a = clone_at_base(world, "a")
    ci = make_ci_dir(world["tmp"])
    write(a, forbidden, "x\n")
    git(a, "add", "-A")
    git(a, "commit", "-qm", "sneaky patch")
    assert asb.assemble(assemble_args(world, ci, a)) == 1


def test_assemble_guard_rejects_gitlink(world):
    a = clone_at_base(world, "a")
    ci = make_ci_dir(world["tmp"])
    git(a, "update-index", "--add", "--cacheinfo", f"160000,{world['base']},third-party/sub")
    git(a, "commit", "-qm", "gitlink")
    assert asb.assemble(assemble_args(world, ci, a)) == 1


def test_assemble_rejects_bad_gate_and_slug(world):
    a = clone_at_base(world, "a")
    ci = make_ci_dir(world["tmp"])
    assert asb.assemble(assemble_args(world, ci, a, gate="whatever")) == 1
    with pytest.raises(v.ValidationError):
        asb.assemble(assemble_args(world, ci, a, repo_slug="a/b/c"))


# --- rot matrix -------------------------------------------------------------------------

def test_rot_matrix_pass_conflict_and_known_fail(world):
    import rot_matrix as rm
    up = world["repo"]
    git(up, "tag", "v6.2.0-daily.201", world["base"])
    # a later upstream release where the patched line changed -> conflict
    git(up, "checkout", "-q", "main")
    lines = ["UPSTREAM EDIT" if k == 5 else f"line{k}" for k in range(1, 21)]
    write(up, "app/a.txt", "\n".join(lines) + "\n")
    git(up, "commit", "-qam", "upstream edit")
    git(up, "tag", "v6.2.0-daily.202")
    scratch = world["tmp"] / "scratch"
    subprocess.run(["git", "-c", "core.autocrlf=false", "clone", "-q", str(up), str(scratch)], check=True,
                   capture_output=True)

    def fake_fetch_factory(slug):
        def fetch(path):
            tag = path.rsplit("/", 1)[1]
            sha = git(up, "rev-parse", f"{tag}^{{commit}}").stdout.strip()
            return {"ref": f"refs/tags/{tag}", "object": {"type": "commit", "sha": sha}}
        return fetch

    tags = ["v6.2.0-daily.201", "v6.2.0-daily.202"]
    res = rm.run(str(scratch), "Nonary/moonlight-qt", tags, str(world["patches"] / "series"),
                 str(world["patches"]), [], fetch_factory=fake_fetch_factory, remote=str(up))
    assert [(r["tag"], r["status"]) for r in res] == [(tags[0], "pass"), (tags[1], "conflict")]
    assert rm.failing(res) == [tags[1]]
    res2 = rm.run(str(scratch), "Nonary/moonlight-qt", tags, str(world["patches"] / "series"),
                  str(world["patches"]), [tags[1]], fetch_factory=fake_fetch_factory, remote=str(up))
    assert rm.failing(res2) == []
    assert "known failure" in rm.render(res2)


# --- the REAL series on the REAL upstream tag (skipped when the objects are not in this clone) ----------

def _have(rev):
    return subprocess.run(["git", "-C", ROOT, "cat-file", "-e", rev + "^{commit}"], capture_output=True).returncode == 0


@pytest.mark.skipif(not _have("v6.2.0-daily.202"), reason="upstream tag not available in this clone")
def test_real_series_applies_to_daily_202_and_assembles(tmp_path):
    wt = tmp_path / "wt"
    base = git(ROOT, "rev-parse", "v6.2.0-daily.202^{commit}").stdout.strip()
    subprocess.run(["git", "-C", ROOT, "-c", "core.autocrlf=false", "worktree", "add", "-q", "--detach", str(wt), base], check=True,
                   capture_output=True)
    try:
        rc = aps.apply(str(wt), base, os.path.join(ROOT, "patches", "series"), os.path.join(ROOT, "patches"))
        assert rc == 0
        ns = argparse.Namespace(repo=str(wt), ci_dir=CI_DIR, base=base, tag="v6.2.0-daily.202", n=1,
                                branch="build/v6.2.0-daily.202-n1", repo_slug="Nonary/moonlight-qt",
                                release_id=454272425, published_at="2026-11-22T07:17:53Z", series_sha=S1,
                                patch_count=7, groups="posture-core,touch-menu", gate="auto",
                                sensitive_count="0", trial=False)
        assert asb.assemble(ns) == 0
        files = sorted(f for f in git(wt, "ls-files").stdout.split("\n") if f.startswith(".github"))
        assert files == [".github/workflows/build-win-mac.yml", ".github/workflows/patched-windows-release.yml"]
        wc.require_workflow_call_only(os.path.join(str(wt), ".github", "workflows", "build-win-mac.yml"))
    finally:
        subprocess.run(["git", "-C", ROOT, "worktree", "remove", "--force", str(wt)], capture_output=True)
