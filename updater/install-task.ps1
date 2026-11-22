<#
.SYNOPSIS
  Installs the Moonlight patch updater and registers the scheduled task \MoonlightPatch\Update (SYSTEM).
.DESCRIPTION
  Run from an ELEVATED PowerShell (use `gsudo` or `sudo.exe`; never self-elevate with Start-Process). Idempotent.
  -WhatIf prints exactly what would be done and changes nothing (no elevation needed).
  The installed config.json defaults to mode=report-only: nothing is installed until you switch it to install (gate G4).
.PARAMETER SourceDir
  Folder holding update.ps1, lib\, gh-pin.json (default: the folder of this script).
.PARAMETER GhExeSource
  Optional path to a gh.exe to provision (must match gh-pin.json by SHA256 and be Authenticode-signed by GitHub).
  Default: reuse C:\Program Files\GitHub CLI\gh.exe if it matches the pin, otherwise download the pinned zip.
.PARAMETER SetWebhook
  Prompts (secure input) for a Google Chat webhook URL, stores it DPAPI-protected and sets notify_enabled=true.
.PARAMETER SetGhToken
  Optional. Prompts (secure input) for a GitHub token (a read-only fine-grained PAT, or a classic token without scopes), stores it
  DPAPI-protected and sets verify_mode=online so the updater additionally runs `gh release verify` / `gh release verify-asset`
  (these cannot run unauthenticated; default verify_mode=offline needs no token).
.PARAMETER SetMode
  Optional: write mode=report-only|install|hold into config.json (new or existing). Switching to install is the G4 decision.
.PARAMETER RunAt
  Daily trigger time (default 04:17 local).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceDir,
    [string]$GhExeSource,
    [switch]$SetWebhook,
    [switch]$SetGhToken,
    [ValidateSet('report-only', 'install', 'hold')][string]$SetMode,
    [string]$RunAt = '04:17'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # progress rendering breaks in non-interactive SYSTEM sessions

if (-not $SourceDir) { $SourceDir = Split-Path -Parent $PSCommandPath }
$ProgramDir = 'C:\Program Files\MoonlightPatchUpdater'
$DataDir = 'C:\ProgramData\MoonlightPatchUpdater'
$TaskPath = '\MoonlightPatch\'
$TaskName = 'Update'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$SystemGhDefault = 'C:\Program Files\GitHub CLI\gh.exe'
# -WhatIf is honoured by this script's own plan/dry-run logic; read-only cmdlets below must not inherit it
$whatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false

