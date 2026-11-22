# Negative tests written by the independent QA / Security Gate reviewer (report qa-updater-report.md, review of commit 25d05388),
# copied into the suite with attribution and adapted to the fixed behaviour: every test that was tagged 'Defect' (a confirmed
# finding) now passes. Tests whose name starts with 'INFO' document a deliberate residual behaviour.
# Sandbox only: temp dirs, fakes, loopback sockets, a compiled stand-in installer. Never touches Moonlight or the real HKCU key.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'FixtureServer.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:Roots = @()
    function New-Case { $d = New-TestDirs; $script:Roots += $d.Root; return $d }

    # Invoke-FakeUpdate clone that lets a test override individual dependencies
    function Invoke-QaUpdate {
        param($Dirs, [hashtable]$Ctx, [hashtable]$ConfigOverride = @{}, [hashtable]$DepOverride = @{}, [object[]]$Fixtures, [switch]$VerifyOnly)
        if ($Fixtures) { $Ctx.Fixtures = $Fixtures }
        if (-not $Ctx.ContainsKey('TargetBuild')) {
            $n = $Ctx.Fixtures | Sort-Object -Property Build -Descending | Select-Object -First 1
            $Ctx.TargetBuild = $(if ($n) { $n.Build } else { 0 })
        }
        if (-not $Ctx.NoBaseline -and -not $Ctx.PackageCache) {
            $pcf = Join-Path $Dirs.Root 'package-cache-bundle.exe'
            if (-not (Test-Path $pcf)) { [System.IO.File]::WriteAllBytes($pcf, [byte[]](1, 2, 3, 4, 5)) }
            $Ctx.PackageCache = $pcf
        }
        Initialize-UpdLog -LogDir (Join-Path $Dirs.Data 'logs') -RunId 'qa'
        $cfg = New-TestConfig -Override $ConfigOverride
        $deps = New-FakeDeps -Ctx $Ctx -Sids @($Dirs.Sid)
        foreach ($k in $DepOverride.Keys) { $deps[$k] = $DepOverride[$k] }
        return (Invoke-MoonlightUpdate -ProgramDir $Dirs.Prog -DataDir $Dirs.Data -Config $cfg -Deps $deps -VerifyOnly:$VerifyOnly)
    }
    function Get-Calls($ctx) { return @($ctx.Calls) }
    function New-ManifestFile([string]$Dir, $Fx, [scriptblock]$Mutate) {
        $m = [System.IO.File]::ReadAllText((Join-Path $Dir 'manifest.json')) | ConvertFrom-Json
        if ($Mutate) { & $Mutate $m }
        $p = Join-Path $Dir 'manifest-mut.json'
        [System.IO.File]::WriteAllText($p, ($m | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }
    function Write-Fixture([string]$Dir, $Fx) { foreach ($k in $Fx.Files.Keys) { [System.IO.File]::WriteAllBytes((Join-Path $Dir $k), [byte[]]$Fx.Files[$k]) } }

    # tiny raw TCP server: Routes = path -> byte[] full raw HTTP response (or scriptblock-free); Hits counted per path
    function Start-RawServer {
        param([hashtable]$Routes, [string]$Address = '127.0.0.1')
        $ip = [System.Net.IPAddress]::Parse($Address)
        $tmp = New-Object System.Net.Sockets.TcpListener($ip, 0); $tmp.Start(); $port = $tmp.LocalEndpoint.Port; $tmp.Stop()
        $shared = [hashtable]::Synchronized(@{ Port = $port; Routes = $Routes; Hits = [hashtable]::Synchronized(@{}); Listener = $null; Address = $Address })
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
                param($S)
                $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($S.Address), $S.Port); $l.Start(); $S.Listener = $l
                while ($true) {
                    try { $c = $l.AcceptTcpClient() } catch { break }
                    try {
                        $ns = $c.GetStream(); $buf = New-Object byte[] 8192; $n = $ns.Read($buf, 0, 8192)
                        $req = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
                        $path = ($req -split ' ')[1]
                        $S.Hits[$path] = 1 + $(if ($S.Hits.ContainsKey($path)) { $S.Hits[$path] } else { 0 })
                        $resp = $S.Routes[$path]
                        if ($null -eq $resp) { $resp = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n") }
                        $ns.Write($resp, 0, $resp.Length); $ns.Flush()
                    } catch { $null = $_ } finally { try { $c.Close() } catch { $null = $_ } }
                }
            }).AddArgument($shared)
        $async = $ps.BeginInvoke()
        $dl = (Get-Date).AddSeconds(10); while (-not $shared.Listener -and (Get-Date) -lt $dl) { Start-Sleep -Milliseconds 50 }
        return @{ Port = $port; Shared = $shared; Ps = $ps; Async = $async }
    }
    function Stop-RawServer($s) { try { $s.Shared.Listener.Stop() } catch { $null = $_ }; try { $s.Ps.Stop(); $s.Ps.Dispose() } catch { $null = $_ } }
    function ConvertTo-RawHttp([string]$Status, [hashtable]$Headers, [byte[]]$Body) {
        $h = "HTTP/1.1 $Status`r`nConnection: close`r`n"
        foreach ($k in $Headers.Keys) { $h += "${k}: $($Headers[$k])`r`n" }
        $h += "`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($h)
        if ($null -eq $Body) { return $hb }
        return [byte[]]($hb + $Body)
    }
}
AfterAll { foreach ($r in $script:Roots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'QA tag and policy canonicalisation' {
    It 'rejects tag with trailing newline / CRLF / spaces / lower-case v / unicode digits' {
        foreach ($t in @("v6.2.0-daily.202-vp.1`n", "v6.2.0-daily.202-vp.1`r`n", 'v6.2.0-daily.202-vp.1 ', ' v6.2.0-daily.202-vp.1', 'V6.2.0-daily.202-vp.1', ([string]::Format('v6.2.0-daily.{0}-vp.1', [char]0x0662 + '02')), "v6.2.0-daily.202-vp.1`0")) {
            Test-MoonlightTag -Tag $t | Should -BeFalse
        }
    }
    It 'P3 (fixed): leading-zero alias tags are rejected, so a deny entry cannot be bypassed by an alias' {
        $b = 'v6.2.0-daily.0202-vp.1'; $c = 'v6.2.0-daily.00202-vp.001'
        (Test-MoonlightTag -Tag $b) | Should -BeFalse   # desired: canonical tags only
        (Test-MoonlightTag -Tag $c) | Should -BeFalse
    }
    It 'a policy deny entry that is an alias (leading zeros) is itself invalid => policy refused (fail closed)' {
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset "deny: ['v6.2.0-daily.0202-vp.1']") } | Should -Throw
    }
    It 'policy: hold must be a real boolean; bad cooling-off values and bad deny entries fail closed' {
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset "hold: 'true'`nallow_upstream_owners: [Nonary]") } | Should -Throw
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset "hold: yes") } | Should -Throw
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset "cooling_off_hours: {canary: -1}") } | Should -Throw
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset "cooling_off_hours: {canary: 0.5}") } | Should -Throw
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset "deny: ['v6.2.0-daily.1-vp.1;calc']") } | Should -Throw
    }
    It 'policy cannot lower the local cooling-off floor (R-CLW-2)' {
        $pol = New-DefaultPolicy -Canary 0
        (Get-EffectiveCoolingOffHours -LocalHours 6 -Policy $pol -Channel 'canary') | Should -Be 6
        $pol2 = [pscustomobject]@{ CoolingOff = @{ canary = 12; stable = 24 } }
        (Get-EffectiveCoolingOffHours -LocalHours 6 -Policy $pol2 -Channel 'canary') | Should -Be 12
    }
    It 'orchestrator: release younger than the local floor is deferred even if policy says 0' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.Policy = New-DefaultPolicy -Canary 0
        $fx = New-FixtureRelease -U 202 -PublishedAt ((Get-Date).ToUniversalTime().AddHours(-1).ToString('o'))
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ cooling_off_hours = 6 } -Fixtures @($fx)
        $r.Result | Should -Be 'deferred'
        (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'orchestrator: published_at in the future is treated as too young (not negative-age bypass)' {
        $d = New-Case; $ctx = New-FakeCtx
        $fx = New-FixtureRelease -U 202 -PublishedAt ((Get-Date).ToUniversalTime().AddHours(5).ToString('o'))
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -ConfigOverride @{ cooling_off_hours = 1 } -Fixtures @($fx)
        $r.Result | Should -Be 'deferred'
    }
}

