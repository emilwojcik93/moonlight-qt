# Verification chain (CONTRACT 4, steps 3, 5, 6): gh.exe provisioning checks, gh runner without a shell,
# offline attestation verification (U3), manifest + SHA256SUMS parsing, hash comparison.

Set-StrictMode -Version Latest

function ConvertTo-WinArg {
    <# Quote one argument for a Windows command line (CommandLineToArgvW rules). No shell is involved. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Arg)
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\', $bs * 2 + 1); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\', $bs * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

if (-not ('MlUpdater.JobObject' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MlUpdater {
    public sealed class JobObject : IDisposable {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        IntPtr handle;
        public JobObject() { handle = CreateJobObject(IntPtr.Zero, null); }
        public bool Valid { get { return handle != IntPtr.Zero; } }
        public bool Assign(IntPtr processHandle) { return handle != IntPtr.Zero && AssignProcessToJobObject(handle, processHandle); }
        public bool Terminate() { return handle != IntPtr.Zero && TerminateJobObject(handle, 1); }
        public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
    }
}
'@
}

function Get-ProcessDescendantId {
    <# Parent walk over Win32_Process (snapshot). Returns the PIDs of all descendants of -RootPid. #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory)][int]$RootPid)
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
    $found = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        foreach ($p in $all) {
            if ($p.ParentProcessId -eq $cur -and $p.ProcessId -ne $cur -and -not $found.Contains([int]$p.ProcessId)) {
                $found.Add([int]$p.ProcessId); $queue.Enqueue([int]$p.ProcessId)
            }
        }
    }
    return , @($found.ToArray())
}

function Stop-ProcessTree {
    <# Kills the root, everything in its job object and every descendant found by a parent walk; returns $true when all are gone. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Root, $Job, [int]$WaitSec = 30)
    $ids = New-Object System.Collections.Generic.List[int]
    $ids.Add($Root.Id)
    foreach ($d in (Get-ProcessDescendantId -RootPid $Root.Id)) { $ids.Add($d) }
    if ($null -ne $Job) { [void]$Job.Terminate() }
    foreach ($id in $ids) { try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { Write-Verbose 'stop-process failed' } }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        $alive = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-UpdProcess {
    <#
      Runs an executable with an argument ARRAY (UseShellExecute=false, no cmd.exe, no string concatenation of
      user data), captures stdout/stderr, enforces a timeout. The process is placed in a job object; on timeout the WHOLE
      TREE (job members + descendants found by a parent walk) is killed and the call only returns once the tree is gone
      (TreeGone) or the wait expired. -EnvRemovePrefix drops matching variables from the child environment; -EnvSet adds/overrides.
      Returns @{Rc;Out;Err;TimedOut;TreeGone}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 120,
        [string[]]$EnvRemovePrefix = @(),
        [hashtable]$EnvSet = @{},
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($pre in $EnvRemovePrefix) {
        foreach ($k in @($psi.EnvironmentVariables.Keys)) {
            if (([string]$k).StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $psi.EnvironmentVariables.Remove([string]$k) }
        }
    }
    foreach ($k in $EnvSet.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvSet[$k] }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $job = New-Object MlUpdater.JobObject
    try {
        [void]$p.Start()
        if ($job.Valid) { [void]$job.Assign($p.Handle) }
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        $timedOut = $false
        $treeGone = $true
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            $treeGone = Stop-ProcessTree -Root $p -Job $job
            [void]$p.WaitForExit(5000)
        }
        $rc = if ($timedOut) { -1 } else { $p.ExitCode }
        $out = ''; $err = ''
        # bounded waits: a grandchild that inherited the pipes must not hang the updater
        if ($so.Wait(5000)) { $out = $so.Result }
        if ($se.Wait(5000)) { $err = $se.Result }
        return @{ Rc = $rc; Out = $out; Err = $err; TimedOut = $timedOut; TreeGone = $treeGone }
    } finally { $job.Dispose(); $p.Dispose() }
}

# ---- gh.exe provisioning checks ------------------------------------------------------------------
function Read-GhPin {
    <# gh-pin.json: { "version": "2.105.0", "gh_exe_sha256": "<64 hex>", "zip_sha256": "<64 hex>", "zip_name": "gh_2.105.0_windows_amd64.zip" } #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramDir)
    $p = Join-Path $ProgramDir 'gh-pin.json'
    if (-not (Test-Path -LiteralPath $p)) { throw 'gh-pin.json missing' }
    $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
    if (-not (Test-UpdRegex ([string]$j.version) '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')) { throw 'gh-pin version invalid' }
    if (-not (Test-UpdRegex ([string]$j.gh_exe_sha256) '^[0-9a-f]{64}$')) { throw 'gh-pin gh_exe_sha256 invalid' }
    if (-not (Test-UpdRegex ([string]$j.zip_sha256) '^[0-9a-f]{64}$')) { throw 'gh-pin zip_sha256 invalid' }
    if (-not (Test-UpdRegex ([string]$j.zip_name) '^gh_[0-9.]{5,20}_windows_(amd64|arm64)\.zip$')) { throw 'gh-pin zip_name invalid' }
    return $j
}

function Assert-GhBinary {
    <# gh.exe must (1) exist in the admin-only bin dir, (2) hash to the pinned SHA256, (3) carry a valid GitHub Authenticode signature. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GhPath, [Parameter(Mandatory)]$Pin, [switch]$SkipSignature)
    if (-not (Test-Path -LiteralPath $GhPath -PathType Leaf)) { throw 'gh.exe not found' }
    $h = Get-UpdSha256 -Path $GhPath
    if ($h -ne [string]$Pin.gh_exe_sha256) { throw 'gh.exe hash does not match pin' }
    if (-not $SkipSignature) {
        $sig = Get-AuthenticodeSignature -LiteralPath $GhPath
        if ($sig.Status -ne 'Valid') { throw "gh.exe signature status $($sig.Status)" }
        if ($sig.SignerCertificate.Subject -notmatch 'O="?GitHub, Inc\."?') { throw 'gh.exe signer is not GitHub, Inc.' }
    }
}

function Get-GhEnvironment {
    <# Environment for gh child processes: private config dir (TUF cache), no ambient tokens, no prompts. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [AllowNull()][string]$Token)
    $set = @{
        'GH_CONFIG_DIR' = (Join-Path $DataDir 'gh-config')
        'GH_PROMPT_DISABLED' = '1'
        'GH_NO_UPDATE_NOTIFIER' = '1'
        'GH_NO_EXTENSION_UPDATE_NOTIFIER' = '1'
        'GH_SPINNER_DISABLED' = '1'
        'NO_COLOR' = '1'
        'GH_FORCE_TTY' = ''
    }
    if ($Token) { $set['GH_TOKEN'] = $Token }
    return $set
}

function Invoke-GhVerify {
    <#
      One `gh` invocation. Arguments come only from validated values. Returns @{Ok;Rc;Err}.
      stdout is never logged (it contains certificates); stderr is scrubbed + truncated by the logger.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GhPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$DataDir,
        [AllowNull()][string]$Token,
        [int]$TimeoutSec = 180
    )
    $gcfg = Join-Path $DataDir 'gh-config'
    if (-not (Test-Path -LiteralPath $gcfg)) { New-Item -ItemType Directory -Path $gcfg -Force | Out-Null }
    $r = Invoke-UpdProcess -FilePath $GhPath -ArgumentList $Arguments -TimeoutSec $TimeoutSec `
        -EnvRemovePrefix @('GH_', 'GITHUB_') -EnvSet (Get-GhEnvironment -DataDir $DataDir -Token $Token)
    return @{ Ok = ($r.Rc -eq 0 -and -not $r.TimedOut); Rc = $r.Rc; Err = $r.Err; TimedOut = $r.TimedOut }
}

function Test-ArtifactAttestation {
    <#
      Offline attestation verification (U3 result): bundle comes from the release asset, so no GitHub token and
      no API lookup are needed. Flags per CONTRACT 4.5.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GhPath,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SignerWorkflow,
        [Parameter(Mandatory)][string]$SourceRef,
        [AllowNull()][string]$SourceDigest
    )
    if (-not (Test-UpdRegex $SourceRef '^refs/heads/build/v6\.2\.0-daily\.[1-9][0-9]{0,4}-n[1-8]$')) { throw 'source ref not allowed (only refs/heads/build/<upstream tag>-n<N>)' }
    $a = @('attestation', 'verify', $FilePath, '--repo', $Repo, '--bundle', $BundlePath,
        '--signer-workflow', $SignerWorkflow, '--source-ref', $SourceRef, '--deny-self-hosted-runners',
        '--predicate-type', 'https://slsa.dev/provenance/v1', '--cert-oidc-issuer', 'https://token.actions.githubusercontent.com', '--format', 'json')
    if ($SourceDigest) {
        if (-not (Test-UpdRegex $SourceDigest '^[0-9a-f]{40}$')) { throw 'source digest invalid' }
        $a += @('--source-digest', $SourceDigest)
    }
    return (Invoke-GhVerify -GhPath $GhPath -Arguments $a -DataDir $DataDir -Token $null)
}

# ---- manifest / SHA256SUMS ----------------------------------------------------------------------
function Read-ReleaseManifest {
    <# Parses and validates manifest.json (schema 1). Every string used later is regex-validated here. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedTag, [string[]]$AllowOwners = @(), [string[]]$LocalOwners = @())
    $fi = Get-Item -LiteralPath $Path
    if ($fi.Length -gt 256KB) { throw 'manifest too large' }
    try { $m = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { throw 'manifest is not valid JSON' }
    $n = @($m.PSObject.Properties.Name)
    foreach ($req in 'schema', 'product', 'tag', 'upstream', 'build', 'installer', 'assets', 'attestation') {
        if ($n -notcontains $req) { throw "manifest missing '$req'" }
    }
    if ($m.schema -ne 1) { throw 'manifest schema unsupported' }
    if ([string]$m.product -cne 'moonlight') { throw 'manifest product is not moonlight' }
    if ([string]$m.tag -cne $ExpectedTag) { throw 'manifest tag does not match release tag' }
    if (-not (Test-SafeAssetName -Name ([string]$m.installer) -Pattern '^MoonlightSetup[A-Za-z0-9._-]{0,40}\.exe$')) { throw 'manifest installer name invalid' }
    $b = $m.build
    if (-not (Test-UpdRegex ([string]$b.version) '^6\.2\.0-daily\.[0-9]{5}$')) { throw 'manifest build.version invalid' }
    if (-not (Test-UpdRegex ([string]$b.source_sha) '^[0-9a-f]{40}$')) { throw 'manifest build.source_sha invalid' }
    # CONTRACT 3b: the attestation source ref is derived from the tag, not trusted from the manifest
    $key = ConvertTo-OrderingKey -Tag $ExpectedTag
    $expectedRef = 'refs/heads/build/v6.2.0-daily.{0}-n{1}' -f $key.U, $key.N
    if ([string]$b.source_ref -cne $expectedRef) { throw 'manifest build.source_ref does not match the tag (expected refs/heads/build/<upstreamtag>-n<N>)' }
    if (-not (Test-UpdRegex ([string]$m.upstream.owner) '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')) { throw 'manifest upstream.owner invalid' }
    if ($AllowOwners.Count -gt 0 -and $AllowOwners -cnotcontains [string]$m.upstream.owner) { throw 'manifest upstream owner not in policy allow-list' }
    if ($LocalOwners.Count -gt 0 -and $LocalOwners -cnotcontains [string]$m.upstream.owner) { throw 'manifest upstream owner not in the local owner list' }
    $bundles = @()
    foreach ($x in @($m.attestation)) {
        if (-not (Test-SafeAssetName -Name ([string]$x) -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.(sigstore\.json|jsonl)$')) { throw 'manifest attestation name invalid' }
        $bundles += [string]$x
    }
    if ($bundles.Count -lt 1) { throw 'manifest lists no attestation bundle' }
    $assets = @{}
    $sizes = @{}
    foreach ($a in @($m.assets)) {
        if (-not (Test-SafeAssetName -Name ([string]$a.name))) { throw 'manifest asset name invalid' }
        if (-not (Test-UpdRegex ([string]$a.sha256) '^[0-9a-f]{64}$')) { throw 'manifest asset sha256 invalid' }
        $assets[[string]$a.name] = [string]$a.sha256
        if ($a.PSObject.Properties.Name -contains 'size') {
            if (($a.size -isnot [int] -and $a.size -isnot [long]) -or $a.size -lt 0) { throw 'manifest asset size invalid' }
            $sizes[[string]$a.name] = [long]$a.size
        }
    }
    if (-not $assets.ContainsKey([string]$m.installer)) { throw 'manifest does not list the installer asset' }
    # build number must equal 60000 + 8*U + (N-1) for the tag (CONTRACT 3b)
    $bn = [int](([string]$b.version).Split('.')[-1])
    if ($bn -ne $key.Build) { throw 'manifest build.version does not match tag per version scheme' }
    return [pscustomobject]@{
        Tag = [string]$m.tag; Installer = [string]$m.installer; Bundles = $bundles; Assets = $assets
        AssetSizes = $sizes; BuildNumber = $bn; BuildVersion = [string]$b.version; SourceSha = [string]$b.source_sha; SourceRef = [string]$b.source_ref
        UpstreamOwner = [string]$m.upstream.owner; Key = $key
    }
}

function Read-Sha256Sums {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $fi = Get-Item -LiteralPath $Path
    if ($fi.Length -gt 64KB) { throw 'SHA256SUMS too large' }
    $map = @{}
    foreach ($line in ([System.IO.File]::ReadAllText($Path) -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        $m = [regex]::Match($line, '^([0-9a-f]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]{0,99})$')
        if (-not $m.Success) { throw 'SHA256SUMS contains a malformed line' }
        if ($map.ContainsKey($m.Groups[2].Value)) { throw 'SHA256SUMS has duplicate entry' }
        $map[$m.Groups[2].Value] = $m.Groups[1].Value
    }
    return $map
}

function Assert-HashesAgree {
    <# installer hash computed from the file == SHA256SUMS entry == manifest entry (== API digest when present). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputedSha256,
        [Parameter(Mandatory)][string]$InstallerName,
        [Parameter(Mandatory)][hashtable]$Sums,
        [Parameter(Mandatory)]$Manifest,
        [AllowNull()][string]$ApiDigest
    )
    if (-not $Sums.ContainsKey($InstallerName)) { throw 'SHA256SUMS has no entry for the installer' }
    if ($Sums[$InstallerName] -ne $ComputedSha256) { throw 'installer hash does not match SHA256SUMS' }
    if ($Manifest.Assets[$InstallerName] -ne $ComputedSha256) { throw 'installer hash does not match manifest.json' }
    if ($ApiDigest) {
        if ($ApiDigest -ne ('sha256:' + $ComputedSha256)) { throw 'installer hash does not match release API digest' }
    }
}

function Assert-ReleaseImmutable {
    <# Offline-mode substitute for `gh release verify` (needs a token): require the API flag immutable == true. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Release)
    if (-not ($Release.PSObject.Properties.Name -contains 'immutable') -or $Release.immutable -ne $true) {
        throw 'release is not immutable (CONTRACT requires immutable releases)'
    }
}
