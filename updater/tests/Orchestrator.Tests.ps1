BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:AllRoots = @()
    function New-Case {
        $d = New-TestDirs
        $script:AllRoots += $d.Root
        return $d
    }
    function Get-Calls($ctx) { return @($ctx.Calls) }
    function Test-NothingInstalled($ctx) { return -not (@($ctx.Calls) -match '^RunInstaller') }
}
AfterAll { foreach ($r in $script:AllRoots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'Happy path' {
    It 'downloads, verifies, installs, health-checks and records state' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $fx = New-FixtureRelease -U 202 -N 1
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'updated'; $r.ExitCode | Should -Be 0; $r.Tag | Should -Be $fx.Tag
        $ctx.Installed | Should -Be '6.2.61616.0'
        $c = Get-Calls $ctx
        $c | Should -Contain 'Download:manifest.json'
        $c | Should -Contain 'Verify:manifest.json'
        $c | Should -Contain 'Verify:SHA256SUMS'
        $c | Should -Contain 'Verify:MoonlightSetup.exe'
        $c | Should -Contain 'RunInstaller:install'
        # order: all verification before the installer
        ([array]::IndexOf($c, 'RunInstaller:install')) | Should -BeGreaterThan ([array]::IndexOf($c, 'Verify:MoonlightSetup.exe'))
        $st = Read-UpdState -DataDir $d.Data
        $st.installed.tag | Should -Be $fx.Tag; $st.installed.u | Should -Be 202; $st.installed.n | Should -Be 1
        (Get-VerifiedBundles -DataDir $d.Data | ForEach-Object Name) | Should -Contain $fx.Tag
        $ctx.Notified | Should -Contain ('updated|' + $fx.Tag)
        $logs = Get-AllLogText $d.Data
        $logs | Should -Match 'event=health_ok'
        $logs | Should -Match 'event=presence_after'
    }
    It 'a second run is a noop (state N recorded, nothing newer)' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $fx = New-FixtureRelease -U 202 -N 1
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        $ctx.Calls.Clear()
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'noop'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'reboot-pending exit code 3010 counts as success' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'reboot'
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202))).Result | Should -Be 'updated'
    }
    It 'saves a rollback baseline from the installed bundle (package cache) before installing' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202)))
        (Get-VerifiedBundles -DataDir $d.Data | ForEach-Object Name) | Should -Contain 'installed-60006'
    }
}

Describe 'Modes' {
    It 'hold (local): nothing happens, no network' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ mode = 'hold' } -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'held'; $ctx.Calls.Count | Should -Be 0
    }
    It 'report-only: selects, reports, downloads nothing, installs nothing' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ mode = 'report-only' } -Fixtures @($fx)
        $r.Result | Should -Be 'report-only'; $r.Tag | Should -Be $fx.Tag
        (@($ctx.Calls) -match '^(Download|RunInstaller|Verify)').Count | Should -Be 0
    }
    It 'command-line override cannot escalate report-only to install' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ mode = 'report-only' } -ModeOverride 'install' -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'report-only'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'VerifyOnly downloads and verifies but never installs' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -VerifyOnly -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'verified'
        $ctx.Calls | Should -Contain 'Verify:MoonlightSetup.exe'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'policy hold=true blocks installation' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Policy = New-DefaultPolicy -Hold $true
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'held'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
}

Describe 'Idle check' {
    It 'Moonlight.exe running => deferred, exit 0, nothing downloaded or installed' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Running = $true
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'deferred'; $r.ExitCode | Should -Be 0
        (@($ctx.Calls) -match '^(Download|RunInstaller|GetReleases)').Count | Should -Be 0
        (Get-AllLogText $d.Data) | Should -Match 'Moonlight.exe is running'
    }
    It 'Moonlight started after the download: second idle check defers, installer never starts' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Running = $false; $ctx.RunningAfter = $true
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'deferred'; $r.ExitCode | Should -Be 0
        Test-NothingInstalled $ctx | Should -BeTrue
        $ctx.Installed | Should -Be '6.2.60006.0'
    }
}

