BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }

    function New-SyntheticSecurity {
        param([string]$OwnerSid = 'S-1-5-32-544', [object[]]$Rules = @())
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        $sec.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($OwnerSid)))
        foreach ($r in $Rules) {
            $id = New-Object System.Security.Principal.SecurityIdentifier($r.Sid)
            $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            $prop = 'None'; if ($r.ContainsKey('InheritOnly') -and $r.InheritOnly) { $prop = 'InheritOnly' }
            $type = 'Allow'; if ($r.ContainsKey('Deny') -and $r.Deny) { $type = 'Deny' }
            $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $r.Rights, $inh, $prop, $type)))
        }
        return $sec
    }
    $script:Sys = @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
    $script:Adm = @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
}

Describe 'Find-AclViolation (pure)' {
    It 'accepts SYSTEM + Administrators only' {
        $v = Find-AclViolation -Security (New-SyntheticSecurity -Rules @($Sys, $Adm))
        @($v).Count | Should -Be 0
    }
    It 'accepts Users with read/execute only' {
        $v = Find-AclViolation -Security (New-SyntheticSecurity -Rules @($Sys, $Adm, @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }))
        @($v).Count | Should -Be 0
    }
    It 'flags <Name> with <Rights>' -ForEach @(
        @{ Name = 'Users'; Sid = 'S-1-5-32-545'; Rights = 'Modify' },
        @{ Name = 'Users'; Sid = 'S-1-5-32-545'; Rights = 'WriteData' },
        @{ Name = 'Users'; Sid = 'S-1-5-32-545'; Rights = 'AppendData' },
        @{ Name = 'Users'; Sid = 'S-1-5-32-545'; Rights = 'Delete' },
        @{ Name = 'Everyone'; Sid = 'S-1-1-0'; Rights = 'FullControl' },
        @{ Name = 'Authenticated Users'; Sid = 'S-1-5-11'; Rights = 'Modify' },
        @{ Name = 'Authenticated Users'; Sid = 'S-1-5-11'; Rights = 'ChangePermissions' },
        @{ Name = 'an arbitrary local user'; Sid = 'S-1-5-21-1-2-3-1001'; Rights = 'Write' }
    ) {
        $v = Find-AclViolation -Security (New-SyntheticSecurity -Rules @($Sys, $Adm, @{ Sid = $Sid; Rights = $Rights }))
        @($v).Count | Should -BeGreaterThan 0
        ($v -join ' ') | Should -Match ([regex]::Escape($Sid))
    }
    It 'ignores Deny ACEs and inherit-only ACEs' {
        $v = Find-AclViolation -Security (New-SyntheticSecurity -Rules @($Sys, $Adm, @{ Sid = 'S-1-5-32-545'; Rights = 'Modify'; Deny = $true }, @{ Sid = 'S-1-1-0'; Rights = 'Modify'; InheritOnly = $true }))
        @($v).Count | Should -Be 0
    }
    It 'flags a non-admin owner' {
        $v = Find-AclViolation -Security (New-SyntheticSecurity -OwnerSid 'S-1-5-32-545' -Rules @($Sys, $Adm))
        ($v -join ' ') | Should -Match 'owner'
    }
}

Describe 'Test-UpdAclSafe / Assert-UpdSelfAcl on the real file system' {
    BeforeEach { $script:d = New-TestDirs; New-Item -ItemType Directory -Path (Join-Path $script:d.Prog 'lib') | Out-Null }
    AfterEach {
        Get-ChildItem -LiteralPath $script:d.Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band 'ReparsePoint' } | ForEach-Object { cmd /c rmdir "`"$($_.FullName)`"" | Out-Null }
        Remove-Item -LiteralPath $script:d.Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'aborts when the script dir is writable by Users (icacls grant)' {
        & icacls.exe $script:d.Prog /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
        $v = Test-UpdAclSafe -Path $script:d.Prog
        ($v -join ' ') | Should -Match 'S-1-5-32-545|Users'
        { Assert-UpdSelfAcl -ProgramDir $script:d.Prog -DataDir $script:d.Data } | Should -Throw '*ACL self-check failed*'
    }
    It 'aborts when the data dir is writable by Everyone' {
        & icacls.exe $script:d.Data /grant '*S-1-1-0:(OI)(CI)M' | Out-Null
        { Assert-UpdSelfAcl -ProgramDir $script:d.Prog -DataDir $script:d.Data } | Should -Throw '*ACL self-check failed*'
    }
    It 'aborts when the data dir is writable by Authenticated Users' {
        & icacls.exe $script:d.Data /grant '*S-1-5-11:(OI)(CI)M' | Out-Null
        { Assert-UpdSelfAcl -ProgramDir $script:d.Prog -DataDir $script:d.Data } | Should -Throw '*ACL self-check failed*'
    }
    It 'aborts when a file inside the program dir is writable by Users' {
        $f = Join-Path $script:d.Prog 'update.ps1'; 'x' | Set-Content $f
        & icacls.exe $f /grant '*S-1-5-32-545:M' | Out-Null
        $v = Test-UpdAclSafe -Path $script:d.Prog
        ($v -join ' ') | Should -Match 'update.ps1'
    }
    It 'refuses a junction (reparse point) in place of the directory' {
        $target = Join-Path $script:d.Root 'real'; New-Item -ItemType Directory $target | Out-Null
        $link = Join-Path $script:d.Root 'link'
        cmd /c mklink /J "`"$link`"" "`"$target`"" | Out-Null
        (Test-UpdAclSafe -Path $link) -join ' ' | Should -Match 'reparse point'
    }
    It 'reports a missing directory' { (Test-UpdAclSafe -Path (Join-Path $script:d.Root 'nope')) -join ' ' | Should -Match 'does not exist' }
}

