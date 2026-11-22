# Installed-version detection, idle check, presence-only registry checks (never reads values), installer run
# with deny-write handle + re-hash, bundle store (keep 2), rollback.

Set-StrictMode -Version Latest

# ---- installed version ----------------------------------------------------------------------------
function Get-InstalledMoonlightVersion {
    <# FileVersion of Moonlight.exe ("6.2.60006.0") or $null; falls back to the Burn bundle ARP DisplayVersion. #>
    [CmdletBinding()]
    param([string]$ExePath = $script:UpdConst.MoonlightExe, [string]$BundleGuid = $script:UpdConst.BundleGuid)
    if (Test-Path -LiteralPath $ExePath -PathType Leaf) {
        $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
        if ($vi.FileMajorPart -gt 0 -or $vi.FileMinorPart -gt 0 -or $vi.FileBuildPart -gt 0) {
            return ('{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
        }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $p = Join-Path $root $BundleGuid
        if (Test-Path -LiteralPath $p) {
            $dv = (Get-ItemProperty -LiteralPath $p -Name DisplayVersion -ErrorAction SilentlyContinue)
            if ($null -ne $dv -and $dv.PSObject.Properties.Name -contains 'DisplayVersion') { return [string]$dv.DisplayVersion }
        }
    }
    return $null
}

function Test-MoonlightRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ProcessName = $script:UpdConst.MoonlightProcess)
    return (@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0)
}

# ---- interactive user hive (presence only) ----------------------------------------------------------
function Get-InteractiveUserSid {
    <# SYSTEM has its own HKCU. Find the console user: Win32_ComputerSystem.UserName, else explorer.exe owner. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $sidRx = '^S-1-(5-21|12-1)-[0-9-]{5,80}$'
    try {
        $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) {
            $sid = (New-Object System.Security.Principal.NTAccount($u)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($sid -match $sidRx) { return $sid }
        }
    } catch { Write-Verbose 'ComputerSystem user lookup failed' }
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
            if ($o.ReturnValue -eq 0 -and $o.Sid -match $sidRx) { return [string]$o.Sid }
        }
    } catch { Write-Verbose 'explorer owner lookup failed' }
    return $null
}

function Get-MoonlightPresence {
    <#
      PRESENCE ONLY. Opens the key read-only and uses GetValueNames()/GetSubKeyNames(); never GetValue().
      Returns booleans; HiveAvailable=$false when the user's hive (or the key) is not loaded/present.
      -Root/-SubPath are injectable so tests can point at a throw-away key instead of the real one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Root,
        [Parameter(Mandatory)][string]$SubPath
    )
    $res = [ordered]@{ HiveAvailable = $false; UniqueId = $false; Hosts = $false; Certificate = $false; Key = $false }
    $k = $null
    try { $k = $Root.OpenSubKey($SubPath, $false) } catch { $k = $null }
    if ($null -eq $k) { return [pscustomobject]$res }
    try {
        $res.HiveAvailable = $true
        $vals = @($k.GetValueNames() | ForEach-Object { $_.ToLowerInvariant() })
        $subs = @($k.GetSubKeyNames() | ForEach-Object { $_.ToLowerInvariant() })
        $res.UniqueId = ($vals -contains 'uniqueid')
        $res.Certificate = ($vals -contains 'certificate')
        $res.Key = ($vals -contains 'key')
        $res.Hosts = ($subs -contains 'hosts')
    } finally { $k.Close() }
    return [pscustomobject]$res
}

