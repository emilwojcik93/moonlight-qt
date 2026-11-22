# Anonymous GitHub API access: conditional requests (ETag), rate-limit awareness, release list,
# policy fetch pinned to a commit SHA, bounded downloads. PowerShell 5.1 compatible (HttpClient).

Set-StrictMode -Version Latest

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'tls12 set failed' }
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { Write-Verbose 'System.Net.Http preloaded' }

function Test-AllowedDownloadHost {
    <# Every hop of a request (including redirects): HTTPS only, exact host allow-list (-AllowHttp admits loopback for in-process tests only). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][uri]$Uri, [switch]$AllowHttp)
    if ($Uri.Scheme -ne 'https' -and -not ($AllowHttp -and $Uri.Scheme -eq 'http')) { return $false }
    $h = $Uri.Host.ToLowerInvariant()
    if ($AllowHttp -and ($h -eq '127.0.0.1' -or $h -eq 'localhost')) { return $true }
    foreach ($ok in @('github.com', 'api.github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')) {
        if ($h -eq $ok) { return $true }
    }
    return $false
}

function Invoke-UpdHttp {
    <#
      Single logical HTTP GET with MANUAL redirect handling: every hop (including the first request) must pass
      Test-AllowedDownloadHost before it is contacted; at most 5 hops. Returns @{Status;Headers(lower-case keys);Body|FilePath;Bytes;FinalUri}.
      -OutFile streams to disk with a hard byte cap. A body shorter than Content-Length, or different from -ExpectedSize, throws
      (truncated download). Never throws on HTTP status codes (caller decides); throws on transport errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$OutFile,
        [long]$MaxBytes = 5MB,
        [long]$ExpectedSize = -1,
        [int]$TimeoutSec = 60,
        [switch]$AllowHttp
    )
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $u = [uri]$Uri
        $resp = $null
        for ($hop = 0; $hop -le 5; $hop++) {
            if (-not (Test-AllowedDownloadHost -Uri $u -AllowHttp:$AllowHttp)) { throw "request to disallowed host or scheme (hop $hop)" }
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $u)
            [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'MoonlightPatchUpdater/1')
            foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation([string]$k, [string]$Headers[$k]) }
            if ($null -ne $resp) { $resp.Dispose() }
            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            if ($code -ge 300 -and $code -lt 400 -and $code -ne 304 -and $null -ne $resp.Headers.Location) {
                if ($hop -ge 5) { throw 'too many redirects' }
                $u = New-Object System.Uri($u, $resp.Headers.Location)
                continue
            }
            break
        }
        try {
            $h = @{}
            foreach ($hh in $resp.Headers) { $h[$hh.Key.ToLowerInvariant()] = ($hh.Value -join ',') }
            foreach ($hh in $resp.Content.Headers) { $h[$hh.Key.ToLowerInvariant()] = ($hh.Value -join ',') }
            $result = @{ Status = [int]$resp.StatusCode; Headers = $h; FinalUri = $u.AbsoluteUri; Body = $null; FilePath = $null; Bytes = 0 }
            $len = $resp.Content.Headers.ContentLength
            if ($null -ne $len -and $len -gt $MaxBytes) { throw "response too large ($len > $MaxBytes)" }
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $total = 0L
                if ($OutFile) {
                    $fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $buf = New-Object byte[] 81920
                        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                            $total += $n
                            if ($total -gt $MaxBytes) { throw "download exceeds cap $MaxBytes" }
                            $fs.Write($buf, 0, $n)
                        }
                    } finally { $fs.Dispose() }
                    $result.FilePath = $OutFile
                } else {
                    $ms = New-Object System.IO.MemoryStream
                    try {
                        $buf = New-Object byte[] 81920
                        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                            if ($ms.Length + $n -gt $MaxBytes) { throw "response exceeds cap $MaxBytes" }
                            $ms.Write($buf, 0, $n)
                        }
                        $total = $ms.Length
                        $result.Body = (New-Object System.Text.UTF8Encoding($false)).GetString($ms.ToArray())
                    } finally { $ms.Dispose() }
                }
                $result.Bytes = $total
                if ($result.Status -eq 200) {
                    if ($null -ne $len -and $total -ne $len) { throw "truncated download ($total of $len bytes)" }
                    if ($ExpectedSize -ge 0 -and $total -ne $ExpectedSize) { throw "download size $total differs from expected $ExpectedSize" }
                }
            } finally { $stream.Dispose() }
            return $result
        } finally { $resp.Dispose() }
    } finally { $client.Dispose(); $handler.Dispose() }
}

function Get-RateLimitState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Headers)
    $rem = $null; $reset = $null
    if ($Headers.ContainsKey('x-ratelimit-remaining')) { $t = 0; if ([int]::TryParse($Headers['x-ratelimit-remaining'], [ref]$t)) { $rem = $t } }
    if ($Headers.ContainsKey('x-ratelimit-reset')) { $t = 0L; if ([long]::TryParse($Headers['x-ratelimit-reset'], [ref]$t)) { $reset = [DateTimeOffset]::FromUnixTimeSeconds($t).UtcDateTime } }
    $retry = $null
    if ($Headers.ContainsKey('retry-after')) { $t = 0; if ([int]::TryParse($Headers['retry-after'], [ref]$t)) { $retry = $t } }
    return [pscustomobject]@{ Remaining = $rem; ResetUtc = $reset; RetryAfter = $retry }
}

