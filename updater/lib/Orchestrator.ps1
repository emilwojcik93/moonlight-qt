# Update flow (CONTRACT 4). All side effects go through $Deps (injectable) so every branch is testable
# without network, registry, or installers. Fail closed everywhere: any doubt => nothing installed.

Set-StrictMode -Version Latest

function New-UpdDeps {
    <# Production implementations. Tests build their own hashtable with the same keys. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ProgramDir)
    $ghPath = Join-Path (Join-Path $ProgramDir 'bin') 'gh.exe'
    if ($Config.ContainsKey('gh_path')) { $ghPath = [string]$Config['gh_path'] }   # test mode only (validated in Read-UpdConfig)
    $d = @{}
    $d.GhPath = $ghPath
    $d.GetReleases = { param($cfg, $dataDir, $state) Get-UpdReleases -Config $cfg -DataDir $dataDir -State $state }
    $d.GetPolicy = { param($cfg, $state, $dataDir) Get-UpdPolicy -Config $cfg -State $state -DataDir $dataDir }
    $d.GetInstalledVersion = { Get-InstalledMoonlightVersion }
    $d.IsMoonlightRunning = { Test-MoonlightRunning }
    $d.GetPresence = { Get-MoonlightPresenceForUser }
    $d.Download = { param($cfg, $tag, $name, $runDir, $maxBytes) Save-ReleaseAsset -Config $cfg -Tag $tag -Name $name -RunDir $runDir -MaxBytes $maxBytes }
    $d.AssertGh = { param($gh, $progDir, $skipSig) Assert-GhBinary -GhPath $gh -Pin (Read-GhPin -ProgramDir $progDir) -SkipSignature:([bool]$skipSig) }
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
    $d.Rollback = { param($prev, $failedPath, $failedSha, $runDir) Invoke-MoonlightRollback -Previous $prev -FailedBundlePath $failedPath -FailedSha256 $failedSha -RunDir $runDir }
    $d.Notify = { param($cfg, $dataDir, $result, $tag, $detail) [void](Send-UpdNotification -Config $cfg -DataDir $dataDir -Result $result -Tag $tag -Detail $detail) }
    $d.Now = { Get-UpdNowUtc }
    $d.TestPathAcl = { param($p) Test-UpdAclSafe -Path $p }
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
    }
    if ($res.Result -eq 'verify_failed' -or $res.ExitCode -eq $script:UpdExit.ConfigInvalid) {
        try { & $Deps.Notify $Config $DataDir $res.Result $res.Tag $res.Detail } catch { Write-Verbose 'notify failed' }
    }
    Write-UpdLog -Event 'result' -Data @{ result = $res.Result; tag = $res.Tag; detail = $res.Detail; exit = $res.ExitCode }
    return $res
}

