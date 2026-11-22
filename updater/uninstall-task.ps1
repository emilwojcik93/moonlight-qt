<#
.SYNOPSIS
  Removes the scheduled task \MoonlightPatch\Update and, optionally, the program/data directories.
.DESCRIPTION
  Run elevated. -WhatIf prints exactly what would be removed. Moonlight itself is never touched.
.PARAMETER RemoveFiles
  Also delete C:\Program Files\MoonlightPatchUpdater (script, config, gh.exe).
.PARAMETER RemoveData
  Also delete C:\ProgramData\MoonlightPatchUpdater (logs, state, stored bundles, DPAPI secrets).
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$RemoveFiles, [switch]$RemoveData)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgramDir = 'C:\Program Files\MoonlightPatchUpdater'
$DataDir = 'C:\ProgramData\MoonlightPatchUpdater'
$TaskPath = '\MoonlightPatch\'
$TaskName = 'Update'

$plan = New-Object System.Collections.Generic.List[string]
$plan.Add("1. Unregister scheduled task $TaskPath$TaskName (if present).")
if ($RemoveFiles) { $plan.Add("2. Delete directory $ProgramDir recursively.") } else { $plan.Add("2. Keep $ProgramDir.") }
if ($RemoveData) { $plan.Add("3. Delete directory $DataDir recursively (logs, state.json, stored bundles, DPAPI secrets).") } else { $plan.Add("3. Keep $DataDir.") }
$plan.Add('4. Moonlight, its settings and its registry key are not touched.')
$whatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false
Write-Output "uninstall-task plan ($(if ($whatIf) { 'WHATIF: nothing will be changed' } else { 'executing' })):"
foreach ($l in $plan) { Write-Output $l }
if ($whatIf) { Write-Output 'WhatIf: no changes made.'; return }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated (gsudo / sudo.exe).' }
if (-not $PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'unregister')) { return }

$t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($t) { Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false; Write-Output 'task unregistered' } else { Write-Output 'task not present' }
if ($RemoveFiles -and (Test-Path -LiteralPath $ProgramDir)) { Remove-Item -LiteralPath $ProgramDir -Recurse -Force; Write-Output "removed $ProgramDir" }
if ($RemoveData -and (Test-Path -LiteralPath $DataDir)) { Remove-Item -LiteralPath $DataDir -Recurse -Force; Write-Output "removed $DataDir" }
