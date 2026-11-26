"""Tag regex, ordering, cooling-off, running client, policy hold, ETag cache."""
import json
import os

import pytest

import fixtures
from fixtures import Release
from moonlight_posture_update import versioning

pytestmark = pytest.mark.skipif(__import__("platform").machine() != "x86_64", reason="x86-64 fixture ELF")

GOOD = "v6.2.0-daily.203-vp.1"


@pytest.mark.parametrize("tag", [
    GOOD, "v6.2.0-daily.1-vp.1", "v6.2.0-daily.99999-vp.999",
])
def test_regex_accepts_canonical(tag):
    assert versioning.is_tag(tag)


@pytest.mark.parametrize("tag", [
    "v6.2.0-daily.203-vp.1\n",                 # trailing newline ($ would accept it)
    "\nv6.2.0-daily.203-vp.1",
    "v6.2.0-daily.0203-vp.1",                  # leading zero alias
    "v6.2.0-daily.203-vp.01",
    "v6.2.0-daily.0-vp.1",
    "v6.2.0-daily.203-vp.0",
    "v6.2.0-daily.203-vp.1 ",
    "v6.2.0-daily.２０３-vp.1",                  # fullwidth digits
    "v6.2.0-daily.٢٠٣-vp.1",                   # arabic-indic digits
    "v6.2.0-daily.203-vp.1/../../x",
    "../v6.2.0-daily.203-vp.1",
    "v6.2.0-daily.203-vp.1;id",
    "v6.2.0-daily.203-vp.$(id)",
    "v6.2.0-daily.203-vp.1`id`",
    "v6.2.0-daily.203-vp.1‮",             # bidi override
    "V6.2.0-daily.203-vp.1",
    "v6.2.0-daily.203-vp.1" + "9" * 400,
    "v6.2.0-daily." + "1" * 200 + "-vp.1",
    "v6.2.0-daily.100000-vp.1",
    "", None, 5, ["v6.2.0-daily.203-vp.1"],
])
def test_regex_rejects_abuse(tag):
    assert not versioning.is_tag(tag)


@pytest.mark.parametrize("tag", ["v6.2.0-daily.203-vp.9", "v6.2.0-daily.692-vp.1", "v6.2.0-daily.99999-vp.1"])
def test_not_installable_ranges(tag):
    assert versioning.is_tag(tag)
    with pytest.raises(ValueError):
        versioning.parse_tag(tag)


def test_build_number_scheme():
    assert versioning.parse_tag("v6.2.0-daily.202-vp.1").build == 61616
    assert versioning.parse_tag("v6.2.0-daily.202-vp.2").build == 61617
    assert versioning.parse_tag("v6.2.0-daily.691-vp.8").build == 65535
    assert versioning.tag_for_build(61616) == "v6.2.0-daily.202-vp.1"
    assert versioning.tag_for_build(59999) is None


def test_abusive_tags_in_the_feed_are_never_downloaded(env):
    good = Release(203)
    evil = []
    for t in ["v6.2.0-daily.204-vp.1\n", "v6.2.0-daily.0205-vp.1", "../../../etc/passwd", "v6.2.0-daily.２０６-vp.1",
              "v6.2.0-daily.207-vp.9", "v6.2.0-daily.700-vp.1", "v6.2.0-daily.208-vp.1" + "9" * 300]:
        e = good.api_entry(); e["tag_name"] = t
        evil.append(e)
    env.fake.add(good)
    env.fake.raw_api = evil + [good.api_entry()]
    res = env.run()
    assert res.result == "updated" and res.tag == good.tag
    assert not any(x in p for p in env.fake.requests if "/dl/" in p for x in ("etc", "0205", "%0A", "%EF%BC%92"))


def test_garbage_release_list(env):
    env.fake.raw_api = {"message": "not a list"}
    assert env.run().result == "verify_failed"
    env.updater().clear_deny(None)
    os.unlink(os.path.join(env.paths.cache_dir, "releases.json")) if os.path.exists(os.path.join(env.paths.cache_dir, "releases.json")) else None
    env.fake.raw_api = [1, None, "x", {"tag_name": 5}, {"tag_name": GOOD}]
    assert env.run().result == "noop"


def test_older_and_equal_builds_are_not_installed(env):
    env.fake.add(Release(203))
    env.fake.add(Release(202))
    assert env.run().result == "updated"
    # same release again, plus an older one: noop
    res = env.run()
    assert res.result == "noop" and "not newer" in res.detail
    # only older ones left in the feed
    env.fake.releases.clear()
    env.fake.add(Release(202)); env.fake.add(Release(201))
    assert env.run().result == "noop"
    assert env.current() == GOOD
    # N bump of the same U counts as newer
    env.fake.add(Release(203, 2))
    assert env.run().result == "updated" and env.current() == "v6.2.0-daily.203-vp.2"


def test_state_cannot_force_a_downgrade(env):
    env.fake.add(Release(203))
    assert env.run().result == "updated"
    s = env.state(); s["installed"] = None
    json.dump(s, open(env.paths.state_file, "w"))
    env.fake.releases.clear(); env.fake.add(Release(202))
    assert env.run().result == "noop" and env.current() == GOOD     # symlink still counts