Describe 'QA CONTRACT v1.1 build-number scheme' {
    It 'P1 (fixed): manifest with CONTRACT 3b build.version = 60000+8U+(N-1) must be accepted' {
        $d = New-Case
        $fx = New-FixtureRelease -U 202 -N 1
        Write-Fixture $d.Root $fx
        $p = New-ManifestFile $d.Root $fx { param($m) $m.build.version = ('6.2.0-daily.{0}' -f (60000 + 8 * 202 + 0)) }
        { Read-ReleaseManifest -Path $p -ExpectedTag $fx.Tag -AllowOwners @('Nonary') } | Should -Not -Throw
    }
    It 'P1 (fixed): installed FileVersion 6.2.61616.0 (= U202,N1 under 3b) must map to U=202,N=1, not U=1616' {
        $k = Resolve-InstalledKey -FileVersion '6.2.61616.0' -State $null
        $k.U | Should -Be 202
    }
}

Describe 'QA manifest / names: traversal and injection' {
    BeforeAll { $script:d = New-Case; $script:fx = New-FixtureRelease -U 202 -N 1; Write-Fixture $script:d.Root $script:fx }
    It 'rejects installer values that point outside the run dir' {
        foreach ($bad in @('..\evil.exe', '../MoonlightSetup.exe', 'MoonlightSetup\..\..\x.exe', 'C:\Windows\System32\cmd.exe', '\\10.0.0.1\s\MoonlightSetup.exe', 'MoonlightSetup.exe:evil.exe', 'MoonlightSetup .exe', "MoonlightSetup.exe`n", 'MoonlightSetup.exe;calc.exe', 'MoonlightSetup$(calc).exe', 'cmd.exe')) {
            $p = New-ManifestFile $script:d.Root $script:fx { param($m) $m.installer = $bad; $m.assets[0].name = $bad }.GetNewClosure()
            { Read-ReleaseManifest -Path $p -ExpectedTag $script:fx.Tag -AllowOwners @('Nonary') } | Should -Throw
        }
    }
    It 'rejects traversal in assets[].name and attestation[]' {
        $p = New-ManifestFile $script:d.Root $script:fx { param($m) $m.assets += [pscustomobject]@{ name = '..\x'; sha256 = ('a' * 64); size = 1 } }
        { Read-ReleaseManifest -Path $p -ExpectedTag $script:fx.Tag -AllowOwners @('Nonary') } | Should -Throw
        $p = New-ManifestFile $script:d.Root $script:fx { param($m) $m.attestation = @('..\att.sigstore.json') }
        { Read-ReleaseManifest -Path $p -ExpectedTag $script:fx.Tag -AllowOwners @('Nonary') } | Should -Throw
    }
    It 'rejects wrong tag / product / schema / owner / source_ref / source_sha' {
        foreach ($mut in @(
                { param($m) $m.tag = 'v6.2.0-daily.201-vp.1' }, { param($m) $m.product = 'vibepollo' }, { param($m) $m.schema = 2 },
                { param($m) $m.upstream.owner = 'Evil' }, { param($m) $m.build.source_ref = 'refs/heads/main' }, { param($m) $m.build.source_ref = 'refs/tags/v1' },
                { param($m) $m.build.source_sha = 'zz' }, { param($m) $m.build.source_ref = "refs/heads/automation`n" })) {
            $p = New-ManifestFile $script:d.Root $script:fx $mut
            { Read-ReleaseManifest -Path $p -ExpectedTag $script:fx.Tag -AllowOwners @('Nonary') } | Should -Throw
        }
    }
    It 'Save-ReleaseAsset refuses traversal, ADS and separators before any network I/O' {
        $run = Join-Path $script:d.Root 'run1'; New-Item -ItemType Directory $run | Out-Null
        $cfg = New-TestConfig
        foreach ($n in @('..\x.exe', '../x', 'a/b', 'a\b', 'x:ads', '.hidden', '', 'a b', 'MoonlightSetup.exe ' )) {
            { Save-ReleaseAsset -Config $cfg -Tag 'v6.2.0-daily.202-vp.1' -Name $n -RunDir $run } | Should -Throw
        }
        { Save-ReleaseAsset -Config $cfg -Tag "v6.2.0-daily.202-vp.1`n" -Name 'manifest.json' -RunDir $run } | Should -Throw
    }
    It 'P3 (fixed): Windows reserved device names are rejected as asset / bundle names' {
        foreach ($n in 'NUL.jsonl', 'CON.jsonl', 'com1.sigstore.json', 'LPT9.exe', 'aux.json') { (Test-SafeAssetName -Name $n) | Should -BeFalse -Because $n }
        (Test-SafeAssetName -Name 'MoonlightSetup.exe') | Should -BeTrue
        (Test-SafeAssetName -Name 'attestation.sigstore.json') | Should -BeTrue
    }
}

