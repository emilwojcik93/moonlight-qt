"""Linux AppImage in the release set: staging, SHA256SUMS, additive manifest keys, Windows byte-identity."""
import argparse
import copy
import hashlib
import json
import os
import re

import pytest

import appimage_gate as ag
import manifest_gen as mg
import stage_assets as st
import vpcommon as v
from test_appimage_gate import CI, NAME, image_bytes
from test_release_assets import BUNDLE, C1, CI_VERSION, S1, TAG, TS, ZIP, gate_summary

assert CI == CI_VERSION
HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "fixtures", "windows_only")


@pytest.fixture(autouse=True)
def small_bounds(monkeypatch):
    monkeypatch.setattr(st, "MIN_BYTES", 1)
    monkeypatch.setattr(ag, "MIN_BYTES", 1024)


def make_dirs(tmp_path, image=None, extra=None):
    rel = tmp_path / "in" / "release"
    rel.mkdir(parents=True)
    (rel / BUNDLE).write_bytes(b"MZ-installer-bytes")
    (rel / ZIP).write_bytes(b"PK-zip")
    lin = tmp_path / "in" / "linux"
    lin.mkdir(parents=True)
    (lin / NAME).write_bytes(image_bytes() if image is None else image)
    for name in (extra or []):
        (lin / name).write_bytes(b"x")
    return rel, lin


def linux_summary(path, content=None, **over):
    data = image_bytes() if content is None else content
    s = {"status": "ok", "tool": "appimage_gate", "ci_version": CI,
         "image": {"name": NAME, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)},
         "elf": {"machine": "x86_64", "appimage_type": 2, "squashfs_offset": 192},
         "squashfs": {"compression": "zstd", "bytes_used": 8192},
         "embedded": {"desktop_version": CI, "binary_version": CI, "binary_machine": "x86_64"},
         "reader": "unsquashfs"}
    s.update(over)
    path.write_text(json.dumps(s))
    return str(path)


def stage_all(tmp_path, **kw):
    rel, lin = make_dirs(tmp_path)
    dist = tmp_path / "dist"
    st.stage(str(rel), str(dist), CI, gate_summary(tmp_path / "gate.json"), str(lin),
             linux_summary(tmp_path / "lin.json"))
    return dist


def gen_argv(dist, win, lin=None, extra=()):
    argv = ["generate", "--dist", str(dist), "--tag", TAG + "-vp.1", "--upstream-tag", TAG, "--upstream-commit", C1,
            "--release-id", "454272425", "--n", "1", "--build-version", CI, "--file-version", "6.2.61616.0",
            "--run-id", "123", "--source-ref", "refs/heads/build/v6.2.0-daily.202-n1", "--source-sha", C1,
            "--series-sha", S1, "--patch-count", "7", "--groups", "posture-core,touch-menu", "--created-at", TS,
            "--gate-summary", win]
    if lin:
        argv += ["--linux-gate-summary", lin]
    return argv + list(extra)


# --- staging ---------------------------------------------------------------------------------------------------------

def test_stage_adds_the_appimage_next_to_the_installer(tmp_path):
    rel, lin = make_dirs(tmp_path)
    dist = tmp_path / "dist"
    staged = st.stage(str(rel), str(dist), CI, gate_summary(tmp_path / "g.json"), str(lin), linux_summary(tmp_path / "l.json"))
    assert staged == ["MoonlightSetup.exe", NAME]
    assert sorted(os.listdir(dist)) == sorted([NAME, "MoonlightSetup.exe"])
    assert (dist / NAME).read_bytes() == image_bytes()
    assert (dist / "MoonlightSetup.exe").read_bytes() == b"MZ-installer-bytes"


def test_stage_without_the_linux_options_is_unchanged(tmp_path):
    rel, _ = make_dirs(tmp_path)
    dist = tmp_path / "dist"
    assert st.stage(str(rel), str(dist), CI) == ["MoonlightSetup.exe"]
    assert os.listdir(dist) == ["MoonlightSetup.exe"]


def test_stage_requires_dir_and_summary_together(tmp_path):
    rel, lin = make_dirs(tmp_path)
    with pytest.raises(v.ValidationError):
        st.stage(str(rel), str(tmp_path / "d1"), CI, "", str(lin), "")
    with pytest.raises(v.ValidationError):
        st.stage(str(rel), str(tmp_path / "d2"), CI, "", "", linux_summary(tmp_path / "l.json"))


