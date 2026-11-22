# Update flow (CONTRACT 4 + v1.1 3b). All side effects go through $Deps (injectable) so every branch is testable
# without network, registry, or installers. Fail closed everywhere: any doubt => nothing installed.
#
# Internal time budget (worst case, all well below the task's ExecutionTimeLimit of PT2H):
#   API calls 3 x 60 s | small assets (manifest, SHA256SUMS, bundle) 3 x 120 s | installer download 600 s | gh verify 3 x 180 s
#   installer run 600 s (+ tree kill 30 s + Windows Installer idle wait 120 s) | rollback: up to 3 installer runs x (600 + 150) s
#   rollback wait for Moonlight to close: bounded backoff 30+60+120+240 s | an install is only started when <= 75 min of the
#   run have elapsed.

Set-StrictMode -Version Latest

function New-UpdDeps {
    <# Production implementations. Tests build their own hashtable with the same keys (or override single entries). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ProgramDir)
    $d = @{}
    $d.GhPath = Join-Path (Join-Path $ProgramDir 'bin') 'gh.exe'
    $d.GetReleases = { param($cfg, $dataDir, $state) Get-UpdReleases -Config $cfg -DataDir $dataDir -State $state }
    $d.GetPolicy = { param($cfg, $state, $dataDir) Get-UpdPolicy -Config $cfg -State $state -DataDir $dataDir }
    $d.GetInstalledVersion = { Get-InstalledMoonlightVersion }
    $d.IsMoonlightRunning = { Test-MoonlightRunning }
    $d.GetPresence = { Get-MoonlightPresenceForUser }
    $d.Download = { param($cfg, $tag, $name, $runDir, $maxBytes, $expectedSize, $timeoutSec) Save-ReleaseAsset -Config $cfg -Tag $tag -Name $name -RunDir $runDir -MaxBytes $maxBytes -ExpectedSize $expectedSize -TimeoutSec $timeoutSec }
    $d.AssertGh = { param($gh, $progDir) Assert-GhBinary -GhPath $gh -Pin (Read-GhPin -ProgramDir $progDir) }
    $d.VerifyAttestation = {
        param($gh, $dataDir, $file, $bundle, $repo, $signer, $ref, $digest)
        Test-ArtifactAttestation -GhPath $gh -DataDir $dataDir -FilePath $file -BundlePath $bundle -Repo $repo -SignerWorkflow $signer -SourceRef $ref -SourceDigest $digest
    }
    $d.VerifyReleaseOnline = {
        param($gh, $dataDir, $repo, $tag, $file)
        $tok = Get-UpdSecret -DataDir $dataDir -Name 'gh-token'
        if (-not $tok) { return @{ Ok = $false; Rc = -1; Err = 'verify_mode=online but no gh token provisioned' } }
        $a = Invoke-GhVerify -GhPath $gh -Arguments @('release', 'verify', $tag, '-R', $repo) -DataDir $dataDir -Token $tok
        if (-not $a.Ok) { return $a }
        return (Invoke-GhVerify -GhPath $gh -Arguments @('release', 'verify-asset', $tag, $file, '-R', $repo) -DataDir $dataDir -Token $tok)
    }
    $d.RunInstaller = { param($path, $sha, $log, $verb) Invoke-MoonlightInstaller -InstallerPath $path -ExpectedSha256 $sha -LogPath $log -Verb $verb }
    $d.Rollback = { param($prev, $failedPath, $failedSha, $runDir, $idle) Invoke-MoonlightRollback -Previous $prev -FailedBundlePath $failedPath -FailedSha256 $failedSha -RunDir $runDir -IdleCheck $idle }
    $d.Notify = { param($cfg, $dataDir, $result, $tag, $detail) [void](Send-UpdNotification -Config $cfg -DataDir $dataDir -Result $result -Tag $tag -Detail $detail) }
    $d.Now = { Get-UpdNowUtc }
    $d.Sleep = { param($sec) Start-Sleep -Seconds $sec }
    $d.GetBootTime = { (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }
    $d.TestPathAcl = { param($p) Test-ReadOnlyArtifactAcl -Path $p -StopAt 'C:\ProgramData\Package Cache' }
    $d.PackageCacheBundle = { Join-Path (Join-Path 'C:\ProgramData\Package Cache' $script:UpdConst.BundleGuid) 'MoonlightSetup.exe' }
    $d.AdditionalFullControlSids = @()
    return $d
}

function New-UpdResult {
    param([string]$Result, [string]$Tag = '', [string]$Detail = '', [int]$ExitCode = 0)
    return [pscustomobject]@{ Result = $Result; Tag = $Tag; Detail = $Detail; ExitCode = $ExitCode }
}

function Invoke-MoonlightUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramDir,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Deps,
        [string]$ModeOverride,
        [switch]$VerifyOnly
    )
    $state = Read-UpdState -DataDir $DataDir
    $res = $null
    try {
        $res = Invoke-MoonlightUpdateCore -ProgramDir $ProgramDir -DataDir $DataDir -Config $Config -Deps $Deps -State $state -ModeOverride $ModeOverride -VerifyOnly:$VerifyOnly
    } catch {
        $e = $_.Exception
        $detail = ConvertTo-SafeLogValue $e.Message 300
        if ($e.Data.Contains('RateLimited')) {
            $res = New-UpdResult -Result 'deferred' -Detail "rate limited: $detail" -ExitCode $script:UpdExit.NetworkDefer
        } else {
            Write-UpdLog -Level ERROR -Event 'unhandled' -Data @{ message = $detail }
            $res = New-UpdResult -Result 'failed' -Detail $detail -ExitCode $script:UpdExit.InternalError
        }
    } finally {
        $state.last_check_utc = (& $Deps.Now).ToString('o')
        try { Save-UpdState -DataDir $DataDir -State $state } catch { Write-UpdLog -Level ERROR -Event 'state_save_failed' -Data @{ message = $_.Exception.Message } }
        # failed or aborted runs leave their directory (up to 200 MB) behind: keep only the newest 3
        try { Remove-OldRunDirectories -DataDir $DataDir -KeepLast 3 } catch { Write-Verbose 'run dir pruning failed' }
    }
    if ($res.Result -eq 'verify_failed' -or $res.ExitCode -eq $script:UpdExit.ConfigInvalid) {
        try { & $Deps.Notify $Config $DataDir $res.Result $res.Tag $res.Detail } catch { Write-Verbose 'notify failed' }
    }
    Write-UpdLog -Event 'result' -Data @{ result = $res.Result; tag = $res.Tag; detail = $res.Detail; exit = $res.ExitCode }
    return $res
}