function Invoke-MoonlightUpdateCore {
    [CmdletBinding()]
    param($ProgramDir, $DataDir, $Config, $Deps, $State, $ModeOverride, [switch]$VerifyOnly)
    $mode = Get-EffectiveMode -ConfigMode $Config['mode'] -Override $ModeOverride
    Write-UpdLog -Event 'start' -Data @{ mode = $mode; channel = $Config['channel']; repo = $Config['repo']; verify_only = [bool]$VerifyOnly }
    if ($mode -eq 'hold') { return (New-UpdResult -Result 'held' -Detail 'local mode=hold') }

    # --- idle check #1 (cheap, before any network) ---
    if ($mode -eq 'install' -and -not $VerifyOnly -and (& $Deps.IsMoonlightRunning)) {
        Write-UpdLog -Event 'deferred' -Data @{ reason = 'Moonlight.exe is running' }
        return (New-UpdResult -Result 'deferred' -Detail 'Moonlight.exe is running')
    }

    # --- installed version -> key ---
    $fvText = & $Deps.GetInstalledVersion
    $installed = Resolve-InstalledKey -FileVersion $fvText -State $State
    if ($null -eq $installed) {
        Write-UpdLog -Level WARN -Event 'noop' -Data @{ reason = 'Moonlight not installed or version not recognised'; file_version = $fvText }
        return (New-UpdResult -Result 'noop' -Detail 'moonlight not installed or version unrecognised')
    }
    Write-UpdLog -Event 'installed' -Data @{ file_version = $fvText; u = $installed.U; n = $installed.N }

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
    $cool = Get-EffectiveCoolingOffHours -LocalHours ([double]$Config['cooling_off_hours']) -Policy $policy -Channel $Config['channel']
    $now = & $Deps.Now

    $chosen = $null; $tooYoung = $null
    foreach ($c in $cands) {
        $tag = $c.Key.Tag
        if ($policy.Deny -ccontains $tag) { Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'denied by policy' }; continue }
        if (Test-LocallyDenied -State $State -Tag $tag) { Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'denied locally (earlier failed install)' }; continue }
        if ((Compare-OrderingKey -A $c.Key -B $installed) -le 0) { Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'not newer than installed' }; continue }
        $bn = ConvertTo-BuildNumber -U $c.Key.U
        if ($bn -le $installed.Build) { Write-UpdLog -Level WARN -Event 'skip' -Data @{ tag = $tag; reason = 'same or lower MSI build number (a rebuild N of the same U cannot be installed by MSI major-upgrade)'; build = $bn; installed_build = $installed.Build }; continue }
        $rr = $c.Release
        if (-not ($rr.PSObject.Properties.Name -contains 'published_at') -or [string]::IsNullOrEmpty([string]$rr.published_at)) { Write-UpdLog -Level WARN -Event 'skip' -Data @{ tag = $tag; reason = 'no published_at' }; continue }
        $age = Get-ReleaseAgeHours -PublishedAt ([string]$rr.published_at) -NowUtc $now
        if ($age -lt $cool) {
            Write-UpdLog -Event 'skip' -Data @{ tag = $tag; reason = 'too young'; age_h = [math]::Round($age, 2); cooling_off_h = $cool }
            if ($null -eq $tooYoung) { $tooYoung = $tag }
            continue
        }
        $chosen = $c; break
    }
    if ($null -eq $chosen) {
        if ($tooYoung) { return (New-UpdResult -Result 'deferred' -Tag $tooYoung -Detail 'newest candidate is inside the cooling-off window') }
        return (New-UpdResult -Result 'noop' -Detail 'no newer eligible release')
    }
    $tag = $chosen.Key.Tag
    $release = $chosen.Release
    Write-UpdLog -Event 'candidate' -Data @{ tag = $tag; u = $chosen.Key.U; n = $chosen.Key.N }
    if ($mode -eq 'report-only' -and -not $VerifyOnly) {
        Write-UpdLog -Event 'report_only' -Data @{ tag = $tag; note = 'would install; mode=report-only' }
        return (New-UpdResult -Result 'report-only' -Tag $tag -Detail 'would install')
    }

    # --- CONTRACT 4.3 (offline substitute): release must be immutable ---
    try { Assert-ReleaseImmutable -Release $release } catch {
        return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail $_.Exception.Message -ExitCode $script:UpdExit.VerifyFailed)
    }
    $assetMap = Get-ReleaseAssetMap -Release $release
    foreach ($need in 'manifest.json', 'SHA256SUMS') {
        if (-not $assetMap.ContainsKey($need)) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail "release lacks asset $need" -ExitCode $script:UpdExit.VerifyFailed) }
    }

    # --- CONTRACT 4.4: download into a per-run admin-only dir ---
    $runDir = New-UpdRunDirectory -DataDir $DataDir -AdditionalFullControlSids $Deps.AdditionalFullControlSids
    Write-UpdLog -Event 'run_dir' -Data @{ path = $runDir }
    $maxInstaller = [long]$Config['max_installer_mb'] * 1MB
    $handles = New-Object System.Collections.Generic.List[System.IDisposable]
    try {
        $manifestPath = & $Deps.Download $Config $tag 'manifest.json' $runDir (256KB)
        $sumsPath = & $Deps.Download $Config $tag 'SHA256SUMS' $runDir (64KB)
        $manifest = $null
        try { $manifest = Read-ReleaseManifest -Path $manifestPath -ExpectedTag $tag -AllowOwners @($policy.AllowOwners) }
        catch { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail ('manifest: ' + $_.Exception.Message) -ExitCode $script:UpdExit.VerifyFailed) }
        if (-not $assetMap.ContainsKey($manifest.Installer)) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail 'installer asset not in release' -ExitCode $script:UpdExit.VerifyFailed) }
        if ($assetMap[$manifest.Installer].Size -gt $maxInstaller) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail 'installer larger than max_installer_mb' -ExitCode $script:UpdExit.VerifyFailed) }
        $bundlePaths = @()
        foreach ($b in $manifest.Bundles) {
            if (-not $assetMap.ContainsKey($b)) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail "bundle asset $b not in release" -ExitCode $script:UpdExit.VerifyFailed) }
            $bundlePaths += (& $Deps.Download $Config $tag $b $runDir (4MB))
        }
        $installerPath = & $Deps.Download $Config $tag $manifest.Installer $runDir $maxInstaller

        # Hold deny-write handles on everything we verify (TOCTOU defence) until the end of the run.
        foreach ($p in @($manifestPath, $sumsPath, $installerPath)) { $handles.Add((Open-DenyWriteHandle -Path $p)) }

        # --- CONTRACT 4.5: attestation (offline bundles), manifest first so that source ref/sha are authenticated ---
        $gh = $Deps.GhPath
        try { & $Deps.AssertGh $gh $ProgramDir ($Config.ContainsKey('gh_path')) } catch {
            return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail ('gh.exe check: ' + $_.Exception.Message) -ExitCode $script:UpdExit.VerifyFailed)
        }
        $repo = $Config['repo']; $signer = $Config['signer_workflow']
        $verifyOne = {
            param([string]$file, [string]$digest)
            $ok = $false
            foreach ($bp in $bundlePaths) {
                $r = & $Deps.VerifyAttestation $gh $DataDir $file $bp $repo $signer $manifest.SourceRef $digest
                if ($r.Ok) { $ok = $true; break }
                Write-UpdLog -Level WARN -Event 'attestation_attempt_failed' -Data @{ file = (Split-Path $file -Leaf); bundle = (Split-Path $bp -Leaf); rc = $r.Rc; stderr = $r.Err }
            }
            return $ok
        }
        if (-not (& $verifyOne $manifestPath $null)) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail 'attestation of manifest.json failed' -ExitCode $script:UpdExit.VerifyFailed) }
        foreach ($f in @($sumsPath, $installerPath)) {
            if (-not (& $verifyOne $f $manifest.SourceSha)) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail ('attestation failed for ' + (Split-Path $f -Leaf)) -ExitCode $script:UpdExit.VerifyFailed) }
        }
        Write-UpdLog -Event 'attestation_ok' -Data @{ tag = $tag; source_ref = $manifest.SourceRef; source_sha = $manifest.SourceSha }

        # --- optional online chain (gh release verify / verify-asset, needs a provisioned token) ---
        if ($Config['verify_mode'] -eq 'online') {
            foreach ($f in @($installerPath, $manifestPath, $sumsPath)) {
                $o = & $Deps.VerifyReleaseOnline $gh $DataDir $repo $tag $f
                if (-not $o.Ok) { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail 'gh release verify-asset failed' -ExitCode $script:UpdExit.VerifyFailed) }
            }
            Write-UpdLog -Event 'release_verify_ok' -Data @{ tag = $tag }
        }

        # --- CONTRACT 4.6: SHA256 file == SHA256SUMS == manifest (== API digest) ---
        $sums = $null
        try {
            $sums = Read-Sha256Sums -Path $sumsPath
            $stream = $handles[2]
            $computed = Get-UpdSha256FromStream -Stream $stream
            Assert-HashesAgree -ComputedSha256 $computed -InstallerName $manifest.Installer -Sums $sums -Manifest $manifest -ApiDigest $assetMap[$manifest.Installer].Digest
            if ($sums.ContainsKey('manifest.json')) {
                if ((Get-UpdSha256FromStream -Stream $handles[0]) -ne $sums['manifest.json']) { throw 'manifest.json hash does not match SHA256SUMS' }
            }
        } catch { return (New-UpdResult -Result 'verify_failed' -Tag $tag -Detail ('hash: ' + $_.Exception.Message) -ExitCode $script:UpdExit.VerifyFailed) }
        Write-UpdLog -Event 'hash_ok' -Data @{ tag = $tag; sha256 = $computed }

        if ($VerifyOnly) { return (New-UpdResult -Result 'verified' -Tag $tag -Detail 'download + verification passed; nothing installed (verify-only)') }

        # --- CONTRACT 4.7: idle check #2, then install from the SAME verified file ---
        if (& $Deps.IsMoonlightRunning) {
            Write-UpdLog -Event 'deferred' -Data @{ reason = 'Moonlight.exe is running (checked before install)'; tag = $tag }
            return (New-UpdResult -Result 'deferred' -Tag $tag -Detail 'Moonlight.exe is running')
        }
        # keep verified bundles (new one + a rollback baseline of whatever is installed now)
        $sid = $Deps.AdditionalFullControlSids
        $prevBundle = Get-PreviousBundle -DataDir $DataDir -State $State -Installed $installed
        if ($null -eq $prevBundle) {
            $pc = & $Deps.PackageCacheBundle
            if ($pc -and (Test-Path -LiteralPath $pc -PathType Leaf)) {
                $viol = & $Deps.TestPathAcl $pc
                if (@($viol).Count -eq 0) {
                    $psha = Get-UpdSha256 -Path $pc
                    [void](Add-VerifiedBundle -DataDir $DataDir -Name ('installed-{0}' -f $installed.Build) -SourcePath $pc -Sha256 $psha -BuildNumber $installed.Build -AdditionalFullControlSids $sid)
                    $prevBundle = Get-PreviousBundle -DataDir $DataDir -State $State -Installed $installed
                    Write-UpdLog -Event 'baseline_bundle_saved' -Data @{ build = $installed.Build }
                } else { Write-UpdLog -Level WARN -Event 'baseline_bundle_skipped' -Data @{ reason = 'package cache ACL not admin-only' } }
            } else { Write-UpdLog -Level WARN -Event 'no_rollback_baseline' -Data @{ note = 'previous installer unavailable; rollback will not be possible' } }
        }
        $newStored = Add-VerifiedBundle -DataDir $DataDir -Name $tag -SourcePath $installerPath -Sha256 $computed -BuildNumber $manifest.BuildNumber -AdditionalFullControlSids $sid

        $before = & $Deps.GetPresence
        Write-UpdLog -Event 'presence_before' -Data @{ hive = $before.HiveAvailable; uniqueid = $before.UniqueId; hosts = $before.Hosts; certificate = $before.Certificate; key = $before.Key }
        Write-UpdLog -Event 'install_start' -Data @{ tag = $tag }
        $inst = & $Deps.RunInstaller $installerPath $computed (Join-Path $runDir 'install.log') 'install'
        Write-UpdLog -Event 'install_done' -Data @{ started = $inst.Started; hash_ok = $inst.HashOk; rc = $inst.Rc; timed_out = $inst.TimedOut }

        # --- health check ---
        $problems = New-Object System.Collections.Generic.List[string]
        if (-not $inst.Started) { $problems.Add('installer not started (hash re-check failed)') }
        elseif ($inst.TimedOut) { $problems.Add('installer timed out') }
        elseif ($inst.Rc -ne 0 -and $inst.Rc -ne 3010) { $problems.Add("installer exit code $($inst.Rc)") }
        $fvAfter = ConvertFrom-FileVersion -Version (& $Deps.GetInstalledVersion)
        if ($null -eq $fvAfter -or $fvAfter.Build -ne $manifest.BuildNumber) { $problems.Add('FileVersion after install does not match target build') }
        $after = & $Deps.GetPresence
        Write-UpdLog -Event 'presence_after' -Data @{ hive = $after.HiveAvailable; uniqueid = $after.UniqueId; hosts = $after.Hosts; certificate = $after.Certificate; key = $after.Key }
        foreach ($lost in (Compare-Presence -Before $before -After $after)) { $problems.Add("lost after install: $lost") }
        if ($problems.Count -eq 0) {
            $State.installed = [pscustomobject]@{ tag = $tag; u = $chosen.Key.U; n = $chosen.Key.N; build = $manifest.BuildNumber; sha256 = $computed; at = (& $Deps.Now).ToString('o') }
            $State.last_success_utc = (& $Deps.Now).ToString('o')
            Remove-ExcessBundles -DataDir $DataDir -Keep 2 -Protect @($tag)
            Remove-OldRunDirectories -DataDir $DataDir -Except $runDir
            Write-UpdLog -Event 'health_ok' -Data @{ tag = $tag; reboot_pending = $inst.RebootPending }
            & $Deps.Notify $Config $DataDir 'updated' $tag ''
            return (New-UpdResult -Result 'updated' -Tag $tag -Detail ("installed; reboot pending: {0}" -f $inst.RebootPending))
        }

        # --- failure: deny + rollback ---
        $why = ($problems -join '; ')
        Write-UpdLog -Level ERROR -Event 'health_failed' -Data @{ tag = $tag; problems = $why }
        Add-LocalDeny -State $State -Tag $tag -Reason $why
        if ($null -eq $prevBundle) {
            Write-UpdLog -Level ERROR -Event 'rollback_impossible' -Data @{ reason = 'no previous verified bundle' }
            try { Remove-Item -LiteralPath (Split-Path -Parent $newStored) -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'failed bundle cleanup failed' }
            & $Deps.Notify $Config $DataDir 'failed-no-rollback' $tag $why
            return (New-UpdResult -Result 'failed' -Tag $tag -Detail ("health check failed and no rollback bundle: $why") -ExitCode $script:UpdExit.RollbackFailed)
        }
        $rb = & $Deps.Rollback $prevBundle $newStored $computed $runDir
        # the failed bundle is denied and must neither be kept as a 'verified bundle' nor count against the keep-2 rule
        try { Remove-Item -LiteralPath (Split-Path -Parent $newStored) -Recurse -Force -ErrorAction Stop } catch { Write-UpdLog -Level WARN -Event 'failed_bundle_cleanup' -Data @{ message = $_.Exception.Message } }
        $fvRb = ConvertFrom-FileVersion -Version (& $Deps.GetInstalledVersion)
        if ($rb.Ok) {
            Write-UpdLog -Event 'rolled_back' -Data @{ to = $prevBundle.Name; method = $rb.Method; file_version_build = $(if ($fvRb) { $fvRb.Build } else { '' }) }
            & $Deps.Notify $Config $DataDir 'rolled_back' $tag $why
            return (New-UpdResult -Result 'rolled_back' -Tag $tag -Detail ("rolled back to $($prevBundle.Name): $why") -ExitCode $script:UpdExit.RolledBack)
        }
        Write-UpdLog -Level ERROR -Event 'rollback_failed' -Data @{ to = $prevBundle.Name }
        & $Deps.Notify $Config $DataDir 'ROLLBACK-FAILED' $tag $why
        return (New-UpdResult -Result 'failed' -Tag $tag -Detail ("health check failed AND rollback failed: $why") -ExitCode $script:UpdExit.RollbackFailed)
    } finally {
        foreach ($h in $handles) { try { $h.Dispose() } catch { Write-Verbose 'handle dispose failed' } }
    }
}

function Get-PreviousBundle {
    <# Bundle matching what is installed now (state.installed.tag, else 'installed-<build>'). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Installed)
    $b = @(Get-VerifiedBundles -DataDir $DataDir)
    $want = @()
    if ($null -ne $State.installed -and ($State.installed.PSObject.Properties.Name -contains 'tag') -and [int]$State.installed.u -eq $Installed.U) { $want += [string]$State.installed.tag }
    $want += ('installed-{0}' -f $Installed.Build)
    foreach ($w in $want) { foreach ($x in $b) { if ($x.Name -ceq $w) { return $x } } }
    return $null
}