if ($RunAt -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'RunAt must be HH:mm' }
foreach ($f in @('update.ps1', 'gh-pin.json', 'lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $f))) { throw "source file missing: $f (SourceDir=$SourceDir)" }
}
$libFiles = @(Get-ChildItem -LiteralPath (Join-Path $SourceDir 'lib') -Filter '*.ps1' -File)
$pin = [System.IO.File]::ReadAllText((Join-Path $SourceDir 'gh-pin.json')) | ConvertFrom-Json
if ($pin.gh_exe_sha256 -notmatch '^[0-9a-f]{64}$' -or $pin.zip_sha256 -notmatch '^[0-9a-f]{64}$' -or $pin.zip_name -notmatch '^gh_[0-9.]{5,20}_windows_(amd64|arm64)\.zip$' -or $pin.version -notmatch '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$') { throw 'gh-pin.json invalid' }

function Get-FileSha256Lower([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }

# ---- decide how gh.exe is provisioned (read-only, so -WhatIf can state it exactly) -----------------------
$ghPlan = $null
if ($GhExeSource) {
    if (-not (Test-Path -LiteralPath $GhExeSource -PathType Leaf)) { throw 'GhExeSource not found' }
    if ((Get-FileSha256Lower $GhExeSource) -ne $pin.gh_exe_sha256) { throw 'GhExeSource does not match gh-pin.json gh_exe_sha256' }
    $ghPlan = [pscustomobject]@{ Kind = 'copy'; From = (Resolve-Path -LiteralPath $GhExeSource).Path }
} elseif ((Test-Path -LiteralPath $SystemGhDefault -PathType Leaf) -and ((Get-FileSha256Lower $SystemGhDefault) -eq $pin.gh_exe_sha256)) {
    $ghPlan = [pscustomobject]@{ Kind = 'copy'; From = $SystemGhDefault }
} else {
    $ghPlan = [pscustomobject]@{ Kind = 'download'; From = ('https://github.com/cli/cli/releases/download/v{0}/{1}' -f $pin.version, $pin.zip_name) }
}

$configPath = Join-Path $ProgramDir 'config.json'
# an unelevated -WhatIf cannot read inside the admin-only program dir: access denied means it exists
$configExists = $true
try { $configExists = [bool](Test-Path -LiteralPath $configPath -ErrorAction Stop) } catch [System.UnauthorizedAccessException] { $configExists = $true }
if ($SetMode -eq 'install' -and -not $configExists) { throw 'refusing -SetMode install on a fresh machine: install in report-only mode first, rehearse with update.ps1 -VerifyOnly, then run with -SetMode install (gate G4)' }
$defaultConfig = [ordered]@{
    schema = 1; mode = 'report-only'; channel = 'canary'; cooling_off_hours = 0
    repo = 'emilwojcik93/moonlight-qt'; policy_branch = 'automation'; policy_path = 'policy.yml'
    signer_workflow = 'github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml'
    verify_mode = 'offline'; notify_enabled = $false; max_installer_mb = 200
}

# ---- plan ---------------------------------------------------------------------------------------------------
$plan = New-Object System.Collections.Generic.List[string]
$plan.Add("1. Require an elevated Administrator session (not needed for -WhatIf).")
$plan.Add("2. Create $ProgramDir ; ACL: protected (no inheritance), owner BUILTIN\Administrators, Allow FullControl to NT AUTHORITY\SYSTEM and BUILTIN\Administrators only.")
$plan.Add("3. Copy update.ps1, gh-pin.json and $($libFiles.Count) lib\*.ps1 files ($((($libFiles | ForEach-Object { $_.Name }) -join ', '))) from $SourceDir into $ProgramDir (inherit the admin-only ACL).")
$plan.Add("4. Create $DataDir (same admin-only protected ACL) with subfolders logs, updates, bundles, cache, secrets, gh-config.")
if ($ghPlan.Kind -eq 'copy') {
    $plan.Add("5. Provision $ProgramDir\bin\gh.exe: copy from $($ghPlan.From) (SHA256 equals pin $($pin.gh_exe_sha256)); then require Authenticode status Valid with signer 'GitHub, Inc.'.")
} else {
    $plan.Add("5. Provision $ProgramDir\bin\gh.exe: download $($ghPlan.From) over HTTPS; require zip SHA256 = $($pin.zip_sha256); extract bin\gh.exe; require SHA256 $($pin.gh_exe_sha256) and Authenticode Valid 'GitHub, Inc.'.")
}
if ($configExists -and $SetMode) { $plan.Add("6. Keep existing $configPath but set mode=$SetMode (other keys unchanged).") }
elseif ($configExists) { $plan.Add("6. Keep existing $configPath (not overwritten).") }
else {
    if ($SetMode) { $defaultConfig['mode'] = $SetMode }
    $plan.Add("6. Write $configPath = " + ($defaultConfig | ConvertTo-Json -Compress))
}
if ($SetWebhook) { $plan.Add("7. Prompt (secure) for a Google Chat webhook URL; store DPAPI(LocalMachine) blob $DataDir\secrets\gchat-webhook.dpapi; set notify_enabled=true in config.json.") }
else { $plan.Add("7. Webhook notifications stay disabled (use -SetWebhook to enable).") }
if ($SetGhToken) { $plan.Add("7b. Prompt (secure) for a GitHub token; store DPAPI(LocalMachine) blob $DataDir\secrets\gh-token.dpapi; set verify_mode=online in config.json (adds gh release verify / verify-asset).") }
else { $plan.Add("7b. verify_mode stays offline: no GitHub token is stored; release verification = immutable flag + offline attestation bundles.") }
$plan.Add("8. Register scheduled task $TaskPath$TaskName :")
$plan.Add("     principal : NT AUTHORITY\SYSTEM, LogonType ServiceAccount, RunLevel Highest")
$plan.Add("     action    : $PsExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ProgramDir\update.ps1`"")
$plan.Add("     triggers  : (a) AtLogOn of any user, random delay 3 min; (b) Daily at $RunAt; (c) every 6 hours (repetition PT6H for 3650 days)")
$plan.Add("     settings  : ExecutionTimeLimit PT2H (exceeds the updater's internal worst-case budget, see docs), MultipleInstances IgnoreNew, StartWhenAvailable, runs on battery, RunOnlyIfNetworkAvailable, Hidden")
$modeText = if ($SetMode) { $SetMode } else { 'whatever config.json says (new installs: report-only)' }
$plan.Add("9. Nothing is installed or downloaded from the Moonlight feed by this script; the task runs in mode: $modeText.")
$plan.Add("10. Delete a stale $ProgramDir\test-mode.flag if one exists (the updater has no test mode; the file has no effect).")

Write-Output "install-task plan ($(if ($whatIf) { 'WHATIF: nothing will be changed' } else { 'executing' })):"
foreach ($l in $plan) { Write-Output $l }
if ($whatIf) { Write-Output 'WhatIf: no changes made.'; return }

# ---- execute ------------------------------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated (gsudo / sudo.exe). Do not self-elevate with Start-Process.' }
if (-not $PSCmdlet.ShouldProcess("$ProgramDir, $DataDir, scheduled task $TaskPath$TaskName", 'install')) { return }

function New-AdminSecurity {
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $sec.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', $inh, 'None', 'Allow')))
    }
    return $sec
}
function Initialize-AdminDir([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "refusing reparse point $p" }
    Set-Acl -LiteralPath $p -AclObject (New-AdminSecurity)
}

# 2/3 program dir
Initialize-AdminDir $ProgramDir
Initialize-AdminDir (Join-Path $ProgramDir 'lib')
Initialize-AdminDir (Join-Path $ProgramDir 'bin')
Copy-Item -LiteralPath (Join-Path $SourceDir 'update.ps1') -Destination (Join-Path $ProgramDir 'update.ps1') -Force
Copy-Item -LiteralPath (Join-Path $SourceDir 'gh-pin.json') -Destination (Join-Path $ProgramDir 'gh-pin.json') -Force
foreach ($f in $libFiles) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path (Join-Path $ProgramDir 'lib') $f.Name) -Force }
# remove stale lib files that are not part of this release
foreach ($old in (Get-ChildItem -LiteralPath (Join-Path $ProgramDir 'lib') -File)) {
    if (-not (@($libFiles | ForEach-Object { $_.Name }) -contains $old.Name)) { Remove-Item -LiteralPath $old.FullName -Force }
}
# files copied into an already-protected dir inherit its ACL; make sure inheritance is on for them
foreach ($f in (Get-ChildItem -LiteralPath $ProgramDir -File -Recurse)) {
    $a = Get-Acl -LiteralPath $f.FullName
    $a.SetAccessRuleProtection($false, $false)
    Set-Acl -LiteralPath $f.FullName -AclObject $a
}
Write-Output "installed scripts into $ProgramDir"

