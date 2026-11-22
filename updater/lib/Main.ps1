# Entry logic of update.ps1 as a function, so that the test harness can drive it in-process with substituted dependencies.
# update.ps1 itself passes only ProgramDir / Mode / VerifyOnly / Echo: config.json can NOT inject paths, URLs or executables.

Set-StrictMode -Version Latest

function Format-UpdOutputLine {
    param([string]$Result, [string]$Tag = '', [string]$Detail = '')
    return ('MLUPD_RESULT={0} MLUPD_TAG={1} MLUPD_DETAIL={2}' -f $Result, $Tag, (ConvertTo-SafeLogValue $Detail 300))
}

function Invoke-UpdaterMain {
    <# Returns @{ExitCode; Line}. DataDir/Config/Deps/AclCheck/MutexName are for in-process callers (tests); update.ps1 uses the defaults. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramDir,
        [string]$DataDir = $script:UpdConst.DataDir,
        [hashtable]$Config,
        [hashtable]$Deps,
        [string]$Mode,
        [switch]$VerifyOnly,
        [switch]$Echo,
        [scriptblock]$AclCheck,
        [string]$MutexName = $script:UpdConst.MutexName
    )
    if ($null -eq $Config) {
        try { $Config = Read-UpdConfig -ProgramDir $ProgramDir } catch {
            return [pscustomobject]@{ ExitCode = $script:UpdExit.ConfigInvalid; Line = (Format-UpdOutputLine -Result 'failed' -Detail ('config invalid: ' + $_.Exception.Message)) }
        }
    }
    if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) {
        return [pscustomobject]@{ ExitCode = $script:UpdExit.ConfigInvalid; Line = (Format-UpdOutputLine -Result 'failed' -Detail 'data dir missing (run install-task.ps1)') }
    }
    Initialize-UpdLog -LogDir (Join-Path $DataDir 'logs') -Echo:$Echo
    try {
        if ($null -ne $AclCheck) { & $AclCheck } else { Assert-UpdSelfAcl -ProgramDir $ProgramDir -DataDir $DataDir }
    } catch {
        Write-UpdLog -Level ERROR -Event 'acl_violation' -Data @{ message = $_.Exception.Message }
        return [pscustomobject]@{ ExitCode = $script:UpdExit.AclViolation; Line = (Format-UpdOutputLine -Result 'failed' -Detail $_.Exception.Message) }
    }
    $mutex = Enter-UpdMutex -Name $MutexName
    if ($null -eq $mutex) {
        Write-UpdLog -Event 'already_running' -Data @{}
        return [pscustomobject]@{ ExitCode = $script:UpdExit.AlreadyRunning; Line = (Format-UpdOutputLine -Result 'deferred' -Detail 'another instance is running') }
    }
    try {
        if ($null -eq $Deps) { $Deps = New-UpdDeps -Config $Config -ProgramDir $ProgramDir }
        $r = Invoke-MoonlightUpdate -ProgramDir $ProgramDir -DataDir $DataDir -Config $Config -Deps $Deps -ModeOverride $Mode -VerifyOnly:$VerifyOnly
        return [pscustomobject]@{ ExitCode = $r.ExitCode; Line = (Format-UpdOutputLine -Result $r.Result -Tag $r.Tag -Detail $r.Detail) }
    } finally { Exit-UpdMutex -Mutex $mutex }
}
