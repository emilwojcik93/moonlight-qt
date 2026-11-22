# Local config (program dir, admin-only), policy.yml extraction, local state.json, test-mode flag.

Set-StrictMode -Version Latest

$script:UpdConfigDefaults = [ordered]@{
    schema             = 1
    mode               = 'report-only'     # install | report-only | hold  (safe default until gate G4)
    channel            = 'canary'          # canary | stable
    cooling_off_hours  = 0
    repo               = 'emilwojcik93/moonlight-qt'
    policy_branch      = 'automation'
    policy_path        = 'policy.yml'
    signer_workflow    = 'github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml'
    verify_mode        = 'offline'         # offline (bundle from release, no token) | online (adds gh release verify, needs token file)
    notify_enabled     = $false
    max_installer_mb   = 200
}

function Get-UpdTestModeFlagPath {
    param([Parameter(Mandatory)][string]$ProgramDir)
    return (Join-Path $ProgramDir 'test-mode.flag')
}

function Test-UpdTestMode {
    <# Test mode exists only when the flag file sits in the (admin-only) program dir. Env vars never enable it. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ProgramDir)
    return (Test-Path -LiteralPath (Get-UpdTestModeFlagPath -ProgramDir $ProgramDir) -PathType Leaf)
}

function Read-UpdConfig {
    <#
      Reads config.json from the program dir, validates every field against a whitelist.
      Unknown keys are ignored but logged by the caller; invalid values throw (fail closed).
      Test-only keys (api_base, download_base, gh_path, allow_http) are honoured ONLY when the
      test-mode flag file exists; otherwise their presence throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramDir)
    $cfg = @{}
    foreach ($k in $script:UpdConfigDefaults.Keys) { $cfg[$k] = $script:UpdConfigDefaults[$k] }
    $path = Join-Path $ProgramDir 'config.json'
    $testMode = Test-UpdTestMode -ProgramDir $ProgramDir
    $cfg['test_mode'] = $testMode
    if (Test-Path -LiteralPath $path) {
        $raw = [System.IO.File]::ReadAllText($path)
        try { $j = $raw | ConvertFrom-Json } catch { throw "config.json is not valid JSON" }
        if ($null -eq $j) { throw 'config.json is empty' }
        $names = @($j.PSObject.Properties.Name)
        $testOnly = @('api_base', 'download_base', 'gh_path', 'allow_http', 'data_dir', 'skip_acl_check')
        foreach ($n in $names) {
            if ($testOnly -contains $n) {
                if (-not $testMode) { throw "config key '$n' requires test-mode flag file" }
                $cfg[$n] = $j.$n
            } elseif ($script:UpdConfigDefaults.Contains($n)) {
                $cfg[$n] = $j.$n
            }
        }
    }
    # ---- validation ----
    if ($cfg['schema'] -ne 1) { throw 'config schema must be 1' }
    if (@('install', 'report-only', 'hold') -cnotcontains [string]$cfg['mode']) { throw 'config mode must be install|report-only|hold' }
    if (@('canary', 'stable') -cnotcontains [string]$cfg['channel']) { throw 'config channel must be canary|stable' }
    $co = $cfg['cooling_off_hours']
    if (($co -isnot [int] -and $co -isnot [double] -and $co -isnot [long]) -or $co -lt 0 -or $co -gt 720) { throw 'cooling_off_hours must be a number 0..720' }
    if (-not (Test-UpdRegex ([string]$cfg['repo']) '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$')) { throw 'config repo invalid' }
    if (-not (Test-UpdRegex ([string]$cfg['policy_branch']) '^[A-Za-z0-9][A-Za-z0-9._/-]{0,60}$')) { throw 'config policy_branch invalid' }
    if (-not (Test-UpdRegex ([string]$cfg['policy_path']) '^[A-Za-z0-9._-]{1,60}$')) { throw 'config policy_path invalid' }
    if (-not (Test-UpdRegex ([string]$cfg['signer_workflow']) '^github\.com/[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}/\.github/workflows/[A-Za-z0-9._-]{1,80}\.ya?ml$')) { throw 'config signer_workflow invalid' }
    if (@('offline', 'online') -cnotcontains [string]$cfg['verify_mode']) { throw 'config verify_mode must be offline|online' }
    if ($cfg['notify_enabled'] -isnot [bool]) { throw 'notify_enabled must be boolean' }
    $mb = $cfg['max_installer_mb']
    if (($mb -isnot [int] -and $mb -isnot [long]) -or $mb -lt 1 -or $mb -gt 1024) { throw 'max_installer_mb must be 1..1024' }
    # the signer workflow must belong to the configured repo (prevents pointing trust at another repo's workflow)
    if (-not ([string]$cfg['signer_workflow']).StartsWith(('github.com/{0}/' -f $cfg['repo']), [StringComparison]::Ordinal)) { throw 'signer_workflow must live in the configured repo' }
    foreach ($k in @('api_base', 'download_base')) {
        if ($cfg.ContainsKey($k)) {
            $allowHttp = ($cfg.ContainsKey('allow_http') -and $cfg['allow_http'] -eq $true)
            $pat = '^https://[A-Za-z0-9.-]{1,100}(:[0-9]{1,5})?$'
            if ($allowHttp) { $pat = '^https?://[A-Za-z0-9.-]{1,100}(:[0-9]{1,5})?$' }
            if (-not (Test-UpdRegex ([string]$cfg[$k]) $pat)) { throw "config $k invalid" }
        }
    }
    if ($cfg.ContainsKey('data_dir') -and -not (Test-UpdRegex ([string]$cfg['data_dir']) '^[A-Za-z]:\\[^"<>|*?]{1,200}$')) { throw 'config data_dir invalid' }
    if ($cfg.ContainsKey('skip_acl_check') -and $cfg['skip_acl_check'] -isnot [bool]) { throw 'config skip_acl_check must be boolean' }
    if (-not $cfg.ContainsKey('api_base')) { $cfg['api_base'] = $script:UpdConst.DefaultApiBase }
    if (-not $cfg.ContainsKey('download_base')) { $cfg['download_base'] = $script:UpdConst.DefaultDlBase }
    return $cfg
}

