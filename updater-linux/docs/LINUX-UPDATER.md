# Linux updater: design, trust chain, operations

Scope: consumer side of the Linux AppImage in the patched Moonlight feed (`linux-client-feed` change, decisions L1 to L6).
Binding inputs: `CONTRACT.md` v1.1 (3b) plus the Linux amendment (v1.2: `manifest.linux`), `ml-UPDATER.md` (Windows updater), `ml-CI.md` section 6.
The producer side (workflow, gate, `manifest.linux`) is written separately; this code is written to the documented contract and to test fixtures.
No release with an AppImage exists yet: against the real feed the updater currently reports `noop` ("has no AppImage").

## 1. Flow

```
timer (daily ~04:17 + Persistent + 10 min after user manager start)  ->  moonlight-posture-update update
  flock(state/lock)                                                        exit 7 when another run is active
  policy.json (strict, defaults baked in)                                  exit 3 when invalid
  state.json (validated; corrupt -> moved aside, rebuilt)
  hold -> stop                                                             result held
  idle check 1: a Moonlight client is running -> stop                      result deferred (exit 0), retried by the next trigger
  GET /repos/<repo>/releases?per_page=30   anonymous, If-None-Match, 60 s timeout, 4 MB cap, rate-limit aware
  filter: strict tag regex, draft == false, immutable == true, valid published_at, N <= 8 and B <= 65535; newest (U, N) first
  per candidate: not denied -> B >= min_build -> API lists an AppImage asset -> B > installed -> age >= cooling-off -> not in backoff
  download manifest.json + SHA256SUMS            (caps 256 KB / 64 KB; size and API digest checked)
  manifest checks (section 3), SHA256SUMS parse, then download the bundle named in the manifest (cap 1 MB)
  gh attestation trusted-root                    (the ONLY network step of the attestation chain)
  gh attestation verify manifest.json            (no --source-digest; the certificate digest must equal manifest.build.source_sha)
  gh attestation verify SHA256SUMS               (--source-digest = authenticated source_sha)
  ONLY THEN download the AppImage (size == manifest == API, cap policy.max_appimage_mb)
  format gate (ELF64 x86-64, AppImage type-2 magic "AI\x02" at offset 8, size bounds)
  gh attestation verify AppImage                 (same flags)
  SHA-256(file) == SHA256SUMS == manifest.linux.sha256 == API digest      (verify-only stops here)
  idle check 2 -> stage copy into ~/.local/opt/moonlight-posture/.stage-<run>/ (hash while copying == verified hash)
  smoke test of the staged file -> idle check 3 -> rename to <tag>/ -> launcher + desktop entry -> `current` symlink switch (atomic)
  smoke test again through `current`: failure -> `current` goes back to the previous version, bad directory removed (exit 5)
  state.json (installed, previous), prune everything except current + previous
```

## 2. Version scheme

Same as the Windows updater (CONTRACT 3b): `B = 60000 + 8*U + (N-1)`, N in 1..8, B <= 65535. Tag regex (matched with `fullmatch`, ASCII digits, canonical, <= 40 characters):
`v6\.2\.0-daily\.([1-9][0-9]{0,4})-vp\.([1-9][0-9]{0,2})`. Ordering is numeric on B. The AppImage is `Moonlight-6.2.0-daily.<B>-x86_64.AppImage`
(regex `Moonlight-6\.2\.0-daily\.[0-9]{5}-x86_64\.AppImage`); the number in the name must equal B of the tag and `manifest.build.version`.
The installed build is `max(state.installed.build, build derived from the `current` symlink target)`: a damaged or deleted `state.json` can never cause a downgrade.

## 3. Trust chain and what is checked where