function Invoke-UpdApi {
    <#
      GET <api_base><path> with optional If-None-Match. Returns @{Status;Json;Etag;RateLimit;Raw}.
      Status 304 => Json $null (caller loads its cache). 403/429 with rate-limit exhaustion => throws
      an exception whose Data['RateLimited']=$true so the orchestrator can defer (exit 8) without alarm.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path,
        [string]$Etag,
        [long]$MaxBytes = 4MB
    )
    $h = @{ 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($Etag) { $h['If-None-Match'] = $Etag }
    $allowHttp = ($Config.ContainsKey('allow_http') -and $Config['allow_http'] -eq $true)
    $r = Invoke-UpdHttp -Uri ($Config['api_base'].TrimEnd('/') + $Path) -Headers $h -MaxBytes $MaxBytes -AllowHttp:$allowHttp
    $rl = Get-RateLimitState -Headers $r.Headers
    if ($r.Status -eq 429 -or ($r.Status -eq 403 -and (($null -ne $rl.Remaining -and $rl.Remaining -le 0) -or $null -ne $rl.RetryAfter))) {
        $e = New-Object System.Exception('GitHub API rate limit reached')
        $e.Data['RateLimited'] = $true
        if ($null -ne $rl.ResetUtc) { $e.Data['ResetUtc'] = $rl.ResetUtc.ToString('o') }
        throw $e
    }
    $et = $null
    if ($r.Headers.ContainsKey('etag')) { $et = $r.Headers['etag'] }
    $sd = $null
    if ($r.Headers.ContainsKey('date')) { $t = [datetime]::MinValue; if ([datetime]::TryParse($r.Headers['date'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$t)) { $sd = $t } }
    if ($r.Status -eq 304) { return @{ Status = 304; Json = $null; Etag = $Etag; RateLimit = $rl; Raw = $null; ServerDate = $sd } }
    if ($r.Status -ne 200) { throw ("GitHub API returned HTTP {0} for {1}" -f $r.Status, $Path) }
    try { $j = $r.Body | ConvertFrom-Json } catch { throw 'GitHub API returned invalid JSON' }
    return @{ Status = 200; Json = $j; Etag = $et; RateLimit = $rl; Raw = $r.Body; ServerDate = $sd }
}

function Get-UpdReleases {
    <# Release list (ETag-cached on disk in the data dir). Returns @{Releases; FromCache; Etag; RateLimit}. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)]$State)
    $cacheDir = Join-Path $DataDir 'cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $cacheFile = Join-Path $cacheDir 'releases.json'
    $etag = $null
    if ((Test-Path -LiteralPath $cacheFile) -and $State.etag_releases) { $etag = [string]$State.etag_releases }
    $r = Invoke-UpdApi -Config $Config -Path ("/repos/{0}/releases?per_page=30" -f $Config['repo']) -Etag $etag
    if ($r.Status -eq 304) {
        $json = [System.IO.File]::ReadAllText($cacheFile) | ConvertFrom-Json
        return @{ Releases = @($json); FromCache = $true; Etag = $etag; RateLimit = $r.RateLimit; ServerDate = $r.ServerDate }
    }
    [System.IO.File]::WriteAllText($cacheFile, $r.Raw, (New-Object System.Text.UTF8Encoding($false)))
    $State.etag_releases = $r.Etag
    return @{ Releases = @($r.Json); FromCache = $false; Etag = $r.Etag; RateLimit = $r.RateLimit; ServerDate = $r.ServerDate }
}

function Get-UpdPolicy {
    <#
      CONTRACT 5: read policy.yml via the contents API, pinned to a commit SHA obtained from the API:
        1. GET /repos/{repo}/branches/{branch}        -> commit.sha  (40 hex, validated; ETag-cached, 304 is free)
        2. GET /repos/{repo}/contents/{path}?ref=<sha> -> base64 content of exactly that commit (cached on disk per sha)
      Returns @{Policy; CommitSha}. Fails closed (throws) when anything is missing/invalid: a client
      without a readable policy never installs. Anonymous: two calls instead of one "same authenticated call"
      (documented deviation); the second call is pinned to the sha of the first, so a branch move in between is harmless.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$DataDir)
    $cacheDir = Join-Path $DataDir 'cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $branchCache = Join-Path $cacheDir 'branch.json'
    $etag = $null
    if ((Test-Path -LiteralPath $branchCache) -and $State.etag_branch) { $etag = [string]$State.etag_branch }
    $branchEnc = [uri]::EscapeDataString($Config['policy_branch']).Replace('%2F', '/')
    $b = Invoke-UpdApi -Config $Config -Path ("/repos/{0}/branches/{1}" -f $Config['repo'], $branchEnc) -Etag $etag
    $bj = $null
    if ($b.Status -eq 304) { $bj = [System.IO.File]::ReadAllText($branchCache) | ConvertFrom-Json }
    elseif ($b.Status -eq 200 -and $null -ne $b.Json) {
        [System.IO.File]::WriteAllText($branchCache, $b.Raw, (New-Object System.Text.UTF8Encoding($false)))
        $State.etag_branch = $b.Etag
        $bj = $b.Json
    } else { throw 'policy: branch lookup failed' }
    $sha = $null
    if ($bj.PSObject.Properties.Name -contains 'commit' -and $bj.commit.PSObject.Properties.Name -contains 'sha') { $sha = [string]$bj.commit.sha }
    if (-not (Test-UpdRegex $sha '^[0-9a-f]{40}$')) { throw 'policy: branch commit sha invalid' }

    $polFile = Join-Path $cacheDir ('policy-{0}.yml' -f $sha)
    $rl = $b.RateLimit
    if (Test-Path -LiteralPath $polFile -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($polFile)
    } else {
        $c = Invoke-UpdApi -Config $Config -Path ("/repos/{0}/contents/{1}?ref={2}" -f $Config['repo'], $Config['policy_path'], $sha) -MaxBytes 256KB
        if ($c.Status -ne 200 -or $null -eq $c.Json) { throw 'policy: contents lookup failed' }
        $rl = $c.RateLimit
        $names = $c.Json.PSObject.Properties.Name
        if (-not ($names -contains 'content') -or -not ($names -contains 'encoding') -or [string]$c.Json.encoding -ne 'base64') { throw 'policy: unexpected contents response' }
        if (($names -contains 'type') -and [string]$c.Json.type -ne 'file') { throw 'policy: not a file' }
        try { $bytes = [Convert]::FromBase64String(([string]$c.Json.content -replace '\s', '')) } catch { throw 'policy: bad base64' }
        if ($bytes.Length -gt 256KB) { throw 'policy: too large' }
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    $doc = ConvertFrom-YamlSubset -Text $text
    $policy = ConvertTo-UpdPolicy -Doc $doc
    # only a fully parsed and validated policy is cached (keyed by commit sha); keep the 3 newest
    if (-not (Test-Path -LiteralPath $polFile)) {
        [System.IO.File]::WriteAllText($polFile, $text, (New-Object System.Text.UTF8Encoding($false)))
        $old = @(Get-ChildItem -LiteralPath $cacheDir -Filter 'policy-*.yml' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3)
        foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue }
    }
    $State.policy_sha = $sha
    return @{ Policy = $policy; CommitSha = $sha; RateLimit = $rl }
}