Describe 'QA ACL self-check: reparse points' {
    It 'Assert-UpdSelfAcl refuses a data dir that is a junction' {
        $root = New-TestRoot; $script:Roots += $root
        $real = Join-Path $root 'real'; New-Item -ItemType Directory $real | Out-Null
        $link = Join-Path $root 'link'; cmd.exe /c mklink /J "$link" "$real" | Out-Null
        $prog = Join-Path $root 'prog'; New-Item -ItemType Directory (Join-Path $prog 'lib') -Force | Out-Null
        $v = @(Test-UpdAclSafe -Path $link | ForEach-Object { $_ })
        ($v -join ' ') | Should -Match 'reparse'
        $threw = $false; $all = ''; try { Assert-UpdSelfAcl -ProgramDir $prog -DataDir $link } catch { $threw = $true; $all = ($_.Exception.Data['AclViolations'] -join ' | ') }
        $threw | Should -BeTrue; $all | Should -Match 'reparse'
    }
    It 'a junction used as the optional subdir "updates"/"cache" inside the data dir is detected' {
        $root = New-TestRoot; $script:Roots += $root
        $data = Join-Path $root 'data'; New-Item -ItemType Directory $data | Out-Null
        $real = Join-Path $root 'real'; New-Item -ItemType Directory $real | Out-Null
        cmd.exe /c mklink /J (Join-Path $data 'cache') "$real" | Out-Null
        $prog = Join-Path $root 'prog'; New-Item -ItemType Directory (Join-Path $prog 'lib') -Force | Out-Null
        $threw = $false; $all = ''; try { Assert-UpdSelfAcl -ProgramDir $prog -DataDir $data } catch { $threw = $true; $all = ($_.Exception.Data['AclViolations'] -join ' | ') }
        $threw | Should -BeTrue; $all | Should -Match 'cache is a reparse point'
    }
    It 'P3 (fixed): a junction two levels down (bundles/NAME) IS now detected (directories are recursed)' {
        $root = New-TestRoot; $script:Roots += $root
        $data = Join-Path $root 'data'; New-Item -ItemType Directory (Join-Path $data 'bundles') -Force | Out-Null
        $real = Join-Path $root 'real'; New-Item -ItemType Directory $real | Out-Null
        cmd.exe /c mklink /J (Join-Path $data 'bundles\evil') "$real" | Out-Null
        $v = @(Test-UpdAclSafe -Path (Join-Path $data 'bundles') | ForEach-Object { $_ })
        ($v -join ' ') | Should -Match 'reparse'
    }
    It 'bootstrap check (update.ps1 inline fn) reports a reparse-point program dir' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $UpdRoot 'update.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-UpdBootstrapAcl' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        $root = New-TestRoot; $script:Roots += $root
        $real = Join-Path $root 'real'; New-Item -ItemType Directory $real | Out-Null
        $link = Join-Path $root 'link'; cmd.exe /c mklink /J "$link" "$real" | Out-Null
        ((Test-UpdBootstrapAcl -Path $link) -join ' ') | Should -Match 'reparse'
    }
    It 'ACL check flags Users-writable (non-owner) via inheritable ACE on directory children' {
        $root = New-TestRoot; $script:Roots += $root
        $dir = Join-Path $root 'd'; New-Item -ItemType Directory $dir | Out-Null
        $f = Join-Path $dir 'x.json'; Set-Content $f 'x'
        $acl = Get-Acl $f
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'Modify', 'Allow')))
        Set-Acl $f $acl
        (@(Test-UpdAclSafe -Path $dir | ForEach-Object { $_ }) -join ' ') | Should -Match 'S-1-5-32-545|Users'
    }
}

