# Moonlight patch updater (Linux)

User-level updater for the patched Moonlight AppImage published by `emilwojcik93/moonlight-qt`
(tags `v6.2.0-daily.U-vp.N`, immutable GitHub releases). It is the Linux counterpart of the Windows updater
(`updater/`, branch `automation-updater`): same release contract, same verification chain, same fail-closed rules.

* Python 3.9+ standard library only, plus the `gh` CLI (package `github-cli`) for Sigstore attestation verification.
* Starts in **report-only** (`mode` in `policy.json`): the timer only logs "would install <tag>" until you run `verify-only` and then `set-mode install`.
* No root, no sudo. Everything lives under `~/.local/...` and `~/.config/systemd/user/`.
* It never reads, writes or moves `~/.config/Moonlight Game Streaming Project/` (settings and paired identity). The smoke test runs the
  new AppImage with a throw-away `HOME`/`XDG_*`.

## Install

```sh
./install.sh                 # into $HOME; writes files and units, enables nothing
./install.sh --prefix /tmp/x # into another prefix (only [A-Za-z0-9._/-] allowed); tests, dry rehearsal
systemctl --user daemon-reload && systemctl --user enable --now moonlight-posture-update.timer   # when you decide
```

Back out: `./uninstall.sh` (keeps the installed client, state and policy) or `./uninstall.sh --purge`.

## Use

```sh
moonlight-posture-update status          # JSON, no network
moonlight-posture-update verify-only     # whole download + verification chain, installs nothing
moonlight-posture-update verify-only --tag v6.2.0-daily.203-vp.1
moonlight-posture-update update          # what the timer runs
moonlight-posture-update set-mode install     # leave report-only (the state after install.sh) once verify-only looked good
moonlight-posture-update rollback        # back to the previous verified version; denies the one rolled back from (state.json AND policy.json)
moonlight-posture-update hold            # no installs until `unhold` (sets hold=true in the local policy)
moonlight-posture-update clear-deny [tag]
moonlight-posture                        # the launcher: runs ~/.local/opt/moonlight-posture/current/Moonlight.AppImage
```

The last stdout line of a run is `MLPU_RESULT=<updated|noop|deferred|held|verified|verify_failed|rolled_back|failed> MLPU_TAG=<tag> MLPU_DETAIL=<text>`.
Exit codes: 0 ok (also noop, deferred, held) | 1 internal | 3 config/policy invalid | 4 verification failed | 5 install failed (previous version kept)
| 6 rollback failed or impossible | 7 another instance running | 8 network / rate-limit / policy-fetch deferral.

## Layout

```
moonlight_posture_update/   the package (stdlib only)
bin/moonlight-posture-update   entry point (python -I); installed into the lib dir, ~/.local/bin only gets symlinks
systemd/                     moonlight-posture-update.service (hardened oneshot) and .timer (daily ~04:17, Persistent, OnStartupSec=10min)
install.sh, uninstall.sh
tests/                       pytest suite (offline: fake GitHub on loopback, gh shim, hand-assembled ELF stand-in for the AppImage)
docs/LINUX-UPDATER.md        design, trust chain, policy, operations, troubleshooting, differences to the Windows updater
```

## Tests

```sh
python3 -m venv venv && venv/bin/pip install pytest
venv/bin/pytest -q                                   # offline, ~1 min, x86-64 only (the AppImage stand-in is an x86-64 ELF)
MLPU_NETWORK_TESTS=1 venv/bin/pytest -q tests/test_real_gh.py   # real gh + real public release, anonymous
```

Nothing in the suite installs or enables a service, uses the real home directory, or compiles anything.
