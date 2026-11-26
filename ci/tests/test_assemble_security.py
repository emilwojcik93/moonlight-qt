"""Assemble / workflow-trigger security tests (stripping, planted files, fail-closed triggers).

Scenarios follow the independent QA review of the Vibepollo pipeline (planted helper modules,
case/extension variants, symlinked dirs, trigger edits in the kept upstream workflow), adapted to
moonlight-qt's ``build-win-mac.yml`` which ships BOTH ``workflow_call`` and ``workflow_dispatch``.
"""
import os

import pytest

import apply_series as aps
import assemble_build as asb
import vpcommon as v
import workflow_check as wc
from test_series_apply_assemble import APPIMAGE_WF, CI_DIR, git, write

S1 = "1" * 64
TS = "2026-11-22T07:17:53Z"
CALL_ONLY = "name: x\non:\n  workflow_call:\n    inputs:\n      a:\n        type: string\njobs: {}\n"
CALL_AND_DISPATCH = CALL_ONLY.replace("jobs: {}", "  workflow_dispatch:\n    inputs:\n      a:\n        type: string\njobs: {}")


# --- trigger parser ------------------------------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    (CALL_ONLY, {"workflow_call"}),
    ("on: push\njobs: {}\n", {"push"}),
    ("on: [push, workflow_call]\n", {"push", "workflow_call"}),
    ("on: {workflow_call: {}, schedule: [{cron: '1 2 * * *'}]}\n", {"workflow_call", "schedule"}),
    ("on:\n  workflow_call:\n  push:\n    branches: [main]\n", {"workflow_call", "push"}),
    ("on:\n  - push\n  - workflow_call\n", {"push", "workflow_call"}),
    ('"on":\n  workflow_dispatch:\n', {"workflow_dispatch"}),
    (CALL_AND_DISPATCH, {"workflow_call", "workflow_dispatch"}),
])
def test_workflow_triggers_parser(text, expected):
    assert wc.triggers(text) == expected


def test_workflow_check_fails_closed(tmp_path):
    ok = tmp_path / "ok.yml"
    ok.write_text(CALL_ONLY)
    wc.require_workflow_call_only(str(ok))
    for bad in ("on: push\n", "on:\n  workflow_call:\n  pull_request:\n", "name: no triggers\njobs: {}\n",
                CALL_AND_DISPATCH, "on: [workflow_call, schedule]\n"):
        p = tmp_path / "bad.yml"
        p.write_text(bad)
        with pytest.raises(v.ValidationError):
            wc.require_workflow_call_only(str(p))


def test_real_upstream_shape_is_accepted_after_dispatch_removal():
    text = ("---\nname: Build - Windows and macOS\npermissions:\n  contents: read\n\non:\n  workflow_call:\n    inputs:\n"
            "      ci_version:\n        required: true\n        type: string\n  workflow_dispatch:\n    inputs:\n"
            "      ci_version:\n        required: true\n        type: string\n\njobs:\n  build:\n    runs-on: x\n")
    assert wc.triggers(text) == {"workflow_call", "workflow_dispatch"}
    new = wc.drop_workflow_dispatch(text)
    assert wc.triggers(new) == {"workflow_call"}
    assert "workflow_dispatch" not in new and new.endswith("    runs-on: x\n")
    assert "jobs:\n  build:" in new and "ci_version:" in new.split("jobs:")[0]  # workflow_call inputs untouched


@pytest.mark.parametrize("text", [
    "on: [push, workflow_dispatch]\njobs: {}\n",                                 # flow style: untouched
    "on:\n  workflow_call:\n  push:\n  workflow_dispatch:\n",                    # other triggers stay -> still refused
    "name: x\njobs: {}\n",
])
def test_drop_dispatch_only_removes_the_dispatch_block(text):
    new = wc.drop_workflow_dispatch(text)
    assert "push" in new or "on:" not in text
    if "push" in text:
        assert wc.triggers(new) - {"workflow_dispatch"} == wc.triggers(text) - {"workflow_dispatch"}


def test_drop_dispatch_is_idempotent_and_handles_comments_and_crlf():
    text = "on:\n  workflow_call:\n    inputs: {}\n  # manual runs\n  workflow_dispatch:\n    inputs:\n      x:\n        type: string\n\njobs: {}\n"
    once = wc.drop_workflow_dispatch(text)
    assert wc.triggers(once) == {"workflow_call"} and wc.drop_workflow_dispatch(once) == once
    crlf = wc.drop_workflow_dispatch(text.replace("\n", "\r\n"))
    assert wc.triggers(crlf) == {"workflow_call"} and "\r" not in crlf


# --- assemble on hostile upstream trees ------------------------------------------------------------------------

def mk_up(tmp_path, files):
    repo = tmp_path / "up"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "commit.gpgsign", "false")
    for rel, text in files.items():
        write(repo, rel, text)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")
    return repo, git(repo, "rev-parse", "HEAD").stdout.strip()


def run_assemble(repo, base, tmp_path):
    ci = tmp_path / "ci"
    (ci / "wrapper").mkdir(parents=True)
    (ci / "wrapper" / "patched-windows-release.yml").write_text("name: w\non: push\njobs: {}\n")
    for n in os.listdir(CI_DIR):
        if n.endswith(".py"):
            (ci / n).write_bytes(open(os.path.join(CI_DIR, n), "rb").read())
    series = tmp_path / "series"
    series.write_text("")
    patches = tmp_path / "patches"
    patches.mkdir()
    assert aps.apply(str(repo), base, str(series), str(patches)) == 0
    return asb.main(["--repo", str(repo), "--ci-dir", str(ci), "--base", base, "--tag", "v6.2.0-daily.202", "--n", "1",
                     "--branch", "build/v6.2.0-daily.202-n1", "--release-id", "5", "--published-at", TS,
                     "--series-sha", S1, "--patch-count", "0"])