$staleFlag = Join-Path $ProgramDir 'test-mode.flag'
if (Test-Path -LiteralPath $staleFlag) { Remove-Item -LiteralPath $staleFlag -Force; Write-Output 'removed stale test-mode.flag' }

# 4 data dir
Initialize-AdminDir $DataDir
foreach ($s in 'logs', 'updates', 'bundles', 'cache', 'secrets', 'gh-config') { Initialize-AdminDir (Join-Path $DataDir $s) }
Write-Output "prepared $DataDir"

# 5 gh.exe
$ghDest = Join-Path (Join-Path $ProgramDir 'bin') 'gh.exe'
$tmp = Join-Path $DataDir ('gh-provision-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $ghSrc = $null
    if ($ghPlan.Kind -eq 'copy') { $ghSrc = $ghPlan.From }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $tmp $pin.zip_name
        Invoke-WebRequest -Uri $ghPlan.From -OutFile $zip -UseBasicParsing
        if ((Get-FileSha256Lower $zip) -ne $pin.zip_sha256) { throw 'downloaded gh zip does not match pinned SHA256' }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x')
        $ghSrc = Join-Path $tmp 'x\bin\gh.exe'
    }
    if ((Get-FileSha256Lower $ghSrc) -ne $pin.gh_exe_sha256) { throw 'gh.exe does not match pinned SHA256' }
    Copy-Item -LiteralPath $ghSrc -Destination $ghDest -Force
    if ((Get-FileSha256Lower $ghDest) -ne $pin.gh_exe_sha256) { throw 'copied gh.exe hash mismatch' }
    $sig = Get-AuthenticodeSignature -LiteralPath $ghDest
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O="?GitHub, Inc\."?') { Remove-Item -LiteralPath $ghDest -Force; throw "gh.exe signature check failed ($($sig.Status))" }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "gh.exe $($pin.version) provisioned and verified"

