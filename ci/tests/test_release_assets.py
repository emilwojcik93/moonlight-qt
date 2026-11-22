import argparse
import datetime as dt
import hashlib
import json
import os

import pytest

import manifest_gen as mg
import notify_dedupe as nd
import notify_text as nt
import sensitive_paths as sp
import stage_assets as st
import version_map as vm
import vpcommon as v
import wrapper_params as wp
from test_gate import build_pe, burn_xml  # noqa: F401  (synthetic PE helper)

UP = "v6.2.0-daily."
TAG = UP + "202"
C1 = "a" * 40
S1 = "1" * 64
TS = "2026-11-22T07:17:53Z"
CI_VERSION = "6.2.0-daily.61616"
BUNDLE = f"MoonlightSetup-{CI_VERSION}.exe"
ZIP = f"MoonlightPortable-x64-{CI_VERSION}.zip"


@pytest.fixture(autouse=True)
def small_installers(monkeypatch):
    monkeypatch.setattr(st, "MIN_BYTES", 1)


def make_release_dir(tmp_path, extra=None, with_zip=True, payload=b"MZ-installer-bytes"):
    d = tmp_path / "in" / "release"
    d.mkdir(parents=True)
    (d / BUNDLE).write_bytes(payload)
    if with_zip:
        (d / ZIP).write_bytes(b"PK-zip")
    for name in (extra or []):
        (d / name).write_bytes(b"x")
    return d


