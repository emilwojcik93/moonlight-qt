BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
}

Describe 'Tag regex (CONTRACT 1)' {
    It 'accepts <_>' -ForEach @('v6.2.0-daily.202-vp.1', 'v6.2.0-daily.1-vp.999', 'v6.2.0-daily.99999-vp.12') {
        Test-MoonlightTag -Tag $_ | Should -BeTrue
    }
    It 'rejects malicious or malformed tag [<_>]' -ForEach @(
        'v6.2.0-daily.202-vp.1$(calc)', 'v6.2.0-daily.202-vp.1; calc', "v6.2.0-daily.202-vp.1`n", "v6.2.0-daily.202-vp.1`r`nGH_TOKEN=x",
        '../v6.2.0-daily.202-vp.1', 'v6.2.0-daily.202-vp.1/../../x', 'V6.2.0-daily.202-vp.1', 'v6.2.0-daily.202', 'v6.2.0-daily.100000-vp.1',
        'v6.2.0-daily.202-vp.1000', 'v6.2.1-daily.202-vp.1', 'v6.2.0-daily.20x-vp.1', ' v6.2.0-daily.202-vp.1', 'v6.2.0-daily.202-vp.1 ',
        ('v6.2.0-daily.' + [char]0x0662 + [char]0x0660 + [char]0x0662 + '-vp.1'), '', 'v6.2.0-daily.-vp.1', 'v6.2.0-daily.202-vp.', '-v6.2.0-daily.202-vp.1'
    ) {
        Test-MoonlightTag -Tag $_ | Should -BeFalse
    }
    It 'rejects $null' { Test-MoonlightTag -Tag $null | Should -BeFalse }
    It 'ConvertTo-OrderingKey throws on invalid tag' { { ConvertTo-OrderingKey -Tag 'evil' } | Should -Throw }
}

Describe 'Ordering key (U,N)' {
    It 'orders numerically, not lexically' {
        $a = ConvertTo-OrderingKey 'v6.2.0-daily.9-vp.1'; $b = ConvertTo-OrderingKey 'v6.2.0-daily.10-vp.1'
        Compare-OrderingKey $a $b | Should -Be -1
        $c = ConvertTo-OrderingKey 'v6.2.0-daily.10-vp.2'; $d = ConvertTo-OrderingKey 'v6.2.0-daily.10-vp.10'
        Compare-OrderingKey $c $d | Should -Be -1
        Compare-OrderingKey $d $d | Should -Be 0
        Compare-OrderingKey $d $c | Should -Be 1
    }
    It 'U dominates N' {
        Compare-OrderingKey (ConvertTo-OrderingKey 'v6.2.0-daily.203-vp.1') (ConvertTo-OrderingKey 'v6.2.0-daily.202-vp.99') | Should -Be 1
    }
}

Describe 'Installed build mapping' {
    It 'FileVersion 6.2.60006.0 -> U=6,N=0' {
        $k = Resolve-InstalledKey -FileVersion '6.2.60006.0' -State $null
        $k.U | Should -Be 6; $k.N | Should -Be 0; $k.Build | Should -Be 60006
    }
    It 'state.json N wins when U matches' {
        $st = [pscustomobject]@{ installed = [pscustomobject]@{ u = 202; n = 3 } }
        (Resolve-InstalledKey -FileVersion '6.2.60202.0' -State $st).N | Should -Be 3
    }
    It 'state.json N ignored when U differs' {
        $st = [pscustomobject]@{ installed = [pscustomobject]@{ u = 100; n = 3 } }
        (Resolve-InstalledKey -FileVersion '6.2.60202.0' -State $st).N | Should -Be 0
    }
    It 'returns $null for unrecognised versions' -ForEach @('', '6.1.0.0', '7.2.60006.0', '6.2.100.0', 'garbage', '6.2.60006.0; calc') {
        Resolve-InstalledKey -FileVersion $_ -State $null | Should -BeNullOrEmpty
    }
    It 'build number mapping and MSI cap' {
        ConvertTo-BuildNumber -U 202 | Should -Be 60202
        { ConvertTo-BuildNumber -U 5536 } | Should -Throw
        ConvertTo-BuildNumber -U 5535 | Should -Be 65535
    }
}

Describe 'Release selection' {
    BeforeAll {
        function New-Rel($tag, [bool]$draft = $false, [bool]$pre = $true) { [pscustomobject]@{ tag_name = $tag; draft = $draft; prerelease = $pre; published_at = '2026-11-20T00:00:00Z' } }
    }
    It 'sorts newest first and drops drafts and invalid tags' {
        $rels = @(
            (New-Rel 'v6.2.0-daily.201-vp.1'), (New-Rel 'v6.2.0-daily.202-vp.2'), (New-Rel 'v6.2.0-daily.202-vp.10'),
            (New-Rel 'v6.2.0-daily.299-vp.1' $true), (New-Rel 'v6.2.0-daily.300-vp.1$(x)'), (New-Rel 'v6.1.0-vrr18'), $null,
            ([pscustomobject]@{ nothing = 1 })
        )
        $c = Select-NewestEligibleRelease -Releases $rels
        @($c).Count | Should -Be 3
        $c[0].Key.Tag | Should -Be 'v6.2.0-daily.202-vp.10'
        $c[1].Key.Tag | Should -Be 'v6.2.0-daily.202-vp.2'
        $c[2].Key.Tag | Should -Be 'v6.2.0-daily.201-vp.1'
    }
    It 'stable channel ignores pre-releases (feed is all pre-release until promoted)' {
        $c = Select-NewestEligibleRelease -Releases @((New-Rel 'v6.2.0-daily.202-vp.1' $false $true), (New-Rel 'v6.2.0-daily.201-vp.1' $false $false)) -Channel stable
        @($c).Count | Should -Be 1
        $c[0].Key.Tag | Should -Be 'v6.2.0-daily.201-vp.1'
    }
    It 'handles an empty list' { $c = Select-NewestEligibleRelease -Releases @(); @($c).Count | Should -Be 0 }
    It 'age in hours' {
        $now = [datetime]::Parse('2026-11-22T12:00:00Z').ToUniversalTime()
        [math]::Round((Get-ReleaseAgeHours -PublishedAt '2026-11-21T12:00:00Z' -NowUtc $now), 1) | Should -Be 24
        { Get-ReleaseAgeHours -PublishedAt 'not a date' -NowUtc $now } | Should -Throw
    }
}