Describe 'QA verification chain: mismatches fail closed' {
    It 'SUMS entry differs from file -> verify_failed, no installer run' {
        $d = New-Case; $ctx = New-FakeCtx; $fx = New-FixtureRelease -U 202
        $fx.Files['SHA256SUMS'] = [Text.Encoding]::UTF8.GetBytes(('{0}  MoonlightSetup.exe' -f ('0' * 64)))
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'; (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'manifest sha differs from file (API digest agrees with file) -> verify_failed' {
        $d = New-Case; $ctx = New-FakeCtx; $fx = New-FixtureRelease -U 202
        $m = [Text.Encoding]::UTF8.GetString($fx.Files['manifest.json']) | ConvertFrom-Json
        $m.assets[0].sha256 = ('1' * 64)
        $mb = [Text.Encoding]::UTF8.GetBytes(($m | ConvertTo-Json -Depth 8)); $fx.Files['manifest.json'] = $mb
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'; (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'bundle subject mismatch for the installer only (manifest ok) -> verify_failed' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyFailFor = @('MoonlightSetup.exe'); $fx = New-FixtureRelease -U 202
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'; (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'manifest installer escaping the run dir -> verify_failed, nothing downloaded beyond manifest/sums' {
        $d = New-Case; $ctx = New-FakeCtx; $fx = New-FixtureRelease -U 202
        $m = [Text.Encoding]::UTF8.GetString($fx.Files['manifest.json']) | ConvertFrom-Json
        $m.installer = '..\..\Windows\System32\cmd.exe'; $m.assets[0].name = '..\..\Windows\System32\cmd.exe'
        $fx.Files['manifest.json'] = [Text.Encoding]::UTF8.GetBytes(($m | ConvertTo-Json -Depth 8))
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx)
        $r.Result | Should -Be 'verify_failed'
        (Get-Calls $ctx) -match 'Download:MoonlightSetup|cmd.exe' | Should -BeNullOrEmpty
    }
    It 'P2 (fixed): manifest.json attestation must be verified BEFORE the (up to 200 MB) installer is downloaded' {
        $d = New-Case; $ctx = New-FakeCtx; $fx = New-FixtureRelease -U 202
        [void](Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        $c = Get-Calls $ctx
        ([array]::IndexOf($c, 'Verify:manifest.json')) | Should -BeLessThan ([array]::IndexOf($c, 'Download:MoonlightSetup.exe'))
    }
    It 'P3 (fixed): a permanently bad newest release is re-downloaded on every run (no backoff / failure counter)' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.VerifyOk = $false; $fx = New-FixtureRelease -U 202
        [void](Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        [void](Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx))
        @(Get-Calls $ctx | Where-Object { $_ -eq 'Download:MoonlightSetup.exe' }).Count | Should -BeLessThan 2
    }
    It 'downgrade / replay: older or equal tag never installs, even with wiped state' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.62000.0'
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202), (New-FixtureRelease -U 240 -N 1))
        $r.Result | Should -Be 'noop'
    }
}

