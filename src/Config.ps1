# Configuration, path validation, and security boundary helpers.
# Windows PowerShell 5.1 and ConstrainedLanguage compatible.

$script:RegisteredSkills = @{}

function Resolve-AgentConfigPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    if (Test-Path -LiteralPath $Path) { return $Path }
    $leaf = Split-Path $Path -Leaf
    $parent = Split-Path $Path -Parent
    if (($leaf -ieq '.env') -and $parent -and ((Split-Path $parent -Leaf) -ieq '.shellossus')) {
        $userRoot = Split-Path $parent -Parent
        if ($userRoot) {
            $legacyPath = Join-Path (Join-Path $userRoot '.h-agent') '.env'
            if (Test-Path -LiteralPath $legacyPath) { return $legacyPath }
        }
    }
    return $Path
}

function Read-AgentConfig {
    param([string]$Path)
    $config = @{}
    $legacyConfig = @{}
    $effectivePath = Resolve-AgentConfigPath -Path $Path
    if (-not $effectivePath -or -not (Test-Path -LiteralPath $effectivePath)) { return $config }
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $effectivePath -Encoding UTF8 -ErrorAction Stop)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^(?:(SHELLOSSUS|H_AGENT)_(BASE_URL|MODEL|API_KEY|WORKSPACE|CONTEXT_WINDOW|COMPACT_THRESHOLD|THEME))\s*=(.*)$') {
            throw "Invalid config entry at line $lineNumber. Expected a supported SHELLOSSUS_* key=value."
        }
        $prefix = $Matches[1].ToUpper()
        $suffix = $Matches[2].ToUpper()
        $normalizedKey = 'SHELLOSSUS_' + $suffix
        $value = $Matches[3].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        # Values are data. Never evaluate config as PowerShell code.
        if ($prefix -eq 'SHELLOSSUS') {
            $config[$normalizedKey] = $value
        }
        else {
            $legacyConfig[$normalizedKey] = $value
        }
    }
    foreach ($k in $legacyConfig.Keys) {
        if (-not $config.ContainsKey($k)) {
            $config[$k] = $legacyConfig[$k]
        }
    }
    return $config
}

function Save-AgentConfig {
    param([string]$Path, $Config)
    $lines = @('# shellossus settings. Contains an API key: do not commit or share.')
    foreach ($key in @('SHELLOSSUS_BASE_URL', 'SHELLOSSUS_MODEL', 'SHELLOSSUS_API_KEY', 'SHELLOSSUS_WORKSPACE')) {
        $value = [string]$Config[$key]
        if ($value -match "[`r`n]") { throw 'Config values must be single-line.' }
        # Quotes preserve paths, # and = without interpreting backslashes.
        if ($value.Contains('"')) { throw 'Config values cannot contain double quotes.' }
        $lines += $key + '="' + $value + '"'
    }
    foreach ($optKey in @('SHELLOSSUS_CONTEXT_WINDOW', 'SHELLOSSUS_COMPACT_THRESHOLD', 'SHELLOSSUS_THEME')) {
        if ($Config.ContainsKey($optKey) -and $Config[$optKey]) {
            $optVal = [string]$Config[$optKey]
            if ($optVal -match "[`r`n]" -or $optVal.Contains('"')) { throw 'Invalid optional config value.' }
            $lines += $optKey + '="' + $optVal + '"'
        }
    }
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -ErrorAction Stop
}

function Test-ValidAgentBaseUrl {
    param([string]$Url)
    if (-not $Url -or ($Url -notmatch '^https?://[^\s]+$')) { return $false }
    try {
        $uri = [uri]$Url
        if (-not $uri.IsAbsoluteUri -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            return $false
        }
        if ($uri.AbsolutePath -match '/(?:chat/completions|models)/?$') {
            return $false
        }
        if ($uri.Scheme -ieq 'https') {
            return $true
        }
        if ($uri.Scheme -ieq 'http') {
            $h = ($uri.Host -replace '^\[|\]$', '').Trim().ToLower()
            if ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -match '^(?:::1|(?:0{1,4}:){7}0{0,3}1)$') {
                return $true
            }
        }
    }
    catch {}
    return $false
}

function Test-IsLoopbackBaseUrl {
    param([string]$Url)
    if (-not (Test-ValidAgentBaseUrl -Url $Url)) { return $false }
    try {
        $uri = [uri]$Url
        $h = ($uri.Host -replace '^\[|\]$', '').Trim().ToLower()
        return ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -match '^(?:::1|(?:0{1,4}:){7}0{0,3}1)$')
    }
    catch {
        return $false
    }
}

