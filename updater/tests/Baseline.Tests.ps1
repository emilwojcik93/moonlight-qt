BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:Roots = @()
    function New-Case { $d = New-TestDirs; $script:Roots += $d.Root; return $d }
    function New-SyntheticSecurity {
        param([string]$OwnerSid = 'S-1-5-32-544', [object[]]$Rules = @())
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        $sec.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($OwnerSid)))
        foreach ($r in $Rules) {
            $id = New-Object System.Security.Principal.SecurityIdentifier($r.Sid)
            $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $r.Rights, $inh, 'None', 'Allow')))
        }
        return $sec
    }
    $script:Sys = @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
    $script:Adm = @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
}
AfterAll { foreach ($r in $script:Roots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'Read-only artifact ACL (Package Cache baseline): relaxed but correct' {
    It 'exact shape of the stock Package Cache file (owner Administrators, Administrators+SYSTEM Full, Everyone/Users ReadAndExecute+Synchronize) is accepted' {
        $v = Find-AclViolation -Security (New-SyntheticSecurity -Rules @($Sys, $Adm, @{ Sid = 'S-1-1-0'; Rights = 'ReadAndExecute, Synchronize' }, @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute, Synchronize' }, @{ Sid = 'S-1-5-11'; Rights = 'Read, Synchronize' }))
        @($v).Count | Should -Be 0
    }
    It 'refuses <Rights> for Users/Everyone/Authenticated Users' -ForEach @(
        @{ Rights = 'WriteData' }, @{ Rights = 'AppendData' }, @{ Rights = 'Delete' }, @{ Rights = 'WriteAttributes' }, @{ Rights = 'WriteExtendedAttributes' },
        @{ Rights = 'DeleteSubdirectoriesAndFiles' }, @{ Rights = 'ChangePermissions' }, @{ Rights = 'TakeOwnership' }, @{ Rights = 'Modify' }, @{ Rights = 'FullControl' }
    ) {
        foreach ($sid in 'S-1-5-32-545', 'S-1-1-0', 'S-1-5-11') {
            @(Find-AclViolation -Security (New-SyntheticSecurity -Rules @($Sys, $Adm, @{ Sid = $sid; Rights = $Rights }))).Count | Should -BeGreaterThan 0 -Because "$sid $Rights"
        }
    }
    It 'refuses a non-admin owner even with a read-only DACL' {
        @(Find-AclViolation -Security (New-SyntheticSecurity -OwnerSid 'S-1-5-32-545' -Rules @($Sys, $Adm, @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }))).Count | Should -BeGreaterThan 0
    }
    It 'a real system-owned read-only file with all ancestors up to the stop dir is accepted (cmd.exe) and the result has Count 0 (no wrapped-empty-array regression)' {
        $r = @(& { Test-ReadOnlyArtifactAcl -Path (Join-Path $env:SystemRoot 'System32\cmd.exe') -StopAt $env:SystemRoot })
        $r.Count | Should -Be 0 -Because ($r -join ' | ')
    }
    It 'the real Package Cache baseline (if present) is accepted' {
        $p = 'C:\ProgramData\Package Cache\{7CA3BD1C-5B34-4D14-91A0-4277DD5E2063}\MoonlightSetup.exe'
        if (-not (Test-Path $p)) { Set-ItResult -Skipped -Because 'no Burn bundle on this machine'; return }
        $r = @(& { Test-ReadOnlyArtifactAcl -Path $p -StopAt 'C:\ProgramData\Package Cache' })
        $r.Count | Should -Be 0 -Because ($r -join ' | ')
    }
    It 'a user-owned file is refused' {
        $d = New-Case
        $f = Join-Path $d.Root 'x.exe'; 'x' | Set-Content $f
        @(Test-ReadOnlyArtifactAcl -Path $f -StopAt $d.Root).Count | Should -BeGreaterThan 0
    }
    It 'a path below a junction is refused; a path outside StopAt is refused' {
        $d = New-Case
        $real = Join-Path $d.Root 'real'; New-Item -ItemType Directory $real | Out-Null; 'x' | Set-Content (Join-Path $real 'a.exe')
        $link = Join-Path $d.Root 'link'; cmd /c mklink /J "`"$link`"" "`"$real`"" | Out-Null
        try {
            (@(Test-ReadOnlyArtifactAcl -Path (Join-Path $link 'a.exe') -StopAt $d.Root) -join ' ') | Should -Match 'reparse point'
            (@(Test-ReadOnlyArtifactAcl -Path (Join-Path $real 'a.exe') -StopAt 'C:\Windows') -join ' ') | Should -Match 'not below'
        } finally { cmd /c rmdir "`"$link`"" | Out-Null }
    }
    It 'strict admin-only checking is unchanged for program/data dirs: a user-owned directory is still flagged by Test-UpdAclSafe' {
        $d = New-Case
        @(Test-UpdAclSafe -Path $d.Root).Count | Should -BeGreaterThan 0
    }
    It 'default TestPathAcl dependency is the read-only artifact check (the stock Package Cache shape must not be reported as a violation)' {
        $deps = New-UpdDeps -Config (New-TestConfig) -ProgramDir 'C:\x'
        $deps.TestPathAcl.ToString() | Should -Match 'Test-ReadOnlyArtifactAcl'
    }
}

Describe 'Baseline trust-on-first-use pin' {
    It 'the baseline hash is pinned on first acceptance; a changed baseline for the same build is refused' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        $ctx.InstallMode = 'wrongversion'
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202)))
        $st = Read-UpdState -DataDir $d.Data
        $st.baseline_pins.'installed-60006' | Should -Be (Get-UpdSha256 -Path $pc)
        # swap the baseline file and drop the stored copy
        $ctx.Installed = '6.2.60006.0'; $ctx.Calls.Clear()
        [IO.File]::WriteAllBytes($pc, [byte[]](9, 9, 9, 9))
        Remove-Item -LiteralPath (Join-Path $d.Data 'bundles') -Recurse -Force
        $r2 = Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 203))
        $r2.ExitCode | Should -Be 3; $r2.Detail | Should -Match 'baseline changed'
        (@($ctx.Calls) -match '^(Download|RunInstaller)').Count | Should -Be 0
        (Get-AllLogText $d.Data) | Should -Match 'event=baseline_changed'
    }
    It 'an unchanged baseline keeps working (pin equals hash)' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        $ctx.InstallMode = 'wrongversion'
        [void](Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202)))
        $ctx.InstallMode = 'ok'; $ctx.Installed = '6.2.60006.0'; $ctx.Now = (Get-Date).ToUniversalTime().AddHours(3)
        (Invoke-FakeUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202))).Result | Should -Be 'updated'
    }
    It 'a baseline with a bad ACL is skipped and the violations are logged' {
        $d = New-Case; $ctx = New-FakeCtx
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3)); $ctx.PackageCache = $pc
        $deps = New-FakeDeps -Ctx $ctx -Sids @($d.Sid)
        $deps.TestPathAcl = { param($p) return @('C:\x writable by Users') }
        Initialize-UpdLog -LogDir (Join-Path $d.Data 'logs') -RunId 't'
        $ctx.Fixtures = @((New-FixtureRelease)); $ctx.TargetBuild = 61616
        (Invoke-MoonlightUpdate -ProgramDir $d.Prog -DataDir $d.Data -Config (New-TestConfig) -Deps $deps).ExitCode | Should -Be 3
        (Get-AllLogText $d.Data) | Should -Match 'baseline_bundle_skipped.*writable by Users'
    }
}
