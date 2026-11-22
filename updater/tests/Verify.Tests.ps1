BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }

    function Write-FixtureFiles($fx, $dir) {
        foreach ($n in $fx.Files.Keys) { [IO.File]::WriteAllBytes((Join-Path $dir $n), [byte[]]$fx.Files[$n]) }
    }
}

Describe 'Command line quoting (no shell, no injection)' {
    It 'quotes <Arg>' -ForEach @(
        @{ Arg = 'plain'; Expect = 'plain' },
        @{ Arg = 'with space'; Expect = '"with space"' },
        @{ Arg = 'say "hi"'; Expect = '"say \"hi\""' },
        @{ Arg = 'C:\Program Files\x\'; Expect = '"C:\Program Files\x\\"' },
        @{ Arg = ''; Expect = '""' }
    ) { ConvertTo-WinArg -Arg $Arg | Should -Be $Expect }

    It 'metacharacters stay one literal argument (echoed back verbatim by a child process)' {
        $evil = 'a" & calc.exe & "b ; $(calc) | `calc`'
        $sc = Join-Path ([IO.Path]::GetTempPath()) ('echo-args-' + [guid]::NewGuid().ToString('N') + '.ps1')
        '$args.Count; $args[0]' | Set-Content -LiteralPath $sc
        try { $r = Invoke-UpdProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $sc, $evil) -TimeoutSec 30 } finally { Remove-Item -LiteralPath $sc -Force }
        $r.Rc | Should -Be 0
        $lines = @($r.Out -split "`r?`n" | Where-Object { $_ -ne '' })
        $lines[0] | Should -Be '1'
        $lines[1] | Should -Be $evil
    }
    It 'scrubs GH_/GITHUB_ environment variables for children and sets a private config dir' {
        $env:GH_TOKEN = 'ghp_SHOULDNOTLEAK0123456789012345'; $env:GITHUB_TOKEN = 'x'; $env:GH_HOST = 'evil.example'
        try {
            $set = Get-GhEnvironment -DataDir 'C:\data' -Token $null
            $r = Invoke-UpdProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Get-ChildItem Env: | ForEach-Object { $_.Name + "=" + $_.Value }') -EnvRemovePrefix @('GH_', 'GITHUB_') -EnvSet $set
            $r.Out | Should -Not -Match 'SHOULDNOTLEAK'
            $r.Out | Should -Not -Match 'GITHUB_TOKEN'
            $r.Out | Should -Not -Match 'evil\.example'
            $r.Out | Should -Match 'GH_CONFIG_DIR=C:\\data\\gh-config'
            $r.Out | Should -Match 'GH_PROMPT_DISABLED=1'
            $r.Out | Should -Not -Match 'GH_TOKEN='
        } finally { Remove-Item Env:\GH_TOKEN, Env:\GITHUB_TOKEN, Env:\GH_HOST -ErrorAction SilentlyContinue }
    }
    It 'enforces the timeout and kills the child' {
        $r = Invoke-UpdProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 30') -TimeoutSec 2
        $r.TimedOut | Should -BeTrue
        $r.Rc | Should -Be -1
    }
}

Describe 'Snappy raw block decoder' {
    It 'decodes literal + copy elements' {
        # "abcabcabcabc": literal "abc" then copy len 9 offset 3 (copy2 tag: ((9-1)<<2)|2 = 0x22)
        $block = [byte[]](12, 0x08, 0x61, 0x62, 0x63, 0x22, 0x03, 0x00)
        [Text.Encoding]::ASCII.GetString((ConvertFrom-SnappyBlock -Bytes $block)) | Should -Be 'abcabcabcabc'
    }
    It 'decodes copy1 (tag 01) with overlapping runs' {
        # "aaaaaaaaaa" (10): literal "a" then copy1 len 9? copy1 len = 4+((tag>>2)&7) max 11; len 9 => (5<<2)|1 = 0x15, offset 1
        $block = [byte[]](10, 0x00, 0x61, 0x15, 0x01)
        [Text.Encoding]::ASCII.GetString((ConvertFrom-SnappyBlock -Bytes $block)) | Should -Be 'aaaaaaaaaa'
    }
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'truncated literal'; Bytes = [byte[]](5, 0x10, 0x61) },
        @{ Name = 'copy before start'; Bytes = [byte[]](4, 0x0D, 0x05) },
        @{ Name = 'length mismatch'; Bytes = [byte[]](9, 0x00, 0x61) },
        @{ Name = 'empty'; Bytes = [byte[]]@() }
    ) { { ConvertFrom-SnappyBlock -Bytes $Bytes } | Should -Throw }
    It 'enforces the output cap (decompression bomb guard)' {
        { ConvertFrom-SnappyBlock -Bytes ([byte[]](0x80, 0x80, 0x80, 0x08, 0x00, 0x61)) -MaxOutputBytes 1024 } | Should -Throw '*exceeds cap*'
    }
}

