BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    foreach ($f in $LibFiles) { . (Join-Path $UpdRoot "lib\$f.ps1") }

    # ---- harmless stand-in for MoonlightSetup.exe, compiled once with the .NET Framework csc ----
    $script:ToolDir = New-TestRoot
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $src = @'
using System; using System.IO; using System.Reflection;
[assembly: AssemblyFileVersion("6.2.60006.0")]
class P {
  static int Main(string[] a) {
    string dir = AppDomain.CurrentDomain.BaseDirectory;
    File.WriteAllText(Path.Combine(dir, "args.txt"), string.Join("|", a));
    string state = Environment.GetEnvironmentVariable("FAKE_STATE");
    string build = File.Exists(Path.Combine(dir, "build.txt")) ? File.ReadAllText(Path.Combine(dir, "build.txt")).Trim() : "0";
    string rcs = File.Exists(Path.Combine(dir, "rc.txt")) ? File.ReadAllText(Path.Combine(dir, "rc.txt")).Trim() : "0";
    string sleep = Environment.GetEnvironmentVariable("FAKE_SLEEP_MS");
    if (sleep != null) System.Threading.Thread.Sleep(int.Parse(sleep));
    if (state != null && a.Length > 0) {
      if (a[0] == "/install") {
        if (Environment.GetEnvironmentVariable("FAKE_REFUSE_DOWNGRADE") == "1" && File.Exists(state) && int.Parse(File.ReadAllText(state).Trim()) > int.Parse(build)) return 1638;
        File.WriteAllText(state, build);
      } else if (a[0] == "/uninstall") { if (File.Exists(state)) File.Delete(state); }
    }
    return int.Parse(rcs);
  }
}
'@
    $srcFile = Join-Path $script:ToolDir 'dummy.cs'
    [IO.File]::WriteAllText($srcFile, $src)
    $script:DummyExe = Join-Path $script:ToolDir 'dummy-template.exe'
    & $csc /nologo /target:exe "/out:$script:DummyExe" $srcFile | Out-Null
    if (-not (Test-Path $script:DummyExe)) { throw 'could not compile the stand-in installer' }

    function New-DummyBundle([string]$Root, [string]$Name, [int]$Build, [int]$Rc = 0) {
        $dir = Join-Path $Root $Name; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'MoonlightSetup.exe'
        Copy-Item -LiteralPath $script:DummyExe -Destination $exe
        Set-Content -LiteralPath (Join-Path $dir 'build.txt') -Value $Build
        Set-Content -LiteralPath (Join-Path $dir 'rc.txt') -Value $Rc
        return [pscustomobject]@{ Dir = $dir; Exe = $exe; Sha = (Get-UpdSha256 -Path $exe); Build = $Build; Name = $Name }
    }
}
AfterAll { Remove-Item -LiteralPath $script:ToolDir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Source audit (security rules, AST based)' {
    BeforeAll {
        $script:Sources = @(Get-ChildItem -LiteralPath $UpdRoot -Recurse -Filter *.ps1 | Where-Object { $_.DirectoryName -ne $PSScriptRoot })
        $script:Asts = @{}
        foreach ($f in $script:Sources) {
            $t = $null; $e = $null
            $script:Asts[$f.Name] = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        }
        function Get-Commands($ast) { $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) }
        function Get-CmdName($c) { $c.GetCommandName() }
    }
    It 'has parsable sources' { $script:Sources.Count | Should -BeGreaterThan 10 }
    It 'never uses Invoke-Expression / iex / Add-Type -Verb tricks / Start-Process -Verb' {
        foreach ($f in $script:Sources) {
            foreach ($c in (Get-Commands $script:Asts[$f.Name])) {
                $n = Get-CmdName $c
                if ($null -eq $n) { continue }
                $n | Should -Not -BeIn @('Invoke-Expression', 'iex') -Because $f.Name
                if ($n -eq 'Start-Process') {
                    ($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Verb' }) | Should -BeNullOrEmpty -Because $f.Name
                }
            }
        }
    }
    It 'never exports or reads Moonlight registry values (no reg.exe, no GetValue, no Get-ItemProperty on HKCU/HKU)' {
        foreach ($f in $script:Sources) {
            $ast = $script:Asts[$f.Name]
            foreach ($c in (Get-Commands $ast)) {
                $n = Get-CmdName $c
                if ($null -eq $n) { continue }
                $n | Should -Not -BeIn @('reg', 'reg.exe', 'regedit', 'Export-Clixml') -Because $f.Name
                if ($n -in @('Get-ItemProperty', 'Get-ItemPropertyValue', 'Get-Item', 'Get-ChildItem')) {
                    $c.Extent.Text | Should -Not -Match '(?i)HKCU|HKU:|HKEY_USERS|HKEY_CURRENT_USER' -Because $f.Name
                }
            }
            $members = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
            foreach ($m in $members) { $m.Member.Extent.Text | Should -Not -BeIn @('GetValue', 'GetValueKind') -Because $f.Name }
        }
    }
    It 'sets TLS 1.2 and never disables certificate validation' {
        [IO.File]::ReadAllText((Join-Path $UpdRoot 'lib\GitHub.ps1')) | Should -Match 'Tls12'
        foreach ($f in $script:Sources) {
            $ast = $script:Asts[$f.Name]
            $mem = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
            foreach ($m in $mem) { $m.Member.Extent.Text | Should -Not -Be 'ServerCertificateValidationCallback' -Because $f.Name }
            foreach ($c in (Get-Commands $ast)) {
                ($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SkipCertificateCheck' }) | Should -BeNullOrEmpty -Because $f.Name
            }
        }
    }
}

Describe 'Presence-only registry check' {
    BeforeEach {
        $script:Base = 'Software\MlUpdaterPesterTest\' + [guid]::NewGuid().ToString('N')
        $script:Sub = $script:Base + '\Moonlight'
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:Sub)
        $k.SetValue('uniqueid', 'SECRET-UNIQUEID-VALUE')
        $k.SetValue('certificate', '-----BEGIN CERTIFICATE----- SECRET-CERT-BODY')
        $k.SetValue('key', '-----BEGIN PRIVATE KEY----- SECRET-KEY-BODY')
        $k.SetValue('clientposture', 1)
        $k.CreateSubKey('hosts').Close()
        $k.Close()
    }
    AfterEach { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:Base, $false) }

    It 'reports booleans only and never returns values' {
        $p = Get-MoonlightPresence -Root ([Microsoft.Win32.Registry]::CurrentUser) -SubPath $script:Sub
        $p.HiveAvailable | Should -BeTrue; $p.UniqueId | Should -BeTrue; $p.Hosts | Should -BeTrue; $p.Certificate | Should -BeTrue; $p.Key | Should -BeTrue
        foreach ($prop in $p.PSObject.Properties) { $prop.Value | Should -BeOfType [bool] }
        (($p | ConvertTo-Json) + ($p | Out-String)) | Should -Not -Match 'SECRET|BEGIN'
    }
    It 'detects missing items' {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:Sub, $true)
        $k.DeleteValue('certificate'); $k.DeleteSubKey('hosts'); $k.Close()
        $p = Get-MoonlightPresence -Root ([Microsoft.Win32.Registry]::CurrentUser) -SubPath $script:Sub
        $p.Certificate | Should -BeFalse; $p.Hosts | Should -BeFalse; $p.UniqueId | Should -BeTrue
    }
    It 'reports HiveAvailable=false for a missing key' {
        (Get-MoonlightPresence -Root ([Microsoft.Win32.Registry]::CurrentUser) -SubPath ($script:Base + '\nope')).HiveAvailable | Should -BeFalse
    }
    It 'Compare-Presence: lost items, unknown-before, missing hive after' {
        $all = [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $true; Key = $true }
        $noCert = [pscustomobject]@{ HiveAvailable = $true; UniqueId = $true; Hosts = $true; Certificate = $false; Key = $true }
        $none = [pscustomobject]@{ HiveAvailable = $false; UniqueId = $false; Hosts = $false; Certificate = $false; Key = $false }
        @(Compare-Presence -Before $all -After $all).Count | Should -Be 0
        (Compare-Presence -Before $all -After $noCert) | Should -Contain 'Certificate'
        @(Compare-Presence -Before $none -After $noCert).Count | Should -Be 0
        (Compare-Presence -Before $all -After $none) | Should -Contain 'hive-or-key-missing-after-install'
    }
}

