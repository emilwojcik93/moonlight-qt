BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'FixtureServer.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:Server = Start-FixtureServer
    $script:Roots = @()

    # stand-in gh: records its arguments and the GH_* environment it can see, fails when FAKEGH_FAIL is set
    $script:FakeGhBody = "@echo off`r`necho %*>>`"%FAKEGH_LOG%`"`r`nset GH_>>`"%FAKEGH_LOG%.env`"`r`nif defined FAKEGH_FAIL exit /b 1`r`nexit /b 0`r`n"

    # All injection happens HERE, in memory (config hashtable + dependency table); the product has no test mode, flag file or config override.
    function New-E2eCase {
        param([string]$Mode = 'install', [int]$InstalledBuild = 60006)
        $d = New-TestDirs
        $script:Roots += $d.Root
        $gh = Join-Path $d.Root 'gh.cmd'
        [IO.File]::WriteAllText($gh, $script:FakeGhBody, [Text.Encoding]::ASCII)
        $stateFile = Join-Path $d.Root 'fakestate.txt'
        Set-Content -LiteralPath $stateFile -Value $InstalledBuild
        $baseline = Join-Path $d.Root 'baseline.exe'
        [IO.File]::WriteAllBytes($baseline, (New-DummyInstallerBytes -Build $InstalledBuild))
        return [pscustomobject]@{ Root = $d.Root; Prog = $d.Prog; Data = $d.Data; Sid = $d.Sid; State = $stateFile; Baseline = $baseline; GhLog = (Join-Path $d.Root 'gh.log'); Gh = $gh; Mode = $Mode }
    }

    function New-E2eConfig {
        param($Case, [hashtable]$Override = @{})
        $cfg = New-TestConfig -Override @{ mode = $Case.Mode; api_base = $script:Server.Base; download_base = $script:Server.Base; allow_http = $true }
        foreach ($k in $Override.Keys) { $cfg[$k] = $Override[$k] }
        return $cfg
    }

    function New-E2eDeps {
        param($Case, [hashtable]$Config)
        $env:FAKE_STATE = $Case.State; $env:FAKEGH_LOG = $Case.GhLog
        $script:E2eStateFile = $Case.State; $script:E2eBaseline = $Case.Baseline; $script:E2eGh = $Case.Gh
        $deps = New-UpdDeps -Config $Config -ProgramDir $Case.Prog
        $deps.GhPath = $Case.Gh
        $deps.AssertGh = { param($gh, $p) if (-not (Test-Path -LiteralPath $gh)) { throw 'gh missing' } }
        $deps.GetInstalledVersion = { if (Test-Path $script:E2eStateFile) { '6.2.{0}.0' -f (Get-Content -LiteralPath $script:E2eStateFile -Raw).Trim() } else { $null } }
        $deps.IsMoonlightRunning = { $false }
        $deps.GetPresence = { [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $true; Key = $true } }
        $deps.PackageCacheBundle = { $script:E2eBaseline }
        $deps.TestPathAcl = { param($p) return @() }
        $deps.Sleep = { param($s) }
        $deps.GetBootTime = { (Get-Date).ToUniversalTime().AddDays(-1) }
        $deps.AdditionalFullControlSids = @($Case.Sid)
        $deps.Rollback = {
            param($prev, $failedPath, $failedSha, $runDir, $idle)
            Invoke-MoonlightRollback -Previous $prev -FailedBundlePath $failedPath -FailedSha256 $failedSha -RunDir $runDir -IdleCheck $idle -GetVersion { if (Test-Path $script:E2eStateFile) { '6.2.{0}.0' -f (Get-Content -LiteralPath $script:E2eStateFile -Raw).Trim() } else { $null } }
        }
        return $deps
    }

    function Get-E2eInstalled { param($Case) if (Test-Path $Case.State) { return (Get-Content -LiteralPath $Case.State -Raw).Trim() } else { return $null } }

    function Invoke-E2eUpdate {
        param($Case, [switch]$VerifyOnly, [hashtable]$ConfigOverride = @{})
        Initialize-UpdLog -LogDir (Join-Path $Case.Data 'logs') -RunId 'e2e'
        $cfg = New-E2eConfig -Case $Case -Override $ConfigOverride
        $deps = New-E2eDeps -Case $Case -Config $cfg
        return (Invoke-MoonlightUpdate -ProgramDir $Case.Prog -DataDir $Case.Data -Config $cfg -Deps $deps -VerifyOnly:$VerifyOnly)
    }

    function New-E2eRelease { param([int]$U = 202, [int]$N = 1, [int]$Rc = 0) return (New-FixtureRelease -U $U -N $N -InstallerBytes (New-DummyInstallerBytes -Build (ConvertTo-BuildNumber -U $U -N $N) -Rc $Rc)) }

    function Get-ServerRequests { return @($script:Server.Shared.Requests.ToArray()) }
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
            Get-E2eInstalled $case | Should -Be '61616'

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
            # order: the installer is requested only after the small files
            [array]::IndexOf($dl, 'MoonlightSetup.exe') | Should -BeGreaterThan ([array]::IndexOf($dl, 'manifest.json'))

            $ghLines = @(Get-Content -LiteralPath $case.GhLog)
            $ghLines.Count | Should -Be 3                                                   # manifest, SHA256SUMS, installer
            foreach ($l in $ghLines) {
                $l | Should -Match '^attestation verify '
                $l | Should -Match '--repo emilwojcik93/moonlight-qt'
                $l | Should -Match '--signer-workflow github\.com/emilwojcik93/moonlight-qt/\.github/workflows/'
                $l | Should -Match ('--source-ref refs/heads/build/' + [regex]::Escape('v6.2.0-daily.202-n1'))
                $l | Should -Match '--deny-self-hosted-runners'
                $l | Should -Match '--predicate-type https://slsa.dev/provenance/v1'
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

    It 'tampered installer on the server: size/hash mismatch, nothing installed, installer never executed' {
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

    It 'truncated installer (shorter than the manifest size) is rejected at download time' {
        $case = New-E2eCase
        $fx = New-E2eRelease -U 204
        Set-ServerReleases -Server $script:Server -Fixtures @($fx)
        $script:Server.Shared.Files[($fx.Tag + '/MoonlightSetup.exe')] = $fx.Files['MoonlightSetup.exe'][0..1000]
        $r = Invoke-E2eUpdate -Case $case
        $r.ExitCode | Should -BeIn @(4, 8)
        Get-E2eInstalled $case | Should -Be '60006'
        @(Get-ChildItem (Join-Path $case.Data 'updates') -Recurse -Filter 'args.txt').Count | Should -Be 0
    }

    It 'attestation verification failure (stand-in gh exits 1): nothing installed, installer not even downloaded when the manifest fails' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 205))
        $env:FAKEGH_FAIL = '1'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'verify_failed'
        Get-E2eInstalled $case | Should -Be '60006'
        @(Get-ServerRequests | Where-Object { $_.Path -like '*/MoonlightSetup.exe' }).Count | Should -Be 0
    }

    It 'API rate limit: deferred (exit 8), no download' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 206))
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

    It 'download that redirects to a non-allow-listed host is refused before that host is contacted' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 207))
        $script:Server.Shared.Mode = 'redirect-evil'
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Not -Be 'updated'
        Get-E2eInstalled $case | Should -Be '60006'
    }

    It 'installer exit code 1603: first failure rolls back with the real rollback code (install-over); not denied yet' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 208 -Rc 1603))
        $r = Invoke-E2eUpdate -Case $case
        $r.Result | Should -Be 'rolled_back'; $r.ExitCode | Should -Be 5
        Get-E2eInstalled $case | Should -Be '60006'
        Test-LocallyDenied -State (Read-UpdState -DataDir $case.Data) -Tag 'v6.2.0-daily.208-vp.1' | Should -BeFalse
        $l = Get-AllLogText $case.Data
        $l | Should -Match 'event=rolled_back'; $l | Should -Match 'method="install-over"'
    }

    It 'installer that refuses a downgrade: rollback uninstalls the failed bundle then installs the previous one' {
        $case = New-E2eCase
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 209 -Rc 1603))
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