Describe 'Manifest validation' {
    BeforeEach { $script:dir = New-TestRoot }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'accepts a good manifest' {
        $fx = New-FixtureRelease -U 202 -N 1
        Write-FixtureFiles $fx $script:dir
        $m = Read-ReleaseManifest -Path (Join-Path $script:dir 'manifest.json') -ExpectedTag $fx.Tag -AllowOwners @('Nonary')
        $m.Installer | Should -Be 'MoonlightSetup.exe'
        $m.BuildNumber | Should -Be 61616
        $m.SourceRef | Should -Be 'refs/heads/build/v6.2.0-daily.202-n1'      # derived from the tag (CONTRACT 3b)
        $m.AssetSizes['MoonlightSetup.exe'] | Should -Be 4096
        $m.Bundles | Should -Contain 'attestation.sigstore.json'
    }
    It 'rejects: <Name>' -ForEach @(
        @{ Name = 'tag mismatch'; Mutate = { param($m) $m.tag = 'v6.2.0-daily.203-vp.1' } },
        @{ Name = 'wrong product'; Mutate = { param($m) $m.product = 'vibepollo' } },
        @{ Name = 'schema 2'; Mutate = { param($m) $m.schema = 2 } },
        @{ Name = 'path traversal installer'; Mutate = { param($m) $m.installer = '..\evil.exe' } },
        @{ Name = 'installer with shell chars'; Mutate = { param($m) $m.installer = 'MoonlightSetup.exe; calc' } },
        @{ Name = 'not-allowed owner'; Mutate = { param($m) $m.upstream.owner = 'Mallory' } },
        @{ Name = 'owner with shell chars'; Mutate = { param($m) $m.upstream.owner = 'Nonary$(x)' } },
        @{ Name = 'bad build version'; Mutate = { param($m) $m.build.version = '6.2.0-daily.6020' } },
        @{ Name = 'build number != scheme(U)'; Mutate = { param($m) $m.build.version = '6.2.0-daily.60203' } },
        @{ Name = 'bad source_ref'; Mutate = { param($m) $m.build.source_ref = 'refs/heads/main' } },
        @{ Name = 'source_ref traversal'; Mutate = { param($m) $m.build.source_ref = 'refs/heads/build/../x' } },
        @{ Name = 'short source_sha'; Mutate = { param($m) $m.build.source_sha = 'abc' } },
        @{ Name = 'bad bundle name'; Mutate = { param($m) $m.attestation = @('../x.json') } },
        @{ Name = 'no bundle'; Mutate = { param($m) $m.attestation = @() } },
        @{ Name = 'installer not listed in assets'; Mutate = { param($m) $m.assets = @(@{ name = 'other.exe'; sha256 = ('a' * 64); size = 1 }) } },
        @{ Name = 'bad asset hash'; Mutate = { param($m) $m.assets[0].sha256 = 'XYZ' } },
        @{ Name = 'legacy build scheme 60000+U'; Mutate = { param($m) $m.build.version = '6.2.0-daily.60202' } },
        @{ Name = 'build number of another N'; Mutate = { param($m) $m.build.version = '6.2.0-daily.61617' } },
        @{ Name = 'source_ref automation instead of the derived build ref'; Mutate = { param($m) $m.build.source_ref = 'refs/heads/automation' } },
        @{ Name = 'source_ref of another build'; Mutate = { param($m) $m.build.source_ref = 'refs/heads/build/v6.2.0-daily.201-n1' } },
        @{ Name = 'reserved device name as bundle'; Mutate = { param($m) $m.attestation = @('NUL.jsonl') } },
        @{ Name = 'negative asset size'; Mutate = { param($m) $m.assets[0].size = -5 } }
    ) {
        $fx = New-FixtureRelease -U 202 -N 1
        $obj = [System.Text.Encoding]::UTF8.GetString($fx.Files['manifest.json']) | ConvertFrom-Json
        & $Mutate $obj
        [IO.File]::WriteAllText((Join-Path $script:dir 'manifest.json'), ($obj | ConvertTo-Json -Depth 8))
        { Read-ReleaseManifest -Path (Join-Path $script:dir 'manifest.json') -ExpectedTag $fx.Tag -AllowOwners @('Nonary') } | Should -Throw
    }
    It 'owner must be in the policy list AND in the local owner list' {
        $fx = New-FixtureRelease -U 202 -N 1
        Write-FixtureFiles $fx $script:dir
        { Read-ReleaseManifest -Path (Join-Path $script:dir 'manifest.json') -ExpectedTag $fx.Tag -AllowOwners @('Nonary') -LocalOwners @('Nonary') } | Should -Not -Throw
        { Read-ReleaseManifest -Path (Join-Path $script:dir 'manifest.json') -ExpectedTag $fx.Tag -AllowOwners @('Nonary', 'Evil') -LocalOwners @('SomeoneElse') } | Should -Throw '*local owner list*'
        { Read-ReleaseManifest -Path (Join-Path $script:dir 'manifest.json') -ExpectedTag $fx.Tag -AllowOwners @('Evil') -LocalOwners @('Nonary') } | Should -Throw '*policy allow-list*'
    }
    It 'rejects invalid JSON and oversize manifests' {
        $p = Join-Path $script:dir 'manifest.json'
        'not json' | Set-Content $p
        { Read-ReleaseManifest -Path $p -ExpectedTag 'v6.2.0-daily.202-vp.1' } | Should -Throw
        [IO.File]::WriteAllBytes($p, (New-Object byte[] (300KB)))
        { Read-ReleaseManifest -Path $p -ExpectedTag 'v6.2.0-daily.202-vp.1' } | Should -Throw '*too large*'
    }
}

