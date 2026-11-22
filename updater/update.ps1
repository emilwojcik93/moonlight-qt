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
$testSkip = $false
if ($bootstrapBad.Count -gt 0) {
    # the only bypass: test-mode flag + config skip_acl_check, evaluated below AFTER libs load is NOT allowed,
    # so the bypass is decided here from the flag file and config.json text only.
    $flag = Join-Path $ProgramDir 'test-mode.flag'
    if ((Test-Path -LiteralPath $flag) -and (Test-Path -LiteralPath (Join-Path $ProgramDir 'config.json'))) {
        try { $tj = [System.IO.File]::ReadAllText((Join-Path $ProgramDir 'config.json')) | ConvertFrom-Json; if ($tj.PSObject.Properties.Name -contains 'skip_acl_check' -and $tj.skip_acl_check -eq $true) { $testSkip = $true } } catch { $testSkip = $false }
    }
    if (-not $testSkip) {
        Write-Output ('MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=ACL self-check failed: ' + (($bootstrapBad | Select-Object -First 3) -join ' | '))
        exit 2
    }
}

# ---- load libraries (order matters) --------------------------------------------------------------------
foreach ($f in 'Common', 'Version', 'Yaml', 'Config', 'Security', 'GitHub', 'Verify', 'Install', 'Notify', 'Orchestrator', 'Snappy') {
    . (Join-Path $libDir ($f + '.ps1'))
}

$exitCode = $script:UpdExit.InternalError
$mutex = $null
try {
    $cfg = $null
    try { $cfg = Read-UpdConfig -ProgramDir $ProgramDir } catch {
        Write-Output ('MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=config invalid: ' + (ConvertTo-SafeLogValue $_.Exception.Message 200))
        exit $script:UpdExit.ConfigInvalid
    }
    $dataDir = $script:UpdConst.DataDir
    if ($cfg.ContainsKey('data_dir')) { $dataDir = [string]$cfg['data_dir'] }
    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
        Write-Output 'MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=data dir missing (run install-task.ps1)'
        exit $script:UpdExit.ConfigInvalid
    }
    Initialize-UpdLog -LogDir (Join-Path $dataDir 'logs') -Echo:$Echo

    if (-not $testSkip -and -not ($cfg.ContainsKey('skip_acl_check') -and $cfg['skip_acl_check'] -eq $true)) {
        try { Assert-UpdSelfAcl -ProgramDir $ProgramDir -DataDir $dataDir } catch {
            Write-UpdLog -Level ERROR -Event 'acl_violation' -Data @{ message = $_.Exception.Message }
            Write-Output ('MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=' + (ConvertTo-SafeLogValue $_.Exception.Message 300))
            exit $script:UpdExit.AclViolation
        }
    } else {
        Write-UpdLog -Level WARN -Event 'acl_check_skipped' -Data @{ reason = 'test-mode skip_acl_check' }
    }

    $mutex = Enter-UpdMutex
    if ($null -eq $mutex) {
        Write-UpdLog -Event 'already_running' -Data @{}
        Write-Output 'MLUPD_RESULT=deferred MLUPD_TAG= MLUPD_DETAIL=another instance is running'
        exit $script:UpdExit.AlreadyRunning
    }

    $deps = New-UpdDeps -Config $cfg -ProgramDir $ProgramDir
    if ($cfg['test_mode'] -eq $true) {
        # test mode only (flag file in the admin-only program dir): a non-admin sandbox user must keep access to the dirs it creates
        $deps.AdditionalFullControlSids = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $r = Invoke-MoonlightUpdate -ProgramDir $ProgramDir -DataDir $dataDir -Config $cfg -Deps $deps -ModeOverride $Mode -VerifyOnly:$VerifyOnly
    Write-Output ('MLUPD_RESULT={0} MLUPD_TAG={1} MLUPD_DETAIL={2}' -f $r.Result, $r.Tag, (ConvertTo-SafeLogValue $r.Detail 200))
    $exitCode = $r.ExitCode
} catch {
    Write-Output ('MLUPD_RESULT=failed MLUPD_TAG= MLUPD_DETAIL=' + (ConvertTo-SafeLogValue $_.Exception.Message 200))
    $exitCode = $script:UpdExit.InternalError
} finally {
    if ($null -ne $mutex) { Exit-UpdMutex -Mutex $mutex }
}
exit $exitCode
