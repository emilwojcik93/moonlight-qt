# Moonlight patch updater: design, operation, enablement

Scope: Windows Client Engineer deliverable (PLAN tasks T-4.3 .. T-4.5) for the patched Moonlight feed. Binding inputs:
CONTRACT.md (release feed v1 + v1.1 section 3b), research/02 (client), research/04 (security). Gate G4 = you switch the task to install mode.

## 1. What it does

```
trigger (logon | daily 04:17 | every 6 h)  ->  SYSTEM  ->  powershell.exe update.ps1
  bootstrap ACL check of update.ps1 + lib\ (inline, before any lib code runs)          exit 2 on violation
  config.json (strict whitelist, unknown key = invalid) -> data-dir ACL check -> named mutex      exit 3 / 2 / 7
  mode: hold -> stop.   leftovers: reboot pending / presence check owed / rollback postponed
  installed version: FileVersion 6.2.B of Moonlight.exe  ->  B = 60000 + 8*U + (N-1)  ->  (U,N)
  idle check 1 (install mode): Moonlight.exe running -> deferred (exit 0)
  policy.yml from branch `automation`: branches API -> commit sha -> contents API ?ref=<sha>    fail closed (exit 3)
  releases API (anonymous, ETag, rate-limit aware; GitHub server time guards the clock) -> canonical tag regex -> newest first
  per candidate: not denied (policy + local) -> B > installed B -> age >= max(floor 2 h, local, policy) -> not in backoff
  report-only -> log "would install <tag>" and stop (no download)
  release must be immutable (API flag); ROLLBACK BASELINE must exist (else refuse, exit 3)
  download manifest.json + SHA256SUMS + bundle(s) -> manifest checks -> attest manifest + SHA256SUMS (offline)
  ONLY THEN download the installer (size == manifest == API) -> attest installer -> SHA256 == SUMS == manifest == API digest   (-VerifyOnly stops here)
  idle check 2 -> presence before (needs the user hive, else postpone) -> keep verified bundle -> idle check 3 immediately before launch
  install from the SAME file (deny-write handle + re-hash) -> classify exit code -> health check
  ok -> state.json + prune bundles (keep 2) | genuinely failed -> wait (bounded) for Moonlight to close -> rollback -> count failure (deny after 2)
  finally: prune run dirs (keep newest 3)
```

Result line (stdout + log): `MLUPD_RESULT=<updated|noop|deferred|held|report-only|verified|verify_failed|pending_reboot|rolled_back|failed> MLUPD_TAG=<tag> MLUPD_DETAIL=<text>`.

### Version scheme (CONTRACT v1.1 section 3b, exactly)
`B = 60000 + 8*U + (N-1)`, N in 1..8, B <= 65535 (U <= 691). Tag `v6.2.0-daily.U-vp.N` (canonical: no leading zeros, N >= 1), manifest `build.version = 6.2.0-daily.B`, FileVersion `6.2.B.0`.
Installed (U,N) = `((B-60000) div 8, ((B-60000) mod 8)+1)`, derived from the FileVersion alone; ordering is numeric on B. A legacy installed `6.2.60006` is not special-cased: it is numerically lower than every new build.
Tags with N > 8 or B > 65535 are never candidates. `build.source_ref` must equal `refs/heads/build/v6.2.0-daily.<U>-n<N>` (derived from the tag, not trusted from the manifest).

### Internal time budget (all below the task limit `ExecutionTimeLimit` = PT2H)
API calls 3 x 60 s | small assets 3 x 120 s | installer download 600 s | `gh attestation verify` 3 x 180 s | installer run 600 s, then process-tree kill (<= 30 s) and Windows Installer idle wait (<= 120 s) |
rollback up to 3 installer runs x (600 + 150) s | wait for Moonlight to close before a rollback: backoff 30 + 60 + 120 + 240 s. An install is only started when <= 75 min of the run have elapsed.

## 2. Files and permissions

