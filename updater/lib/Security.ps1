# ACL self-check, secure directory creation, per-run dirs, single-instance mutex, deny-write handle.

Set-StrictMode -Version Latest

$script:SidSystem = 'S-1-5-18'
$script:SidAdmins = 'S-1-5-32-544'
$script:SidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:SidCreatorOwner = 'S-1-3-0'
# Principals that may legitimately hold write access to the updater's directories.
$script:AclTrustedSids = @($script:SidSystem, $script:SidAdmins, $script:SidTrustedInstaller, $script:SidCreatorOwner)
# Always-hostile principals (reported by name in the violation text).
$script:AclLowPrivSids = @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-11', 'S-1-5-4', 'S-1-2-1', 'S-1-5-7', 'S-1-5-32-546')

# FileSystemRights bits that allow changing content or security.
$script:WriteRightsMask = [int](
    [System.Security.AccessControl.FileSystemRights]::WriteData -bor
    [System.Security.AccessControl.FileSystemRights]::AppendData -bor
    [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [System.Security.AccessControl.FileSystemRights]::Delete -bor
    [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [System.Security.AccessControl.FileSystemRights]::TakeOwnership)

function Find-AclViolation {
    <#
      Pure function over a FileSystemSecurity object. Returns a list of strings, empty when safe.
      Violation = (a) an Allow ACE granting any write-type right to a principal that is not
      SYSTEM / Administrators / TrustedInstaller / CREATOR OWNER, or (b) owner not in that set.
      Inherit-only ACEs are ignored for the object itself (they are checked on the children by
      recursing with -Path in Test-UpdAclSafe).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Security.AccessControl.FileSystemSecurity]$Security, [string]$Label = 'object')
    $v = New-Object System.Collections.Generic.List[string]
    $owner = $Security.GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($null -eq $owner -or ($script:AclTrustedSids -notcontains $owner.Value)) {
        $v.Add(("{0}: owner {1} is not SYSTEM/Administrators/TrustedInstaller" -f $Label, $owner))
    }
    foreach ($ace in $Security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($ace.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        $sid = $ace.IdentityReference.Value
        if ($script:AclTrustedSids -contains $sid) { continue }
        if (([int]$ace.FileSystemRights -band $script:WriteRightsMask) -ne 0) {
            $name = $sid
            try { $name = $ace.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { Write-Verbose "sid translate failed" }
            $v.Add(("{0}: {1} ({2}) has write-type rights {3}" -f $Label, $name, $sid, $ace.FileSystemRights))
        }
    }
    return , @($v.ToArray())
}

function Test-UpdAclSafe {
    <# Checks a file or directory via Get-Acl: for directories their files and (to -Depth levels) sub-directories, including reparse points. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path, [int]$Depth = 3)
    $all = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { $all.Add("$Path does not exist"); return , @($all.ToArray()) }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $all.Add("$Path is a reparse point (junction/symlink)")
        return , @($all.ToArray())
    }
    foreach ($x in (Find-AclViolation -Security (Get-Acl -LiteralPath $Path) -Label $Path)) { $all.Add($x) }
    if ($item.PSIsContainer) {
        foreach ($f in (Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
            foreach ($x in (Find-AclViolation -Security (Get-Acl -LiteralPath $f.FullName) -Label $f.FullName)) { $all.Add($x) }
        }
        if ($Depth -gt 0) {
            foreach ($dch in (Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($x in (Test-UpdAclSafe -Path $dch.FullName -Depth ($Depth - 1))) { $all.Add($x) }
            }
        }
    }
    return , @($all.ToArray())
}

function Assert-UpdSelfAcl {
    <# Aborts (throws) when script dir, update.ps1/libs or the data dir are writable by non-admins. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramDir, [Parameter(Mandatory)][string]$DataDir)
    $viol = New-Object System.Collections.Generic.List[string]
    $paths = @($ProgramDir, (Join-Path $ProgramDir 'lib'), $DataDir)
    foreach ($sub in 'bin') { $paths += (Join-Path $ProgramDir $sub) }
    foreach ($sub in 'logs', 'updates', 'bundles', 'cache', 'secrets', 'gh-config') { $paths += (Join-Path $DataDir $sub) }
    foreach ($p in $paths) {
        # optional sub-directories are only checked when present (the base dirs must exist)
        if (($p -ne $ProgramDir) -and ($p -ne $DataDir) -and ($p -ne (Join-Path $ProgramDir 'lib')) -and -not (Test-Path -LiteralPath $p)) { continue }
        foreach ($x in (Test-UpdAclSafe -Path $p)) { $viol.Add($x) }
    }
    if ($viol.Count -gt 0) {
        $e = New-Object System.Exception(('ACL self-check failed: ' + (($viol | Select-Object -First 5) -join ' | ')))
        $e.Data['AclViolations'] = $viol.ToArray()
        throw $e
    }
}

function New-AdminOnlySecurity {
    <# DirectorySecurity: SYSTEM + Administrators full, inheritance removed, owner Administrators.
       -AdditionalFullControlSids is for tests only (a non-admin sandbox user must keep access to its own temp dir). #>
    [CmdletBinding()]
    param([string[]]$AdditionalFullControlSids = @())
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $inh = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in (@($script:SidSystem, $script:SidAdmins) + $AdditionalFullControlSids)) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inh, 'None', 'Allow')
        $sec.AddAccessRule($rule)
    }
    return $sec
}