Describe 'Invoke-UpdaterMain / update.ps1 (no test mode exists in the product)' {
    BeforeEach { $script:Server.Shared.Mode = 'normal'; Remove-Item Env:\FAKEGH_FAIL -ErrorAction SilentlyContinue }

    It 'update.ps1 in a user-writable program dir aborts with exit 2 (ACL self-check) and touches nothing' {
        $ErrorActionPreference = 'Continue'
        $root = New-TestRoot; $script:Roots += $root
        $dest = Join-Path $root 'prog'; New-Item -ItemType Directory -Path $dest | Out-Null
        Copy-Item -LiteralPath (Join-Path $UpdRoot 'update.ps1') -Destination $dest
        Copy-Item -LiteralPath (Join-Path $UpdRoot 'lib') -Destination $dest -Recurse
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'update.ps1') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $out | Should -Match 'MLUPD_RESULT=failed'
        $out | Should -Match 'ACL self-check failed'
    }
    It 'a stale test-mode.flag, a config with override keys and environment variables change nothing: still exit 2' {
        $ErrorActionPreference = 'Continue'
        $root = New-TestRoot; $script:Roots += $root
        $dest = Join-Path $root 'prog'; New-Item -ItemType Directory -Path $dest | Out-Null
        Copy-Item -LiteralPath (Join-Path $UpdRoot 'update.ps1') -Destination $dest
        Copy-Item -LiteralPath (Join-Path $UpdRoot 'lib') -Destination $dest -Recurse
        '' | Set-Content (Join-Path $dest 'test-mode.flag')
        '{"schema":1,"mode":"install","skip_acl_check":true,"data_dir":"C:\\x"}' | Set-Content (Join-Path $dest 'config.json')
        $env:MLU_TEST_MODE = '1'; $env:MLU_SKIP_ACL_CHECK = '1'; $env:TEST_MODE = '1'
        try { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'update.ps1') 2>&1 } finally { Remove-Item Env:\MLU_TEST_MODE, Env:\MLU_SKIP_ACL_CHECK, Env:\TEST_MODE -ErrorAction SilentlyContinue }
        $LASTEXITCODE | Should -Be 2
    }
    It 'the product source contains no test-mode / ACL-skip / path-override seam' {
        foreach ($f in @(Get-ChildItem (Join-Path $UpdRoot 'lib') -Filter *.ps1) + @(Get-Item (Join-Path $UpdRoot 'update.ps1'))) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $t | Should -Not -Match 'test-mode|test_mode|skip_acl_check|gh_path' -Because $f.Name
        }
    }
    It 'install-task.ps1 copies exactly update.ps1, gh-pin.json and lib\*.ps1: no seam, test or fixture file can be shipped' {
        $libNames = @(Get-ChildItem (Join-Path $UpdRoot 'lib') -File | ForEach-Object Name)
        foreach ($n in $libNames) { $n | Should -Not -Match '(?i)seam|test|fixture|fake' }
        $t = [IO.File]::ReadAllText((Join-Path $UpdRoot 'install-task.ps1'))
        $t | Should -Match "Get-ChildItem -LiteralPath \(Join-Path \`$SourceDir 'lib'\) -Filter '\*\.ps1'"
        $t | Should -Not -Match 'tests'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf 2>&1 | Out-String
        $out | Should -Match ('Copy update.ps1, gh-pin.json and ' + $libNames.Count + ' lib')
        $out | Should -Not -Match '(?i)seam|fixture|Tests\.ps1'
    }
    It 'invalid config.json (override key) => exit 3 through the real config reader' {
        $case = New-E2eCase
        '{"schema":1,"mode":"install","api_base":"http://127.0.0.1:1"}' | Set-Content (Join-Path $case.Prog 'config.json')
        $r = Invoke-UpdaterMain -ProgramDir $case.Prog -DataDir $case.Data -AclCheck { } -MutexName ('Global\MlUpdTest' + [guid]::NewGuid().ToString('N'))
        $r.ExitCode | Should -Be 3
        $r.Line | Should -Match 'unknown config key'
    }
    It 'missing data dir => exit 3' {
        $case = New-E2eCase
        $r = Invoke-UpdaterMain -ProgramDir $case.Prog -DataDir (Join-Path $case.Root 'nope') -AclCheck { }
        $r.ExitCode | Should -Be 3
    }
    It 'ACL check failing in-process => exit 2' {
        $case = New-E2eCase
        $r = Invoke-UpdaterMain -ProgramDir $case.Prog -DataDir $case.Data -AclCheck { throw 'ACL self-check failed: x' }
        $r.ExitCode | Should -Be 2
    }
    It 'local mode=hold => MLUPD_RESULT=held, exit 0' {
        $case = New-E2eCase -Mode 'hold'
        $cfg = New-E2eConfig -Case $case
        $r = Invoke-UpdaterMain -ProgramDir $case.Prog -DataDir $case.Data -Config $cfg -Deps (New-E2eDeps -Case $case -Config $cfg) -AclCheck { } -MutexName ('Global\MlUpdTest' + [guid]::NewGuid().ToString('N'))
        $r.ExitCode | Should -Be 0
        $r.Line | Should -Match 'MLUPD_RESULT=held'
    }
    It 'single instance: while another thread holds the mutex, Invoke-UpdaterMain returns exit 7' {
        $case = New-E2eCase -Mode 'hold'
        $name = 'Global\MlUpdTest' + [guid]::NewGuid().ToString('N')
        $m = Enter-UpdMutex -Name $name
        try {
            $ps = [powershell]::Create()
            $null = $ps.AddScript({
                    param($root, $libs, $prog, $data, $mname)
                    foreach ($f in $libs) { . (Join-Path $root "lib\$f.ps1") }
                    Invoke-UpdaterMain -ProgramDir $prog -DataDir $data -Config @{ mode = 'hold' } -AclCheck { } -MutexName $mname
                }).AddArgument($UpdRoot).AddArgument($LibFiles).AddArgument($case.Prog).AddArgument($case.Data).AddArgument($name)
            $r = $ps.Invoke() | Select-Object -Last 1
            $ps.Dispose()
            $r.ExitCode | Should -Be 7
            $r.Line | Should -Match 'another instance is running'
        } finally { Exit-UpdMutex -Mutex $m }
    }
    It 'VerifyOnly through Invoke-UpdaterMain: verified, exit 0, nothing installed' {
        $case = New-E2eCase -Mode 'install'
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 210))
        $cfg = New-E2eConfig -Case $case
        $r = Invoke-UpdaterMain -ProgramDir $case.Prog -DataDir $case.Data -Config $cfg -Deps (New-E2eDeps -Case $case -Config $cfg) -AclCheck { } -VerifyOnly -MutexName ('Global\MlUpdTest' + [guid]::NewGuid().ToString('N'))
        $r.ExitCode | Should -Be 0
        $r.Line | Should -Match 'MLUPD_RESULT=verified'
        Get-E2eInstalled $case | Should -Be '60006'
        @(Get-ChildItem (Join-Path $case.Data 'updates') -Recurse -Filter 'args.txt').Count | Should -Be 0
    }
    It 'report-only through Invoke-UpdaterMain: no download, exit 0' {
        $case = New-E2eCase -Mode 'report-only'
        Set-ServerReleases -Server $script:Server -Fixtures @((New-E2eRelease -U 211))
        $script:Server.Shared.Requests.Clear()
        $cfg = New-E2eConfig -Case $case
        $r = Invoke-UpdaterMain -ProgramDir $case.Prog -DataDir $case.Data -Config $cfg -Deps (New-E2eDeps -Case $case -Config $cfg) -AclCheck { } -MutexName ('Global\MlUpdTest' + [guid]::NewGuid().ToString('N'))
        $r.Line | Should -Match 'MLUPD_RESULT=report-only'
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
        $out | Should -Match 'ExecutionTimeLimit PT2H'
        $out | Should -Match 'new installs: report-only'
        $out | Should -Match 'stale .*test-mode\.flag'
        $out | Should -Match 'WhatIf: no changes made'
        Test-Path 'C:\Program Files\MoonlightPatchUpdater' | Should -BeFalse
        Test-Path 'C:\ProgramData\MoonlightPatchUpdater' | Should -BeFalse
        @(Get-ScheduledTask -TaskPath '\MoonlightPatch\' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'the registered task limit really is 2 hours' {
        [IO.File]::ReadAllText((Join-Path $UpdRoot 'install-task.ps1')) | Should -Match 'ExecutionTimeLimit \(New-TimeSpan -Hours 2\)'
    }
    It 'install-task -WhatIf -SetWebhook -RunAt 05:30 reflects the options' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf -SetWebhook -RunAt 05:30 2>&1 | Out-String
        $out | Should -Match 'Daily at 05:30'
        $out | Should -Match 'gchat-webhook\.dpapi'
    }
    It 'install-task rejects a malformed RunAt' {
        $ErrorActionPreference = 'Continue'
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf -RunAt '25:99; calc' 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }
    It '-SetMode install is refused on a fresh machine (rehearse in report-only first)' {
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') -WhatIf -SetMode install 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'refusing -SetMode install on a fresh machine'
    }
    It 'install-task without -WhatIf refuses to run unelevated (and changes nothing)' {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) { Set-ItResult -Skipped -Because 'session is elevated: would really install'; return }
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $UpdRoot 'install-task.ps1') 2>&1 | Out-String
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