function Get-MoonlightPresenceForUser {
    [CmdletBinding()]
    param()
    $sid = Get-InteractiveUserSid
    if (-not $sid) { return [pscustomobject]@{ HiveAvailable = $false; UniqueId = $false; Hosts = $false; Certificate = $false; Key = $false } }
    return (Get-MoonlightPresence -Root ([Microsoft.Win32.Registry]::Users) -SubPath ($sid + '\' + $script:UpdConst.HkcuSubPath))
}

function Compare-Presence {
    <# Returns the list of items present BEFORE but missing AFTER. Unknown before => nothing to compare. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $lost = New-Object System.Collections.Generic.List[string]
    if (-not $Before.HiveAvailable) { return }
    if (-not $After.HiveAvailable) { return 'hive-or-key-missing-after-install' }
    foreach ($n in 'UniqueId', 'Hosts', 'Certificate', 'Key') {
        if ($Before.$n -and -not $After.$n) { $lost.Add($n) }
    }
    return $lost.ToArray()
}

# ---- installer execution ----------------------------------------------------------------------------
function Invoke-MoonlightInstaller {
    <#
      Runs `<installer> /install /quiet /norestart /log <log>` from the SAME verified file:
      holds a FileShare.Read handle (nobody can write/replace/delete it) and re-hashes through that handle
      immediately before launch. Returns @{Started;HashOk;Rc;TimedOut;RebootPending}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$LogPath,
        [ValidateSet('install', 'uninstall')][string]$Verb = 'install',
        [int]$TimeoutSec = 600
    )
    $h = Open-DenyWriteHandle -Path $InstallerPath
    try {
        $actual = Get-UpdSha256FromStream -Stream $h
        if ($actual -ne $ExpectedSha256) { return @{ Started = $false; HashOk = $false; Rc = $null; TimedOut = $false; RebootPending = $false } }
        $iargs = @(('/' + $Verb), '/quiet', '/norestart', '/log', $LogPath)
        $r = Invoke-UpdProcess -FilePath $InstallerPath -ArgumentList $iargs -TimeoutSec $TimeoutSec
        return @{ Started = $true; HashOk = $true; Rc = $r.Rc; TimedOut = $r.TimedOut; RebootPending = ($r.Rc -eq 3010) }
    } finally { $h.Dispose() }
}

# ---- bundle store (keep last 2 verified bundles) ------------------------------------------------------
function Add-VerifiedBundle {
    <# Copies the verified installer into <data>\bundles\<name>\ and records meta; returns the stored path. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$Name,        # tag or 'installed-<build>'
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][int]$BuildNumber,
        [string[]]$AdditionalFullControlSids = @()
    )
    if (-not (Test-UpdRegex $Name '^(v6\.2\.0-daily\.[0-9]{1,5}-vp\.[0-9]{1,3}|installed-[0-9]{5})$')) { throw 'bundle name invalid' }
    $root = Join-Path $DataDir 'bundles'
    Initialize-SecureDirectory -Path $root -AdditionalFullControlSids $AdditionalFullControlSids
    $dir = Join-Path $root $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $dest = Join-Path $dir 'MoonlightSetup.exe'
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    if ((Get-UpdSha256 -Path $dest) -ne $Sha256) { Remove-Item -LiteralPath $dir -Recurse -Force; throw 'stored bundle hash mismatch' }
    $meta = [pscustomobject]@{ name = $Name; sha256 = $Sha256; build = $BuildNumber; stored_utc = (Get-UpdNowUtc).ToString('o') }
    [System.IO.File]::WriteAllText((Join-Path $dir 'meta.json'), ($meta | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    return $dest
}

function Get-VerifiedBundles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir)
    $root = Join-Path $DataDir 'bundles'
    $out = @()
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $mp = Join-Path $d.FullName 'meta.json'
        $ep = Join-Path $d.FullName 'MoonlightSetup.exe'
        if (-not (Test-Path -LiteralPath $mp) -or -not (Test-Path -LiteralPath $ep)) { continue }
        try { $m = [System.IO.File]::ReadAllText($mp) | ConvertFrom-Json } catch { continue }
        if (-not (Test-UpdRegex ([string]$m.sha256) '^[0-9a-f]{64}$')) { continue }
        $out += [pscustomobject]@{ Name = [string]$m.name; Sha256 = [string]$m.sha256; Build = [int]$m.build; Path = $ep; Dir = $d.FullName }
    }
    return @($out | Sort-Object -Property Build -Descending)
}

function Remove-ExcessBundles {
    <# Keep the newest $Keep bundles (by build number) plus anything in $Protect (names). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [int]$Keep = 2, [string[]]$Protect = @())
    $b = @(Get-VerifiedBundles -DataDir $DataDir)
    $i = 0
    foreach ($x in $b) {
        $i++
        if ($i -le $Keep) { continue }
        if ($Protect -contains $x.Name) { continue }
        Remove-Item -LiteralPath $x.Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MoonlightRollback {
    <#
      Re-installs the previous verified bundle. Attempt 1: install over the new version. If the version did not
      change (Burn/MSI blocks downgrades), attempt 2: uninstall the failed bundle first, then install previous.
      Returns @{Ok;Method}. All executions go through Invoke-MoonlightInstaller (hash re-check, deny-write).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Previous,           # from Get-VerifiedBundles
        [Parameter(Mandatory)][string]$FailedBundlePath,
        [Parameter(Mandatory)][string]$FailedSha256,
        [Parameter(Mandatory)][string]$RunDir,
        [scriptblock]$GetVersion = { Get-InstalledMoonlightVersion }
    )
    # never uninstall anything if the previous bundle is not intact: a failed-health install beats no install
    if ((-not (Test-Path -LiteralPath $Previous.Path -PathType Leaf)) -or ((Get-UpdSha256 -Path $Previous.Path) -ne $Previous.Sha256)) {
        return @{ Ok = $false; Method = 'previous-bundle-missing-or-corrupt' }
    }
    $log1 = Join-Path $RunDir 'rollback-install.log'
    $r1 = Invoke-MoonlightInstaller -InstallerPath $Previous.Path -ExpectedSha256 $Previous.Sha256 -LogPath $log1
    $fv = ConvertFrom-FileVersion -Version (& $GetVersion)
    if ($r1.Started -and $null -ne $fv -and $fv.Build -eq $Previous.Build) { return @{ Ok = $true; Method = 'install-over' } }
    $log2 = Join-Path $RunDir 'rollback-uninstall.log'
    $null = Invoke-MoonlightInstaller -InstallerPath $FailedBundlePath -ExpectedSha256 $FailedSha256 -LogPath $log2 -Verb uninstall
    $log3 = Join-Path $RunDir 'rollback-install2.log'
    $r3 = Invoke-MoonlightInstaller -InstallerPath $Previous.Path -ExpectedSha256 $Previous.Sha256 -LogPath $log3
    $fv = ConvertFrom-FileVersion -Version (& $GetVersion)
    if ($r3.Started -and $null -ne $fv -and $fv.Build -eq $Previous.Build) { return @{ Ok = $true; Method = 'uninstall-then-install' } }
    return @{ Ok = $false; Method = 'failed' }
}