function Set-UpdDirectoryDacl {
    <# Writes only the DACL/protection (Set-Acl would also need SeSecurityPrivilege for the SACL).
       Windows PowerShell 5.1: DirectoryInfo.SetAccessControl; PowerShell 7: FileSystemAclExtensions. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Item, [Parameter(Mandatory)][System.Security.AccessControl.DirectorySecurity]$Security)
    if ($Item.PSObject.Methods['SetAccessControl']) { $Item.SetAccessControl($Security) }
    else { [System.IO.FileSystemAclExtensions]::SetAccessControl($Item, $Security) }
}

function Initialize-SecureDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$AdditionalFullControlSids = @())
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "refusing reparse point: $Path" }
    $sec = New-AdminOnlySecurity -AdditionalFullControlSids $AdditionalFullControlSids
    Set-UpdDirectoryDacl -Item $item -Security $sec
}

function New-UpdRunDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [string[]]$AdditionalFullControlSids = @())
    $updates = Join-Path $DataDir 'updates'
    Initialize-SecureDirectory -Path $updates -AdditionalFullControlSids $AdditionalFullControlSids
    $name = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N').Substring(0, 8)
    $run = Join-Path $updates $name
    New-Item -ItemType Directory -Path $run | Out-Null
    $sec = New-AdminOnlySecurity -AdditionalFullControlSids $AdditionalFullControlSids
    Set-UpdDirectoryDacl -Item (Get-Item -LiteralPath $run -Force) -Security $sec
    return $run
}

function Remove-OldRunDirectories {
    <# Keeps the newest -KeepLast run dirs (names sort by UTC timestamp) plus -Except; everything else is removed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [int]$KeepLast = 3, [string]$Except = '')
    $updates = Join-Path $DataDir 'updates'
    if (-not (Test-Path -LiteralPath $updates)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $updates -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    $i = 0
    foreach ($d in $dirs) {
        if ($d.FullName -eq $Except) { $i++; continue }
        $i++
        if ($i -le $KeepLast) { continue }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- single instance mutex ---------------------------------------------------------------------
function Enter-UpdMutex {
    <# Returns the Mutex object when acquired, $null when another instance owns it. #>
    [CmdletBinding()]
    param([string]$Name = $script:UpdConst.MutexName)
    $created = $false
    $m = New-Object System.Threading.Mutex($false, $Name, [ref]$created)
    $got = $false
    try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { $m.Dispose(); return $null }
    return $m
}

function Exit-UpdMutex {
    [CmdletBinding()]
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { Write-Verbose 'mutex release failed' }
    $Mutex.Dispose()
}

# ---- deny-write handle ---------------------------------------------------------------------------
function Open-DenyWriteHandle {
    <# Holds a read handle with FileShare.Read: nobody can open the file for write/delete/rename while held. #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}
