"""Linux AppImage gate (appimage_gate.py): synthetic images, fake unsquashfs / 7z executables.

Nothing here runs a real AppImage.  The synthetic image is an ELF header + section table + a
squashfs superblock; the squashfs *reader* is replaced by tiny stand-in executables that record
their command lines, so the exact argv the gate passes is asserted too.  One optional test runs the
real 7-Zip against the real upstream v6.2.0-daily.202 AppImage when ML_REAL_APPIMAGE points at it.
"""
import json
import os
import stat
import struct
import subprocess
import sys
import time

import pytest

import appimage_gate as g
import version_map as vm
import vpcommon as v

UP_TAG = "v6.2.0-daily.202"
CI = "6.2.0-daily.61616"
NAME = f"Moonlight-{CI}-x86_64.AppImage"
SHOFF, SHNUM = 64, 2
OFFSET = SHOFF + 64 * SHNUM  # 192: where the squashfs starts
PAYLOAD = 8192
REAL_APPIMAGE = os.environ.get("ML_REAL_APPIMAGE", os.path.expanduser("~/src/stream-posture-sync/appimage-test/Moonlight.AppImage"))


@pytest.fixture(autouse=True)
def small_bounds(monkeypatch):
    monkeypatch.setattr(g, "MIN_BYTES", 1024)
    monkeypatch.setattr(g, "MIN_BINARY_BYTES", 64)


def elf_head(machine=62, cls=2, data=1, ai=b"AI\x02", shoff=SHOFF, shentsize=64, shnum=SHNUM):
    h = bytearray(64)
    h[0:4] = b"\x7fELF"
    h[4], h[5] = cls, data
    h[8:11] = ai
    struct.pack_into("<H", h, 18, machine)
    struct.pack_into("<Q", h, 0x28, shoff)
    struct.pack_into("<HH", h, 0x3A, shentsize, shnum)
    return bytes(h)


def superblock(magic=b"hsqs", compression=6, major=4, used=PAYLOAD):
    sb = bytearray(96)
    sb[0:4] = magic
    struct.pack_into("<H", sb, 20, compression)
    struct.pack_into("<H", sb, 28, major)
    struct.pack_into("<Q", sb, 40, used)
    return bytes(sb)


def image_bytes(head=None, sb=None, used=PAYLOAD, trailer=0, pad_to=None):
    head = elf_head() if head is None else head
    sb = superblock(used=used) if sb is None else sb
    body = head + b"\0" * (OFFSET - len(head)) + sb + b"\0" * (used - len(sb)) + b"\0" * trailer
    if pad_to:
        body += b"\0" * (pad_to - len(body))
    return body


def write_image(tmp_path, data=None, name=NAME):
    p = tmp_path / name
    p.write_bytes(image_bytes() if data is None else data)
    return str(p)


def desktop(version=CI, extra=""):
    return (f"[Desktop Entry]\nName=Moonlight\nExec=moonlight\nIcon=moonlight\nType=Application\n"
            f"X-AppImage-Version={version}\n{extra}").encode()


def binary(*versions, machine=62, cls=2):
    """ELF whose string table holds each version as its own NUL-delimited literal."""
    return binary_raw(*[ver.encode() + b"\0moonlight-stream.com\0" for ver in versions], machine=machine, cls=cls)


def binary_raw(*chunks, machine=62, cls=2):
    body = bytearray(elf_head(machine=machine, cls=cls, shnum=0))
    body += b"\0padding\0" + b"%s\n\0"
    for chunk in chunks:
        body += chunk
    body += b"\0" * 200
    return bytes(body)