Describe 'Secure directory creation' {
    BeforeEach { $script:d = New-TestDirs }
    AfterEach { Remove-Item -LiteralPath $script:d.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates a protected directory with SYSTEM + Administrators (+ test sid) and no Users/Everyone' {
        $p = Join-Path $script:d.Data 'secure'
        Initialize-SecureDirectory -Path $p -AdditionalFullControlSids @($script:d.Sid)
        $acl = Get-Acl -LiteralPath $p
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
        $sids | Should -Contain 'S-1-5-18'
        $sids | Should -Contain 'S-1-5-32-544'
        $sids | Should -Not -Contain 'S-1-5-32-545'
        $sids | Should -Not -Contain 'S-1-1-0'
        $sids | Should -Not -Contain 'S-1-5-11'
        # only the sandbox user is reported (it is not an admin); no other violation
        $v = Find-AclViolation -Security $acl -Label $p
        foreach ($x in $v) { $x | Should -Match ([regex]::Escape($script:d.Sid)) }
    }
    It 'creates per-run dirs under updates\ with a unique, sortable name' {
        $a = New-UpdRunDirectory -DataDir $script:d.Data -AdditionalFullControlSids @($script:d.Sid)
        $b = New-UpdRunDirectory -DataDir $script:d.Data -AdditionalFullControlSids @($script:d.Sid)
        $a | Should -Not -Be $b
        (Split-Path $a -Leaf) | Should -Match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'
        (Split-Path (Split-Path $a -Parent) -Leaf) | Should -Be 'updates'
        (Get-Acl $a).AreAccessRulesProtected | Should -BeTrue
    }
    It 'removes old run dirs but keeps the current one' {
        $a = New-UpdRunDirectory -DataDir $script:d.Data -AdditionalFullControlSids @($script:d.Sid)
        $b = New-UpdRunDirectory -DataDir $script:d.Data -AdditionalFullControlSids @($script:d.Sid)
        (Get-Item $a).LastWriteTime = (Get-Date).AddDays(-30)
        Remove-OldRunDirectories -DataDir $script:d.Data -Except $b
        Test-Path $a | Should -BeFalse
        Test-Path $b | Should -BeTrue
    }
    It 'refuses to initialise a reparse point' {
        $target = Join-Path $script:d.Root 'real'; New-Item -ItemType Directory $target | Out-Null
        $link = Join-Path $script:d.Root 'link'; cmd /c mklink /J "`"$link`"" "`"$target`"" | Out-Null
        try { { Initialize-SecureDirectory -Path $link } | Should -Throw '*reparse*' } finally { cmd /c rmdir "`"$link`"" | Out-Null }
    }
}

Describe 'Single instance mutex' {
    It 'a second process cannot acquire the mutex while the first holds it' {
        $name = 'Global\MlUpdaterTest' + [guid]::NewGuid().ToString('N')
        $m = Enter-UpdMutex -Name $name
        try {
            $m | Should -Not -BeNullOrEmpty
            $code = "`$c=`$false; `$m=New-Object System.Threading.Mutex(`$false,'$name',[ref]`$c); if(`$m.WaitOne(0)){'ACQUIRED'}else{'BLOCKED'}"
            $out = & powershell.exe -NoProfile -Command $code
            $out | Should -Be 'BLOCKED'
        } finally { Exit-UpdMutex -Mutex $m }
        $out2 = & powershell.exe -NoProfile -Command $code
        $out2 | Should -Be 'ACQUIRED'
    }
}

Describe 'Deny-write handle' {
    It 'blocks writers, deleters and renamers while held' {
        $d = New-TestRoot
        try {
            $f = Join-Path $d 'x.bin'; [IO.File]::WriteAllBytes($f, [byte[]](1, 2, 3))
            $h = Open-DenyWriteHandle -Path $f
            try {
                { [IO.File]::Open($f, 'Open', 'Write', 'ReadWrite').Dispose() } | Should -Throw
                { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } | Should -Throw
                { Rename-Item -LiteralPath $f -NewName 'y.bin' -ErrorAction Stop } | Should -Throw
                [IO.File]::ReadAllBytes($f).Length | Should -Be 3     # readers are fine
            } finally { $h.Dispose() }
            { [IO.File]::WriteAllBytes($f, [byte[]](9)) } | Should -Not -Throw
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