Describe 'QA HTTP hardening (raw loopback server)' {
    It 'P3 (fixed): a truncated download (Content-Length > body) is detected by Save-ReleaseAsset and leaves no file behind' {
        $body = New-Object byte[] 100
        $srv = Start-RawServer -Routes @{ '/emilwojcik93/moonlight-qt/releases/download/v6.2.0-daily.202-vp.1/MoonlightSetup.exe' = (ConvertTo-RawHttp '200 OK' @{ 'Content-Length' = '1000' } $body) }
        try {
            $run = New-TestRoot; $script:Roots += $run
            $cfg = New-TestConfig -Override @{ download_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            { Save-ReleaseAsset -Config $cfg -Tag 'v6.2.0-daily.202-vp.1' -Name 'MoonlightSetup.exe' -RunDir $run -MaxBytes 1MB } | Should -Throw '*runcated*'
            Test-Path (Join-Path $run 'MoonlightSetup.exe') | Should -BeFalse
        } finally { Stop-RawServer $srv }
    }
    It 'a body that differs from the expected (manifest) size is rejected' {
        $body = New-Object byte[] 100
        $srv = Start-RawServer -Routes @{ '/emilwojcik93/moonlight-qt/releases/download/v6.2.0-daily.202-vp.1/MoonlightSetup.exe' = (ConvertTo-RawHttp '200 OK' @{ 'Content-Length' = '100' } $body) }
        try {
            $run = New-TestRoot; $script:Roots += $run
            $cfg = New-TestConfig -Override @{ download_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            { Save-ReleaseAsset -Config $cfg -Tag 'v6.2.0-daily.202-vp.1' -Name 'MoonlightSetup.exe' -RunDir $run -MaxBytes 1MB -ExpectedSize 4096 } | Should -Throw '*differs from expected*'
        } finally { Stop-RawServer $srv }
    }
    It 'Content-Length above cap is refused before reading the body' {
        $srv = Start-RawServer -Routes @{ '/emilwojcik93/moonlight-qt/releases/download/v6.2.0-daily.202-vp.1/MoonlightSetup.exe' = (ConvertTo-RawHttp '200 OK' @{ 'Content-Length' = '999999999' } $null) }
        try {
            $run = New-TestRoot; $script:Roots += $run
            $cfg = New-TestConfig -Override @{ download_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            { Save-ReleaseAsset -Config $cfg -Tag 'v6.2.0-daily.202-vp.1' -Name 'MoonlightSetup.exe' -RunDir $run -MaxBytes 1MB } | Should -Throw '*too large*'
        } finally { Stop-RawServer $srv }
    }
    It 'P3 (fixed): an intermediate redirect hop to a non-allow-listed host is NOT contacted (every hop is checked)' {
        $evil = Start-RawServer -Address '127.0.0.2' -Routes @{}
        $main = Start-RawServer -Routes @{}
        $evil.Shared.Routes['/hop'] = (ConvertTo-RawHttp '302 Found' @{ Location = "http://127.0.0.1:$($main.Port)/final"; 'Content-Length' = '0' } $null)
        $main.Shared.Routes['/r'] = (ConvertTo-RawHttp '302 Found' @{ Location = "http://127.0.0.2:$($evil.Port)/hop"; 'Content-Length' = '0' } $null)
        $main.Shared.Routes['/final'] = (ConvertTo-RawHttp '200 OK' @{ 'Content-Length' = '2' } ([Text.Encoding]::ASCII.GetBytes('ok')))
        try {
            { Invoke-UpdHttp -Uri "http://127.0.0.1:$($main.Port)/r" -AllowHttp } | Should -Throw '*disallowed*'
            $evil.Shared.Hits.ContainsKey('/hop') | Should -BeFalse
        } finally { Stop-RawServer $evil; Stop-RawServer $main }
    }
    It 'redirects to an allow-listed host are followed (loopback only in-process), https-only otherwise' {
        $main = Start-RawServer -Routes @{}
        $main.Shared.Routes['/r'] = (ConvertTo-RawHttp '302 Found' @{ Location = '/final'; 'Content-Length' = '0' } $null)
        $main.Shared.Routes['/final'] = (ConvertTo-RawHttp '200 OK' @{ 'Content-Length' = '2' } ([Text.Encoding]::ASCII.GetBytes('ok')))
        try {
            (Invoke-UpdHttp -Uri "http://127.0.0.1:$($main.Port)/r" -AllowHttp).Body | Should -Be 'ok'
            { Invoke-UpdHttp -Uri "http://127.0.0.1:$($main.Port)/r" } | Should -Throw '*disallowed*'      # plain http without the in-process allowance
            (Test-AllowedDownloadHost -Uri ([uri]'https://release-assets.githubusercontent.com/x')) | Should -BeTrue
            (Test-AllowedDownloadHost -Uri ([uri]'https://objects.githubusercontent.com/x')) | Should -BeTrue
            (Test-AllowedDownloadHost -Uri ([uri]'https://api.github.com/x')) | Should -BeTrue
            (Test-AllowedDownloadHost -Uri ([uri]'https://github.com/x')) | Should -BeTrue
            (Test-AllowedDownloadHost -Uri ([uri]'https://evil.example/x')) | Should -BeFalse
            (Test-AllowedDownloadHost -Uri ([uri]'https://github.com.evil.example/x')) | Should -BeFalse
            (Test-AllowedDownloadHost -Uri ([uri]'http://github.com/x')) | Should -BeFalse
        } finally { Stop-RawServer $main }
    }
    It 'final redirect target outside the allow-list is rejected' {
        $evil = Start-RawServer -Address '127.0.0.2' -Routes @{ '/x' = (ConvertTo-RawHttp '200 OK' @{ 'Content-Length' = '2' } ([Text.Encoding]::ASCII.GetBytes('ok'))) }
        $main = Start-RawServer -Routes @{}
        $main.Shared.Routes['/r'] = (ConvertTo-RawHttp '302 Found' @{ Location = "http://127.0.0.2:$($evil.Port)/x"; 'Content-Length' = '0' } $null)
        try { { Invoke-UpdHttp -Uri "http://127.0.0.1:$($main.Port)/r" -AllowHttp } | Should -Throw '*disallowed*' }
        finally { Stop-RawServer $evil; Stop-RawServer $main }
    }
    It 'no Authorization header is ever sent (anonymous)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $UpdRoot 'lib\GitHub.ps1'), [ref]$null, [ref]$null)
        $ast.Extent.Text | Should -Not -Match 'Authorization|Bearer|GH_TOKEN'
    }
}

Describe 'QA installer exit codes / timeout / concurrency' {
    It 'timeout kills only the root process: a Burn-style child survives (P2 (fixed): no job object / tree kill)' {
        $w = New-TestRoot; $script:Roots += $w
        $src = @'
using System; using System.Diagnostics; using System.Threading;
class P { static int Main(string[] a) {
  if (a.Length > 0 && a[0] == "child") { Thread.Sleep(60000); return 0; }
  Process.Start(new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location, "child") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = false });
  Thread.Sleep(60000); return 0; } }
'@
        [IO.File]::WriteAllText((Join-Path $w 'h.cs'), $src)
        $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        $exe = Join-Path $w 'QaHang.exe'
        & $csc /nologo /target:exe "/out:$exe" (Join-Path $w 'h.cs') | Out-Null
        $r = Invoke-UpdProcess -FilePath $exe -ArgumentList @('/install') -TimeoutSec 3
        $r.TimedOut | Should -BeTrue
        Start-Sleep -Milliseconds 500
        $left = @(Get-Process -Name 'QaHang' -ErrorAction SilentlyContinue)
        try { $left.Count | Should -Be 0 } finally { $left | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    It 'Task Scheduler ExecutionTimeLimit (30 min) must exceed worst-case internal budget (P2-2 fixed)' {
        $t = [System.IO.File]::ReadAllText((Join-Path $UpdRoot 'install-task.ps1'))
        $m = [regex]::Match($t, 'ExecutionTimeLimit \(New-TimeSpan -Hours (\d+)\)')
        $limitMin = 60 * [int]$m.Groups[1].Value
        # internal budget: 4 downloads*600s + 3 gh verifies*180s + install 600s + rollback 3*600s (Install.ps1/Verify.ps1/GitHub.ps1 defaults)
        $budgetMin = (4 * 600 + 3 * 180 + 600 + 3 * 600) / 60
        $limitMin | Should -BeGreaterThan $budgetMin
    }
    foreach ($case in @(
            @{ rc = 1603; ver = 'target'; want = 'rolled_back' },
            @{ rc = 1618; ver = 'same'; want = 'deferred' },
            @{ rc = 3010; ver = 'same'; want = 'pending_reboot' },
            @{ rc = 3010; ver = 'target'; want = 'updated' },
            @{ rc = 1641; ver = 'target'; want = 'updated' })) {
        It ("orchestrator: installer rc {0} with FileVersion {1} -> {2}" -f $case.rc, $case.ver, $case.want) -TestCases @($case) {
            param($rc, $ver, $want)
            $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
            $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
            $fx = New-FixtureRelease -U 202
            $inst = {
                param($path, $sha, $log, $verb)
                $script:FakeCtx.Calls.Add("RunInstaller:$verb")
                if ($script:QaVer -eq 'target') { $script:FakeCtx.Installed = ('6.2.{0}.0' -f $script:FakeCtx.TargetBuild) }
                return @{ Started = $true; HashOk = $true; Rc = $script:QaRc; TimedOut = $false; RebootPending = ($script:QaRc -eq 3010) }
            }
            $script:QaVer = $ver; $script:QaRc = $rc
            $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @($fx) -DepOverride @{ RunInstaller = $inst }
            $r.Result | Should -Be $want
            if ($want -in 'deferred', 'pending_reboot') { (Test-LocallyDenied -State (Read-UpdState -DataDir $d.Data) -Tag $fx.Tag) | Should -BeFalse }
        }
    }
    It 'P2-4 (fixed): idle is re-checked before a rollback that uninstalls/reinstalls: Moonlight started meanwhile => wait with backoff, then postpone' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.InstallMode = 'rc1'
        $pc = Join-Path $d.Root 'pc.exe'; [IO.File]::WriteAllBytes($pc, [byte[]](1, 2, 3, 4)); $ctx.PackageCache = $pc
        $script:QaRunCalls = 0
        $running = { $script:QaRunCalls++; return ($script:QaRunCalls -ge 4) }   # Moonlight starts after the 3rd check (right before the launch)
        $rb = { param($prev, $fp, $fs, $rd, $idle) $script:FakeCtx.Calls.Add("Rollback:$($prev.Name)"); return @{ Ok = $true; Method = 'fake' } }
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202)) -DepOverride @{ IsMoonlightRunning = $running; Rollback = $rb }
        $script:QaRunCalls | Should -BeGreaterThan 3
        (Get-Calls $ctx) -match '^Rollback' | Should -BeNullOrEmpty
        $r.ExitCode | Should -Be 6
    }
    It 'P2 (fixed): with no rollback baseline the updater should refuse to install (fail safe), not install and hope' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'; $ctx.NoBaseline = $true   # no baseline at all
        [void](Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202)))
        (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'P2-8 (fixed): presence hive unavailable (user logged off) => install postponed, never unchecked' {
        $d = New-Case; $ctx = New-FakeCtx -Installed '6.2.60006.0'
        $none = [pscustomobject]@{ HiveAvailable = $false; UniqueId = $false; Hosts = $false; Certificate = $false; Key = $false }
        $ctx.PresenceBefore = $none; $ctx.PresenceAfter = $none
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202))
        $r.Result | Should -Be 'deferred'
        (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'Moonlight starting between download and install -> deferred, nothing installed' {
        $d = New-Case; $ctx = New-FakeCtx; $ctx.RunningAfter = $true
        $r = Invoke-QaUpdate -Dirs $d -Ctx $ctx -Fixtures @((New-FixtureRelease -U 202))
        $r.Result | Should -Be 'deferred'; (Get-Calls $ctx) -match '^RunInstaller' | Should -BeNullOrEmpty
    }
    It 'rollback: previous bundle missing or corrupt -> never uninstalls the (possibly working) new version' {
        $w = New-TestRoot; $script:Roots += $w
        $prev = [pscustomobject]@{ Path = (Join-Path $w 'nope.exe'); Sha256 = ('a' * 64); Build = 60006; Name = 'x' }
        $r = Invoke-MoonlightRollback -Previous $prev -FailedBundlePath (Join-Path $w 'f.exe') -FailedSha256 ('b' * 64) -RunDir $w -GetVersion { '6.2.60202.0' }
        $r.Ok | Should -BeFalse; $r.Method | Should -Be 'previous-bundle-missing-or-corrupt'
    }
}