function Get-EffectiveMode {
    <# A command-line override may only make the run MORE restrictive than config (install > report-only > hold). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigMode, [AllowNull()][string]$Override)
    $rank = @{ 'install' = 2; 'report-only' = 1; 'hold' = 0 }
    if ([string]::IsNullOrEmpty($Override)) { return $ConfigMode }
    if (-not $rank.ContainsKey($Override)) { throw 'invalid mode override' }
    if ($rank[$Override] -lt $rank[$ConfigMode]) { return $Override }
    return $ConfigMode
}

# ---- policy.yml -------------------------------------------------------------------------------
function ConvertTo-UpdPolicy {
    <#
      Parsed YAML (hashtable) -> normalised policy object. Accepts the CONTRACT shape
      (allow_upstream_owners, cooling_off_hours{stable,canary}, hold, deny, keep_releases) and the
      shape currently on the automation branch (upstream.owner_allowlist, channels.<c>.cooling_off_hours).
      Fail closed: hold must be a boolean, deny entries must match the tag regex.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Doc)
    if ($Doc -isnot [hashtable]) { throw 'policy root must be a map' }
    $hold = $false
    if ($Doc.ContainsKey('hold')) {
        if ($Doc['hold'] -isnot [bool]) { throw 'policy hold must be boolean' }
        $hold = $Doc['hold']
    }
    $deny = @()
    if ($Doc.ContainsKey('deny') -and $null -ne $Doc['deny']) {
        foreach ($d in @($Doc['deny'])) {
            if (-not (Test-MoonlightTag -Tag ([string]$d))) { throw 'policy deny entry is not a valid tag' }
            $deny += [string]$d
        }
    }
    $owners = @()
    if ($Doc.ContainsKey('allow_upstream_owners') -and $null -ne $Doc['allow_upstream_owners']) {
        $owners = @($Doc['allow_upstream_owners'] | ForEach-Object { [string]$_ })
    } elseif ($Doc.ContainsKey('upstream') -and $Doc['upstream'] -is [hashtable] -and $Doc['upstream'].ContainsKey('owner_allowlist') -and $null -ne $Doc['upstream']['owner_allowlist']) {
        $owners = @($Doc['upstream']['owner_allowlist'] | ForEach-Object { [string]$_ })
    }
    foreach ($o in $owners) { if (-not (Test-UpdRegex $o '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')) { throw 'policy owner invalid' } }
    $cool = @{ stable = $null; canary = $null }
    foreach ($ch in 'stable', 'canary') {
        $v = $null
        if ($Doc.ContainsKey('cooling_off_hours') -and $Doc['cooling_off_hours'] -is [hashtable] -and $Doc['cooling_off_hours'].ContainsKey($ch)) {
            $v = $Doc['cooling_off_hours'][$ch]
        } elseif ($Doc.ContainsKey('channels') -and $Doc['channels'] -is [hashtable] -and $Doc['channels'].ContainsKey($ch) -and
            $Doc['channels'][$ch] -is [hashtable] -and $Doc['channels'][$ch].ContainsKey('cooling_off_hours')) {
            $v = $Doc['channels'][$ch]['cooling_off_hours']
        }
        if ($null -ne $v) {
            if ($v -isnot [int] -or $v -lt 0 -or $v -gt 720) { throw "policy cooling_off_hours.$ch invalid" }
            $cool[$ch] = [int]$v
        }
    }
    return [pscustomobject]@{ Hold = $hold; Deny = $deny; AllowOwners = $owners; CoolingOff = $cool; HasDenyKey = $Doc.ContainsKey('deny') }
}