Describe 'Version rules' {
    It 'refuses downgrade: installed newer than every release => noop' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.62000.0'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202), (New-FixtureRelease -U 201))
        $r.Result | Should -Be 'noop'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'a rebuild N+1 of the same U has its own build number and installs (CONTRACT 3b)' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.61616.0'         # U202 N1
        $fx = New-FixtureRelease -U 202 -N 2                               # B 61617
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'updated'
        $ctx.Installed | Should -Be '6.2.61617.0'
    }
    It 'the installed build itself and lower rebuilds are not newer: noop' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.61617.0'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202 -N 2), (New-FixtureRelease -U 202 -N 1))
        $r.Result | Should -Be 'noop'
        (Get-AllLogText $d.Data) | Should -Match 'not newer than installed'
    }
    It 'legacy installed 6.2.60006 is upgraded by a 3b build without any special case' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202 -N 1))).Result | Should -Be 'updated'
    }
    It 'no Moonlight installed => noop (first install is manual)' {
        $d = New-Case; $ctx = New-FakeCtx -Installed ''
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))).Result | Should -Be 'noop'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'prefers the newest eligible, ignoring older ones' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 200), (New-FixtureRelease -U 203), (New-FixtureRelease -U 202))
        $r.Tag | Should -Be 'v6.2.0-daily.203-vp.1'
    }
}

Describe 'Malicious tags and names' {
    It 'tags that fail the regex never reach download or install' {
        $d = New-Case; $ctx = New-FakeCtx
        $good = New-FixtureRelease -U 202
        $evil = @('v6.2.0-daily.999-vp.1$(calc)', "v6.2.0-daily.999-vp.1`nGH_TOKEN=x", '../../v6.2.0-daily.999-vp.1', 'v6.2.0-daily.999-vp.1; calc', 'v6.2.0-daily.99999-vp.999999') | ForEach-Object {
            [pscustomobject]@{ Tag = $_; Release = [pscustomobject]@{ tag_name = $_; draft = $false; prerelease = $true; published_at = '2020-01-01T00:00:00Z'; immutable = $true; assets = @() }; Files = @{}; Build = 65000; U = 999; N = 1 }
        }
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures (@($evil) + $good)
        $r.Tag | Should -Be $good.Tag
        $dl = @($ctx.Calls) -match '^Download'
        foreach ($x in $dl) { $x | Should -Match '^Download:(manifest\.json|SHA256SUMS|MoonlightSetup\.exe|attestation\.sigstore\.json)$' }
    }
    It 'draft releases are ignored' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease -U 203; $fx.Release.draft = $true
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'noop'
    }
}

Describe 'Age rule (cooling-off)' {
    It 'too young (canary cooling-off 6 h from local config) => deferred, no download' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ cooling_off_hours = 6 } -Fixtures @($fx)
        $r.Result | Should -Be 'deferred'; $r.ExitCode | Should -Be 0
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'default canary cooling-off is 0 h: a brand-new release is eligible' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'updated'
    }
    It 'policy can raise the cooling-off above the local value' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Policy = New-DefaultPolicy -Canary 12
        $fx = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'deferred'
    }
    It 'an older release that has aged enough is installed when the newest is still too young' {
        $d = New-Case; $ctx = New-FakeCtx
        $young = New-FixtureRelease -U 204 -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $old = New-FixtureRelease -U 203 -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-30).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $ctx.TargetBuild = $old.Build
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ cooling_off_hours = 24 } -Fixtures @($young, $old)
        $r.Result | Should -Be 'updated'; $r.Tag | Should -Be $old.Tag
    }
    It 'unparseable published_at is not installable' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease; $fx.Release.published_at = 'yesterday-ish'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Not -Be 'updated'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
}