SHIM = """#!{py}
import json, os, sys
a = sys.argv[1:]
root = os.environ["FAKE_ROOT"]
cfg = json.load(open(os.path.join(root, "config.json")))
with open(os.path.join(root, "argv.log"), "a") as fh:
    fh.write(json.dumps([os.path.basename(sys.argv[0])] + a) + "\\n")
def member(name):
    p = os.path.join(root, "m_" + name.replace("/", "__"))
    return open(p, "rb").read() if os.path.exists(p) else b""
kind = os.path.basename(sys.argv[0])
mode = cfg.get("mode")
reads_member = kind == "unsquashfs" or a[:1] == ["e"]
if mode in ("hang", "flood") and reads_member or (mode == "hang_list" and a[:1] == ["l"]):
    open(os.path.join(root, "pid"), "w").write(str(os.getpid()))
    if mode == "flood":
        chunk = b"x" * (1 << 20)
        while True:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    sys.stdout.buffer.write(b"partial output")
    sys.stdout.buffer.flush()
    import time
    time.sleep(300)
if kind == "unsquashfs":
    if a[:3] != ["-n", "-o", str(cfg["offset"])] or a[3] != "-cat" or len(a) != 6:
        sys.exit(2)
    sys.stdout.buffer.write(member(a[5]))
else:
    if a[:1] == ["l"]:
        print("7-Zip (fake)\\n\\nListing archive: x\\n\\n--\\nPath = x\\nType = " + cfg.get("type", "SquashFS") +
              "\\nOffset = " + str(cfg.get("seven_offset", cfg["offset"])) + "\\nPhysical Size = 1\\n\\n----------\\nPath = AppRun")
        sys.exit(0)
    if a[:5] != ["e", "-so", "-bd", "-y", "-tsquashfs"] or a[5] != "--" or len(a) != 8:
        sys.exit(2)
    sys.stdout.buffer.write(member(a[7]))
sys.exit(cfg.get("rc", 0))
"""


@pytest.fixture()
def lab(tmp_path, monkeypatch):
    """A fake squashfs reader: members live in ``root``; returns helpers to configure it."""
    root = tmp_path / "fake"
    bindir = tmp_path / "bin"
    root.mkdir()
    bindir.mkdir()
    for exe in ("unsquashfs", "7z"):
        p = bindir / exe
        p.write_text(SHIM.format(py=sys.executable))
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("FAKE_ROOT", str(root))
    cfg = {"offset": OFFSET}

    class Lab:
        def __init__(self):
            self.root = root
            self.bin = bindir

        def config(self, **kw):
            cfg.update(kw)
            (root / "config.json").write_text(json.dumps(cfg))

        def member(self, name, data):
            (root / ("m_" + name.replace("/", "__"))).write_bytes(data)

        def good(self, desk=None, binry=None):
            self.config()
            self.member(g.DESKTOP_ENTRY, desktop() if desk is None else desk)
            self.member(g.BINARY_ENTRY, binary(CI) if binry is None else binry)

        def reader(self, kind):
            return (kind, str(bindir / kind))

        def argv(self):
            return [json.loads(ln) for ln in (root / "argv.log").read_text().splitlines()]

    lb = Lab()
    lb.config()
    return lb


# --- names and the version rule ---------------------------------------------------------------------------

def test_image_name_follows_the_build_version_rule():
    assert g.image_name(CI) == NAME
    assert vm.build_version(UP_TAG, 1) == CI
    for bad in ("6.2.0-daily.202", "6.2.0-daily.0202", "6.2.0-daily.61616\n", "6.2.0-daily.61616/../x", "7.0.0-daily.61616"):
        with pytest.raises(v.ValidationError):
            g.image_name(bad)


# --- header ------------------------------------------------------------------------------------------------------

def test_header_of_a_good_image(tmp_path):
    h = g.read_header(write_image(tmp_path))
    assert h == {"size": OFFSET + PAYLOAD, "squashfs_offset": OFFSET, "squashfs_bytes": PAYLOAD, "compression": "zstd"}
    assert g.read_header(write_image(tmp_path, image_bytes(trailer=g.MAX_TRAILER)))["squashfs_offset"] == OFFSET