function Get-EffectiveCoolingOffHours {
    <# Local value is a floor; policy may only raise it for the configured channel. #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][double]$LocalHours, [Parameter(Mandatory)]$Policy, [Parameter(Mandatory)][string]$Channel)
    $h = $LocalHours
    $p = $Policy.CoolingOff[$Channel]
    if ($null -ne $p -and $p -gt $h) { $h = [double]$p }
    return $h
}

# ---- local state.json (data dir, admin-only) ---------------------------------------------------
function New-UpdState {
    return [pscustomobject]@{
        schema = 1; installed = $null; denied = @(); failures = @{}; last_check_utc = $null
        last_success_utc = $null; etag_releases = $null; etag_branch = $null; policy_sha = $null; bundles = @()
    }
}

function Read-UpdState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir)
    $p = Join-Path $DataDir 'state.json'
    $st = New-UpdState
    if (-not (Test-Path -LiteralPath $p)) { return $st }
    try {
        $j = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
    } catch {
        # corrupt state: keep a copy, start fresh (deny entries lost => policy deny list still protects)
        Move-Item -LiteralPath $p -Destination ($p + '.corrupt') -Force -ErrorAction SilentlyContinue
        return $st
    }
    foreach ($n in @($j.PSObject.Properties.Name)) {
        if ($st.PSObject.Properties.Name -contains $n) { $st.$n = $j.$n }
    }
    if ($null -eq $st.denied) { $st.denied = @() }
    if ($null -eq $st.bundles) { $st.bundles = @() }
    return $st
}

function Save-UpdState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)]$State)
    $p = Join-Path $DataDir 'state.json'
    $tmp = $p + '.tmp'
    $json = $State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

function Test-LocallyDenied {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag)
    foreach ($d in @($State.denied)) {
        if ($null -ne $d -and ($d.PSObject.Properties.Name -contains 'tag') -and [string]$d.tag -ceq $Tag) { return $true }
    }
    return $false
}

function Add-LocalDeny {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Reason)
    if (Test-LocallyDenied -State $State -Tag $Tag) { return }
    $State.denied = @($State.denied) + [pscustomobject]@{ tag = $Tag; reason = (ConvertTo-SafeLogValue $Reason 120); at = (Get-UpdNowUtc).ToString('o') }
}