Describe 'Deny lists' {
    It 'policy deny: newest tag is skipped, next newest eligible one installs' {
        $d = New-Case; $ctx = New-FakeCtx
        $a = New-FixtureRelease -U 203; $b = New-FixtureRelease -U 202
        $ctx.Policy = New-DefaultPolicy -Deny @($a.Tag)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($a, $b)
        $r.Tag | Should -Be $b.Tag
    }
    It 'policy deny of the only candidate => noop, nothing downloaded' {
        $d = New-Case; $ctx = New-FakeCtx
        $a = New-FixtureRelease -U 203; $ctx.Policy = New-DefaultPolicy -Deny @($a.Tag)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($a)
        $r.Result | Should -Be 'noop'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'local deny (earlier failed install) is honoured' {
        $d = New-Case; $ctx = New-FakeCtx
        $a = New-FixtureRelease -U 203
        $s = Read-UpdState -DataDir $d.Data; Add-LocalDeny -State $s -Tag $a.Tag -Reason 'earlier failure'; Save-UpdState -DataDir $d.Data -State $s
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($a)
        $r.Result | Should -Be 'noop'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
}

Describe 'Policy handling (fail closed)' {
    It 'policy unavailable => exit 3, nothing installed' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.PolicyThrows = 'policy: branch lookup failed'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.ExitCode | Should -Be 3; $r.Result | Should -Be 'failed'
        Test-NothingInstalled $ctx | Should -BeTrue
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'policy without an upstream owner allow-list => exit 3 (an empty allow-list must not disable the owner check)' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Policy.AllowOwners = @()
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.ExitCode | Should -Be 3
        (@($ctx.Calls) -match '^(Download|RunInstaller)').Count | Should -Be 0
    }
    It 'rate limit => deferred with exit 8, no side effects' {
        $d = New-Case; $ctx = New-FakeCtx
        $e = New-Object System.Exception('GitHub API rate limit reached'); $e.Data['RateLimited'] = $true; $ctx.ReleasesThrows = $e
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'deferred'; $r.ExitCode | Should -Be 8
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'manifest owner outside policy allow-list => verify_failed' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -Owner 'Mallory'))
        $r.Result | Should -Be 'verify_failed'; $r.ExitCode | Should -Be 4
        Test-NothingInstalled $ctx | Should -BeTrue
    }
}

Describe 'Verification failures => nothing installed' {
    It 'tampered installer byte (hash mismatch vs SHA256SUMS/manifest)' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.TamperInstallerOnDownload = $true
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'verify_failed'; $r.ExitCode | Should -Be 4
        $r.Detail | Should -Match 'hash'
        Test-NothingInstalled $ctx | Should -BeTrue
        $ctx.Installed | Should -Be '6.2.60006.0'
    }
    It 'SHA256SUMS disagrees with manifest' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease
        $fx.Files['SHA256SUMS'] = [Text.Encoding]::UTF8.GetBytes(('f' * 64) + "  MoonlightSetup.exe`n")
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'; Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'API asset digest disagrees' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease
        ($fx.Release.assets | Where-Object name -eq 'MoonlightSetup.exe').digest = 'sha256:' + ('9' * 64)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'; Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'attestation verification fails for <Which>' -ForEach @(
        @{ Which = 'MoonlightSetup.exe' }, @{ Which = 'manifest.json' }, @{ Which = 'SHA256SUMS' }
    ) {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyFailFor = @($Which)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'verify_failed'; $r.ExitCode | Should -Be 4
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'attestation fails globally' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyOk = $false
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))).Result | Should -Be 'verify_failed'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'release is not immutable' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -NotImmutable))
        $r.Result | Should -Be 'verify_failed'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'manifest tag does not match the release tag' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease -U 203; $other = New-FixtureRelease -U 202
        $fx.Files['manifest.json'] = $other.Files['manifest.json']
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'verify_failed'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'release lacks SHA256SUMS or the installer asset' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease; $fx.Release.assets = @($fx.Release.assets | Where-Object name -ne 'SHA256SUMS')
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'verify_failed'
        $d2 = New-Case; $ctx2 = New-FakeCtx
        $fx2 = New-FixtureRelease; $fx2.Release.assets = @($fx2.Release.assets | Where-Object name -ne 'MoonlightSetup.exe')
        (Invoke-FakeUpdate -Dirs $d2 -Ctx $ctx2 -Fixtures @($fx2)).Result | Should -Be 'verify_failed'
        Test-NothingInstalled $ctx | Should -BeTrue; Test-NothingInstalled $ctx2 | Should -BeTrue
    }
    It 'installer larger than max_installer_mb is rejected before download' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease; ($fx.Release.assets | Where-Object name -eq 'MoonlightSetup.exe').size = 500MB
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'
        (@($ctx.Calls) -match '^Download:MoonlightSetup').Count | Should -Be 0
    }
    It 'gh.exe failing its pin check aborts before any attestation call' {
        $d = New-Case; $ctx = New-FakeCtx
        $deps = New-FakeDeps -Ctx $ctx -Sids @($d.Sid)
        $deps.AssertGh = { param($gh, $p) throw 'gh.exe hash does not match pin' }
        Initialize-UpdLog -LogDir (Join-Path $d.Data 'logs') -RunId 't'
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        $ctx.Fixtures = @((New-FixtureRelease)); $ctx.TargetBuild = 61616
        $r = Invoke-MoonlightUpdate -ProgramDir $d.Prog -DataDir $d.Data -Config (New-TestConfig) -Deps $deps
        $r.Result | Should -Be 'verify_failed'
        (@($ctx.Calls) -match '^Verify:').Count | Should -Be 0
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'online verify_mode runs gh release verify(-asset) and fails closed' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ verify_mode = 'online' } -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'updated'
        $ctx.Calls | Should -Contain 'VerifyOnline'
    }
}