def listing(repo):
    return sorted(git(repo, "ls-files").stdout.split())


def test_strips_yaml_variants_nested_dirs_planted_wrapper_and_planted_helpers(tmp_path):
    repo, base = mk_up(tmp_path, {
        ".github/workflows/build-win-mac.yml": CALL_AND_DISPATCH,
        ".github/workflows/build-appimage.yml": APPIMAGE_WF,
        ".github/workflows/evil.yaml": "name: e\non: push\njobs: {}\n",
        ".github/workflows/Evil.YML": "name: e\non: push\njobs: {}\n",
        ".github/workflows/sub/x.yml": "name: e\non: push\njobs: {}\n",
        ".github/workflows/patched-windows-release.yml": "name: planted\non: push\njobs: {}\n",
        ".github/actions/evil/action.yml": "name: a\nruns: {using: composite, steps: []}\n",
        ".github/CODEOWNERS": "* @evil\n",
        ".vp-ci/json.py": "raise SystemExit('planted')\n",
        ".vp-ci/sitecustomize.py": "x=1\n",
        "README.md": "x\n"})
    assert run_assemble(repo, base, tmp_path) == 0
    files = listing(repo)
    assert [f for f in files if f.startswith(".github")] == [
        ".github/workflows/build-appimage.yml", ".github/workflows/build-win-mac.yml",
        ".github/workflows/patched-windows-release.yml"]
    assert ".vp-ci/json.py" not in files and ".vp-ci/sitecustomize.py" not in files
    assert open(repo / ".github/workflows/patched-windows-release.yml").read().startswith("name: w")
    wc.require_workflow_call_only(str(repo / ".github/workflows/build-win-mac.yml"))
    wc.require_workflow_call_only(str(repo / ".github/workflows/build-appimage.yml"))


@pytest.mark.parametrize("kept", [
    "name: ci\non: [push, workflow_dispatch]\njobs: {}\n",
    "name: ci\non:\n  workflow_call:\n  push:\n    branches: [master]\njobs: {}\n",
    "name: ci\non:\n  workflow_call:\n  schedule:\n    - cron: '1 2 * * *'\njobs: {}\n",
    "name: ci\non:\n  workflow_call:\n  pull_request:\njobs: {}\n",
    "name: ci\njobs: {}\n",
])
def test_kept_workflow_with_unexpected_triggers_is_refused(tmp_path, kept):
    repo, base = mk_up(tmp_path, {".github/workflows/build-win-mac.yml": kept,
                                  ".github/workflows/build-appimage.yml": APPIMAGE_WF})
    assert run_assemble(repo, base, tmp_path) == 1


@pytest.mark.parametrize("kept", [
    "name: ci\non: [push, workflow_dispatch]\njobs: {}\n",
    "name: ci\non:\n  workflow_call:\n  push:\n    branches: [master]\njobs: {}\n",
    "name: ci\non:\n  workflow_call:\n  schedule:\n    - cron: '1 2 * * *'\njobs: {}\n",
    "name: ci\njobs: {}\n",
])
def test_appimage_workflow_with_unexpected_triggers_is_refused(tmp_path, kept):
    repo, base = mk_up(tmp_path, {".github/workflows/build-win-mac.yml": CALL_AND_DISPATCH,
                                  ".github/workflows/build-appimage.yml": kept})
    assert run_assemble(repo, base, tmp_path) == 1


def test_appimage_workflow_is_required_and_its_dispatch_is_dropped(tmp_path):
    repo, base = mk_up(tmp_path, {".github/workflows/build-win-mac.yml": CALL_AND_DISPATCH})
    assert run_assemble(repo, base, tmp_path) == 1  # fail closed when upstream stops shipping it
    (tmp_path / "second").mkdir()
    repo2, base2 = mk_up(tmp_path / "second", {".github/workflows/build-win-mac.yml": CALL_AND_DISPATCH,
                                               ".github/workflows/build-appimage.yml": APPIMAGE_WF})
    assert run_assemble(repo2, base2, tmp_path / "second") == 0
    text = (repo2 / ".github/workflows/build-appimage.yml").read_text()
    assert "workflow_dispatch" not in text and wc.triggers(text) == {"workflow_call"}
    assert "Version string used for the release artifact" not in text


def test_missing_reusable_workflow_is_refused(tmp_path):
    repo, base = mk_up(tmp_path, {".github/workflows/build.yml": "name: ci\non: push\njobs: {}\n", "README.md": "x\n"})
    assert run_assemble(repo, base, tmp_path) == 1


def test_symlinked_workflows_dir_is_refused(tmp_path):
    if os.name == "nt":
        pytest.skip("symlinks need privileges on Windows")
    repo, base = mk_up(tmp_path, {"x": "1"})
    os.makedirs(repo / ".github")
    os.symlink("/etc", repo / ".github" / "workflows")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "symlink")
    base = git(repo, "rev-parse", "HEAD").stdout.strip()
    assert run_assemble(repo, base, tmp_path) == 1