function Get-PreviousBundle {
    <# Bundle matching what is installed now (state.installed.tag, else 'installed-<build>'). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Installed)
    $b = @(Get-VerifiedBundles -DataDir $DataDir)
    $want = @()
    if ($null -ne $State.installed -and ($State.installed.PSObject.Properties.Name -contains 'tag') -and [int]$State.installed.build -eq $Installed.Build) { $want += [string]$State.installed.tag }
    $want += ('installed-{0}' -f $Installed.Build)
    foreach ($w in $want) { foreach ($x in $b) { if ($x.Name -ceq $w) { return $x } } }
    return $null
}

function Resolve-BaselineBundle {
    <#
      Rollback baseline (P2-5): the verified bundle of the build that is installed now, or the existing Burn Package Cache
      bundle copied into the data dir (after an admin-only ACL check). The baseline is re-hashed here, before anything is installed.
      Trust on first use: the SHA256 of a Package Cache baseline is pinned in state.json when first accepted; a different hash
      for the same build later is refused. Returns @{Bundle; Refused; Reason}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Deps, [Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Installed)
    $prev = Get-PreviousBundle -DataDir $DataDir -State $State -Installed $Installed
    if ($null -ne $prev -and (Test-Path -LiteralPath $prev.Path -PathType Leaf) -and ((Get-UpdSha256 -Path $prev.Path) -eq $prev.Sha256)) { return @{ Bundle = $prev; Refused = $false; Reason = $null } }
    $pc = & $Deps.PackageCacheBundle
    if ($pc -and (Test-Path -LiteralPath $pc -PathType Leaf)) {
        $viol = @(& $Deps.TestPathAcl $pc)
        if ($viol.Count -eq 0) {
            $psha = Get-UpdSha256 -Path $pc
            $pinName = 'installed-{0}' -f $Installed.Build
            $pin = $State.baseline_pins.PSObject.Properties[$pinName]
            if ($null -ne $pin -and [string]$pin.Value -ne $psha) {
                Write-UpdLog -Level ERROR -Event 'baseline_changed' -Data @{ build = $Installed.Build; pinned = $pin.Value; now = $psha }
                return @{ Bundle = $null; Refused = $true; Reason = 'the Package Cache baseline changed since it was first accepted (same build, different SHA256)' }
            }
            [void](Add-VerifiedBundle -DataDir $DataDir -Name $pinName -SourcePath $pc -Sha256 $psha -BuildNumber $Installed.Build -AdditionalFullControlSids $Deps.AdditionalFullControlSids)
            if ($null -eq $pin) { $State.baseline_pins | Add-Member -NotePropertyName $pinName -NotePropertyValue $psha }
            Write-UpdLog -Event 'baseline_bundle_saved' -Data @{ build = $Installed.Build; sha256 = $psha; pinned_first_use = ($null -eq $pin) }
            return @{ Bundle = (Get-PreviousBundle -DataDir $DataDir -State $State -Installed $Installed); Refused = $false; Reason = $null }
        }
        Write-UpdLog -Level WARN -Event 'baseline_bundle_skipped' -Data @{ reason = 'package cache file or an ancestor is writable by non-admins, not owned by the system, or a reparse point'; detail = ($viol -join ' | ') }
    }
    return @{ Bundle = $null; Refused = $false; Reason = $null }
}

function Wait-MoonlightClosed {
    <# Bounded backoff (30, 60, 120, 240 s) for Moonlight.exe to close. Returns $true when idle. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Deps)
    foreach ($delay in 0, 30, 60, 120, 240) {
        if ($delay -gt 0) { Write-UpdLog -Event 'waiting_for_moonlight' -Data @{ seconds = $delay }; & $Deps.Sleep $delay }
        if (-not (& $Deps.IsMoonlightRunning)) { return $true }
    }
    return $false
}

