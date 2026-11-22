BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }
    $script:ContractPolicy = @'
schema: 1
allow_upstream_owners: [Nonary]
cooling_off_hours: {stable: 24, canary: 0}
hold: false
deny: []          # list of tags that must never install
keep_releases: 10
'@
    # shape currently on the `automation` branch of emilwojcik93/moonlight-qt
    $script:BranchPolicy = @'
# Policy for the moonlight-qt patch pipeline.
upstream:
  owner_allowlist:
    - Nonary
  repo: moonlight-qt
  tag_regex: '^v6\.2\.0-daily\.[0-9]{1,5}$'
  poll_interval_hours: 6
supported_floor_tag: v6.2.0-daily.201
channels:
  canary:
    cooling_off_hours: 0
  stable:
    cooling_off_hours: 24
hold: false
groups_enabled:
  - posture-core
  - touch-menu
version_scheme:
  ci_version: '6.2.0-daily.(60000+U)'
  max_build_number: 65535
'@
}

Describe 'YAML subset + policy' {
    It 'parses the CONTRACT policy shape' {
        $p = ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset -Text $script:ContractPolicy)
        $p.Hold | Should -BeFalse
        @($p.Deny).Count | Should -Be 0
        $p.AllowOwners | Should -Contain 'Nonary'
        $p.CoolingOff['stable'] | Should -Be 24
        $p.CoolingOff['canary'] | Should -Be 0
        $p.HasDenyKey | Should -BeTrue
    }
    It 'parses the shape currently on the automation branch (no deny key)' {
        $p = ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset -Text $script:BranchPolicy)
        $p.AllowOwners | Should -Contain 'Nonary'
        $p.CoolingOff['canary'] | Should -Be 0
        $p.CoolingOff['stable'] | Should -Be 24
        $p.HasDenyKey | Should -BeFalse
        @($p.Deny).Count | Should -Be 0
    }
    It 'reads block-list deny entries and hold: true' {
        $p = ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset -Text "hold: true`ndeny:`n  - v6.2.0-daily.202-vp.1`n  - 'v6.2.0-daily.203-vp.2'`n")
        $p.Hold | Should -BeTrue
        $p.Deny | Should -Contain 'v6.2.0-daily.202-vp.1'
        $p.Deny | Should -Contain 'v6.2.0-daily.203-vp.2'
    }
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'tabs'; Text = "hold:`tfalse" },
        @{ Name = 'anchors'; Text = "a: &x 1`nb: *x" },
        @{ Name = 'block scalars'; Text = "a: |`n  text" },
        @{ Name = 'list of maps'; Text = "deny:`n  - tag: x" },
        @{ Name = 'duplicate keys'; Text = "hold: false`nhold: true" },
        @{ Name = 'multiple documents'; Text = "a: 1`n---`nb: 2" },
        @{ Name = 'bad indentation'; Text = "a:`n    b: 1`n  c: 2" }
    ) {
        { ConvertFrom-YamlSubset -Text $Text } | Should -Throw
    }
    It 'policy fails closed on invalid content' -ForEach @(
        @{ Text = 'hold: maybe' }, @{ Text = 'deny: [evil]' }, @{ Text = 'deny: ["v6.2.0-daily.1-vp.1$(x)"]' },
        @{ Text = 'allow_upstream_owners: ["a b"]' }, @{ Text = "cooling_off_hours: {canary: -1}" }
    ) {
        { ConvertTo-UpdPolicy -Doc (ConvertFrom-YamlSubset -Text $Text) } | Should -Throw
    }
    It 'local cooling-off is a floor; policy can only raise it' {
        $pol = New-DefaultPolicy -Canary 6
        Get-EffectiveCoolingOffHours -LocalHours 0 -Policy $pol -Channel canary | Should -Be 6
        Get-EffectiveCoolingOffHours -LocalHours 12 -Policy $pol -Channel canary | Should -Be 12
    }
}

