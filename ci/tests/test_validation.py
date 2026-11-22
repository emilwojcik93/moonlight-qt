import json
import os

import pytest

import policy
import select_release as sr
import validate_tag
import vpcommon as v

HERE = os.path.dirname(os.path.abspath(__file__))
UP = "v6.2.0-daily."

MALICIOUS = [
    "$(id)", "`id`", UP + "202\n", UP + "202\n" + UP + "203", "../" + UP + "202", "../../etc/passwd",
    UP + "202;rm -rf /", UP + "202 && curl x", UP + "202|id", UP + "202\r\n",
    UP + "٢٠٢", UP + "２０２", UP + "202‮",
    UP + "123456", UP + "0", UP + "0202", UP + "-1", "v6.2.0-daily.", "v6.2.0", "v6.1.0-vrr18",
    "v6.3.0-daily.202", "V6.2.0-DAILY.202", "6.2.0-daily.202", "", " " + UP + "202", UP + "202 ",
    UP + "202\x00", "${{ github.token }}", UP + "202'", UP + '202"', UP + "202#", UP + "202%0a",
    UP + "202-vp.1",
]


@pytest.mark.parametrize("tag", [UP + "1", UP + "202", UP + "691", UP + "99999"])
def test_upstream_tag_accepts(tag):
    assert v.upstream_tag(tag) == tag


@pytest.mark.parametrize("tag", MALICIOUS)
def test_upstream_tag_rejects(tag):
    with pytest.raises(v.ValidationError):
        v.upstream_tag(tag)


@pytest.mark.parametrize("tag", [UP + "202-vp.1", UP + "1-vp.999", UP + "691-vp.8"])
def test_release_tag_accepts(tag):
    assert v.release_tag(tag) == tag


@pytest.mark.parametrize("tag", [t for t in MALICIOUS if not t.endswith("-vp.1")] + [
    UP + "202-vp.", UP + "202-vp.1000", UP + "202-vp.1\n", UP + "202-posture.1", UP + "202-VP.1",
    UP + "202-vp.-1", UP + "202-vp.0", UP + "202-vp.01", UP + "0202-vp.1"])
def test_release_tag_rejects_bad(tag):
    with pytest.raises(v.ValidationError):
        v.release_tag(tag)


def test_release_tag_regex_equals_the_contract_regex():
    """CONTRACT section 1: ^v6\\.2\\.0-daily\\.[0-9]{1,5}-vp\\.[0-9]{1,3}$ (ours is the canonical subset)."""
    import re
    contract = re.compile(r"v6\.2\.0-daily\.[0-9]{1,5}-vp\.[0-9]{1,3}")
    for tag in (UP + "202-vp.1", UP + "99999-vp.999", UP + "1-vp.8"):
        assert contract.fullmatch(tag) and v.RELEASE_TAG_RE.fullmatch(tag)


def test_non_string_rejected():
    for bad in (None, 5, b"v6.2.0-daily.202", [UP + "202"]):
        with pytest.raises(v.ValidationError):
            v.upstream_tag(bad)


def test_error_message_does_not_echo_payload():
    try:
        v.upstream_tag("$(curl evil)\n::set-output name=x::y")
    except v.ValidationError as exc:
        msg = str(exc)
        assert "\n" not in msg
        assert "::set-output" not in msg and "curl" not in msg


def test_ordering_key():
    assert v.release_tag_key(UP + "202") == (202, 0)
    assert v.release_tag_key(UP + "202-vp.1") == (202, 1)
    keys = [v.release_tag_key(t) for t in (UP + "202", UP + "202-vp.1", UP + "202-vp.2", UP + "203-vp.1", UP + "300")]
    assert keys == sorted(keys)
    assert v.release_tag_key(UP + "202-vp.10") > v.release_tag_key(UP + "202-vp.9")  # numeric, not lexical
    assert v.release_tag_key(UP + "1000") > v.release_tag_key(UP + "999-vp.8")


def test_branch_names():
    assert v.branch_name(UP + "202", 3) == "build/v6.2.0-daily.202-n3"
    assert v.parse_branch("build/v6.2.0-daily.202-n3") == (UP + "202", 3)
    for bad in ("build/v6.2.0-daily.202-n", "build/../x-n1", "build/v6.2.0-daily.202-n1\n", "feature/x",
                "build/v6.2.0-daily.202-n1/extra", "build/v6.2.0-daily.202-n01", "build/v6.2.0-daily.202-n0"):
        assert v.parse_branch(bad) is None
    with pytest.raises(v.ValidationError):
        v.branch_name(UP + "202", 0)
    with pytest.raises(v.ValidationError):
        v.branch_name(UP + "202", 9)  # CONTRACT 3b: N <= 8