| Path | Content | ACL |
|---|---|---|
| `C:\Program Files\MoonlightPatchUpdater\` | `update.ps1`, `lib\*.ps1`, `gh-pin.json`, `config.json`, `bin\gh.exe` | protected; owner Administrators; SYSTEM + Administrators full; nobody else |
| `C:\ProgramData\MoonlightPatchUpdater\` | `logs\`, `updates\<run>\`, `bundles\`, `cache\`, `secrets\`, `gh-config\`, `state.json` | same |
| scheduled task `\MoonlightPatch\Update` | SYSTEM, highest, triggers logon+3 min / daily / PT6H, `ExecutionTimeLimit` PT2H, IgnoreNew | |

Self ACL check (R-CLW-1, AC-CLW-1): any Allow ACE with a write-type right (WriteData, AppendData, Delete, ChangePermissions,
TakeOwnership, ...) for a principal other than SYSTEM / Administrators / TrustedInstaller / CREATOR OWNER, a non-admin owner, or a
reparse point, on the program dir, `lib\`, `bin\`, every file in them, the data dir and its known sub-directories => exit 2, nothing else runs.
`update.ps1` performs the first check inline (before dot-sourcing `lib\`), so a tampered `lib\` file is never executed.

## 3. Configuration (`config.json`, program dir)

| key | default | meaning |
|---|---|---|
| `mode` | `report-only` | `install` \| `report-only` \| `hold`. Command line `-Mode` can only narrow (install > report-only > hold) |
| `channel` | `canary` | `canary` accepts pre-releases (the feed is all pre-release); `stable` ignores them |
| `cooling_off_hours` | `0` | local value; effective cooling-off = max(`min_cooling_off_hours`, this, policy value of the channel) |
| `min_cooling_off_hours` | `2` | local FLOOR: a policy value (canary `0`) is clamped up to it. The Owner lowers it locally by editing this file (admin-only), e.g. `0` for an immediate canary |
| `repo` | `emilwojcik93/moonlight-qt` | feed |
| `policy_branch` / `policy_path` | `automation` / `policy.yml` | policy source |
| `signer_workflow` | `github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml` | pinned `--signer-workflow`; must live in `repo`. **Confirm against the real publish workflow name.** |
| `verify_mode` | `offline` | `online` additionally runs `gh release verify` / `verify-asset` and needs a stored token (see 6) |
| `notify_enabled` | `false` | Google Chat webhook (DPAPI blob must exist) |
| `max_installer_mb` | `200` | download cap |
| `allow_no_baseline` | `false` | install even when no rollback baseline (previous verified bundle or Package Cache bundle) exists. Not recommended |
| `upstream_owners` | `["Nonary"]` | local owner floor: `manifest.upstream.owner` must be in this list AND in the policy list |

**There is no test mode.** Any key outside this table (`api_base`, `gh_path`, `skip_acl_check`, `data_dir`, ...) makes `config.json` invalid (exit 3); a stale `test-mode.flag` has no effect (`install-task.ps1` deletes it). Paths, endpoints and executables are constants of the code; the test harness substitutes them in memory (config hashtable, dependency table, `Invoke-UpdaterMain` parameters), and none of that code path is reachable from `update.ps1` or a file on disk.

Switches of `update.ps1`: `-Mode report-only|hold` (narrowing), `-VerifyOnly` (download and fully verify, install nothing, even when mode is install or report-only), `-Echo` (log lines on the console).

## 4. Policy (`policy.yml`, CONTRACT 5)

Parsed with a strict YAML subset parser (no PS 5.1 YAML support): scalars, nested maps, block and flow lists, comments; anchors, tags,
multi-line scalars, lists of maps and duplicate keys are rejected (=> fail closed). Both shapes are accepted:
CONTRACT (`allow_upstream_owners`, `cooling_off_hours: {stable, canary}`, `hold`, `deny`) and the file currently on `automation`
(`upstream.owner_allowlist`, `channels.<c>.cooling_off_hours`, `hold`). A policy without an owner allow-list, with a non-boolean `hold`
or a `deny` entry that is not a valid tag is refused. `hold: true` => no install. Missing `deny:` key is treated as empty and logged as a warning.
The policy is read anonymously with two calls: `GET /branches/automation` (ETag) gives the commit sha, `GET /contents/policy.yml?ref=<sha>`
reads exactly that commit (cached per sha, so steady state costs only conditional 304 requests).

## 5. Verification chain (CONTRACT 4) and what changed

| CONTRACT step | implementation |
|---|---|
| 1 tag regex, key > installed, deny-list | `^v6\.2\.0-daily\.[1-9][0-9]{0,4}-vp\.[1-9][0-9]{0,2}$` anchored (newline-safe, canonical: no aliases such as `0202`), build number B numeric > installed B; policy `deny:` (entries must be canonical tags) + local `state.json` deny |
| 2 age | `now - published_at >= max(min_cooling_off_hours, cooling_off_hours, policy[channel])`; `now` is replaced by the GitHub `Date` header when the local clock differs by more than 5 min; an older release that is old enough is chosen when the newest is too young |
| 3 `gh release verify[-asset]` | **cannot run unauthenticated (U3)**. Offline substitute: API `immutable == true` required; optional `verify_mode=online` with a stored token runs the real commands |
| 4 download to admin-only per-run dir | URLs are constructed from validated repo/tag/name (reserved device names rejected), HTTPS only, redirects followed manually and EVERY hop checked against `github.com`, `api.github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`, byte caps, truncation detected (Content-Length and manifest/API size), per-run dir with its own protected ACL. Order: manifest, SHA256SUMS, bundle first; the installer only after the manifest and SUMS attestations passed |
| 5 `gh attestation verify` | offline `--bundle` from the release asset named in the manifest: `--repo --signer-workflow --source-ref --deny-self-hosted-runners --predicate-type https://slsa.dev/provenance/v1 --cert-oidc-issuer https://token.actions.githubusercontent.com --format json`, plus `--source-digest <manifest.build.source_sha>` for SHA256SUMS and the installer. The source ref is derived from the tag (`refs/heads/build/v6.2.0-daily.<U>-n<N>`); the manifest is verified first so `source_sha` is authenticated |
| 6 SHA256 vs SHA256SUMS vs manifest | computed from the deny-write handle == SUMS == manifest == release API `digest` |
| 7 install from the same verified file, health check, rollback | see below |

