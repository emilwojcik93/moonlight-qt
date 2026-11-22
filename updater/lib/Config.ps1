# Local config (program dir, admin-only), policy.yml extraction, local state.json, attempt counters.

Set-StrictMode -Version Latest

$script:UpdConfigDefaults = [ordered]@{
    schema                = 1
    mode                  = 'report-only'     # install | report-only | hold  (safe default until gate G4)
    channel               = 'canary'          # canary | stable
    cooling_off_hours     = 0                 # local value; effective = max(min_cooling_off_hours, this, policy[channel])
    min_cooling_off_hours = 2                 # local floor: policy (e.g. canary 0) can never go below it
    repo                  = 'emilwojcik93/moonlight-qt'
    policy_branch         = 'automation'
    policy_path           = 'policy.yml'
    signer_workflow       = 'github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml'
    verify_mode           = 'offline'         # offline (bundle from release, no token) | online (adds gh release verify, needs token file)
    notify_enabled        = $false
    max_installer_mb      = 200
    allow_no_baseline     = $false            # install even when no rollback baseline exists (NOT recommended)
    upstream_owners       = @('Nonary')       # local owner floor: manifest.upstream.owner must be in this list AND in the policy list
}

function Read-UpdConfig {
    <#
      Reads config.json from the program dir and validates every field against a whitelist. There are NO test or override
      keys: any key outside the whitelist makes the config invalid (fail closed; no path, URL or executable can be injected).
      The returned hashtable also carries api_base / download_base (hard-coded defaults) so that in-process callers (the test
      harness) can substitute them in memory; config.json can never set them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramDir)
    $cfg = @{}
    foreach ($k in $script:UpdConfigDefaults.Keys) { $cfg[$k] = $script:UpdConfigDefaults[$k] }
    $path = Join-Path $ProgramDir 'config.json'
    if (Test-Path -LiteralPath $path) {
        $raw = [System.IO.File]::ReadAllText($path)
        try { $j = $raw | ConvertFrom-Json } catch { throw "config.json is not valid JSON" }
        if ($null -eq $j) { throw 'config.json is empty' }
        foreach ($n in @($j.PSObject.Properties.Name)) {
            if (-not $script:UpdConfigDefaults.Contains($n)) { throw "unknown config key '$n'" }
            $cfg[$n] = $j.$n
        }
    }
    # ---- validation ----
    if ($cfg['schema'] -ne 1) { throw 'config schema must be 1' }
    if (@('install', 'report-only', 'hold') -cnotcontains [string]$cfg['mode']) { throw 'config mode must be install|report-only|hold' }
    if (@('canary', 'stable') -cnotcontains [string]$cfg['channel']) { throw 'config channel must be canary|stable' }
    foreach ($hk in 'cooling_off_hours', 'min_cooling_off_hours') {
        $co = $cfg[$hk]
        if (($co -isnot [int] -and $co -isnot [double] -and $co -isnot [long]) -or $co -lt 0 -or $co -gt 720) { throw "$hk must be a number 0..720" }
    }
    if (-not (Test-UpdRegex ([string]$cfg['repo']) '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$')) { throw 'config repo invalid' }
    if (-not (Test-UpdRegex ([string]$cfg['policy_branch']) '^[A-Za-z0-9][A-Za-z0-9._/-]{0,60}$')) { throw 'config policy_branch invalid' }
    if (-not (Test-UpdRegex ([string]$cfg['policy_path']) '^[A-Za-z0-9._-]{1,60}$')) { throw 'config policy_path invalid' }
    if (-not (Test-UpdRegex ([string]$cfg['signer_workflow']) '^github\.com/[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}/\.github/workflows/[A-Za-z0-9._-]{1,80}\.ya?ml$')) { throw 'config signer_workflow invalid' }
    if (@('offline', 'online') -cnotcontains [string]$cfg['verify_mode']) { throw 'config verify_mode must be offline|online' }
    if ($cfg['notify_enabled'] -isnot [bool]) { throw 'notify_enabled must be boolean' }
    if ($cfg['allow_no_baseline'] -isnot [bool]) { throw 'allow_no_baseline must be boolean' }
    $mb = $cfg['max_installer_mb']
    if (($mb -isnot [int] -and $mb -isnot [long]) -or $mb -lt 1 -or $mb -gt 1024) { throw 'max_installer_mb must be 1..1024' }
    $own = @($cfg['upstream_owners'])
    if ($own.Count -lt 1) { throw 'upstream_owners must not be empty' }
    foreach ($o in $own) { if (-not (Test-UpdRegex ([string]$o) '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')) { throw 'upstream_owners entry invalid' } }
    $cfg['upstream_owners'] = @($own | ForEach-Object { [string]$_ })
    # the signer workflow must belong to the configured repo (prevents pointing trust at another repo's workflow)
    if (-not ([string]$cfg['signer_workflow']).StartsWith(('github.com/{0}/' -f $cfg['repo']), [StringComparison]::Ordinal)) { throw 'signer_workflow must live in the configured repo' }
    $cfg['api_base'] = $script:UpdConst.DefaultApiBase
    $cfg['download_base'] = $script:UpdConst.DefaultDlBase
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
    <# effective = max(local floor, local value, policy value for the channel). The policy can only raise it above the floor. #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][double]$LocalHours, [Parameter(Mandatory)]$Policy, [Parameter(Mandatory)][string]$Channel, [double]$MinHours = 0)
    $h = [math]::Max($LocalHours, $MinHours)
    $p = $Policy.CoolingOff[$Channel]
    if ($null -ne $p -and $p -gt $h) { $h = [double]$p }
    return $h
}