def test_write_outputs_blocks_injection(tmp_path):
    out = tmp_path / "o"
    v.write_outputs({"tag": UP + "202", "ref": "refs/heads/build/v6.2.0-daily.202-n1"}, str(out))
    assert out.read_text() == "tag=v6.2.0-daily.202\nref=refs/heads/build/v6.2.0-daily.202-n1\n"
    for bad in ("x\ny=z", "a;b", "$(id)", "`id`", "a\rb", "x" * 301):
        with pytest.raises(v.ValidationError):
            v.write_outputs({"k": bad}, str(out))
    with pytest.raises(v.ValidationError):
        v.write_outputs({"Bad Key": "x"}, str(out))
    with pytest.raises(v.ValidationError):
        v.write_outputs({"k\nj": "x"}, str(out))


def test_validate_tag_cli(capsys):
    assert validate_tag.main(["upstream-tag", UP + "202"]) == 0
    assert validate_tag.main(["upstream-tag", "$(id)"]) == 1
    err = capsys.readouterr().err
    assert "::error::" in err and "$(id)" not in err
    assert validate_tag.main(["nope", "x"]) == 2
    assert validate_tag.main(["release-tag", UP + "202-vp.3"]) == 0
    assert validate_tag.main(["build-branch", "build/v6.2.0-daily.202-n1"]) == 0
    assert validate_tag.main(["sha1", "a" * 40]) == 0
    assert validate_tag.main(["sha1", "A" * 40]) == 1
    assert validate_tag.main(["run-id", "123456789"]) == 0
    assert validate_tag.main(["run-id", "12a"]) == 1
    assert validate_tag.main(["repo-slug", "emilwojcik93/moonlight-qt"]) == 0
    assert validate_tag.main(["repo-slug", "a/b/c"]) == 1


# --- release selection -------------------------------------------------------------

def load_fixture():
    with open(os.path.join(HERE, "fixtures", "releases.json"), encoding="utf-8") as fh:
        return json.load(fh)


def test_select_picks_newest_daily_published():
    res = sr.select(load_fixture(), slug="Nonary/moonlight-qt", allow=["Nonary"])
    # drafts, unpublished, unmappable (U > 691) and every junk tag are skipped; prerelease flag ignored
    assert res["selected"]["tag"] == UP + "202"
    tags = [c["tag"] for c in sr.numeric_candidates(load_fixture())]
    assert tags == [UP + "202", UP + "201", UP + "200"]


def test_select_skips_every_malicious_tag():
    for c in sr.numeric_candidates(load_fixture()):
        assert v.UPSTREAM_TAG_RE.fullmatch(c["tag"])
    tags = {c["tag"] for c in sr.numeric_candidates(load_fixture())}
    assert UP + "203" not in tags  # draft
    assert UP + "204" not in tags  # unpublished
    assert UP + "692" not in tags  # B would exceed 65535
    assert "v6.1.0-vrr18" not in tags and UP + "202-vp.1" not in tags


def test_select_floor_and_explicit_tag():
    rels = load_fixture()
    res = sr.select(rels, slug="Nonary/moonlight-qt", allow=["Nonary"], top=5, floor=UP + "201")
    assert [c["tag"] for c in res["candidates"]] == [UP + "202", UP + "201"]
    # an explicit tag ignores the floor (manual override) and must still be a valid published release
    res = sr.select(rels, slug="Nonary/moonlight-qt", allow=["Nonary"], tag=UP + "200", floor=UP + "201")
    assert res["selected"]["release_id"] == 200
    assert sr.select(rels, slug="Nonary/moonlight-qt", allow=["Nonary"], tag=UP + "203")["selected"] is None
    with pytest.raises(v.ValidationError):
        sr.select(rels, slug="Nonary/moonlight-qt", allow=["Nonary"], tag="$(id)")


def test_select_owner_allowlist():
    with pytest.raises(v.ValidationError):
        sr.select(load_fixture(), slug="evil/moonlight-qt", allow=["Nonary"])
    with pytest.raises(v.ValidationError):
        sr.select(load_fixture(), slug="Nonary/moonlight-qt", allow=["Nonary;x"])
    with pytest.raises(v.ValidationError):
        sr.select(load_fixture(), slug="Nonary/moonlight-qt/extra", allow=["Nonary"])