Install (R-CLW-3): a `FileShare.Read` handle is held from before the attestation check until the run ends (nobody can write, delete or rename the file);
the hash is recomputed through that handle immediately before launch; `MoonlightSetup.exe /install /quiet /norestart /log <run>\install.log`, 600 s timeout.
Moonlight.exe must be closed at three points: at the start of the run, after the downloads/presence check, and immediately before the launch (any hit => deferred, nothing started).
The installer runs inside a job object: on timeout the WHOLE tree (Burn engine, msiexec children; job members plus a `Win32_Process` parent walk) is killed, the Windows Installer mutex (`Global\_MSIExecute`) is awaited,
and only after the tree is gone is any decision taken. If the tree or the Windows Installer cannot be stopped: exit 6, NO rollback, no deny, notification (needs a human).

Exit-code handling (P2-3): `0` success | `1618` (another install running) => deferred, no rollback, no deny, transient backoff | `3010` / `1641` with the target version present => success |
`3010` / `1641` with the version unchanged => `pending_reboot` (state `pending_reboot`, no rollback, no deny, new bundle kept); the next runs wait until the machine has rebooted, then either resolve it (target version present => installed recorded) or treat it as a genuine failure |
anything else, a wrong FileVersion after exit 0, or lost registry items => genuine failure: rollback, failure counter, **deny only after 2 consecutive real failures of the same tag** (1 h, then 2 h, ... backoff between attempts).
Health: FileVersion build == `manifest.build.version` build; presence-only booleans (before vs after) of `uniqueid`, `hosts` subkey, `certificate`/`key` value names in the console user's hive.

Backoff / counters (P2-6): per tag, `state.json` `attempts`: transient failures (network, download errors, gh timeouts, 1618) never deny, backoff 15 min x 2^(n-1) up to 6 h; verification failures (hash, attestation, manifest) back off the same way and deny after 3;
install failures back off 1 h x 2^(n-1) and deny after 2. A completely verified release resets the transient/verify counters. Failed or aborted runs leave at most the newest 3 run directories.

Presence-only registry check (R-CLW-4, T-4.4): SYSTEM has its own HKCU, so the console user is resolved (`Win32_ComputerSystem.UserName`, fallback owner of `explorer.exe`)
and `HKU\<sid>\Software\Moonlight Game Streaming Project\Moonlight` is opened read-only with `GetValueNames()` / `GetSubKeyNames()` only. The code contains no `GetValue`,
no `reg.exe`, no export; the Pester suite audits the AST for this and greps every log for `BEGIN PRIVATE KEY` / `BEGIN CERTIFICATE` (log values are also scrubbed:
PEM markers, DER blobs, tokens, webhook URLs, control characters). **User hive not loaded (nobody logged on):** before the install the run is postponed (`deferred`, log `presence_unavailable`; the AtLogOn trigger retries) so an install never goes unchecked;
if the hive disappears after the install, `verification_pending` is recorded (no rollback) and the check is repeated at the next run/logon; a late loss raises a `PRESENCE-LOST` notification.

