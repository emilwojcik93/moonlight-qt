<#
.SYNOPSIS
  Moonlight patch updater (runs as SYSTEM from the scheduled task \MoonlightPatch\Update).
.DESCRIPTION
  Polls the patched feed emilwojcik93/moonlight-qt, verifies (tag regex, ordering, policy, age, attestation,
  SHA256) and installs MoonlightSetup.exe when Moonlight is idle. See docs/UPDATER.md.
  Exit codes: 0 ok/noop/deferred/held/report-only/verified, 1 internal, 2 ACL violation, 3 config/policy
  invalid or unavailable, 4 verification failed, 5 rolled back, 6 rollback failed, 7 already running, 8 rate-limit/network defer.
.PARAMETER Mode
  Optional narrowing override: report-only or hold. Can never escalate beyond config.json (install needs config mode=install).
.PARAMETER VerifyOnly
  Download and fully verify the newest eligible release, install nothing (used for the G4 rehearsal).
.PARAMETER Echo
  Also print log lines to the console.
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'report-only', 'hold')][string]$Mode,
    [switch]$VerifyOnly,
    [switch]$Echo
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProgramDir = $PSScriptRoot

# ---- bootstrap ACL check (inline on purpose: runs BEFORE any code from lib\ is loaded) ----------------
function Test-UpdBootstrapAcl {
    param([string]$Path)
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'S-1-3-0')
    $mask = [int]([System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
    $bad = @()
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $bad += "$Path is a reparse point" }
    $sec = Get-Acl -LiteralPath $Path
    $own = $sec.GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($trusted -notcontains $own.Value) { $bad += "$Path owner $($own.Value)" }
    foreach ($ace in $sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        if (($ace.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($trusted -contains $ace.IdentityReference.Value) { continue }
        if (([int]$ace.FileSystemRights -band $mask) -ne 0) { $bad += "$Path writable by $($ace.IdentityReference.Value)" }
    }
    return , $bad
}

$bootstrapBad = @()
$libDir = Join-Path $ProgramDir 'lib'
foreach ($p in @($ProgramDir, $libDir, $PSCommandPath) + @(Get-ChildItem -LiteralPath $libDir -File -Force | ForEach-Object { $_.FullName })) {
    $bootstrapBad += Test-UpdBootstrapAcl -Path $p
}
if ($bootstrapBad.Count -gt 0) {
    Write-Output ('MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=ACL self-check failed: ' + (($bootstrapBad | Select-Object -First 3) -join ' | '))
    exit 2
}

# ---- load libraries (order matters) --------------------------------------------------------------------
foreach ($f in 'Common', 'Version', 'Yaml', 'Config', 'Security', 'GitHub', 'Verify', 'Install', 'Notify', 'Orchestrator', 'Main', 'Snappy') {
    . (Join-Path $libDir ($f + '.ps1'))
}

$exitCode = $script:UpdExit.InternalError
try {
    $r = Invoke-UpdaterMain -ProgramDir $ProgramDir -Mode $Mode -VerifyOnly:$VerifyOnly -Echo:$Echo
    Write-Output $r.Line
    $exitCode = $r.ExitCode
} catch {
    Write-Output ('MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=' + (ConvertTo-SafeLogValue $_.Exception.Message 200))
    $exitCode = $script:UpdExit.InternalError
}
exit $exitCode
