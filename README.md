# moonlight-qt posture patches (automation branch)

This branch holds only automation files for `emilwojcik93/moonlight-qt`: the
posture and touch-menu feature as an ordered patch series on top of
`Nonary/moonlight-qt`, plus the tools to apply and test it. The fork's
`feature/stream-posture-sync` is the reference the series is verified against.

```
patches/series         ordered list; "# group: NAME" markers
patches/0001..0007     git format-patch files (author, subject, rationale)
upstream.lock          upstream tag/commit the series was last verified against
policy.yml             allowlist, cooling-off, hold switch, version scheme
tools/apply-series.sh  git am --3way into a temp worktree, optional tree verify
tools/rot-matrix.sh    dry run against the last N upstream daily tags + master
tools/tests/           regression tests (tools/tests/test-tools.sh)
tools/series-sha.sh hash of the series (patch_series_sha256)
docs/                  rot matrix results, how to resolve rot
```

## The series

| # | group | patch |
|---|---|---|
| 0001 | posture-core | classifier + Windows/Linux (KWin D-Bus) detectors + unit tests |
| 0002 | posture-core | settings: posture mode, reconnect-on-posture, CLI flags |
| 0003 | posture-core | send posture on launch/resume, `/posture` monitor, resume on change |
| 0004 | posture-core | docs/client-posture.md |
| 0005 | touch-menu | settings: touch menu trigger |
| 0006 | touch-menu | touch menu model, overlay rendering, tests |
| 0007 | touch-menu | input handling + Quit session wiring |

Provenance: squashed from the 18 commits of `feature/stream-posture-sync`
(`ea12abb4..6dfa16ee`): 12 posture commits become 0001-0004, 6 touch-menu
commits become 0005-0007. Applied onto
`ea12abb41914565db391a23e69cd7264b038edba` the result has the same git tree
(`10ffc5ef98d0351c52b984d421a431469be6f04a`) as the fork branch.

`ci/posture-windows` (the branch the installed Windows client was built from,
head `8e1dc629`) differs from `feature/stream-posture-sync` only by
`.github/workflows/posture-windows.yml` (a 17-line caller of
`build-win-mac.yml` with `ci_version: 6.2.0-daily.60006`, `build_macos: false`)
plus merge and "bump the Windows build number" commits. That workflow and the
`ci_version` strings are not part of the series; the pipeline generates them.

## Use

From a clone of the fork with the `upstream` remote fetched:

```
git remote add upstream https://github.com/Nonary/moonlight-qt.git
git fetch upstream master --tags

# apply onto a tag; leaves nothing behind
tools/apply-series.sh v6.2.0-daily.202

# prove it reproduces the reference tree
tools/apply-series.sh ea12abb4 --verify feature/stream-posture-sync

# without the touch menu
tools/apply-series.sh v6.2.0-daily.202 --skip-group touch-menu

# keep the result as a branch (what the build pipeline does)
tools/apply-series.sh v6.2.0-daily.202 --keep-branch build/v6.2.0-daily.202-n1

# rot matrix
tools/rot-matrix.sh 5 --floor v6.2.0-daily.201
```

POSIX bash; works in git-bash and on ubuntu runners (needs git with
`am --3way`, `worktree`, and `sha256sum`). Exit codes of `apply-series.sh`:
0 ok, 1 conflict, 2 tree mismatch, 3 usage/environment.

## Rules

* Patches never touch submodule gitlinks, `.github/` or version files.
* Version scheme: `ci_version = 6.2.0-daily.(60000+U)`, U = upstream daily
  number (see `policy.yml`).
* Rot: see `docs/RESOLVING-ROT.md`; current matrix:
  `docs/ROT-MATRIX-2026-11-22.md`.
* `.gitattributes` keeps `*.patch` byte-exact (no CRLF conversion on Windows).

## Series identity and tool behaviour

* `patch_series_sha256` (`tools/series-sha.sh`, same algorithm as the Vibepollo
  repo): sha256 over the bytes of `patches/series` with LF line endings,
  followed by the bytes of each patch listed in it (non-blank, non-`#` lines),
  in series order, unconverted. Group markers and comments are therefore part
  of the identity.
* Every patch is authored `emilwojcik93 <adminit@adar.pl>`.
* `apply-series.sh` uses `git am --3way --keep-cr`; `--keep-branch` creates the
  branch only after a successful apply and, with `--verify`, a matching tree.
  `--prefix-check` applies cumulatively, prints `prefix k/N OK|FAILS` and (with
  `--keep-branch NAME`) creates `NAME-p01..` so CI can build each prefix.
* `rot-matrix.sh --floor TAG`: targets older than the floor print
  `BELOW_FLOOR` (informational); any failure at or above the floor, including
  the newest tag and master, exits non-zero.
* `.gitattributes`: `* text=auto eol=lf`, patches and series `-text`.
* Tests: `tools/tests/test-tools.sh`.