@pytest.mark.parametrize("label,over", [
    ("tampered after the gate", {"image": {"name": NAME, "sha256": "0" * 64, "size": len(image_bytes())}}),
    ("other version", {"ci_version": "6.2.0-daily.61617"}),
    ("not ok", {"status": "failed"}),
    ("other tool", {"tool": "bundle_gate"}),
    ("other name", {"image": {"name": "Moonlight-6.2.0-daily.61617-x86_64.AppImage", "sha256": "0" * 64, "size": 1}}),
])
def test_stage_rebinds_the_bytes_to_the_gate_summary(tmp_path, label, over):
    rel, lin = make_dirs(tmp_path)
    with pytest.raises(v.ValidationError):
        st.stage(str(rel), str(tmp_path / "dist"), CI, "", str(lin), linux_summary(tmp_path / "l.json", **over))


def test_stage_rejects_a_wrong_appimage_artifact(tmp_path):
    summ = linux_summary(tmp_path / "l.json")
    rel, lin = make_dirs(tmp_path, extra=["README"])
    with pytest.raises(v.ValidationError):  # unexpected extra file
        st.stage(str(rel), str(tmp_path / "d"), CI, "", str(lin), summ)
    (lin / "README").unlink()
    (lin / NAME).unlink()
    with pytest.raises(v.ValidationError):  # missing
        st.stage(str(rel), str(tmp_path / "d"), CI, "", str(lin), summ)
    (lin / "Moonlight-6.2.0-daily.61617-x86_64.AppImage").write_bytes(image_bytes())
    with pytest.raises(v.ValidationError):  # wrong name
        st.stage(str(rel), str(tmp_path / "d"), CI, "", str(lin), summ)


@pytest.mark.parametrize("data", [b"MZ" + image_bytes()[2:], image_bytes()[:500], b"x" * 4000])
def test_stage_rejects_a_file_that_is_not_an_appimage(tmp_path, data):
    rel, lin = make_dirs(tmp_path, image=data)
    with pytest.raises(v.ValidationError):
        st.stage(str(rel), str(tmp_path / "d"), CI, "", str(lin), linux_summary(tmp_path / "l.json"))


def test_stage_rejects_symlinks_in_the_appimage_artifact(tmp_path):
    rel, lin = make_dirs(tmp_path)
    (lin / NAME).unlink()
    target = tmp_path / "real.AppImage"
    target.write_bytes(image_bytes())
    (lin / NAME).symlink_to(target)
    with pytest.raises(v.ValidationError):
        st.stage(str(rel), str(tmp_path / "d"), CI, "", str(lin), linux_summary(tmp_path / "l.json"))


def test_stage_cli(tmp_path, capsys):
    rel, lin = make_dirs(tmp_path)
    args = ["--release-dir", str(rel), "--dist", str(tmp_path / "dist"), "--ci-version", CI,
            "--gate-summary", gate_summary(tmp_path / "g.json"),
            "--appimage-dir", str(lin), "--appimage-gate-summary", linux_summary(tmp_path / "l.json")]
    assert st.main(args) == 0
    assert f"staged: MoonlightSetup.exe, {NAME}" in capsys.readouterr().out
    assert st.main(args[:-2]) == 1  # directory without a summary
    assert st.main(args[:-4] + ["--appimage-dir", str(tmp_path / "nope"), *args[-2:]]) == 1


# --- manifest and SHA256SUMS -----------------------------------------------------------------------------------------------

