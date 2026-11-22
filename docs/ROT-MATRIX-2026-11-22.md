# Rot matrix, 2026-11-22

Dry run of `patches/series` against the last 5 upstream `v6.2.0-daily.*` tags
plus `upstream/master` (Nonary/moonlight-qt). Produced by:

```
tools/rot-matrix.sh 5 --floor v6.2.0-daily.201 --out docs/rot.md
```

Series: 7 patches, `patch_series_sha256 = 838eb05f3f5c4b531f5401e2110fac313b7731457e4202a2555086cc3bfe76cd`.
Method: `git am --3way` into a temporary worktree per target; nothing is built
(apply-only check, see "What this does not prove"). "posture-only" is the series
with `--skip-group touch-menu`.

| target | commit | full series | posture-only | detail |
|---|---|---|---|---|
| `v6.2.0-daily.202` | `9184cacd8` | PASS | PASS | |
| `v6.2.0-daily.201` | `bbe6d2d36` | PASS | PASS | |
| `v6.2.0-daily.200` | `f586143cf` | BELOW_FLOOR | BELOW_FLOOR | 0002 conflicts in `app/gui/SettingsView.qml` |
| `v6.2.0-daily.199` | `19758e5e6` | BELOW_FLOOR | BELOW_FLOOR | 0002 conflicts in `app/gui/SettingsView.qml` |
| `v6.2.0-daily.198` | `d54e6c04b` | BELOW_FLOOR | BELOW_FLOOR | 0002 conflicts in `app/gui/SettingsView.qml` |
| `upstream/master` | `9184cacd8` | PASS | PASS | same commit as daily.202 |

`BELOW_FLOOR` = below the supported floor (`supported_floor_tag: v6.2.0-daily.201` in
`policy.yml`), not counted as rot.

## Reading the result

* The series applies cleanly to the two newest dailies and to master, with the
  full series and with posture-core alone.
* daily.198..200 fail for a structural reason, not rot: they predate upstream
  commit `17c572d7` ("feat(ui): add a controller-focused console interface"),
  which rewrote `SettingsView.qml` (1144 changed lines) and landed between
  daily.200 and the series base `ea12abb4`. The series was authored on top of
  that rewrite, so it cannot apply to older trees. Nothing to fix; this is why
  the floor exists.
* Failure behaviour was exercised on these tags: `apply-series.sh` stops at the
  first failing patch, prints it and the unmerged files, writes the optional
  `--report` markdown, and leaves no worktree behind (`git worktree list` clean).

## Cross-checks

* `apply-series.sh ea12abb4 --verify feature/stream-posture-sync` -> tree
  `10ffc5ef98d0351c52b984d421a431469be6f04a`, equal to the fork branch.
* `apply-series.sh ea12abb4 --skip-group touch-menu --verify 5b531d91` -> equal
  (the last posture-only commit of the fork branch), so the touch-menu group
  really is separable.
* Series on `upstream/master` gives tree `6016fa0ff7eadf4c1b3e0b85d7947138e15bf5e5`,
  identical to `git merge-tree --write-tree upstream/master feature/stream-posture-sync`.

## Expected future rot points

Patches touching files that upstream edits often (highest risk first):

| file | patches | why it moves |
|---|---|---|
| `app/gui/SettingsView.qml` | 0002, 0005 | console-UI/settings work, huge file |
| `app/streaming/session.cpp` | 0003, 0007 | upstream changes it nearly every week |
| `app/streaming/input/input.cpp` | 0007 | DualSense / Steam Controller / input work |
| `app/streaming/video/overlaymanager.cpp` | 0006 | overlay/VRR work |
| `app/app.pro`, `tests/tests.pro` | 0001, 0003, 0006 | any new source file upstream (list hunks) |
| `app/settings/streamingpreferences.{h,cpp}` | 0002, 0005 | any new setting upstream |

## What this does not prove

Apply-only: no compile, no tests, no run. The apply result on `ea12abb4` is
byte-identical (same tree) to the fork branch, which was built by CI as
`ci/posture-windows`, so that base is known to build. A newer upstream that
applies cleanly can still fail to build or fail tests; that is the build
pipeline's job (PLAN phase 2).