Describe 'Installed version' {
    It 'reads the FileVersion of an exe' {
        Get-InstalledMoonlightVersion -ExePath $script:DummyExe -BundleGuid '{00000000-0000-0000-0000-000000000000}' | Should -Be '6.2.60006.0'
    }
    It 'returns $null when nothing is installed' {
        Get-InstalledMoonlightVersion -ExePath 'C:\nope\Moonlight.exe' -BundleGuid '{00000000-0000-0000-0000-000000000000}' | Should -BeNullOrEmpty
    }
}

Describe 'Installer execution (stand-in exe)' {
    BeforeEach { $script:w = New-TestRoot; $env:FAKE_STATE = Join-Path $script:w 'state.txt' }
    AfterEach {
        Remove-Item Env:\FAKE_STATE, Env:\FAKE_SLEEP_MS, Env:\FAKE_REFUSE_DOWNGRADE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:w -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs /install /quiet /norestart /log LOGPATH and returns the exit code' {
        $b = New-DummyBundle $script:w 'b1' 60202
        $r = Invoke-MoonlightInstaller -InstallerPath $b.Exe -ExpectedSha256 $b.Sha -LogPath (Join-Path $script:w 'i.log')
        $r.Started | Should -BeTrue; $r.HashOk | Should -BeTrue; $r.Rc | Should -Be 0; $r.TimedOut | Should -BeFalse
        (Get-Content (Join-Path $b.Dir 'args.txt') -Raw).Trim() | Should -Be ('/install|/quiet|/norestart|/log|' + (Join-Path $script:w 'i.log'))
        (Get-Content $env:FAKE_STATE -Raw).Trim() | Should -Be '60202'
    }
    It 'reports 3010 as reboot pending' {
        $b = New-DummyBundle $script:w 'b2' 60202 3010
        (Invoke-MoonlightInstaller -InstallerPath $b.Exe -ExpectedSha256 $b.Sha -LogPath 'x').RebootPending | Should -BeTrue
    }
    It 'does NOT launch when the file hash differs from the verified hash (re-hash before launch)' {
        $b = New-DummyBundle $script:w 'b3' 60202
        $r = Invoke-MoonlightInstaller -InstallerPath $b.Exe -ExpectedSha256 ('0' * 64) -LogPath 'x'
        $r.Started | Should -BeFalse; $r.HashOk | Should -BeFalse
        Test-Path (Join-Path $b.Dir 'args.txt') | Should -BeFalse
        Test-Path $env:FAKE_STATE | Should -BeFalse
    }
    It 'kills the installer after the timeout' {
        $b = New-DummyBundle $script:w 'b4' 60202
        $env:FAKE_SLEEP_MS = '20000'
        $r = Invoke-MoonlightInstaller -InstallerPath $b.Exe -ExpectedSha256 $b.Sha -LogPath 'x' -TimeoutSec 2
        $r.TimedOut | Should -BeTrue
    }
    It 'nobody can swap the installer while it runs (deny-write handle)' {
        $b = New-DummyBundle $script:w 'b5' 60202
        $env:FAKE_SLEEP_MS = '3000'
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
                param($root, $exe, $sha, $libs)
                foreach ($f in $libs) { . (Join-Path $root "lib\$f.ps1") }
                Invoke-MoonlightInstaller -InstallerPath $exe -ExpectedSha256 $sha -LogPath 'x' -TimeoutSec 30
            }).AddArgument($UpdRoot).AddArgument($b.Exe).AddArgument($b.Sha).AddArgument(@('Common', 'Security', 'Verify', 'Install'))
        $async = $ps.BeginInvoke()
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not (Test-Path (Join-Path $b.Dir 'args.txt')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path (Join-Path $b.Dir 'args.txt') | Should -BeTrue    # installer is running now
            { [IO.File]::WriteAllBytes($b.Exe, [byte[]](1, 2, 3)) } | Should -Throw
            { Remove-Item -LiteralPath $b.Exe -Force -ErrorAction Stop } | Should -Throw
            { Rename-Item -LiteralPath $b.Exe -NewName 'evil.exe' -ErrorAction Stop } | Should -Throw
        } finally { $null = $ps.EndInvoke($async); $ps.Dispose() }
        (Get-UpdSha256 -Path $b.Exe) | Should -Be $b.Sha
    }
}

