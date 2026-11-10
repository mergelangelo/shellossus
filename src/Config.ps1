# Configuration, path validation, and security boundary helpers.
# Windows PowerShell 5.1 and ConstrainedLanguage compatible.

$script:RegisteredSkills = @{}

function Read-AgentConfig {
    param([string]$Path)
    $config = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $config }
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^(SHELLOSSUS_(?:BASE_URL|MODEL|API_KEY|WORKSPACE|CONTEXT_WINDOW|COMPACT_THRESHOLD|THEME))\s*=(.*)$') {
            throw "Invalid config entry at line $lineNumber. Expected a supported SHELLOSSUS_* key=value."
        }
        $normalizedKey = $Matches[1].ToUpper()
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        # Values are data. Never evaluate config as PowerShell code.
        $config[$normalizedKey] = $value
    }
    return $config
}

function Test-AgentPrivateWindowsAcl {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($acl.Sddl -notmatch '^O:(?<owner>[^:]+)G:[^:]+D:(?<dacl>[^:]+)(?:S:.*)?$') { return $false }
    $owner = $Matches.owner
    $dacl = $Matches.dacl
    $trusted = @('SY', 'BA', 'S-1-5-18', 'S-1-5-32-544')
    if ($env:USERDOMAIN -and $env:USERNAME -and $acl.Owner -ieq "$env:USERDOMAIN\$env:USERNAME") {
        $trusted += $owner
    }
    if ($owner -notin $trusted -or $dacl -notmatch '^(?:P|AI|AR)*(?<rules>(?:\([^()]+\))+)$') { return $false }
    foreach ($rule in ($Matches.rules.Trim('(', ')') -split '\)\(')) {
        $parts = $rule -split ';'
        if ($parts.Count -ne 6 -or $parts[0] -notin @('A', 'D')) { return $false }
        # Inherit-only rules do not grant access to this object. The file is checked separately.
        if ($parts[0] -eq 'A' -and $parts[1] -notmatch 'IO' -and $parts[5] -notin $trusted) { return $false }
    }
    return $true
}

function Test-AgentConfigPrivacy {
    param([string]$Path, [switch]$ParentOnly)
    try {
        $full = Format-ConfigPath -Path $Path
        if (-not $full -or $full -match '^[\\/]{2}' -or (Test-PathHasReparsePoint -Path $full)) { return $false }
        $parent = Get-Item -LiteralPath (Split-Path $full -Parent) -Force -ErrorAction Stop
        if (-not $parent.PSIsContainer) { return $false }
        if (-not $ParentOnly) {
            $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($file.PSIsContainer -or ($file.Attributes -band 1024)) { return $false }
        }
        if ($env:OS -eq 'Windows_NT') {
            if ($parent.PSDrive.DisplayRoot -match '^[\\/]{2}') { return $false }
            return ((Test-AgentPrivateWindowsAcl -Path $parent.FullName) -and ($ParentOnly -or (Test-AgentPrivateWindowsAcl -Path $file.FullName)))
        }
        if ($null -eq $parent.UnixFileMode -or $parent.User -cne [Environment]::UserName -or ([int]$parent.UnixFileMode -band 18)) {
            return $false
        }
        # Parent directories must not be replaceable by another user.
        $ancestorPath = Split-Path $parent.FullName -Parent
        while ($ancestorPath) {
            $ancestor = Get-Item -LiteralPath $ancestorPath -Force -ErrorAction Stop
            if ($null -eq $ancestor.UnixFileMode -or
                ($ancestor.User -cne [Environment]::UserName -and $ancestor.UnixStat.UserId -ne 0) -or
                (([int]$ancestor.UnixFileMode -band 18) -and -not ($ancestor.UnixStat.UserId -eq 0 -and $ancestor.UnixStat.IsSticky))) {
                return $false
            }
            $ancestorPath = Split-Path $ancestor.FullName -Parent
        }
        return ($ParentOnly -or ($null -ne $file.UnixFileMode -and $file.User -ceq [Environment]::UserName -and
            -not ([int]$file.UnixFileMode -band 63) -and $file.UnixStat.HardlinkCount -eq 1))
    }
    catch { return $false }
}

function Get-AgentConfiguredApiKey {
    param($Config)
    if ($env:SHELLOSSUS_API_KEY) { return $env:SHELLOSSUS_API_KEY }
    return $Config.SHELLOSSUS_API_KEY
}

