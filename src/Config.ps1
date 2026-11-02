# Configuration, path validation, and security boundary helpers.
# Windows PowerShell 5.1 and ConstrainedLanguage compatible.

function Read-AgentConfig {
    param([string]$Path)
    $config = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $config }
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^(H_AGENT_BASE_URL|H_AGENT_MODEL|H_AGENT_API_KEY|H_AGENT_WORKSPACE)\s*=(.*)$') {
            throw "Invalid config entry at line $lineNumber. Expected a supported H_AGENT_* key=value."
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        # Values are data. Never evaluate config as PowerShell code.
        $config[$key] = $value
    }
    return $config
}

function Save-AgentConfig {
    param([string]$Path, $Config)
    $lines = @('# h-agent settings. Contains an API key: do not commit or share.')
    foreach ($key in @('H_AGENT_BASE_URL', 'H_AGENT_MODEL', 'H_AGENT_API_KEY', 'H_AGENT_WORKSPACE')) {
        $value = [string]$Config[$key]
        if ($value -match "[`r`n]") { throw 'Config values must be single-line.' }
        # Quotes preserve paths, # and = without interpreting backslashes.
        if ($value.Contains('"')) { throw 'Config values cannot contain double quotes.' }
        $lines += $key + '="' + $value + '"'
    }
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -ErrorAction Stop
}

function Format-ConfigPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path -Force).FullName }
    $parent = Split-Path $Path -Parent
    $leaf = Split-Path $Path -Leaf
    if (-not $parent) { $parent = '.' }
    if (Test-Path -LiteralPath $parent) {
        return (Join-Path (Get-Item -LiteralPath $parent -Force).FullName $leaf)
    }
    return $Path
}

function Format-AgentError {
    param($ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    $details = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $details = $ErrorRecord.ErrorDetails.Message.Trim()
    }
    if ($details) {
        try {
            $parsed = $details | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error -and $parsed.error.message) { $details = [string]$parsed.error.message }
        }
        catch {}
        if ($details.Length -gt 300) { $details = $details.Substring(0, 300) + '...' }
        return ($msg + ' (' + $details + ')')
    }
    return $msg
}

function Format-PreviewText {
    param([string]$Text)
    return ($Text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]', '?')
}

function Test-IsSecretFile {
    param($Item)
    if ($Item.PSIsContainer) { return $false }
    return ($Item.Name -eq '.env' -or ($Item.Name -like '.env.*' -and $Item.Name -ne '.env.example') -or $Item.FullName -eq $script:AgentConfigPath)
}

function Get-WorkspaceRelativePath {
    param([string]$Root, [string]$FullPath)
    $prefix = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\') + '\'
    $resolvedFull = if (Test-Path -LiteralPath $FullPath) { (Get-Item -LiteralPath $FullPath -Force).FullName } else { $FullPath }
    if ($resolvedFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedFull.Substring($prefix.Length).Replace('\', '/')
    }
    return $FullPath
}

function Resolve-AgentPath {
    param([string]$Root, [string]$RelativePath)
    if (-not $RelativePath) { $RelativePath = '.' }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    $item = Get-Item -LiteralPath (Join-Path $rootItem.FullName $RelativePath) -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem') { throw 'Only filesystem paths are supported.' }
    if (Test-IsSecretFile $item) {
        throw 'Agent tools cannot access credential configuration files.'
    }
    $prefix = $rootItem.FullName.TrimEnd('\') + '\'
    if (($item.FullName -ne $rootItem.FullName) -and
        (-not $item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Path is outside the workspace.'
    }
    # Reject junctions/symlinks, including those in workspace ancestors.
    $cursor = $item
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band 1024) -ne 0) { throw 'Reparse points are not allowed.' }
        if ($cursor.PSIsContainer) { $cursor = $cursor.Parent }
        else { $cursor = $cursor.Directory }
    }
    return $item.FullName
}
