import hashlib
import json

import pytest

import lock_update as lu
import plan_build as pb
import series as sr
import vpcommon as v

UP = "v6.2.0-daily."
TAG = UP + "202"
C1 = "a" * 40
C2 = "b" * 40
S1 = "1" * 64
S2 = "2" * 64
TS = "2026-11-22T07:17:53Z"
BR = "build/v6.2.0-daily.202-n1"


def mklock(tag=TAG, commit=C1, builds=()):
    lock = lu.empty()
    lock["entries"][tag] = {"commit": commit, "release_id": 454272425, "published_at": TS, "first_seen": TS,
                            "builds": list(builds)}
    return lock


def build(n, sha=S1, tag=TAG):
    return {"n": n, "series_sha256": sha, "branch": f"build/{tag}-n{n}", "source_sha": C2}


def rel(tag, draft=False):
    return {"tag_name": tag, "draft": draft}


def plan(lock, **kw):
    base = dict(tag=TAG, commit=C1, lock=lock, our_releases=[], runs=[], series_sha=S1)
    base.update(kw)
    return pb.plan(**base)


def run(attempt, conclusion="failure", status="completed", rid=77, branch=BR):
    return {"headBranch": branch, "status": status, "conclusion": conclusion, "databaseId": rid, "attempt": attempt}


# --- lock ---------------------------------------------------------------------------

def test_lock_record_new_then_same(tmp_path):
    p = tmp_path / "upstream-seen.json"
    lock = lu.load(str(p))  # absent file
    assert lock["upstream"] == "Nonary/moonlight-qt"
    assert lu.record(lock, TAG, C1, 200, TS, TS) == "new"
    lu.save(lock, str(p))
    lock2 = lu.load(str(p))
    assert lu.record(lock2, TAG, C1, 200, TS, TS) == "same"
    assert p.read_text().endswith("\n") and json.loads(p.read_text())["schema"] == 1


def test_repository_state_file_is_valid_and_preseeded():
    import os
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    lock = lu.load(os.path.join(root, "upstream-seen.json"))
    assert lock["entries"][UP + "202"]["commit"] == "9184cacd8d426316bdecc47634f0dbf4e6e34654"
    assert lock["entries"][UP + "201"]["commit"] == "bbe6d2d368bc156317882edc21b9671af02bcf97"


def test_lock_moved_tag_halts():
    lock = mklock()
    with pytest.raises(lu.TagMoved):
        lu.check(lock, TAG, C2)
    with pytest.raises(lu.TagMoved):
        lu.record(lock, TAG, C2, 200, TS, TS)


def test_lock_cli_exit_codes(tmp_path):
    p = str(tmp_path / "l")
    args = ["record", "--lock", p, "--tag", TAG, "--commit", C1, "--release-id", "5",
            "--published-at", TS, "--now", TS]
    assert lu.main(args) == 0
    assert lu.main(args) == 0
    moved = ["check", "--lock", p, "--tag", TAG, "--commit", C2]
    assert lu.main(moved) == lu.EXIT_MOVED
    assert lu.main(["add-build", "--lock", p, "--tag", TAG, "--n", "1", "--series-sha", S1,
                    "--source-sha", C2]) == 0
    assert lu.main(["add-build", "--lock", p, "--tag", TAG, "--n", "1", "--series-sha", S1,
                    "--source-sha", C2]) == 1  # duplicate n
    assert lu.main(["add-build", "--lock", p, "--tag", TAG, "--n", "9", "--series-sha", S1,
                    "--source-sha", C2]) == 1  # beyond the CONTRACT 3b limit


def test_lock_validation_rejects_garbage(tmp_path):
    p = tmp_path / "l"
    for bad in ('{"schema": 2}', '{"schema":1,"upstream":"a/b","entries":{"$(id)":{}}}',
                '{"schema":1,"upstream":"a/b","entries":{"v6.2.0-daily.202":{"commit":"x","release_id":1}}}',
                '{"schema":1,"upstream":"a/b","entries":{"2.20.0":{"commit":"' + C1 + '","release_id":1}}}'):
        p.write_text(bad)
        with pytest.raises(v.ValidationError):
            lu.load(str(p))


