import pytest

import deref_commit as dc
import version_map as vm
import vpcommon as v

UP = "v6.2.0-daily."


# --- version mapper (CONTRACT 3b) -------------------------------------------------------

def test_contract_examples():
    assert vm.build_number(UP + "202", 1) == 61616 == 60000 + 8 * 202 + 0
    assert vm.build_version(UP + "202", 1) == "6.2.0-daily.61616"
    assert vm.file_version(UP + "202", 1) == "6.2.61616.0"
    assert vm.upstream_file_version(UP + "202") == "6.2.202.0"
    c = vm.compute(UP + "202", 3)
    assert c["release_tag"] == "v6.2.0-daily.202-vp.3" and c["branch"] == "build/v6.2.0-daily.202-n3"
    assert c["build_version"] == "6.2.0-daily.61618" and c["file_version"] == "6.2.61618.0"


def test_formula_is_exactly_60000_plus_8u_plus_n_minus_1():
    for u in (1, 2, 201, 202, 203, 500, 691):
        for n in range(1, 9):
            assert vm.build_number(UP + str(u), n) == 60000 + 8 * u + (n - 1)


def test_strictly_monotonic_in_u_then_n_and_unique():
    seen = []
    for u in range(1, 692):
        for n in range(1, 9):
            seen.append(vm.build_number(UP + str(u), n))
    assert seen == sorted(seen) and len(set(seen)) == len(seen)
    assert seen[-1] == 65535 and seen[0] == 60008
    # next daily always above any rebuild of the previous one (the MSI would otherwise refuse the upgrade)
    assert vm.build_number(UP + "203", 1) > vm.build_number(UP + "202", 8)


def test_always_above_upstream_and_legacy_builds():
    for u in (1, 202, 691):
        for n in (1, 8):
            exp = vm.version_tuple(vm.file_version(UP + str(u), n))
            assert exp > vm.version_tuple(vm.upstream_file_version(UP + str(u)))
            assert exp > vm.version_tuple("6.2.60006.0")  # legacy hand-built fork client (60002..60006)


def test_inverse_mapping():
    for u in (1, 202, 691):
        for n in range(1, 9):
            assert vm.from_build_number(vm.build_number(UP + str(u), n)) == (u, n)
    for bad in (59999, 60007, 65536, True, "61616", None):
        with pytest.raises(v.ValidationError):
            vm.from_build_number(bad)


@pytest.mark.parametrize("n", [0, -1, 9, 87, 1000, True, "1", None, 1.0])
def test_n_beyond_8_fails_the_build(n):
    with pytest.raises(v.ValidationError):
        vm.build_number(UP + "202", n)
    with pytest.raises(v.ValidationError):
        vm.compute(UP + "202", n)


def test_u_limits():
    assert vm.compute(UP + "691", 8)["build_number"] == "65535"
    for tag in (UP + "692", UP + "99999"):
        with pytest.raises(v.ValidationError):
            vm.compute(tag, 1)
    with pytest.raises(v.ValidationError):
        vm.compute("$(id)", 1)


def test_check_window_is_the_release_gate():
    vm.check_window("6.2.61616.0", UP + "202", 1)
    vm.check_window("6.2.61616", UP + "202", 1)  # 3-part form compares equal (MSI semantics)
    for bad in ("6.2.202.0",          # upstream's own version: a plain upstream build would replace ours
                "6.2.61617.0",        # next rebuild
                "6.2.60006.0",        # legacy hand-built
                "6.2.61616.1", "7.2.61616.0", "6.2", "6.2.61616.0.0", "a.b.c", "6.2.61616\n"):
        with pytest.raises(v.ValidationError):
            vm.check_window(bad, UP + "202", 1)


def test_version_tuple():
    assert vm.version_tuple("6.2.61616") == (6, 2, 61616, 0)
    assert vm.version_tuple("6.2.61616.0") == (6, 2, 61616, 0)
    for bad in ("6.2", "6.2.1.2.3", "a.b.c", "6.2.-1", "6.2.1\n", "6.2.123456"):
        with pytest.raises(v.ValidationError):
            vm.version_tuple(bad)


def test_version_cli(capsys):
    assert vm.main(["--tag", UP + "202", "--n", "2"]) == 0
    out = capsys.readouterr().out
    assert "build_version=6.2.0-daily.61617" in out and "file_version=6.2.61617.0" in out
    assert vm.main(["--tag", "bad", "--n", "1"]) == 1
    assert vm.main(["--tag", UP + "202", "--n", "9"]) == 1


# --- deref ---------------------------------------------------------------------------

C1 = "a" * 40
T1 = "b" * 40
T2 = "c" * 40
TAG = UP + "202"


def fake_fetch(table):
    def fetch(path):
        return table[path]
    return fetch


def test_deref_lightweight():
    f = fake_fetch({f"git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}", "object": {"type": "commit", "sha": C1}}})
    assert dc.deref(f, TAG) == C1


def test_deref_annotated_and_nested():
    f = fake_fetch({
        f"git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}", "object": {"type": "tag", "sha": T1}},
        f"git/tags/{T1}": {"object": {"type": "tag", "sha": T2}},
        f"git/tags/{T2}": {"object": {"type": "commit", "sha": C1}},
    })
    assert dc.deref(f, TAG) == C1


def test_deref_rejects_wrong_ref_and_types():
    wrong = fake_fetch({f"git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}-rc1", "object": {"type": "commit", "sha": C1}}})
    with pytest.raises(v.ValidationError):
        dc.deref(wrong, TAG)
    tree = fake_fetch({f"git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}", "object": {"type": "tree", "sha": C1}}})
    with pytest.raises(v.ValidationError):
        dc.deref(tree, TAG)
    badsha = fake_fetch({f"git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}", "object": {"type": "commit", "sha": "zz"}}})
    with pytest.raises(v.ValidationError):
        dc.deref(badsha, TAG)
    with pytest.raises(v.ValidationError):
        dc.deref(wrong, "$(id)")
    garbage = fake_fetch({f"git/ref/tags/{TAG}": [{"ref": "x"}]})
    with pytest.raises(v.ValidationError):
        dc.deref(garbage, TAG)


def test_deref_loop_is_bounded():
    table = {f"git/ref/tags/{TAG}": {"ref": f"refs/tags/{TAG}", "object": {"type": "tag", "sha": T1}},
             f"git/tags/{T1}": {"object": {"type": "tag", "sha": T1}}}
    with pytest.raises(v.ValidationError):
        dc.deref(fake_fetch(table), TAG)