| Check | Where | Failure |
|---|---|---|
| repo and upstream owner on the baked-in allow-list | `policy.py` (`ALLOWED_REPOS`, `ALLOWED_UPSTREAM_OWNERS`); the local file can only narrow them | exit 3 |
| tag regex, not draft, **immutable == true** (strictly: absent or false is refused), N <= 8, B <= 65535 | `release.filter_releases` | release ignored |
| deny list (policy + local state), `min_build`, B > installed, cooling-off from `published_at`, backoff | `updater._run` | next candidate / noop |
| `manifest.json`: schema 1, product `moonlight`, `tag` == release tag, `build.version` == `6.2.0-daily.<B(tag)>`, `build.source_ref` == `refs/heads/build/v6.2.0-daily.<U>-n<N>` (derived, not trusted), `build.source_sha` 40 hex, `upstream.owner` allow-listed, `attestation[]` names, `linux.installer` regex + equals the name derived from the tag, `linux.sha256`, `linux.size` <= cap; duplicate JSON keys, NaN and wrong types rejected | `release.parse_manifest` | verify_failed, exit 4 |
| SHA256SUMS strict lines, no duplicates; its `manifest.json` entry equals the downloaded manifest | `release.parse_sums` | exit 4 |
| attestation of manifest.json, SHA256SUMS and the AppImage: offline `--bundle`, `--repo`, `--signer-workflow <repo>/.github/workflows/patched-windows-release.yml`, `--source-ref` (derived from the tag), `--source-digest` (from the attested manifest; not for the manifest itself), `--deny-self-hosted-runners`, `--predicate-type https://slsa.dev/provenance/v1`, `--cert-oidc-issuer https://token.actions.githubusercontent.com`, `--custom-trusted-root`, `--format json` | `attest.Attestor.verify` | exit 4 |
| defense in depth: the JSON that `gh` prints must itself contain a certificate with the expected repo URI, ref, digest, issuer, `github-hosted` runner, a signer SAN starting with `https://github.com/<signer>@`, and a statement whose subjects contain the file's SHA-256. An exit code 0 alone is not trusted. | `attest._recheck` | exit 4 |
| SHA-256 of the file == SHA256SUMS == manifest == API `digest`; size == manifest == API | `release.check_hashes` | exit 4 |
| the copy that is installed hashes to the verified value (hashed while copying) | `store.stage` | exit 5 |

Transport: no `Authorization` header is ever sent; HTTPS only; redirects are followed manually and every hop must be on `github.com`,
`api.github.com`, `objects.githubusercontent.com` or `release-assets.githubusercontent.com` (no userinfo, port 443); download URLs are built from the validated repo, tag and
asset name; byte caps, `Content-Length` and truncation checks, a 600 s deadline for the AppImage.