Describe 'Install failure => rollback; deny only after 2 consecutive real failures' {
    It '<Mode>: first failure rolls back (exit 5) and does NOT deny; the tag is retried after backoff' -ForEach @(
        @{ Mode = 'wrongversion' }, @{ Mode = 'rc1' }, @{ Mode = 'timeout' }, @{ Mode = 'loseCert' }
    ) {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = $Mode
        $fx = New-FixtureRelease -U 202
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'rolled_back'; $r.ExitCode | Should -Be 5
        @($ctx.Calls) | Should -Contain 'Rollback:installed-60006'
        $ctx.Installed | Should -Be '6.2.60006.0'
        $st = Read-UpdState -DataDir $d.Data
        Test-LocallyDenied -State $st -Tag $fx.Tag | Should -BeFalse
        (Get-AttemptRecord -State $st -Tag $fx.Tag).failures | Should -Be 1
        $st.installed | Should -BeNullOrEmpty
        (Get-VerifiedBundles -DataDir $d.Data | ForEach-Object Name) | Should -Not -Contain $fx.Tag      # failed bundle is not kept
        $ctx.Notified | Should -Contain ('rolled_back|' + $fx.Tag)
        # next run, inside the 1 h backoff: nothing happens
        $ctx.Calls.Clear()
        $r2 = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r2.Result | Should -Be 'deferred'; $r2.Detail | Should -Match 'backoff'
        (@($ctx.Calls) -match '^(Download|RunInstaller)').Count | Should -Be 0
    }
    It 'second consecutive failure of the same tag denies it; a third run does nothing' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = 'wrongversion'
        $fx = New-FixtureRelease -U 202
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        $ctx.Installed = '6.2.60006.0'; $ctx.Now = (Get-Date).ToUniversalTime().AddHours(3); $ctx.Calls.Clear()
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'rolled_back'
        Test-LocallyDenied -State (Read-UpdState -DataDir $d.Data) -Tag $fx.Tag | Should -BeTrue
        $ctx.Calls.Clear(); $ctx.InstallMode = 'ok'
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'noop'
        (@($ctx.Calls) -match '^RunInstaller').Count | Should -Be 0
    }
    It 'rollback failure => exit 6 and a loud notification' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'wrongversion'; $ctx.RollbackOk = $false
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.ExitCode | Should -Be 6
        ($ctx.Notified -join ',') | Should -Match 'ROLLBACK-FAILED'
    }
    It 'installer hash re-check failure (file swapped after verification): nothing ran => verify_failed, no rollback' {
        $d = New-Case; $ctx = New-FakeCtx
        $deps = New-FakeDeps -Ctx $ctx -Sids @($d.Sid)
        $deps.RunInstaller = { param($p, $s, $l, $v) $script:FakeCtx.Calls.Add('RunInstaller:install'); return @{ Started = $false; HashOk = $false; Rc = $null; TimedOut = $false; RebootPending = $false; TreeGone = $true; MsiIdle = $true } }
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        Initialize-UpdLog -LogDir (Join-Path $d.Data 'logs') -RunId 't'
        $ctx.Fixtures = @((New-FixtureRelease)); $ctx.TargetBuild = 61616
        $r = Invoke-MoonlightUpdate -ProgramDir $d.Prog -DataDir $d.Data -Config (New-TestConfig) -Deps $deps
        $r.Result | Should -Be 'verify_failed'
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
    }
}