function Invoke-InstallFailureHandling {
    <#
      A genuinely failed install (wrong version, bad exit code, lost registry items). Counts the failure (deny after
      2 consecutive failures of the same tag), waits (bounded) for Moonlight to be closed, rolls back to the baseline bundle
      and tells the human. Returns a result object.
    #>
    [CmdletBinding()]
    param($Deps, $Config, [string]$DataDir, $State, [string]$Tag, [string]$Why, [string]$RunDir, [string]$Computed, [string]$NewStored, $PrevBundle)
    $now = & $Deps.Now
    $rec = Set-AttemptRecord -State $State -Tag $Tag -Kind install -NowUtc $now
    $denied = ([int]$rec.failures -ge 2)
    if ($denied) { Add-LocalDeny -State $State -Tag $Tag -Reason $Why }
    Write-UpdLog -Level ERROR -Event 'health_failed' -Data @{ tag = $Tag; problems = $Why; failures = $rec.failures; denied = $denied }
    $keepBundle = $false
    $result = $null
    if ($null -eq $PrevBundle) {
        Write-UpdLog -Level ERROR -Event 'rollback_impossible' -Data @{ reason = 'no previous verified bundle' }
        & $Deps.Notify $Config $DataDir 'failed-no-rollback' $Tag $Why
        $result = New-UpdResult -Result 'failed' -Tag $Tag -Detail ("health check failed and no rollback bundle: $Why") -ExitCode $script:UpdExit.RollbackFailed
    } elseif (-not (Wait-MoonlightClosed -Deps $Deps)) {
        $State.rollback_pending = [pscustomobject]@{ tag = $Tag; previous = $PrevBundle.Name; failed_sha256 = $Computed; at = $now.ToString('o') }
        $keepBundle = $true
        Write-UpdLog -Level ERROR -Event 'rollback_postponed' -Data @{ reason = 'Moonlight.exe is running'; tag = $Tag }
        & $Deps.Notify $Config $DataDir 'ROLLBACK-POSTPONED' $Tag $Why
        $result = New-UpdResult -Result 'failed' -Tag $Tag -Detail ("health check failed; rollback postponed because Moonlight is running: $Why") -ExitCode $script:UpdExit.RollbackFailed
    } else {
        $idle = { -not (& $Deps.IsMoonlightRunning) }.GetNewClosure()
        $rb = & $Deps.Rollback $PrevBundle $NewStored $Computed $RunDir $idle
        $fvRb = ConvertFrom-FileVersion -Version (& $Deps.GetInstalledVersion)
        if ($rb.Ok) {
            Write-UpdLog -Event 'rolled_back' -Data @{ to = $PrevBundle.Name; method = $rb.Method; file_version_build = $(if ($fvRb) { $fvRb.Build } else { '' }) }
            & $Deps.Notify $Config $DataDir 'rolled_back' $Tag $Why
            $result = New-UpdResult -Result 'rolled_back' -Tag $Tag -Detail ("rolled back to $($PrevBundle.Name): $Why") -ExitCode $script:UpdExit.RolledBack
        } else {
            Write-UpdLog -Level ERROR -Event 'rollback_failed' -Data @{ to = $PrevBundle.Name; method = $rb.Method }
            & $Deps.Notify $Config $DataDir 'ROLLBACK-FAILED' $Tag $Why
            $result = New-UpdResult -Result 'failed' -Tag $Tag -Detail ("health check failed AND rollback failed ($($rb.Method)): $Why") -ExitCode $script:UpdExit.RollbackFailed
        }
    }
    if (-not $keepBundle -and $NewStored -and (Test-Path -LiteralPath (Split-Path -Parent $NewStored))) {
        # a failed bundle must neither be kept as a 'verified bundle' nor count against the keep-2 rule
        try { Remove-Item -LiteralPath (Split-Path -Parent $NewStored) -Recurse -Force -ErrorAction Stop } catch { Write-UpdLog -Level WARN -Event 'failed_bundle_cleanup' -Data @{ message = $_.Exception.Message } }
    }
    return $result
}