`gh` is taken from `/usr/bin/gh` or `/usr/local/bin/gh` only (no `PATH` lookup), and only if it is root-owned and not group/world-writable. It runs without a shell, in its own session
(a timeout kills the process group), with every `GH_*`/`GITHUB_*` variable removed and private `GH_CONFIG_DIR`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` under the state directory, so no stored login or keyring token is ever used.
Its stdout is parsed but never logged.

### Experiment: `gh attestation verify --bundle` without a login (answered empirically)

Setup: `gh 2.105.0`, `env -u GH_TOKEN -u GITHUB_TOKEN`, throw-away `HOME`/`GH_CONFIG_DIR`/`XDG_CACHE_HOME` (`gh auth status`: "not logged into any GitHub hosts"),
real public release `v6.2.0-daily.202-vp.1` (immutable, bundle `attestation.sigstore.json`, subjects `MoonlightSetup.exe`, `SHA256SUMS`, `manifest.json`), the exact flags of section 3.

| case | result |
|---|---|
| online (TUF fetched implicitly), `MoonlightSetup.exe`, `manifest.json`, `SHA256SUMS` | **rc 0 without any login or token** (about 6 s on a cold cache); TUF cache created under `$XDG_CACHE_HOME/gh/.sigstore` |
| `gh attestation trusted-root` | rc 0, no login needed (34 KB, 2 root documents: GitHub and Sigstore public good) |
| verify with `--custom-trusted-root <that file>` and `HTTPS_PROXY` pointing at a dead port (no network at all) | **rc 0** for all three subjects: verification is fully offline once the root file exists |
| verify **without** `--custom-trusted-root`, dead proxy, cold cache **and warm cache** | rc 1, "error creating Sigstore verifier": gh refreshes the TUF metadata on every run, a warm cache does not help |
| tampered file, wrong signer workflow, wrong `--source-ref`, wrong `--source-digest`, wrong `--repo`, corrupted bundle, missing bundle | all rc 1 |

Design consequence: the updater fetches the trusted root explicitly (one network step, TUF-verified by gh, stored in the private run directory) and verifies every subject with
`--custom-trusted-root`. A failure to fetch the root is a transient deferral (exit 8, nothing denied); a verification failure with a loaded root is exit 4. The root is never cached across runs
(a stale root could miss a key revocation); it costs one request per run that actually has a candidate. Unlike the Windows updater the `gh` binary is not pinned by hash
(distribution package under a root-owned path instead); an unknown flag or an incompatible `gh` fails closed.
`tests/test_real_gh.py` repeats this against the real release (`MLPU_NETWORK_TESTS=1`).

## 4. Policy (`~/.config/moonlight-posture-updater/policy.json`)

Optional. Missing file = defaults. The file must be a regular file owned by you, not group/world-writable, not a symlink, <= 64 KB, strict JSON without duplicate keys;
an unknown key, a wrong type or an out-of-range value makes the whole file invalid and the run exits 3 without doing anything.

| key | default | meaning |
|---|---|---|
| `repo` | `emilwojcik93/moonlight-qt` | must be one of the baked-in repositories (the list can only be widened by editing the code) |
| `upstream_owners` | `["Nonary"]` | subset of the baked-in owners; `manifest.upstream.owner` must be in it |
| `channel` | `canary` | `canary` adds no cooling-off, `stable` adds 24 h (CONTRACT section 5). Channels do not look at the pre-release flag (every feed release is a pre-release) |
| `cooling_off_hours` | `2` | effective cooling-off = max(`min_cooling_off_hours`, `cooling_off_hours`, channel value) |
| `min_cooling_off_hours` | `2` | local floor; lower it only deliberately (`0` = install as soon as the release is published) |
| `min_build` | `0` | never install a build below this number |
| `hold` | `false` | no installs (verify-only still works) |
| `deny` | `[]` | canonical tags that must never be installed |
| `smoke_test` | `display` | `display`: run the AppImage with `--version` (needs a display, otherwise the run is deferred); `static`: only the AppImage runtime runs (`--appimage-version`, `--appimage-extract usr/bin/moonlight`), the extracted binary must be an ELF that embeds the expected version |
| `max_appimage_mb` | `250` | download and manifest size cap |

There is no test mode: endpoints, paths and executables are constants of the code; the test suite substitutes them in memory.
The Windows updater additionally reads `policy.yml` from the `automation` branch (deny list, `hold`). That is **not** implemented here (open question O2).

## 5. Files

| Path | Content |
|---|---|
| `~/.local/lib/moonlight-posture-updater/moonlight_posture_update/` | the code (copied by `install.sh`) |
| `~/.local/bin/moonlight-posture-update` | entry point (`python3 -I`) |
| `~/.config/systemd/user/moonlight-posture-update.{service,timer}` | units |
| `~/.config/moonlight-posture-updater/policy.json` | optional policy |
| `~/.local/state/moonlight-posture-updater/` (0700) | `state.json`, `log` (rotates at 1 MB), `lock`, `cache/releases.json` (ETag + body), `runs/<id>/` (newest 3; the AppImage copy is always deleted), `gh/` |
| `~/.local/opt/moonlight-posture/<tag>/Moonlight.AppImage` (0755) + `INSTALL.json` | installed versions (current + previous only); `current` is a relative symlink to `<tag>` |
| `~/.local/bin/moonlight-posture`, `~/.local/share/applications/moonlight-posture.desktop` | launcher (FUSE if usable, else `--appimage-extract-and-run`; `MOONLIGHT_POSTURE_NO_FUSE=1` forces extraction) and desktop entry, rewritten on every install |

Log lines: `<utc> LEVEL run=<id> event=<name> key="value" ...` to stdout (the journal) and to the log file. Values are scrubbed (control characters, tokens, PEM markers) and truncated.

## 6. Failure handling

* Never replace a running client: three idle checks (start, before staging, immediately before the rename and switch) read `/proc` for a process called `moonlight`, `Moonlight.AppImage*`, `moonlight-qt`, an executable with that name, or anything run from `~/.local/opt/moonlight-posture`. A hit defers the run (exit 0).
* Atomicity: the AppImage is staged in `.stage-<run>/` on the same file system, renamed to `<tag>/`, and `current` is switched with `symlink` + `rename`; `current` never dangles and never disappears. A crash leaves at most a `.stage-*` or `.trash-*` directory that the next run removes after an hour.
* Backoff and deny (as on Windows): network/disk problems never deny and back off 15 min doubling to 6 h; verification failures back off the same way and deny the tag after 3; install failures (smoke test) back off from 1 h and deny after 2. `clear-deny` forgets them.
* Disk full: staging or download fails with ENOSPC, the partial file and stage directory are removed, the old version stays current, the failure counts as transient.
* Time: if the local clock differs from the GitHub `Date` header by more than 5 minutes the server time is used for the cooling-off check.

## 7. Operations

```sh
moonlight-posture-update status                       # JSON: current, previous, deny, attempts, policy, held, client_running, gh path
journalctl --user -u moonlight-posture-update -n 50   # structured log lines; also ~/.local/state/moonlight-posture-updater/log
systemctl --user list-timers moonlight-posture-update.timer
moonlight-posture-update verify-only                  # rehearse the full chain; add --tag <tag> to check one release (ignores cooling-off and installed version)
moonlight-posture-update hold / unhold
moonlight-posture-update rollback                     # previous -> current (re-hashed against INSTALL.json); the old current is added to the local deny list
```

Rollback refuses while a client runs, when no previous version exists, or when the previous AppImage no longer matches its recorded hash (exit 6, nothing changed).
After a rollback the next release newer than the denied one installs normally; `clear-deny <tag>` re-allows the denied one.

First enable, suggested: `install.sh`, `verify-only` once the producer has published a release with an AppImage, `hold` off, then enable the timer.
For a headless or lingering-only session set `"smoke_test": "static"`, otherwise runs without a display are deferred.

## 8. Troubleshooting

| Symptom | Cause / action |
|---|---|
| `MLPU_RESULT=noop ... has no AppImage` | the feed has no release with `manifest.linux` yet (producer v1.2 pending) |
| `deferred ... Moonlight is running` | close the client; the next trigger retries (or run `update` by hand) |
| `deferred ... no display available` | no `WAYLAND_DISPLAY`/`DISPLAY` and no `wayland-N` socket in `$XDG_RUNTIME_DIR`: log into the desktop session, or set `smoke_test` to `static` |
| exit 8, `rate limit` | anonymous API limit (60/h); conditional requests make steady state free; wait |
| exit 8, `could not fetch the Sigstore trusted root` | no route to the TUF repositories; retried later |
| exit 4, `attestation verification failed` | the release was not built by the pinned workflow/ref/commit, or the bundle does not cover the file. Nothing was installed; the run directory (`runs/`, bundle + manifest, no AppImage) is kept for inspection |
| exit 3 | `policy.json` invalid (the message names the key), or `HOME` unusable |
| exit 4, `gh not found at a trusted location` | install `github-cli` via pacman (root-owned `/usr/bin/gh`) |
| `state_corrupt` in the log | `state.json` was invalid and moved to `state.json.corrupt-<ts>`; the installed build is taken from the `current` symlink |

## 9. Differences to the Windows updater

| | Windows | Linux |
|---|---|---|
| execution context | SYSTEM scheduled task, admin-only ACLs, self ACL check | user systemd timer, no privileges; files 0700/0600, ownership checks on policy/state; the user account is the trust boundary (a compromise of it is out of scope, as for the client's own config) |
| policy | local `config.json` + `policy.yml` from branch `automation` (deny, hold, owners) | local `policy.json` only (open question O2) |
| mode | `report-only` default until gate G4 | no report-only; `hold` and `verify-only` instead; install is gated by enabling the timer |
| installed version | FileVersion of `Moonlight.exe` | `current` symlink + `INSTALL.json` + `state.json` (max of both) |
| `gh` | pinned by hash and Authenticode signature, copied into the program dir | distribution `gh` from a root-owned path; trusted root fetched explicitly each run; not hash-pinned |
| install | Burn installer, health check on registry presence, Windows Installer idle handling | file copy + atomic rename + symlink, smoke test before and after the switch; no registry/identity access of any kind |
| rollback | re-run of the previous bundle, failure counters | symlink back to the kept previous version, re-hash; denied tag |
| pre-release flag | ignored | ignored |
| immutable flag | required | required (strictly) |
| baseline | mandatory rollback baseline before updating | none needed: the previous version stays installed until the new one is switched in; first install has no rollback target |

## 10. Not verified / open questions

* **O1** No release with `manifest.linux` and an AppImage exists. The shape of `manifest.linux`, the asset name, the contents of `SHA256SUMS` for the AppImage, and the attestation subject set are taken from the amendment text and fixtures. The smoke test expects `Moonlight <build.version>` on a line of `--version` output (verified on upstream `6.2.0-daily.202`: `Moonlight 6.2.0-daily.202`; whether the patched build embeds `6.2.0-daily.<B>` is assumed from the design: "embedded version string equals `ci_version`").
* **O2** Remote kill switch: Windows honours `hold`/`deny` in `policy.yml` on the `automation` branch; Linux only has the local file. It could be added the same way (branches API for the commit sha, contents API pinned to it).
* **O3** `--version` needs a display (Qt creates the GUI application before parsing the options). `static` mode covers headless hosts but cannot prove the binary starts.
* **O4** The systemd hardening is verified with `systemd-analyze --user verify` and `security --offline` (exposure 4.5), not by running the unit under a real user manager on this machine.
* **O5** Minimum `gh` version is not enforced; an old `gh` without `--source-digest`/`--custom-trusted-root` fails closed with rc != 0.
* **O6** FUSE branch of the launcher is not exercised against a real AppImage here (only the extraction branch and a stub).