@pytest.mark.parametrize("label,data", [
    ("not elf", b"MZ" + image_bytes()[2:]),
    ("32-bit", image_bytes(head=elf_head(cls=1))),
    ("big endian", image_bytes(head=elf_head(data=2))),
    ("aarch64", image_bytes(head=elf_head(machine=183))),
    ("type 1 appimage", image_bytes(head=elf_head(ai=b"AI\x01"))),
    ("no appimage magic", image_bytes(head=elf_head(ai=b"\0\0\0"))),
    ("odd section entry size", image_bytes(head=elf_head(shentsize=40))),
    ("no sections", image_bytes(head=elf_head(shnum=0))),
    ("absurd section count", image_bytes(head=elf_head(shnum=60000))),
    ("section table beyond the file", image_bytes(head=elf_head(shoff=10 ** 9))),
    ("section table overflow", image_bytes(head=elf_head(shoff=2 ** 64 - 64))),
    ("no squashfs magic", image_bytes(sb=superblock(magic=b"sqsh"))),
    ("squashfs 3", image_bytes(sb=superblock(major=3))),
    ("unknown compression", image_bytes(sb=superblock(compression=42))),
    ("payload longer than the file", image_bytes(sb=superblock(used=PAYLOAD + 1))),
    ("tiny payload", image_bytes(sb=superblock(used=100), used=PAYLOAD)),
    ("big trailer", image_bytes(trailer=g.MAX_TRAILER + 1)),
    ("truncated", image_bytes()[:100]),
])
def test_header_rejects_malformed_images(tmp_path, label, data):
    with pytest.raises(v.ValidationError):
        g.read_header(write_image(tmp_path, data))


def test_header_size_bounds_and_symlinks(tmp_path, monkeypatch):
    p = write_image(tmp_path)
    monkeypatch.setattr(g, "MIN_BYTES", len(image_bytes()) + 1)
    with pytest.raises(v.ValidationError):
        g.read_header(p)
    monkeypatch.setattr(g, "MIN_BYTES", 1)
    monkeypatch.setattr(g, "MAX_BYTES", len(image_bytes()) - 1)
    with pytest.raises(v.ValidationError):
        g.read_header(p)
    monkeypatch.setattr(g, "MAX_BYTES", 10 ** 9)
    link = tmp_path / "link.AppImage"
    link.symlink_to(p)
    with pytest.raises(v.ValidationError):
        g.read_header(str(link))
    with pytest.raises(v.ValidationError):
        g.read_header(str(tmp_path))


# --- desktop entry and binary strings -------------------------------------------------------------------------

def test_desktop_version_parser():
    assert g.parse_desktop_version(desktop()) == CI
    for bad in (b"Name=x\nX-AppImage-Version=6.2.0-daily.61616\n",                    # no header
                b"[Desktop Entry]\nName=x\n",                                           # no key
                desktop() + b"X-AppImage-Version=" + CI.encode() + b"\n",              # twice
                desktop("6.2.0-daily.61616; rm -rf /"), desktop("v6.2.0-daily.61616"),
                b"[Desktop Entry]\nX-AppImage-Version=\n", b"x" * (g.MAX_DESKTOP_BYTES + 1)):
        with pytest.raises(v.ValidationError):
            g.parse_desktop_version(bad)


def test_binary_check_accepts_the_expected_string_and_records_lower_ones():
    assert g.check_binary(binary(CI), CI) == {"binary_version": CI, "binary_machine": "x86_64", "other_versions": []}
    assert g.check_binary(binary(CI, CI), CI)["other_versions"] == []          # the same string twice is fine
    got = g.check_binary(binary("6.2.0-daily.202", CI, "6.2.0-daily.61000"), CI)
    assert got["binary_version"] == CI and got["other_versions"] == ["6.2.0-daily.202", "6.2.0-daily.61000"]  # ordered by n


@pytest.mark.parametrize("chunks,others", [
    # '/', ':', '=', space, quotes and a 'v' are delimiters on the left; the expected literal may be tail-merged into them
    ([b"Moonlight/" + CI.encode() + b"\0"], []),
    ([b"x\0Moonlight/6.2.0-daily.100\0", CI.encode() + b"\0"], ["6.2.0-daily.100"]),
    ([b"version=" + CI.encode() + b" (x)\0", b"v6.2.0-daily.200\0"], ["6.2.0-daily.200"]),
    ([b"\"6.2.0-daily.300\"\0", CI.encode() + b"\0"], ["6.2.0-daily.300"]),
    ([CI.encode() + b".dmg\0"], []),                                          # letters after '.' end the version
])
def test_binary_check_delimiter_edge_cases_that_must_pass(chunks, others):
    assert g.check_binary(binary_raw(*chunks), CI)["other_versions"] == others


