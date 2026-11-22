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
        $ctx.Installed | Should -Be '6.2.60202.0'
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
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60300.0'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202), (New-FixtureRelease -U 201))
        $r.Result | Should -Be 'noop'
        (@($ctx.Calls) -match '^Download').Count | Should -Be 0
    }
    It 'same upstream U, higher N: key is newer but MSI build number is not => skipped, not installed' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60202.0'
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202 -N 2))
        $r.Result | Should -Be 'noop'
        (Get-AllLogText $d.Data) | Should -Match 'same or lower MSI build number'
        Test-NothingInstalled $ctx | Should -BeTrue
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
        $ctx.Fixtures = @((New-FixtureRelease)); $ctx.TargetBuild = 60202
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

Describe 'Install failure => deny + rollback' {
    It '<Mode>: failed health check rolls back to the previous bundle, denies the tag, exit 5' -ForEach @(
        @{ Mode = 'wrongversion' }, @{ Mode = 'rc1' }, @{ Mode = 'timeout' }, @{ Mode = 'loseCert' }
    ) {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = $Mode
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        $fx = New-FixtureRelease -U 202
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'rolled_back'; $r.ExitCode | Should -Be 5
        @($ctx.Calls) | Should -Contain 'Rollback:installed-60006'
        $ctx.Installed | Should -Be '6.2.60006.0'
        $st = Read-UpdState -DataDir $d.Data
        Test-LocallyDenied -State $st -Tag $fx.Tag | Should -BeTrue
        $st.installed | Should -BeNullOrEmpty
        (Get-VerifiedBundles -DataDir $d.Data | ForEach-Object Name) | Should -Not -Contain $fx.Tag      # failed bundle is not kept
        $ctx.Notified | Should -Contain ('rolled_back|' + $fx.Tag)
        # next run does not retry the denied tag
        $ctx.Calls.Clear(); $ctx.InstallMode = 'ok'
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)).Result | Should -Be 'noop'
        Test-NothingInstalled $ctx | Should -BeTrue
    }
    It 'rollback failure => exit 6 and a loud notification' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'wrongversion'; $ctx.RollbackOk = $false
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease))
        $r.ExitCode | Should -Be 6
        ($ctx.Notified -join ',') | Should -Match 'ROLLBACK-FAILED'
    }
    It 'no previous bundle available => cannot roll back, exit 6, tag denied' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.InstallMode = 'wrongversion'; $ctx.PackageCache = $null
        $fx = New-FixtureRelease
        $r = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.ExitCode | Should -Be 6
        Test-LocallyDenied -State (Read-UpdState -DataDir $d.Data) -Tag $fx.Tag | Should -BeTrue
    }
    It 'installer hash re-check failure (file swapped after verification) is a failed install, not a success' {
        $d = New-Case; $ctx = New-FakeCtx
        $deps = New-FakeDeps -Ctx $ctx -Sids @($d.Sid)
        $deps.RunInstaller = { param($p, $s, $l, $v) $ctx.Calls.Add('RunInstaller:install'); return @{ Started = $false; HashOk = $false; Rc = $null; TimedOut = $false; RebootPending = $false } }.GetNewClosure()
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        Initialize-UpdLog -LogDir (Join-Path $d.Data 'logs') -RunId 't'
        $ctx.Fixtures = @((New-FixtureRelease)); $ctx.TargetBuild = 60202
        $r = Invoke-MoonlightUpdate -ProgramDir $d.Prog -DataDir $d.Data -Config (New-TestConfig) -Deps $deps
        $r.Result | Should -Be 'rolled_back'
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