function Update-AgentConfigOptionalKey {
    param([string]$Path, [string]$Key, [string]$Value)
    if (-not $Path -or -not $Key) { return $false }
    $effectivePath = Resolve-AgentConfigPath -Path $Path
    if (-not $effectivePath -or -not (Test-Path -LiteralPath $effectivePath)) { return $false }
    $cfg = @{}
    try {
        $cfg = Read-AgentConfig -Path $Path
        if (-not $cfg -or $cfg.Count -eq 0) { return $false }
        $cfg[$Key] = $Value
        Save-AgentConfig -Path $Path -Config $cfg
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($cfg) { $cfg.Clear() }
    }
}

function Format-ConfigPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path -Force).FullName }
    $segments = @()
    $curr = $Path
    for ($depth = 0; $depth -lt 64; $depth++) {
        if (-not $curr) { break }
        $leaf = Split-Path $curr -Leaf
        $parent = Split-Path $curr -Parent
        if ($leaf -and $leaf -ne '.') {
            $segments = @($leaf) + $segments
        }
        if (-not $parent) {
            if ($curr -notmatch '^([a-zA-Z]:[/\\]?|[/\\])$') { $curr = '.' }
            break
        }
        if ($parent -ieq $curr) { break }
        $curr = $parent
        while ((Split-Path $curr -Leaf) -eq '.') {
            $nextParent = Split-Path $curr -Parent
            if (-not $nextParent -or $nextParent -ieq $curr) {
                $curr = '.'
                break
            }
            $curr = $nextParent
        }
        if (Test-Path -LiteralPath $curr) { break }
    }
    $basePath = if ($curr -and (Test-Path -LiteralPath $curr)) {
        (Get-Item -LiteralPath $curr -Force).FullName
    }
    elseif ($curr -match '^[a-zA-Z]:[/\\]?$') {
        $curr
    }
    else {
        (Get-Item -LiteralPath (Get-Location).Path -Force).FullName
    }
    foreach ($seg in $segments) {
        $basePath = Join-Path $basePath $seg
    }
    return $basePath
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
    $cleanName = ($Item.Name -replace ':.*$', '').TrimEnd('.', ' ')
    $cleanFull = ($Item.FullName -replace '(?<!^[a-zA-Z]):.*$', '').TrimEnd('.', ' ')
    return ($cleanName -eq '.env' -or ($cleanName -like '.env.*' -and $cleanName -ne '.env.example') -or $cleanFull -eq $script:AgentConfigPath -or ($script:LegacyAgentConfigPath -and $cleanFull -eq $script:LegacyAgentConfigPath))
}