function Get-ReleaseAssetMap {
    <# name -> @{Name;Size;Digest} for the release JSON; asset names validated. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Release)
    $map = @{}
    if (-not ($Release.PSObject.Properties.Name -contains 'assets')) { return $map }
    foreach ($a in @($Release.assets)) {
        if ($null -eq $a) { continue }
        $n = [string]$a.name
        if (-not (Test-SafeAssetName -Name $n)) { continue }
        $digest = $null
        if ($a.PSObject.Properties.Name -contains 'digest' -and $null -ne $a.digest) { $digest = [string]$a.digest }
        $size = 0L
        if ($a.PSObject.Properties.Name -contains 'size') { $size = [long]$a.size }
        $map[$n] = [pscustomobject]@{ Name = $n; Size = $size; Digest = $digest }
    }
    return $map
}

function Save-ReleaseAsset {
    <#
      Downloads one asset into the per-run dir. The URL is CONSTRUCTED from the validated repo, tag and
      asset name (never taken from API-provided URLs). Every redirect hop is checked against the host allow-list.
      Hard size cap; -ExpectedSize (manifest / API size) and Content-Length are enforced (truncation => throw).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RunDir,
        [long]$MaxBytes = 5MB,
        [long]$ExpectedSize = -1,
        [int]$TimeoutSec = 120
    )
    if (-not (Test-MoonlightTag -Tag $Tag)) { throw 'download: invalid tag' }
    if (-not (Test-SafeAssetName -Name $Name)) { throw 'download: invalid asset name' }
    $dest = Join-Path $RunDir $Name
    $fullRun = [System.IO.Path]::GetFullPath($RunDir)
    if (-not ([System.IO.Path]::GetFullPath($dest)).StartsWith($fullRun, [StringComparison]::OrdinalIgnoreCase)) { throw 'download: path escape' }
    $uri = '{0}/{1}/releases/download/{2}/{3}' -f $Config['download_base'].TrimEnd('/'), $Config['repo'], $Tag, $Name
    $allowHttp = ($Config.ContainsKey('allow_http') -and $Config['allow_http'] -eq $true)
    try {
        $r = Invoke-UpdHttp -Uri $uri -OutFile $dest -MaxBytes $MaxBytes -ExpectedSize $ExpectedSize -TimeoutSec $TimeoutSec -AllowHttp:$allowHttp
    } catch {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw
    }
    if ($r.Status -ne 200) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw ("download of {0} failed with HTTP {1}" -f $Name, $r.Status)
    }
    return $dest
}
