# Evaluated at discovery time (Pester -Skip is decided before BeforeAll runs): the process-level VerifyOnly/report-only
# tests need a recognisable installed Moonlight (6.2.6xxxx) because update.ps1 reads the real FileVersion (read-only).
$script:MoonlightKnown = $false
$mlExeForSkip = 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe'
if (Test-Path -LiteralPath $mlExeForSkip) {
    $viForSkip = (Get-Item -LiteralPath $mlExeForSkip).VersionInfo
    $script:MoonlightKnown = ($viForSkip.FileMajorPart -eq 6 -and $viForSkip.FileMinorPart -eq 2 -and $viForSkip.FileBuildPart -gt 60000 -and $viForSkip.FileBuildPart -lt 60200)
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'FixtureServer.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:Server = Start-FixtureServer
    $script:Roots = @()

    # stand-in gh: records its arguments and the GH_* environment it can see, fails when FAKEGH_FAIL is set
    $script:FakeGhBody = "@echo off`r`necho %*>>`"%FAKEGH_LOG%`"`r`nset GH_>>`"%FAKEGH_LOG%.env`"`r`nif defined FAKEGH_FAIL exit /b 1`r`nexit /b 0`r`n"

    function New-E2eCase {
        param([string]$Mode = 'install', [int]$InstalledBuild = 60006)
        $d = New-TestDirs
        $script:Roots += $d.Root
        '' | Set-Content -LiteralPath (Join-Path $d.Prog 'test-mode.flag')
        $gh = Join-Path $d.Prog 'gh.cmd'
        [IO.File]::WriteAllText($gh, $script:FakeGhBody, [Text.Encoding]::ASCII)
        $pin = @{ version = '2.105.0'; zip_name = 'gh_2.105.0_windows_amd64.zip'; zip_sha256 = ('0' * 64); gh_exe_sha256 = (Get-UpdSha256 -Path $gh) }
        ($pin | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $d.Prog 'gh-pin.json')
        $cfg = [ordered]@{
            schema = 1; mode = $Mode; channel = 'canary'; cooling_off_hours = 0
            api_base = $script:Server.Base; download_base = $script:Server.Base; allow_http = $true
            gh_path = $gh; data_dir = $d.Data; skip_acl_check = $true
        }
        ($cfg | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $d.Prog 'config.json')
        $stateFile = Join-Path $d.Root 'fakestate.txt'
        Set-Content -LiteralPath $stateFile -Value $InstalledBuild
        $baseline = Join-Path $d.Root 'baseline.exe'
        [IO.File]::WriteAllBytes($baseline, (New-DummyInstallerBytes -Build $InstalledBuild))
        return [pscustomobject]@{ Root = $d.Root; Prog = $d.Prog; Data = $d.Data; Sid = $d.Sid; State = $stateFile; Baseline = $baseline; GhLog = (Join-Path $d.Root 'gh.log') }
    }

    function Get-E2eInstalled { param($Case) if (Test-Path $Case.State) { return (Get-Content -LiteralPath $Case.State -Raw).Trim() } else { return $null } }

    function Invoke-E2eUpdate {
        param($Case, [switch]$VerifyOnly)
        $env:FAKE_STATE = $Case.State; $env:FAKEGH_LOG = $Case.GhLog
        $script:E2eStateFile = $Case.State
        Initialize-UpdLog -LogDir (Join-Path $Case.Data 'logs') -RunId 'e2e'
        $cfg = Read-UpdConfig -ProgramDir $Case.Prog
        $deps = New-UpdDeps -Config $cfg -ProgramDir $Case.Prog
        $deps.GetInstalledVersion = { if (Test-Path $script:E2eStateFile) { '6.2.{0}.0' -f (Get-Content -LiteralPath $script:E2eStateFile -Raw).Trim() } else { $null } }
        $deps.IsMoonlightRunning = { $false }
        $deps.GetPresence = { [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $true; Key = $true } }
        $deps.PackageCacheBundle = { $script:E2eBaseline }
        $script:E2eBaseline = $Case.Baseline
        $deps.TestPathAcl = { param($p) return @() }
        $deps.AdditionalFullControlSids = @($Case.Sid)
        $deps.Rollback = {
            param($prev, $failedPath, $failedSha, $runDir)
            Invoke-MoonlightRollback -Previous $prev -FailedBundlePath $failedPath -FailedSha256 $failedSha -RunDir $runDir -GetVersion { if (Test-Path $script:E2eStateFile) { '6.2.{0}.0' -f (Get-Content -LiteralPath $script:E2eStateFile -Raw).Trim() } else { $null } }
        }
        return (Invoke-MoonlightUpdate -ProgramDir $Case.Prog -DataDir $Case.Data -Config $cfg -Deps $deps -VerifyOnly:$VerifyOnly)
    }

    function New-E2eRelease { param([int]$U = 202, [int]$Rc = 0) return (New-FixtureRelease -U $U -N 1 -InstallerBytes (New-DummyInstallerBytes -Build (60000 + $U) -Rc $Rc)) }

    function Get-ServerRequests { return @($script:Server.Shared.Requests.ToArray()) }

    function Copy-Updater {
        param([string]$Dest)
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $UpdRoot 'update.ps1') -Destination $Dest
        Copy-Item -LiteralPath (Join-Path $UpdRoot 'lib') -Destination $Dest -Recurse
    }
}
AfterAll {
    Stop-FixtureServer -Server $script:Server
    Remove-Item Env:\FAKE_STATE, Env:\FAKEGH_LOG, Env:\FAKEGH_FAIL, Env:\FAKE_REFUSE_DOWNGRADE -ErrorAction SilentlyContinue
    foreach ($r in $script:Roots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'End to end over loopback HTTP (real download, real gh runner with a stand-in gh, real installer runner with a stand-in exe)' {
    BeforeEach { $script:Server.Shared.Mode = 'normal'; $script:Server.Shared.Requests.Clear(); Remove-Item Env:\FAKEGH_FAIL, Env:\FAKE_REFUSE_DOWNGRADE -ErrorAction SilentlyContinue }

    It 'full chain: policy pinned to the commit sha, anonymous requests, verify then install, token env scrubbed' {
        $env:GH_TOKEN = 'ghp_SHOULDNEVERREACHCHILD0123456789ab'
        try {
            $case = New-E2eCase
            $fx = New-E2eRelease -U 202
            Set-ServerReleases -Server $script:Server -Fixtures @($fx)
            $r = Invoke-E2eUpdate -Case $case
            $r.Result | Should -Be 'updated' -Because $r.Detail
            Get-E2eInstalled $case | Should -Be '60202'

            $req = Get-ServerRequests
            $api = @($req | Where-Object { $_.Path -like '/repos/*' })
            $api.Count | Should -Be 3
            $api[0].Path | Should -Match '/branches/automation$'
            $api[1].Path | Should -Match '/contents/policy.yml$'
            $api[2].Path | Should -Match '/releases$'
            $api[1].Query | Should -Be ('?ref=' + $script:Server.Shared.PolicySha)       # pinned to the commit sha from the branch call
            @($req | Where-Object { $_.Auth }).Count | Should -Be 0                         # anonymous
            @($req | Where-Object { $_.UA -notmatch '^MoonlightPatchUpdater/' }).Count | Should -Be 0
            $dl = @($req | Where-Object { $_.Path -like '*/releases/download/*' } | ForEach-Object { $_.Path.Split('/')[-1] })
            $dl | Should -Contain 'MoonlightSetup.exe'; $dl | Should -Contain 'manifest.json'; $dl | Should -Contain 'SHA256SUMS'; $dl | Should -Contain 'attestation.sigstore.json'

            $ghLines = @(Get-Content -LiteralPath $case.GhLog)
            $ghLines.Count | Should -Be 3                                                   # manifest, SHA256SUMS, installer
            foreach ($l in $ghLines) {
                $l | Should -Match '^attestation verify '
                $l | Should -Match '--repo emilwojcik93/moonlight-qt'
                $l | Should -Match '--signer-workflow github\.com/emilwojcik93/moonlight-qt/\.github/workflows/'
                $l | Should -Match ('--source-ref refs/heads/build/' + [regex]::Escape('v6.2.0-daily.202-n1'))
                $l | Should -Match '--deny-self-hosted-runners'
                $l | Should -Match '--bundle '
            }
            @($ghLines | Where-Object { $_ -match ('--source-digest ' + ('b' * 40)) }).Count | Should -Be 2   # SHA256SUMS + installer pinned to the attested source sha
            $envDump = Get-Content -LiteralPath ($case.GhLog + '.env') -Raw
            $envDump | Should -Not -Match 'SHOULDNEVERREACH'
            $envDump | Should -Not -Match 'GH_TOKEN'
            $envDump | Should -Match 'GH_CONFIG_DIR='

            $run = Get-ChildItem (Join-Path $case.Data 'updates') -Directory | Select-Object -First 1
            (Get-Content (Join-Path $run.FullName 'args.txt') -Raw).Trim() | Should -Match '^/install\|/quiet\|/norestart\|/log\|'
            $st = Read-UpdState -DataDir $case.Data
            $st.installed.tag | Should -Be $fx.Tag; $st.policy_sha | Should -Be $script:Server.Shared.PolicySha
            @(Get-VerifiedBundles -DataDir $case.Data | ForEach-Object Name) | Should -Contain 'installed-60006'
        } finally { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
    }

    It 'second run uses the ETag (If-None-Match) and is a noop' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 202))
        (Invoke-E2eUpdate -Case $case).Result | Should -Be 'updated'
        $script:Server.Shared.Requests.Clear()
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'noop'
        $first = @(Get-ServerRequests | Where-Object { $_.Path -like '*/releases' })[0]
        $first.IfNoneMatch | Should -Be $script:Server.Shared.ReleasesEtag
        $br = @(Get-ServerRequests | Where-Object { $_.Path -like '*/branches/automation' })[0]
        $br.IfNoneMatch | Should -Be ('"br-' + $script:Server.Shared.PolicySha + '"')
        @(Get-ServerRequests | Where-Object { $_.Path -like '*/contents/*' }).Count | Should -Be 0     # policy served from the per-sha cache
        Test-Path (Join-Path $case.Data ('cache\policy-' + $script:Server.Shared.PolicySha + '.yml')) | Should -BeTrue
        (Get-AllLogText $case.Data) | Should -Match 'from_cache="True"'
    }

    It 'tampered installer on the server: hash mismatch, nothing installed, installer never executed' {
        $case = New-E2eCase
        $fx = New-E2eRelease -U 203
        Set-ServerReleases -Server $script:Server -Fixtures @($fx)
        $evil = $fx.Files['MoonlightSetup.exe'].Clone(); $evil[200] = $evil[200] -bxor 0xFF
        $script:Server.Shared.Files[($fx.Tag + '/MoonlightSetup.exe')] = $evil
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'verify_failed'; $r.ExitCode | Should -Be 4
        Get-E2eInstalled $case | Should -Be '60006'
        @(Get-ChildItem (Join-Path $case.Data 'updates') -Recurse -Filter 'args.txt').Count | Should -Be 0
    }

    It 'attestation verification failure (stand-in gh exits 1): nothing installed' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 204))
        $env:FAKEGH_FAIL = '1'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'verify_failed'
        Get-E2eInstalled $case | Should -Be '60006'
        @(Get-ChildItem (Join-Path $case.Data 'updates') -Recurse -Filter 'args.txt').Count | Should -Be 0
    }

    It 'API rate limit: deferred (exit 8), no download' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 205))
        $script:Server.Shared.Mode = 'ratelimit'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'deferred'; $r.ExitCode | Should -Be 8
        @(Get-ServerRequests | Where-Object { $_.Path -like '*/releases/download/*' }).Count | Should -Be 0
    }

    It 'oversized API body is capped, nothing happens' {
        $case = New-E2eCase
        $script:Server.Shared.Mode = 'bigbody'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Not -Be 'updated'
        Get-E2eInstalled $case | Should -Be '60006'
    }

    It 'download that redirects to a non-allow-listed host is refused' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 206))
        # let API calls through, redirect only the downloads
        $script:Server.Shared.Mode = 'redirect-evil'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Not -Be 'updated'
        Get-E2eInstalled $case | Should -Be '60006'
    }

    It 'installer exit code 1603: health check fails, real rollback re-installs the previous bundle (install-over)' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 207 -Rc 1603))
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'rolled_back'; $r.ExitCode | Should -Be 5
        Get-E2eInstalled $case | Should -Be '60006'
        Test-LocallyDenied -State (Read-UpdState -DataDir $case.Data) -Tag 'v6.2.0-daily.207-vp.1' | Should -BeTrue
        $l = Get-AllLogText $case.Data
        $l | Should -Match 'event=rolled_back'; $l | Should -Match 'method="install-over"'
    }

    It 'installer that refuses a downgrade: rollback uninstalls the failed bundle then installs the previous one' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 208 -Rc 1603))
        $env:FAKE_REFUSE_DOWNGRADE = '1'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'rolled_back'
        Get-E2eInstalled $case | Should -Be '60006'
        (Get-AllLogText $case.Data) | Should -Match 'method="uninstall-then-install"'
    }

    It 'no log of any e2e run contains BEGIN PRIVATE KEY / BEGIN CERTIFICATE' {
        foreach ($c in $script:Roots) { (Get-AllLogText $c) | Should -Not -Match 'BEGIN (PRIVATE KEY|CERTIFICATE)' }
    }
}