Rollback (R-CLW-5, P2-5): **a rollback baseline is mandatory.** Baseline = the verified bundle of the build installed now (`bundles\<tag>` / `bundles\installed-<build>`), or the existing Burn bundle
`C:\ProgramData\Package Cache\{7CA3BD1C-5B34-4D14-91A0-4277DD5E2063}\MoonlightSetup.exe` copied into the data dir after an admin-only ACL check; it is re-hashed before anything is installed.
No baseline => the update is refused before any download (exit 3, log `no_rollback_baseline`) unless `allow_no_baseline` is true. At most 2 bundles are kept.
Rollback itself: Moonlight must be closed (bounded wait 30/60/120/240 s, then `rollback_pending` + alert `ROLLBACK-POSTPONED`, retried at the start of the next run); the previous bundle is re-hashed (abort if changed),
installed over the failed version; if the version did not change (Burn/MSI blocks downgrades) the idle check is repeated, the failed bundle is uninstalled, then the previous one installed. Every installer step has its own tree-kill/idle guard.
Exit 5 (rolled back) or 6 (rollback failed / postponed: needs a human). Optional Google Chat notification (disabled by default).

## 6. U3: unauthenticated `gh attestation verify` as SYSTEM (answered empirically)

Probe: `tests/U3-SystemProbe.ps1` run with `gsudo -s` (whoami = `nt authority\system`, PowerShell 5.1, no token, SYSTEM-like profile variables, private `GH_CONFIG_DIR`),
real public attested artifact `cli/cli` `v2.105.0` `gh_2.105.0_windows_amd64.zip` (immutable release). Result, 15/15 checks as expected:

| command (unauthenticated, SYSTEM) | result |
|---|---|
| `gh attestation verify <file> -R cli/cli` | **fails**, rc 4, "To get started with GitHub CLI, please run: gh auth login" |
| `gh release verify <tag>` / `gh release verify-asset <tag> <file>` | **fail**, rc 4, same message |
| `gh release download`, `gh attestation trusted-root` | work |
| `gh attestation verify <file> -R .. --bundle <bundle> --signer-workflow .. --source-ref .. --deny-self-hosted-runners` | **works**, rc 0 (TUF root fetched from Sigstore, no GitHub token) |
| same with `--custom-trusted-root <trusted-root.jsonl>` | works (fully offline once the root file exists) |
| tampered byte / wrong `--repo` / wrong `--signer-workflow` / wrong `--source-ref` | all rc 1 (fail closed) |

An earlier run that inherited the interactive user's profile variables "succeeded" online: that was ambient credentials, not unauthenticated SYSTEM. The probe scrubs them.
Anonymous `GET /repos/{r}/attestations/sha256:<digest>` works (60 requests/hour) but returns `bundle_url` pointing at an Azure blob holding a snappy-compressed bundle (decoder in `lib/Snappy.ps1`);
the updater does not need it because the CONTRACT ships `attestation.sigstore.json` as a release asset, which is also covered by the immutable release.
`gh attestation verify` cannot check the *release* attestation (tag -> commit -> asset set) offline: that certificate carries no repository OIDC claims, so `-R/--owner` (mandatory) fails with
"expected SourceRepositoryOwnerURI ... got <empty>" (verified). Therefore offline mode relies on the API `immutable` flag for the release-level guarantee.

Decision: **offline `--bundle` mode is the default and needs no secret on the machine.** `verify_mode=online` (token in a DPAPI blob, passed only through the child process environment) adds the real `gh release verify` / `verify-asset`.

## 7. gh.exe provisioning

