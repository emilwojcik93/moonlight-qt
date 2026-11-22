# Moonlight patch updater (Windows, ROG Ally X)

Scheduled-task updater for the patched Moonlight feed `emilwojcik93/moonlight-qt` (tags `v6.2.0-daily.U-vp.N`,
see the release-feed CONTRACT). It runs as SYSTEM, verifies a release end to end, installs `MoonlightSetup.exe` only when
Moonlight is idle, health-checks, and rolls back on failure. Default mode after installation is **report-only**: nothing is
installed until you switch `config.json` to `install` (human gate G4).

```
updater/
  update.ps1                 entry point (scheduled task action)
  install-task.ps1           elevated installer: files, ACLs, gh.exe, config, task   (-WhatIf prints the exact plan)
  uninstall-task.ps1         removes the task (and optionally files/data)            (-WhatIf supported)
  gh-pin.json                pinned gh.exe (version + SHA256 of zip and exe)
  lib/*.ps1                  Common, Version, Yaml, Config, Security, GitHub, Verify, Install, Notify, Orchestrator, Snappy
  tests/*.Tests.ps1          Pester v5 suite (sandbox only); tests/U3-SystemProbe.ps1 = research probe, run as SYSTEM
  docs/UPDATER.md            design, security model, config, exit codes, U3 answer, enablement steps
  PSScriptAnalyzerSettings.psd1
```

* Windows PowerShell 5.1 compatible (also tested on PowerShell 7), strict mode, no `Invoke-Expression`, every value that
  reaches a command line is regex-validated and passed as an argument array (no shell).
* Program dir `C:\Program Files\MoonlightPatchUpdater\` (admin-only), data dir `C:\ProgramData\MoonlightPatchUpdater\`
  (SYSTEM + Administrators only, inheritance removed); the script aborts at start when either is writable by anyone else.
* Task `\MoonlightPatch\Update`: SYSTEM, triggers at logon + daily 04:17 + every 6 h, 30 min time limit, single instance.

Run the tests (needs Pester 5; `-IncludeNetwork` adds the anonymous GitHub/Sigstore checks):

```powershell
powershell -NoProfile -File .\tests\Invoke-Tests.ps1                # add -ModulePath <dir with Pester 5> if needed
powershell -NoProfile -File .\tests\Invoke-Tests.ps1 -IncludeNetwork
```

Everything about how it works, what it trusts, and how to enable it is in [docs/UPDATER.md](docs/UPDATER.md).