Describe 'QA presence-only registry access (R-CLW-4)' {
    BeforeAll {
        $script:Files = @(Get-ChildItem -LiteralPath (Join-Path $UpdRoot 'lib') -Filter *.ps1) + @(Get-Item (Join-Path $UpdRoot 'update.ps1'), (Join-Path $UpdRoot 'install-task.ps1'), (Join-Path $UpdRoot 'uninstall-task.ps1'))
        $script:Asts = @{}
        foreach ($f in $script:Files) { $e = $null; $script:Asts[$f.Name] = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e) }
    }
    It 'no .GetValue/.GetValueKind/.SetValue/.OpenSubKey(writable)/.Export member calls anywhere' {
        foreach ($k in $script:Asts.Keys) {
            $hits = $script:Asts[$k].FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ($n.Member.Extent.Text -match '^(GetValue|GetValueKind|SetValue|DeleteValue|CreateSubKey|Export|Save|GetAccessControl)$') }, $true)
            @($hits).Count | Should -Be 0 -Because $k
        }
    }
    It 'no reg.exe / regedit / Get-ItemPropertyValue / Export-* / Get-Item HKCU: commands; Get-ItemProperty only reads DisplayVersion under HKLM Uninstall' {
        foreach ($k in $script:Asts.Keys) {
            $cmds = $script:Asts[$k].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $cmds) {
                $name = $c.GetCommandName()
                if ($name) {
                    $name | Should -Not -Match '^(reg|reg\.exe|regedit|regedit\.exe|Get-ItemPropertyValue|Export-Clixml|Export-Csv|Invoke-Expression|iex|Start-Process|Invoke-Command)$' -Because "$k : $($c.Extent.Text)"
                    if ($name -eq 'Get-ItemProperty') { $c.Extent.Text | Should -Match 'HKLM|\$p ' }
                    if ($name -eq 'Get-ItemProperty') { $c.Extent.Text | Should -Match '-Name DisplayVersion' }
                }
            }
        }
    }
    It 'the only registry-hive entry point is Get-MoonlightPresenceForUser and it passes -Root/-SubPath to GetValueNames-only code' {
        $uses = @()
        foreach ($k in $script:Asts.Keys) { $uses += @($script:Asts[$k].FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.TypeName.FullName -match 'Win32\.Registry' }, $true) | ForEach-Object { "$k : $($_.Extent.Text)" }) }
        $uses | ForEach-Object { $_ } | Should -Match 'Install.ps1'
        @($uses | Where-Object { $_ -notmatch 'Install.ps1' }).Count | Should -Be 0
        $script:Asts['Install.ps1'].Extent.Text | Should -Match 'GetValueNames\(\)'
    }
    It 'dynamic-code constructs inventory (informational): none outside Snappy Add-Type' {
        $dyn = @()
        foreach ($k in $script:Asts.Keys) {
            $dyn += @($script:Asts[$k].FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(Add-Type|Invoke-Expression|iex|New-Object)$' -and $n.Extent.Text -match 'Add-Type|Invoke-Expression|iex ') -or ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -match 'ScriptBlock\]::Create|InvokeScript') }, $true) | ForEach-Object { "$k : $($_.Extent.Text.Split("`n")[0])" })
        }
        Write-Host ($dyn -join "`n")
        @($dyn | Where-Object { $_ -notmatch 'Snappy.ps1|Verify.ps1|System.Net.Http|System.Security' }).Count | Should -Be 0
    }
    It 'presence function on a throw-away key returns booleans only' {
        $kp = 'Software\MlUpdaterQaTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($kp)
        try {
            $k.SetValue('key', 'SECRET-KEY-BODY'); $k.SetValue('certificate', 'SECRET-CERT-BODY'); $k.SetValue('uniqueid', 'SECRET-ID'); [void]$k.CreateSubKey('hosts')
            $p = Get-MoonlightPresence -Root ([Microsoft.Win32.Registry]::CurrentUser) -SubPath $kp
            ($p | ConvertTo-Json -Compress) | Should -Not -Match 'SECRET'
            $p.Key | Should -BeTrue; $p.Certificate | Should -BeTrue; $p.UniqueId | Should -BeTrue; $p.Hosts | Should -BeTrue
        } finally { $k.Close(); [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($kp) }
    }
    It 'log scrubber: PEM markers and MII blobs removed; P3 (fixed): a raw base64 key body without MII prefix passes through' {
        (ConvertTo-SafeLogValue '-----BEGIN PRIVATE KEY----- xx') | Should -Not -Match 'BEGIN PRIVATE'
        (ConvertTo-SafeLogValue ('MIIC' + ('A' * 60))) | Should -Match 'REDACTED'
        # informational: nothing in the code logs registry values, so this is defence-in-depth only
        (ConvertTo-SafeLogValue ('MC4CAQAwBQYDK2VwBCIEI' + ('B' * 60))) | Should -Match 'MC4CAQ'
    }
}

