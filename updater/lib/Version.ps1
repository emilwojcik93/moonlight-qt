# Tag validation, ordering key (U,N), installed-build mapping. CONTRACT sections 1 and 4.1.

Set-StrictMode -Version Latest

# Build scheme "contract-v1": ci_version = 6.2.0-daily.(60000+U) -> FileVersion 6.2.(60000+U).0.
# Everything that depends on the scheme lives in this file (single place to change).
$script:UpdScheme = @{ Offset = 60000; MaxBuild = 65535; Major = 6; Minor = 2 }

function Test-MoonlightTag {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Tag, [string]$Pattern = $script:UpdConst.TagRegex)
    return (Test-UpdRegex -Value $Tag -Pattern $Pattern)
}

function ConvertTo-OrderingKey {
    <# Tag v6.2.0-daily.U-vp.N -> @{U;N;Tag}. Throws on anything that does not match the anchored regex. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tag)
    if (-not (Test-MoonlightTag -Tag $Tag)) { throw "invalid moonlight tag" }
    $m = [regex]::Match($Tag, '^v6\.2\.0-daily\.([0-9]{1,5})-vp\.([0-9]{1,3})$')
    return [pscustomobject]@{ U = [int]$m.Groups[1].Value; N = [int]$m.Groups[2].Value; Tag = $Tag }
}

function Compare-OrderingKey {
    <# -1, 0, 1 comparing (U,N) numerically. #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)]$B)
    if ($A.U -lt $B.U) { return -1 }
    if ($A.U -gt $B.U) { return 1 }
    if ($A.N -lt $B.N) { return -1 }
    if ($A.N -gt $B.N) { return 1 }
    return 0
}

function ConvertTo-BuildNumber {
    <# Upstream-daily number U -> third FileVersion field (scheme contract-v1). #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$U)
    $b = $script:UpdScheme.Offset + $U
    if ($b -gt $script:UpdScheme.MaxBuild) { throw "build number $b exceeds MSI limit" }
    return $b
}

function ConvertFrom-FileVersion {
    <# "6.2.60006.0" (or ProductVersion style) -> @{Major;Minor;Build;Revision;U}. U = Build-60000 or $null when below offset. #>
    [CmdletBinding()]
    param([AllowNull()][string]$Version)
    if ([string]::IsNullOrEmpty($Version)) { return $null }
    $m = [regex]::Match($Version.Trim(), '^([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})(?:\.([0-9]{1,5}))?$')
    if (-not $m.Success) { return $null }
    $rev = 0
    if ($m.Groups[4].Success) { $rev = [int]$m.Groups[4].Value }
    $build = [int]$m.Groups[3].Value
    $u = $null
    if ($build -gt $script:UpdScheme.Offset) { $u = $build - $script:UpdScheme.Offset }
    return [pscustomobject]@{
        Major = [int]$m.Groups[1].Value; Minor = [int]$m.Groups[2].Value; Build = $build; Revision = $rev; U = $u
    }
}

function Resolve-InstalledKey {
    <#
      Installed version -> ordering key.
      * FileVersion 6.2.<60000+U> gives U; N is unknown for builds not installed by this updater => 0.
      * If local state.json recorded an install with the same U, its N wins (we know it exactly).
      Returns $null when nothing usable is installed (caller treats as "not installed": updater does NOT
      install on a machine without Moonlight; first install is a manual step).
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$FileVersion, [AllowNull()]$State)
    $fv = ConvertFrom-FileVersion -Version $FileVersion
    if ($null -eq $fv) { return $null }
    if ($fv.Major -ne $script:UpdScheme.Major -or $fv.Minor -ne $script:UpdScheme.Minor) { return $null }
    if ($null -eq $fv.U) { return $null }
    $n = 0
    if ($null -ne $State) {
        $si = $null
        if ($State.PSObject.Properties.Name -contains 'installed') { $si = $State.installed }
        if ($null -ne $si -and ($si.PSObject.Properties.Name -contains 'u') -and ($si.PSObject.Properties.Name -contains 'n')) {
            if ([int]$si.u -eq $fv.U) { $n = [int]$si.n }
        }
    }
    return [pscustomobject]@{ U = $fv.U; N = $n; Build = $fv.Build; Tag = ('v6.2.0-daily.{0}-vp.{1}' -f $fv.U, $n) }
}

function Select-NewestEligibleRelease {
    <#
      Input: array of API release objects (untrusted). Output: candidate list sorted newest first, each
      @{Release; Key}. Releases that are drafts, have invalid tags, or (channel stable) are pre-releases
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
        $pre = $false
        if ($names -contains 'prerelease') { $pre = ($r.prerelease -eq $true) }
        if ($Channel -eq 'stable' -and $pre) { continue }
        $key = ConvertTo-OrderingKey -Tag $tag
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