# ---- local state.json (data dir, admin-only) ---------------------------------------------------
function New-UpdState {
    return [pscustomobject]@{
        schema = 1; installed = $null; denied = @(); attempts = (New-Object psobject); last_check_utc = $null
        last_success_utc = $null; etag_releases = $null; etag_branch = $null; policy_sha = $null
        pending_reboot = $null; verification_pending = $null; rollback_pending = $null; baseline_pins = (New-Object psobject)
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
    if ($null -eq $st.attempts) { $st.attempts = (New-Object psobject) }
    if ($null -eq $st.baseline_pins) { $st.baseline_pins = (New-Object psobject) }
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


# ---- per-tag attempt records (failure counters + exponential backoff) ------------------------------------------
function Get-AttemptRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag)
    $p = $State.attempts.PSObject.Properties[$Tag]
    if ($null -eq $p) { return [pscustomobject]@{ transient = 0; failures = 0; verify_failures = 0; next_after_utc = $null; last_kind = $null; last_utc = $null } }
    return $p.Value
}

function Set-AttemptRecord {
    <# Kind transient | verify | install. Backoff: 15 min * 2^(n-1) for transient/verify (cap 6 h); 1 h * 2^(n-1) for install failures (cap 24 h). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][ValidateSet('transient', 'verify', 'install')][string]$Kind, [Parameter(Mandatory)][datetime]$NowUtc)
    $r = Get-AttemptRecord -State $State -Tag $Tag
    switch ($Kind) {
        'transient' { $r.transient = [int]$r.transient + 1; $cnt = $r.transient; $delay = [math]::Min(360, 15 * [math]::Pow(2, [math]::Min($cnt, 10) - 1)) }
        'verify' { $r.verify_failures = [int]$r.verify_failures + 1; $cnt = $r.verify_failures; $delay = [math]::Min(360, 15 * [math]::Pow(2, [math]::Min($cnt, 10) - 1)) }
        'install' { $r.failures = [int]$r.failures + 1; $cnt = $r.failures; $delay = [math]::Min(1440, 60 * [math]::Pow(2, [math]::Min($cnt, 10) - 1)) }
    }
    $r.last_kind = $Kind; $r.last_utc = $NowUtc.ToString('o'); $r.next_after_utc = $NowUtc.AddMinutes($delay).ToString('o')
    if ($null -eq $State.attempts.PSObject.Properties[$Tag]) { $State.attempts | Add-Member -NotePropertyName $Tag -NotePropertyValue $r } else { $State.attempts.$Tag = $r }
    return $r
}

function Test-AttemptBackoff {
    <# $true while the tag is inside its backoff window. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][datetime]$NowUtc)
    $r = Get-AttemptRecord -State $State -Tag $Tag
    if (-not $r.next_after_utc) { return $false }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$r.next_after_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) { return $false }
    return ($NowUtc -lt $dt)
}

function Clear-AttemptRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag)
    if ($null -ne $State.attempts.PSObject.Properties[$Tag]) { $State.attempts.PSObject.Properties.Remove($Tag) }
}

function Reset-VerifyCounters {
    <# A fully verified release resets the transient and verification counters; install-failure counters are kept (deny after 2). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Tag)
    if ($null -eq $State.attempts.PSObject.Properties[$Tag]) { return }
    $r = $State.attempts.$Tag
    $r.transient = 0; $r.verify_failures = 0
    if ([int]$r.failures -eq 0) { Clear-AttemptRecord -State $State -Tag $Tag }
}