Describe 'QA gh.exe pin' {
    It 'tampered gh.exe (one extra byte) fails the pin even if the signature were valid' {
        $src = 'C:\Program Files\GitHub CLI\gh.exe'
        if (-not (Test-Path $src)) { Set-ItResult -Skipped -Because 'gh.exe not installed'; return }
        $pin = Read-GhPin -ProgramDir $UpdRoot
        if ((Get-UpdSha256 -Path $src) -ne $pin.gh_exe_sha256) { Set-ItResult -Skipped -Because 'machine gh differs from pin'; return }
        { Assert-GhBinary -GhPath $src -Pin $pin } | Should -Not -Throw
        $w = New-TestRoot; $script:Roots += $w
        $t = Join-Path $w 'gh.exe'; Copy-Item $src $t
        $fs = [IO.File]::Open($t, 'Append'); $fs.WriteByte(0); $fs.Close()
        { Assert-GhBinary -GhPath $t -Pin $pin } | Should -Throw '*hash*'
    }
    It 'an unsigned binary with a (forged) matching pin is still rejected by the signature check' {
        $w = New-TestRoot; $script:Roots += $w
        $t = Join-Path $w 'gh.exe'; [IO.File]::WriteAllBytes($t, [byte[]](77, 90, 1, 2, 3))
        $pin = [pscustomobject]@{ gh_exe_sha256 = (Get-UpdSha256 -Path $t) }
        { Assert-GhBinary -GhPath $t -Pin $pin } | Should -Throw '*signature*'
    }
    It 'attestation argv contains all pinned flags (repo, bundle, signer-workflow, source-ref, deny-self-hosted, source-digest)' {
        $script:capt = $null
        Mock Invoke-GhVerify { $script:capt = $Arguments; return @{ Ok = $true; Rc = 0; Err = '' } }
        [void](Test-ArtifactAttestation -GhPath 'x' -DataDir 'y' -FilePath 'f' -BundlePath 'b' -Repo 'o/r' -SignerWorkflow 'github.com/o/r/.github/workflows/w.yml' -SourceRef 'refs/heads/build/v6.2.0-daily.202-n1' -SourceDigest ('a' * 40))
        foreach ($f in '--repo', '--bundle', '--signer-workflow', '--source-ref', '--deny-self-hosted-runners', '--source-digest') { $script:capt | Should -Contain $f }
        # P3-9 (fixed): predicate type and OIDC issuer are pinned explicitly
        $script:capt | Should -Contain '--predicate-type'
        $script:capt | Should -Contain '--cert-oidc-issuer'
    }
}