@pytest.mark.parametrize("label,chunks", [
    ("only a lower string, expected one missing", [b"6.2.0-daily.202\0"]),
    ("no string at all", []),
    ("only a higher one", [b"6.2.0-daily.61617\0"]),
    ("higher one next to the expected", [CI.encode() + b"\0", b"6.2.0-daily.61617\0"]),
    ("higher one behind a slash", [CI.encode() + b"\0", b"Moonlight/6.2.0-daily.61617\0"]),
    ("longer number is above", [CI.encode() + b"\0", b"6.2.0-daily.616161\0"]),
    ("expected glued to letters", [b"x" + CI.encode() + b"y\0"]),
    ("expected glued to digits", [b"1" + CI.encode() + b"\0", CI.encode() + b"5\0"]),
    ("expected continued by a number", [CI.encode() + b".5\0"]),
    ("too many other strings", [CI.encode() + b"\0"] + [f"6.2.0-daily.{i}\0".encode() for i in range(1, 19)]),
])
def test_binary_check_rejects(label, chunks):
    with pytest.raises(v.ValidationError):
        g.check_binary(binary_raw(*chunks), CI)


def test_binary_check_elf_rules():
    for bad in (b"MZ" + binary(CI)[2:], binary(CI, machine=183), binary(CI, cls=1), binary(CI)[:32]):
        with pytest.raises(v.ValidationError):
            g.check_binary(bad, CI)


# --- the whole gate -------------------------------------------------------------------------------------------

@pytest.mark.parametrize("kind", ["unsquashfs", "7z"])
def test_gate_passes_and_reports_what_it_checked(tmp_path, lab, kind):
    img = write_image(tmp_path)
    lab.good()
    s = g.run_gate(UP_TAG, 1, img, lab.reader(kind))
    assert s["status"] == "ok" and s["tool"] == "appimage_gate" and s["ci_version"] == CI
    assert s["image"] == {"name": NAME, "sha256": __import__("hashlib").sha256(open(img, "rb").read()).hexdigest(),
                          "size": os.path.getsize(img)}
    assert s["elf"] == {"machine": "x86_64", "appimage_type": 2, "squashfs_offset": OFFSET}
    assert s["squashfs"] == {"compression": "zstd", "bytes_used": PAYLOAD}
    assert s["embedded"] == {"desktop_version": CI, "binary_version": CI, "binary_machine": "x86_64",
                             "other_versions": []}
    assert s["reader"] == kind
    md = g.markdown(s)
    assert CI in md and "nothing executed" in md and s["image"]["sha256"] in md


def test_reader_command_lines_are_exact_and_never_use_a_shell(tmp_path, lab):
    img = write_image(tmp_path)
    lab.good()
    g.run_gate(UP_TAG, 1, img, lab.reader("unsquashfs"))
    assert lab.argv() == [["unsquashfs", "-n", "-o", str(OFFSET), "-cat", img, g.DESKTOP_ENTRY],
                          ["unsquashfs", "-n", "-o", str(OFFSET), "-cat", img, g.BINARY_ENTRY]]
    (lab.root / "argv.log").unlink()
    g.run_gate(UP_TAG, 1, img, lab.reader("7z"))
    calls = lab.argv()
    assert calls[0][:2] == ["7z", "l"] and calls[0][-2:] == ["--", img]
    assert calls[1] == ["7z", "e", "-so", "-bd", "-y", "-tsquashfs", "--", img, g.DESKTOP_ENTRY]
    assert calls[2] == ["7z", "e", "-so", "-bd", "-y", "-tsquashfs", "--", img, g.BINARY_ENTRY]