Describe 'SHA256SUMS and hash agreement' {
    BeforeEach { $script:dir = New-TestRoot }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'parses text-mode and binary-mode lines' {
        $a = 'a' * 64; $b = 'b' * 64
        [IO.File]::WriteAllText((Join-Path $script:dir 'S'), "$a  MoonlightSetup.exe`n$b *manifest.json`n")
        $m = Read-Sha256Sums -Path (Join-Path $script:dir 'S')
        $m['MoonlightSetup.exe'] | Should -Be $a; $m['manifest.json'] | Should -Be $b
    }
    It 'rejects malformed / duplicate / path-bearing lines' -ForEach @(
        @{ T = "zzz  MoonlightSetup.exe`n" }, @{ T = ('a' * 64) + "  ..\evil.exe`n" }, @{ T = ('a' * 64) + "  a.exe`n" + ('b' * 64) + "  a.exe`n" }, @{ T = ('A' * 64) + "  a.exe`n" }
    ) {
        [IO.File]::WriteAllText((Join-Path $script:dir 'S'), $T)
        { Read-Sha256Sums -Path (Join-Path $script:dir 'S') } | Should -Throw
    }
    It 'Assert-HashesAgree passes when all agree and fails on each single disagreement' {
        $fx = New-FixtureRelease
        Write-FixtureFiles $fx $script:dir
        $man = Read-ReleaseManifest -Path (Join-Path $script:dir 'manifest.json') -ExpectedTag $fx.Tag -AllowOwners @('Nonary')
        $sums = Read-Sha256Sums -Path (Join-Path $script:dir 'SHA256SUMS')
        { Assert-HashesAgree -ComputedSha256 $fx.Sha -InstallerName 'MoonlightSetup.exe' -Sums $sums -Manifest $man -ApiDigest ('sha256:' + $fx.Sha) } | Should -Not -Throw
        $bad = ('f' * 64)
        { Assert-HashesAgree -ComputedSha256 $bad -InstallerName 'MoonlightSetup.exe' -Sums $sums -Manifest $man -ApiDigest $null } | Should -Throw '*SHA256SUMS*'
        $sums2 = @{ 'MoonlightSetup.exe' = $fx.Sha }
        $man2 = [pscustomobject]@{ Assets = @{ 'MoonlightSetup.exe' = $bad } }
        { Assert-HashesAgree -ComputedSha256 $fx.Sha -InstallerName 'MoonlightSetup.exe' -Sums $sums2 -Manifest $man2 -ApiDigest $null } | Should -Throw '*manifest*'
        { Assert-HashesAgree -ComputedSha256 $fx.Sha -InstallerName 'MoonlightSetup.exe' -Sums $sums -Manifest $man -ApiDigest ('sha256:' + $bad) } | Should -Throw '*API digest*'
        { Assert-HashesAgree -ComputedSha256 $fx.Sha -InstallerName 'MoonlightSetup.exe' -Sums @{} -Manifest $man -ApiDigest $null } | Should -Throw
    }
    It 'immutability flag is required' {
        { Assert-ReleaseImmutable -Release ([pscustomobject]@{ immutable = $true }) } | Should -Not -Throw
        { Assert-ReleaseImmutable -Release ([pscustomobject]@{ immutable = $false }) } | Should -Throw
        { Assert-ReleaseImmutable -Release ([pscustomobject]@{ tag_name = 'x' }) } | Should -Throw
    }
}