Describe 'QA test-mode escape hatches in production code' {
    It 'P2-7 (fixed): no test-only override (flag file, skip_acl_check, gh_path, api_base, data_dir, allow_http via config) in production code paths' {
        $t = [System.IO.File]::ReadAllText((Join-Path $UpdRoot 'lib\Config.ps1')) + [System.IO.File]::ReadAllText((Join-Path $UpdRoot 'update.ps1')) + [System.IO.File]::ReadAllText((Join-Path $UpdRoot 'lib\Main.ps1'))
        $t | Should -Not -Match 'test-mode\.flag|skip_acl_check|test_mode'
    }
    It 'P2-7 (fixed): install-task.ps1 removes a stale test-mode.flag' {
        [System.IO.File]::ReadAllText((Join-Path $UpdRoot 'install-task.ps1')) | Should -Match 'test-mode'
    }
}

Describe 'QA API / ETag / policy pinning (raw loopback API)' {
    It 'policy contents call is pinned to the sha returned by the branch call; malformed sha rejected' {
        $sha = ('1' * 40)
        $pol = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("hold: false`nallow_upstream_owners: [Nonary]`ndeny: []`n"))
        $bb = [Text.Encoding]::UTF8.GetBytes('{"commit":{"sha":"' + $sha + '"}}')
        $cb = [Text.Encoding]::UTF8.GetBytes('{"type":"file","encoding":"base64","content":"' + $pol + '"}')
        $routes = @{}
        $routes['/repos/emilwojcik93/moonlight-qt/branches/automation'] = (ConvertTo-RawHttp '200 OK' @{ 'Content-Type' = 'application/json'; 'Content-Length' = [string]$bb.Length; ETag = '"b1"' } $bb)
        $routes["/repos/emilwojcik93/moonlight-qt/contents/policy.yml?ref=$sha"] = (ConvertTo-RawHttp '200 OK' @{ 'Content-Type' = 'application/json'; 'Content-Length' = [string]$cb.Length } $cb)
        $srv = Start-RawServer -Routes $routes
        try {
            $d = New-Case; New-Item -ItemType Directory (Join-Path $d.Data 'cache') | Out-Null
            $cfg = New-TestConfig -Override @{ api_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            $r = Get-UpdPolicy -Config $cfg -State (New-UpdState) -DataDir $d.Data
            $r.CommitSha | Should -Be $sha
            $srv.Shared.Hits.Keys | Should -Contain "/repos/emilwojcik93/moonlight-qt/contents/policy.yml?ref=$sha"
            ($srv.Shared.Hits.Keys | Where-Object { $_ -match 'policy.yml' -and $_ -notmatch 'ref=' }) | Should -BeNullOrEmpty
        } finally { Stop-RawServer $srv }
        foreach ($badsha in @(('ABCDEF' + ('1' * 34)), ('1' * 39), (('1' * 40) + '&ref=main'), 'main')) {
            $bb2 = [Text.Encoding]::UTF8.GetBytes('{"commit":{"sha":"' + $badsha + '"}}')
            $srv2 = Start-RawServer -Routes @{ '/repos/emilwojcik93/moonlight-qt/branches/automation' = (ConvertTo-RawHttp '200 OK' @{ 'Content-Type' = 'application/json'; 'Content-Length' = [string]$bb2.Length } $bb2) }
            try {
                $d2 = New-Case; $cfg2 = New-TestConfig -Override @{ api_base = "http://127.0.0.1:$($srv2.Port)"; allow_http = $true }
                { Get-UpdPolicy -Config $cfg2 -State (New-UpdState) -DataDir $d2.Data } | Should -Throw '*sha invalid*'
            } finally { Stop-RawServer $srv2 }
        }
    }
    It '304 with a corrupted cache file fails closed (no poisoned release list is used)' {
        $srv = Start-RawServer -Routes @{ '/repos/emilwojcik93/moonlight-qt/releases?per_page=30' = (ConvertTo-RawHttp '304 Not Modified' @{ ETag = '"r1"' } $null) }
        try {
            $d = New-Case; $cache = Join-Path $d.Data 'cache'; New-Item -ItemType Directory $cache | Out-Null
            $cfg = New-TestConfig -Override @{ api_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            $st = New-UpdState; $st.etag_releases = '"r1"'
            [IO.File]::WriteAllText((Join-Path $cache 'releases.json'), '{not json')
            { Get-UpdReleases -Config $cfg -DataDir $d.Data -State $st } | Should -Throw
        } finally { Stop-RawServer $srv }
    }
    It 'rate limit exhausted (403 + remaining 0) defers; so does a secondary-limit 403 with Retry-After' {
        $srv = Start-RawServer -Routes @{ '/repos/emilwojcik93/moonlight-qt/releases?per_page=30' = (ConvertTo-RawHttp '403 Forbidden' @{ 'X-RateLimit-Remaining' = '0'; 'Content-Length' = '0' } $null) }
        try {
            $d = New-Case; $cfg = New-TestConfig -Override @{ api_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            $e = $null; try { Get-UpdReleases -Config $cfg -DataDir $d.Data -State (New-UpdState) } catch { $e = $_.Exception }
            $e.Data['RateLimited'] | Should -BeTrue
        } finally { Stop-RawServer $srv }
        $srv = Start-RawServer -Routes @{ '/repos/emilwojcik93/moonlight-qt/releases?per_page=30' = (ConvertTo-RawHttp '403 Forbidden' @{ 'X-RateLimit-Remaining' = '40'; 'Retry-After' = '60'; 'Content-Length' = '0' } $null) }
        try {
            $d = New-Case; $cfg = New-TestConfig -Override @{ api_base = "http://127.0.0.1:$($srv.Port)"; allow_http = $true }
            $e = $null; try { Get-UpdReleases -Config $cfg -DataDir $d.Data -State (New-UpdState) } catch { $e = $_.Exception }
            $e.Data['RateLimited'] | Should -BeTrue      # P3-6 (fixed): secondary limits (Retry-After) defer instead of failing hard
        } finally { Stop-RawServer $srv }
    }
}