def test_seven_zip_must_open_the_squashfs_we_validated(tmp_path, lab):
    img = write_image(tmp_path)
    lab.good()
    lab.config(seven_offset=OFFSET + 1)
    with pytest.raises(v.ValidationError, match="expected offset"):
        g.run_gate(UP_TAG, 1, img, lab.reader("7z"))
    lab.config(seven_offset=OFFSET, type="Elf")
    with pytest.raises(v.ValidationError, match="expected offset"):
        g.run_gate(UP_TAG, 1, img, lab.reader("7z"))


@pytest.mark.parametrize("kind", ["unsquashfs", "7z"])
def test_gate_failures_are_fail_closed(tmp_path, lab, kind):
    img = write_image(tmp_path)
    r = lab.reader(kind)
    lab.good(desk=desktop("6.2.0-daily.61617"))
    with pytest.raises(v.ValidationError, match="desktop X-AppImage-Version"):
        g.run_gate(UP_TAG, 1, img, r)
    lab.good(binry=binary("6.2.0-daily.61617"))
    with pytest.raises(v.ValidationError, match="missing or not delimited"):
        g.run_gate(UP_TAG, 1, img, r)
    lab.good(binry=binary(CI, "6.2.0-daily.61617"))
    with pytest.raises(v.ValidationError, match="above the expected"):
        g.run_gate(UP_TAG, 1, img, r)
    lab.good(binry=binary(CI, "6.2.0-daily.202"))   # a lower string is recorded, not fatal
    assert g.run_gate(UP_TAG, 1, img, r)["embedded"]["other_versions"] == ["6.2.0-daily.202"]
    lab.good()
    (lab.root / ("m_" + g.BINARY_ENTRY.replace("/", "__"))).unlink()   # reader exits 0 with no output (7-Zip does)
    with pytest.raises(v.ValidationError, match="missing or empty"):
        g.run_gate(UP_TAG, 1, img, r)
    lab.good()
    lab.config(rc=1)
    with pytest.raises(v.ValidationError, match="reader failed"):
        g.run_gate(UP_TAG, 1, img, r)
    lab.config(rc=0)
    assert g.run_gate(UP_TAG, 1, img, r)["ci_version"] == CI


def test_gate_rejects_wrong_name_wrong_build_and_oversized_members(tmp_path, lab, monkeypatch):
    lab.good()
    r = lab.reader("unsquashfs")
    (tmp_path / "other").mkdir()
    wrong_name = write_image(tmp_path / "other", name="Moonlight-6.2.0-daily.61617-x86_64.AppImage")
    with pytest.raises(v.ValidationError, match="file name"):
        g.run_gate(UP_TAG, 1, wrong_name, r)
    ok = write_image(tmp_path)
    with pytest.raises(v.ValidationError, match="file name"):
        g.run_gate(UP_TAG, 2, ok, r)                       # N=2 expects ...61617
    for bad_n in (0, 9):
        with pytest.raises(v.ValidationError):
            g.run_gate(UP_TAG, bad_n, ok, r)
    monkeypatch.setattr(g, "MAX_BINARY_BYTES", 10)
    with pytest.raises(v.ValidationError, match="larger than allowed"):
        g.run_gate(UP_TAG, 1, ok, r)


def test_unsafe_member_or_image_names_never_reach_the_reader(tmp_path, lab):
    r = lab.reader("unsquashfs")
    img = write_image(tmp_path)
    for bad in ("usr/bin/moon light", "usr/bin/$(id)", "../etc/passwd;x", "-cat", "a\nb", ""):
        with pytest.raises(v.ValidationError):
            g.read_member(r, img, OFFSET, bad, 100)
    with pytest.raises(v.ValidationError):
        g.read_member(r, "-evil.AppImage", OFFSET, g.DESKTOP_ENTRY, 100)
    assert not (lab.root / "argv.log").exists()


def test_missing_reader_executable_is_a_validation_error(tmp_path):
    with pytest.raises(v.ValidationError):
        g.read_member(("unsquashfs", str(tmp_path / "nope")), write_image(tmp_path), OFFSET, g.DESKTOP_ENTRY, 100)