function Resolve-PendingWork {
    <#
      Work left over from an earlier run: reboot pending after an install (3010/1641), presence check that could not run
      (user hive unavailable), a rollback that had to wait for Moonlight. Returns a result to STOP this run, or $null to continue.
    #>
    [CmdletBinding()]
    param($Deps, $Config, [string]$DataDir, $State, [string]$Mode, $Installed)
    # -- presence check owed from an earlier run: read-only, never rolls anything back --
    if ($null -ne $State.verification_pending) {
        $vp = $State.verification_pending
        $nowP = & $Deps.GetPresence
        if ($nowP.HiveAvailable) {
            $lost = @(Compare-Presence -Before $vp.before -After $nowP)
            if ($lost.Count -gt 0) {
                Write-UpdLog -Level ERROR -Event 'presence_lost_late' -Data @{ tag = $vp.tag; lost = ($lost -join ',') }
                & $Deps.Notify $Config $DataDir 'PRESENCE-LOST' ([string]$vp.tag) ($lost -join ',')
            } else { Write-UpdLog -Event 'presence_verified_late' -Data @{ tag = $vp.tag } }
            $State.verification_pending = $null
        } else { Write-UpdLog -Level WARN -Event 'verification_still_pending' -Data @{ tag = $vp.tag; note = 'user hive not available' } }
    }
    # -- reboot pending after an install --
    if ($null -ne $State.pending_reboot) {
        $pr = $State.pending_reboot
        if ($null -ne $Installed -and $Installed.Build -eq [int]$pr.build) {
            $State.installed = [pscustomobject]@{ tag = [string]$pr.tag; u = [int]$pr.u; n = [int]$pr.n; build = [int]$pr.build; sha256 = [string]$pr.sha256; at = (& $Deps.Now).ToString('o') }
            $State.last_success_utc = (& $Deps.Now).ToString('o')
            Clear-AttemptRecord -State $State -Tag ([string]$pr.tag)
            Write-UpdLog -Event 'pending_reboot_resolved' -Data @{ tag = $pr.tag }
            $State.pending_reboot = $null
        } else {
            $boot = & $Deps.GetBootTime
            $at = [datetime]::Parse([string]$pr.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
            if ($boot -le $at) {
                Write-UpdLog -Event 'pending_reboot' -Data @{ tag = $pr.tag; note = 'no reboot since the install; waiting' }
                return (New-UpdResult -Result 'deferred' -Tag ([string]$pr.tag) -Detail 'reboot pending after install; waiting for the next boot')
            }
            # rebooted and still not the target version: a genuine failure
            $prev = $null
            if ($null -ne $Installed) { $prev = Get-PreviousBundle -DataDir $DataDir -State $State -Installed $Installed }
            $newStored = Join-Path (Join-Path (Join-Path $DataDir 'bundles') ([string]$pr.tag)) 'MoonlightSetup.exe'
            $State.pending_reboot = $null
            if ($Mode -eq 'install') {
                return (Invoke-InstallFailureHandling -Deps $Deps -Config $Config -DataDir $DataDir -State $State -Tag ([string]$pr.tag) -Why 'target version not present after reboot' -RunDir (Join-Path $DataDir 'updates') -Computed ([string]$pr.sha256) -NewStored $newStored -PrevBundle $prev)
            }
            Write-UpdLog -Level ERROR -Event 'pending_reboot_failed' -Data @{ tag = $pr.tag; mode = $Mode }
        }
    }
    # -- rollback that had to wait for Moonlight --
    if ($null -ne $State.rollback_pending -and $Mode -eq 'install') {
        $rp = $State.rollback_pending
        if (-not (& $Deps.IsMoonlightRunning)) {
            $bundles = @(Get-VerifiedBundles -DataDir $DataDir)
            $prev = $bundles | Where-Object { $_.Name -ceq [string]$rp.previous } | Select-Object -First 1
            $failed = $bundles | Where-Object { $_.Name -ceq [string]$rp.tag } | Select-Object -First 1
            if ($null -ne $prev -and $null -ne $failed) {
                $idle = { -not (& $Deps.IsMoonlightRunning) }.GetNewClosure()
                $rb = & $Deps.Rollback $prev $failed.Path $failed.Sha256 (Join-Path $DataDir 'updates') $idle
                if ($rb.Ok) {
                    $State.rollback_pending = $null
                    Write-UpdLog -Event 'rolled_back' -Data @{ to = $prev.Name; method = $rb.Method; late = $true }
                    & $Deps.Notify $Config $DataDir 'rolled_back' ([string]$rp.tag) 'late rollback'
                    return (New-UpdResult -Result 'rolled_back' -Tag ([string]$rp.tag) -Detail 'late rollback completed' -ExitCode $script:UpdExit.RolledBack)
                }
                Write-UpdLog -Level ERROR -Event 'rollback_failed' -Data @{ to = $prev.Name; method = $rb.Method; late = $true }
                return (New-UpdResult -Result 'failed' -Tag ([string]$rp.tag) -Detail 'late rollback failed' -ExitCode $script:UpdExit.RollbackFailed)
            }
            $State.rollback_pending = $null
        } else {
            return (New-UpdResult -Result 'deferred' -Tag ([string]$rp.tag) -Detail 'rollback pending, Moonlight is running')
        }
    }
    return $null
}

function Invoke-MoonlightUpdateCore {
    [CmdletBinding()]
    param($ProgramDir, $DataDir, $Config, $Deps, $State, $ModeOverride, [switch]$VerifyOnly)
    $mode = Get-EffectiveMode -ConfigMode $Config['mode'] -Override $ModeOverride
    $startedAt = & $Deps.Now
    Write-UpdLog -Event 'start' -Data @{ mode = $mode; channel = $Config['channel']; repo = $Config['repo']; verify_only = [bool]$VerifyOnly }
    if ($mode -eq 'hold') { return (New-UpdResult -Result 'held' -Detail 'local mode=hold') }

    # --- installed version -> key (needed by the pending-work resolver as well) ---
    $fvText = & $Deps.GetInstalledVersion
    $installed = Resolve-InstalledKey -FileVersion $fvText -State $State

    # --- leftovers of earlier runs ---
    $pend = Resolve-PendingWork -Deps $Deps -Config $Config -DataDir $DataDir -State $State -Mode $mode -Installed $installed
    if ($null -ne $pend) { return $pend }

    # --- idle check #1 (cheap, before any network) ---
    if ($mode -eq 'install' -and -not $VerifyOnly -and (& $Deps.IsMoonlightRunning)) {
        Write-UpdLog -Event 'deferred' -Data @{ reason = 'Moonlight.exe is running' }
        return (New-UpdResult -Result 'deferred' -Detail 'Moonlight.exe is running')
    }
    if ($null -eq $installed) {
        Write-UpdLog -Level WARN -Event 'noop' -Data @{ reason = 'Moonlight not installed or version not recognised'; file_version = $fvText }
        return (New-UpdResult -Result 'noop' -Detail 'moonlight not installed or version unrecognised')
    }
    Write-UpdLog -Event 'installed' -Data @{ file_version = $fvText; u = $installed.U; n = $installed.N; build = $installed.Build }

    # --- policy (fail closed) ---
    $pol = $null
    try { $pol = & $Deps.GetPolicy $Config $State $DataDir } catch {
        if ($_.Exception.Data.Contains('RateLimited')) { throw }
        Write-UpdLog -Level ERROR -Event 'policy_unavailable' -Data @{ message = $_.Exception.Message }
        return (New-UpdResult -Result 'failed' -Detail 'policy unavailable or invalid (fail closed)' -ExitCode $script:UpdExit.ConfigInvalid)
    }
    $policy = $pol.Policy
    Write-UpdLog -Event 'policy' -Data @{ commit = $pol.CommitSha; hold = $policy.Hold; deny_count = @($policy.Deny).Count }
    if ($policy.Hold) { return (New-UpdResult -Result 'held' -Detail 'policy hold=true') }
    if (@($policy.AllowOwners).Count -eq 0) {
        Write-UpdLog -Level ERROR -Event 'policy_invalid' -Data @{ reason = 'no upstream owner allow-list (allow_upstream_owners / upstream.owner_allowlist)' }
        return (New-UpdResult -Result 'failed' -Detail 'policy has no upstream owner allow-list (fail closed)' -ExitCode $script:UpdExit.ConfigInvalid)
    }
    if (-not $policy.HasDenyKey) { Write-UpdLog -Level WARN -Event 'policy_no_deny_key' -Data @{ note = 'policy.yml has no deny: key (treated as empty)' } }

    # --- release list ---
    $rel = & $Deps.GetReleases $Config $DataDir $State
    $cands = Select-NewestEligibleRelease -Releases @($rel.Releases) -Channel $Config['channel']
    Write-UpdLog -Event 'releases' -Data @{ total = @($rel.Releases).Count; eligible = @($cands).Count; from_cache = $rel.FromCache }
    $cool = Get-EffectiveCoolingOffHours -LocalHours ([double]$Config['cooling_off_hours']) -Policy $policy -Channel $Config['channel'] -MinHours ([double]$Config['min_cooling_off_hours'])
    $now = & $Deps.Now
    if ($rel.ContainsKey('ServerDate') -and $null -ne $rel.ServerDate) {
        $skew = ($now - $rel.ServerDate).TotalMinutes
        if ([math]::Abs($skew) -gt 5) {
            Write-UpdLog -Level WARN -Event 'clock_skew' -Data @{ skew_minutes = [math]::Round($skew, 1); note = 'using the GitHub server time for the cooling-off check' }
            $now = $rel.ServerDate
        }
    }

    $chosen = $null; $tooYoung = $null; $backoffTag = $null
    foreach ($c in $cands) {
        $tag = $c.Key.Tag
        if ($policy.Deny -ccontains $tag) { Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'denied by policy' }; continue }
        if (Test-LocallyDenied -State $State -Tag $tag) { Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'denied locally (repeated failures)' }; continue }
        if ((Compare-OrderingKey -A $c.Key -B $installed) -le 0) { Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'not newer than installed'; build = $c.Key.Build; installed_build = $installed.Build }; continue }
        $rr = $c.Release
        if (-not ($rr.PSObject.Properties.Name -contains 'published_at') -or [string]::IsNullOrEmpty([string]$rr.published_at)) { Write-UpdLog -Level WARN -Event 'skip' -Data @{ tag = $tag; reason = 'no published_at' }; continue }
        $age = Get-ReleaseAgeHours -PublishedAt ([string]$rr.published_at) -NowUtc $now
        if ($age -lt $cool) {
            Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'too young'; age_h = [math]::Round($age, 2); cooling_off_h = $cool }
            if ($null -eq $tooYoung) { $tooYoung = $tag }
            continue
        }
        if (Test-AttemptBackoff -State $State -Tag $tag -NowUtc $now) {
            $backoffTag = $tag
            Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'backoff after an earlier failed attempt' }
            break
        }
        $chosen = $c; break
    }
    if ($null -eq $chosen) {
        if ($backoffTag) { return (New-UpdResult -Result 'deferred' -Tag $backoffTag -Detail 'in backoff after an earlier failed attempt') }
        if ($tooYoung) { return (New-UpdResult -Result 'deferred' -Tag $tooYoung -Detail 'newest candidate is inside the cooling-off window') }
        return (New-UpdResult -Result 'noop' -Detail 'no newer eligible release')
    }
    $tag = $chosen.Key.Tag
    $release = $chosen.Release
    Write-UpdLog -Event 'candidate' -Data @{ tag = $tag; u = $chosen.Key.U; n = $chosen.Key.N; build = $chosen.Key.Build }
    if ($mode -eq 'report-only' -and -not $VerifyOnly) {
        Write-UpdLog -Event 'report_only' -Data @{ tag = $tag; note = 'would install; mode=report-only' }
        return (New-UpdResult -Result 'report-only' -Tag $tag -Detail 'would install')
    }

    # failure helper (nested: uses $State / $tag / $Deps of this call)
    function Stop-VerifyFailed {
        param([string]$Detail, [switch]$Transient)
        $nowF = & $Deps.Now
        if ($Transient) {
            [void](Set-AttemptRecord -State $State -Tag $tag -Kind transient -NowUtc $nowF)
            Write-UpdLog -Level WARN -Event 'transient_failure' -Data @{ tag = $tag; detail = $Detail }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail ("transient failure: $Detail") -ExitCode $script:UpdExit.NetworkDefer)
        }
        $rec = Set-AttemptRecord -State $State -Tag $tag -Kind verify -NowUtc $nowF
        if ([int]$rec.verify_failures -ge 3) { Add-LocalDeny -State $State -Tag $tag -Reason $Detail; Write-UpdLog -Level ERROR -Event 'denied_after_repeated_verify_failures' -Data @{ tag = $tag } }
        return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail $Detail -ExitCode $script:UpdExit.VerifyFailed)
    }

    # --- CONTRACT 4.3 (offline substitute): release must be immutable ---
    try { Assert-ReleaseImmutable -Release $release } catch { return (Stop-VerifyFailed -Detail $_.Exception.Message) }
    $assetMap = Get-ReleaseAssetMap -Release $release
    foreach ($need in 'manifest.json', 'SHA256SUMS') {
        if (-not $assetMap.ContainsKey($need)) { return (Stop-VerifyFailed -Detail "release lacks asset $need") }
    }

    # --- rollback baseline BEFORE any big download (P2-5) ---
    $prevBundle = $null
    if (-not $VerifyOnly) {
        $bl = Resolve-BaselineBundle -Deps $Deps -DataDir $DataDir -State $State -Installed $installed
        if ($bl.Refused) { return (New-UpdResult -Result 'failed' -Tag $tag -Detail ('refusing to install: ' + $bl.Reason) -ExitCode $script:UpdExit.ConfigInvalid) }
        $prevBundle = $bl.Bundle
        if ($null -eq $prevBundle) {
            Write-UpdLog -Level ERROR -Event 'no_rollback_baseline' -Data @{ tag = $tag; allow_no_baseline = $Config['allow_no_baseline'] }
            if ($Config['allow_no_baseline'] -ne $true) {
                return (New-UpdResult -Result 'failed' -Tag $tag -Detail 'no rollback baseline (no previous verified bundle, Package Cache bundle missing or not admin-only): refusing to install' -ExitCode $script:UpdExit.ConfigInvalid)
            }
        }
    }

    # --- CONTRACT 4.4: download into a per-run admin-only dir; small files first, installer only after the manifest is verified ---
    $runDir = New-UpdRunDirectory -DataDir $DataDir -AdditionalFullControlSids $Deps.AdditionalFullControlSids
    Write-UpdLog -Event 'run_dir' -Data @{ path = $runDir }
    $maxInstaller = [long]$Config['max_installer_mb'] * 1MB
    $handles = New-Object System.Collections.Generic.List[System.IDisposable]
    try {
        $manifestPath = $null; $sumsPath = $null
        try {
            $manifestPath = & $Deps.Download $Config $tag 'manifest.json' $runDir (256KB) $assetMap['manifest.json'].Size 120
            $sumsPath = & $Deps.Download $Config $tag 'SHA256SUMS' $runDir (64KB) $assetMap['SHA256SUMS'].Size 120
        } catch { return (Stop-VerifyFailed -Detail ('download failed: ' + $_.Exception.Message) -Transient) }
        $manifest = $null
        try { $manifest = Read-ReleaseManifest -Path $manifestPath -ExpectedTag $tag -AllowOwners @($policy.AllowOwners) -LocalOwners @($Config['upstream_owners']) }
        catch { return (Stop-VerifyFailed -Detail ('manifest: ' + $_.Exception.Message)) }
        if (-not $assetMap.ContainsKey($manifest.Installer)) { return (Stop-VerifyFailed -Detail 'installer asset not in release') }
        $apiInstSize = [long]$assetMap[$manifest.Installer].Size
        if ($apiInstSize -gt $maxInstaller) { return (Stop-VerifyFailed -Detail 'installer larger than max_installer_mb') }
        $expectedSize = -1
        if ($manifest.AssetSizes.ContainsKey($manifest.Installer)) {
            $expectedSize = [long]$manifest.AssetSizes[$manifest.Installer]
            if ($apiInstSize -gt 0 -and $apiInstSize -ne $expectedSize) { return (Stop-VerifyFailed -Detail 'installer size differs between manifest and release') }
        } elseif ($apiInstSize -gt 0) { $expectedSize = $apiInstSize }
        $bundlePaths = @()
        try {
            foreach ($b in $manifest.Bundles) {
                if (-not $assetMap.ContainsKey($b)) { return (Stop-VerifyFailed -Detail "bundle asset $b not in release") }
                $bundlePaths += (& $Deps.Download $Config $tag $b $runDir (4MB) $assetMap[$b].Size 120)
            }
        } catch { return (Stop-VerifyFailed -Detail ('download failed: ' + $_.Exception.Message) -Transient) }
        foreach ($p in @($manifestPath, $sumsPath)) { $handles.Add((Open-DenyWriteHandle -Path $p)) }

        # --- CONTRACT 4.5: attestation (offline bundles), manifest first so that source ref/sha are authenticated ---
        $gh = $Deps.GhPath
        try { & $Deps.AssertGh $gh $ProgramDir } catch { return (Stop-VerifyFailed -Detail ('gh.exe check: ' + $_.Exception.Message)) }
        $repo = $Config['repo']; $signer = $Config['signer_workflow']
        $script:UpdVerifyTimedOut = $false
        $verifyOne = {
            param([string]$file, [string]$digest)
            $ok = $false
            foreach ($bp in $bundlePaths) {
                $r = & $Deps.VerifyAttestation $gh $DataDir $file $bp $repo $signer $manifest.SourceRef $digest
                if ($r.Ok) { $ok = $true; break }
                if ($r.ContainsKey('TimedOut') -and $r.TimedOut) { $script:UpdVerifyTimedOut = $true }
                Write-UpdLog -Level WARN -Event 'attestation_attempt_failed' -Data @{ file = (Split-Path $file -Leaf); bundle = (Split-Path $bp -Leaf); rc = $r.Rc; stderr = $r.Err }
            }
            return $ok
        }
        if (-not (& $verifyOne $manifestPath $null)) { return (Stop-VerifyFailed -Detail 'attestation of manifest.json failed' -Transient:$script:UpdVerifyTimedOut) }
        if (-not (& $verifyOne $sumsPath $manifest.SourceSha)) { return (Stop-VerifyFailed -Detail 'attestation failed for SHA256SUMS' -Transient:$script:UpdVerifyTimedOut) }

        # --- only now the (up to 200 MB) installer ---
        $installerPath = $null
        try { $installerPath = & $Deps.Download $Config $tag $manifest.Installer $runDir $maxInstaller $expectedSize 600 }
        catch { return (Stop-VerifyFailed -Detail ('download failed: ' + $_.Exception.Message) -Transient) }
        $handles.Add((Open-DenyWriteHandle -Path $installerPath))      # handles: [0] manifest [1] SUMS [2] installer
        if (-not (& $verifyOne $installerPath $manifest.SourceSha)) { return (Stop-VerifyFailed -Detail 'attestation failed for the installer' -Transient:$script:UpdVerifyTimedOut) }
        Write-UpdLog -Event 'attestation_ok' -Data @{ tag = $tag; source_ref = $manifest.SourceRef; source_sha = $manifest.SourceSha }

        # --- optional online chain (gh release verify / verify-asset, needs a provisioned token) ---
        if ($Config['verify_mode'] -eq 'online') {
            foreach ($f in @($installerPath, $manifestPath, $sumsPath)) {
                $o = & $Deps.VerifyReleaseOnline $gh $DataDir $repo $tag $f
                if (-not $o.Ok) { return (Stop-VerifyFailed -Detail 'gh release verify-asset failed') }
            }
            Write-UpdLog -Event 'release_verify_ok' -Data @{ tag = $tag }
        }

        # --- CONTRACT 4.6: SHA256 file == SHA256SUMS == manifest (== API digest) ---
        $sums = $null; $computed = $null
        try {
            $sums = Read-Sha256Sums -Path $sumsPath
            $computed = Get-UpdSha256FromStream -Stream $handles[2]
            Assert-HashesAgree -ComputedSha256 $computed -InstallerName $manifest.Installer -Sums $sums -Manifest $manifest -ApiDigest $assetMap[$manifest.Installer].Digest
            if ($sums.ContainsKey('manifest.json')) {
                if ((Get-UpdSha256FromStream -Stream $handles[0]) -ne $sums['manifest.json']) { throw 'manifest.json hash does not match SHA256SUMS' }
            }
        } catch { return (Stop-VerifyFailed -Detail ('hash: ' + $_.Exception.Message)) }
        Write-UpdLog -Event 'hash_ok' -Data @{ tag = $tag; sha256 = $computed }
        Reset-VerifyCounters -State $State -Tag $tag      # a fully verified release resets transient/verify counters (not install failures)

        if ($VerifyOnly) { return (New-UpdResult -Result 'verified' -Tag $tag -Detail 'download + verification passed; nothing installed (verify-only)') }

        # --- installing: time budget, idle, presence ---
        $used = ((& $Deps.Now) - $startedAt).TotalMinutes
        if ($used -gt 75) {
            Write-UpdLog -Level WARN -Event 'deferred' -Data @{ reason = 'time budget used up before install'; used_min = [math]::Round($used, 1) }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail 'time budget used up before install; will retry')
        }
        if (& $Deps.IsMoonlightRunning) {
            Write-UpdLog -Event 'deferred' -Data @{ reason = 'Moonlight.exe is running (checked before install)'; tag = $tag }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail 'Moonlight.exe is running')
        }
        $before = & $Deps.GetPresence
        Write-UpdLog -Event 'presence_before' -Data @{ hive = $before.HiveAvailable; uniqueid = $before.UniqueId; hosts = $before.Hosts; certificate = $before.Certificate; key = $before.Key }
        if (-not $before.HiveAvailable) {
            # R-CLW-3 needs the interactive user's hive; never install unchecked. The AtLogOn trigger retries.
            Write-UpdLog -Level WARN -Event 'deferred' -Data @{ reason = 'presence_unavailable: no loaded interactive user hive; install postponed to the next run/logon'; tag = $tag }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail 'presence check unavailable (no interactive user hive); will retry at next run/logon')
        }
        $newStored = Add-VerifiedBundle -DataDir $DataDir -Name $tag -SourcePath $installerPath -Sha256 $computed -BuildNumber $manifest.BuildNumber -AdditionalFullControlSids $Deps.AdditionalFullControlSids

        # --- idle check immediately before the launch (P2-4) ---
        if (& $Deps.IsMoonlightRunning) {
            Write-UpdLog -Event 'deferred' -Data @{ reason = 'Moonlight.exe started just before launch'; tag = $tag }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail 'Moonlight.exe is running')
        }
        Write-UpdLog -Event 'install_start' -Data @{ tag = $tag }
        $inst = & $Deps.RunInstaller $installerPath $computed (Join-Path $runDir 'install.log') 'install'
        $rc = $inst.Rc
        Write-UpdLog -Event 'install_done' -Data @{ started = $inst.Started; hash_ok = $inst.HashOk; rc = $rc; timed_out = $inst.TimedOut }

        if (-not $inst.Started) {
            # the file changed between verification and launch (re-hash failed): nothing ran, so nothing to roll back
            return (Stop-VerifyFailed -Detail 'installer hash re-check failed immediately before launch')
        }
        if ($inst.TimedOut -and ((-not $inst.TreeGone) -or ($inst.ContainsKey('MsiIdle') -and -not $inst.MsiIdle))) {
            Write-UpdLog -Level ERROR -Event 'installer_not_stopped' -Data @{ tree_gone = $inst.TreeGone }
            & $Deps.Notify $Config $DataDir 'INSTALLER-NOT-STOPPED' $tag 'needs a human'
            return (New-UpdResult -Result 'failed' -Tag $tag -Detail 'installer timed out and its process tree / Windows Installer did not stop; no rollback attempted, needs a human' -ExitCode $script:UpdExit.RollbackFailed)
        }
        if ($rc -eq 1618) {
            [void](Set-AttemptRecord -State $State -Tag $tag -Kind transient -NowUtc (& $Deps.Now))
            Write-UpdLog -Level WARN -Event 'deferred' -Data @{ reason = 'another installation is in progress (1618)'; tag = $tag }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail 'another installation is in progress (1618); retry later')
        }

        # --- health check ---
        $fvAfter = ConvertFrom-FileVersion -Version (& $Deps.GetInstalledVersion)
        $versionOk = ($null -ne $fvAfter -and $fvAfter.Build -eq $manifest.BuildNumber)
        $after = & $Deps.GetPresence
        Write-UpdLog -Event 'presence_after' -Data @{ hive = $after.HiveAvailable; uniqueid = $after.UniqueId; hosts = $after.Hosts; certificate = $after.Certificate; key = $after.Key }
        if (($rc -eq 3010 -or $rc -eq 1641) -and -not $versionOk) {
            # reboot pending: not a failure; re-verified at the next run / logon
            $State.pending_reboot = [pscustomobject]@{ tag = $tag; u = $chosen.Key.U; n = $chosen.Key.N; build = $manifest.BuildNumber; sha256 = $computed; at = (& $Deps.Now).ToString('o') }
            Write-UpdLog -Level WARN -Event 'pending_reboot' -Data @{ tag = $tag; rc = $rc }
            return (New-UpdResult -Result 'pending_reboot' -Tag $tag -Detail "installer returned $rc; reboot pending, will be re-verified at the next run/logon")
        }
        $problems = New-Object System.Collections.Generic.List[string]
        if ($inst.TimedOut) { $problems.Add('installer timed out') }
        elseif ($rc -ne 0 -and $rc -ne 3010 -and $rc -ne 1641) { $problems.Add("installer exit code $rc") }
        if (-not $versionOk) { $problems.Add('FileVersion after install does not match target build') }
        if ($after.HiveAvailable) {
            foreach ($lost in (Compare-Presence -Before $before -After $after)) { $problems.Add("lost after install: $lost") }
        } else {
            $State.verification_pending = [pscustomobject]@{ tag = $tag; before = $before; at = (& $Deps.Now).ToString('o') }
            Write-UpdLog -Level WARN -Event 'verification_pending' -Data @{ tag = $tag; note = 'user hive not available after install; presence check will be repeated at the next run/logon' }
        }
        if ($problems.Count -eq 0) {
            $State.installed = [pscustomobject]@{ tag = $tag; u = $chosen.Key.U; n = $chosen.Key.N; build = $manifest.BuildNumber; sha256 = $computed; at = (& $Deps.Now).ToString('o') }
            $State.last_success_utc = (& $Deps.Now).ToString('o')
            Clear-AttemptRecord -State $State -Tag $tag
            Remove-ExcessBundles -DataDir $DataDir -Keep 2 -Protect @($tag)
            Write-UpdLog -Event 'health_ok' -Data @{ tag = $tag; reboot_pending = $inst.RebootPending }
            & $Deps.Notify $Config $DataDir 'updated' $tag ''
            return (New-UpdResult -Result 'updated' -Tag $tag -Detail ("installed; reboot pending: {0}" -f $inst.RebootPending))
        }
        return (Invoke-InstallFailureHandling -Deps $Deps -Config $Config -DataDir $DataDir -State $State -Tag $tag -Why ($problems -join '; ') -RunDir $runDir -Computed $computed -NewStored $newStored -PrevBundle $prevBundle)
    } finally {
        foreach ($h in $handles) { try { $h.Dispose() } catch { Write-Verbose 'handle dispose failed' } }
    }
}