Describe 'Installer exit codes (P2-3)' {
    It '1618 (another installation running) => deferred, no rollback, no deny, transient backoff' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'rc1618'
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'deferred'; $r.ExitCode | Should -Be 0
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
        $st = Read-UpdState -DataDir $d.Data
        Test-LocallyDenied -State $st -Tag $fx.Tag | Should -BeFalse
        (Get-AttemptRecord -State $st -Tag $fx.Tag).transient | Should -Be 1
        (Get-AttemptRecord -State $st -Tag $fx.Tag).failures | Should -Be 0
    }
    It '3010 with the target version present => success' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'reboot'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'updated'; $r.Detail | Should -Match 'reboot pending: True'
    }
    It '<Mode>: version unchanged => pending_reboot (no rollback, no deny), state recorded' -ForEach @(@{ Mode = 'rc3010same' }, @{ Mode = 'rc1641same' }) {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = $Mode
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'pending_reboot'; $r.ExitCode | Should -Be 0
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
        $st = Read-UpdState -DataDir $d.Data
        $st.pending_reboot.tag | Should -Be $fx.Tag
        Test-LocallyDenied -State $st -Tag $fx.Tag | Should -BeFalse
        (Get-VerifiedBundles -DataDir $d.Data | ForEach-Object Name) | Should -Contain $fx.Tag      # kept for the re-verification
    }
    It '1641 with the correct version => success' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'rc1641'
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))).Result | Should -Be 'updated'
    }
    It 'pending reboot: next run before a reboot waits; after the reboot with the target version it is resolved' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = 'rc3010same'
        $fx = New-FixtureRelease
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        $ctx.Calls.Clear()
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)       # BootTime = yesterday: no reboot yet
        $r.Result | Should -Be 'deferred'; $r.Detail | Should -Match 'reboot pending'
        (@($ctx.Calls) -match '^(Download|RunInstaller)').Count | Should -Be 0
        $ctx.BootTime = (Get-Date).ToUniversalTime().AddMinutes(5); $ctx.Installed = '6.2.61616.0'       # rebooted, upgrade completed
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'noop'
        $st = Read-UpdState -DataDir $d.Data
        $st.pending_reboot | Should -BeNullOrEmpty; $st.installed.tag | Should -Be $fx.Tag
        (Get-AllLogText $d.Data) | Should -Match 'event=pending_reboot_resolved'
    }
    It 'pending reboot: after the reboot the target version is still missing => genuine failure, rollback' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = 'rc3010same'
        $fx = New-FixtureRelease
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        $ctx.Calls.Clear(); $ctx.BootTime = (Get-Date).ToUniversalTime().AddMinutes(5)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'rolled_back'
        @($ctx.Calls) | Should -Contain 'Rollback:installed-60006'
    }
    It 'installer timeout whose process tree could not be stopped => exit 6, NO rollback, no deny (rollback only after the tree is gone)' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'stuck'
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.ExitCode | Should -Be 6; $r.Detail | Should -Match 'did not stop'
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
        Test-LocallyDenied -State (Read-UpdState -DataDir $d.Data) -Tag $fx.Tag | Should -BeFalse
    }
}

