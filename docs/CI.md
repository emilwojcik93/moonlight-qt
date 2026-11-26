# moonlight-qt patch pipeline: CI/release automation

Scope: `emilwojcik93/moonlight-qt` (public fork of `Nonary/moonlight-qt`). Implements PLAN sections 4.2, 4.3, 4.7,
5.4, 5.9 (tasks T-4.1, T-4.2) and the producer side of `CONTRACT.md` (v1.1 incl. 3b, plus the additive Linux amendment v1.2,
`docs/CONTRACT-v1.2-linux-amendment.md`). It is the moonlight twin of the
Vibepollo automation (`emilwojcik93/Vibepollo`, branch `automation`, `docs/CI.md`): same design and the same security
properties, adapted to the daily-tag feed, the `build-win-mac.yml` reusable workflow and the WiX Burn bundle; the same run also builds
upstream's Linux AppImage (`build-appimage.yml`) and ships it in the same immutable release.
Everything lives on the `automation` branch (the fork's default branch after the Owner switches it); build branches
`build/<tag>-n<N>` are generated, never edited by hand.

## 1. Flow

```
cron (hourly 07-11 UTC + 6-hourly)            manual: workflow_dispatch (tag, dry_run, override_hold, force_rebuild)
        |
  upstream-watch / resolve   (contents:read)
        |  list Nonary/moonlight-qt releases -> v6.2.0-daily.U (U <= 691), published, non-draft, >= policy floor -> newest
        |  deref tag -> commit SHA; compare with upstream-seen.json + upstream.lock (moved tag = HALT + alert)
        |  fingerprint patches/series (7 patches, groups posture-core + touch-menu); plan: build | rerun | noop | hold | halt
        v
  upstream-watch / prepare   (environment build-push; GITHUB_TOKEN contents:write for upstream-seen.json only)
        |  fetch tag (verify SHA again) -> git am --3way --keep-cr series (pinned identity/dates, reproducible)
        |  guard: patches may not touch gitlinks, .gitmodules, .github/, wix/, scripts/, app/deploy/, setup-deps.*, libs/, version.txt
        |  strip EVERYTHING below .github/ except build-win-mac.yml + build-appimage.yml (and drop their workflow_dispatch trigger)
        |  add wrapper + .vp-ci/ + build-meta.json; record upstream-seen.json BEFORE pushing the branch
        |  push build/<tag>-nN with the GitHub App token  ----> push event starts the wrapper
        v
  patched-windows-release.yml  (on the build branch)
     validate  (contents:read)   regex-check ref + metadata, recompute versions, ancestry check, workflow set
     build     (contents:read)   uses ./.github/workflows/build-win-mac.yml (ci_version 6.2.0-daily.B, source_ref = commit,
                                 build_macos false); no secrets exist in that workflow
     linux     (contents:read)   uses ./.github/workflows/build-appimage.yml (same ci_version and source_ref, in parallel with
                                 build); no secrets exist in that workflow; artifact Moonlight-LinuxAppImage-<ci_version>.
                                 BEST EFFORT: a failed linux job never blocks the Windows release
     package   (no permissions)  runs when validate + build succeeded (even if linux failed; not when cancelled);
                                 MANDATORY version gate (section 3); only if linux succeeded: AppImage gate (section 3, nothing
                                 executed); preview manifest; uploads gate-summary (+ appimage-gate-summary)
     publish   (contents/attestations/id-token:write; dry_run=false only)
               stage (bytes bound to the gate summaries) -> manifest.json + SHA256SUMS -> actions/attest
               -> self-verify like the Windows updater (online + offline) -> DRAFT release + upload -> digest check
               -> publish -> gh release verify + verify-asset + API immutable == true
     notify    (actions:write)   dispatches notify.yml on automation (issue + GChat, 24 h de-duplication); kinds failure
                                 (Windows side), success, and a separate `linuxskipped` when the linux job failed or was cancelled
```

### Why the build starts from a push, not from `workflow_dispatch`
Same reason as Vibepollo: `patched-windows-release.yml` exists only on build branches (it must live in the tree that
`build-win-mac.yml` checks out). Pushing the branch with an App token (App tokens, unlike `GITHUB_TOKEN`, trigger
workflows) starts the run bound to the exact pushed commit. Retries of failed builds use `gh run rerun --failed`
(planned by `plan_build.py`, at most 3 attempts in total per build branch, counted with the run `attempt` field because
a re-run keeps the run id; then `stuck` + alert).

## 2. Files (branch `automation`, owned by the CI/Release Engineer unless noted)

| Path | Purpose |
|---|---|
| `patches/`, `tools/`, `upstream.lock`, `policy.yml`, `docs/RESOLVING-ROT.md` | Patch Engineer (series, reference pin, CONTRACT section 5 policy) |
| `.github/workflows/upstream-watch.yml` | poll, plan, create + push `build/*` branch, record `upstream-seen.json`, re-run failed builds |
| `ci/appimage_gate.py` | mandatory Linux gate: name, size, ELF x86-64 + AppImage type 2, squashfs superblock, embedded version (never executes the image) |
| `docs/CONTRACT-v1.2-linux-amendment.md` | additive contract amendment: AppImage asset, manifest key `linux`, consumer verification steps |
| `ci/wrapper/patched-windows-release.yml` | TEMPLATE copied into each build branch as `.github/workflows/patched-windows-release.yml` |
| `.github/workflows/notify.yml` | one alert issue (label `automation-alert`, de-duplicated per kind+tag for 24 h) + sanitized GChat post |
| `.github/workflows/rot-matrix.yml` | apply the series to the last 5 upstream dailies at or above the floor (weekly, and on patch changes) |
| `.github/workflows/keepalive.yml` | weekly re-enable of scheduled workflows + dead-man check (3 days) |
| `.github/workflows/ci-selftest.yml` | pytest + actionlint + zizmor on every change to `ci/` and `.github/` |
| `.github/dependabot.yml` | weekly updates of SHA-pinned actions |
| `upstream-seen.json` | first-seen commit per upstream tag + recorded builds (pre-seeded with daily.201 and daily.202) |
| `ci/prepare_build_branch.py`, `tools/prepare-build-branch.sh` | break-glass local `prepare` (section 4) |
| `ci/*.py` | helpers (all stdlib, python3 >= 3.8), copied to `.vp-ci/` in build branches |
| `ci/tests/` | pytest suite (malicious tag fixtures in `ci/tests/fixtures/releases.json`, synthetic PE files for the gate) |
| `ci/rot-known-fail.txt` | upstream tags the series is known not to apply to (explicit, empty today) |

Helpers: `vpcommon` (regexes, safe `$GITHUB_OUTPUT` writer), `validate_tag`, `select_release`, `deref_commit`,
`version_map` (build number rule), `series` (series parser + fingerprint), `policy` (strict `policy.yml` reader, `x-`
extension keys ignored), `lock_update`, `plan_build`, `apply_series`, `assemble_build`, `workflow_check`,
`sensitive_paths`, `wrapper_params`, `pe_version` + `bundle_gate` (the version gate), `appimage_gate` (the Linux gate), `stage_assets`, `manifest_gen`
(manifest + SHA256SUMS), `notify_text`, `notify_dedupe`, `rot_matrix`.

Differences to the Vibepollo implementation (everything else is a copy): moonlight tag regex / `U`-keyed ordering;
`MAX_BUILD_N = 8` (exhaustion is a `stuck` alert, never a build); `select_release --floor`; `reference_pin` reads the flat
`upstream.lock`; no standalone MSI and no `release-provenance.json` exist, so `msi_summary.py` and the provenance
cross-check are replaced by `pe_version.py` + `bundle_gate.py`; the kept upstream workflow is `build-win-mac.yml`, which
upstream ships with `workflow_call` **and** `workflow_dispatch` (the pipeline removes the latter, section 4); alert
de-duplication (`notify_dedupe.py`, QA finding D11 of the Vibepollo review).

## 3. Versioning and the mandatory release gate (CONTRACT v1.1 section 3b)

| item | value for upstream daily `U`, rebuild `N` (1..8) |
|---|---|
| release tag | `v6.2.0-daily.U-vp.N` (regex `^v6\.2\.0-daily\.[0-9]{1,5}-vp\.[0-9]{1,3}$`; the pipeline only emits canonical numbers) |
| build branch / source ref | `build/v6.2.0-daily.U-nN`, attestation source ref `refs/heads/build/v6.2.0-daily.U-nN` |
| build number `B` | `60000 + 8*U + (N-1)` (U <= 691 so B <= 65535; N > 8 fails the build) |
| `ci_version` = `manifest.build.version` | `6.2.0-daily.B` (upstream `scripts/vrr-pe-version.ps1` maps it to PE/MSI `6.2.B`) |
| expected FileVersion = `manifest.build.msi_product_version` | `6.2.B.0` |

`B` is strictly monotonic in `(U, N)` (`B(U,8) + 1 = B(U+1,1)`), always above upstream's own `6.2.U` (Nonary's in-app updater
never offers a downgrade) and above the legacy hand-built `6.2.60002..60006`. Example: `v6.2.0-daily.202-vp.1` ->
`6.2.0-daily.61616` -> `6.2.61616.0`. Rebuilds of the same daily are `-vp.2` -> `61617`, ... `-vp.8` -> `61623`; the
next daily `203` starts at `61624`. `version_map.from_build_number` is the inverse the Windows updater uses.

