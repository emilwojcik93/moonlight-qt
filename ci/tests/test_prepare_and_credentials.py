import argparse
import os
import re
import subprocess

import pytest

import prepare_build_branch as pbb
import vpcommon as v

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WATCH = os.path.join(ROOT, ".github", "workflows", "upstream-watch.yml")


def test_slug_from_url():
    assert pbb.slug_from_url("git@github.com:emilwojcik93/moonlight-qt.git") == "emilwojcik93/moonlight-qt"
    assert pbb.slug_from_url("https://github.com/emilwojcik93/moonlight-qt") == "emilwojcik93/moonlight-qt"
    for bad in ("https://evil.example/a/b.git", "git@github.com:a/b/c.git", "file:///x"):
        with pytest.raises(v.ValidationError):
            pbb.slug_from_url(bad)


def test_runs_from_api_maps_attempt_and_conclusion():
    payload = {"workflow_runs": [{"id": 5, "head_branch": "build/v6.2.0-daily.202-n1", "status": "completed",
                                  "conclusion": "failure", "run_attempt": 2}, {"id": 6, "head_branch": "x",
                                                                                 "status": "queued"}]}
    out = pbb.runs_from_api(payload)
    assert out[0] == {"databaseId": 5, "headBranch": "build/v6.2.0-daily.202-n1", "status": "completed",
                      "conclusion": "failure", "attempt": 2}
    assert out[1]["attempt"] == 1 and out[1]["conclusion"] == ""
    assert pbb.runs_from_api({"message": "Not Found"}) == []


def test_http_get_json_refuses_foreign_urls():
    for url in ("https://example.com/repos/x", "http://api.github.com/repos/a/b", "file:///etc/passwd",
                "https://api.github.com.evil.example/repos/a/b"):
        with pytest.raises(v.ValidationError):
            pbb.http_get_json(url)


def git(cwd, *a):
    return subprocess.run(["git", "-C", str(cwd), *a], capture_output=True, text=True, check=True).stdout


def test_refuses_dirty_tree_and_wrong_branch(tmp_path):
    repo = tmp_path / "r"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "automation")
    git(repo, "config", "user.email", "t@example.invalid")
    git(repo, "config", "user.name", "t")
    (repo / "f").write_text("x")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "c")
    git(repo, "remote", "add", "origin", "git@github.com:o/r.git")
    args = argparse.Namespace(root=str(repo), tag=None, remote="origin", fork_repo="", dry_run=True,
                              override_hold=False, force_rebuild=False, allow_any_branch=False, workdir="",
                              upstream_url="")
    (repo / "dirty").write_text("y")
    assert pbb.prepare(args, get_json=lambda u: (_ for _ in ()).throw(AssertionError("no network before guards"))) == 1
    os.remove(repo / "dirty")
    git(repo, "checkout", "-qb", "other")
    assert pbb.prepare(args, get_json=lambda u: (_ for _ in ()).throw(AssertionError("no network before guards"))) == 1


def test_script_has_exactly_two_push_calls_and_no_force():
    text = open(os.path.join(ROOT, "ci", "prepare_build_branch.py"), encoding="utf-8").read()
    code = re.sub(r'""".*?"""', "", text, flags=re.S)
    pushes = re.findall(r'"push"', code)
    assert len(pushes) == 2  # lock commit, build branch: the only credentialed steps
    code = chr(10).join(line.split("  # ")[0] for line in code.splitlines())
    assert not re.search(r'"--force"|"-f"|--force(?!-rebuild)', code.replace("--force-rebuild", ""))


# --- prepare job: App OR deploy key, never GITHUB_TOKEN for the branch push ---------------------

def prepare_job():
    text = open(WATCH, encoding="utf-8").read()
    start = text.index("\n  prepare:\n")
    end = text.index("\n  rerun:\n")
    return text[start:end]


def test_prepare_supports_app_and_deploy_key_with_strict_ssh():
    job = prepare_job()
    assert "PUSH_APP_PRIVATE_KEY" in job and "PUSH_DEPLOY_KEY" in job
    assert "IdentitiesOnly=yes" in job and "StrictHostKeyChecking=yes" in job and "UserKnownHostsFile" in job
    assert "gh api meta --jq '.ssh_keys[]'" in job
    assert "umask 077" in job and "chmod 600" in job
    assert "rm -f" in job and "if: always() && steps.cred.outputs.mode == 'deploy'" in job
    assert "No push credential configured" in job and "Refusing to fall back" in job
    assert "StrictHostKeyChecking=no" not in job and "accept-new" not in job


def test_branch_push_steps_never_use_github_token():
    job = prepare_job()
    steps = job.split(chr(10) + "      - name:")
    app_step = next(x for x in steps if x.startswith(" Push the build branch (App token"))
    deploy_step = next(x for x in steps if x.startswith(" Push the build branch (deploy key"))
    assert "github.token" not in app_step and "GITHUB_TOKEN" not in app_step
    assert "GITHUB_TOKEN" not in deploy_step
    # the deploy step only reads the PUBLIC /meta endpoint with the job token; the push itself is ssh
    assert deploy_step.count("github.token") == 1 and "git@github.com:" in deploy_step
    assert "x-access-token" not in deploy_step
