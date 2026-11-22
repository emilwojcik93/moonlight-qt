# Shared helpers for the Pester v5 suite. Dot-sourced from each *.Tests.ps1 BeforeAll.
# Everything here runs in a sandbox: temp dirs, fake dependencies, throw-away registry key under HKCU:\Software\MlUpdaterPesterTest.

Set-StrictMode -Version Latest

$script:UpdRoot = Split-Path -Parent $PSScriptRoot
$script:LibFiles = @('Common', 'Version', 'Yaml', 'Config', 'Security', 'GitHub', 'Verify', 'Install', 'Notify', 'Orchestrator', 'Main', 'Snappy')

function New-TestRoot {
    $r = Join-Path ([System.IO.Path]::GetTempPath()) ('mlu-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $r | Out-Null
    return $r
}

function Get-CurrentSidValue { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function New-TestDirs {
    <# ProgramDir + DataDir under a temp root, with the current (non-admin) user allowed so the sandbox stays usable. #>
    $root = New-TestRoot
    $prog = Join-Path $root 'prog'; $data = Join-Path $root 'data'
    New-Item -ItemType Directory -Path $prog, $data | Out-Null
    return [pscustomobject]@{ Root = $root; Prog = $prog; Data = $data; Sid = (Get-CurrentSidValue) }
}

function New-TestConfig {
    param([hashtable]$Override = @{})
    $c = @{}
    foreach ($k in $script:UpdConfigDefaults.Keys) { $c[$k] = $script:UpdConfigDefaults[$k] }
    $c['mode'] = 'install'
    $c['min_cooling_off_hours'] = 0        # the production default floor is 2 h; tests opt in explicitly
    $c['api_base'] = 'https://api.github.com'
    $c['download_base'] = 'https://github.com'
    foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
    return $c
}

function New-FixtureRelease {
    <# Builds an attested-looking release fixture. Hash/size fields are consistent unless a switch breaks them. #>
    param(
        [int]$U = 202, [int]$N = 1,
        [string]$PublishedAt = ((Get-Date).ToUniversalTime().AddHours(-48).ToString('yyyy-MM-ddTHH:mm:ssZ')),
        [string]$Owner = 'Nonary',
        [switch]$NotImmutable, [switch]$Prerelease, [byte[]]$InstallerBytes
    )
    $tag = 'v6.2.0-daily.{0}-vp.{1}' -f $U, $N
    $build = ConvertTo-BuildNumber -U $U -N $N      # CONTRACT 3b: 60000 + 8*U + (N-1)
    $rng = New-Object System.Random($U * 1000 + $N)
    $inst = New-Object byte[] 4096; $rng.NextBytes($inst)
    if ($InstallerBytes) { $inst = $InstallerBytes }
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($inst)) -replace '-', '').ToLowerInvariant()
    $manifest = [ordered]@{
        schema = 1; product = 'moonlight'; tag = $tag
        upstream = @{ owner = $Owner; repo = 'moonlight-qt'; tag = ('v6.2.0-daily.{0}' -f $U); commit = ('a' * 40); release_id = 1 }
        build = @{ n = $N; version = ('6.2.0-daily.{0}' -f $build); run_id = 1; workflow = '.github/workflows/patched-windows-release.yml'
            source_ref = ('refs/heads/build/v6.2.0-daily.{0}-n{1}' -f $U, $N); source_sha = ('b' * 40) }
        patches = @{ series_sha256 = ('c' * 64); count = 7; groups = @('posture-core') }
        installer = 'MoonlightSetup.exe'
        assets = @(@{ name = 'MoonlightSetup.exe'; sha256 = $sha; size = $inst.Length })
        attestation = @('attestation.sigstore.json')
        created_at = '2026-11-22T00:00:00Z'
    }
    $manifestText = $manifest | ConvertTo-Json -Depth 6
    $manifestBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($manifestText)
    $msha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($manifestBytes)) -replace '-', '').ToLowerInvariant()
    $sums = "{0}  MoonlightSetup.exe`n{1}  manifest.json`n" -f $sha, $msha
    $files = @{
        'MoonlightSetup.exe' = $inst
        'SHA256SUMS' = (New-Object System.Text.UTF8Encoding($false)).GetBytes($sums)
        'manifest.json' = $manifestBytes
        'attestation.sigstore.json' = [System.Text.Encoding]::UTF8.GetBytes('{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}')
    }
    $assets = @()
    foreach ($fname in $files.Keys) {
        $h = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([byte[]]$files[$fname])) -replace '-', '').ToLowerInvariant()
        $assets += [pscustomobject]@{ name = $fname; size = $files[$fname].Length; digest = ('sha256:' + $h) }
    }
    $rel = [pscustomobject]@{
        tag_name = $tag; draft = $false; prerelease = $true; published_at = $PublishedAt
        immutable = (-not [bool]$NotImmutable); assets = $assets
    }
    return [pscustomobject]@{ Tag = $tag; Release = $rel; Files = $files; Sha = $sha; Build = $build; U = $U; N = $N }
}