Describe 'Idle handling (P2-4)' {
    It 'Moonlight starts right before the launch (3rd idle check) => deferred, installer never launched' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.RunningSeq = @($false, $false, $true)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'deferred'
        (@($ctx.Calls) -match '^RunInstaller').Count | Should -Be 0
    }
    It 'rollback needed while Moonlight runs: bounded backoff, then rollback_pending + alert (no uninstall)' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = 'wrongversion'
        $ctx.RunningSeq = @($false, $false, $false) + (1..10 | ForEach-Object { $true })       # idle for the installs, then Moonlight is started
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.ExitCode | Should -Be 6; $r.Detail | Should -Match 'rollback postponed'
        @($ctx.Sleeps) | Should -Be @(30, 60, 120, 240)
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
        ($ctx.Notified -join ',') | Should -Match 'ROLLBACK-POSTPONED'
        $st = Read-UpdState -DataDir $d.Data
        $st.rollback_pending.tag | Should -Be $fx.Tag
        (Get-VerifiedBundles -DataDir $d.Data | ForEach-Object Name) | Should -Contain $fx.Tag      # failed bundle kept for the late rollback
        # later, Moonlight is closed: the late rollback happens at the start of the next run
        $ctx.RunningSeq = @(); $ctx.Running = $false; $ctx.Calls.Clear()
        $r2 = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r2.Result | Should -Be 'rolled_back'; $r2.Detail | Should -Match 'late rollback'
        @($ctx.Calls) | Should -Contain 'Rollback:installed-60006'
        (Read-UpdState -DataDir $d.Data).rollback_pending | Should -BeNullOrEmpty
    }
}

Describe 'Rollback baseline (P2-5)' {
    It 'no baseline => refuse to install before downloading anything (exit 3, log no_rollback_baseline)' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.NoBaseline = $true
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.ExitCode | Should -Be 3; $r.Detail | Should -Match 'refusing to install'
        (@($ctx.Calls) -match '^(Download|RunInstaller)').Count | Should -Be 0
        (Get-AllLogText $d.Data) | Should -Match 'no_rollback_baseline'
    }
    It 'allow_no_baseline=true installs anyway' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.NoBaseline = $true
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ allow_no_baseline = $true } -Fixtures @((New-FixtureRelease))).Result | Should -Be 'updated'
    }
    It 'a Package Cache bundle that is not admin-only is not used as baseline' {
        $d = New-Case; $ctx = New-FakeCtx
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3)); $ctx.PackageCache = $pc
        $deps = New-FakeDeps -Ctx $ctx -Sids @($d.Sid)
        $deps.TestPathAcl = { param($p) return @('writable by Users') }
        Initialize-UpdLog -LogDir (Join-Path $d.Data 'logs') -RunId 't'
        $ctx.Fixtures = @((New-FixtureRelease)); $ctx.TargetBuild = 61616
        (Invoke-MoonlightUpdate -ProgramDir $d.Prog -DataDir $d.Data -Config (New-TestConfig) -Deps $deps).ExitCode | Should -Be 3
    }
    It 'after a successful update the new bundle is the baseline of the next one' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202)))
        $ctx.NoBaseline = $true; $ctx.PackageCache = $null; $ctx.Calls.Clear(); $ctx.TargetBuild = (ConvertTo-BuildNumber -U 203 -N 1)
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 203))
        $r.Result | Should -Be 'updated'
    }
}