function Read-AgentApiKey {
    param([string]$Prompt = 'API key')
    $secret = $null
    try {
        $secret = Read-Host -Prompt (Format-TuiText $Prompt) -AsSecureString -ErrorAction Stop
        if (-not $secret -or $secret.Length -eq 0) { return '' }
        return ([pscredential]::new('shellossus', $secret)).GetNetworkCredential().Password
    }
    catch { throw 'Hidden key input is unavailable. Set SHELLOSSUS_API_KEY in the environment.' }
    finally {
        if ($secret -is [securestring]) { $secret.Dispose() }
    }
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
    $Path = Format-ConfigPath -Path $Path
    $parent = Split-Path $Path -Parent
    if ($Config.SHELLOSSUS_API_KEY -and ($Path -match '^[\\/]{2}' -or (Test-PathHasReparsePoint -Path $Path))) {
        throw 'Choose a local config path without reparse points or use SHELLOSSUS_API_KEY from the environment.'
    }
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null }
    if (-not $Config.SHELLOSSUS_API_KEY) {
        Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -ErrorAction Stop
        return
    }

    $privacyError = 'Cannot verify private API key storage. Choose a private -ConfigPath or use SHELLOSSUS_API_KEY from the environment.'
    if (-not (Test-AgentConfigPrivacy -Path $Path -ParentOnly) -or (Test-Path -LiteralPath $Path -PathType Container)) {
        throw $privacyError
    }
    $stagePath = Join-Path $parent ('.config-' + $PID + '-' + (Get-Random -Minimum 10000000 -Maximum 99999999) + '.tmp')
    $stage = New-Item -ItemType File -Path $stagePath -ErrorAction Stop
    try {
        if ($env:OS -ne 'Windows_NT') {
            try { Set-ItemProperty -LiteralPath $stage.FullName -Name UnixFileMode -Value 384 -ErrorAction Stop }
            catch { throw $privacyError }
        }
        if (-not (Test-AgentConfigPrivacy -Path $stage.FullName)) { throw $privacyError }
        Set-Content -LiteralPath $stage.FullName -Value $lines -Encoding UTF8 -ErrorAction Stop
        if (-not (Test-AgentConfigPrivacy -Path $stage.FullName) -or (Test-PathHasReparsePoint -Path $Path) -or (Test-Path -LiteralPath $Path -PathType Container)) {
            throw $privacyError
        }
        Move-Item -LiteralPath $stage.FullName -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $stage.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-AgentUserRoot {
    if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
}

function Test-IsLoopbackHost {
    param([string]$HostName)
    if (-not $HostName) { return $false }
    $h = ($HostName -replace '^\[|\]$', '').Trim().ToLower()
    return ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -match '^(?:::1|(?:0{1,4}:){7}0{0,3}1)$')
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
            if (Test-IsLoopbackHost -HostName $uri.Host) {
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
        return (Test-IsLoopbackHost -HostName $uri.Host)
    }
    catch {
        return $false
    }
}

function Update-AgentConfigOptionalKey {
    param([string]$Path, [string]$Key, [string]$Value)
    if (-not $Path -or -not $Key) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
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
        if ($details.Length -le 16KB -and (Get-AgentUtf8ByteCount $details) -le 16KB) {
            try {
                $parsed = $details | ConvertFrom-Json -ErrorAction Stop
                if ($parsed.error -and $parsed.error.message) { $details = [string]$parsed.error.message }
            }
            catch {}
        }
        if ($details.Length -gt 300) { $details = $details.Substring(0, 300) + '...' }
        return ($msg + ' (' + $details + ')')
    }
    return $msg
}

function Format-PreviewText {
    param([string]$Text)
    return ($Text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]', '?')
}

function Format-TuiText {
    param([string]$Text, [switch]$Multiline)
    $clean = Format-PreviewText $Text
    if ($Multiline) { return ($clean -replace '\r\n', "`n" -replace '[\r\u2028\u2029]', '?' -replace '\t', '    ') }
    return ($clean -replace '\r\n|\n', '\n' -replace '\r', '\r' -replace '\t', '\t' -replace '[\u2028\u2029]', '?')
}

