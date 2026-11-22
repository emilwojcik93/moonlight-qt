"""Version gate: PE version-resource reader, Burn manifest parsing and the bundle gate."""
import json
import os
import struct

import pytest

import bundle_gate as bg
import manifest_gen as mg
import pe_version as pe
import vpcommon as v

UP = "v6.2.0-daily."
TAG = UP + "202"


# --- synthetic PE builder (a real PE resource tree, no real binaries in the repo) ---------------------------

def _align4(b: bytes) -> bytes:
    return b + b"\x00" * (-len(b) % 4)


def _u16z(text: str) -> bytes:
    return text.encode("utf-16-le") + b"\x00\x00"


def _node(wvallen, wtype, key, payload):
    """One VS_VERSIONINFO node: header + key padded together, payload, wLength excludes the trailing pad."""
    head = _align4(struct.pack("<HHH", 0, wvallen, wtype) + _u16z(key))
    body = head + payload
    return struct.pack("<H", len(body)) + body[2:]


def _string_entry(key: str, value: str) -> bytes:
    return _align4(_node(len(value) + 1, 1, key, _u16z(value)))


def version_block(fixed=(6, 2, 61616, 0), strings=None) -> bytes:
    strings = {"FileVersion": ".".join(map(str, fixed)), "ProductVersion": ".".join(map(str, fixed))}         if strings is None else strings
    ms = (fixed[0] << 16) | fixed[1]
    ls = (fixed[2] << 16) | fixed[3]
    ffi = struct.pack("<13I", 0xFEEF04BD, 0x10000, ms, ls, ms, ls, 0x3F, 0, 0x4, 1, 0, 0, 0)
    table = _align4(_node(0, 1, "040904b0", b"".join(_string_entry(k, val) for k, val in strings.items())))
    sfi = _align4(_node(0, 1, "StringFileInfo", table))
    return _node(52, 0, "VS_VERSION_INFO", ffi + sfi)


def build_pe(fixed=(6, 2, 61616, 0), strings=None, with_rsrc=True, pe32=False, junk_tail=0) -> bytes:
    block = _align4(version_block(fixed, strings))
    # resource tree at the start of the section: root -> RT_VERSION -> id 1 -> lang -> data entry
    dir_hdr = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1)
    root = dir_hdr + struct.pack("<II", 16, 0x80000000 | 24)
    l2 = dir_hdr + struct.pack("<II", 1, 0x80000000 | 48)
    l3 = dir_hdr + struct.pack("<II", 0x409, 72)
    rva_section = 0x2000
    data_entry_off = 72
    data_rva = rva_section + 88
    entry = struct.pack("<IIII", data_rva, len(block), 0, 0)
    rsrc = root + l2 + l3 + entry + block
    raw_ptr = 0x400
    opt_size = 224 if pe32 else 240
    opt = bytearray(opt_size)
    struct.pack_into("<H", opt, 0, 0x10B if pe32 else 0x20B)
    dd = 96 if pe32 else 112
    if with_rsrc:
        struct.pack_into("<II", opt, dd + 16, rva_section, len(rsrc))
    coff = struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, opt_size, 0x22)
    sect = struct.pack("<8sIIIIIIHHI", b".rsrc", len(rsrc), rva_section, len(rsrc), raw_ptr, 0, 0, 0, 0, 0x40000040)
    dos = bytearray(64)
    dos[:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x80)
    out = bytearray(raw_ptr)
    out[:64] = dos
    out[0x80:0x84] = b"PE\x00\x00"
    out[0x84:0x84 + 20] = coff
    out[0x98:0x98 + opt_size] = opt
    out[0x98 + opt_size:0x98 + opt_size + 40] = sect
    return bytes(out) + rsrc + b"\x00" * junk_tail


def write_pe(path, **kw):
    path.write_bytes(build_pe(**kw))
    return str(path)