Describe 'Order, backoff and pruning (P2-6)' {
    It 'the manifest and SHA256SUMS attestations are verified BEFORE the installer is downloaded' {
        $d = New-Case; $ctx = New-FakeCtx
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease)))
        $c = Get-Calls $ctx
        $iDl = [array]::IndexOf($c, 'Download:MoonlightSetup.exe')
        [array]::IndexOf($c, 'Verify:manifest.json') | Should -BeLessThan $iDl
        [array]::IndexOf($c, 'Verify:SHA256SUMS') | Should -BeLessThan $iDl
        [array]::IndexOf($c, 'Verify:MoonlightSetup.exe') | Should -BeGreaterThan $iDl
    }
    It 'a manifest that fails verification never causes the installer download' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyFailFor = @('manifest.json')
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease)))
        (@($ctx.Calls) -match '^Download:MoonlightSetup').Count | Should -Be 0
    }
    It 'a permanently bad release is not re-processed on every run (backoff) and is denied after 3 verification failures' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyOk = $false
        $fx = New-FixtureRelease
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        $ctx.Calls.Clear()
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)       # immediately again: inside the backoff
        $r.Result | Should -Be 'deferred'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
        $ctx.Now = (Get-Date).ToUniversalTime().AddHours(1)
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))     # 2nd failure
        $ctx.Now = (Get-Date).ToUniversalTime().AddHours(10)
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))     # 3rd failure => denied
        Test-LocallyDenied -State (Read-UpdState -DataDir $d.Data) -Tag $fx.Tag | Should -BeTrue
        $ctx.Calls.Clear(); $ctx.VerifyOk = $true; $ctx.Now = (Get-Date).ToUniversalTime().AddHours(20)
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'noop'
    }
    It 'download errors are transient: deferred (exit 8), backoff, never denied' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.DownloadThrows = 'HTTP 503'
        $fx = New-FixtureRelease
        foreach ($h in 0, 2, 5, 12, 30, 60) {
            $ctx.Now = (Get-Date).ToUniversalTime().AddHours($h)
            $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
            @(8, 0) | Should -Contain $r.ExitCode
        }
        $st = Read-UpdState -DataDir $d.Data
        Test-LocallyDenied -State $st -Tag $fx.Tag | Should -BeFalse
        (Get-AttemptRecord -State $st -Tag $fx.Tag).transient | Should -BeGreaterThan 2
    }
    It 'failed runs do not leak: only the newest 3 run dirs survive' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyOk = $false
        $fx = New-FixtureRelease
        foreach ($h in 0, 2, 4, 6, 8) {
            $ctx.Now = (Get-Date).ToUniversalTime().AddHours($h * 20)
            [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
            Start-Sleep -Milliseconds 1100       # run dir names carry a one-second timestamp
            Remove-UpdDenyForTest -DataDir $d.Data
        }
        @(Get-ChildItem (Join-Path $d.Data 'updates') -Directory).Count | Should -BeLessOrEqual 3
    }
    It 'installer size must equal the manifest / release size (truncation or swap) => verify_failed before any install' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease; ($fx.Release.assets | Where-Object name -eq 'MoonlightSetup.exe').size = 9999      # API disagrees with the manifest (4096)
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'verify_failed'
        (@($ctx.Calls) -match '^(Download:MoonlightSetup|RunInstaller)').Count | Should -Be 0
    }
    It 'the manifest owner must be in the LOCAL owner list as well' {
        $d = New-Case; $ctx = New-FakeCtx
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ upstream_owners = @('SomeoneElse') } -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'verify_failed'
        (@($ctx.Calls) -match '^RunInstaller').Count | Should -Be 0
    }
}

Describe 'Presence when the user hive is unavailable (P2-8)' {
    It 'no hive before the install => install postponed (never unchecked), exit 0' {
        $d = New-Case; $ctx = New-FakeCtx
        $ctx.PresenceBefore = [pscustomobject]@{ HiveAvailable = $false; UniqueId = $false; Hosts = $false; Certificate = $false; Key = $false }
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.Result | Should -Be 'deferred'; $r.Detail | Should -Match 'presence check unavailable'
        (@($ctx.Calls) -match '^RunInstaller').Count | Should -Be 0
        (Get-AllLogText $d.Data) | Should -Match 'presence_unavailable'
    }
    It 'hive gone after the install => verification_pending (no rollback); re-checked at the next run' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $ctx.PresenceAfter = [pscustomobject]@{ HiveAvailable = $false; UniqueId = $false; Hosts = $false; Certificate = $false; Key = $false }
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'updated'
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
        (Read-UpdState -DataDir $d.Data).verification_pending.tag | Should -Be $fx.Tag
        # next run: hive available again and the certificate is missing => alert, no rollback, pending cleared
        $ctx.PresenceCalls = 5; $ctx.PresenceAfter = [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $false; Key = $true }
        $ctx.Calls.Clear()
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        ($ctx.Notified -join ',') | Should -Match 'PRESENCE-LOST'
        (@($ctx.Calls) -match '^Rollback').Count | Should -Be 0
        (Read-UpdState -DataDir $d.Data).verification_pending | Should -BeNullOrEmpty
    }
}