`install-task.ps1` places `bin\gh.exe` into the admin-only program dir. Source: the machine copy `C:\Program Files\GitHub CLI\gh.exe` when its SHA256 equals the pin in `gh-pin.json` (version 2.105.0,
exe sha256 `77437def...bcd69`, same bytes as the cli/cli release zip `8813a72c...0627`), otherwise the pinned zip is downloaded over HTTPS and must match the pinned zip SHA256. Either way the copy must hash to the pinned exe SHA256 and have
a valid Authenticode signature by `GitHub, Inc.` (the machine exe is signed; checked). At every run `update.ps1` re-hashes `bin\gh.exe` against the pin before using it. Child environment: `GH_*`/`GITHUB_*` removed, `GH_CONFIG_DIR=<data>\gh-config`,
no prompts. Bumping gh = new `gh-pin.json` via a reviewed commit and a re-run of `install-task.ps1`.

## 8. CONTRACT findings (status)

1. **CONTRACT 4.3 infeasible token-less**: resolved by CONTRACT v1.1 section 3b (offline mode = immutable flag + offline bundle; online mode with token). Implemented as `verify_mode`.
2. **Rebuilds of the same upstream daily**: resolved by v1.1 3b (`B = 60000 + 8*U + (N-1)`), adopted exactly (section 1). N > 8 or B > 65535 is not installable and is dropped from the candidates.
3. `policy.yml` on `automation`: the legacy `upstream.owner_allowlist` shape is still tolerated, an empty owner list is refused, a missing `deny:` key is a warning.
4. Manifest fields consumed: `schema, product=moonlight, tag, upstream.owner, build.version|source_ref|source_sha, installer, assets[].name|sha256|size, attestation[]`; the bundle files must be release assets; attestation subjects must include the installer, `SHA256SUMS` and `manifest.json`; the signer workflow is `.github/workflows/patched-windows-release.yml`.
5. Anonymous policy read uses two API calls (branch sha, then contents pinned to that sha) instead of "one authenticated call"; equivalent pinning, documented deviation.

### Security Gate review (commit 25d05388): what was done
All P1/P2 items were fixed (P1 scheme; P2-1 tree kill; P2-2 task limit PT2H + documented budget; P2-3 exit-code classes; P2-4 idle re-checks; P2-5 mandatory baseline; P2-6 order/backoff/pruning; P2-7 no test hooks; P2-8 hive; P2-9 2 h floor).
P3 fixed: canonical tags (aliases rejected, also in deny lists), manual redirects with per-hop allow-list, truncation checks (Content-Length + expected size), GitHub server time vs local clock, directory recursion in the ACL check (junctions two levels down),
secondary rate limits (Retry-After) defer, reserved device names rejected, explicit `--predicate-type` / `--cert-oidc-issuer`, source ref derived from the tag, local owner floor, `-SetMode install` refused on a fresh machine,
the empty task folder is removed by `uninstall-task.ps1`, `-WhatIf` wording follows `-SetMode`. **Skipped** (residual): bounded reading of gh stdout/stderr and a wider env scrub for gh (P3-8), key-body scrubbing without PEM/`MII` prefix (P3-12; nothing logs registry data),
a dead-man alert for the Ally (needs the webhook), making the ACL self-check preventive rather than detective (protection rests on the install-time DACL and the inline bootstrap check), Deny-ACE evaluation.
The reviewer's negative tests are in `tests/QA.Negative.Tests.ps1` (attributed; formerly `Defect`-tagged tests now pass).

## 9. Exit codes

0 ok (updated, noop, deferred, held, report-only, verified, pending_reboot) | 1 internal error | 2 ACL violation | 3 config/policy invalid or unavailable (fail closed) | 4 verification failed (nothing installed) |
5 install failed, rolled back | 6 install failed and rollback failed / impossible / postponed, or installer could not be stopped | 7 another instance running | 8 rate limit or network deferral. `MLUPD_RESULT` carries the symbolic result.

## 10. Logs and state