def gate_summary(path, payload=b"MZ-installer-bytes", version="6.2.61616.0"):
    summary = {"status": "ok", "tool": "bundle_gate", "expected_file_version": version,
               "upstream_file_version": "6.2.202.0",
               "bundle": {"sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload), "file_version": version},
               "burn": {"registration_version": version,
                        "msi_packages": [{"id": "Moonlight_x64", "version": version},
                                         {"id": "Moonlight_arm64", "version": version}]},
               "executables": {"x64": {"file_version": version}, "arm64": {"file_version": version}}}
    path.write_text(json.dumps(summary))
    return str(path)


def gen_args(dist, summary, **over):
    ns = argparse.Namespace(dist=str(dist), installer="MoonlightSetup.exe", tag=TAG + "-vp.1",
                            upstream_owner="Nonary", upstream_repo="moonlight-qt", upstream_tag=TAG,
                            upstream_commit=C1, release_id=454272425, n=1, build_version=CI_VERSION,
                            file_version="6.2.61616.0", run_id="123",
                            source_ref="refs/heads/build/v6.2.0-daily.202-n1", source_sha=C1, series_sha=S1,
                            patch_count=7, groups="posture-core,touch-menu", created_at=TS, gate_summary=summary)
    for k, val in over.items():
        setattr(ns, k, val)
    return ns


# --- stage ------------------------------------------------------------------------------------------------

def test_stage_renames_the_bundle_and_never_publishes_the_zip(tmp_path):
    d = make_release_dir(tmp_path)
    dist = tmp_path / "dist"
    assert st.stage(str(d), str(dist), CI_VERSION) == ["MoonlightSetup.exe"]
    assert sorted(os.listdir(dist)) == ["MoonlightSetup.exe"]
    assert (dist / "MoonlightSetup.exe").read_bytes() == b"MZ-installer-bytes"


def test_stage_rejects_unexpected_or_missing_files(tmp_path):
    with pytest.raises(v.ValidationError):
        st.stage(str(make_release_dir(tmp_path / "a", extra=["evil.dll"])), str(tmp_path / "d1"), CI_VERSION)
    with pytest.raises(v.ValidationError):
        st.stage(str(make_release_dir(tmp_path / "b", with_zip=False)), str(tmp_path / "d2"), CI_VERSION)
    with pytest.raises(v.ValidationError):  # artifact of another build
        st.stage(str(make_release_dir(tmp_path / "c")), str(tmp_path / "d3"), "6.2.0-daily.61617")
    with pytest.raises(v.ValidationError):  # ci_version must be well formed
        st.stage(str(make_release_dir(tmp_path / "e")), str(tmp_path / "d4"), "6.2.0-daily.1;id")


def test_stage_size_floor_and_pe_magic(tmp_path, monkeypatch):
    monkeypatch.setattr(st, "MIN_BYTES", 1024 * 1024)
    with pytest.raises(v.ValidationError):  # a real Burn bundle is ~50 MB
        st.stage(str(make_release_dir(tmp_path / "a")), str(tmp_path / "d"), CI_VERSION)
    monkeypatch.setattr(st, "MIN_BYTES", 1)
    with pytest.raises(v.ValidationError):
        st.stage(str(make_release_dir(tmp_path / "b", payload=b"not an exe")), str(tmp_path / "d2"), CI_VERSION)


def test_stage_binds_the_staged_bytes_to_the_gate_summary(tmp_path):
    d = make_release_dir(tmp_path)
    ok = gate_summary(tmp_path / "s.json")
    st.stage(str(d), str(tmp_path / "ok"), CI_VERSION, ok)
    # the file inspected by the gate is not the file that would be attested
    bad = gate_summary(tmp_path / "bad.json", payload=b"MZ-other-bytes")
    with pytest.raises(v.ValidationError):
        st.stage(str(d), str(tmp_path / "bad"), CI_VERSION, bad)


def test_stage_rejects_symlink(tmp_path):
    d = make_release_dir(tmp_path)
    try:
        os.symlink(str(d / BUNDLE), str(d / "link.exe"))
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unavailable")
    with pytest.raises(v.ValidationError):
        st.stage(str(d), str(tmp_path / "d"), CI_VERSION)


# --- manifest + sums ----------------------------------------------------------------------------------------

def staged(tmp_path):
    d = make_release_dir(tmp_path)
    dist = tmp_path / "dist"
    st.stage(str(d), str(dist), CI_VERSION)
    return dist, gate_summary(tmp_path / "gate.json")


def test_manifest_roundtrip_matches_the_contract_and_the_updater(tmp_path):
    dist, summ = staged(tmp_path)
    rc = mg.main(["generate", "--dist", str(dist), "--tag", TAG + "-vp.1", "--upstream-tag", TAG,
                  "--upstream-commit", C1, "--release-id", "454272425", "--n", "1", "--build-version", CI_VERSION,
                  "--file-version", "6.2.61616.0", "--run-id", "123", "--source-ref",
                  "refs/heads/build/v6.2.0-daily.202-n1", "--source-sha", C1, "--series-sha", S1, "--patch-count", "7",
                  "--groups", "posture-core,touch-menu", "--created-at", TS, "--gate-summary", summ])
    assert rc == 0
    m = json.loads((dist / "manifest.json").read_text())
    # CONTRACT section 3 / UPDATER.md section 8 item 4 (fields the Windows updater reads)
    assert m["schema"] == 1 and m["product"] == "moonlight" and m["tag"] == "v6.2.0-daily.202-vp.1"
    assert m["upstream"] == {"owner": "Nonary", "repo": "moonlight-qt", "tag": TAG, "commit": C1,
                             "release_id": 454272425}
    b = m["build"]
    assert b["n"] == 1 and b["version"] == "6.2.0-daily.61616" and b["msi_product_version"] == "6.2.61616.0"
    assert b["workflow"] == ".github/workflows/patched-windows-release.yml"
    assert b["source_ref"] == "refs/heads/build/v6.2.0-daily.202-n1" and b["source_sha"] == C1
    assert m["patches"] == {"series_sha256": S1, "count": 7, "groups": ["posture-core", "touch-menu"]}
    assert m["installer"] == "MoonlightSetup.exe" and m["attestation"] == ["attestation.sigstore.json"]
    assert [a["name"] for a in m["assets"]] == ["MoonlightSetup.exe"]
    assert m["installer_checks"]["expected_file_version"] == "6.2.61616.0"
    sums = (dist / "SHA256SUMS").read_text().splitlines()
    assert [ln.split("  ")[1] for ln in sums] == ["MoonlightSetup.exe", "manifest.json"]
    assert "SHA256SUMS" not in "".join(sums) and "sigstore" not in "".join(sums)
    for ln in sums:  # the updater's SHA256SUMS line regex
        assert __import__("re").fullmatch(r"[0-9a-f]{64}  [A-Za-z0-9][A-Za-z0-9._-]{0,99}", ln)
    assert mg.main(["verify", "--dist", str(dist)]) == 0
    for a in m["assets"]:
        assert f"{a['sha256']}  {a['name']}" in sums
    (dist / "MoonlightSetup.exe").write_bytes(b"tampered")  # tamper -> verify fails
    assert mg.main(["verify", "--dist", str(dist)]) == 1


def test_updater_side_checks_on_the_generated_manifest(tmp_path):
    """Re-implements Read-ReleaseManifest (updater/lib/Verify.ps1) in python."""
    import re
    dist, summ = staged(tmp_path)
    m = mg.build_manifest(gen_args(dist, summ))
    assert m["schema"] == 1 and m["product"] == "moonlight"
    assert re.fullmatch(r"MoonlightSetup[A-Za-z0-9._-]{0,40}\.exe", m["installer"])
    assert re.fullmatch(r"6\.2\.0-daily\.[0-9]{5}", m["build"]["version"])
    assert re.fullmatch(r"[0-9a-f]{40}", m["build"]["source_sha"])
    u, n = vm.from_build_number(int(m["build"]["version"].split(".")[-1]))
    assert (u, n) == (202, 1) and m["build"]["source_ref"] == f"refs/heads/build/v6.2.0-daily.{u}-n{n}"
    for x in m["attestation"]:
        assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.(sigstore\.json|jsonl)", x)
    assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", m["upstream"]["owner"])


def test_manifest_validation_rejects_inconsistency(tmp_path):
    dist, summ = staged(tmp_path)
    for over in ({"build_version": "6.2.0-daily.61617"}, {"file_version": "6.2.202.0"},
                 {"tag": TAG + "-vp.2"}, {"upstream_commit": "xyz"}, {"source_ref": "refs/tags/" + TAG},
                 {"source_ref": "refs/heads/automation"}, {"run_id": "1; rm"}, {"installer": "../evil.exe"},
                 {"installer": "Evil.exe"}, {"created_at": "yesterday"}, {"n": 9}, {"n": 2},
                 {"groups": "a; b"}, {"upstream_tag": UP + "692"}):
        with pytest.raises((v.ValidationError, KeyError, ValueError)):
            mg.build_manifest(gen_args(dist, summ, **over))
    with pytest.raises(v.ValidationError):  # the gate summary is mandatory
        mg.build_manifest(gen_args(dist, None))
    other = gate_summary(tmp_path / "other.json", version="6.2.61617.0")
    with pytest.raises(v.ValidationError):  # summary of a different build
        mg.build_manifest(gen_args(dist, other))
    swapped = gate_summary(tmp_path / "swapped.json", payload=b"MZ-other")
    with pytest.raises(v.ValidationError):  # summary describes a different installer file
        mg.build_manifest(gen_args(dist, swapped))


def test_sums_refuses_self_and_bundle(tmp_path):
    (tmp_path / "a.bin").write_bytes(b"1")
    for bad in ("SHA256SUMS", "attestation.sigstore.json", "../x"):
        with pytest.raises(v.ValidationError):
            mg.write_sums(str(tmp_path), ["a.bin", bad])


def test_sensitive_line_cli(tmp_path, capsys):
    meta = tmp_path / "m.json"
    meta.write_text(json.dumps({"sensitive": {"since": UP + "201", "count": 3, "paths": ["a"], "enforced": False}}))
    assert mg.main(["sensitive-line", "--meta", str(meta)]) == 0
    assert "SENSITIVE UPSTREAM PATHS TOUCHED since v6.2.0-daily.201: 3 file(s)" in capsys.readouterr().out
    meta.write_text(json.dumps({"sensitive": {"since": "", "count": 0, "paths": [], "enforced": False}}))
    assert mg.main(["sensitive-line", "--meta", str(meta)]) == 0
    assert "none" in capsys.readouterr().out


@pytest.mark.parametrize("bad", [{"since": "x", "count": 0, "paths": [], "enforced": False},
                                 {"since": "", "count": -1, "paths": [], "enforced": False},
                                 {"since": "", "count": 1, "paths": ["a\nb"], "enforced": False},
                                 {"since": "", "count": 1, "paths": ["a"] * 51, "enforced": False},
                                 {"since": "", "count": 1, "paths": [], "enforced": "yes"}, None, []])
def test_sensitive_block_is_validated(bad):
    with pytest.raises(v.ValidationError):
        mg.sanitize_sensitive(bad)


def test_manifest_records_sensitive_paths(tmp_path):
    dist, summ = staged(tmp_path)
    meta = tmp_path / "meta.json"
    meta.write_text(json.dumps({"sensitive": {"since": UP + "201", "count": 2, "paths": ["wix/a.wxs", "scripts/b.ps1"],
                                              "enforced": False}}))
    m = mg.build_manifest(gen_args(dist, summ, meta=str(meta)))
    assert m["sensitive_paths_touched"] == {"since": UP + "201", "count": 2,
                                            "paths": ["wix/a.wxs", "scripts/b.ps1"], "enforced": False}


# --- wrapper params ----------------------------------------------------------------------------------------------

def meta(tag=TAG, n=1, trial=False, branch=None, gate="auto"):
    ver = vm.compute(tag, n)
    return {"schema": 1,
            "upstream": {"owner": "Nonary", "repo": "moonlight-qt", "tag": tag, "commit": C1, "release_id": 454272425,
                         "published_at": TS},
            "build": {"n": n, "release_tag": ver["release_tag"], "version": ver["build_version"],
                      "build_number": int(ver["build_number"]), "file_version": ver["file_version"],
                      "branch": branch or f"{'ci-trial' if trial else 'build'}/{tag}-n{n}", "trial": trial},
            "patches": {"series_sha256": S1, "count": 7, "groups": ["posture-core", "touch-menu"]},
            "patch_commits": 7, "gate": gate, "sensitive_count": 0,
            "sensitive": {"since": "", "count": 0, "paths": [], "enforced": False}}


def env(ref="refs/heads/build/v6.2.0-daily.202-n1", **kw):
    e = {"EVENT_NAME": "push", "REF": ref, "SHA": "b" * 40, "INPUT_DRY_RUN": ""}
    e.update(kw)
    return e


def test_wrapper_params_release_and_dry_run():
    out = wp.derive(env(), meta())
    assert out["dry_run"] == "false" and out["environment"] == "release-auto"
    assert out["build_version"] == "6.2.0-daily.61616" and out["file_version"] == "6.2.61616.0"
    assert out["upstream_file_version"] == "6.2.202.0" and out["build_number"] == "61616"
    assert out["patch_groups"] == "posture-core,touch-menu"
    assert wp.derive(env(INPUT_DRY_RUN="true"), meta())["dry_run"] == "true"
    assert wp.derive(env(), meta(gate="approval"))["environment"] == "release-approval"


def test_wrapper_params_trial_is_always_dry_and_maps_n0():
    out = wp.derive(env(ref="refs/heads/ci-trial/v6.2.0-daily.202-n0"),
                    meta(n=1, trial=True, branch="ci-trial/v6.2.0-daily.202-n0"))
    assert out["dry_run"] == "true" and out["n"] == "1" and out["trial"] == "true"


@pytest.mark.parametrize("ref", ["refs/tags/v6.2.0-daily.202", "refs/heads/master", "refs/heads/build/v6.2.0-daily.202-n1/x",
                                 "refs/heads/build/$(id)-n1", "refs/heads/build/v6.2.0-daily.202-n1\n", "refs/pull/1/merge",
                                 "refs/heads/automation", "", "refs/heads/build/v6.2.0-daily.0202-n1",
                                 "refs/heads/build/v6.2.0-daily.202-n01"])
def test_wrapper_params_refuses_foreign_refs(ref):
    with pytest.raises(v.ValidationError):
        wp.derive(env(ref=ref), meta())


def test_wrapper_params_cross_checks_and_n_limit():
    with pytest.raises(v.ValidationError):  # tag mismatch
        wp.derive(env(ref="refs/heads/build/v6.2.0-daily.203-n1"), meta())
    with pytest.raises(v.ValidationError):  # n mismatch
        wp.derive(env(ref="refs/heads/build/v6.2.0-daily.202-n2"), meta())
    with pytest.raises(v.ValidationError):  # trial flag vs branch kind
        wp.derive(env(ref="refs/heads/ci-trial/v6.2.0-daily.202-n1"), meta())
    with pytest.raises(v.ValidationError):  # release n=0
        wp.derive(env(ref="refs/heads/build/v6.2.0-daily.202-n0"), meta(n=1))
    with pytest.raises(v.ValidationError):  # CONTRACT 3b: N > 8 fails the build
        wp.derive(env(ref="refs/heads/build/v6.2.0-daily.202-n9"), {**meta(), "build": {**meta()["build"], "n": 9}})
    for field, value in (("version", "6.2.0-daily.60006"), ("file_version", "6.2.60006.0"),
                         ("build_number", 60006), ("release_tag", TAG + "-vp.2")):
        bad = meta()
        bad["build"][field] = value
        with pytest.raises(v.ValidationError):
            wp.derive(env(), bad)
    bad = meta()
    bad["upstream"]["commit"] = "nothex"
    with pytest.raises(v.ValidationError):
        wp.derive(env(), bad)
    bad = meta()
    bad["patches"]["groups"] = ["x; rm"]
    with pytest.raises(v.ValidationError):
        wp.derive(env(), bad)


def test_wrapper_workflow_set_check(tmp_path):
    gh = tmp_path / ".github"
    d = gh / "workflows"
    d.mkdir(parents=True)
    call_only = "name: x\non:\n  workflow_call:\n    inputs: {}\njobs: {}\n"
    (d / "build-win-mac.yml").write_text(call_only)
    (d / "patched-windows-release.yml").write_text("x")
    wp.check_workflows(str(d))
    (d / "build.yml").write_text("x")
    with pytest.raises(v.ValidationError):
        wp.check_workflows(str(d))
    (d / "build.yml").unlink()
    (d / "build-win-mac.yml").write_text("name: x\non:\n  workflow_call:\n  workflow_dispatch:\njobs: {}\n")
    with pytest.raises(v.ValidationError):  # dispatch trigger must have been removed by the assembler
        wp.check_workflows(str(d))
    (d / "build-win-mac.yml").write_text(call_only)
    (gh / "dependabot.yml").write_text("version: 2\n")
    with pytest.raises(v.ValidationError):
        wp.check_workflows(str(d))


# --- notifications ---------------------------------------------------------------------------------------------

def test_notify_sanitizes_everything():
    out = nt.compose({"KIND": "failure", "TAG": "$(id)", "RUN_ID": "123", "REPO": "emilwojcik93/moonlight-qt",
                      "DETAIL": "bad\n@everyone <script>alert(1)</script> `rm -rf` ${{ secrets.X }} " + "x" * 400})
    for key in ("text", "issue_body"):
        assert "<script" not in out[key] and "`rm" not in out[key] and "${{" not in out[key] and "\n@" not in out[key]
    assert "$(id)" not in out["text"] and "(invalid tag)" in out["text"]
    assert len(out["text"]) < 500
    assert "https://github.com/emilwojcik93/moonlight-qt/actions/runs/123" in out["text"]
    assert out["marker"] == "<!-- ml-alert:kind=failure;tag=none -->"


def test_notify_rejects_bad_fields():
    with pytest.raises(v.ValidationError):
        nt.compose({"KIND": "nope", "REPO": "a/b"})
    with pytest.raises(v.ValidationError):
        nt.compose({"KIND": "failure", "REPO": "a/b", "RUN_ID": "12; id"})
    with pytest.raises(v.ValidationError):
        nt.compose({"KIND": "failure", "REPO": "not a repo"})


def test_notify_cli_writes_json_and_marker(tmp_path, monkeypatch):
    for k, val in {"KIND": "stuck", "TAG": TAG + "-vp.1", "RUN_ID": "9", "REPO": "o/r", "DETAIL": ""}.items():
        monkeypatch.setenv(k, val)
    g, i, m = tmp_path / "g.json", tmp_path / "i.md", tmp_path / "m.txt"
    assert nt.main(["--gchat", str(g), "--issue-body", str(i), "--marker", str(m)]) == 0
    assert json.loads(g.read_text())["text"].startswith("moonlight-qt patch pipeline: Build stuck")
    assert m.read_text().strip() == "<!-- ml-alert:kind=stuck;tag=v6.2.0-daily.202-vp.1 -->"
    assert m.read_text().strip() in i.read_text()


# --- alert de-duplication -----------------------------------------------------------------------------------------

NOW = dt.datetime(2026, 11, 22, 12, 0, 0, tzinfo=dt.timezone.utc)
MARK = "<!-- ml-alert:kind=stuck;tag=v6.2.0-daily.202-vp.1 -->"


def issue(created, comments=()):
    return {"createdAt": created, "body": "text " + MARK,
            "comments": [{"createdAt": c, "body": b} for c, b in comments]}


def test_dedupe_suppresses_the_same_alert_within_24h_only():
    assert nd.suppress(issue("2026-11-22T11:00:00Z"), MARK, NOW) is True
    assert nd.suppress(issue("2026-11-20T11:00:00Z"), MARK, NOW) is False            # old
    assert nd.suppress(issue("2026-11-20T11:00:00Z", [("2026-11-22T01:00:00Z", MARK)]), MARK, NOW) is True
    other = "<!-- ml-alert:kind=failure;tag=none -->"
    assert nd.suppress(issue("2026-11-22T11:00:00Z"), other, NOW) is False           # other kind/tag is never hidden
    assert nd.suppress({"createdAt": "2026-11-22T11:00:00Z", "body": "no marker", "comments": []}, MARK, NOW) is False


def test_dedupe_rejects_hostile_input(tmp_path):
    with pytest.raises(v.ValidationError):
        nd.suppress(issue("2026-11-22T11:00:00Z"), "<!-- x -->", NOW)
    with pytest.raises(v.ValidationError):
        nd.suppress([], MARK, NOW)
    assert nd.suppress({"createdAt": "yesterday", "body": MARK, "comments": [1, None, "x"]}, MARK, NOW) is False


def test_dedupe_cli(tmp_path, monkeypatch):
    out = tmp_path / "o"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    (tmp_path / "i.json").write_text(json.dumps(issue("2026-11-22T11:00:00Z")))
    (tmp_path / "m.txt").write_text(MARK + "\n")
    assert nd.main(["--issue", str(tmp_path / "i.json"), "--marker-file", str(tmp_path / "m.txt"),
                    "--now", "2026-11-22T12:00:00Z", "--github-output"]) == 0
    assert out.read_text() == "suppress=true\n"
    (tmp_path / "i.json").write_text("not json")
    assert nd.main(["--issue", str(tmp_path / "i.json"), "--marker-file", str(tmp_path / "m.txt")]) == 1


# --- sensitive paths ---------------------------------------------------------------------------------------------

def test_sensitive_paths():
    flagged = [".github/workflows/build-win-mac.yml", "wix/Moonlight/Product.wxs", "wix/MoonlightSetup/Bundle.wxs",
               "scripts/generate-bundle.bat", "scripts/vrr-pe-version.ps1", "setup-deps.ps1", "setup-deps.py",
               ".gitmodules", "moonlight-common-c/moonlight-common-c", "app/backend/nvhttp.cpp",
               "app/backend/autoupdatechecker.cpp", "app/backend/identitymanager.cpp", "app/streaming/session.cpp",
               "app/app.pro", "moonlight-qt.pro", "globaldefs.pri", "app/version.txt", "app/Moonlight.exe.manifest",
               "AntiHooking/x.cpp", "foo.cmake", "app/deploy/x.bat"]
    quiet = ["README.md", "docs/a.md", "app/gui/Foo.qml", "app/streaming/video/ffmpeg.cpp", "tests/posture/a.cpp",
             "app/languages/qml_de.ts", ""]
    assert sp.sensitive(flagged + quiet) == sorted(flagged)
    assert sp.sensitive(quiet) == []


def test_sensitive_cli(tmp_path, monkeypatch):
    names = tmp_path / "n.txt"
    names.write_text("app/gui/a.qml\n.github/workflows/x.yml\n")
    out = tmp_path / "o"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    assert sp.main(["--names", str(names), "--github-output", "--summary", str(tmp_path / "s.md")]) == 0
    assert "gate=approval" in out.read_text() and "sensitive_count=1" in out.read_text()