Describe 'Config' {
    BeforeEach { $script:d = New-TestDirs }
    AfterEach { Remove-Item -LiteralPath $script:d.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'defaults to report-only canary with 0 h cooling-off' {
        $c = Read-UpdConfig -ProgramDir $script:d.Prog
        $c['mode'] | Should -Be 'report-only'; $c['channel'] | Should -Be 'canary'; $c['cooling_off_hours'] | Should -Be 0
        $c['api_base'] | Should -Be 'https://api.github.com'
    }
    It 'reads valid config.json' {
        '{"schema":1,"mode":"install","channel":"stable","cooling_off_hours":6}' | Set-Content -LiteralPath (Join-Path $script:d.Prog 'config.json')
        $c = Read-UpdConfig -ProgramDir $script:d.Prog
        $c['mode'] | Should -Be 'install'; $c['cooling_off_hours'] | Should -Be 6
    }
    It 'rejects invalid value <Json>' -ForEach @(
        @{ Json = '{"mode":"yolo"}' }, @{ Json = '{"channel":"nightly"}' }, @{ Json = '{"cooling_off_hours":-1}' },
        @{ Json = '{"cooling_off_hours":"0"}' }, @{ Json = '{"repo":"a/b; calc"}' }, @{ Json = '{"repo":"evil/other"}' },
        @{ Json = '{"signer_workflow":"github.com/evil/repo/.github/workflows/x.yml"}' }, @{ Json = '{"verify_mode":"none"}' },
        @{ Json = '{"schema":2}' }, @{ Json = 'not json' }, @{ Json = '{"max_installer_mb":0}' }, @{ Json = '{"notify_enabled":"yes"}' }
    ) {
        $Json | Set-Content -LiteralPath (Join-Path $script:d.Prog 'config.json')
        { Read-UpdConfig -ProgramDir $script:d.Prog } | Should -Throw
    }
    It 'test-only key <Key> is refused without the flag file (env vars never enable it)' -ForEach @(
        @{ Key = 'api_base'; Val = '"http://127.0.0.1:1"' }, @{ Key = 'download_base'; Val = '"http://127.0.0.1:1"' },
        @{ Key = 'gh_path'; Val = '"C:\\x\\gh.exe"' }, @{ Key = 'allow_http'; Val = 'true' }, @{ Key = 'skip_acl_check'; Val = 'true' }, @{ Key = 'data_dir'; Val = '"C:\\x"' }
    ) {
        $env:MLU_TEST_MODE = '1'; $env:TEST_MODE = '1'
        try {
            ('{"' + $Key + '":' + $Val + '}') | Set-Content -LiteralPath (Join-Path $script:d.Prog 'config.json')
            { Read-UpdConfig -ProgramDir $script:d.Prog } | Should -Throw '*test-mode*'
        } finally { Remove-Item Env:\MLU_TEST_MODE, Env:\TEST_MODE -ErrorAction SilentlyContinue }
    }
    It 'test-only keys are honoured when the flag file exists' {
        '' | Set-Content -LiteralPath (Join-Path $script:d.Prog 'test-mode.flag')
        '{"api_base":"http://127.0.0.1:8123","download_base":"http://127.0.0.1:8123","allow_http":true}' | Set-Content -LiteralPath (Join-Path $script:d.Prog 'config.json')
        $c = Read-UpdConfig -ProgramDir $script:d.Prog
        $c['api_base'] | Should -Be 'http://127.0.0.1:8123'; $c['test_mode'] | Should -BeTrue
    }
    It 'http api_base needs allow_http even in test mode' {
        '' | Set-Content -LiteralPath (Join-Path $script:d.Prog 'test-mode.flag')
        '{"api_base":"http://127.0.0.1:8123"}' | Set-Content -LiteralPath (Join-Path $script:d.Prog 'config.json')
        { Read-UpdConfig -ProgramDir $script:d.Prog } | Should -Throw
    }
    It 'command-line mode override can only narrow' {
        Get-EffectiveMode -ConfigMode 'install' -Override 'report-only' | Should -Be 'report-only'
        Get-EffectiveMode -ConfigMode 'install' -Override 'hold' | Should -Be 'hold'
        Get-EffectiveMode -ConfigMode 'report-only' -Override 'install' | Should -Be 'report-only'
        Get-EffectiveMode -ConfigMode 'hold' -Override 'install' | Should -Be 'hold'
        Get-EffectiveMode -ConfigMode 'install' -Override '' | Should -Be 'install'
        { Get-EffectiveMode -ConfigMode 'install' -Override 'x' } | Should -Throw
    }
}

Describe 'State' {
    BeforeEach { $script:d = New-TestDirs }
    AfterEach { Remove-Item -LiteralPath $script:d.Root -Recurse -Force -ErrorAction SilentlyContinue }
    It 'round-trips and records local denies' {
        $s = Read-UpdState -DataDir $script:d.Data
        Add-LocalDeny -State $s -Tag 'v6.2.0-daily.202-vp.1' -Reason 'unit'
        Save-UpdState -DataDir $script:d.Data -State $s
        $s2 = Read-UpdState -DataDir $script:d.Data
        Test-LocallyDenied -State $s2 -Tag 'v6.2.0-daily.202-vp.1' | Should -BeTrue
        Test-LocallyDenied -State $s2 -Tag 'v6.2.0-daily.203-vp.1' | Should -BeFalse
    }
    It 'survives a corrupt state file' {
        'garbage{' | Set-Content -LiteralPath (Join-Path $script:d.Data 'state.json')
        $s = Read-UpdState -DataDir $script:d.Data
        @($s.denied).Count | Should -Be 0
        Test-Path (Join-Path $script:d.Data 'state.json.corrupt') | Should -BeTrue
    }
}