Describe 'update.ps1 as a process' {
    BeforeAll {
    }
    BeforeEach { $script:Server.Shared.Mode = 'normal'; Remove-Item Env:\FAKEGH_FAIL -ErrorAction SilentlyContinue }

    It 'ACL self-check: a user-writable program dir aborts with exit 2 and touches nothing' {
        $root = New-TestRoot; $script:Roots += $root
        $dest = Join-Path $root 'prog'; Copy-Updater -Dest $dest
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'update.ps1') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'MLUPD_RESULT=failed'
        $out | Should -Match 'ACL self-check failed'
    }
    It 'ACL self-check also fires from the writable *file* even when the flag file exists but skip_acl_check is absent' {
        $root = New-TestRoot; $script:Roots += $root
        $dest = Join-Path $root 'prog'; Copy-Updater -Dest $dest
        '' | Set-Content (Join-Path $dest 'test-mode.flag')
        '{"schema":1,"mode":"install"}' | Set-Content (Join-Path $dest 'config.json')
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'update.ps1') 2>&1
        $LASTEXITCODE | Should -Be 2
    }
    It 'environment variables can not enable test mode / skip the ACL check' {
        $root = New-TestRoot; $script:Roots += $root
        $dest = Join-Path $root 'prog'; Copy-Updater -Dest $dest
        $env:MLU_TEST_MODE = '1'; $env:MLU_SKIP_ACL_CHECK = '1'; $env:TEST_MODE = '1'
        try { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'update.ps1') 2>&1 } finally { Remove-Item Env:\MLU_TEST_MODE, Env:\MLU_SKIP_ACL_CHECK, Env:\TEST_MODE -ErrorAction SilentlyContinue }
        $LASTEXITCODE | Should -Be 2
    }
    It 'invalid config.json (test-mode, ACL bypass) => exit 3' {
        $root = New-TestRoot; $script:Roots += $root
        $dest = Join-Path $root 'prog'; Copy-Updater -Dest $dest
        '' | Set-Content (Join-Path $dest 'test-mode.flag')
        '{"schema":1,"mode":"install","skip_acl_check":true,"cooling_off_hours":"lots"}' | Set-Content (Join-Path $dest 'config.json')
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'update.ps1') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 3
        $out | Should -Match 'config invalid'
    }
    It 'local mode=hold => MLUPD_RESULT=held, exit 0' {
        $case = New-E2eCase -Mode 'hold'
        Copy-Updater -Dest $case.Prog
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $case.Prog 'update.ps1') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'MLUPD_RESULT=held'
    }
    It 'single instance: a held mutex => exit 7' {
        $case = New-E2eCase -Mode 'hold'
        Copy-Updater -Dest $case.Prog
        $m = Enter-UpdMutex
        try {
            $m | Should -Not -BeNullOrEmpty
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $case.Prog 'update.ps1') 2>&1
            $LASTEXITCODE | Should -Be 7
        } finally { Exit-UpdMutex -Mutex $m }
    }
    It 'VerifyOnly through the real script, loopback feed and stand-in gh => verified, exit 0, nothing installed' -Skip:(-not $script:MoonlightKnown) {
        $case = New-E2eCase -Mode 'install'
        Copy-Updater -Dest $case.Prog
        $fx = New-E2eRelease -U 209
        Set-ServerReleases -Server $script:Server -Fixtures @($fx)
        $env:FAKEGH_LOG = $case.GhLog
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $case.Prog 'update.ps1') -VerifyOnly 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'MLUPD_RESULT=verified'
        @(Get-ChildItem (Join-Path $case.Data 'updates') -Recurse -Filter 'args.txt').Count | Should -Be 0
        (Get-AllLogText $case.Data) | Should -Match 'event=hash_ok'
    }
    It 'report-only through the real script: no download, exit 0' -Skip:(-not $script:MoonlightKnown) {
        $case = New-E2eCase -Mode 'report-only'
        Copy-Updater -Dest $case.Prog
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 210))
        $script:Server.Shared.Requests.Clear()
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $case.Prog 'update.ps1') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'MLUPD_RESULT=report-only'
        @(Get-ServerRequests | Where-Object { $_.Path -like '*/releases/download/*' }).Count | Should -Be 0
    }
}