`C:\ProgramData\MoonlightPatchUpdater\logs\update-YYYY-MM-DD.log`: one line per event, `<utc> LEVEL run=<id> event=<name> key="value" ...`; files roll at 2 MB (`.1`) and are deleted after 30 days; only the newest 3 per-run dirs are kept.
`state.json`: installed `{tag,u,n,build,sha256}`, local deny list, per-tag `attempts`, `pending_reboot`, `verification_pending`, `rollback_pending`, ETags, last check / last success. `cache\`: release list, branch, policy per sha.

## 11. Enabling it (gate G4): exact steps

Prerequisites (other roles): CI publishes with the CONTRACT 3b build numbers; the feed has at least one immutable release with `manifest.json`, `SHA256SUMS`, `attestation.sigstore.json`; `signer_workflow` below equals the real publish workflow path; ideally `deny: []` exists in `policy.yml`.

All commands from a normal PowerShell; elevation through gsudo (never `Start-Process -Verb RunAs`).

```powershell
cd C:\Users\ewojcik\vp-work\ml-updater\updater          # checkout of branch automation-updater
# 1. review the plan; this changes nothing
powershell -NoProfile -File .\install-task.ps1 -WhatIf
# 2. install (files, ACLs, gh.exe, config in report-only mode, scheduled task)
gsudo powershell -NoProfile -ExecutionPolicy Bypass -File .\install-task.ps1
# 3. if the CI publish workflow has another file name, edit signer_workflow
gsudo notepad "C:\Program Files\MoonlightPatchUpdater\config.json"
# 4. rehearsal as SYSTEM with Moonlight closed or open: selection only (needs a build number scheme 3b release newer than the installed 6.2.60006)
gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\MoonlightPatchUpdater\update.ps1" -Echo
#    expect MLUPD_RESULT=report-only (or noop). Then full download + verification, still no install:
gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\MoonlightPatchUpdater\update.ps1" -Echo -VerifyOnly
#    expect MLUPD_RESULT=verified; read C:\ProgramData\MoonlightPatchUpdater\logs\update-<date>.log (events attestation_ok, hash_ok)
#    The rollback baseline is the existing Burn bundle in C:\ProgramData\Package Cache\{7CA3BD1C-...}; without it the install is refused (check: Test-Path that file, ACL admin-only write).
#    Before enabling, consider the floor: min_cooling_off_hours defaults to 2 (a new release waits 2 h even if the policy says 0); lower it in config.json only deliberately.
# 5. G4: switch to install
gsudo powershell -NoProfile -ExecutionPolicy Bypass -File .\install-task.ps1 -SetMode install      # idempotent re-run, only mode changes
# 6. first real install with Moonlight closed, watched:
gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\MoonlightPatchUpdater\update.ps1" -Echo
#    expect MLUPD_RESULT=updated, events presence_before / presence_after (booleans), health_ok; start Moonlight, confirm pairing + a stream
# 7. let the task run: Start-ScheduledTask -TaskPath '\MoonlightPatch\' -TaskName Update ; (Get-ScheduledTaskInfo -TaskPath '\MoonlightPatch\' -TaskName Update).LastTaskResult  (0 = ok)
```

Optional: `-SetWebhook` (Google Chat alerts) and `-SetGhToken` (verify_mode=online) are prompts of `install-task.ps1`. Back out: `gsudo powershell -File .\uninstall-task.ps1 -RemoveFiles` (task and program dir; `-RemoveData` also removes logs/state/bundles). Hold at any time: set `"mode": "hold"` or `hold: true` in `policy.yml`.
Still to rehearse on the real feed (T-4.6): one watched install and one FORCED rollback (the Burn rollback path (uninstall + install previous), HKCU presence intact afterwards) and SYSTEM-session execution of `MoonlightSetup.exe`.

## 12. Tests

`tests/*.Tests.ps1` (Pester 5, 379 tests, Windows PowerShell 5.1): version/tag rules incl. malicious names, aliases and the 3b scheme, YAML/policy/config (no override keys), ACL checks (synthetic and on the real file system, junctions at any depth), mutex, deny-write handle,
command-line quoting and env scrubbing, process-tree kill, snappy decoder, manifest/SHA256SUMS validation, presence-only registry check (throw-away `HKCU:\Software\MlUpdaterPesterTest` key), installer runner with a compiled stand-in exe (hash re-check, timeout, locked file),
bundle store, rollback (both methods, idle guards), the whole orchestrator with fake dependencies (every negative case plus exit-code classes, pending reboot, postponed rollback, baseline, backoff/deny counters, hive unavailable, cooling-off floor, clock skew),
an end-to-end run against a loopback HTTP fixture (anonymous requests, policy pinned to the commit sha, ETag, real download and process runners, stand-in `gh` recording its flags, stand-in installer, real rollback), `update.ps1` as a process (ACL exit 2; stale flag/env vars have no effect),
`Invoke-UpdaterMain` in-process, `-WhatIf` of the install/uninstall scripts, the reviewer's negative suite, and network-tagged checks against a real attested artifact.
The suite never registers the task, installs or uninstalls Moonlight, or reads the real Moonlight registry key.