def test_manifest_with_linux_keys(tmp_path):
    dist = stage_all(tmp_path)
    assert mg.main(gen_argv(dist, gate_summary(tmp_path / "gate2.json"), linux_summary(tmp_path / "l2.json"))) == 0
    m = json.loads((dist / "manifest.json").read_text())
    data = image_bytes()
    assert m["linux"] == {"installer": NAME, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    assert m["linux_checks"]["embedded"] == {"desktop_version": CI, "binary_version": CI, "binary_machine": "x86_64"}
    assert m["linux_checks"]["image"]["sha256"] == m["linux"]["sha256"] and m["linux_checks"]["image"]["name"] == NAME
    # the Windows contract is untouched: installer, assets[], attestation, build
    assert m["installer"] == "MoonlightSetup.exe" and [a["name"] for a in m["assets"]] == ["MoonlightSetup.exe"]
    assert m["attestation"] == ["attestation.sigstore.json"] and m["installer_checks"]["tool"] == "bundle_gate"
    sums = (dist / "SHA256SUMS").read_text().splitlines()
    assert [ln.split("  ")[1] for ln in sums] == [NAME, "MoonlightSetup.exe", "manifest.json"]
    for ln in sums:
        assert re.fullmatch(r"[0-9a-f]{64}  [A-Za-z0-9][A-Za-z0-9._-]{0,99}", ln)
    assert f"{m['linux']['sha256']}  {NAME}" in sums
    assert mg.main(["verify", "--dist", str(dist)]) == 0
    (dist / NAME).write_bytes(b"tampered")
    assert mg.main(["verify", "--dist", str(dist)]) == 1


def test_windows_only_manifest_is_byte_identical_to_the_pre_amendment_output(tmp_path):
    rel, _ = make_dirs(tmp_path)
    dist = tmp_path / "dist"
    st.stage(str(rel), str(dist), CI)
    assert mg.main(gen_argv(dist, gate_summary(tmp_path / "gate.json"))) == 0
    for name in ("manifest.json", "SHA256SUMS"):
        assert (dist / name).read_bytes() == open(os.path.join(GOLDEN, name), "rb").read(), name


def test_windows_fields_do_not_change_when_the_linux_asset_is_added(tmp_path):
    dist = stage_all(tmp_path)
    assert mg.main(gen_argv(dist, gate_summary(tmp_path / "gate.json"), linux_summary(tmp_path / "l.json"))) == 0
    with open(os.path.join(GOLDEN, "manifest.json"), encoding="utf-8") as fh:
        golden = json.load(fh)
    got = json.loads((dist / "manifest.json").read_text())
    additive = {k: got.pop(k) for k in ("linux", "linux_checks")}
    assert got == golden and list(got) == list(golden)  # same keys, same order, same values
    assert list(json.loads((dist / "manifest.json").read_text()))[-2:] == ["linux", "linux_checks"]
    # the only SHA256SUMS differences: one more line, for the AppImage
    new = (dist / "SHA256SUMS").read_text().splitlines()
    old = open(os.path.join(GOLDEN, "SHA256SUMS"), encoding="ascii").read().splitlines()
    assert [ln for ln in new if not ln.endswith("  " + NAME)] == [ln for ln in old if not ln.endswith("  manifest.json")] + \
        [ln for ln in new if ln.endswith("  manifest.json")]
    assert len(new) == len(old) + 1 and additive["linux"]["installer"] == NAME


def test_existing_updater_checks_still_pass_on_a_manifest_with_linux_keys(tmp_path):
    dist = stage_all(tmp_path)
    m = mg.build_manifest(argparse.Namespace(**vars(_ns(dist, tmp_path))))
    assert m["schema"] == 1 and m["product"] == "moonlight"
    assert re.fullmatch(r"MoonlightSetup[A-Za-z0-9._-]{0,40}\.exe", m["installer"])
    assert m["installer"] in [a["name"] for a in m["assets"]]
    assert re.fullmatch(r"6\.2\.0-daily\.[0-9]{5}", m["build"]["version"])
    assert all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.(sigstore\.json|jsonl)", x) for x in m["attestation"])
    mg.validate_manifest(m)


def _ns(dist, tmp_path, **over):
    ns = argparse.Namespace(dist=str(dist), installer="MoonlightSetup.exe", tag=TAG + "-vp.1", upstream_owner="Nonary",
                            upstream_repo="moonlight-qt", upstream_tag=TAG, upstream_commit=C1, release_id=454272425,
                            n=1, build_version=CI, file_version="6.2.61616.0", run_id="123",
                            source_ref="refs/heads/build/v6.2.0-daily.202-n1", source_sha=C1, series_sha=S1,
                            patch_count=7, groups="posture-core,touch-menu", created_at=TS,
                            gate_summary=gate_summary(tmp_path / "gw.json"),
                            linux_gate_summary=linux_summary(tmp_path / "gl.json"))
    for k, val in over.items():
        setattr(ns, k, val)
    return ns


def test_generate_refuses_a_summary_that_does_not_match_the_staged_file(tmp_path):
    dist = stage_all(tmp_path)
    other = image_bytes(trailer=4)
    with pytest.raises(v.ValidationError):
        mg.build_manifest(_ns(dist, tmp_path, linux_gate_summary=linux_summary(tmp_path / "x.json", content=other)))
    with pytest.raises(v.ValidationError):
        mg.build_manifest(_ns(dist, tmp_path, linux_gate_summary=linux_summary(tmp_path / "y.json", ci_version="6.2.0-daily.61617")))
    (dist / NAME).unlink()
    with pytest.raises(v.ValidationError):  # linux summary but no staged AppImage
        mg.build_manifest(_ns(dist, tmp_path))
    assert mg.main(gen_argv(dist, gate_summary(tmp_path / "g.json"), linux_summary(tmp_path / "l.json"))) == 1


# --- sanitizer and schema ------------------------------------------------------------------------------------------------------

def good_summary():
    return json.loads(open(linux_summary(__import__("pathlib").Path(__import__("tempfile").mkdtemp()) / "s.json")).read())


def test_sanitizer_accepts_the_gate_output_and_drops_unknown_keys():
    s = good_summary()
    s["extra"] = {"x": 1}
    s["image"]["note"] = "ignored"
    clean = mg.sanitize_linux_gate_summary(s, CI)
    assert clean is not None and "extra" not in clean and "note" not in clean["image"] and clean["tool"] == "appimage_gate"
    assert mg.sanitize_linux_gate_summary(s) is not None  # expected version optional


@pytest.mark.parametrize("path,value", [
    (("status",), "failed"), (("status",), None), (("ci_version",), "6.2.0-daily.202"),
    (("ci_version",), "6.2.0-daily.61617"), (("image", "name"), "Moonlight-6.2.0-daily.61617-x86_64.AppImage"),
    (("image", "name"), "../x"), (("image", "sha256"), "ABC"), (("image", "size"), 0), (("image", "size"), True),
    (("image", "size"), 2 ** 40), (("elf", "machine"), "aarch64"), (("elf", "appimage_type"), 1),
    (("elf", "squashfs_offset"), -1), (("squashfs", "compression"), "rot13"), (("squashfs", "bytes_used"), "8"),
    (("embedded", "desktop_version"), "6.2.0-daily.61617"), (("embedded", "binary_version"), "x"),
    (("embedded", "binary_machine"), "arm64"), (("reader",), "bash"), (("image",), "x"), (("embedded",), None),
])
def test_sanitizer_rejects_inconsistent_summaries(path, value):
    s = good_summary()
    node = s
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value
    assert mg.sanitize_linux_gate_summary(s, CI) is None


def test_sanitizer_rejects_non_dicts_and_missing_blocks():
    for raw in (None, [], "x", {}, {"status": "ok"}):
        assert mg.sanitize_linux_gate_summary(raw, CI) is None
    for key in ("image", "elf", "squashfs", "embedded"):
        s = good_summary()
        del s[key]
        assert mg.sanitize_linux_gate_summary(s, CI) is None


def manifest_with_linux(tmp_path):
    dist = stage_all(tmp_path)
    return mg.build_manifest(_ns(dist, tmp_path))


def test_validate_manifest_linux_rules(tmp_path):
    m = manifest_with_linux(tmp_path)
    mg.validate_manifest(m)
    cases = []
    for label, edit in [
        ("linux without checks", lambda x: x.pop("linux_checks")),
        ("checks without linux", lambda x: x.pop("linux")),
        ("extra key in linux", lambda x: x["linux"].update(extra=1)),
        ("missing key in linux", lambda x: x["linux"].pop("size")),
        ("name not the build version", lambda x: x["linux"].update(installer="Moonlight-6.2.0-daily.61617-x86_64.AppImage")),
        ("name outside contract", lambda x: x["linux"].update(installer="MoonlightSetup.exe")),
        ("bad sha", lambda x: x["linux"].update(sha256="xyz")),
        ("size zero", lambda x: x["linux"].update(size=0)),
        ("checks for another file", lambda x: x["linux_checks"]["image"].update(sha256="1" * 64)),
        ("checks for another size", lambda x: x["linux_checks"]["image"].update(size=1)),
        ("checks for another version", lambda x: x["linux_checks"].update(ci_version="6.2.0-daily.61617")),
        ("linux not a dict", lambda x: x.update(linux="x")),
    ]:
        bad = copy.deepcopy(m)
        edit(bad)
        with pytest.raises(v.ValidationError):
            mg.validate_manifest(bad)
        cases.append(label)
    assert len(cases) == 12


def test_the_appimage_is_covered_by_the_same_regexes_as_other_assets():
    assert v.ASSET_NAME_RE.fullmatch(NAME) and mg.LINUX_NAME_RE.fullmatch(NAME)
    for bad in ("Moonlight-6.2.0-daily.0123-x86_64.AppImage", "Moonlight-6.2.0-daily.61616-aarch64.AppImage",
                "Moonlight-6.2.0-daily.61616-x86_64.AppImage\n", "moonlight-6.2.0-daily.61616-x86_64.AppImage"):
        assert mg.LINUX_NAME_RE.fullmatch(bad) is None