def test_pe_reader_roundtrip_and_strings(tmp_path):
    info = pe.read(write_pe(tmp_path / "a.exe"))
    assert info["fixed"] == (6, 2, 61616, 0)
    assert info["file_version"] == "6.2.61616.0" and info["product_version"] == "6.2.61616.0"
    assert pe.dotted(info["fixed"]) == "6.2.61616.0"
    info = pe.read(write_pe(tmp_path / "b.exe", pe32=True, fixed=(1, 2, 3, 4), strings={"FileVersion": "1.2.3.4"}))
    assert info["fixed"] == (1, 2, 3, 4) and info["product_version"] is None


@pytest.mark.parametrize("mutate", [
    lambda b: b"ZZ" + b[2:],                                  # not MZ
    lambda b: b[:0x80] + b"XX" + b[0x82:],                    # bad PE signature
    lambda b: b[:0x3C] + struct.pack("<I", 0xFFFFFF) + b[0x40:],   # e_lfanew far outside
    lambda b: b[:200],                                        # truncated headers
    lambda b: b[:0x400 + 40],                                 # truncated resources
    lambda b: b[:0x98 + 112 + 16] + b"\xff" * 8 + b[0x98 + 112 + 24:],   # rsrc rva garbage
])
def test_pe_reader_rejects_malformed_input(tmp_path, mutate):
    p = tmp_path / "x.exe"
    p.write_bytes(mutate(build_pe() + b"\x00" * 600))
    with pytest.raises(v.ValidationError):
        pe.read(str(p))


def test_pe_reader_without_resources_and_tiny_file(tmp_path):
    with pytest.raises(v.ValidationError):
        pe.read(write_pe(tmp_path / "n.exe", with_rsrc=False))
    (tmp_path / "t.exe").write_bytes(b"MZ")
    with pytest.raises(v.ValidationError):
        pe.read(str(tmp_path / "t.exe"))


def test_pe_reader_cli(tmp_path, capsys):
    assert pe.main([write_pe(tmp_path / "a.exe")]) == 0
    assert "fixed=6.2.61616.0" in capsys.readouterr().out
    assert pe.main([str(tmp_path / "missing.exe")]) == 1
    assert pe.main([]) == 2


REAL_BUNDLE = os.environ.get("ML_REAL_BUNDLE", r"C:\Users\ewojcik\MoonlightSetup-6.2.0-daily.60002.exe")
REAL_7Z = r"C:\Program Files\7-Zip\7z.exe"


@pytest.mark.skipif(not os.path.isfile(REAL_BUNDLE), reason="no real Burn bundle on this machine")
def test_real_bundle_version_resource():
    info = pe.read(REAL_BUNDLE)
    assert info["fixed"] == (6, 2, 60002, 0) and info["file_version"] == "6.2.60002.0"


@pytest.mark.skipif(not (os.path.isfile(REAL_BUNDLE) and os.path.isfile(REAL_7Z)), reason="no real bundle / 7-Zip")
def test_real_bundle_burn_manifest_via_7zip():
    got = bg.parse_burn_versions(bg.extract_burn_manifest(REAL_BUNDLE, REAL_7Z))
    assert got["registration_version"] == "6.2.60002.0"
    assert [(p["id"], p["version"]) for p in got["msi_packages"]] == [("Moonlight_x64", "6.2.60002.0"),
                                                                    ("Moonlight_arm64", "6.2.60002.0")]


# --- Burn manifest parsing ------------------------------------------------------------------------------

