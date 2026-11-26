"""Command line: moonlight-posture-update [update|verify-only|status|rollback|hold|unhold|clear-deny]."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import List, Optional

from . import __version__
from .errors import ConfigError, EXIT_CONFIG, EXIT_INTERNAL
from .paths import Paths
from .updater import Deps, Updater


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="moonlight-posture-update",
                                 description="Verified updater for the patched Moonlight AppImage feed.")
    ap.add_argument("--version", action="version", version="moonlight-posture-update " + __version__)
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("update", help="check, verify, install (default)")
    v = sub.add_parser("verify-only", help="run the whole download + verification chain, install nothing")
    v.add_argument("--tag", help="verify exactly this release (ignores cooling-off and installed version)")
    sub.add_parser("status", help="print JSON status (no network)")
    sub.add_parser("rollback", help="switch back to the previous verified version and deny the one rolled back from")
    sub.add_parser("hold", help="set hold=true in the local policy (no installs)")
    sub.add_parser("unhold", help="set hold=false in the local policy")
    c = sub.add_parser("clear-deny", help="remove local deny entries / failure counters")
    c.add_argument("tag", nargs="?", help="only this tag (default: all local entries)")
    return ap


def main(argv: Optional[List[str]] = None, deps: Optional[Deps] = None) -> int:
    args = build_parser().parse_args(argv)
    cmd = args.cmd or "update"
    if deps is None:
        home = os.path.expanduser("~")
        if not home or home == "~" or not os.path.isabs(home) or not os.path.isdir(home):
            print("MLPU_RESULT=failed MLPU_TAG=- MLPU_DETAIL=no usable HOME", file=sys.stderr)
            return EXIT_CONFIG
        os.umask(0o077)
        deps = Deps(paths=Paths(home))
    up = Updater(deps)
    try:
        if cmd == "status":
            json.dump(up.status(), sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        if cmd == "rollback":
            return up.rollback().exit_code
        if cmd in ("hold", "unhold"):
            return up.set_hold(cmd == "hold").exit_code
        if cmd == "clear-deny":
            return up.clear_deny(args.tag).exit_code
        if cmd == "verify-only":
            return up.run("verify-only", args.tag).exit_code
        return up.run("update").exit_code
    except ConfigError as e:
        print("MLPU_RESULT=failed MLPU_TAG=- MLPU_DETAIL=%s" % str(e)[:200], file=sys.stderr)
        return e.exit_code
    except Exception as e:  # noqa: BLE001
        print("MLPU_RESULT=failed MLPU_TAG=- MLPU_DETAIL=internal error %s" % type(e).__name__, file=sys.stderr)
        return EXIT_INTERNAL
