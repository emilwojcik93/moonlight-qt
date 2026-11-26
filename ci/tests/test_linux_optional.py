"""Linux is optional: the REAL stage steps of the wrapper are executed with bash for both outcomes.

The ``run:`` text of the ``package`` and ``publish`` stage steps is taken from the wrapper template and run
in a scratch directory with the helper scripts copied to ``.vp-ci``; only size floors are lowered in that
copy (the synthetic files are tiny).  ``LINUX_OK=false`` is what the workflow evaluates when the ``linux``
job failed or was cancelled.
"""
import json
import os
import re
import shutil
import subprocess
import textwrap

import pytest

import manifest_gen as mg
import notify_dedupe as nd
import notify_text as nt
import vpcommon as v
from test_appimage_gate import CI, NAME, image_bytes
from test_linux_release_assets import linux_summary
from test_release_assets import BUNDLE, C1, S1, TAG, TS, ZIP, gate_summary
from test_workflows import WRAPPER, jobs, read, step

HERE = os.path.dirname(os.path.abspath(__file__))
CI_DIR = os.path.dirname(HERE)
GOLDEN = os.path.join(HERE, "fixtures", "windows_only")

ENV = {"TAG": TAG + "-vp.1", "UP_TAG": TAG, "UP_COMMIT": C1, "RELEASE_ID": "454272425", "N": "1",
       "BUILD_VERSION": CI, "FILE_VERSION": "6.2.61616.0", "RUN_ID": "123",
       "SOURCE_REF": "refs/heads/build/v6.2.0-daily.202-n1", "SOURCE_SHA": C1, "SERIES_SHA": S1, "PATCH_COUNT": "7",
       "GROUPS_CSV": "posture-core,touch-menu", "LINUX_RESULT": "failure"}


def script_and_env_keys(job, prefix):
    text = step(job, prefix)
    run = text.split("        run: |\n", 1)[1]
    body = textwrap.dedent(run.split("\n      - name:", 1)[0])
    env_keys = set(re.findall(r"(?m)^          ([A-Z_]+): \$\{\{", text))
    return body, env_keys


@pytest.fixture()
def work(tmp_path):
    w = tmp_path / "w"
    vp = w / ".vp-ci"
    vp.mkdir(parents=True)
    for name in os.listdir(CI_DIR):
        if name.endswith(".py"):
            shutil.copyfile(os.path.join(CI_DIR, name), vp / name)
    # lower the size floors in the COPY (synthetic files are tiny); logic is untouched
    sa = (vp / "stage_assets.py").read_text().replace("MIN_BYTES = 1024 * 1024", "MIN_BYTES = 1")
    (vp / "stage_assets.py").write_text(sa)
    ag = (vp / "appimage_gate.py").read_text().replace("MIN_BYTES = 16 * 1024 * 1024", "MIN_BYTES = 1024")
    (vp / "appimage_gate.py").write_text(ag)
    (vp / "build-meta.json").write_text(json.dumps({"sensitive": {"since": "", "count": 0, "paths": [], "enforced": False}}))
    rel = w / "in" / "release"
    rel.mkdir(parents=True)
    (rel / BUNDLE).write_bytes(b"MZ-installer-bytes")
    (rel / ZIP).write_bytes(b"PK-zip")
    (w / "in" / "summary").mkdir()
    (w / "in" / "linux").mkdir()
    (w / "in" / "linux" / NAME).write_bytes(image_bytes())
    gate_summary(w / "gate-summary.json")
    gate_summary(w / "in" / "summary" / "gate-summary.json")
    linux_summary(w / "appimage-gate-summary.json")
    linux_summary(w / "in" / "summary" / "appimage-gate-summary.json")
    (w / "gate.md").write_text("### Version gate passed\n")
    (w / "appimage-gate.md").write_text("### AppImage gate passed\n")
    return w


def run_step(work, job_name, prefix, linux_ok):
    job = jobs(read(WRAPPER))[job_name]
    body, keys = script_and_env_keys(job, prefix)
    env = dict(ENV, LINUX_OK="true" if linux_ok else "false")
    assert keys <= set(env), f"step env keys not provided by the test: {keys - set(env)}"
    full = dict(os.environ, **env, GITHUB_STEP_SUMMARY=str(work / "summary.md"))
    proc = subprocess.run(["bash", "-c", body], cwd=work, env=full, capture_output=True, text=True)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return proc


def golden_manifest():
    with open(os.path.join(GOLDEN, "manifest.json"), encoding="utf-8") as fh:
        return json.load(fh)


def windows_part(manifest):
    """The manifest without the fields that differ by construction in this scripted run."""
    m = {k: val for k, val in manifest.items() if k not in ("created_at", "sensitive_paths_touched", "linux", "linux_checks")}
    return m


STAGES = [("package", "preview"), ("publish", "dist")]


