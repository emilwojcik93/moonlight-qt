# Rot matrix 2026-11-27 (series of 9 patches)

Series: 9 patches (posture-core 0001-0004, touch-menu 0005-0007, display 0008-0009),
`patch_series_sha256 = fae184b99cb2a13e8eca285722e26cf55e8d63b19da53938f1bfb805c34d5042`
(see `tools/series-sha.sh`). Floor: `v6.2.0-daily.201`.

| target | commit | full series | notes |
|---|---|---|---|
| v6.2.0-daily.202 | 9184cacd | PASS | |
| v6.2.0-daily.201 | bbe6d2d3 | PASS | |
| v6.2.0-daily.200 | f586143c | BELOW_FLOOR | as before |
| upstream/master | c4bc7097 | **FAIL** | 0009 conflicts in `app/streaming/session.cpp`; 0001-0008 apply |

"posture-only" (`--skip-group touch-menu`) fails on 0009 for every target: the display group needs
touch-menu (context in `streamingpreferences.h`). Skip both groups together if a degraded build is ever needed.

## Known rot on upstream master (next release after daily.202)

Upstream master added per-app video settings: `Session` now holds
`m_RequestedVideo = m_Preferences->videoSettingsForApp(...)` (resolution, fps, bitrate, HDR) and uses it where
the series reads `m_Preferences->width/height/fps/bitrateKbps` (`Session::initialize`, notch handling,
VRR snapshot). Patch 0009 has to be remade on top of that: compute the adapted mode from `m_RequestedVideo`
as the reference, decide whether a per-app override should win over "Adapt to the display", and keep the
settings page preview in `backend/displayadapt.cpp` consistent. Reference implementation:
`feature/stream-posture-sync` of the fork at `520676d2` (tests in `tests/posture`).
Procedure: `docs/RESOLVING-ROT.md`.