Describe 'Bundle store (keep 2) and rollback' {
    BeforeEach { $script:w = New-TestRoot; $script:data = Join-Path $script:w 'data'; New-Item -ItemType Directory $script:data | Out-Null; $script:sid = Get-CurrentSidValue; $env:FAKE_STATE = Join-Path $script:w 'state.txt' }
    AfterEach {
        Remove-Item Env:\FAKE_STATE, Env:\FAKE_REFUSE_DOWNGRADE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:w -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stores verified bundles, keeps the newest two, protects named ones' {
        foreach ($i in 1..4) {
            $b = New-DummyBundle (Join-Path $script:w 'src') ("s$i") (60100 + $i)
            [void](Add-VerifiedBundle -DataDir $script:data -Name ('v6.2.0-daily.{0}-vp.1' -f (100 + $i)) -SourcePath $b.Exe -Sha256 $b.Sha -BuildNumber $b.Build -AdditionalFullControlSids @($script:sid))
        }
        @(Get-VerifiedBundles -DataDir $script:data).Count | Should -Be 4
        Remove-ExcessBundles -DataDir $script:data -Keep 2 -Protect @('v6.2.0-daily.101-vp.1')
        $names = @(Get-VerifiedBundles -DataDir $script:data | ForEach-Object Name)
        $names | Should -Contain 'v6.2.0-daily.104-vp.1'
        $names | Should -Contain 'v6.2.0-daily.103-vp.1'
        $names | Should -Contain 'v6.2.0-daily.101-vp.1'
        $names | Should -Not -Contain 'v6.2.0-daily.102-vp.1'
    }
    It 'rejects bundle names that are not a tag or installed-BUILD' {
        $b = New-DummyBundle (Join-Path $script:w 'src') 's' 60100
        { Add-VerifiedBundle -DataDir $script:data -Name '..\evil' -SourcePath $b.Exe -Sha256 $b.Sha -BuildNumber 1 -AdditionalFullControlSids @($script:sid) } | Should -Throw '*invalid*'
    }
    It 'refuses to store a bundle whose hash does not match' {
        $b = New-DummyBundle (Join-Path $script:w 'src') 's' 60100
        { Add-VerifiedBundle -DataDir $script:data -Name 'installed-60100' -SourcePath $b.Exe -Sha256 ('1' * 64) -BuildNumber 60100 -AdditionalFullControlSids @($script:sid) } | Should -Throw '*mismatch*'
        @(Get-VerifiedBundles -DataDir $script:data).Count | Should -Be 0
    }
    It 'rollback: installs the previous bundle over the failed one' {
        $prev = New-DummyBundle $script:w 'prev' 60100; $bad = New-DummyBundle $script:w 'bad' 60202
        Set-Content $env:FAKE_STATE 60202
        $getV = { '6.2.{0}.0' -f (Get-Content $env:FAKE_STATE -Raw).Trim() }
        $res = Invoke-MoonlightRollback -Previous ([pscustomobject]@{ Name = 'installed-60100'; Path = $prev.Exe; Sha256 = $prev.Sha; Build = 60100 }) `
            -FailedBundlePath $bad.Exe -FailedSha256 $bad.Sha -RunDir $script:w -GetVersion $getV
        $res.Ok | Should -BeTrue; $res.Method | Should -Be 'install-over'
        (Get-Content $env:FAKE_STATE -Raw).Trim() | Should -Be '60100'
    }
    It 'rollback: when the installer refuses a downgrade, uninstalls the failed bundle first' {
        $env:FAKE_REFUSE_DOWNGRADE = '1'
        $prev = New-DummyBundle $script:w 'prev' 60100; $bad = New-DummyBundle $script:w 'bad' 60202
        Set-Content $env:FAKE_STATE 60202
        $getV = { if (Test-Path $env:FAKE_STATE) { '6.2.{0}.0' -f (Get-Content $env:FAKE_STATE -Raw).Trim() } else { $null } }
        $res = Invoke-MoonlightRollback -Previous ([pscustomobject]@{ Name = 'installed-60100'; Path = $prev.Exe; Sha256 = $prev.Sha; Build = 60100 }) `
            -FailedBundlePath $bad.Exe -FailedSha256 $bad.Sha -RunDir $script:w -GetVersion $getV
        $res.Ok | Should -BeTrue; $res.Method | Should -Be 'uninstall-then-install'
        (Get-Content $env:FAKE_STATE -Raw).Trim() | Should -Be '60100'
    }
    It 'rollback reports failure when the previous bundle cannot be restored' {
        $prev = New-DummyBundle $script:w 'prev' 60100 1603; $bad = New-DummyBundle $script:w 'bad' 60202
        Set-Content $env:FAKE_STATE 60202
        $getV = { '6.2.{0}.0' -f '60202' }
        $res = Invoke-MoonlightRollback -Previous ([pscustomobject]@{ Name = 'installed-60100'; Path = $prev.Exe; Sha256 = $prev.Sha; Build = 60100 }) `
            -FailedBundlePath $bad.Exe -FailedSha256 $bad.Sha -RunDir $script:w -GetVersion $getV
        $res.Ok | Should -BeFalse
    }
    It 'rollback refuses a previous bundle whose bytes changed on disk' {
        $prev = New-DummyBundle $script:w 'prev' 60100; $bad = New-DummyBundle $script:w 'bad' 60202
        Set-Content $env:FAKE_STATE 60202
        $fsT = [IO.File]::Open($prev.Exe, 'Append'); $fsT.WriteByte(1); $fsT.Dispose()
        $getV = { '6.2.60202.0' }
        $res = Invoke-MoonlightRollback -Previous ([pscustomobject]@{ Name = 'installed-60100'; Path = $prev.Exe; Sha256 = $prev.Sha; Build = 60100 }) `
            -FailedBundlePath $bad.Exe -FailedSha256 $bad.Sha -RunDir $script:w -GetVersion $getV
        $res.Ok | Should -BeFalse
        (Get-Content $env:FAKE_STATE -Raw).Trim() | Should -Not -Be '60100'
    }
}