**Mandatory gate** (`package` job, `bundle_gate.py`; publish is skipped when it fails): upstream emits no standalone MSI
(the x64 and arm64 MSIs sit inside the Burn bundle), so the gate reads what is there, with the stdlib and `7z`, never
executing anything:

1. expected `6.2.B.0` recomputed from tag + N, and `> upstream's own 6.2.U.0`;
2. bundle `MoonlightSetup-<ci_version>.exe` PE version resource (numeric `dwFileVersion` and the `FileVersion` string)
   equals expected;
3. Burn manifest (file `0` of the bundle's UX cabinet, extracted with `7z e -so`, size-capped, parsed with strict regexes):
   the `Registration` version and **every `MsiPackage` Version (the embedded MSIs' ProductVersion)** equal expected and at least
   two MSI packages (x64 + arm64) exist;
4. `Moonlight.exe` of the x64 and arm64 artifacts equal expected (numeric and string).

The summary (`gate-summary.json`: versions, bundle sha256/size) is re-validated by `manifest_gen.sanitize_gate_summary`
and embedded in `manifest.json` under the additive key `installer_checks`; `stage_assets.py --gate-summary` requires that the
bytes staged for release hash to the sha256 the gate inspected. Upstream's own in-build checks (`check-daily-packages.ps1`)
remain as a first line but run inside the untrusted build.

**Mandatory Linux gate** (`package` job, `appimage_gate.py`, CONTRACT v1.2). The artifact `Moonlight-LinuxAppImage-<ci_version>`
must hold exactly `Moonlight-<ci_version>-x86_64.AppImage` (`ci_version` recomputed from tag + N like the Windows one). The image
is only parsed, never run (no `--appimage-extract`, no `--version`):

1. name equals `Moonlight-<ci_version>-x86_64.AppImage`; regular file, 16 MiB <= size <= 400 MiB;
2. ELF header: 64-bit little-endian, machine x86-64, AppImage type-2 magic `AI\x02` at offset 8;
3. the squashfs starts at `e_shoff + e_shentsize * e_shnum`, has the `hsqs` magic, is squashfs 4.x with a known compression
   (zstd today) and ends inside the file (<= 1 MiB trailing bytes);
4. (reader) the payload is read, every reader run bounded by a 300 s wall-clock deadline and the member size cap (the process is
   killed on timeout or overflow), with `unsquashfs -n -o <offset> -cat` (installed from `squashfs-tools` when absent; the preinstalled
   7-Zip of ubuntu-24.04 is 23.01 and cannot read zstd squashfs) or, when only 7-Zip >= 24.01 exists, `7z e -so -tsquashfs`
   after checking that 7-Zip opened the same offset: `com.moonlight_stream.Moonlight.desktop` must carry
   `X-AppImage-Version=<ci_version>` (linuxdeploy writes `$VERSION` = `$CI_VERSION`), and `usr/bin/moonlight` must be an
   x86-64 ELF that contains the delimited string `<ci_version>` (the `VERSION_STR` define, the string `moonlight --version`
   prints, which upstream's build job checks by running it). A version string is delimited when it is not glued to letters, digits,
   `_`, `-` or `.` (so `Moonlight/6.2.0-daily.N`, `v6.2.0-daily.N`, quoted and `=`-prefixed forms count, which also covers a
   literal tail-merged into a longer string). Other `6.2.0-daily.<n>` strings are recorded in the summary (`other_versions`,
   at most 16) and fail the gate only when one is higher than `<ci_version>`.

Both versions exist in the real image (checked on the upstream v6.2.0-daily.202 AppImage: desktop entry and exactly one binary
string `6.2.0-daily.202`). The gate is a consistency check against mislabelled or stale artifacts, not a defence against a
malicious build job (same trust boundary as `bundle_gate.py`); the cryptographic guarantee is the attestation of the bytes
published. The summary (`appimage-gate-summary.json`: name, sha256, size, ELF/squashfs facts, embedded versions) travels in the
same `gate-summary` artifact, is re-validated by `manifest_gen.sanitize_linux_gate_summary`, embedded under the additive key
`linux_checks`, and `stage_assets.py --appimage-gate-summary` requires the staged bytes to hash to the sha256 the gate inspected.

## 4. Security model

Identical to the Vibepollo design (see its `docs/CI.md` section 4); restated for this repo:

* Top-level `permissions: {}` everywhere; per-job minimum. The build job and the unprivileged `package` job have no write
  scope, no `id-token`, no secrets. Only `publish` has `contents/attestations/id-token: write`.
* Every third-party action pinned by full SHA with a version comment (`test_workflows.py` enforces; Dependabot updates the
  workflows; the wrapper template pins are kept in sync by the same test). Pins: checkout v7.0.1, upload-artifact v7.0.2,
  download-artifact v8.0.2, attest v4.2.2, create-github-app-token v3.3.0. (Upstream's `build-win-mac.yml` itself uses
  unpinned `actions/checkout@v5`, `jurplel/install-qt-action@v4`, `upload-artifact@v6`: it runs in the secret-free build job
  and is accepted like upstream `ci-windows.yml` in the Vibepollo design.)
* Untrusted strings (tags, branch names, release ids, inputs) are regex-validated (`vpcommon`), passed through `env:` and never
  interpolated into `run:` (a test scans all workflows). Malicious fixtures: `$(id)`, backticks, newlines, `../`, unicode digits, bidi
  override, leading zeros, oversize numbers.
* Triggers: `schedule`, `workflow_dispatch`, `push` on `build/**` / `ci-trial/**` only. No `pull_request_target`, no `workflow_run`,
  no comment triggers. Privileged workflows refuse to run off `refs/heads/automation`; the wrapper refuses anything except `build/**`
  and `ci-trial/**` (trial branches are forced dry runs: no attestation, no release, no alerts).
* Build branches contain NOTHING below `.github/` except `workflows/build-win-mac.yml`, `workflows/build-appimage.yml` and the
  wrapper (all other upstream workflows, composite actions, dependabot/CODEOWNERS files are removed by `assemble_build.py`). Each
  kept file must have `on:` == exactly `workflow_call`: upstream's `workflow_dispatch` block is cut by a deterministic text
  transform and the result is re-checked in `assemble_build.py` and again in the `validate` job (`wrapper_params.check_workflows`);
  any other trigger added by upstream stops the pipeline (fail closed), as does a missing `build-appimage.yml`. Patches that touch
  `.github/`, `.gitmodules`, submodule gitlinks/paths, `wix/`, `scripts/`, `app/deploy/` (the AppImage workflow applies
  `app/deploy/linux/appimage/*.patch` to a libplacebo checkout), `setup-deps.*`, `libs/` or `app/version.txt` are rejected.
* Branch push credentials: `actions/create-github-app-token` with `PUSH_APP_ID` / `PUSH_APP_PRIVATE_KEY`, scoped to this
  repository with `contents:write` + `workflows:write`, only in the `prepare` job (executes no upstream code), environment
  `build-push` (deployment branches: `automation` only). Missing credentials fail the job explicitly; there is deliberately no
  fallback token.
* Push credential, App token OR deploy key: the `prepare` job needs ONE credential able to create branches that contain workflow
  files: the GitHub App (`PUSH_APP_ID` + `PUSH_APP_PRIVATE_KEY`) or a write deploy key of this repository (secret `PUSH_DEPLOY_KEY`;
  written with mode 600 to `$RUNNER_TEMP`, `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes`, `known_hosts` built from `gh api meta`
  over TLS, removed in an always step). Both live in environment `build-push`; the App wins when both exist; neither = explicit
  failure, never `GITHUB_TOKEN`.
* Break-glass / first-release path: `tools/prepare-build-branch.sh [--dry-run] [--tag v6.2.0-daily.U] [--remote origin]` (python
  `ci/prepare_build_branch.py`) runs the same code as `prepare` on the operator machine from a clean `automation` checkout and pushes
  the lock commit to `automation` and then `build/<tag>-nN` with the operator's own ssh credentials (exactly two `git push` calls, no
  `--force`; everything else reads public GitHub data anonymously). `--dry-run` prints branch, tip and tree and changes nothing. The
  shell wrapper picks the first interpreter that really runs (`python3`, `python`, `py -3`). On Windows use
  `GIT_SSH_COMMAND=C:/Windows/System32/OpenSSH/ssh.exe`.
* Moved upstream tag vs `upstream-seen.json` or the `upstream.lock` pin = HALT (job fails, issue + chat alert, nothing built).
* State ordering: `upstream-seen.json` is committed and pushed to `automation` BEFORE the build branch is pushed; a recorded
  build whose branch push failed is `stuck` (alert), a published release without a state entry is also `stuck`.
* Linux AppImage build (`linux` job): `build-appimage.yml` declares no secrets either, takes only `ci_version` and `source_ref`
  (the exact commit), runs on `ubuntu-22.04` with `permissions: contents: read` and enforces `runner.environment == github-hosted`
  for daily versions. Like `build-win-mac.yml` it is upstream code run inside the secret-free build job and is accepted on the
  same terms; it additionally downloads unpinned tools (`linuxdeploy` `continuous` releases, the LunarG apt key, `actions/checkout@v5`)
  and runs `scripts/*` that patches cannot touch. Its cache-save steps only run on the default branch, which never executes it, so
  build branches cannot poison caches. The job has no `timeout-minutes` (a reusable-workflow call cannot set one; the
  called workflow's own default applies) and a cold first run compiles SDL, FFmpeg, libplacebo and Moonlight.
  The `package` job parses the untrusted AppImage (ELF header, squashfs superblock by hand; payload via `unsquashfs` or 7-Zip) with
  `permissions: {}` and no secrets, so a reader bug cannot reach a token.
* Linux is optional (CONTRACT v1.2): `package` and `publish` use `!cancelled() && validate/build succeeded` (and `package`
  succeeded for `publish`), never `always()`, so an operator cancel cannot continue into publishing and a failed `linux` job cannot
  block Windows. Every Linux step is guarded by `needs.linux.result == 'success'`; with it false the staged files, `manifest.json`,
  `SHA256SUMS`, the attestation subjects, the upload and the verifications are exactly the Windows-only ones (tests execute the real
  stage steps with `LINUX_OK=false` and compare with a golden generated by the pre-amendment code). Two exclusive attest steps
  (`attest_both` / `attest_win`) keep one multi-subject bundle in both cases. A Linux build that succeeded but fails its gate
  still fails `package`: a suspicious artifact stops the release (fail closed); only a missing Linux build is tolerated. Releases
  are immutable, so a release published without the AppImage never gets one later; the next build (`-vp.N+1`) can.
  `notify` sends `linuxskipped` (own marker, own 24 h de-duplication) when linux failed or was cancelled; it never counts as `failure`.
* Secret-free upstream workflow: `build-win-mac.yml` declares **no secrets at all** (no SignPath, no symbol token, no signing
  identity; verified in the trial). Inputs: `ci_version`, `source_ref` (the exact commit SHA), `build_macos: false`. Never run on a
  tag ref.
* Sensitive-path report/gate (R-SEC-5): `sensitive_paths.py` lists upstream files changed since the LAST BUILT daily (else the previous
  release) under `.github/`, `wix/`, `scripts/`, `libs/`, submodule dirs, `setup-deps.*`, `*.pro/*.pri`, `.ps1/.bat/.cmd/.vbs/.wxs`,
  `AntiHooking/`, network/pairing/updater code (`app/backend/nvhttp*`, `autoupdatechecker*`, `identitymanager*`, `nvpairingmanager*`, ...).
  **Default = report only** (Owner decision: fully automatic installs): `::warning::`, run summary, release-notes bullet and
  `manifest.json` key `sensitive_paths_touched`. Repository variable `ENFORCE_SENSITIVE_GATE=true` routes such releases to environment
  `release-approval` (create it with a required reviewer first; `GITHUB_TOKEN` cannot read environment rules).
* Immutable releases are checked BEFORE the draft is created (`GET /repos/{repo}/immutable-releases`; if `GITHUB_TOKEN` cannot read
  it the variable `IMMUTABLE_CONFIRMED=true` is required) and a pre-existing tag without a release aborts the job. After publishing:
  `gh release verify`, `verify-asset` and API `immutable == true` (also on re-runs of an already published release).
* Release assets: `MoonlightSetup.exe` (the Burn bundle, renamed), `Moonlight-<ci_version>-x86_64.AppImage` (upstream's AppImage,
  name unchanged), `SHA256SUMS` (installer + AppImage + manifest), `manifest.json` (schema 1, `product: "moonlight"`, plus additive keys
  `installer_checks`, `sensitive_paths_touched`, `build.number`, `linux`, `linux_checks`), `attestation.sigstore.json` (ONE bundle covering
  installer, AppImage, SHA256SUMS, manifest; verified offline per subject). Created as a draft,
  `--prerelease --latest=false`, published after every digest matches. The portable zip is not published.
* The publish job verifies its own attestation before the release exists, both online and **offline with exactly the flags the Windows
  updater passes** (`--bundle --repo --signer-workflow --source-ref --source-digest --deny-self-hosted-runners --predicate-type
  https://slsa.dev/provenance/v1 --cert-oidc-issuer https://token.actions.githubusercontent.com`, no token).
* Untrusted binary parsing (PE resources, Burn manifest via 7-Zip) runs only in the unprivileged `package` job.

## 5. Operations

| Task | How |
|---|---|
| Dry run of the whole resolve/apply/assemble path | Actions -> Upstream Watch -> Run workflow, `dry_run=true` (needs no App credentials) |
| Build a specific upstream daily | `tag=v6.2.0-daily.U` (manual runs ignore the "older than newest seen" rule and the floor) |
| Pause | `policy.yml: hold: true` or repository variable `HOLD=true`; `override_hold=true` for one run |
| Rebuild with an unchanged series | `force_rebuild=true` -> next `N` (max 8 per daily) |
| Series changed (new commit in `patches/`) | next scheduled/manual run sees a new `series_sha256` -> new `N` automatically; protect `automation` with a ruleset |
| Ship posture-core while touch-menu rots | comment the `# group: touch-menu` block out of `patches/series` (new series hash -> new N; `patches.groups` in the manifest then lists `posture-core` only); restore it when fixed |
| `N` exhausted (8 rebuilds of one daily) | `stuck` alert; wait for the next upstream daily (resets to N=1) or fold fixes into fewer rebuilds |
| Build failed | automatic `gh run rerun --failed` until 3 attempts in total, then `stuck` alert (once per 24 h) until fixed |
| Patch conflict | run summary + artifact `conflict-report`; fix patches on `automation` (`docs/RESOLVING-ROT.md`) |
| Moved upstream tag | investigate; to accept the new commit remove the tag entry from `upstream-seen.json` AND update `upstream.lock` deliberately |
| Upstream daily number > 691 | selection skips it (B would exceed 65535); needs a CONTRACT change (new base) - about 3.7 years at 2.5 dailies/week |
| Verify a release by hand | `gh release verify <tag> -R emilwojcik93/moonlight-qt`; `gh attestation verify MoonlightSetup.exe -R emilwojcik93/moonlight-qt --signer-workflow emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml --source-ref refs/heads/build/<tag>-n<N> --deny-self-hosted-runners` |
| Local checks | `python -m pytest ci/tests`; `actionlint`; `zizmor .github/workflows ci/wrapper` |

Trial of the Linux path (dry run: forced for `ci-trial/**`, no attestation, no release, no alerts; the workflow reads
`.vp-ci/build-meta.json` with `trial: true`). Build the branch locally with the same code the workflow uses, from a clean
checkout of the branch that carries this pipeline (`automation`), and push it by hand (needs an identity that may push workflow files):

```
U=9184cacd8d426316bdecc47634f0dbf4e6e34654; TAG=v6.2.0-daily.202; W=$(mktemp -d)
git init -q $W/src && git -C $W/src fetch -q --no-tags https://github.com/Nonary/moonlight-qt.git refs/tags/$TAG:refs/tags/up
git -C $W/src checkout -q --detach $U
python3 ci/apply_series.py --repo $W/src --base $U --series patches/series --patches-dir patches
python3 ci/assemble_build.py --repo $W/src --ci-dir ci --base $U --tag $TAG --n 0 --branch ci-trial/$TAG-n0 \
  --release-id 454272425 --published-at 2026-11-22T07:17:53Z --series-sha "$(bash tools/series-sha.sh)" \
  --patch-count 7 --groups posture-core,touch-menu --trial
git -C $W/src push https://github.com/emilwojcik93/moonlight-qt.git HEAD:refs/heads/ci-trial/$TAG-n0
```

Expect `validate`, `build`, `linux`, `package` green and the artifact `release-preview` holding a `manifest.json` with the keys
`linux` and `linux_checks`. The first `linux` run is cold (dependency and compiler caches are not shared with `build/*` branches).

Alerts: failures open or comment on ONE issue labelled `automation-alert` (Issues must be enabled) and, when the secret
`GCHAT_WEBHOOK_URL` exists, post a sanitized one-line message (webhook URL through curl `-K -` on stdin). The same kind+tag is not
repeated within 24 hours (hidden marker `<!-- ml-alert:kind=K;tag=T -->` in the issue body/comments). Missing secret = silent skip.

## 6. Producer / consumer contract (Windows updater, branch `automation-updater`, `updater/docs/UPDATER.md`)

| Consumer expectation | Producer |
|---|---|
| release tag `^v6\.2\.0-daily\.[1-9][0-9]{0,4}-vp\.[1-9][0-9]{0,2}$`, N 1..8 | emitted exactly (`vpcommon.RELEASE_TAG_RE`, `version_map`) |
| assets `manifest.json`, `SHA256SUMS`, installer, bundle named in `manifest.attestation` | all present; bundle = `attestation.sigstore.json` |
| `manifest.installer` matches `^MoonlightSetup[A-Za-z0-9._-]{0,40}\.exe$` | `MoonlightSetup.exe` |
| `build.version` `^6\.2\.0-daily\.[0-9]{5}$`, `B == 60000 + 8U + N - 1` | `6.2.0-daily.B` (checked in `validate_manifest`) |
| `build.source_ref == refs/heads/build/v6.2.0-daily.U-nN`, `build.source_sha` 40 hex | exact; `source_sha` = `github.sha` of the signing run = attestation `SourceRepositoryDigest` |
| `upstream.owner` in policy + local allow-list | `Nonary` |
| attestation subjects include installer, `SHA256SUMS`, `manifest.json`; verified offline with `--source-digest manifest.source_sha` | one multi-subject SLSA provenance v1 bundle; self-verified with the identical flags in `publish` |
| SHA256SUMS lines `sha256  name` for installer (+ `manifest.json`) | exact; `manifest.json` hash is in the sums; one more line for the AppImage (ignored by the Windows updater: it looks up its installer by name) |
| (Linux, v1.2) asset `Moonlight-<ci_version>-x86_64.AppImage`, manifest key `linux` = `{installer, sha256, size}` | additive: `assets[]`, `installer`, `installer_checks` and every other key unchanged; the AppImage is an attestation subject and a release asset; `linux_checks` carries the gate summary (`manifest_gen.validate_linux`) |
| (Linux, v1.2) embedded version of the AppImage = `manifest.build.version` | enforced by the Linux gate (section 3) |
| release flagged `immutable` (API) | enforced before creating the draft and asserted after publishing |
| signer workflow `.github/workflows/patched-windows-release.yml` | the `publish` job lives in that file (attest runs directly in it) |
| FileVersion of the installed Moonlight.exe = `6.2.B.0` | enforced by the version gate (section 3) |

## 7. Owner actions (manual, once; none of them is possible with the agent token)

Already present (verified read-only on 2026-11-22): environments `build-push` (deployment branch policy `automation`) and `release-auto`,
immutable releases enabled, Issues enabled.

1. Fast-forward `automation` to `automation-ci` (Orchestrator), then make `automation` the fork's default branch
   (`gh repo edit emilwojcik93/moonlight-qt --default-branch automation`). Scheduled workflows and `workflow_dispatch` of
   `notify.yml` need it.
2. Create the GitHub App (Contents: Read & write, Workflows: Read & write, Metadata: Read; no webhook, no user access), **install it on
   `emilwojcik93/moonlight-qt` only**, and store `PUSH_APP_ID` (variable; the App ID or Client ID) and `PUSH_APP_PRIVATE_KEY` (secret) in
   environment `build-push`. The environment currently has no secret or variable. If one App serves both forks, install it on both
   repositories; the token minted here is scoped to this repository.
3. Immutable releases: already enabled; confirm the repository variable `IMMUTABLE_CONFIRMED=true` only if
   `GET /repos/emilwojcik93/moonlight-qt/immutable-releases` is not readable by `GITHUB_TOKEN`.
4. Optional: environment `release-approval` (required reviewer = Owner) only if `ENFORCE_SENSITIVE_GATE=true`; secret `GCHAT_WEBHOOK_URL`.
5. Rulesets: `build/**` creation/update restricted to the App; `automation` no force-push/deletion but it MUST still accept pushes of `github-actions[bot]` (upstream-watch commits `upstream-seen.json` with `GITHUB_TOKEN`); tags `*-vp.*` no update/delete
   (do not restrict creation: `GITHUB_TOKEN` creates the tag). Settings > Actions: "Require actions to be pinned to a full-length
   commit SHA" (the self-test and the wrapper are pinned; the upstream reusable workflow is not, so enable it only after checking that
   setting's scope for reusable workflows from the same repository), fork-PR approval for all external contributors, artifact and log
   retention 7 days (upstream's workflow uploads symbols and binaries with the repository default of 90 days).

## 8. Trial result (secret-free build path, wrapper dry run) - works

Branch `ci-trial/v6.2.0-daily.202-n0` = upstream `v6.2.0-daily.202` (9184cacd) + the 7-patch series + wrapper (built locally with the
same `apply_series.py` / `assemble_build.py` the workflow uses, pushed by hand), run 45059534569 (push trigger, dry run),
19:13:33Z -> 19:41:39Z (28.1 min), **success**:

| Job | Result | Time |
|---|---|---|
| validate | success | 12 s |
| build -> `build-win-mac.yml` (windows-2025, Qt 6.11.1: compile x64+arm64, all upstream tests incl. the patch's posture/touch-menu test targets, bundle) | success | 27.3 min |
| package (gate, stage, preview manifest; ubuntu, 7-Zip = preinstalled `/usr/bin/7z`) | success | 28 s |
| publish / notify | skipped (dry run / trial) | - |

Facts learned: no secret and no input beyond `ci_version`, `source_ref`, `build_macos` is needed (the workflow declares no secrets);
no standalone MSI and no provenance file are produced; artifacts: `Moonlight-Windows-Release-<ci>` (bundle 52.97 MB + portable zip,
92 MB), `Moonlight-Windows-x64-<ci>` (39 MB, `Moonlight.exe` at the root), `-arm64-` (34 MB), `zDevDbgSyms-Windows-<ci>` (99 MB),
`VRR-trace-contracts-*` (0.5 MB). The gate read `6.2.61616.0` from the bundle PE, from the Burn manifest (registration + both MSI
packages) and from both `Moonlight.exe`; the manifest was generated and verified (`manifest.json` + `SHA256SUMS`). The patched
series compiled and passed upstream's tests on the current upstream daily (the series had only been apply-tested before).
Untested until the first real release: the `publish` job (attest, release, verify) and `upstream-watch` itself (it can only run
from the default branch). The self-test workflow is green on `ubuntu-24.04` (338 tests, actionlint 1.7.12 + shellcheck, zizmor 1.32.0).

## 9. Optimization notes (measured, run 45059534569)

| Step | Time | Note |
|---|---|---|
| checkout (recursive submodules, depth 0) | 27 s | fine |
| setup-deps (prebuilt moonlight-qt-deps v8) | 31 s | fine |
| Install Qt x64 + arm64 | 102 s + 61 s | `jurplel/install-qt-action` caches are branch-scoped: a fresh `build/*` branch never hits the cache. A warm-up workflow on the default branch would save ~2.5 min per build; not worth a new privileged-adjacent workflow |
| Build x64 | 421 s | |
| Build VRR diagnostics / test targets (all of `tests/tests.pro`) | 454 s | includes the posture and touch-menu tests (patch group tests) |
| Run upstream test steps | ~2-3 min | |
| Build ARM64 | 358 s | cross build; required because the Burn bundle embeds the arm64 MSI and the gate requires both |
| bundle (`generate-bundle.bat`) | 12 s | |
| package (gate) | 28 s | |

Total 28 min versus the PLAN budget of 60 min (R-BLD-5): no further optimization is needed. Skipping arm64 or the tests would need a
`ci` patch to upstream's workflow (diverging from upstream, Security Gate review) for a 6-8 min gain: not done. Artifact
retention is the repository default (upstream's workflow sets no retention): set Settings > Actions > retention to 7 days
(Owner action 5). `fail-fast` is irrelevant (single matrix entry); concurrency is per build branch with `cancel-in-progress: false`.
