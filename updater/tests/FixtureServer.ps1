# Loopback HTTP fixture (GitHub API + download stand-in) and a harmless stand-in for MoonlightSetup.exe.
# Dot-sourced from tests. Nothing here touches the network beyond 127.0.0.1.

Set-StrictMode -Version Latest

$script:DummyTemplatePath = $null

function Get-DummyInstallerTemplate {
    <# Compiles (once per process) a console exe that mimics the Burn bundle CLI. Behaviour is data-driven:
       overlay markers "BUILD=<n>;" and "RC=<n>;" appended to the exe bytes win, else sidecar build.txt/rc.txt files.
       State file: env FAKE_STATE (the "installed build number"). FAKE_SLEEP_MS delays;
       FAKE_REFUSE_DOWNGRADE=1 emulates Burn refusing a downgrade. #>
    if ($script:DummyTemplatePath -and (Test-Path $script:DummyTemplatePath)) { return $script:DummyTemplatePath }
    $dir = New-TestRoot
    $src = @'
using System; using System.IO; using System.Reflection; using System.Text; using System.Text.RegularExpressions;
[assembly: AssemblyFileVersion("6.2.60006.0")]
class P {
  static string Marker(string txt, string name) {
    int i = txt.LastIndexOf(name + "=", StringComparison.Ordinal); if (i < 0) return null;
    Match m = Regex.Match(txt.Substring(i), "^" + name + "=([0-9]+);"); return m.Success ? m.Groups[1].Value : null;
  }
  static int Main(string[] a) {
    string dir = AppDomain.CurrentDomain.BaseDirectory;
    string me = Encoding.GetEncoding(28591).GetString(File.ReadAllBytes(Assembly.GetExecutingAssembly().Location));
    File.WriteAllText(Path.Combine(dir, "args.txt"), string.Join("|", a));
    string state = Environment.GetEnvironmentVariable("FAKE_STATE");
    string build = Marker(me, "BUILD") ?? (File.Exists(Path.Combine(dir, "build.txt")) ? File.ReadAllText(Path.Combine(dir, "build.txt")).Trim() : "0");
    string rcs = Marker(me, "RC") ?? (File.Exists(Path.Combine(dir, "rc.txt")) ? File.ReadAllText(Path.Combine(dir, "rc.txt")).Trim() : "0");
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
    $cs = Join-Path $dir 'dummy.cs'; [IO.File]::WriteAllText($cs, $src)
    $exe = Join-Path $dir 'dummy-template.exe'
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:exe "/out:$exe" $cs | Out-Null
    if (-not (Test-Path $exe)) { throw 'could not compile the stand-in installer' }
    $script:DummyTemplatePath = $exe
    return $exe
}

function New-DummyInstallerBytes {
    param([int]$Build, [int]$Rc = 0)
    $t = [IO.File]::ReadAllBytes((Get-DummyInstallerTemplate))
    $m = [Text.Encoding]::ASCII.GetBytes(('BUILD={0};RC={1};' -f $Build, $Rc))
    return [byte[]]($t + $m)
}

function Start-FixtureServer {
    $tmp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $tmp.Start(); $port = $tmp.LocalEndpoint.Port; $tmp.Stop()
    $shared = [hashtable]::Synchronized(@{
            Port = $port; Requests = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            ReleasesJson = '[]'; ReleasesEtag = '"rel-1"'; PolicySha = ('e' * 40); PolicyText = "hold: false`nallow_upstream_owners: [Nonary]`ndeny: []`n"
            Files = [hashtable]::Synchronized(@{}); Mode = 'normal'; Listener = $null
        })
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript({
            param($S)
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$($S.Port)/")
            $l.Start(); $S.Listener = $l
            $repo = '/repos/emilwojcik93/moonlight-qt'
            function Send($ctx, [int]$status, [byte[]]$body, [hashtable]$headers) {
                $r = $ctx.Response; $r.StatusCode = $status
                if ($headers) { foreach ($k in $headers.Keys) { if ($k -eq 'Content-Type') { $r.ContentType = $headers[$k] } else { $r.Headers[$k] = $headers[$k] } } }
                if ($null -ne $body) { $r.ContentLength64 = $body.Length; $r.OutputStream.Write($body, 0, $body.Length) }
                $r.OutputStream.Close()
            }
            while ($l.IsListening) {
                try { $ctx = $l.GetContext() } catch { break }
                try {
                    $req = $ctx.Request; $path = $req.Url.AbsolutePath; $query = $req.Url.Query
                    [void]$S.Requests.Add(@{ Path = $path; Query = $query; Auth = $req.Headers['Authorization']; IfNoneMatch = $req.Headers['If-None-Match']; UA = $req.Headers['User-Agent'] })
                    $rl = @{ 'X-RateLimit-Remaining' = '55'; 'X-RateLimit-Limit' = '60' }
                    if ($S.Mode -eq 'ratelimit' -and $path.StartsWith('/repos/')) {
                        $h = @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = [string]([DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds()) }
                        Send $ctx 403 ([Text.Encoding]::UTF8.GetBytes('{"message":"API rate limit exceeded"}')) $h; continue
                    }
                    if ($S.Mode -eq 'bigbody' -and $path -eq "$repo/releases") {
                        $big = New-Object byte[] (6MB); Send $ctx 200 $big $rl; continue
                    }
                    if ($path -eq "$repo/releases") {
                        if ($req.Headers['If-None-Match'] -eq $S.ReleasesEtag) { $rl['ETag'] = $S.ReleasesEtag; Send $ctx 304 $null $rl; continue }
                        $rl['ETag'] = $S.ReleasesEtag; $rl['Content-Type'] = 'application/json'
                        Send $ctx 200 ([Text.Encoding]::UTF8.GetBytes($S.ReleasesJson)) $rl; continue
                    }
                    if ($path -eq "$repo/branches/automation") {
                        $et = '"br-' + $S.PolicySha + '"'
                        if ($req.Headers['If-None-Match'] -eq $et) { $rl['ETag'] = $et; Send $ctx 304 $null $rl; continue }
                        $rl['ETag'] = $et
                        $rl['Content-Type'] = 'application/json'
                        Send $ctx 200 ([Text.Encoding]::UTF8.GetBytes('{"name":"automation","commit":{"sha":"' + $S.PolicySha + '"}}')) $rl; continue
                    }
                    if ($path -eq "$repo/contents/policy.yml") {
                        if ($query -ne ('?ref=' + $S.PolicySha)) { Send $ctx 404 ([Text.Encoding]::UTF8.GetBytes('{"message":"Not Found"}')) $rl; continue }
                        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($S.PolicyText))
                        $rl['Content-Type'] = 'application/json'
                        Send $ctx 200 ([Text.Encoding]::UTF8.GetBytes('{"type":"file","encoding":"base64","content":"' + $b64 + '","sha":"abc"}')) $rl; continue
                    }
                    $prefix = '/emilwojcik93/moonlight-qt/releases/download/'
                    if ($path.StartsWith($prefix)) {
                        $key = $path.Substring($prefix.Length)
                        if ($S.Mode -eq 'redirect-evil') { Send $ctx 302 $null @{ Location = 'http://127.0.0.2:1/evil' }; continue }
                        if ($S.Files.ContainsKey($key)) { Send $ctx 200 ([byte[]]$S.Files[$key]) @{ 'Content-Type' = 'application/octet-stream' }; continue }
                    }
                    Send $ctx 404 ([Text.Encoding]::UTF8.GetBytes('not found')) $null
                } catch { try { $ctx.Response.Abort() } catch { $null = $_ } }
            }
        }).AddArgument($shared)
    $async = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $shared.Listener -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not $shared.Listener) { throw 'fixture server did not start' }
    return @{ Port = $port; Shared = $shared; Ps = $ps; Async = $async; Base = "http://127.0.0.1:$port" }
}

function Stop-FixtureServer {
    param($Server)
    try { $Server.Shared.Listener.Stop(); $Server.Shared.Listener.Close() } catch { $null = $_ }
    try { $Server.Ps.Stop() } catch { $null = $_ }
    try { $Server.Ps.Dispose() } catch { $null = $_ }
}

function Set-ServerReleases {
    param($Server, [object[]]$Fixtures)
    $Server.Shared.ReleasesJson = ConvertTo-Json -InputObject @($Fixtures | ForEach-Object { $_.Release }) -Depth 6
    foreach ($fx in $Fixtures) { foreach ($fname in $fx.Files.Keys) { $Server.Shared.Files[($fx.Tag + '/' + $fname)] = $fx.Files[$fname] } }
}