def test_cooling_off_not_elapsed(env):
    env.fake.add(Release(203, hours_old=1.0))
    res = env.run()
    assert res.result == "noop" and "cooling-off" in res.detail
    assert env.current() is None and not any("/dl/" in p for p in env.fake.requests)


def test_cooling_off_floor_and_policy(env):
    env.fake.add(Release(203, hours_old=1.0))
    env.set_policy(cooling_off_hours=0)                   # floor of 2 h still applies
    assert env.run().result == "noop"
    env.set_policy(cooling_off_hours=0, min_cooling_off_hours=0)
    assert env.run().result == "updated"


def test_stable_channel_waits_24h(env):
    env.fake.add(Release(203, hours_old=20))
    env.set_policy(channel="stable")
    assert env.run().result == "noop"
    env.fake.releases.clear(); env.fake.add(Release(203, hours_old=25))
    assert env.run().result == "updated"


def test_older_eligible_release_chosen_when_newest_is_too_young(env):
    env.fake.add(Release(204, hours_old=0.5))
    env.fake.add(Release(203, hours_old=30))
    res = env.run()
    assert res.result == "updated" and res.tag == GOOD


def test_clock_skew_uses_server_time(env):
    env.fake.add(Release(203, hours_old=10))
    env.clock_offset = -30 * 86400          # local clock a month behind: release would look "from the future"
    res = env.run()
    assert res.result == "updated"
    assert "clock_skew" in open(env.paths.log_file).read()


def test_running_client_defers_before_any_network(env):
    env.fake.add(Release(203))
    env.fake_client()
    res = env.run()
    assert res.result == "deferred" and res.exit_code == 0 and "running" in res.detail
    assert env.fake.requests == [] and env.current() is None


@pytest.mark.parametrize("comm", ["moonlight", "Moonlight.AppIma"])
def test_client_detection_variants(env, comm):
    env.fake_client(comm=comm)
    assert env.run().result == "deferred"


def test_non_client_process_is_ignored(env):
    env.fake_client(comm="moonlight-posture-update")        # us / a lookalike script, not the client
    d = os.path.join(env.proc, "4242"); open(os.path.join(d, "cmdline"), "wb").write(b"/usr/bin/python3\0x\0")
    env.fake.add(Release(203))
    assert env.run().result == "updated"


def test_client_started_between_download_and_install_defers(env, monkeypatch):
    from moonlight_posture_update import updater as up
    env.fake.add(Release(203))
    real = up.procs.find_clients
    calls = {"n": 0}

    def fake(*a, **k):
        calls["n"] += 1
        return [(1234, "moonlight")] if calls["n"] >= 3 else real(*a, **k)       # third check = right before the switch
    monkeypatch.setattr(up.procs, "find_clients", fake)
    res = env.run()
    assert res.result == "deferred" and calls["n"] == 3
    assert env.current() is None
    assert os.listdir(env.paths.opt_dir) == []          # staging dir removed, nothing committed


def test_policy_hold_stops_everything(env):
    env.fake.add(Release(203))
    env.set_policy(hold=True)
    res = env.run()
    assert res.result == "held" and res.exit_code == 0
    assert env.fake.requests == [] and env.current() is None


def test_hold_command_roundtrip(env):
    env.fake.add(Release(203))
    assert env.updater().set_hold(True).result == "held"
    assert env.run().result == "held"
    env.updater().set_hold(False)
    assert env.run().result == "updated"


def test_policy_deny_and_floor(env):
    env.fake.add(Release(203)); env.fake.add(Release(204))
    env.set_policy(deny=["v6.2.0-daily.204-vp.1"])
    assert env.run().tag == GOOD
    env.fake.add(Release(205))
    env.set_policy(min_build=versioning.parse_tag("v6.2.0-daily.206-vp.1").build)
    res = env.run()
    assert res.result == "noop" and "floor" in res.detail


def test_etag_conditional_request_and_304_path(env):
    env.fake.add(Release(203, hours_old=1))        # stays in cooling-off: cheap noops
    assert env.run().result == "noop"
    assert env.fake.conditional_hits == 0
    assert env.run().result == "noop"
    assert env.fake.conditional_hits == 1
    assert "source=\"cache-304\"" in env.out.getvalue()
    # a changed list is fetched again and re-cached
    env.fake.add(Release(204, hours_old=1))
    assert env.run().result == "noop"
    assert env.fake.conditional_hits == 1
    assert env.run().result == "noop" and env.fake.conditional_hits == 2


def test_304_without_cache_defers(env):
    env.fake.add(Release(203, hours_old=1))
    env.fake.always_304 = True            # a server answering 304 although we sent no validator
    res = env.run()
    assert res.result == "deferred" and res.exit_code == 8


def test_corrupt_release_cache_is_ignored(env):
    env.fake.add(Release(203, hours_old=1))
    env.run()
    open(os.path.join(env.paths.cache_dir, "releases.json"), "w").write("{broken")
    assert env.run().result == "noop"