function Test-IsSecretFile {
    param($Item)
    if ($Item.PSIsContainer) { return $false }
    $cleanName = ($Item.Name -replace ':.*$', '').TrimEnd('.', ' ')
    $cleanFull = ($Item.FullName -replace '(?<!^[a-zA-Z]):.*$', '').TrimEnd('.', ' ')
    return ($cleanName -eq '.env' -or ($cleanName -like '.env.*' -and $cleanName -ne '.env.example') -or $cleanFull -eq $script:AgentConfigPath)
}

function Test-ValidPathSegment {
    param([string]$Segment, [ValidateSet('Directory','File')][string]$Kind)
    $invalid = (-not $Segment -or $Segment -eq '.' -or $Segment -eq '..' -or $Segment -match '[<>:"/\\|?*\x00-\x1f]' -or $Segment -match '[. ]$')
    $reserved = $Segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)'
    if ($Kind -eq 'Directory') {
        if ($invalid -or $reserved) { throw 'Invalid directory name.' }
        return
    }
    if ($invalid) { throw 'Invalid file name.' }
    if ($reserved) { throw 'Reserved file name.' }
}

function Resolve-ExistingPathAncestor {
    param([string]$Root, [string]$RelativePath)
    $missingNames = @()
    $currRel = $RelativePath
    while ($currRel) {
        $probeCand = if ($currRel -match '^([a-zA-Z]:[/\\]|[/\\])') { $currRel } else { Join-Path $Root $currRel }
        if (Test-Path -LiteralPath $probeCand) { break }
        $seg = Split-Path $currRel -Leaf
        Test-ValidPathSegment -Segment $seg -Kind Directory
        $missingNames = @($seg) + @($missingNames)
        $nextParent = Split-Path $currRel -Parent
        if (-not $nextParent -or $nextParent -eq $currRel) {
            $currRel = ''
            break
        }
        $currRel = $nextParent
    }
    $existingRel = if ($currRel) { $currRel } else { '.' }
    $existing = Resolve-AgentPath -Root $Root -RelativePath $existingRel
    return @{
        existing = $existing
        missing_names = @($missingNames)
    }
}

function Resolve-AgentWriteTarget {
    param([string]$Root, [string]$RelativePath)
    if ($RelativePath -match '[/\\]$') { throw 'Invalid file name.' }
    if (($RelativePath -replace '^[a-zA-Z]:(?=[/\\]|$)', '').Contains(':')) { throw 'Invalid path syntax.' }
    $rawParent = Split-Path $RelativePath -Parent
    $parentRel = if ($rawParent) { $rawParent } else { '.' }
    $ancestor = Resolve-ExistingPathAncestor -Root $Root -RelativePath $parentRel
    if (-not (Get-Item -LiteralPath $ancestor.existing -Force).PSIsContainer) { throw 'Parent must be a directory.' }
    $leaf = Split-Path $RelativePath -Leaf
    Test-ValidPathSegment -Segment $leaf -Kind File
    $parent = [string]$ancestor.existing
    $dirsToCreate = @()
    foreach ($dirName in @($ancestor.missing_names)) {
        $parent = Join-Path $parent $dirName
        $dirsToCreate += $parent
    }
    $fullPath = Join-Path $parent $leaf
    $cleanLeaf = ($leaf -replace ':.*$', '').TrimEnd('.', ' ')
    if ($cleanLeaf -eq '.env' -or ($cleanLeaf -like '.env.*' -and $cleanLeaf -ne '.env.example') -or $fullPath -eq $script:AgentConfigPath) {
        throw 'Agent tools cannot write credential configuration files.'
    }
    $exists = $false
    if (Test-Path -LiteralPath $fullPath) {
        $fullPath = Resolve-AgentPath -Root $Root -RelativePath $RelativePath
        $exists = $true
    }
    return @{
        full_path = [string]$fullPath
        parent = [string]$parent
        leaf = [string]$leaf
        dirs_to_create = @($dirsToCreate)
        exists = $exists
    }
}

