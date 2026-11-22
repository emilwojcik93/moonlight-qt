BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
}

Describe 'Tag regex (CONTRACT 1)' {
    It 'accepts <_>' -ForEach @('v6.2.0-daily.202-vp.1', 'v6.2.0-daily.1-vp.999', 'v6.2.0-daily.99999-vp.12', 'v6.2.0-daily.202-vp.8') {
        Test-MoonlightTag -Tag $_ | Should -BeTrue
    }
    It 'rejects malicious or malformed tag [<_>]' -ForEach @(
        'v6.2.0-daily.202-vp.1$(calc)', 'v6.2.0-daily.202-vp.1; calc', "v6.2.0-daily.202-vp.1`n", "v6.2.0-daily.202-vp.1`r`nGH_TOKEN=x",
        '../v6.2.0-daily.202-vp.1', 'v6.2.0-daily.202-vp.1/../../x', 'V6.2.0-daily.202-vp.1', 'v6.2.0-daily.202', 'v6.2.0-daily.100000-vp.1',
        'v6.2.0-daily.202-vp.1000', 'v6.2.1-daily.202-vp.1', 'v6.2.0-daily.0202-vp.1', 'v6.2.0-daily.00202-vp.1', 'v6.2.0-daily.202-vp.01', 'v6.2.0-daily.202-vp.0', 'v6.2.0-daily.0-vp.1', 'v6.2.0-daily.20x-vp.1', ' v6.2.0-daily.202-vp.1', 'v6.2.0-daily.202-vp.1 ',
        ('v6.2.0-daily.' + [char]0x0662 + [char]0x0660 + [char]0x0662 + '-vp.1'), '', 'v6.2.0-daily.-vp.1', 'v6.2.0-daily.202-vp.', '-v6.2.0-daily.202-vp.1'
    ) {
        Test-MoonlightTag -Tag $_ | Should -BeFalse
    }
    It 'rejects $null' { Test-MoonlightTag -Tag $null | Should -BeFalse }
    It 'ConvertTo-OrderingKey throws on invalid tag' { { ConvertTo-OrderingKey -Tag 'evil' } | Should -Throw }
    It 'ConvertTo-OrderingKey rejects N > 8 and B > 65535 (not installable under CONTRACT 3b) although the tag regex matches' {
        { ConvertTo-OrderingKey -Tag 'v6.2.0-daily.202-vp.9' } | Should -Throw '*N must be*'
        { ConvertTo-OrderingKey -Tag 'v6.2.0-daily.692-vp.1' } | Should -Throw '*exceeds MSI limit*'
        (ConvertTo-OrderingKey -Tag 'v6.2.0-daily.691-vp.8').Build | Should -Be 65535
    }
}

Describe 'Ordering key (U,N) and build number (CONTRACT 3b: B = 60000 + 8*U + (N-1))' {
    It 'orders numerically, not lexically' {
        $a = ConvertTo-OrderingKey 'v6.2.0-daily.9-vp.1'; $b = ConvertTo-OrderingKey 'v6.2.0-daily.10-vp.1'
        Compare-OrderingKey $a $b | Should -Be -1
        $c = ConvertTo-OrderingKey 'v6.2.0-daily.10-vp.2'; $d = ConvertTo-OrderingKey 'v6.2.0-daily.10-vp.8'
        Compare-OrderingKey $c $d | Should -Be -1
        Compare-OrderingKey $d $d | Should -Be 0
        Compare-OrderingKey $d $c | Should -Be 1
    }
    It 'U dominates N' {
        Compare-OrderingKey (ConvertTo-OrderingKey 'v6.2.0-daily.203-vp.1') (ConvertTo-OrderingKey 'v6.2.0-daily.202-vp.8') | Should -Be 1
    }
    It 'build number formula and bounds' {
        ConvertTo-BuildNumber -U 202 -N 1 | Should -Be 61616
        ConvertTo-BuildNumber -U 202 -N 8 | Should -Be 61623
        ConvertTo-BuildNumber -U 203 -N 1 | Should -Be 61624
        ConvertTo-BuildNumber -U 691 -N 8 | Should -Be 65535
        { ConvertTo-BuildNumber -U 692 -N 1 } | Should -Throw
        { ConvertTo-BuildNumber -U 202 -N 9 } | Should -Throw
        { ConvertTo-BuildNumber -U 202 -N 0 } | Should -Throw
        { ConvertTo-BuildNumber -U 0 -N 1 } | Should -Throw
    }
    It 'ConvertFrom-BuildNumber is the exact inverse for every installable (U,N)' {
        foreach ($u in 1, 2, 202, 691) { foreach ($n in 1..8) {
                if ($u -eq 691 -and $n -gt 8) { continue }
                $b = ConvertTo-BuildNumber -U $u -N $n
                $x = ConvertFrom-BuildNumber -Build $b
                $x.U | Should -Be $u; $x.N | Should -Be $n
            } }
        ConvertFrom-BuildNumber -Build 59999 | Should -BeNullOrEmpty
        ConvertFrom-BuildNumber -Build 65536 | Should -BeNullOrEmpty
    }
}