Describe 'Attestation argument construction' {
    It 'refuses a source ref outside automation|build/*' {
        { Test-ArtifactAttestation -GhPath 'x' -DataDir 'y' -FilePath 'f' -BundlePath 'b' -Repo 'a/b' -SignerWorkflow 'w' -SourceRef 'refs/heads/main' -SourceDigest $null } | Should -Throw '*not allowed*'
        { Test-ArtifactAttestation -GhPath 'x' -DataDir 'y' -FilePath 'f' -BundlePath 'b' -Repo 'a/b' -SignerWorkflow 'w' -SourceRef 'refs/heads/automation' -SourceDigest 'nothex' } | Should -Throw '*digest*'
    }
    It 'passes the pinned flags (checked with a stand-in gh that records its arguments)' {
        $d = New-TestRoot
        try {
            $log = Join-Path $d 'args.txt'
            $fake = Join-Path $d 'gh.cmd'
            "@echo off`r`necho %* > `"$log`"`r`nexit /b 0" | Set-Content -LiteralPath $fake -Encoding ASCII
            $r = Test-ArtifactAttestation -GhPath $fake -DataDir $d -FilePath 'C:\run dir\MoonlightSetup.exe' -BundlePath 'C:\run dir\attestation.sigstore.json' `
                -Repo 'emilwojcik93/moonlight-qt' -SignerWorkflow 'github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml' `
                -SourceRef 'refs/heads/build/v6.2.0-daily.202-n1' -SourceDigest ('b' * 40)
            $r.Ok | Should -BeTrue
            $a = Get-Content -LiteralPath $log -Raw
            $a | Should -Match 'attestation verify'
            $a | Should -Match '--repo emilwojcik93/moonlight-qt'
            $a | Should -Match '--signer-workflow github.com/emilwojcik93/moonlight-qt/.github/workflows/patched-windows-release.yml'
            $a | Should -Match '--source-ref refs/heads/build/v6.2.0-daily.202-n1'
            $a | Should -Match '--deny-self-hosted-runners'
            $a | Should -Match '--predicate-type https://slsa.dev/provenance/v1'
            $a | Should -Match '--cert-oidc-issuer https://token.actions.githubusercontent.com'
            $a | Should -Match ('--source-digest ' + ('b' * 40))
            $a | Should -Match '--bundle "C:\\run dir\\attestation.sigstore.json"'
            $a | Should -Not -Match '--token|GH_TOKEN'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'gh.exe pin' {
    It 'Assert-GhBinary rejects a binary that does not match the pinned hash' {
        $d = New-TestRoot
        try {
            $p = Join-Path $d 'gh.exe'; [IO.File]::WriteAllBytes($p, [byte[]](1, 2, 3))
            $pin = [pscustomobject]@{ gh_exe_sha256 = ('0' * 64) }
            { Assert-GhBinary -GhPath $p -Pin $pin -SkipSignature } | Should -Throw '*does not match pin*'
            $pin2 = [pscustomobject]@{ gh_exe_sha256 = (Get-UpdSha256 -Path $p) }
            { Assert-GhBinary -GhPath $p -Pin $pin2 -SkipSignature } | Should -Not -Throw
            { Assert-GhBinary -GhPath $p -Pin $pin2 } | Should -Throw '*signature*'    # unsigned file fails the Authenticode requirement
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'the shipped gh-pin.json is well-formed' {
        $pin = Read-GhPin -ProgramDir $UpdRoot
        $pin.version | Should -Match '^[0-9]+\.[0-9]+\.[0-9]+$'
    }
    It 'the machine gh.exe (if present) matches the pin and carries a valid GitHub signature' -Skip:(-not (Test-Path 'C:\Program Files\GitHub CLI\gh.exe')) {
        $pin = Read-GhPin -ProgramDir $UpdRoot
        $h = Get-UpdSha256 -Path 'C:\Program Files\GitHub CLI\gh.exe'
        if ($h -ne $pin.gh_exe_sha256) { Set-ItResult -Skipped -Because 'machine gh version differs from pin' } else {
            { Assert-GhBinary -GhPath 'C:\Program Files\GitHub CLI\gh.exe' -Pin $pin } | Should -Not -Throw
        }
    }
}