function Test-AgentPathWithinRoot {
    param([string]$RootPath, [string]$TargetPath)
    $isWin = ($env:OS -eq 'Windows_NT')
    $isWinDrivePath = $isWin -and ($RootPath -match '^[a-zA-Z]:[/\\]')
    $prefix = if ($isWin) { $RootPath.TrimEnd('\').TrimEnd('/') } else { $RootPath.TrimEnd('/') }
    $targetNorm = if ($isWin) { $TargetPath.TrimEnd('\').TrimEnd('/') } else { $TargetPath.TrimEnd('/') }
    if ($isWinDrivePath) {
        if ($targetNorm -ieq $prefix) { return $true }
        if ($TargetPath.StartsWith($prefix + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($TargetPath.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        return $false
    }
    if ($targetNorm -ceq $prefix) { return $true }
    if ($TargetPath.StartsWith($prefix + '/', [StringComparison]::Ordinal)) { return $true }
    if ($isWin -and $TargetPath.StartsWith($prefix + '\', [StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-WorkspaceRelativePath {
    param([string]$Root, [string]$FullPath)
    $rootFull = if ($Root -and (Test-Path -LiteralPath $Root)) { (Get-Item -LiteralPath $Root -Force).FullName } else { $Root }
    $resolvedFull = if ($FullPath -and (Test-Path -LiteralPath $FullPath)) { (Get-Item -LiteralPath $FullPath -Force).FullName } else { $FullPath }
    $isWin = ($env:OS -eq 'Windows_NT')
    $isWinDrivePath = $isWin -and ($rootFull -match '^[a-zA-Z]:[/\\]')
    $rootNorm = if ($isWin) { $rootFull.TrimEnd('\').TrimEnd('/') } else { $rootFull.TrimEnd('/') }
    $fullNorm = if ($isWin) { $resolvedFull.TrimEnd('\').TrimEnd('/') } else { $resolvedFull.TrimEnd('/') }
    if ($isWinDrivePath) {
        if ($fullNorm -ieq $rootNorm) { return '.' }
        if ($resolvedFull.StartsWith($rootNorm + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $resolvedFull.StartsWith($rootNorm + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $resolvedFull.Substring($rootNorm.Length + 1).Replace('\', '/')
        }
        return $FullPath
    }
    if ($fullNorm -ceq $rootNorm) { return '.' }
    if ($resolvedFull.StartsWith($rootNorm + '/', [StringComparison]::Ordinal) -or
        ($isWin -and $resolvedFull.StartsWith($rootNorm + '\', [StringComparison]::Ordinal))) {
        return $resolvedFull.Substring($rootNorm.Length + 1).Replace('\', '/')
    }
    return $FullPath
}

function Test-PathHasReparsePoint {
    param([string]$Path, [string]$StopAt = '')
    if (-not $Path) { return $false }
    $stopNorm = ''
    if ($StopAt) {
        if (Test-Path -LiteralPath $StopAt) {
            $stopItem = Get-Item -LiteralPath $StopAt -Force -ErrorAction SilentlyContinue
            if ($stopItem) { $stopNorm = $stopItem.FullName.Replace('\', '/').TrimEnd('/') }
        }
        if (-not $stopNorm) {
            $stopNorm = $StopAt.Replace('\', '/').TrimEnd('/')
        }
    }
    $curr = $Path
    while ($curr) {
        $currNorm = $curr.Replace('\', '/').TrimEnd('/')
        if (Test-Path -LiteralPath $curr) {
            $item = Get-Item -LiteralPath $curr -Force -ErrorAction SilentlyContinue
            if ($item) {
                if (($item.Attributes -band 1024) -ne 0) { return $true }
                if ($stopNorm -and ($item.FullName.Replace('\', '/').TrimEnd('/') -ieq $stopNorm)) { break }
            }
        }
        if ($stopNorm -and ($currNorm -ieq $stopNorm)) { break }
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
    if (($RelativePath -replace '^[a-zA-Z]:(?=[/\\]|$)', '').Contains(':')) { throw 'Invalid path syntax.' }
    if ($AllowRegisteredSkill -and $script:RegisteredSkills -and $script:RegisteredSkills.Count -gt 0) {
        $skillTarget = $null
        $slash = $RelativePath.Replace('\', '/')
        if ($script:RegisteredSkills.ContainsKey($RelativePath)) {
            $skillTarget = $script:RegisteredSkills[$RelativePath]
        }
        elseif ($script:RegisteredSkills.ContainsKey($slash)) {
            $skillTarget = $script:RegisteredSkills[$slash]
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
            if (Test-PathHasReparsePoint -Path $skillItem.FullName) { throw 'Reparse points are not allowed.' }
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
    if (Test-PathHasReparsePoint -Path $item.FullName) { throw 'Reparse points are not allowed.' }
    return $item.FullName
}