def test_last_built_before():
    lock = lu.empty()
    for t, builds in ((UP + "200", [1]), (UP + "201", []), (UP + "202", [1])):
        lu.record(lock, t, C1, 1, TS, TS)
        for n in builds:
            lu.add_build(lock, t, n, S1, "b" * 40)
    assert lu.last_built_before(lock, UP + "202") == UP + "200"  # 201 was seen but never built
    assert lu.last_built_before(lock, UP + "200") == ""
    assert lu.last_built_before(lock, UP + "203") == UP + "202"


# --- reference pin (Patch Engineer's upstream.lock) --------------------------------------------

def test_reference_pin_reads_the_flat_moonlight_lock(tmp_path):
    p = tmp_path / "upstream.lock"
    p.write_text("# c\nowner: Nonary\nrepo: moonlight-qt\ntag: " + TAG + "\ncommit: " + C1 +
                 "   # x\nrelease_id: 454272425\npatch_series_sha256: " + S1 + "\n")
    assert lu.reference_pin(str(p)) == (TAG, C1)
    assert lu.reference_pin(str(tmp_path / "missing")) is None
    p.write_text("tag: $(id)\ncommit: " + C1 + "\n")
    with pytest.raises(v.ValidationError):
        lu.reference_pin(str(p))


def test_reference_pin_reads_the_real_file():
    import os
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    assert lu.reference_pin(os.path.join(root, "upstream.lock")) == (TAG, "9184cacd8d426316bdecc47634f0dbf4e6e34654")


def test_reference_pin_nested_layout_still_accepted(tmp_path):
    p = tmp_path / "upstream.lock"
    p.write_text("upstream:\n  repository: Nonary/moonlight-qt\n  tag: " + TAG + "\n  commit: " + C1 + "\npatch_series:\n  count: 7\n")
    assert lu.reference_pin(str(p)) == (TAG, C1)


def test_plan_halts_when_tag_moved_vs_reference_pin():
    assert plan(lu.empty(), commit=C2, pin=(TAG, C1))["action"] == "halt"
    assert plan(lu.empty(), commit=C1, pin=(TAG, C1))["action"] == "build"
    assert plan(lu.empty(), commit=C2, pin=(UP + "201", C1))["action"] == "build"  # pin belongs to another tag


def test_series_fingerprint_definition_matches_patch_engineer(tmp_path):
    """sha256( series with CR removed || raw bytes of each patch in order ), see tools/series-sha.sh."""
    d = tmp_path / "p"
    d.mkdir()
    a = b"AAA\r\nBBB\n"
    (d / "0001-a.patch").write_bytes(a)
    (d / "0002-b.patch").write_bytes(b"CCC")
    series = b"# c\r\n# group: posture-core\r\n0001-a.patch\r\n\n# group: touch-menu\n0002-b.patch  # t\n"
    (d / "series").write_bytes(series)
    expect = hashlib.sha256(series.replace(b"\r", b"") + a + b"CCC").hexdigest()
    info = sr.fingerprint(str(d / "series"), str(d))
    assert info["series_sha256"] == expect and info["groups"] == ["posture-core", "touch-menu"]


def test_real_series_fingerprint_equals_patch_engineer_value():
    import os
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    info = sr.fingerprint(os.path.join(root, "patches", "series"), os.path.join(root, "patches"))
    pin = {}
    with open(os.path.join(root, "upstream.lock"), encoding="utf-8") as fh:
        for ln in fh:
            if ln.startswith("patch_series_sha256:"):
                pin = ln.split(":", 1)[1].strip()
    assert info["count"] == 7 and info["groups"] == ["posture-core", "touch-menu"]
    assert info["series_sha256"] == pin


# --- plan ---------------------------------------------------------------------------

def test_plan_first_sight_builds_n1():
    r = plan(lu.empty())
    assert (r["action"], r["n"], r["record_lock"]) == ("build", 1, True)


def test_plan_hold_and_override():
    assert plan(lu.empty(), hold=True)["action"] == "hold"
    assert plan(lu.empty(), hold=True, override_hold=True)["action"] == "build"


def test_plan_moved_tag_halts_even_when_built():
    lock = mklock(builds=[build(1)])
    r = plan(lock, commit=C2, our_releases=[rel(TAG + "-vp.1")])
    assert r["action"] == "halt"
    assert plan(lock, commit=C2, hold=True)["action"] == "hold"  # hold wins, still no build


def test_plan_already_built_is_noop():
    lock = mklock(builds=[build(1)])
    r = plan(lock, our_releases=[rel(TAG + "-vp.1")])
    assert (r["action"], r["n"]) == ("noop", 1)
    assert "already built" in r["reason"]