function Test-AgentPathWithinRoot {
    param([string]$RootPath, [string]$TargetPath)
    $isWin = ($env:OS -eq 'Windows_NT')
    $prefix = if ($isWin) { $RootPath.TrimEnd('\').TrimEnd('/') } else { $RootPath.TrimEnd('/') }
    $targetNorm = if ($isWin) { $TargetPath.TrimEnd('\').TrimEnd('/') } else { $TargetPath.TrimEnd('/') }
    if ($isWin) {
        if ($targetNorm -ieq $prefix) { return $true }
        if ($TargetPath.StartsWith($prefix + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($TargetPath.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        return $false
    }
    if ($targetNorm -ceq $prefix) { return $true }
    if ($TargetPath.StartsWith($prefix + '/', [StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-WorkspaceRelativePath {
    param([string]$Root, [string]$FullPath)
    $rootNorm = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\').TrimEnd('/')
    $resolvedFull = if (Test-Path -LiteralPath $FullPath) { (Get-Item -LiteralPath $FullPath -Force).FullName } else { $FullPath }
    if ($resolvedFull.StartsWith($rootNorm + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedFull.StartsWith($rootNorm + '/', [StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedFull.Substring($rootNorm.Length + 1).Replace('\', '/')
    }
    return $FullPath
}

function Test-PathHasReparsePoint {
    param([string]$Path, [string]$StopAt = '')
    if (-not $Path) { return $false }
    $stopNorm = ''
    if ($StopAt -and (Test-Path -LiteralPath $StopAt)) {
        $stopItem = Get-Item -LiteralPath $StopAt -Force -ErrorAction SilentlyContinue
        if ($stopItem) { $stopNorm = $stopItem.FullName.TrimEnd('\').TrimEnd('/') }
    }
    $curr = $Path
    for ($depth = 0; $depth -lt 64; $depth++) {
        if (-not $curr) { break }
        if (Test-Path -LiteralPath $curr) {
            $item = Get-Item -LiteralPath $curr -Force -ErrorAction SilentlyContinue
            if ($item) {
                if (($item.Attributes -band 1024) -ne 0) { return $true }
                if ($stopNorm -and ($item.FullName.TrimEnd('\').TrimEnd('/') -ieq $stopNorm)) { break }
            }
        }
        $parent = Split-Path $curr -Parent
        if (-not $parent -or ($parent -ieq $curr)) { break }
        $curr = $parent
    }
    return $false
}

function New-AgentTempFile {
    $baseTmp = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TMP) { $env:TMP } else { '/tmp' }
    if (-not (Test-Path -LiteralPath $baseTmp)) {
        New-Item -ItemType Directory -Path $baseTmp -Force -ErrorAction Stop | Out-Null
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $r1 = Get-Random -Minimum 100000 -Maximum 999999
        $r2 = Get-Random -Minimum 100000 -Maximum 999999
        $cand = Join-Path $baseTmp ("shellossus-$PID-$r1-$r2.tmp")
        if (-not (Test-Path -LiteralPath $cand)) {
            return (New-Item -ItemType File -Path $cand -ErrorAction Stop)
        }
    }
    throw 'Failed to allocate a unique temporary file.'
}

function Set-AgentUtf8Content {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [AllowEmptyString()][string]$Value = ''
    )
    if ($null -eq $Value -or $Value.Length -eq 0) {
        $null = New-Item -ItemType File -Path $LiteralPath -Force -ErrorAction Stop
    }
    elseif ($Value -notmatch '[^\x00-\x7F]') {
        Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding Ascii -NoNewline -ErrorAction Stop
    }
    else {
        Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding UTF8 -NoNewline -ErrorAction Stop
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $rawBytes = Get-Content -LiteralPath $LiteralPath -Encoding Byte -ReadCount 0 -ErrorAction Stop
            if ($rawBytes -is [array] -and $rawBytes.Count -eq 1 -and $rawBytes[0] -is [array]) {
                $rawBytes = $rawBytes[0]
            }
            if ($null -ne $rawBytes -and $rawBytes.Count -ge 3 -and $rawBytes[0] -eq 239 -and $rawBytes[1] -eq 187 -and $rawBytes[2] -eq 191) {
                if ($rawBytes.Count -eq 3) {
                    $null = New-Item -ItemType File -Path $LiteralPath -Force -ErrorAction Stop
                }
                else {
                    [byte[]]$stripped = $rawBytes[3..($rawBytes.Count - 1)]
                    Set-Content -LiteralPath $LiteralPath -Value $stripped -Encoding Byte -ErrorAction Stop
                }
            }
        }
    }
}

function Resolve-AgentPath {
    param([string]$Root, [string]$RelativePath, [switch]$AllowRegisteredSkill)
    if (-not $RelativePath) { $RelativePath = '.' }
    if (($RelativePath -replace '^[a-zA-Z]:', '').Contains(':')) { throw 'Invalid path syntax.' }
    if ($AllowRegisteredSkill -and $script:RegisteredSkills -and $script:RegisteredSkills.Count -gt 0) {
        $skillTarget = $null
        if ($script:RegisteredSkills.ContainsKey($RelativePath)) {
            $skillTarget = $script:RegisteredSkills[$RelativePath]
        }
        elseif (Test-Path -LiteralPath $RelativePath) {
            $candFull = (Get-Item -LiteralPath $RelativePath -Force -ErrorAction SilentlyContinue).FullName
            if ($candFull -and $script:RegisteredSkills.ContainsKey($candFull)) {
                $skillTarget = $script:RegisteredSkills[$candFull]
            }
        }
        if ($skillTarget -and (Test-Path -LiteralPath $skillTarget)) {
            $skillItem = Get-Item -LiteralPath $skillTarget -Force -ErrorAction Stop
            if ($skillItem.PSProvider.Name -ne 'FileSystem' -or $skillItem.PSIsContainer) { throw 'Invalid skill file.' }
            if (Test-IsSecretFile $skillItem) { throw 'Agent tools cannot access credential configuration files.' }
            $cursor = $skillItem
            while ($null -ne $cursor) {
                if (($cursor.Attributes -band 1024) -ne 0) { throw 'Reparse points are not allowed.' }
                if ($cursor.PSIsContainer) { $cursor = $cursor.Parent }
                else { $cursor = $cursor.Directory }
            }
            return $skillItem.FullName
        }
    }
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    $targetCandidate = if ($RelativePath -match '^([a-zA-Z]:[/\\]|[/\\])') {
        $RelativePath
    }
    else {
        Join-Path $rootItem.FullName $RelativePath
    }
    $item = Get-Item -LiteralPath $targetCandidate -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem') { throw 'Only filesystem paths are supported.' }
    if (Test-IsSecretFile $item) {
        throw 'Agent tools cannot access credential configuration files.'
    }
    if (-not (Test-AgentPathWithinRoot -RootPath $rootItem.FullName -TargetPath $item.FullName)) {
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