def burn_xml(version="6.2.61616.0", reg=None, pkgs=("Moonlight_x64", "Moonlight_arm64"), pkg_versions=None):
    reg = reg or version
    out = ['<?xml version="1.0" encoding="utf-8"?><BurnManifest EngineVersion="7.0.0.0" ProtocolVersion="1" '
           'xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">',
           '<RelatedBundle Code="{466FA35D-4BE4-40EF-9CE5-AFADC3B63BC5}" Action="Upgrade" />']
    for i, pid in enumerate(pkgs):
        pv = (pkg_versions or {}).get(pid, version)
        out.append(f'<MsiPackage Id="{pid}" Cache="keep" CacheId="{{94CF10A5-3B8B}}v{pv}" InstallSize="1" '
                   f'ProductCode="{{94CF10A5-3B8B-4823-8FB3-D7034481B898}}" Language="1033" Version="{pv}" '
                   f'UpgradeCode="{{5C09F94E-F809-4C6A-9B7B-597C99F041FE}}">')
        out.append("<MsiProperty Id=\"X\" Value=\"Version=9.9.9.9\" /></MsiPackage>")
    out.append('<ExePackage Id="VC_redist.x64.exe" Version="14.44.35211.0" />')
    out.append(f'<Registration Code="{{E4B673B5}}" ExecutableName="MoonlightSetup.exe" Scope="perMachine" Tag="" '
               f'Version="{reg}" ProviderKey="{{E4B673B5}}">')
    return "".join(out)


def test_burn_parse_extracts_registration_and_packages():
    got = bg.parse_burn_versions(burn_xml())
    assert got == {"registration_version": "6.2.61616.0",
                   "msi_packages": [{"id": "Moonlight_x64", "version": "6.2.61616.0"},
                                    {"id": "Moonlight_arm64", "version": "6.2.61616.0"}]}


@pytest.mark.parametrize("bad", [
    '<MsiPackage Id="x" Version="6.2.1">',                       # too few parts
    '<MsiPackage Id="a;b" Version="6.2.61616.0">',               # hostile id
    '<MsiPackage Id="x" Version="6.2.61616.0\n">',               # newline in version
    '<MsiPackage Id="x">',                                       # no version
])
def test_burn_parse_rejects_hostile_values(bad):
    with pytest.raises(v.ValidationError):
        bg.parse_burn_versions(bad)


# --- the gate ---------------------------------------------------------------------------------------------

@pytest.fixture()
def files(tmp_path):
    def make(bundle=(6, 2, 61616, 0), x64=(6, 2, 61616, 0), arm64=(6, 2, 61616, 0), strings=None):
        b = write_pe(tmp_path / "MoonlightSetup-6.2.0-daily.61616.exe", fixed=bundle, strings=strings)
        return b, write_pe(tmp_path / "x64.exe", fixed=x64), write_pe(tmp_path / "arm64.exe", fixed=arm64)
    return make


def gate(monkeypatch, files, xml=None, tag=TAG, n=1, **kw):
    b, x, a = files(**kw)
    monkeypatch.setattr(bg, "extract_burn_manifest", lambda bundle, seven_zip=None: xml or burn_xml())
    return bg.run_gate(tag, n, b, x, a)


def test_gate_passes_for_the_expected_build(monkeypatch, files):
    s = gate(monkeypatch, files)
    assert s["status"] == "ok" and s["expected_file_version"] == "6.2.61616.0"
    assert s["upstream_file_version"] == "6.2.202.0"
    assert s["executables"] == {"x64": {"file_version": "6.2.61616.0"}, "arm64": {"file_version": "6.2.61616.0"}}
    assert s["burn"]["registration_version"] == "6.2.61616.0" and len(s["burn"]["msi_packages"]) == 2
    assert v.SHA256_RE.fullmatch(s["bundle"]["sha256"])


@pytest.mark.parametrize("kw", [
    {"bundle": (6, 2, 202, 0)},                # upstream's own version: upstream installs would replace ours
    {"bundle": (6, 2, 61617, 0)},              # wrong rebuild
    {"bundle": (6, 2, 60006, 0)},              # legacy hand-built
    {"bundle": (6, 2, 61616, 1)},              # fourth field
    {"x64": (6, 2, 202, 0)},
    {"arm64": (6, 2, 61615, 0)},
    {"strings": {"FileVersion": "6.2.202.0"}},     # numeric ok, string lies
    {"strings": {"ProductVersion": "6.2.61616.0"}},  # no FileVersion string at all
])
def test_gate_fails_on_any_version_mismatch(monkeypatch, files, kw):
    with pytest.raises(v.ValidationError):
        gate(monkeypatch, files, **kw)