def test_find_reader_prefers_unsquashfs_and_fails_without_any(monkeypatch):
    avail = {"unsquashfs": "/x/unsquashfs", "7zz": "/x/7zz", "7z": "/x/7z"}
    monkeypatch.setattr(g.shutil, "which", lambda n: avail.get(n))
    assert g.find_reader() == ("unsquashfs", "/x/unsquashfs")
    del avail["unsquashfs"]
    assert g.find_reader() == ("7z", "/x/7zz")
    avail.clear()
    with pytest.raises(v.ValidationError):
        g.find_reader()


# --- hung and flooding readers, exact argv ------------------------------------------------------------------------

def _gone(pid, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


@pytest.mark.parametrize("kind", ["unsquashfs", "7z"])
def test_hung_reader_is_killed_at_the_deadline(tmp_path, lab, monkeypatch, kind):
    monkeypatch.setattr(g, "DEADLINE_SECONDS", 1)
    lab.config(mode="hang")
    started = time.monotonic()
    with pytest.raises(v.ValidationError, match="timed out"):
        g.read_member(lab.reader(kind), write_image(tmp_path), OFFSET, g.DESKTOP_ENTRY, 1000)
    assert time.monotonic() - started < 20
    assert _gone(int((lab.root / "pid").read_text()))


def test_hung_seven_zip_listing_is_bounded_too(tmp_path, lab, monkeypatch):
    monkeypatch.setattr(g, "DEADLINE_SECONDS", 1)
    lab.config(mode="hang_list")
    with pytest.raises(v.ValidationError, match="timed out"):
        g.check_seven_zip_layout(lab.reader("7z")[1], write_image(tmp_path), OFFSET)
    assert _gone(int((lab.root / "pid").read_text()))


@pytest.mark.parametrize("kind", ["unsquashfs", "7z"])
def test_over_cap_reader_is_killed_without_waiting_for_the_deadline(tmp_path, lab, kind):
    lab.config(mode="flood")
    started = time.monotonic()
    with pytest.raises(v.ValidationError, match="larger than allowed"):
        g.read_member(lab.reader(kind), write_image(tmp_path), OFFSET, g.BINARY_ENTRY, 4096)
    assert time.monotonic() - started < 20          # DEADLINE_SECONDS is 300
    assert _gone(int((lab.root / "pid").read_text()))


STRICT_STUB = """#!{py}
import json, os, sys
allowed = json.loads(os.environ["STRICT_ARGV"])
if sys.argv[1:] not in allowed:
    sys.stderr.write("unexpected argv: %r\\n" % (sys.argv[1:],))
    sys.exit(2)
member = sys.argv[-1]
sys.stdout.buffer.write(open(os.path.join(os.environ["STRICT_ROOT"], member.replace("/", "__")), "rb").read())
"""


def test_unsquashfs_argv_is_exactly_n_o_offset_cat_image_member(tmp_path, monkeypatch):
    """The stub accepts ONLY ``-n -o <offset> -cat <image> <member>``; the executable is found through PATH."""
    img = write_image(tmp_path)
    bindir, root = tmp_path / "strictbin", tmp_path / "strictroot"
    bindir.mkdir()
    root.mkdir()
    stub = bindir / "unsquashfs"
    stub.write_text(STRICT_STUB.format(py=sys.executable))
    stub.chmod(0o755)
    (root / g.DESKTOP_ENTRY).write_bytes(desktop())
    (root / g.BINARY_ENTRY.replace("/", "__")).write_bytes(binary(CI))
    allowed = [["-n", "-o", str(OFFSET), "-cat", img, g.DESKTOP_ENTRY],
               ["-n", "-o", str(OFFSET), "-cat", img, g.BINARY_ENTRY]]
    monkeypatch.setenv("STRICT_ARGV", json.dumps(allowed))
    monkeypatch.setenv("STRICT_ROOT", str(root))
    # the stub is not vacuous: other argument shapes fail
    for wrong in (["-n", "-o", "0", "-cat", img, g.DESKTOP_ENTRY], ["-cat", img, g.DESKTOP_ENTRY],
                  ["-n", "-offset", str(OFFSET), "-cat", img, g.DESKTOP_ENTRY], ["-n", "-o", str(OFFSET), "-cat", img]):
        assert subprocess.run([str(stub), *wrong], capture_output=True).returncode == 2
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + "/nonexistent")
    reader = g.find_reader()
    assert reader == ("unsquashfs", str(stub))
    s = g.run_gate(UP_TAG, 1, img, reader)
    assert s["reader"] == "unsquashfs" and s["ci_version"] == CI