function New-DefaultPolicy {
    param([bool]$Hold = $false, [string[]]$Deny = @(), [int]$Canary = 0)
    return [pscustomobject]@{ Hold = $Hold; Deny = $Deny; AllowOwners = @('Nonary'); CoolingOff = @{ stable = 24; canary = $Canary }; HasDenyKey = $true }
}

function New-FakeCtx {
    <# Mutable context shared with the closures of New-FakeDeps. #>
    param([string]$Installed = '6.2.60006.0')
    return @{
        Installed = $Installed; Running = $false; RunningAfter = $null; Policy = (New-DefaultPolicy); Fixtures = @(); VerifyOk = $true
        VerifyFailFor = @(); InstallMode = 'ok'; PresenceBefore = $null; PresenceAfter = $null; RollbackOk = $true
        PolicyThrows = $null; ReleasesThrows = $null; Calls = (New-Object System.Collections.Generic.List[string]); Notified = (New-Object System.Collections.Generic.List[string])
        PackageCache = $null; PresenceCalls = 0; RunningCalls = 0; TamperInstallerOnDownload = $false; Now = $null
        RunningSeq = $null; NoBaseline = $false; Sleeps = (New-Object System.Collections.Generic.List[int]); BootTime = (Get-Date).ToUniversalTime().AddDays(-1)
        DownloadThrows = $null; ServerDate = $null
    }
}