Describe 'install-task.ps1 / uninstall-task.ps1 -WhatIf (no elevation, no changes)' {
    It 'install-task -WhatIf prints the exact plan and changes nothing' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'WHATIF: nothing will be changed'
        $out | Should -Match 'C:\\Program Files\\MoonlightPatchUpdater'
        $out | Should -Match 'C:\\ProgramData\\MoonlightPatchUpdater'
        $out | Should -Match 'NT AUTHORITY\\SYSTEM'
        $out | Should -Match '\\MoonlightPatch\\Update'
        $out | Should -Match 'AtLogOn'
        $out | Should -Match 'Daily at 04:17'
        $out | Should -Match 'every 6 hours'
        $out | Should -Match 'ExecutionTimeLimit PT30M'
        $out | Should -Match 'default report-only'
        $out | Should -Match 'WhatIf: no changes made'
        Test-Path 'C:\Program Files\MoonlightPatchUpdater' | Should -BeFalse
        Test-Path 'C:\ProgramData\MoonlightPatchUpdater' | Should -BeFalse
        @(Get-ScheduledTask -TaskPath '\MoonlightPatch\' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'install-task -WhatIf -SetWebhook -RunAt 05:30 reflects the options' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf -SetWebhook -RunAt 05:30 2>&1 | Out-String
        $out | Should -Match 'Daily at 05:30'
        $out | Should -Match 'gchat-webhook\.dpapi'
    }
    It 'install-task rejects a malformed RunAt' {
        $ErrorActionPreference = 'Continue'
        $null =& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf -RunAt '25:99; calc' 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }
    It 'install-task without -WhatIf refuses to run unelevated (and changes nothing)' {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) { Set-ItResult -Skipped -Because 'session is elevated: would really install'; return }
        $ErrorActionPreference = 'Continue'
        $out =& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'elevated'
        Test-Path 'C:\Program Files\MoonlightPatchUpdater' | Should -BeFalse
    }
    It 'uninstall-task -WhatIf lists what would be removed and changes nothing' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'uninstall-task.ps1') -WhatIf -RemoveFiles -RemoveData 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Unregister scheduled task \\MoonlightPatch\\Update'
        $out | Should -Match 'Delete directory C:\\Program Files\\MoonlightPatchUpdater'
        $out | Should -Match 'Delete directory C:\\ProgramData\\MoonlightPatchUpdater'
        $out | Should -Match 'Moonlight, its settings and its registry key are not touched'
    }
}