def test_plan_draft_release_does_not_count_as_built():
    lock = mklock(builds=[build(1)])
    r = plan(lock, our_releases=[rel(TAG + "-vp.1", draft=True)], runs=[run(1, rid=77)])
    assert (r["action"], r["rerun_run_id"]) == ("rerun", 77)


def test_plan_in_flight_noop():
    lock = mklock(builds=[build(1)])
    assert plan(lock, runs=[run(1, status="in_progress", conclusion="")])["reason"] == "build in flight"


def test_plan_branch_recorded_but_no_run_is_stuck():
    r = plan(mklock(builds=[build(1)]))
    assert r["action"] == "noop" and r["stuck"] is True


def test_plan_runs_of_other_branches_ignored():
    lock = mklock(builds=[build(1)])
    runs = [run(1, status="in_progress", conclusion="", branch="build/v6.2.0-daily.201-n1")]
    assert plan(lock, runs=runs)["stuck"] is True


def test_plan_series_change_bumps_n():
    lock = mklock(builds=[build(1, S1), build(2, S1)])
    r = plan(lock, series_sha=S2, our_releases=[rel(TAG + "-vp.1"), rel(TAG + "-vp.2")])
    assert (r["action"], r["n"]) == ("build", 3)


def test_plan_force_rebuild_bumps_n_even_if_same_series():
    lock = mklock(builds=[build(1)])
    r = plan(lock, force_rebuild=True, our_releases=[rel(TAG + "-vp.1")])
    assert (r["action"], r["n"]) == ("build", 2)


def test_plan_n_counts_published_releases_beyond_lock():
    lock = mklock(builds=[build(1, S1)])
    r = plan(lock, series_sha=S2, our_releases=[rel(TAG + "-vp.1"), rel(TAG + "-vp.7")])
    assert (r["action"], r["n"]) == ("build", 8)


def test_plan_counter_exhausted_beyond_8_is_stuck_never_a_build():
    """CONTRACT 3b: N > 8 must fail; the pipeline alerts (stuck) and never creates build/...-n9."""
    lock = mklock(builds=[build(8, S1)])
    r = plan(lock, series_sha=S2, our_releases=[rel(TAG + "-vp.8")])
    assert r["action"] == "noop" and r["stuck"] is True and "max 8" in r["reason"]
    r = plan(lock, series_sha=S1, force_rebuild=True, our_releases=[rel(TAG + "-vp.8")])
    assert r["action"] == "noop" and r["stuck"] is True
    # a release published out of band at n=9 does not open the door either
    r = plan(mklock(builds=[build(1)]), series_sha=S2, our_releases=[rel(TAG + "-vp.1"), rel(TAG + "-vp.9")])
    assert r["action"] == "noop" and r["stuck"] is True


def test_plan_release_without_lock_entry_is_an_alert_not_a_silent_noop():
    r = plan(lu.empty(), our_releases=[rel(TAG + "-vp.1")])
    assert r["action"] == "noop" and r["stuck"] is True and r["record_lock"] is True


def test_plan_older_than_newest_seen_is_skipped_unless_manual():
    lock = mklock(tag=UP + "203")
    assert plan(lock, tag=TAG)["action"] == "noop"
    assert plan(lock, tag=TAG, manual_tag=True)["action"] == "build"


def test_first_run_builds_only_the_newest_and_never_backfills():
    r = plan(lu.empty())
    assert (r["action"], r["n"]) == ("build", 1)
    lock = lu.empty()
    lu.record(lock, UP + "202", C1, 11, TS, TS)
    older = pb.plan(tag=UP + "201", commit=C2, lock=lock, our_releases=[], runs=[], series_sha=S1)
    assert older["action"] == "noop"


def test_plan_ignores_other_tags_releases():
    r = plan(lu.empty(), our_releases=[rel(UP + "201-vp.3"), rel(TAG + "-vp.1x"), rel(UP + "2020-vp.1")])
    assert r["action"] == "build" and r["n"] == 1


# --- retry budget: `gh run rerun` keeps the run id and only bumps `attempt` ------------------------------

def lock_with_build():
    return mklock(builds=[build(1)])


def test_rerun_budget_uses_attempt_field_and_stops():
    assert plan(lock_with_build(), runs=[run(1)])["action"] == "rerun"
    assert plan(lock_with_build(), runs=[run(2)])["action"] == "rerun"
    r3 = plan(lock_with_build(), runs=[run(3)])
    assert r3["action"] == "noop" and r3["stuck"] is True and r3["rerun_run_id"] == 0
    assert plan(lock_with_build(), runs=[run(9)])["stuck"] is True  # never an unbounded loop


