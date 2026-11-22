# Moonlight patch updater: design, operation, enablement

Scope: Windows Client Engineer deliverable (PLAN tasks T-4.3 .. T-4.5) for the patched Moonlight feed. Binding inputs:
CONTRACT.md (release feed v1), research/02 (client), research/04 (security). Gate G4 = you switch the task to install mode.

## 1. What it does

```
trigger (logon | daily 04:17 | every 6 h)  ->  SYSTEM  ->  powershell.exe update.ps1
  bootstrap ACL check of update.ps1 + lib\ (inline, before any lib code runs)          exit 2 on violation
  config.json (validated, whitelist)  ->  data-dir self ACL check  ->  named mutex      exit 3 / 2 / 7
  mode: hold -> stop.  install & Moonlight.exe running -> deferred (exit 0)
  installed version: FileVersion 6.2.<60000+U> of Moonlight.exe  ->  key (U, N=0 | N from state.json)
  policy.yml from branch `automation`: branches API -> commit sha -> contents API ?ref=<sha>    fail closed (exit 3)
  releases API (anonymous, ETag, rate-limit aware) -> tag regex -> newest-first candidates
  per candidate: not denied (policy + local) -> key > installed -> MSI build number > installed -> age >= cooling-off
  report-only -> log "would install <tag>" and stop (no download)
  release must be immutable (API flag) -> download manifest.json + SHA256SUMS + bundles + installer into a per-run dir
  manifest schema/regex validation -> offline attestation verify of manifest, SHA256SUMS, installer (pinned flags)
  SHA256: computed == SHA256SUMS == manifest == API digest      (-VerifyOnly stops here)
  idle check again -> keep verified bundles -> install from the SAME file (deny-write handle + re-hash) -> health check
  health ok -> state.json + prune bundles (keep 2) | health failed -> deny tag locally, rollback, notify
```

Result line (stdout + log): `MLUPD_RESULT=<updated|noop|deferred|held|report-only|verified|verify_failed|rolled_back|failed> MLUPD_TAG=<tag> MLUPD_DETAIL=<text>`.

## 2. Files and permissions

