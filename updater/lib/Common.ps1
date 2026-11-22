# Common helpers: constants, structured logging with secret scrubbing + rotation, exit codes.
# PowerShell 5.1 compatible. No Invoke-Expression anywhere in this code base.

Set-StrictMode -Version Latest

# ---- constants (CONTRACT section 1, 7) -------------------------------------------------------
$script:UpdConst = @{
    ProgramDir       = 'C:\Program Files\MoonlightPatchUpdater'
    DataDir          = 'C:\ProgramData\MoonlightPatchUpdater'
    TaskPath         = '\MoonlightPatch\'
    TaskName         = 'Update'
    MutexName        = 'Global\MoonlightPatchUpdater'
    BundleGuid       = '{7CA3BD1C-5B34-4D14-91A0-4277DD5E2063}'
    MoonlightExe     = 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe'
    MoonlightProcess = 'Moonlight'
    HkcuSubPath      = 'Software\Moonlight Game Streaming Project\Moonlight'
    TagRegex         = '^v6\.2\.0-daily\.[0-9]{1,5}-vp\.[0-9]{1,3}$'
    DefaultRepo      = 'emilwojcik93/moonlight-qt'
    DefaultApiBase   = 'https://api.github.com'
    DefaultDlBase    = 'https://github.com'
}

# Exit codes (documented in docs/UPDATER.md)
$script:UpdExit = @{
    Ok             = 0   # updated | noop | deferred | held | report-only | verified-only
    InternalError  = 1
    AclViolation   = 2   # self ACL check failed (script dir or data dir writable by non-admins)
    ConfigInvalid  = 3   # config/policy missing, invalid or unavailable: fail closed
    VerifyFailed   = 4   # a verification step failed, nothing installed
    RolledBack     = 5   # install failed health check, previous bundle restored
    RollbackFailed = 6   # install failed AND rollback failed (needs a human)
    AlreadyRunning = 7   # another instance holds the mutex
    NetworkDefer   = 8   # network error / rate limit: nothing done, will retry
}

# ---- value helpers ---------------------------------------------------------------------------
function Test-UpdRegex {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Pattern)
    if ($null -eq $Value) { return $false }
    # -cmatch: case sensitive; anchors in the patterns are the validation. Use [regex]::IsMatch so that
    # a trailing newline cannot sneak past '$' (RegexOptions.None, '$' matches before a final \n!).
    return [regex]::IsMatch($Value, $Pattern) -and ($Value -notmatch "[\r\n]")
}

function ConvertTo-SafeLogValue {
    <# Neutralises untrusted text before it reaches the log: control chars, PEM/cert/key material, tokens. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value, [int]$MaxLength = 400)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    # PEM markers of any kind (private key, certificate, ...): never allow them into a log.
    $s = [regex]::Replace($s, '-{0,5}BEGIN [A-Z0-9 ]*(PRIVATE KEY|CERTIFICATE|PUBLIC KEY)[A-Z0-9 ]*-{0,5}', '[REDACTED-PEM]')
    $s = [regex]::Replace($s, '-{0,5}END [A-Z0-9 ]*(PRIVATE KEY|CERTIFICATE|PUBLIC KEY)[A-Z0-9 ]*-{0,5}', '[REDACTED-PEM]')
    # base64 DER blobs (certificates start with MII...)
    $s = [regex]::Replace($s, 'MII[A-Za-z0-9+/=]{40,}', '[REDACTED-DER]')
    # GitHub tokens, chat webhooks
    $s = [regex]::Replace($s, '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}', '[REDACTED-TOKEN]')
    $s = [regex]::Replace($s, 'github_pat_[A-Za-z0-9_]{20,}', '[REDACTED-TOKEN]')
    $s = [regex]::Replace($s, 'https://chat\.googleapis\.com/\S+', '[REDACTED-WEBHOOK]')
    # control characters (log injection): CR/LF/TAB -> visible escapes, others dropped
    $s = $s.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    $s = [regex]::Replace($s, '[\x00-\x1F\x7F]', '?')
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength) + '...' }
    return $s
}

# ---- structured logging -----------------------------------------------------------------------
$script:UpdLog = @{ Dir = $null; RunId = ''; Path = $null; MaxBytes = 2MB; KeepDays = 30; Echo = $false }

function Initialize-UpdLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [string]$RunId = ([guid]::NewGuid().ToString('N').Substring(0, 8)),
        [switch]$Echo,
        [int]$MaxBytes = 2MB,
        [int]$KeepDays = 30
    )
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $script:UpdLog.Dir = $LogDir
    $script:UpdLog.RunId = $RunId
    $script:UpdLog.MaxBytes = $MaxBytes
    $script:UpdLog.KeepDays = $KeepDays
    $script:UpdLog.Echo = [bool]$Echo
    $script:UpdLog.Path = Join-Path $LogDir ('update-{0}.log' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'))
    Invoke-UpdLogRotation
}

function Invoke-UpdLogRotation {
    [CmdletBinding()]
    param()
    if (-not $script:UpdLog.Dir) { return }
    try {
        $cut = (Get-Date).AddDays(-$script:UpdLog.KeepDays)
        Get-ChildItem -LiteralPath $script:UpdLog.Dir -Filter 'update-*.log*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Write-Verbose "log rotation: $($_.Exception.Message)" }
}

function Write-UpdLog {
    <# Structured line: <utc-iso> <LEVEL> run=<id> event=<name> k="v" ... Values are scrubbed. #>
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][Alias('Event')][string]$EventName,
        [hashtable]$Data = @{}
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))
    $parts.Add($Level)
    $parts.Add('run=' + $script:UpdLog.RunId)
    $parts.Add('event=' + (ConvertTo-SafeLogValue $EventName 80))
    foreach ($k in ($Data.Keys | Sort-Object)) {
        $key = [regex]::Replace([string]$k, '[^A-Za-z0-9_]', '_')
        $parts.Add(('{0}="{1}"' -f $key, (ConvertTo-SafeLogValue $Data[$k])))
    }
    $line = $parts -join ' '
    if ($script:UpdLog.Echo) { Write-Host $line }
    if (-not $script:UpdLog.Path) { return }
    try {
        $p = $script:UpdLog.Path
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt $script:UpdLog.MaxBytes)) {
            $rolled = $p + '.1'
            if (Test-Path -LiteralPath $rolled) { Remove-Item -LiteralPath $rolled -Force }
            Move-Item -LiteralPath $p -Destination $rolled -Force
        }
        [System.IO.File]::AppendAllText($p, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Verbose "log write failed: $($_.Exception.Message)"
    }
}

# ---- misc -------------------------------------------------------------------------------------
function Get-UpdSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try { $h = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant()
}

function Get-UpdSha256FromStream {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        [void]$Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
        $h = $sha.ComputeHash($Stream)
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant()
}

function Get-UpdNowUtc { [OutputType([datetime])] param() return (Get-Date).ToUniversalTime() }
