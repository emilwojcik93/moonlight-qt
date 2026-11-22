<#
.SYNOPSIS
  Research question U3 probe: does `gh attestation verify` work UNAUTHENTICATED as SYSTEM, and does the offline
  (--bundle) route work? Self-contained: downloads a real, public, attested artifact (cli/cli release asset), fetches
  its Sigstore bundle from the anonymous attestations API, and runs gh with a scrubbed SYSTEM-like environment.
.DESCRIPTION
  Run as SYSTEM:   gsudo -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\U3-SystemProbe.ps1
  Needs network access to github.com / api.github.com / tuf-repo-cdn.sigstore.dev only. Writes nothing outside a temp dir.
  Exit code 0 = offline route works and online route is (as expected) unavailable without a token.
.PARAMETER GhExe
  gh.exe to test (default: the machine install; the updater uses its pinned copy under the program dir).
.PARAMETER Version
  cli/cli release tag to use (immutable, attested).
#>
[CmdletBinding()]
param(
    [string]$GhExe = 'C:\Program Files\GitHub CLI\gh.exe',
    [string]$Version = 'v2.105.0',
    [string]$Asset = 'gh_2.105.0_windows_amd64.zip'
)
Set-StrictMode -Version Latest
$script:Gh = $GhExe
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # progress rendering breaks in non-interactive SYSTEM sessions
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Snappy.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# mimic the SYSTEM scheduled-task environment: no user profile, no tokens, private gh config dir
$sp = Join-Path $env:SystemRoot 'System32\config\systemprofile'
$work = Join-Path ([IO.Path]::GetTempPath()) ('u3probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$env:USERPROFILE = $sp; $env:HOME = $null; $env:APPDATA = "$sp\AppData\Roaming"; $env:LOCALAPPDATA = "$sp\AppData\Local"
foreach ($v in 'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GH_HOST', 'XDG_CONFIG_HOME') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
$env:GH_CONFIG_DIR = Join-Path $work 'gh-config'; $env:GH_PROMPT_DISABLED = '1'; $env:NO_COLOR = '1'

function Invoke-Gh([string[]]$a) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Gh
    $psi.Arguments = (($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    return [pscustomobject]@{ Rc = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}
$results = New-Object System.Collections.Generic.List[string]
function Check([string]$name, [bool]$ok, [string]$detail) { $results.Add(('{0} {1} :: {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)); return $ok }

$who = (& whoami)
$null = Check 'running identity' $true $who
$null = Check 'no ambient token' (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) 'GH_TOKEN/GITHUB_TOKEN unset'
$ver = Invoke-Gh @('--version'); $null = Check 'gh version' ($ver.Rc -eq 0) (($ver.Out -split "`n")[0].Trim())

$file = Join-Path $work $Asset
Invoke-WebRequest -Uri ("https://github.com/cli/cli/releases/download/$Version/$Asset") -OutFile $file -UseBasicParsing
$sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$null = Check 'downloaded artifact' $true "$Asset sha256=$sha"

# ---- 1. online mode (what the CONTRACT's `gh attestation verify` / `gh release verify[-asset]` do) ----
$on = Invoke-Gh @('attestation', 'verify', $file, '-R', 'cli/cli')
$null = Check 'online: gh attestation verify (no token) FAILS as expected' ($on.Rc -ne 0) ("rc=$($on.Rc) " + ($on.Err.Trim() -replace '\s+', ' ').Substring(0, [Math]::Min(120, $on.Err.Trim().Length)))
$rv = Invoke-Gh @('release', 'verify', $Version, '-R', 'cli/cli')
$null = Check 'online: gh release verify (no token) FAILS as expected' ($rv.Rc -ne 0) ("rc=$($rv.Rc) " + ($rv.Err.Trim() -replace '\s+', ' ').Substring(0, [Math]::Min(120, $rv.Err.Trim().Length)))
$ra = Invoke-Gh @('release', 'verify-asset', $Version, $file, '-R', 'cli/cli')
$null = Check 'online: gh release verify-asset (no token) FAILS as expected' ($ra.Rc -ne 0) "rc=$($ra.Rc)"

# ---- 2. offline route: bundle from the anonymous attestations API (a real feed ships it as a release asset) ----
$resp = Invoke-WebRequest -Uri "https://api.github.com/repos/cli/cli/attestations/sha256:$sha" -Headers @{ 'User-Agent' = 'u3probe'; Accept = 'application/vnd.github+json' } -UseBasicParsing
$null = Check 'anonymous attestations API' ($resp.StatusCode -eq 200) "HTTP $($resp.StatusCode), rate-limit remaining $($resp.Headers['X-RateLimit-Remaining'])"
$att = ($resp.Content | ConvertFrom-Json).attestations
$lines = New-Object System.Collections.Generic.List[string]
foreach ($a in $att) {
    $raw = (New-Object System.Net.WebClient).DownloadData($a.bundle_url)
    $json = [Text.Encoding]::UTF8.GetString((ConvertFrom-SnappyBlock -Bytes $raw))
    $lines.Add(($json | ConvertFrom-Json | ConvertTo-Json -Depth 50 -Compress))
}
$bundle = Join-Path $work 'bundle.jsonl'
[IO.File]::WriteAllText($bundle, ($lines -join "`n") + "`n")
$null = Check 'bundles decoded (snappy)' ($lines.Count -ge 1) "$($lines.Count) bundle(s)"

$flags = @('--repo', 'cli/cli', '--bundle', $bundle, '--signer-workflow', 'github.com/cli/cli/.github/workflows/deployment.yml', '--source-ref', 'refs/heads/trunk', '--deny-self-hosted-runners')
$ok = Invoke-Gh (@('attestation', 'verify', $file) + $flags + @('--format', 'json'))
$null = Check 'OFFLINE: attestation verify --bundle with pinned flags (unauthenticated SYSTEM)' ($ok.Rc -eq 0) "rc=$($ok.Rc) stderr=[$($ok.Err.Trim())]"

$tr = Invoke-Gh @('attestation', 'trusted-root')
$trf = Join-Path $work 'trusted_root.jsonl'; [IO.File]::WriteAllText($trf, $tr.Out)
$ok2 = Invoke-Gh (@('attestation', 'verify', $file) + $flags + @('--custom-trusted-root', $trf))
$null = Check 'OFFLINE: trusted-root fetched unauthenticated, verify with --custom-trusted-root' ($tr.Rc -eq 0 -and $ok2.Rc -eq 0) "trusted-root rc=$($tr.Rc), verify rc=$($ok2.Rc)"

# ---- 3. negatives must fail closed ----
$bad = Join-Path $work 'tampered.zip'; Copy-Item $file $bad
$fs = [IO.File]::Open($bad, 'Open', 'ReadWrite'); $fs.Position = 100; $fs.WriteByte(0xFF); $fs.Dispose()
$n1 = Invoke-Gh (@('attestation', 'verify', $bad) + $flags)
$null = Check 'negative: tampered byte' ($n1.Rc -ne 0) "rc=$($n1.Rc)"
$n2 = Invoke-Gh @('attestation', 'verify', $file, '--repo', 'cli/go-gh', '--bundle', $bundle)
$null = Check 'negative: wrong repo' ($n2.Rc -ne 0) "rc=$($n2.Rc)"
$n3 = Invoke-Gh @('attestation', 'verify', $file, '--repo', 'cli/cli', '--bundle', $bundle, '--signer-workflow', 'github.com/cli/cli/.github/workflows/evil.yml')
$null = Check 'negative: wrong signer workflow' ($n3.Rc -ne 0) "rc=$($n3.Rc)"
$n4 = Invoke-Gh @('attestation', 'verify', $file, '--repo', 'cli/cli', '--bundle', $bundle, '--source-ref', 'refs/heads/automation')
$null = Check 'negative: wrong source ref' ($n4.Rc -ne 0) "rc=$($n4.Rc) $($n4.Err.Trim())"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
$results | ForEach-Object { Write-Output $_ }
$fail = @($results | Where-Object { $_ -like 'FAIL*' }).Count
Write-Output ("U3 probe finished: {0} check(s), {1} failure(s)" -f $results.Count, $fail)
exit $(if ($fail -eq 0) { 0 } else { 1 })
