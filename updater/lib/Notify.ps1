# Optional notifications (Google Chat webhook) and optional gh token, both kept in DPAPI (LocalMachine) blobs
# inside an admin-only secrets dir. Disabled by default (config notify_enabled=false, no blob present).
# A webhook URL on a device is spoof/spam-grade secret only (research/04 sec.4): treat chat as informational.

Set-StrictMode -Version Latest

try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { Write-Verbose 'System.Security preloaded' }

$script:SecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('MoonlightPatchUpdater/v1')

function Set-UpdSecret {
    <# Stores a secret as <data>\secrets\<name>.dpapi (DPAPI, machine scope). The plaintext never touches disk. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][ValidateSet('gchat-webhook', 'gh-token')][string]$Name,
        [Parameter(Mandatory)][System.Security.SecureString]$Value, [string[]]$AdditionalFullControlSids = @())
    $dir = Join-Path $DataDir 'secrets'
    Initialize-SecureDirectory -Path $dir -AdditionalFullControlSids $AdditionalFullControlSids
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $blob = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $script:SecretEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes((Join-Path $dir ($Name + '.dpapi')), $blob)
}

function Get-UpdSecret {
    <# Returns the plaintext string or $null when not provisioned / not decryptable. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][ValidateSet('gchat-webhook', 'gh-token')][string]$Name)
    $p = Join-Path (Join-Path $DataDir 'secrets') ($Name + '.dpapi')
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $blob = [System.IO.File]::ReadAllBytes($p)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $script:SecretEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch { return $null }
}

function Send-UpdNotification {
    <# Sanitised one-line message to the webhook. Never throws; returns $true when posted. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$Result, [string]$Tag = '', [string]$Detail = '')
    if ($Config['notify_enabled'] -ne $true) { return $false }
    $url = Get-UpdSecret -DataDir $DataDir -Name 'gchat-webhook'
    if (-not $url) { return $false }
    if (-not (Test-UpdRegex $url '^https://chat\.googleapis\.com/v1/spaces/[A-Za-z0-9_-]{1,40}/messages\?[A-Za-z0-9=&_%.-]{1,300}$')) { return $false }
    $safe = 'Moonlight updater on {0}: {1} {2} {3}' -f $env:COMPUTERNAME, (ConvertTo-SafeLogValue $Result 40), (ConvertTo-SafeLogValue $Tag 60), (ConvertTo-SafeLogValue $Detail 160)
    $body = (@{ text = $safe } | ConvertTo-Json -Compress)
    try {
        $c = New-Object System.Net.Http.HttpClient
        $c.Timeout = [TimeSpan]::FromSeconds(15)
        try {
            $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
            $resp = $c.PostAsync($url, $content).GetAwaiter().GetResult()
            return $resp.IsSuccessStatusCode
        } finally { $c.Dispose() }
    } catch { return $false }
}