Describe 'Installed build mapping (from FileVersion alone)' {
    It 'FileVersion 6.2.61616.0 -> U=202,N=1' {
        $k = Resolve-InstalledKey -FileVersion '6.2.61616.0' -State $null
        $k.U | Should -Be 202; $k.N | Should -Be 1; $k.Build | Should -Be 61616
    }
    It 'N=8 and N=1 of the next U are adjacent' {
        (Resolve-InstalledKey -FileVersion '6.2.61623.0' -State $null).N | Should -Be 8
        $k = Resolve-InstalledKey -FileVersion '6.2.61624.0' -State $null
        $k.U | Should -Be 203; $k.N | Should -Be 1
    }
    It 'legacy 6.2.60006 is not special-cased: it simply compares numerically lower than any new build' {
        $old = Resolve-InstalledKey -FileVersion '6.2.60006.0' -State $null
        $old.Build | Should -Be 60006
        $new = ConvertTo-OrderingKey 'v6.2.0-daily.202-vp.1'
        Compare-OrderingKey $old $new | Should -Be -1
        Compare-OrderingKey $new $old | Should -Be 1
    }
    It 'state.json is ignored for ordering' {
        $st = [pscustomobject]@{ installed = [pscustomobject]@{ u = 999; n = 8; build = 65000 } }
        (Resolve-InstalledKey -FileVersion '6.2.61616.0' -State $st).U | Should -Be 202
    }
    It 'returns $null for unrecognised versions' -ForEach @('', '6.1.0.0', '7.2.60006.0', '6.2.100.0', '6.2.65536.0', 'garbage', '6.2.60006.0; calc') {
        Resolve-InstalledKey -FileVersion $_ -State $null | Should -BeNullOrEmpty
    }
}

Describe 'Release selection' {
    BeforeAll {
        function New-Rel($tag, [bool]$draft = $false, [bool]$pre = $true) { [pscustomobject]@{ tag_name = $tag; draft = $draft; prerelease = $pre; published_at = '2026-11-20T00:00:00Z' } }
    }
    It 'sorts newest first and drops drafts and invalid tags' {
        $rels = @(
            (New-Rel 'v6.2.0-daily.201-vp.1'), (New-Rel 'v6.2.0-daily.202-vp.2'), (New-Rel 'v6.2.0-daily.202-vp.8'), (New-Rel 'v6.2.0-daily.202-vp.9'), (New-Rel 'v6.2.0-daily.700-vp.1'),
            (New-Rel 'v6.2.0-daily.0203-vp.1'),
            (New-Rel 'v6.2.0-daily.299-vp.1' $true), (New-Rel 'v6.2.0-daily.300-vp.1$(x)'), (New-Rel 'v6.1.0-vrr18'), $null,
            ([pscustomobject]@{ nothing = 1 })
        )
        $c = Select-NewestEligibleRelease -Releases $rels
        @($c).Count | Should -Be 3      # N=9, U=700 (B > 65535) and the leading-zero alias are dropped
        $c[0].Key.Tag | Should -Be 'v6.2.0-daily.202-vp.8'
        $c[1].Key.Tag | Should -Be 'v6.2.0-daily.202-vp.2'
        $c[2].Key.Tag | Should -Be 'v6.2.0-daily.201-vp.1'
    }
    It 'channels differ only by cooling-off: the pre-release flag is not a filter (all feed releases are pre-releases)' {
        foreach ($ch in 'canary', 'stable') {
            $c = Select-NewestEligibleRelease -Releases @((New-Rel 'v6.2.0-daily.202-vp.1' $false $true), (New-Rel 'v6.2.0-daily.201-vp.1' $false $false)) -Channel $ch
            @($c).Count | Should -Be 2
            $c[0].Key.Tag | Should -Be 'v6.2.0-daily.202-vp.1'
        }
    }
    It 'handles an empty list' { $c = Select-NewestEligibleRelease -Releases @(); @($c).Count | Should -Be 0 }
    It 'age in hours' {
        $now = [datetime]::Parse('2026-11-22T12:00:00Z').ToUniversalTime()
        [math]::Round((Get-ReleaseAgeHours -PublishedAt '2026-11-21T12:00:00Z' -NowUtc $now), 1) | Should -Be 24
        { Get-ReleaseAgeHours -PublishedAt 'not a date' -NowUtc $now } | Should -Throw
    }
}
