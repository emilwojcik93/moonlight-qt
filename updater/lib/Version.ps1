# Tag validation, ordering key (U,N), installed-build mapping. CONTRACT sections 1 and 4.1.

Set-StrictMode -Version Latest

# Build scheme "contract-v1.1 s3b": ci_version = 6.2.0-daily.B with B = 60000 + 8*U + (N-1), N in 1..8, B <= 65535,
# FileVersion 6.2.B.0. (U,N) is derived from B: U = (B-60000) div 8, N = ((B-60000) mod 8)+1. Ordering is numeric on B.
# A legacy installed build such as 6.2.60006 simply compares numerically lower than any new build (no special case).
# Everything that depends on the scheme lives in this file (single place to change).
$script:UpdScheme = @{ Offset = 60000; PerU = 8; MaxBuild = 65535; Major = 6; Minor = 2 }

function Test-MoonlightTag {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Tag, [string]$Pattern = $script:UpdConst.TagRegex)
    return (Test-UpdRegex -Value $Tag -Pattern $Pattern)
}

function ConvertTo-BuildNumber {
    <# (U,N) -> third FileVersion field. Throws for N outside 1..8 or B above the MSI limit. #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$U, [Parameter(Mandatory)][int]$N)
    if ($U -lt 1) { throw 'U must be >= 1' }
    if ($N -lt 1 -or $N -gt $script:UpdScheme.PerU) { throw "N must be 1..$($script:UpdScheme.PerU)" }
    $b = $script:UpdScheme.Offset + $script:UpdScheme.PerU * $U + ($N - 1)
    if ($b -gt $script:UpdScheme.MaxBuild) { throw "build number $b exceeds MSI limit" }
    return $b
}

function ConvertFrom-BuildNumber {
    <# B -> @{U;N}; $null when B is outside 60000..65535. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Build)
    if ($Build -lt $script:UpdScheme.Offset -or $Build -gt $script:UpdScheme.MaxBuild) { return $null }
    $d = $Build - $script:UpdScheme.Offset
    return [pscustomobject]@{ U = [int][math]::Floor($d / $script:UpdScheme.PerU); N = ($d % $script:UpdScheme.PerU) + 1 }
}

function ConvertTo-OrderingKey {
    <# Tag v6.2.0-daily.U-vp.N -> @{U;N;Build;Tag}. Throws on non-canonical tags and on N > 8 / B > 65535 (not installable). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tag)
    if (-not (Test-MoonlightTag -Tag $Tag)) { throw "invalid moonlight tag" }
    $m = [regex]::Match($Tag, '^v6\.2\.0-daily\.([1-9][0-9]{0,4})-vp\.([1-9][0-9]{0,2})$')
    $u = [int]$m.Groups[1].Value; $n = [int]$m.Groups[2].Value
    $b = ConvertTo-BuildNumber -U $u -N $n
    return [pscustomobject]@{ U = $u; N = $n; Build = $b; Tag = $Tag }
}

function Compare-OrderingKey {
    <# -1, 0, 1 comparing numerically on the build number (equivalent to (U,N) order). #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)]$B)
    if ($A.Build -lt $B.Build) { return -1 }
    if ($A.Build -gt $B.Build) { return 1 }
    return 0
}

function ConvertFrom-FileVersion {
    <# "6.2.61616.0" -> @{Major;Minor;Build;Revision;U;N}. U/N are $null outside the scheme range. #>
    [CmdletBinding()]
    param([AllowNull()][string]$Version)
    if ([string]::IsNullOrEmpty($Version)) { return $null }
    $m = [regex]::Match($Version.Trim(), '^([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})(?:\.([0-9]{1,5}))?$')
    if (-not $m.Success) { return $null }
    $rev = 0
    if ($m.Groups[4].Success) { $rev = [int]$m.Groups[4].Value }
    $build = [int]$m.Groups[3].Value
    $un = ConvertFrom-BuildNumber -Build $build
    $u = $null; $n = $null
    if ($null -ne $un) { $u = $un.U; $n = $un.N }
    return [pscustomobject]@{ Major = [int]$m.Groups[1].Value; Minor = [int]$m.Groups[2].Value; Build = $build; Revision = $rev; U = $u; N = $n }
}

function Resolve-InstalledKey {
    <#
      Installed version -> ordering key, derived from the FileVersion build field alone (state.json is not trusted for ordering).
      Returns $null when nothing usable is installed (the updater does not install on a machine without Moonlight).
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$FileVersion, [AllowNull()]$State)
    $fv = ConvertFrom-FileVersion -Version $FileVersion
    if ($null -eq $fv) { return $null }
    if ($fv.Major -ne $script:UpdScheme.Major -or $fv.Minor -ne $script:UpdScheme.Minor) { return $null }
    if ($null -eq $fv.U) { return $null }
    return [pscustomobject]@{ U = $fv.U; N = $fv.N; Build = $fv.Build; Tag = ('v6.2.0-daily.{0}-vp.{1}' -f $fv.U, $fv.N) }
}

function Select-NewestEligibleRelease {
    <#
      Input: array of API release objects (untrusted). Output: candidate list sorted newest first, each
      @{Release; Key}. Releases that are drafts or have invalid tags (the pre-release flag is NOT used: every feed release is a pre-release; channels differ only by cooling-off)
      are dropped. Never throws on garbage entries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Releases,
        [ValidateSet('canary', 'stable')][string]$Channel = 'canary'
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Releases) {
        if ($null -eq $r) { continue }
        $names = $r.PSObject.Properties.Name
        if (-not ($names -contains 'tag_name')) { continue }
        $tag = [string]$r.tag_name
        if (-not (Test-MoonlightTag -Tag $tag)) { continue }
        if (($names -contains 'draft') -and ($r.draft -eq $true)) { continue }
        $key = $null
        try { $key = ConvertTo-OrderingKey -Tag $tag } catch { continue }   # N > 8 or B > 65535: not installable
        $out.Add([pscustomobject]@{ Release = $r; Key = $key })
    }
    $sorted = @($out.ToArray() | Sort-Object -Property @{ Expression = { $_.Key.U }; Descending = $true }, @{ Expression = { $_.Key.N }; Descending = $true })
    return , $sorted
}

function Get-ReleaseAgeHours {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][string]$PublishedAt, [datetime]$NowUtc = (Get-Date).ToUniversalTime())
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParse($PublishedAt, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)
    if (-not $ok) { throw "unparseable published_at" }
    return ($NowUtc - $dt).TotalHours
}
