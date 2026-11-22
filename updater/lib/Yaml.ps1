# Minimal, strict YAML subset parser for policy.yml (PowerShell 5.1 has no YAML support).
# Supported: comments, `key: scalar`, nested maps by indentation (spaces only), block lists `- item`,
# flow lists `[a, b]`, flow maps `{k: v, k2: v2}`, single/double quoted scalars, true/false/null/int.
# NOT supported (rejected with an exception => caller fails closed): tabs, anchors/aliases, tags,
# multi-line scalars (| >), multiple documents, lists of maps.

Set-StrictMode -Version Latest

function ConvertFrom-YamlScalar {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $Text.Trim()
    if ($t -eq '' -or $t -eq '~' -or $t -eq 'null') { return $null }
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        $inner = $t.Substring(1, $t.Length - 2)
        return ($inner -replace '\\"', '"' -replace '\\\\', '\')
    }
    if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) {
        return $t.Substring(1, $t.Length - 2).Replace("''", "'")
    }
    if ($t -match '^[&*!|>]') { throw "unsupported yaml construct: $($t.Substring(0, 1))" }
    if ($t -ceq 'true') { return $true }
    if ($t -ceq 'false') { return $false }
    if ($t -match '^-?[0-9]{1,9}$') { return [int]$t }
    return $t
}

function Split-YamlFlow {
    # split on top-level commas (no nesting support inside flow collections beyond one level)
    param([string]$Text)
    $items = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $q = [char]0
    foreach ($ch in $Text.ToCharArray()) {
        if ($q -ne [char]0) {
            [void]$sb.Append($ch)
            if ($ch -eq $q) { $q = [char]0 }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $q = $ch; [void]$sb.Append($ch); continue }
        if ($ch -eq ',') { $items.Add($sb.ToString()); [void]$sb.Clear(); continue }
        [void]$sb.Append($ch)
    }
    if ($sb.Length -gt 0 -or $items.Count -gt 0) { $items.Add($sb.ToString()) }
    return , @($items.ToArray())
}

function ConvertFrom-YamlValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $Text.Trim()
    if ($t.StartsWith('[')) {
        if (-not $t.EndsWith(']')) { throw 'unterminated flow list' }
        $body = $t.Substring(1, $t.Length - 2).Trim()
        $list = New-Object System.Collections.Generic.List[object]
        if ($body -ne '') { foreach ($i in (Split-YamlFlow $body)) { $list.Add((ConvertFrom-YamlScalar $i)) } }
        return , @($list.ToArray())
    }
    if ($t.StartsWith('{')) {
        if (-not $t.EndsWith('}')) { throw 'unterminated flow map' }
        $body = $t.Substring(1, $t.Length - 2).Trim()
        $map = @{}
        if ($body -ne '') {
            foreach ($i in (Split-YamlFlow $body)) {
                $kv = $i.Split(':', 2)
                if ($kv.Count -ne 2) { throw 'bad flow map entry' }
                $k = (ConvertFrom-YamlScalar $kv[0])
                $map[[string]$k] = ConvertFrom-YamlScalar $kv[1]
            }
        }
        return $map
    }
    return (ConvertFrom-YamlScalar $t)
}

function Remove-YamlComment {
    param([string]$Line)
    $q = [char]0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($q -ne [char]0) { if ($ch -eq $q) { $q = [char]0 }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $q = $ch; continue }
        if ($ch -eq '#' -and ($i -eq 0 -or $Line[$i - 1] -eq ' ')) { return $Line.Substring(0, $i) }
    }
    return $Line
}

function ConvertFrom-YamlSubset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Contains("`t")) { throw 'tabs are not allowed in yaml' }
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($raw in ($Text -split "`r?`n")) {
        $l = (Remove-YamlComment $raw).TrimEnd()
        if ($l.Trim() -eq '') { continue }
        if ($l.Trim() -eq '---') { if ($lines.Count -gt 0) { throw 'multiple documents' } else { continue } }
        $indent = $l.Length - $l.TrimStart().Length
        $lines.Add([pscustomobject]@{ Indent = $indent; Text = $l.Trim() })
    }
    $st = @{ Pos = 0 }
    $parseBlock = $null
    $parseBlock = {
        param([int]$indent)
        $result = $null
        while ($st.Pos -lt $lines.Count) {
            $ln = $lines[$st.Pos]
            if ($ln.Indent -lt $indent) { break }
            if ($ln.Indent -gt $indent) { throw "unexpected indentation at line item '$($ln.Text)'" }
            if ($ln.Text.StartsWith('- ') -or $ln.Text -eq '-') {
                if ($null -eq $result) { $result = New-Object System.Collections.Generic.List[object] }
                if ($result -isnot [System.Collections.Generic.List[object]]) { throw 'mixed list and map' }
                $val = $ln.Text.Substring(1).Trim()
                if ($val -match '^[A-Za-z0-9_.-]+:(\s|$)' -and $val -notmatch '^[''"]') { throw 'list of maps is not supported' }
                $result.Add((ConvertFrom-YamlValue $val))
                $st.Pos++
                continue
            }
            $m = [regex]::Match($ln.Text, '^([A-Za-z0-9_.-]+):(?:\s+(.*))?$')
            if (-not $m.Success) { throw "unsupported yaml line '$($ln.Text)'" }
            if ($null -eq $result) { $result = @{} }
            if ($result -isnot [hashtable]) { throw 'mixed list and map' }
            $key = $m.Groups[1].Value
            if ($result.ContainsKey($key)) { throw "duplicate key $key" }
            $rest = ''
            if ($m.Groups[2].Success) { $rest = $m.Groups[2].Value }
            $st.Pos++
            if ($rest -eq '') {
                if ($st.Pos -lt $lines.Count -and $lines[$st.Pos].Indent -gt $indent) {
                    $result[$key] = & $parseBlock $lines[$st.Pos].Indent
                } elseif ($st.Pos -lt $lines.Count -and $lines[$st.Pos].Indent -eq $indent -and ($lines[$st.Pos].Text.StartsWith('- '))) {
                    # "key:" followed by list at the same indent (allowed YAML style)
                    $result[$key] = & $parseBlock $indent
                } else { $result[$key] = $null }
            } else {
                $result[$key] = ConvertFrom-YamlValue $rest
            }
        }
        if ($result -is [System.Collections.Generic.List[object]]) { return , @($result.ToArray()) }
        return $result
    }
    if ($lines.Count -eq 0) { return @{} }
    $doc = & $parseBlock $lines[0].Indent
    if ($st.Pos -lt $lines.Count) { throw 'trailing content could not be parsed' }
    return $doc
}