def test_select_is_numeric_not_lexical():
    rels = [{"id": i + 1, "tag_name": t, "draft": False, "published_at": "2026-01-01T00:00:00Z"}
            for i, t in enumerate([UP + "99", UP + "100", UP + "20"])]
    assert sr.select(rels, slug="Nonary/moonlight-qt", allow=["Nonary"])["selected"]["tag"] == UP + "100"


def test_select_rejects_garbage_payload():
    with pytest.raises(v.ValidationError):
        sr.numeric_candidates({"message": "Not Found"})
    assert sr.numeric_candidates([1, "x", None, {"tag_name": 5}]) == []
    bad_id = [{"id": "5", "tag_name": UP + "202", "draft": False, "published_at": "2026-01-01T00:00:00Z"},
              {"id": True, "tag_name": UP + "203", "draft": False, "published_at": "2026-01-01T00:00:00Z"}]
    assert sr.numeric_candidates(bad_id) == []


def test_unbuildable_newest_tag_is_skipped_not_wedging():
    rels = [{"draft": False, "published_at": "2026-11-22T07:17:53Z", "tag_name": t, "id": i + 1}
            for i, t in enumerate([UP + "202", UP + "692", UP + "99999", UP + "65535"])]
    res = sr.select(rels, slug="Nonary/moonlight-qt", allow=["Nonary"])
    assert res["selected"]["tag"] == UP + "202"


def test_previous_of():
    cands = sr.numeric_candidates(load_fixture())
    assert sr.previous_of(cands, UP + "202") == UP + "201"
    assert sr.previous_of(cands, UP + "200") is None


def test_select_cli(tmp_path, monkeypatch):
    out = tmp_path / "gho"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    rc = sr.main(["--releases", os.path.join(HERE, "fixtures", "releases.json"), "--repo", "Nonary/moonlight-qt",
                  "--allow", "Nonary,Other", "--tag", UP + "201", "--github-output"])
    assert rc == 0
    text = out.read_text()
    assert "tag=v6.2.0-daily.201\n" in text and "release_id=201\n" in text and "prev_tag=v6.2.0-daily.200\n" in text
    assert sr.main(["--releases", "nonexistent.json", "--repo", "Nonary/moonlight-qt", "--allow", "Nonary"]) == 1
    assert sr.main(["--releases", os.path.join(HERE, "fixtures", "releases.json"), "--repo", "Nonary/moonlight-qt",
                    "--allow", "Nonary", "--floor", "x; id"]) == 1


# --- policy -------------------------------------------------------------------------

POLICY = """\
schema: 1
allow_upstream_owners: [Nonary]
cooling_off_hours: {stable: 24, canary: 0}
hold: false
deny: []          # list of tags that must never install
keep_releases: 10
x-supported_floor_tag: v6.2.0-daily.201
"""


def test_policy_parses_contract_file_and_the_real_one():
    p = policy.parse(POLICY)
    assert p["allow_upstream_owners"] == ["Nonary"] and p["hold"] is False
    assert p["cooling_off_hours"] == {"stable": 24, "canary": 0} and p["keep_releases"] == 10
    assert p["x-supported_floor_tag"] == UP + "201"
    real = os.path.join(os.path.dirname(os.path.dirname(HERE)), "policy.yml")
    assert policy.load(real)["allow_upstream_owners"] == ["Nonary"]


def test_policy_deny_and_hold():
    p = policy.parse(POLICY.replace("deny: []", "deny: [v6.2.0-daily.202-vp.1, v6.2.0-daily.202-vp.2]")
                     .replace("hold: false", "hold: true"))
    assert p["deny"] == [UP + "202-vp.1", UP + "202-vp.2"] and p["hold"] is True


@pytest.mark.parametrize("mutate", [
    lambda s: s.replace("schema: 1", "schema: 2"),
    lambda s: s.replace("[Nonary]", "[]"),
    lambda s: s.replace("[Nonary]", "[No nary;x]"),
    lambda s: s.replace("hold: false", "hold: maybe"),
    lambda s: s + "  nested: x\n",
    lambda s: s + "garbage line\n",
    lambda s: s.replace("deny: []", "deny: [$(id)]"),
    lambda s: s.replace("deny: []", "deny: [v6.2.0-daily.202]"),  # must be a release tag
    lambda s: s.replace("v6.2.0-daily.201", "v6.2.0"),             # bad floor
    lambda s: s + "Bad-Key: 1\n",
])
def test_policy_fails_closed(mutate):
    with pytest.raises(v.ValidationError):
        policy.parse(mutate(POLICY))