@pytest.mark.parametrize("xml", [
    burn_xml(reg="6.2.202.0"),
    burn_xml(pkg_versions={"Moonlight_arm64": "6.2.202.0"}),
    burn_xml(pkg_versions={"Moonlight_x64": "6.2.61615.0"}),
    burn_xml(pkgs=("Moonlight_x64",)),                       # arm64 package missing
    burn_xml(pkgs=()),
])
def test_gate_fails_on_burn_manifest_mismatch(monkeypatch, files, xml):
    with pytest.raises(v.ValidationError):
        gate(monkeypatch, files, xml=xml)


def test_gate_fails_for_unbuildable_tag_or_n(monkeypatch, files):
    with pytest.raises(v.ValidationError):
        gate(monkeypatch, files, n=9)
    with pytest.raises(v.ValidationError):
        gate(monkeypatch, files, tag=UP + "692")


def test_gate_cli_writes_summary_and_markdown(monkeypatch, files, tmp_path, capsys):
    b, x, a = files()
    monkeypatch.setattr(bg, "extract_burn_manifest", lambda bundle, seven_zip=None: burn_xml())
    out, md = tmp_path / "s.json", tmp_path / "s.md"
    rc = bg.main(["--tag", TAG, "--n", "1", "--bundle", b, "--x64-exe", x, "--arm64-exe", a,
                  "--out", str(out), "--markdown", str(md)])
    assert rc == 0 and json.loads(out.read_text())["status"] == "ok"
    assert "Version gate passed" in md.read_text() and "6.2.61616.0" in md.read_text()
    out.unlink()
    assert bg.main(["--tag", TAG, "--n", "2", "--bundle", b, "--x64-exe", x, "--arm64-exe", a,
                    "--out", str(out)]) == 1 and not out.exists()


def test_extract_burn_manifest_is_bounded_and_needs_a_manifest(tmp_path):
    fake = tmp_path / "7z.py"
    fake.write_text("import sys\nsys.stdout.write('not a manifest')\n")
    import stat
    import sys
    wrapper = tmp_path / ("7z.cmd" if os.name == "nt" else "7z.sh")
    if os.name == "nt":
        wrapper.write_text(f'@"{sys.executable}" "{fake}" %*\n')
    else:
        wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{fake}" "$@"\n')
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
    with pytest.raises(v.ValidationError):
        bg.extract_burn_manifest(str(tmp_path / "b.exe"), str(wrapper))
    with pytest.raises(v.ValidationError):
        bg.extract_burn_manifest(str(tmp_path / "b.exe"), str(tmp_path / "does-not-exist"))


# --- manifest embedding of the gate summary ---------------------------------------------------------------

def test_gate_summary_is_revalidated_before_it_reaches_the_manifest(monkeypatch, files):
    s = gate(monkeypatch, files)
    assert mg.sanitize_gate_summary(s, "6.2.61616.0") is not None
    assert mg.sanitize_gate_summary(s, "6.2.61617.0") is None  # not the expected build
    for mutate in (lambda d: d["burn"]["msi_packages"].pop(),
                   lambda d: d["burn"].update(registration_version="6.2.202.0"),
                   lambda d: d["bundle"].update(sha256="x"),
                   lambda d: d["bundle"].update(file_version="6.2.202.0"),
                   lambda d: d["executables"].pop("arm64"),
                   lambda d: d["executables"]["x64"].update(file_version="6.2.1.0"),
                   lambda d: d["burn"]["msi_packages"][0].update(id="a;b"),
                   lambda d: d.update(status="failed")):
        evil = json.loads(json.dumps(s))
        mutate(evil)
        assert mg.sanitize_gate_summary(evil, "6.2.61616.0") is None