@pytest.mark.parametrize("job_name,dist", STAGES)
def test_linux_failed_gives_the_windows_only_release_identical_to_the_pre_change_golden(work, job_name, dist):
    (work / "in" / "linux" / NAME).unlink()      # the artifact does not exist when the linux job failed
    (work / "appimage-gate-summary.json").unlink()
    (work / "in" / "summary" / "appimage-gate-summary.json").unlink()
    run_step(work, job_name, "Stage the installer", linux_ok=False)
    out = work / dist
    assert sorted(os.listdir(out)) == ["MoonlightSetup.exe", "SHA256SUMS", "manifest.json"]
    m = json.loads((out / "manifest.json").read_text())
    assert "linux" not in m and "linux_checks" not in m
    gold = golden_manifest()
    assert windows_part(m) == windows_part(gold) and list(windows_part(m)) == list(windows_part(gold))
    sums = (out / "SHA256SUMS").read_text().splitlines()
    old = open(os.path.join(GOLDEN, "SHA256SUMS"), encoding="ascii").read().splitlines()
    assert [ln for ln in sums if not ln.endswith("  manifest.json")] == [ln for ln in old if not ln.endswith("  manifest.json")]
    assert not any("AppImage" in ln for ln in sums)
    assert mg.main(["verify", "--dist", str(out)]) == 0
    if job_name == "package":
        assert "Linux AppImage not included (linux job result: failure)" in (work / "summary.md").read_text()
        assert sorted(os.listdir(work / "preview-upload")) == ["SHA256SUMS", "gate-summary.json", "manifest.json"]


@pytest.mark.parametrize("job_name,dist", STAGES)
def test_linux_success_adds_the_appimage_and_the_linux_keys(work, job_name, dist):
    run_step(work, job_name, "Stage the installer", linux_ok=True)
    out = work / dist
    assert sorted(os.listdir(out)) == sorted([NAME, "MoonlightSetup.exe", "SHA256SUMS", "manifest.json"])
    m = json.loads((out / "manifest.json").read_text())
    assert m["linux"]["installer"] == NAME and m["linux"]["size"] == len(image_bytes())
    assert m["linux_checks"]["ci_version"] == CI
    assert windows_part(m) == windows_part(golden_manifest())      # Windows fields unchanged by the AppImage
    sums = (out / "SHA256SUMS").read_text().splitlines()
    assert f"{m['linux']['sha256']}  {NAME}" in sums and len(sums) == 3
    assert mg.main(["verify", "--dist", str(out)]) == 0
    if job_name == "package":
        assert "AppImage gate passed" in (work / "summary.md").read_text()
        assert "appimage-gate-summary.json" in os.listdir(work / "preview-upload")


def test_a_tampered_appimage_still_fails_the_stage_step_when_linux_succeeded(work):
    (work / "in" / "linux" / NAME).write_bytes(image_bytes(trailer=8))   # differs from what the gate summary hashed
    with pytest.raises(AssertionError, match="differs from the file the AppImage gate inspected"):
        run_step(work, "publish", "Stage the installer", linux_ok=True)


def test_without_linux_a_stray_appimage_artifact_is_ignored_not_staged(work):
    run_step(work, "publish", "Stage the installer", linux_ok=False)     # in/linux/<NAME> is still on disk
    assert NAME not in os.listdir(work / "dist")
    assert "linux" not in json.loads((work / "dist" / "manifest.json").read_text())


# --- the separate alert kind --------------------------------------------------------------------------------------

def test_linuxskipped_is_a_distinct_alert_kind_with_its_own_dedupe_marker():
    out = nt.compose({"KIND": "linuxskipped", "TAG": TAG + "-vp.1", "RUN_ID": "5", "REPO": "emilwojcik93/moonlight-qt"})
    assert out["alert"] == "true" and "Windows release is unaffected" in out["text"]
    assert out["marker"] == f"<!-- ml-alert:kind=linuxskipped;tag={TAG}-vp.1 -->"
    assert nd.MARKER_RE.fullmatch(out["marker"])
    failure = nt.compose({"KIND": "failure", "TAG": TAG + "-vp.1", "REPO": "emilwojcik93/moonlight-qt"})
    assert failure["marker"] != out["marker"]
    # a recent build-failure alert for the same tag does not suppress the Linux one (and vice versa)
    import datetime as dt
    issue = {"createdAt": "2026-11-26T10:00:00Z", "body": failure["issue_body"], "comments": []}
    now = dt.datetime(2026, 11, 26, 11, tzinfo=dt.timezone.utc)
    assert nd.suppress(issue, failure["marker"], now) is True
    assert nd.suppress(issue, out["marker"], now) is False
    issue2 = {"createdAt": "2026-11-26T10:00:00Z", "body": out["issue_body"], "comments": []}
    assert nd.suppress(issue2, out["marker"], now) is True      # repeat within 24 h is de-duplicated
    with pytest.raises(v.ValidationError):
        nt.compose({"KIND": "linux-skipped", "REPO": "emilwojcik93/moonlight-qt"})