# 6 config
if (-not $configExists) {
    [System.IO.File]::WriteAllText($configPath, ($defaultConfig | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "wrote default config (mode=report-only)"
}

if ($configExists -and $SetMode) {
    $c = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $c.mode = $SetMode
    [System.IO.File]::WriteAllText($configPath, ($c | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "config mode set to $SetMode"
}

# 7 webhook
if ($SetWebhook) {
    $sec = Read-Host -AsSecureString -Prompt 'Google Chat webhook URL'
    foreach ($f in 'Common', 'Security', 'Notify') { . (Join-Path (Join-Path $ProgramDir 'lib') ($f + '.ps1')) }
    Set-UpdSecret -DataDir $DataDir -Name 'gchat-webhook' -Value $sec
    $c = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $c.notify_enabled = $true
    [System.IO.File]::WriteAllText($configPath, ($c | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'webhook stored (DPAPI) and notify_enabled=true'
}

# 7b gh token
if ($SetGhToken) {
    $tok = Read-Host -AsSecureString -Prompt 'GitHub token (read-only)'
    foreach ($f in 'Common', 'Security', 'Notify') { . (Join-Path (Join-Path $ProgramDir 'lib') ($f + '.ps1')) }
    Set-UpdSecret -DataDir $DataDir -Name 'gh-token' -Value $tok
    $c = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $c.verify_mode = 'online'
    [System.IO.File]::WriteAllText($configPath, ($c | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'gh token stored (DPAPI) and verify_mode=online'
}

# 8 scheduled task
$action = New-ScheduledTaskAction -Execute $PsExe -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\update.ps1"' -f $ProgramDir)
$t1 = New-ScheduledTaskTrigger -AtLogOn
$t1.Delay = 'PT3M'
$t2 = New-ScheduledTaskTrigger -Daily -At $RunAt
$t3 = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddHours(0)) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -Hidden
$prin = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$task = New-ScheduledTask -Action $action -Trigger @($t1, $t2, $t3) -Settings $settings -Principal $prin -Description 'Moonlight patched-feed updater (verify, then install when idle). Managed by install-task.ps1.'
Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -InputObject $task -Force | Out-Null
Write-Output "registered scheduled task $TaskPath$TaskName"
Write-Output "next: powershell -File `"$ProgramDir\update.ps1`" -Echo -VerifyOnly   (as SYSTEM via gsudo -s) to rehearse; edit $configPath mode=install to enable (gate G4)."
