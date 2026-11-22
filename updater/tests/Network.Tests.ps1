# Network-tagged tests: anonymous calls to api.github.com / github.com / Sigstore TUF with a real public attested artifact
# (cli/cli release asset). Excluded by default; run with: tests\Invoke-Tests.ps1 -IncludeNetwork
# Evidence for research question U3 (unauthenticated verification) lives here and in U3-SystemProbe.ps1 (SYSTEM).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:Gh = 'C:\Program Files\GitHub CLI\gh.exe'
    $script:Version = 'v2.105.0'; $script:Asset = 'gh_2.105.0_windows_amd64.zip'
    $script:Work = New-TestRoot
    $script:Cfg = New-TestConfig -Override @{ repo = 'cli/cli'; api_base = 'https://api.github.com' }
    $script:Ready = $false
    try {
        $pin = Read-GhPin -ProgramDir $UpdRoot
        if ((Test-Path $script:Gh) -and ((Get-UpdSha256 -Path $script:Gh) -eq $pin.gh_exe_sha256)) {
            $script:File = Join-Path $script:Work $script:Asset
            $r = Invoke-UpdHttp -Uri "https://github.com/cli/cli/releases/download/$($script:Version)/$($script:Asset)" -OutFile $script:File -MaxBytes 40MB -TimeoutSec 300
            if ($r.Status -eq 200) {
                $script:Sha = Get-UpdSha256 -Path $script:File
                $a = Invoke-UpdApi -Config $script:Cfg -Path "/repos/cli/cli/attestations/sha256:$($script:Sha)"
                $lines = @()
                foreach ($att in $a.Json.attestations) {
                    # bundle_url points at an Azure blob host that the updater itself never contacts (the bundle is a release asset in the real feed)
                    $bytes = (New-Object System.Net.WebClient).DownloadData([string]$att.bundle_url)
                    $lines += ([Text.Encoding]::UTF8.GetString((ConvertFrom-SnappyBlock -Bytes $bytes)) | ConvertFrom-Json | ConvertTo-Json -Depth 50 -Compress)
                }
                $script:Bundle = Join-Path $script:Work 'bundle.jsonl'
                [IO.File]::WriteAllText($script:Bundle, ($lines -join "`n") + "`n")
                $script:Ready = ($lines.Count -ge 1)
            }
        }
    } catch { Write-Host "Network fixture setup failed: $($_.Exception.Message)" }
}
AfterAll { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Anonymous GitHub API shape assumptions' -Tag 'Network' {
    It 'release JSON carries immutable, published_at, assets[].digest (fields the updater relies on)' {
        $r = Invoke-UpdApi -Config $script:Cfg -Path "/repos/cli/cli/releases/tags/$($script:Version)"
        $r.Status | Should -Be 200
        $r.Json.immutable | Should -BeTrue
        [string]$r.Json.published_at | Should -Not -BeNullOrEmpty
        ($r.Json.assets | Where-Object name -eq $script:Asset).digest | Should -Match '^sha256:[0-9a-f]{64}$'
        $r.RateLimit.Remaining | Should -Not -BeNullOrEmpty
        Assert-ReleaseImmutable -Release $r.Json
    }
    It 'conditional request returns 304 with the ETag' {
        $a = Invoke-UpdApi -Config $script:Cfg -Path '/repos/cli/cli/releases?per_page=2'
        $b = Invoke-UpdApi -Config $script:Cfg -Path '/repos/cli/cli/releases?per_page=2' -Etag $a.Etag
        $b.Status | Should -Be 304
    }
}

Describe 'U3: unauthenticated verification with a scrubbed (SYSTEM-like) environment' -Tag 'Network' {
    BeforeEach { if (-not $script:Ready) { Set-ItResult -Skipped -Because 'network, pinned gh.exe or fixture unavailable' } }

    It 'online gh attestation verify / gh release verify need a token (rc != 0) => contract step 3 cannot run as written' {
        if (-not $script:Ready) { return }
        $o = Invoke-GhVerify -GhPath $script:Gh -Arguments @('attestation', 'verify', $script:File, '-R', 'cli/cli') -DataDir $script:Work -Token $null
        $o.Ok | Should -BeFalse
        $o.Err | Should -Match 'gh auth login|GH_TOKEN'
        (Invoke-GhVerify -GhPath $script:Gh -Arguments @('release', 'verify', $script:Version, '-R', 'cli/cli') -DataDir $script:Work -Token $null).Ok | Should -BeFalse
    }
    It 'offline --bundle verification with pinned flags works with no token' {
        if (-not $script:Ready) { return }
        $a = @('attestation', 'verify', $script:File, '--repo', 'cli/cli', '--bundle', $script:Bundle, '--signer-workflow', 'github.com/cli/cli/.github/workflows/deployment.yml', '--source-ref', 'refs/heads/trunk', '--deny-self-hosted-runners', '--format', 'json')
        $o = Invoke-GhVerify -GhPath $script:Gh -Arguments $a -DataDir $script:Work -Token $null
        $o.Ok | Should -BeTrue -Because $o.Err
    }
    It 'fails closed: tampered file, wrong repo, wrong signer, wrong ref' {
        if (-not $script:Ready) { return }
        $bad = Join-Path $script:Work 'tampered.zip'; Copy-Item $script:File $bad
        $fs = [IO.File]::Open($bad, 'Open', 'ReadWrite'); $fs.Position = 100; $fs.WriteByte(0xFF); $fs.Dispose()
        $base = @('--bundle', $script:Bundle)
        (Invoke-GhVerify -GhPath $script:Gh -Arguments (@('attestation', 'verify', $bad, '--repo', 'cli/cli') + $base) -DataDir $script:Work -Token $null).Ok | Should -BeFalse
        (Invoke-GhVerify -GhPath $script:Gh -Arguments (@('attestation', 'verify', $script:File, '--repo', 'cli/go-gh') + $base) -DataDir $script:Work -Token $null).Ok | Should -BeFalse
        (Invoke-GhVerify -GhPath $script:Gh -Arguments (@('attestation', 'verify', $script:File, '--repo', 'cli/cli', '--signer-workflow', 'github.com/cli/cli/.github/workflows/evil.yml') + $base) -DataDir $script:Work -Token $null).Ok | Should -BeFalse
        (Invoke-GhVerify -GhPath $script:Gh -Arguments (@('attestation', 'verify', $script:File, '--repo', 'cli/cli', '--source-ref', 'refs/heads/automation') + $base) -DataDir $script:Work -Token $null).Ok | Should -BeFalse
    }
    It 'Test-ArtifactAttestation refuses a source ref outside automation|build/* even when gh would accept it' {
        if (-not $script:Ready) { return }
        { Test-ArtifactAttestation -GhPath $script:Gh -DataDir $script:Work -FilePath $script:File -BundlePath $script:Bundle -Repo 'cli/cli' -SignerWorkflow 'github.com/cli/cli/.github/workflows/deployment.yml' -SourceRef 'refs/heads/trunk' -SourceDigest $null } | Should -Throw '*not allowed*'
    }
}