| Path | Content | ACL |
|---|---|---|
| `C:\Program Files\MoonlightPatchUpdater\` | `update.ps1`, `lib\*.ps1`, `gh-pin.json`, `config.json`, `bin\gh.exe` | protected; owner Administrators; SYSTEM + Administrators full; nobody else |
| `C:\ProgramData\MoonlightPatchUpdater\` | `logs\`, `updates\<run>\`, `bundles\`, `cache\`, `secrets\`, `gh-config\`, `state.json` | same |
| scheduled task `\MoonlightPatch\Update` | SYSTEM, highest, triggers logon+3 min / daily / PT6H, `ExecutionTimeLimit` PT30M, IgnoreNew | |

Self ACL check (R-CLW-1, AC-CLW-1): any Allow ACE with a write-type right (WriteData, AppendData, Delete, ChangePermissions,
TakeOwnership, ...) for a principal other than SYSTEM / Administrators / TrustedInstaller / CREATOR OWNER, a non-admin owner, or a
reparse point, on the program dir, `lib\`, `bin\`, every file in them, the data dir and its known sub-directories => exit 2, nothing else runs.
`update.ps1` performs the first check inline (before dot-sourcing `lib\`), so a tampered `lib\` file is never executed.

## 3. Configuration (`config.json`, program dir)

| key | default | meaning |
|---|---|---|
| `mode` | `report-only` | `install` \| `report-only` \| `hold`. Command line `-Mode` can only narrow (install > report-only > hold) |
| `channel` | `canary` | `canary` accepts pre-releases (the feed is all pre-release); `stable` ignores them |
| `cooling_off_hours` | `0` | local floor; the policy value for the channel can raise it, never lower it |
| `repo` | `emilwojcik93/moonlight-qt` | feed |
| `policy_branch` / `policy_path` | `automation` / `policy.yml` | policy source |
| `signer_workflow` | `github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml` | pinned `--signer-workflow`; must live in `repo`. **Confirm against the real publish workflow name.** |
| `verify_mode` | `offline` | `online` additionally runs `gh release verify` / `verify-asset` and needs a stored token (see 6) |
| `notify_enabled` | `false` | Google Chat webhook (DPAPI blob must exist) |
| `max_installer_mb` | `200` | download cap |

Test-only keys (`api_base`, `download_base`, `allow_http`, `gh_path`, `data_dir`, `skip_acl_check`) are rejected unless the file
`test-mode.flag` exists in the (admin-only) program dir. Environment variables never enable them. The flag file must not exist in production.

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
| 1 tag regex, key > installed, deny-list | `^v6\.2\.0-daily\.[0-9]{1,5}-vp\.[0-9]{1,3}$` anchored (newline-safe), key (U,N) numeric; policy `deny:` + local `state.json` deny; **plus** MSI build number must exceed installed (see 8.2) |
| 2 age | `now - published_at >= max(local, policy[channel])`; an older release that is old enough is chosen when the newest is too young |
| 3 `gh release verify[-asset]` | **cannot run unauthenticated (U3)**. Offline substitute: API `immutable == true` required; optional `verify_mode=online` with a stored token runs the real commands |
| 4 download to admin-only per-run dir | URLs are constructed from validated repo/tag/name, HTTPS, redirect hosts allow-listed, byte caps, per-run dir with its own protected ACL |
| 5 `gh attestation verify` | offline `--bundle` from the release asset named in the manifest: `--repo --signer-workflow --source-ref --deny-self-hosted-runners --format json`, plus `--source-digest <manifest.build.source_sha>` for SHA256SUMS and the installer. Manifest verified first so its `source_ref`/`source_sha` are authenticated. Allowed refs: `refs/heads/automation` or `refs/heads/build/<name>` |
| 6 SHA256 vs SHA256SUMS vs manifest | computed from the deny-write handle == SUMS == manifest == release API `digest` |
| 7 install from the same verified file, health check, rollback | see below |

Install (R-CLW-3): a `FileShare.Read` handle is held from before the attestation check until the run ends (nobody can write, delete or rename the file);
the hash is recomputed through that handle immediately before launch; `MoonlightSetup.exe /install /quiet /norestart /log <run>\install.log`, 10 min timeout (process killed).
Exit 0 and 3010 are success. Health: FileVersion build == `manifest.build.version` build; presence-only booleans (before vs after) of `uniqueid`, `hosts` subkey, `certificate`/`key` value names in the console user's hive.

Presence-only registry check (R-CLW-4, T-4.4): SYSTEM has its own HKCU, so the console user is resolved (`Win32_ComputerSystem.UserName`, fallback owner of `explorer.exe`)
and `HKU\<sid>\Software\Moonlight Game Streaming Project\Moonlight` is opened read-only with `GetValueNames()` / `GetSubKeyNames()` only. The code contains no `GetValue`,
no `reg.exe`, no export; the Pester suite audits the AST for this and greps every log for `BEGIN PRIVATE KEY` / `BEGIN CERTIFICATE` (log values are also scrubbed:
PEM markers, DER blobs, tokens, webhook URLs, control characters). If the user's hive is not loaded the check is `unknown` and not used for a decision.

Rollback (R-CLW-5): the verified bundle of the version being replaced is kept (`bundles\<tag>` or `bundles\installed-<build>` copied from
`C:\ProgramData\Package Cache\{7CA3BD1C-5B34-4D14-91A0-4277DD5E2063}\MoonlightSetup.exe` after an ACL check); at most 2 are kept. On failed health: the tag is added to the local deny list,
the previous bundle is re-hashed (aborts if changed), installed over the failed version; if the version did not change (Burn/MSI blocks downgrades) the failed bundle is uninstalled first,
then the previous one installed. Exit 5 (rolled back) or 6 (rollback failed: needs a human). Optional Google Chat notification (disabled by default).

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

## 8. Findings that need a decision from the Orchestrator (CONTRACT feasibility)

1. **CONTRACT 4.3 as written is infeasible for a token-less consumer** (section 6). Proposal: amend 4.3 to "release is immutable (API flag) AND, where a token is available, `gh release verify[-asset]`"; step 5 stays mandatory and offline.
2. **Rebuilds of the same upstream daily cannot be installed.** `ci_version = 6.2.0-daily.(60000+U)` gives FileVersion `6.2.<60000+U>` for every `-vp.N` of the same U; MSI major upgrade ignores a same-version package. The updater therefore skips a candidate whose MSI build
   number is not greater than the installed one (logged `same or lower MSI build number`) instead of reporting a fake success. Proposal for CI: encode N in the third field, e.g. `60000 + 8*U + (N-1)` (N <= 8; U up to ~694) or a monotonic counter as research/02 recommended; the updater reads the expected build only from the attested `manifest.build.version`
   (one function, `ConvertTo-BuildNumber` in `lib/Version.ps1`, to change when the scheme changes).
3. The `policy.yml` on branch `automation` today has no `schema`, `deny` or `allow_upstream_owners` (CONTRACT 5); the updater accepts the `upstream.owner_allowlist` shape and warns on the missing `deny:` key. Proposal: add `deny: []` (and `schema: 1`) so a deny entry can actually be written.
4. The publish workflow file name (`signer_workflow`) and the manifest fields used here (`product`, `tag`, `upstream.owner`, `build.version|source_ref|source_sha`, `installer`, `assets[]`, `attestation[]`) must match what the CI engineer ships; subjects of the attestation must include the installer, `SHA256SUMS` and `manifest.json`.
5. Anonymous policy read uses two API calls (branch sha, then contents pinned to that sha) instead of "one authenticated call"; equivalent pinning, documented deviation.

## 9. Exit codes

0 ok (updated, noop, deferred, held, report-only, verified) | 1 internal error | 2 ACL violation | 3 config/policy invalid or unavailable (fail closed) | 4 verification failed (nothing installed) |
5 install failed, rolled back | 6 install failed and rollback failed / impossible | 7 another instance running | 8 rate limit or network deferral. `MLUPD_RESULT` carries the symbolic result.

## 10. Logs and state

`C:\ProgramData\MoonlightPatchUpdater\logs\update-YYYY-MM-DD.log`: one line per event, `<utc> LEVEL run=<id> event=<name> key="value" ...`; files roll at 2 MB (`.1`) and are deleted after 30 days; per-run dirs older than 7 days are removed.
`state.json`: installed `{tag,u,n,build,sha256}`, local deny list, ETags, last check / last success. `cache\`: release list, branch, policy per sha.

## 11. Enabling it (gate G4): exact steps

Prerequisites (other roles): the feed has at least one immutable release with `manifest.json`, `SHA256SUMS`, `attestation.sigstore.json`; `signer_workflow` below equals the real publish workflow path; ideally `deny: []` exists in `policy.yml`.

All commands from a normal PowerShell; elevation through gsudo (never `Start-Process -Verb RunAs`).

```powershell
cd C:\Users\ewojcik\vp-work\ml-updater\updater          # checkout of branch automation-updater
# 1. review the plan; this changes nothing
powershell -NoProfile -File .\install-task.ps1 -WhatIf
# 2. install (files, ACLs, gh.exe, config in report-only mode, scheduled task)
gsudo powershell -NoProfile -ExecutionPolicy Bypass -File .\install-task.ps1
# 3. if the CI publish workflow has another file name, edit signer_workflow
gsudo notepad "C:\Program Files\MoonlightPatchUpdater\config.json"
# 4. rehearsal as SYSTEM with Moonlight closed or open: selection only
gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\MoonlightPatchUpdater\update.ps1" -Echo
#    expect MLUPD_RESULT=report-only (or noop). Then full download + verification, still no install:
gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\MoonlightPatchUpdater\update.ps1" -Echo -VerifyOnly
#    expect MLUPD_RESULT=verified; read C:\ProgramData\MoonlightPatchUpdater\logs\update-<date>.log (events attestation_ok, hash_ok)
# 5. G4: switch to install
gsudo powershell -NoProfile -ExecutionPolicy Bypass -File .\install-task.ps1 -SetMode install      # idempotent re-run, only mode changes
# 6. first real install with Moonlight closed, watched:
gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\MoonlightPatchUpdater\update.ps1" -Echo
#    expect MLUPD_RESULT=updated, events presence_before / presence_after (booleans), health_ok; start Moonlight, confirm pairing + a stream
# 7. let the task run: Start-ScheduledTask -TaskPath '\MoonlightPatch\' -TaskName Update ; (Get-ScheduledTaskInfo -TaskPath '\MoonlightPatch\' -TaskName Update).LastTaskResult  (0 = ok)
```

Optional: `-SetWebhook` (Google Chat alerts) and `-SetGhToken` (verify_mode=online) are prompts of `install-task.ps1`. Back out: `gsudo powershell -File .\uninstall-task.ps1 -RemoveFiles` (task and program dir; `-RemoveData` also removes logs/state/bundles). Hold at any time: set `"mode": "hold"` or `hold: true` in `policy.yml`.
Not yet proven on a real feed: the Burn rollback path (uninstall + install previous) and SYSTEM-session execution of `MoonlightSetup.exe`; rehearse with T-4.6 on the first real update.

## 12. Tests

`tests/*.Tests.ps1` (Pester 5): version/tag rules incl. malicious names, YAML/policy/config, ACL checks (synthetic and on the real file system, junctions), mutex, deny-write handle, command-line quoting and env scrubbing, snappy decoder,
manifest/SHA256SUMS validation, presence-only registry check (throw-away `HKCU:\Software\MlUpdaterPesterTest` key), installer runner with a compiled stand-in exe (hash re-check, timeout, locked file), bundle store, rollback (both methods),
the whole orchestrator with fake dependencies (every negative case: tampered byte, hash mismatch, attestation failure, downgrade, too young, deny-listed, Moonlight running, ACL violation, policy unavailable, rate limit, rollback), an end-to-end run
against a loopback HTTP fixture (anonymous requests, policy pinned to the commit sha, ETag, real download and process runners, stand-in `gh` recording its flags, stand-in installer), `update.ps1` as a process, `-WhatIf` of the install/uninstall scripts,
and network-tagged checks against a real attested artifact. The suite never registers the task, installs or uninstalls Moonlight, or reads the real Moonlight registry key.