Describe 'Process tree kill, Windows Installer idle wait, rollback idle checks (P2-1, P2-4)' {
    BeforeEach { $script:w = New-TestRoot; $env:FAKE_STATE = Join-Path $script:w 'state.txt' }
    AfterEach {
        Remove-Item Env:\FAKE_STATE, Env:\FAKE_REFUSE_DOWNGRADE -ErrorAction SilentlyContinue
        Get-Process -Name 'MlHang' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:w -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Invoke-UpdProcess on timeout kills the whole tree (a Burn-style child and grandchild) and reports TreeGone' {
        $src = @'
using System; using System.Diagnostics; using System.Threading;
class P { static int Main(string[] a) {
  if (a.Length > 0 && a[0] == "child") { if (a.Length < 2) Process.Start(new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location, "child grandchild") { UseShellExecute = false, CreateNoWindow = true }); Thread.Sleep(60000); return 0; }
  Process.Start(new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location, "child") { UseShellExecute = false, CreateNoWindow = true });
  Thread.Sleep(60000); return 0; } }
'@
        [IO.File]::WriteAllText((Join-Path $script:w 'h.cs'), $src)
        $exe = Join-Path $script:w 'MlHang.exe'
        & (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe "/out:$exe" (Join-Path $script:w 'h.cs') | Out-Null
        $r = Invoke-UpdProcess -FilePath $exe -ArgumentList @('/install') -TimeoutSec 3
        $r.TimedOut | Should -BeTrue
        $r.TreeGone | Should -BeTrue
        Start-Sleep -Milliseconds 500
        @(Get-Process -Name 'MlHang' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'Get-ProcessDescendantId finds children and grandchildren' {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ping -n 20 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 800
            @(Get-ProcessDescendantId -RootPid $p.Id).Count | Should -BeGreaterThan 0
        } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Get-Process -Name ping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    It 'Wait-MsiIdle: becomes idle when the probe frees up, gives up when it never does' {
        $script:n = 0
        (Wait-MsiIdle -TimeoutSec 10 -Probe { $script:n++; return ($script:n -lt 2) }) | Should -BeTrue
        (Wait-MsiIdle -TimeoutSec 1 -Probe { $true }) | Should -BeFalse
    }
    It 'Test-MsiBusy is $false when no Windows Installer transaction holds the mutex' {
        Test-MsiBusy | Should -BeFalse
    }
    It 'rollback refuses to touch anything when Moonlight is running (IdleCheck false)' {
        $prev = New-DummyBundle $script:w 'prev' 60100; $bad = New-DummyBundle $script:w 'bad' 60202
        Set-Content $env:FAKE_STATE 60202
        $res = Invoke-MoonlightRollback -Previous ([pscustomobject]@{ Name = 'installed-60100'; Path = $prev.Exe; Sha256 = $prev.Sha; Build = 60100 }) `
            -FailedBundlePath $bad.Exe -FailedSha256 $bad.Sha -RunDir $script:w -GetVersion { '6.2.60202.0' } -IdleCheck { $false }
        $res.Ok | Should -BeFalse; $res.Method | Should -Be 'moonlight-running'
        (Get-Content $env:FAKE_STATE -Raw).Trim() | Should -Be '60202'
        Test-Path (Join-Path $prev.Dir 'args.txt') | Should -BeFalse
    }
    It 'rollback stops before the uninstall step when Moonlight starts between the two attempts' {
        $env:FAKE_REFUSE_DOWNGRADE = '1'
        $prev = New-DummyBundle $script:w 'prev' 60100; $bad = New-DummyBundle $script:w 'bad' 60202
        Set-Content $env:FAKE_STATE 60202
        $script:idleCalls = 0
        $res = Invoke-MoonlightRollback -Previous ([pscustomobject]@{ Name = 'installed-60100'; Path = $prev.Exe; Sha256 = $prev.Sha; Build = 60100 }) `
            -FailedBundlePath $bad.Exe -FailedSha256 $bad.Sha -RunDir $script:w -GetVersion { '6.2.{0}.0' -f (Get-Content $env:FAKE_STATE -Raw).Trim() } -IdleCheck { $script:idleCalls++; return ($script:idleCalls -lt 2) }
        $res.Ok | Should -BeFalse; $res.Method | Should -Be 'moonlight-running'
        (Get-Content $env:FAKE_STATE -Raw).Trim() | Should -Be '60202'        # the (failed but working) new version was NOT uninstalled
        Test-Path (Join-Path $bad.Dir 'args.txt') | Should -BeFalse
    }
}
