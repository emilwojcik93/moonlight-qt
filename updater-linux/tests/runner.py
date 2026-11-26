"""Subprocess helper for tests: runs the updater with in-memory Deps taken from a JSON file.
usage: python -I runner.py <config.json>
config: lib (dir that contains moonlight_posture_update), home, port, gh, proc, kill (point or null), probe (bool)"""
import json
import os
import signal
import sys
import time

cfg = json.load(open(sys.argv[1]))
sys.path.insert(0, cfg["lib"])
from moonlight_posture_update import store as store_mod  # noqa: E402
from moonlight_posture_update.net import HttpSettings  # noqa: E402
from moonlight_posture_update.paths import Paths  # noqa: E402
from moonlight_posture_update.updater import Deps, Updater  # noqa: E402

probe = {}
if cfg.get("probe"):
    def can_write(path):
        try:
            with open(path, "w") as f:
                f.write("x")
            os.unlink(path)
            return True
        except OSError:
            return False
    h = cfg["home"]
    probe = {"tmp_writable": can_write("/tmp/mlpu-probe-%d" % os.getpid()),
             "lib_writable": can_write(os.path.join(h, ".local/lib/moonlight-posture-updater/probe")),
             "bin_writable": can_write(os.path.join(h, ".local/bin/probe")),
             "state_writable": can_write(os.path.join(h, ".local/state/moonlight-posture-updater/probe"))}

kill = cfg.get("kill")


def die(*a, **k):
    os.kill(os.getpid(), signal.SIGKILL)


if kill == "before_commit":
    store_mod.Store.commit = die
elif kill == "before_switch":
    store_mod.Store.switch = die
elif kill == "after_switch":
    store_mod.Store.prune = die

base = "http://127.0.0.1:%d" % cfg["port"]
http = HttpSettings(api_base=base, download_base=base + "/dl", allowed_hosts=frozenset({"127.0.0.1"}), require_https=False,
                    use_env_proxy=False, api_timeout=10, small_timeout=10, big_timeout=20, socket_timeout=5)
deps = Deps(paths=Paths(cfg["home"]), http=http, gh_path=cfg["gh"], now=time.time, proc_root=cfg["proc"],
            display=lambda: {"WAYLAND_DISPLAY": "wayland-test"}, run_id=cfg.get("run_id", "runner-%d" % os.getpid()))
res = Updater(deps).run("update")
print(json.dumps({"result": res.result, "exit": res.exit_code, "detail": res.detail, "probe": probe}))