def test_rerun_budget_counts_all_runs_of_the_branch():
    assert plan(lock_with_build(), runs=[run(1, rid=5), run(2, rid=6)])["stuck"] is True


def test_successful_or_cancelled_run_without_release_is_stuck_not_rerun():
    for conclusion in ("success", "cancelled", "skipped"):
        r = plan(lock_with_build(), runs=[run(1, conclusion=conclusion)])
        assert r["action"] == "noop" and r["stuck"] is True, conclusion


def test_missing_attempt_field_counts_as_one():
    r = plan(lock_with_build(), runs=[{"headBranch": BR, "status": "completed", "conclusion": "failure",
                                       "databaseId": 3}])
    assert r["action"] == "rerun"


def reason_cases():
    lock = lock_with_build()
    return [plan(lock), plan(lock, runs=[run(3)]), plan(lock, runs=[run(1, conclusion="success")]),
            plan(lock, runs=[run(1)]), plan(lock, runs=[run(1, status="in_progress", conclusion="")]),
            pb.plan(tag=TAG, commit=C2, lock=lock, our_releases=[], runs=[], series_sha=S1),
            plan(lu.empty(), our_releases=[rel(TAG + "-vp.1")]),
            plan(lu.empty(), hold=True),
            plan(mklock(builds=[build(8)]), series_sha=S2)]


def test_every_reason_is_a_valid_output_value(tmp_path):
    for res in reason_cases():
        v.write_outputs({"reason": pb._clean(res["reason"])}, str(tmp_path / "o"))


@pytest.mark.parametrize("runs_payload", [[], [run(3)], [run(1, conclusion="success")]])
def test_cli_stuck_paths_do_not_crash(tmp_path, monkeypatch, runs_payload):
    out = tmp_path / "gho"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    lock = tmp_path / "lock.json"
    lock.write_text(lu.dumps(lock_with_build()))
    rel_json = tmp_path / "rel.json"
    rel_json.write_text("[]")
    runs = tmp_path / "runs.json"
    runs.write_text(json.dumps(runs_payload))
    rc = pb.main(["--tag", TAG, "--commit", C1, "--lock", str(lock), "--our-releases", str(rel_json),
                  "--runs", str(runs), "--series-sha", S1, "--github-output"])
    assert rc == 0
    text = out.read_text()
    assert "stuck=true\n" in text and "action=noop\n" in text


def test_cli_exhausted_counter_does_not_crash(tmp_path, monkeypatch):
    out = tmp_path / "gho"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    lock = tmp_path / "lock.json"
    lock.write_text(lu.dumps(mklock(builds=[build(8, S1)])))
    (tmp_path / "e.json").write_text("[]")
    rc = pb.main(["--tag", TAG, "--commit", C1, "--lock", str(lock), "--our-releases", str(tmp_path / "e.json"),
                  "--runs", str(tmp_path / "e.json"), "--series-sha", S2, "--github-output"])
    assert rc == 0 and "stuck=true\n" in out.read_text()


def test_cli_write_failure_is_a_clean_error_not_a_traceback(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(pb, "_clean", lambda t, limit=200: "bad;value")
    lock = tmp_path / "lock.json"
    lock.write_text(lu.dumps(lock_with_build()))
    (tmp_path / "e.json").write_text("[]")
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "gho"))
    rc = pb.main(["--tag", TAG, "--commit", C1, "--lock", str(lock), "--our-releases", str(tmp_path / "e.json"),
                  "--runs", str(tmp_path / "e.json"), "--series-sha", S1, "--github-output"])
    assert rc == 1 and "::error::" in capsys.readouterr().err


def test_plan_cli_first_sight(tmp_path, monkeypatch):
    out = tmp_path / "o"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    (tmp_path / "l").write_text("")
    (tmp_path / "r.json").write_text("[]")
    rc = pb.main(["--tag", TAG, "--commit", C1, "--lock", str(tmp_path / "l"),
                  "--our-releases", str(tmp_path / "r.json"), "--runs", str(tmp_path / "r.json"),
                  "--series-sha", S1, "--github-output"])
    assert rc == 0
    assert "action=build\n" in out.read_text() and "n=1\n" in out.read_text()
