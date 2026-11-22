<#
.SYNOPSIS
  Runs the Pester v5 suite (sandbox only: temp dirs, fake dependencies, loopback HTTP fixture; never installs Moonlight).
.PARAMETER ModulePath
  Optional extra folder containing Pester 5 / PSScriptAnalyzer (e.g. produced by Save-Module).
.PARAMETER IncludeNetwork
  Also run tests tagged Network (anonymous calls to api.github.com / github.com for the cli/cli attestation sample).
.PARAMETER OutputFile
  Optional NUnit XML result path.
#>
[CmdletBinding()]
param([string]$ModulePath, [switch]$IncludeNetwork, [string]$OutputFile, [string]$Filter)
$ErrorActionPreference = 'Stop'
if ($ModulePath) { $env:PSModulePath = $ModulePath + [IO.Path]::PathSeparator + $env:PSModulePath }
$m = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $m) { throw 'Pester 5 not found (Install-Module Pester -Scope CurrentUser, or pass -ModulePath)' }
Import-Module $m.Path -Force
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
if (-not $IncludeNetwork) { $cfg.Filter.ExcludeTag = @('Network') }
if ($Filter) { $cfg.Filter.FullName = $Filter }
if ($OutputFile) { $cfg.TestResult.Enabled = $true; $cfg.TestResult.OutputPath = $OutputFile }
$r = Invoke-Pester -Configuration $cfg
"Pester {0} on PowerShell {1}: passed={2} failed={3} skipped={4}" -f $m.Version, $PSVersionTable.PSVersion, $r.PassedCount, $r.FailedCount, $r.SkippedCount
if ($r.FailedCount -gt 0) { exit 1 }