function New-FakeDeps {
    param([Parameter(Mandatory)][hashtable]$Ctx, [string[]]$Sids = @())
    $script:FakeCtx = $Ctx
    $d = @{}
    $d.GhPath = 'C:\fake\gh.exe'
    $d.AdditionalFullControlSids = $Sids
    $d.Now = { if ($script:FakeCtx.Now) { $script:FakeCtx.Now } else { (Get-Date).ToUniversalTime() } }
    $d.GetReleases = {
        param($cfg, $dataDir, $state)
        $script:FakeCtx.Calls.Add('GetReleases')
        if ($script:FakeCtx.ReleasesThrows) { throw $script:FakeCtx.ReleasesThrows }
        return @{ Releases = @($script:FakeCtx.Fixtures | ForEach-Object { $_.Release }); FromCache = $false; Etag = 'x'; RateLimit = $null; ServerDate = $script:FakeCtx.ServerDate }
    }
    $d.GetPolicy = {
        param($cfg, $state, $dataDir)
        $script:FakeCtx.Calls.Add('GetPolicy')
        if ($script:FakeCtx.PolicyThrows) { throw $script:FakeCtx.PolicyThrows }
        return @{ Policy = $script:FakeCtx.Policy; CommitSha = ('d' * 40) }
    }
    $d.GetInstalledVersion = { $script:FakeCtx.Installed }
    $d.IsMoonlightRunning = {
        $script:FakeCtx.RunningCalls++
        if ($null -ne $script:FakeCtx.RunningSeq -and @($script:FakeCtx.RunningSeq).Count -gt 0) {
            $first = @($script:FakeCtx.RunningSeq)[0]
            $script:FakeCtx.RunningSeq = @(@($script:FakeCtx.RunningSeq) | Select-Object -Skip 1)
            return [bool]$first
        }
        if ($script:FakeCtx.RunningCalls -gt 1 -and $null -ne $script:FakeCtx.RunningAfter) { return [bool]$script:FakeCtx.RunningAfter }
        return [bool]$script:FakeCtx.Running
    }
    $d.GetPresence = {
        $script:FakeCtx.PresenceCalls++
        $p = if ($script:FakeCtx.PresenceCalls -le 1) { $script:FakeCtx.PresenceBefore } else { $script:FakeCtx.PresenceAfter }
        if ($null -eq $p) { $p = [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $true; Key = $true } }
        return $p
    }
    $d.Download = {
        param($cfg, $tag, $name, $runDir, $maxBytes, $expectedSize, $timeoutSec)
        $script:FakeCtx.Calls.Add("Download:$name")
        if ($script:FakeCtx.DownloadThrows) { throw $script:FakeCtx.DownloadThrows }
        $fx = $script:FakeCtx.Fixtures | Where-Object { $_.Tag -ceq $tag } | Select-Object -First 1
        if ($null -eq $fx -or -not $fx.Files.ContainsKey($name)) { throw "HTTP 404 $name" }
        $bytes = [byte[]]$fx.Files[$name]
        if ($script:FakeCtx.TamperInstallerOnDownload -and $name -eq 'MoonlightSetup.exe') { $bytes = $bytes.Clone(); $bytes[10] = $bytes[10] -bxor 0xFF }
        if ($bytes.Length -gt $maxBytes) { throw 'download exceeds cap' }
        $dest = Join-Path $runDir $name
        [System.IO.File]::WriteAllBytes($dest, $bytes)
        return $dest
    }
    $d.AssertGh = { param($gh, $progDir) $script:FakeCtx.Calls.Add('AssertGh') }
    $d.VerifyAttestation = {
        param($gh, $dataDir, $file, $bundle, $repo, $signer, $ref, $digest)
        $leaf = Split-Path $file -Leaf
        $script:FakeCtx.Calls.Add("Verify:$leaf")
        $ok = $script:FakeCtx.VerifyOk -and ($script:FakeCtx.VerifyFailFor -notcontains $leaf)
        return @{ Ok = $ok; Rc = $(if ($ok) { 0 } else { 1 }); Err = $(if ($ok) { '' } else { 'verifying with issuer "sigstore.dev"' }) }
    }
    $d.VerifyReleaseOnline = { param($gh, $dataDir, $repo, $tag, $file) $script:FakeCtx.Calls.Add('VerifyOnline'); return @{ Ok = $true; Rc = 0; Err = '' } }
    $d.RunInstaller = {
        param($path, $sha, $log, $verb)
        $script:FakeCtx.Calls.Add("RunInstaller:$verb")
        $res = { param($rc, $timedOut = $false, $tree = $true, $msi = $true) @{ Started = $true; HashOk = $true; Rc = $rc; TimedOut = $timedOut; RebootPending = ($rc -eq 3010); TreeGone = $tree; MsiIdle = $msi } }
        if ((Get-UpdSha256 -Path $path) -ne $sha) { return @{ Started = $false; HashOk = $false; Rc = $null; TimedOut = $false; RebootPending = $false; TreeGone = $true; MsiIdle = $true } }
        $target = ('6.2.{0}.0' -f $script:FakeCtx.TargetBuild)
        switch ($script:FakeCtx.InstallMode) {
            'ok' { $script:FakeCtx.Installed = $target; return (& $res 0) }
            'reboot' { $script:FakeCtx.Installed = $target; return (& $res 3010) }
            'rc3010same' { return (& $res 3010) }
            'rc1641' { $script:FakeCtx.Installed = $target; return (& $res 1641) }
            'rc1641same' { return (& $res 1641) }
            'rc1618' { return (& $res 1618) }
            'wrongversion' { return (& $res 0) }
            'rc1' { return (& $res 1603) }
            'timeout' { return (& $res -1 $true $true $true) }
            'stuck' { return (& $res -1 $true $false $true) }
            'loseCert' {
                $script:FakeCtx.Installed = $target
                $script:FakeCtx.PresenceAfter = [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $false; Key = $true }
                return (& $res 0)
            }
        }
    }
    $d.Rollback = {
        param($prev, $failedPath, $failedSha, $runDir, $idle)
        $script:FakeCtx.Calls.Add("Rollback:$($prev.Name)")
        if ($script:FakeCtx.RollbackOk) { $script:FakeCtx.Installed = ('6.2.{0}.0' -f $prev.Build) }
        return @{ Ok = [bool]$script:FakeCtx.RollbackOk; Method = 'fake' }
    }
    $d.Notify = { param($cfg, $dataDir, $result, $tag, $detail) $script:FakeCtx.Notified.Add("$result|$tag") }
    $d.TestPathAcl = { param($p) return @() }
    $d.PackageCacheBundle = { $script:FakeCtx.PackageCache }
    $d.Sleep = { param($sec) $script:FakeCtx.Sleeps.Add([int]$sec) }
    $d.GetBootTime = { $script:FakeCtx.BootTime }
    return $d
}