# --- command line --------------------------------------------------------------------------------------------

def test_main_writes_summary_and_markdown(tmp_path, lab, monkeypatch, capsys):
    img = write_image(tmp_path)
    lab.good()
    monkeypatch.setenv("PATH", str(lab.bin) + os.pathsep + os.environ["PATH"])
    out, md = tmp_path / "s.json", tmp_path / "s.md"
    assert g.main(["--tag", UP_TAG, "--n", "1", "--image", img, "--out", str(out), "--markdown", str(md)]) == 0
    summary = json.loads(out.read_text())
    assert summary["reader"] == "unsquashfs" and summary["ci_version"] == CI
    assert out.read_text().endswith("\n") and "### AppImage gate passed" in md.read_text()
    assert "gate passed" in capsys.readouterr().out


def test_main_fails_without_writing_a_summary(tmp_path, lab, monkeypatch, capsys):
    img = write_image(tmp_path)
    lab.good(desk=desktop("6.2.0-daily.1"))
    monkeypatch.setenv("PATH", str(lab.bin) + os.pathsep + os.environ["PATH"])
    out = tmp_path / "s.json"
    assert g.main(["--tag", UP_TAG, "--n", "1", "--image", img, "--out", str(out)]) == 1
    assert not out.exists() and "::error::appimage_gate" in capsys.readouterr().err
    assert g.main(["--tag", "v6.2.0-daily.202; id", "--n", "1", "--image", img, "--out", str(out)]) == 1
    assert g.main(["--tag", UP_TAG, "--n", "1", "--image", str(tmp_path / "missing"), "--out", str(out)]) == 1


# --- the real upstream image (optional) ----------------------------------------------------------------------------

@pytest.mark.skipif(not os.path.isfile(REAL_APPIMAGE) or g.shutil.which("7z") is None,
                    reason="real upstream AppImage / 7-Zip not available")
def test_real_upstream_daily_202_image_with_real_seven_zip(tmp_path, monkeypatch):
    """v6.2.0-daily.202 embeds its OWN daily number (not a 6.2.0-daily.B build number): relax the 5-digit rule."""
    ci = "6.2.0-daily.202"
    link = tmp_path / f"Moonlight-{ci}-x86_64.AppImage"
    os.symlink(REAL_APPIMAGE, link)
    monkeypatch.setattr(g, "MIN_BYTES", 1024 * 1024)
    real = g.read_header(os.path.realpath(link))
    assert real["compression"] == "zstd" and real["squashfs_offset"] > 64
    monkeypatch.setattr(g, "CI_VERSION_RE", g.ANY_DAILY_RE)
    monkeypatch.setattr(g.version_map, "build_version", lambda tag, n: ci)
    monkeypatch.setattr(g, "read_header", lambda p: real)  # read_header refuses symlinks; the link only carries the name
    monkeypatch.setattr(g, "sha256_file", lambda p: "0" * 64)
    s = g.run_gate(UP_TAG, 1, str(link), ("7z", g.shutil.which("7z")))
    assert s["embedded"] == {"desktop_version": ci, "binary_version": ci, "binary_machine": "x86_64", "other_versions": []}
    # a different expected version is refused by the same real files
    monkeypatch.setattr(g.version_map, "build_version", lambda tag, n: "6.2.0-daily.203")
    other = tmp_path / "Moonlight-6.2.0-daily.203-x86_64.AppImage"
    os.symlink(REAL_APPIMAGE, other)
    with pytest.raises(v.ValidationError):
        g.run_gate(UP_TAG, 1, str(other), ("7z", g.shutil.which("7z")))