Describe 'Local cooling-off floor (P2-9) and clock (P3)' {
    It 'with the production default floor of 2 h a 1 h old release is deferred even though the policy says 0' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Policy = New-DefaultPolicy -Canary 0
        $fx = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ min_cooling_off_hours = 2 } -Fixtures @($fx)
        $r.Result | Should -Be 'deferred'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'a 3 h old release passes the floor; the Owner can lower the floor locally' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ min_cooling_off_hours = 2 } -Fixtures @($fx)).Result | Should -Be 'updated'
        $d2 = New-Case; $ctx2 = New-FakeCtx
        $young = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        (Invoke-FakeUpdate -Dirs $d2 -Ctx $ctx2 -ConfigOverride @{ min_cooling_off_hours = 0 } -Fixtures @($young)).Result | Should -Be 'updated'
    }
    It 'a local clock 30 days ahead does not defeat cooling-off: GitHub server time is used when the skew exceeds 5 minutes' {
        $d = New-Case; $ctx = New-FakeCtx
        $ctx.Now = (Get-Date).ToUniversalTime().AddDays(30); $ctx.ServerDate = (Get-Date).ToUniversalTime()
        $fx = New-FixtureRelease -PublishedAt ((Get-Date).ToUniversalTime().AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ cooling_off_hours = 24 } -Fixtures @($fx)
        $r.Result | Should -Be 'deferred'
        (Get-AllLogText $d.Data) | Should -Match 'clock_skew'
    }
}

Describe 'Logs never contain key or certificate material' {
    It 'scrubs PEM markers, DER blobs, tokens and control characters' {
        $s = ConvertTo-SafeLogValue ("-----BEGIN PRIVATE KEY-----`nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7`n-----END PRIVATE KEY----- BEGIN CERTIFICATE ghp_abcdefghijklmnopqrstuvwxyz0123456789 https://chat.googleapis.com/v1/spaces/X/messages?key=a&token=b`tx") 2000
        $s | Should -Not -Match 'BEGIN (PRIVATE KEY|CERTIFICATE)'
        $s | Should -Not -Match 'MIIEvQ'
        $s | Should -Not -Match 'ghp_'
        $s | Should -Not -Match 'googleapis'
        $s | Should -Not -Match "[\r\n\t]"
    }
    It 'after a full set of scenarios (incl. hostile exception text) no log contains BEGIN PRIVATE KEY / BEGIN CERTIFICATE' {
        $d = New-Case; $ctx = New-FakeCtx
        $ctx.PolicyThrows = "boom -----BEGIN PRIVATE KEY-----`nAAAA`n-----END PRIVATE KEY----- BEGIN CERTIFICATE"
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease)))
        $ctx.PolicyThrows = $null
        $ctx.InstallMode = 'wrongversion'
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease)))
        $ctx.VerifyOk = $false
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 210)))
        Write-UpdLog -Level ERROR -Event 'direct' -Data @{ message = '-----BEGIN PRIVATE KEY----- x -----BEGIN CERTIFICATE-----' }
        $all = Get-AllLogText $d.Root
        $all.Length | Should -BeGreaterThan 500
        $all | Should -Not -Match 'BEGIN PRIVATE KEY'
        $all | Should -Not -Match 'BEGIN CERTIFICATE'
        $all | Should -Not -Match 'END PRIVATE KEY'
        $all | Should -Match 'REDACTED-PEM'
    }
    It 'log rotation: old files are deleted, big files roll over' {
        $d = New-Case
        $ld = Join-Path $d.Data 'logs'; New-Item -ItemType Directory $ld | Out-Null
        $old = Join-Path $ld 'update-2020-01-01.log'; 'x' | Set-Content $old; (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-90)
        Initialize-UpdLog -LogDir $ld -RunId 'rot' -MaxBytes 2000 -KeepDays 30
        Test-Path $old | Should -BeFalse
        1..60 | ForEach-Object { Write-UpdLog -Event 'filler' -Data @{ n = $_; pad = ('x' * 80) } }
        @(Get-ChildItem $ld -Filter 'update-*.log*').Count | Should -BeGreaterThan 1
    }
    It 'every line has the documented structure' {
        $d = New-Case
        Initialize-UpdLog -LogDir (Join-Path $d.Data 'logs') -RunId 'abc12345'
        Write-UpdLog -Event 'x' -Data @{ k = "line1`nline2" }
        $line = (Get-Content (Join-Path $d.Data 'logs\*.log') | Select-Object -Last 1)
        $line | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z INFO run=abc12345 event=x k="line1\\nline2"$'
    }
}