function Invoke-FakeUpdate {
    param([Parameter(Mandatory)]$Dirs, [Parameter(Mandatory)][hashtable]$Ctx, [hashtable]$ConfigOverride = @{}, [string]$ModeOverride, [switch]$VerifyOnly, [object[]]$Fixtures)
    if ($Fixtures) { $Ctx.Fixtures = $Fixtures }
    if (-not $Ctx.ContainsKey('TargetBuild')) {
        $newest = $Ctx.Fixtures | Sort-Object -Property Build -Descending | Select-Object -First 1
        if ($newest) { $Ctx.TargetBuild = $newest.Build } else { $Ctx.TargetBuild = 0 }
    }
    if (-not $Ctx.NoBaseline -and -not $Ctx.PackageCache) {
        $pcf = Join-Path $Dirs.Root 'package-cache-bundle.exe'
        if (-not (Test-Path $pcf)) { [System.IO.File]::WriteAllBytes($pcf, [byte[]](1, 2, 3, 4, 5)) }
        $Ctx.PackageCache = $pcf
    }
    Initialize-UpdLog -LogDir (Join-Path $Dirs.Data 'logs') -RunId 'test'
    $cfg = New-TestConfig -Override $ConfigOverride
    $deps = New-FakeDeps -Ctx $Ctx -Sids @($Dirs.Sid)
    return (Invoke-MoonlightUpdate -ProgramDir $Dirs.Prog -DataDir $Dirs.Data -Config $cfg -Deps $deps -ModeOverride $ModeOverride -VerifyOnly:$VerifyOnly)
}

function Get-AllLogText {
    param([string]$Root)
    $t = ''
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.log' -or $_.Name -like '*.log.1' })) { $t += [System.IO.File]::ReadAllText($f.FullName) + "`n" }
    return $t
}

function Remove-UpdDenyForTest {
    <# Test convenience: forget attempts/denies so that a loop can produce many runs for one tag. #>
    param([string]$DataDir)
    $st = Read-UpdState -DataDir $DataDir
    $st.denied = @(); $st.attempts = (New-Object psobject)
    Save-UpdState -DataDir $DataDir -State $st
}
