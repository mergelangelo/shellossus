# Agent tools, permission modes, strict argument validation, fuzzy/batch file edits, shell runner, and disk undo.

$script:CurrentTurnWrites = @()
$script:AgentPermission = 'Ask'
$script:OutputMode = 'text'
$script:ShowReasoning = 'compact'
$script:ReasoningEffort = ''
$script:NoTools = $false
$script:EnabledTools = @()
$script:ExcludedTools = @()
$script:ActiveSessionId = ''
$script:ActiveSessionFile = ''
$script:ActiveModelId = ''
$script:Diagnostics = $false
$script:MaxRepeatToolCalls = 3
$script:ActiveWorkspace = ''
$script:ActiveEndpoint = ''
$script:ActiveApiKey = ''
$script:ActiveState = $null
$script:SubagentDepth = 0
$script:MaxSubagentDepth = 1
$script:ActiveSessionTodos = @()

function Resolve-ToolCanonicalName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $lower = $Name.Trim().ToLower()
    switch ($lower) {
        'read' { return 'read_file' }
        'ls' { return 'list_files' }
        'find' { return 'find_files' }
        'grep' { return 'grep_files' }
        'write' { return 'write_file' }
        'edit' { return 'edit_file' }
        'bash' { return 'run_command' }
        'powershell' { return 'run_command' }
        'subagent' { return 'run_agent' }
        'delegate' { return 'run_agent' }
        'delegate_task' { return 'run_agent' }
        'spawn_agent' { return 'run_agent' }
        'fetch' { return 'fetch_url' }
        'web_fetch' { return 'fetch_url' }
        'webfetch' { return 'fetch_url' }
        'search_web' { return 'web_search' }
        'websearch' { return 'web_search' }
        'todo' { return 'todo' }
        'todos' { return 'todo' }
        'manage_todo' { return 'todo' }
        'task_board' { return 'todo' }
        'tasks' { return 'todo' }
        default { return $lower }
    }
}

function Test-IsToolEnabled {
    param([string]$Name)
    $canon = Resolve-ToolCanonicalName -Name $Name
    if ($script:NoTools) { return $false }
    if ($canon -eq 'run_agent' -and $script:SubagentDepth -ge $script:MaxSubagentDepth) {
        return $false
    }
    if ($script:AgentPermission -eq 'ReadOnly' -and $canon -in @('write_file', 'edit_file', 'run_command')) {
        return $false
    }
    if ($script:EnabledTools -and $script:EnabledTools.Count -gt 0) {
        $matched = $false
        foreach ($pat in $script:EnabledTools) {
            $normPat = Resolve-ToolCanonicalName -Name $pat
            if ($canon -like $normPat -or $Name -like $pat) { $matched = $true; break }
        }
        if (-not $matched) { return $false }
    }
    if ($script:ExcludedTools -and $script:ExcludedTools.Count -gt 0) {
        foreach ($pat in $script:ExcludedTools) {
            $normPat = Resolve-ToolCanonicalName -Name $pat
            if ($canon -like $normPat -or $Name -like $pat) { return $false }
        }
    }
    return $true
}

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return "${Bytes}B" }
    if ($Bytes -lt 1048576) {
        $kb = [int](($Bytes * 10) / 1024)
        $frac = $kb % 10
        $whole = ($kb - $frac) / 10
        return "${whole}.${frac}KB"
    }
    $mb = [int](($Bytes * 10) / 1048576)
    $fracMb = $mb % 10
    $wholeMb = ($mb - $fracMb) / 10
    return "${wholeMb}.${fracMb}MB"
}

function Invoke-TruncateLine {
    param([string]$Line, [int]$MaxChars = 500)
    if ($null -eq $Line) { return @{ text = ''; wasTruncated = $false; was_truncated = $false } }
    if ($Line.Length -le $MaxChars) {
        return @{ text = $Line; wasTruncated = $false; was_truncated = $false }
    }
    return @{ text = ($Line.Substring(0, $MaxChars) + '... [truncated]'); wasTruncated = $true; was_truncated = $true }
}

function Invoke-TruncateHead {
    param([string]$Content, [int]$MaxLines = 2000, [int]$MaxBytes = 51200)
    if (-not $Content) {
        return @{
            content = ''
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = 0
            total_lines = 0
            totalBytes = 0
            total_bytes = 0
            outputLines = 0
            output_lines = 0
            outputBytes = 0
            output_bytes = 0
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $norm = $Content.Replace("`r`n", "`n")
    $lines = @($norm -split "`n")
    if ($norm.EndsWith("`n") -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $totalLines = $lines.Count
    $totalBytes = $norm.Length
    if ($totalLines -le $MaxLines -and $totalBytes -le $MaxBytes) {
        return @{
            content = $norm
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = $totalLines
            total_lines = $totalLines
            totalBytes = $totalBytes
            total_bytes = $totalBytes
            outputLines = $totalLines
            output_lines = $totalLines
            outputBytes = $totalBytes
            output_bytes = $totalBytes
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    if ($lines.Count -gt 0 -and ([string]$lines[0]).Length -gt $MaxBytes) {
        return @{
            content = ''
            truncated = $true
            truncatedBy = 'bytes'
            truncated_by = 'bytes'
            totalLines = $totalLines
            total_lines = $totalLines
            totalBytes = $totalBytes
            total_bytes = $totalBytes
            outputLines = 0
            output_lines = 0
            outputBytes = 0
            output_bytes = 0
            lastLinePartial = $false
            firstLineExceedsLimit = $true
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $outBytes = 0
    $truncBy = 'lines'
    $outLines = @(for ($i = 0; $i -lt $lines.Count -and $i -lt $MaxLines; $i++) {
        $ln = [string]$lines[$i]
        $lnBytes = $ln.Length + $(if ($i -gt 0) { 1 } else { 0 })
        if (($outBytes + $lnBytes) -gt $MaxBytes) {
            $truncBy = 'bytes'
            break
        }
        $outBytes += $lnBytes
        $ln
    })
    if ($outLines.Count -ge $MaxLines -and $outBytes -le $MaxBytes) {
        $truncBy = 'lines'
    }
    $outText = $outLines -join "`n"
    return @{
        content = $outText
        truncated = $true
        truncatedBy = $truncBy
        truncated_by = $truncBy
        totalLines = $totalLines
        total_lines = $totalLines
        totalBytes = $totalBytes
        total_bytes = $totalBytes
        outputLines = $outLines.Count
        output_lines = $outLines.Count
        outputBytes = $outText.Length
        output_bytes = $outText.Length
        lastLinePartial = $false
        firstLineExceedsLimit = $false
        maxLines = $MaxLines
        maxBytes = $MaxBytes
    }
}

function Invoke-TruncateTail {
    param([string]$Content, [int]$MaxLines = 2000, [int]$MaxBytes = 51200)
    if (-not $Content) {
        return @{
            content = ''
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = 0
            total_lines = 0
            totalBytes = 0
            total_bytes = 0
            outputLines = 0
            output_lines = 0
            outputBytes = 0
            output_bytes = 0
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $norm = $Content.Replace("`r`n", "`n")
    $lines = @($norm -split "`n")
    if ($norm.EndsWith("`n") -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $totalLines = $lines.Count
    $totalBytes = $norm.Length
    if ($totalLines -le $MaxLines -and $totalBytes -le $MaxBytes) {
        return @{
            content = $norm
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = $totalLines
            total_lines = $totalLines
            totalBytes = $totalBytes
            total_bytes = $totalBytes
            outputLines = $totalLines
            output_lines = $totalLines
            outputBytes = $totalBytes
            output_bytes = $totalBytes
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $outBytes = 0
    $truncBy = 'lines'
    $lastPartial = $false
    $revLines = @(for ($i = $lines.Count - 1; $i -ge 0 -and (($lines.Count - 1 - $i) -lt $MaxLines); $i--) {
        $ln = [string]$lines[$i]
        $isFirst = ($i -eq ($lines.Count - 1))
        $lnBytes = $ln.Length + $(if (-not $isFirst) { 1 } else { 0 })
        if (($outBytes + $lnBytes) -gt $MaxBytes) {
            $truncBy = 'bytes'
            if ($isFirst -and $ln.Length -gt $MaxBytes) {
                $lastPartial = $true
                $ln.Substring($ln.Length - $MaxBytes)
            }
            break
        }
        $outBytes += $lnBytes
        $ln
    })
    $outLines = @(for ($j = $revLines.Count - 1; $j -ge 0; $j--) {
        $revLines[$j]
    })
    if ($outLines.Count -ge $MaxLines -and $outBytes -le $MaxBytes) {
        $truncBy = 'lines'
    }
    $outText = $outLines -join "`n"
    return @{
        content = $outText
        truncated = $true
        truncatedBy = $truncBy
        truncated_by = $truncBy
        totalLines = $totalLines
        total_lines = $totalLines
        totalBytes = $totalBytes
        total_bytes = $totalBytes
        outputLines = $outLines.Count
        output_lines = $outLines.Count
        outputBytes = $outText.Length
        output_bytes = $outText.Length
        lastLinePartial = $lastPartial
        firstLineExceedsLimit = $false
        maxLines = $MaxLines
        maxBytes = $MaxBytes
    }
}

function Convert-IgnorePatternToRule {
    param([string]$Line, [string]$DirPrefix = '')
    $trimmed = $Line.Trim()
    if (-not $trimmed) { return $null }
    if ($trimmed.StartsWith('#') -and (-not $trimmed.StartsWith('\#'))) { return $null }
    $pat = $trimmed
    $negated = $false
    if ($pat.StartsWith('!')) {
        $negated = $true
        $pat = $pat.Substring(1)
    }
    elseif ($pat.StartsWith('\!') -or $pat.StartsWith('\#')) {
        $pat = $pat.Substring(1)
    }
    if (-not $pat) { return $null }
    $dirOnly = $pat.EndsWith('/')
    if ($dirOnly) { $pat = $pat.TrimEnd('/') }
    if (-not $pat) { return $null }
    $anchored = $pat.StartsWith('/')
    if ($anchored) { $pat = $pat.TrimStart('/') }
    if ($pat.Contains('/')) { $anchored = $true }
    $rx = $pat -replace '([.+^$()\[\]{}|\\])', '\$1'
    $rx = $rx -replace '/\*\*/', '__DBLSTAR_SLASH__'
    $rx = $rx -replace '^\*\*/', '__LEAD_DBLSTAR__'
    $rx = $rx -replace '/\*\*$', '__TRAIL_DBLSTAR__'
    $rx = $rx -replace '\*\*', '__ANY__'
    $rx = $rx -replace '\*', '[^/]*'
    $rx = $rx -replace '\?', '[^/]'
    $rx = $rx.Replace('__DBLSTAR_SLASH__', '(?:/.*)?/')
    $rx = $rx.Replace('__LEAD_DBLSTAR__', '(?:.+/)?')
    $rx = $rx.Replace('__TRAIL_DBLSTAR__', '(?:/.*)?')
    $rx = $rx.Replace('__ANY__', '.*')
    $prefRx = if ($DirPrefix) { ($DirPrefix -replace '([.+^$()\[\]{}|\\*?\-])', '\$1') } else { '' }
    $tailRx = if ($dirOnly) { '/.*$' } else { '(?:/.*)?$' }
    $finalRx = if ($anchored) {
        '^' + $prefRx + $rx + $tailRx
    }
    else {
        '^' + $prefRx + '(?:.+/)?' + $rx + $tailRx
    }
    return @{
        regex = $finalRx
        negated = $negated
        pattern = $trimmed
    }
}

function Compress-IgnoreRules {
    param([array]$Rules)
    if (-not $Rules -or $Rules.Count -eq 0) { return @() }
    if ($Rules.Count -eq 1 -and $Rules[0].combined) { return $Rules }
    $valid = @(foreach ($r in $Rules) {
        if ($null -ne $r -and $r.regex) { $r }
    })
    if ($valid.Count -eq 0) { return @() }
    $firstNeg = [bool]$valid[0].negated
    $allSame = $true
    foreach ($v in $valid) {
        if ([bool]$v.negated -ne $firstNeg) {
            $allSame = $false
            break
        }
    }
    if ($allSame) {
        $rxParts = @(foreach ($v in $valid) {
            if ($v.combined) { [string]$v.regex } else { "(?:$($v.regex))" }
        })
        return @(@{
            regex = ($rxParts -join '|')
            negated = $firstNeg
            combined = $true
        })
    }
    $segments = @()
    $startIdx = 0
    $currNeg = $firstNeg
    for ($i = 1; $i -le $valid.Count; $i++) {
        $isEnd = ($i -eq $valid.Count)
        $nextNeg = if (-not $isEnd) { [bool]$valid[$i].negated } else { (-not $currNeg) }
        if ($isEnd -or ($nextNeg -ne $currNeg)) {
            $rxParts = @(for ($j = $startIdx; $j -lt $i; $j++) {
                $item = $valid[$j]
                if ($item.combined) { [string]$item.regex } else { "(?:$($item.regex))" }
            })
            $segments += @{
                regex = ($rxParts -join '|')
                negated = $currNeg
                combined = $true
            }
            $startIdx = $i
            $currNeg = $nextNeg
        }
    }
    return $segments
}

function Read-DirectoryIgnoreRules {
    param([string]$RootFull, [string]$DirFull)
    $relDir = Get-WorkspaceRelativePath -Root $RootFull -FullPath $DirFull
    $dirPrefix = if ($DirFull -ieq $RootFull -or -not $relDir -or $relDir -eq '.') { '' } else { $relDir.Replace('\', '/').Trim('/') + '/' }
    $localRules = @(foreach ($igName in @('.gitignore', '.ignore', '.fdignore')) {
        $igFile = Join-Path $DirFull $igName
        if (-not (Test-Path -LiteralPath $igFile)) { continue }
        $igItem = Get-Item -LiteralPath $igFile -Force -ErrorAction SilentlyContinue
        if (-not $igItem -or $igItem.PSIsContainer -or (($igItem.Attributes -band 1024) -ne 0) -or $igItem.Length -gt 256KB) { continue }
        foreach ($line in @(Get-Content -LiteralPath $igFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $r = Convert-IgnorePatternToRule -Line ([string]$line) -DirPrefix $dirPrefix
            if ($null -ne $r) { $r }
        }
    })
    return $localRules
}

function Get-AncestorIgnoreRules {
    param([string]$RootFull, [string]$ScanDir)
    $ancestorsRev = @()
    $currDir = $ScanDir
    $guard = 0
    while ($currDir -and ($currDir -ine $RootFull) -and ($guard -lt 100)) {
        $guard++
        $parentDir = Split-Path $currDir -Parent
        if (-not $parentDir -or ($parentDir -ieq $currDir)) { break }
        $currDir = $parentDir.TrimEnd('\').TrimEnd('/')
        $ancestorsRev += $currDir
    }
    $ancestorDirs = @()
    for ($i = $ancestorsRev.Count - 1; $i -ge 0; $i--) {
        if (-not ($ancestorDirs -contains $ancestorsRev[$i])) {
            $ancestorDirs += $ancestorsRev[$i]
        }
    }
    if (($ScanDir -ine $RootFull) -and (-not ($ancestorDirs -contains $RootFull))) {
        $ancestorDirs = @($RootFull) + $ancestorDirs
    }
    $rawRules = @(foreach ($d in $ancestorDirs) {
        Read-DirectoryIgnoreRules -RootFull $RootFull -DirFull $d
    })
    return @(Compress-IgnoreRules -Rules $rawRules)
}

function Invoke-WorkspaceIgnoreScan {
    param([string]$RootFull, [string]$CurrentDir, [array]$ParentRules = @(), [int]$Depth = 0, [int]$MaxDepth = 64)
    if ($Depth -gt $MaxDepth) { return }
    $localRules = @(Read-DirectoryIgnoreRules -RootFull $RootFull -DirFull $CurrentDir)
    foreach ($lr in $localRules) { $lr }
    $activeRules = @(if ($localRules.Count -gt 0) {
        Compress-IgnoreRules -Rules (@($ParentRules) + $localRules)
    }
    else {
        $ParentRules
    })
    $subDirs = @(Get-ChildItem -LiteralPath $CurrentDir -Force -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)
    foreach ($sd in $subDirs) {
        if (($sd.Attributes -band 1024) -ne 0) { continue }
        if ($sd.Name -ieq '.git' -or $sd.Name -ieq 'node_modules') { continue }
        $relDir = Get-WorkspaceRelativePath -Root $RootFull -FullPath $sd.FullName
        if (Test-PathIgnored -RelativePath $relDir -IsDir $true -Rules $activeRules) { continue }
        Invoke-WorkspaceIgnoreScan -RootFull $RootFull -CurrentDir $sd.FullName -ParentRules $activeRules -Depth ($Depth + 1) -MaxDepth $MaxDepth
    }
}

function Get-WorkspaceIgnoreRules {
    param([string]$Root, [string]$SearchPath = '')
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return @() }
    $rootFull = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\').TrimEnd('/')
    $scanItem = if ($SearchPath -and (Test-Path -LiteralPath $SearchPath)) { Get-Item -LiteralPath $SearchPath -Force } else { Get-Item -LiteralPath $Root -Force }
    $scanDir = if ($scanItem.PSIsContainer) { $scanItem.FullName.TrimEnd('\').TrimEnd('/') } else { (Split-Path $scanItem.FullName -Parent).TrimEnd('\').TrimEnd('/') }
    $ancestorRules = @(Get-AncestorIgnoreRules -RootFull $rootFull -ScanDir $scanDir)
    $scannedRules = @(if ($scanItem.PSIsContainer) {
        Invoke-WorkspaceIgnoreScan -RootFull $rootFull -CurrentDir $scanDir -ParentRules $ancestorRules
    }
    else {
        Read-DirectoryIgnoreRules -RootFull $rootFull -DirFull $scanDir
    })
    return @(Compress-IgnoreRules -Rules ($ancestorRules + $scannedRules))
}

function Test-PathIgnored {
    param([string]$RelativePath, [bool]$IsDir, [array]$Rules)
    if (-not $Rules -or $Rules.Count -eq 0 -or -not $RelativePath) { return $false }
    $norm = $RelativePath.Replace('\', '/').TrimStart('/')
    $check = if ($IsDir) { $norm.TrimEnd('/') + '/' } else { $norm }
    $ignored = $false
    foreach ($r in $Rules) {
        $rNeg = [bool]$r.negated
        if ($rNeg -ne $ignored) { continue }
        if ($check -match $r.regex) {
            $ignored = (-not $rNeg)
        }
    }
    return $ignored
}

function Invoke-WorkspaceWalk {
    param(
        [string]$RootFull,
        [string]$CurrentDir,
        [array]$ParentRules = @(),
        [switch]$FilesOnly,
        [int]$Depth = 0,
        [int]$MaxDepth = 64
    )
    if ($Depth -gt $MaxDepth) { return }
    $localRules = @(Read-DirectoryIgnoreRules -RootFull $RootFull -DirFull $CurrentDir)
    $activeRules = @(if ($localRules.Count -gt 0) {
        Compress-IgnoreRules -Rules (@($ParentRules) + $localRules)
    }
    elseif ($Depth -eq 0 -and $ParentRules.Count -gt 0) {
        Compress-IgnoreRules -Rules $ParentRules
    }
    else {
        $ParentRules
    })
    $entries = @(Get-ChildItem -LiteralPath $CurrentDir -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    $dirsToEnter = @(foreach ($child in $entries) {
        if (($child.Attributes -band 1024) -ne 0) { continue }
        if ($child.PSIsContainer) {
            if ($child.Name -ieq '.git' -or $child.Name -ieq 'node_modules') { continue }
            $relDir = Get-WorkspaceRelativePath -Root $RootFull -FullPath $child.FullName
            if (Test-PathIgnored -RelativePath $relDir -IsDir $true -Rules $activeRules) { continue }
            if (-not $FilesOnly) {
                @{ item = $child; rel_path = $relDir; is_dir = $true }
            }
            $child
        }
        else {
            if (Test-IsSecretFile $child) { continue }
            $relFile = Get-WorkspaceRelativePath -Root $RootFull -FullPath $child.FullName
            if (Test-PathIgnored -RelativePath $relFile -IsDir $false -Rules $activeRules) { continue }
            @{ item = $child; rel_path = $relFile; is_dir = $false }
        }
    })
    foreach ($entryOrDir in $dirsToEnter) {
        if ($entryOrDir -is [hashtable]) {
            $entryOrDir
        }
        else {
            Invoke-WorkspaceWalk -RootFull $RootFull -CurrentDir $entryOrDir.FullName -ParentRules $activeRules -FilesOnly:$FilesOnly -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
    }
}

function Get-WorkspaceWalkEntries {
    param([string]$Root, [string]$SearchPath = '', [switch]$FilesOnly)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return @() }
    $rootFull = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\').TrimEnd('/')
    $scanItem = if ($SearchPath -and (Test-Path -LiteralPath $SearchPath)) { Get-Item -LiteralPath $SearchPath -Force } else { Get-Item -LiteralPath $Root -Force }
    if (-not $scanItem.PSIsContainer) {
        if (($scanItem.Attributes -band 1024) -ne 0 -or (Test-IsSecretFile $scanItem)) { return @() }
        $relFile = Get-WorkspaceRelativePath -Root $rootFull -FullPath $scanItem.FullName
        $rules = @(Get-WorkspaceIgnoreRules -Root $rootFull -SearchPath $scanItem.FullName)
        if (Test-PathIgnored -RelativePath $relFile -IsDir $false -Rules $rules) { return @() }
        return @(@{ item = $scanItem; rel_path = $relFile; is_dir = $false })
    }
    $scanDir = $scanItem.FullName.TrimEnd('\').TrimEnd('/')
    $ancestorRules = @(Get-AncestorIgnoreRules -RootFull $rootFull -ScanDir $scanDir)
    return @(Invoke-WorkspaceWalk -RootFull $rootFull -CurrentDir $scanDir -ParentRules $ancestorRules -FilesOnly:$FilesOnly)
}

function Get-AgentEnvironment {
    param([string]$Root = '')
    $effRoot = if ($Root) { $Root } elseif ($script:ActiveWorkspace) { $script:ActiveWorkspace } else { (Get-Location).Path }
    if ($effRoot -and (Test-Path -LiteralPath $effRoot)) {
        $item = Get-Item -LiteralPath $effRoot -Force -ErrorAction SilentlyContinue
        if ($item) { $effRoot = $item.FullName }
    }
    $osDesc = if ($PSVersionTable -and $PSVersionTable.OS) {
        [string]$PSVersionTable.OS
    }
    elseif ($env:OS) {
        [string]$env:OS
    }
    elseif ($PSVersionTable -and $PSVersionTable.Platform) {
        [string]$PSVersionTable.Platform
    }
    else {
        'Windows'
    }
    $psVer = if ($PSVersionTable -and $PSVersionTable.PSVersion) { [string]$PSVersionTable.PSVersion } else { '5.1' }
    $editionName = if ($PSVersionTable -and $PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
    $langMode = if ($ExecutionContext -and $ExecutionContext.SessionState -and $ExecutionContext.SessionState.LanguageMode) {
        [string]$ExecutionContext.SessionState.LanguageMode
    }
    else {
        'FullLanguage'
    }
    $preferPwsh = ($editionName -eq 'Core')
    $shellCmd = if ($preferPwsh) {
        $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command -Name 'powershell' -ErrorAction SilentlyContinue }
        $c
    }
    else {
        $c = Get-Command -Name 'powershell' -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue }
        $c
    }
    $shellExe = if ($shellCmd -and $shellCmd.Name) {
        if ($shellCmd.Name -match '(?i)^pwsh') { 'pwsh' } else { 'powershell' }
    }
    elseif ($preferPwsh) {
        'pwsh'
    }
    else {
        'powershell'
    }
    $shellVer = $psVer
    if ($shellCmd -and $shellCmd.Version -and ([string]$shellCmd.Version -ne '0.0.0.0')) {
        $shellVer = [string]$shellCmd.Version
    }
    return @{
        os = $osDesc
        ps_version = $psVer
        ps_edition = $editionName
        language_mode = $langMode
        shell_exe = $shellExe
        shell_version = $shellVer
        workspace = [string]$effRoot
    }
}

function Get-AgentCapabilities {
    param([string]$Root = '')
    $envInfo = Get-AgentEnvironment -Root $Root
    $perm = if ($script:AgentPermission -in @('ReadOnly', 'Ask', 'AutoEdit', 'Auto')) { $script:AgentPermission } else { 'Ask' }
    $tools = @()
    $toolNames = @()
    foreach ($name in @('list_files', 'read_file')) {
        if (-not (Test-IsToolEnabled -Name $name)) { continue }
        $description = 'List up to 200 entries in a directory. Names only; no file contents.'
        $properties = @{
            path = @{ type = 'string'; description = 'Workspace-relative path; . means the root.' }
        }
        if ($name -eq 'list_files') {
            $properties.limit = @{ type = 'integer'; description = 'Optional maximum number of entries to return (1..500, default 200).' }
        }
        if ($name -eq 'read_file') {
            $description = 'Read a UTF-8 text file: up to 300 lines and 20000 characters, maximum file size 1 MiB. Returns total_lines and pagination metadata.'
            $properties.start_line = @{ type = 'integer'; description = 'Optional 1-based first line to read (default 1).' }
            $properties.max_lines = @{ type = 'integer'; description = 'Optional maximum number of lines to read (1..300, default 300).' }
            $properties.start_char = @{ type = 'integer'; description = 'Optional 1-based character offset within start_line for reading long lines (default 1).' }
            $properties.offset = @{ type = 'integer'; description = 'Optional alias for start_line (1-based line offset).' }
            $properties.limit = @{ type = 'integer'; description = 'Optional alias for max_lines (1..300).' }
        }
        $toolNames += $name
        $tools += @{
            type = 'function'
            function = @{
                name = $name
                description = $description
                parameters = @{
                    type = 'object'
                    properties = $properties
                    required = @('path')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'find_files') {
        $toolNames += 'find_files'
        $tools += @{
            type = 'function'
            function = @{
                name = 'find_files'
                description = 'Find files or directories recursively by wildcard pattern (e.g. *.sql, src/*.ps1), respecting .gitignore/.ignore.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        path = @{ type = 'string'; description = 'Workspace-relative directory path; . means the root.' }
                        pattern = @{ type = 'string'; description = 'File name or relative path wildcard pattern, e.g. *.sql or src/*.ps1.' }
                        limit = @{ type = 'integer'; description = 'Optional maximum number of results (1..1000, default 200).' }
                    }
                    required = @('path', 'pattern')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'grep_files') {
        $toolNames += 'grep_files'
        $tools += @{
            type = 'function'
            function = @{
                name = 'grep_files'
                description = 'Search UTF-8 text files for a regex or literal pattern (respecting .gitignore/.ignore), returning matching paths, line numbers, and lines.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        path = @{ type = 'string'; description = 'Workspace-relative file or directory path; . means the root.' }
                        pattern = @{ type = 'string'; description = 'Regex or literal search pattern.' }
                        literal = @{ type = 'boolean'; description = 'Set true for literal substring match instead of regex.' }
                        case_sensitive = @{ type = 'boolean'; description = 'Set true for case-sensitive matching.' }
                        include = @{ type = 'string'; description = 'Optional file name wildcard filter, e.g. *.sql or *.ps1.' }
                        glob = @{ type = 'string'; description = 'Optional alias for include wildcard filter.' }
                        context_lines = @{ type = 'integer'; description = 'Optional surrounding context lines (0..5).' }
                        limit = @{ type = 'integer'; description = 'Optional maximum number of matches to return (1..500, default 100).' }
                        file_offset = @{ type = 'integer'; description = 'Optional 0-based file offset. To continue, use next_file_offset together with next_start_line from the previous result (default 0).' }
                        start_line = @{ type = 'integer'; description = 'Optional 1-based first matching line to include in the file at file_offset; later files start at line 1 (default 1).' }
                    }
                    required = @('path', 'pattern')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'fetch_url') {
        $toolNames += 'fetch_url'
        $tools += @{
            type = 'function'
            function = @{
                name = 'fetch_url'
                description = 'Fetch an HTTP/HTTPS URL and return readable text, Markdown, or JSON content (up to 20000 characters by default).'
                parameters = @{
                    type = 'object'
                    properties = @{
                        url = @{ type = 'string'; description = 'HTTP or HTTPS URL to fetch.' }
                        max_chars = @{ type = 'integer'; description = 'Optional maximum characters to return (500..50000, default 20000).' }
                        raw = @{ type = 'boolean'; description = 'Optional: set true to return raw HTML without tag stripping.' }
                    }
                    required = @('url')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'web_search') {
        $toolNames += 'web_search'
        $tools += @{
            type = 'function'
            function = @{
                name = 'web_search'
                description = 'Search the web for a query and return matching result titles, URLs, and snippets.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        query = @{ type = 'string'; description = 'Search query text.' }
                        limit = @{ type = 'integer'; description = 'Optional maximum number of results (1..20, default 8).' }
                    }
                    required = @('query')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'todo') {
        $toolNames += 'todo'
        $tools += @{
            type = 'function'
            function = @{
                name = 'todo'
                description = 'Track task plan and progress during multi-step work. Call this to initialize or update the active todo list (replaces entire list on each call).'
                parameters = @{
                    type = 'object'
                    properties = @{
                        todos = @{
                            type = 'array'
                            description = 'Complete ordered list of task items: array of {content, status}. Status must be pending, in_progress, or completed.'
                            items = @{
                                type = 'object'
                                properties = @{
                                    content = @{ type = 'string'; description = 'Clear, concise description of the task.' }
                                    status = @{ type = 'string'; description = 'Task status: pending, in_progress, or completed.' }
                                }
                                required = @('content', 'status')
                            }
                        }
                    }
                    required = @('todos')
                }
            }
        }
    }
    if ($perm -ne 'ReadOnly') {
        foreach ($name in @('write_file', 'edit_file')) {
            if (-not (Test-IsToolEnabled -Name $name)) { continue }
            $properties = @{ path = @{ type = 'string'; description = 'Workspace-relative text file path. Parent directory must exist.' } }
            if ($name -eq 'write_file') {
                $description = 'Create a UTF-8 text file (or overwrite when overwrite=true).'
                $properties.content = @{ type = 'string'; description = 'Complete file contents, up to 1 MiB.' }
                $properties.overwrite = @{ type = 'boolean'; description = 'Set true to overwrite an existing file (saves a backup).' }
                $required = @('path', 'content')
            }
            else {
                $description = 'Replace one or more unique blocks in a UTF-8 text file (supports single old_text/new_text or batch edits[] array; saves a backup).'
                $properties.old_text = @{ type = 'string'; description = 'Single edit: nonempty text occurring once in the file.' }
                $properties.new_text = @{ type = 'string'; description = 'Single edit: replacement text.' }
                $properties.edits = @{
                    type = 'array'
                    description = 'Optional batch of non-overlapping edits: array of {old_text, new_text} objects.'
                    items = @{
                        type = 'object'
                        properties = @{
                            old_text = @{ type = 'string' }
                            new_text = @{ type = 'string' }
                        }
                        required = @('old_text', 'new_text')
                    }
                }
                $required = @('path')
            }
            $toolNames += $name
            $tools += @{ type = 'function'; function = @{ name = $name; description = $description; parameters = @{ type = 'object'; properties = $properties; required = $required } } }
        }
        if (Test-IsToolEnabled -Name 'run_command') {
            $toolNames += 'run_command'
            $tools += @{
                type = 'function'
                function = @{
                    name = 'run_command'
                    description = 'Execute a PowerShell command in the workspace directory.'
                    parameters = @{
                        type = 'object'
                        properties = @{
                            command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                            timeout_sec = @{ type = 'integer'; description = 'Optional timeout in seconds (1..600, default 60).' }
                        }
                        required = @('command')
                    }
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'run_agent') {
        $toolNames += 'run_agent'
        $tools += @{
            type = 'function'
            function = @{
                name = 'run_agent'
                description = 'Delegate a task, parallel fan-out, or sequential pipeline to isolated subagents (roles: recon [ReadOnly], audit [ReadOnly], craft [inherits permission]). Keeps main context clean.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        role = @{ type = 'string'; description = 'Optional subagent role: recon (ReadOnly search), audit (ReadOnly review), craft (inherits permission), or custom role name.' }
                        prompt = @{ type = 'string'; description = 'Single-task instruction for the subagent (mutually exclusive with parallel and pipeline).' }
                        context = @{ type = 'string'; description = 'Optional context mode for single/pipeline tasks: clean (default, fresh context) or fork (clones parent conversation history).' }
                        max_steps = @{ type = 'integer'; description = 'Optional step budget per subagent run (1..50, default 15).' }
                        parallel = @{
                            type = 'array'
                            description = 'Concurrent ReadOnly fan-out tasks (1..8 items of {role, prompt}).'
                            items = @{
                                type = 'object'
                                properties = @{
                                    role = @{ type = 'string' }
                                    prompt = @{ type = 'string' }
                                }
                                required = @('prompt')
                            }
                        }
                        pipeline = @{
                            type = 'array'
                            description = 'Sequential pipeline steps (1..8 items of {role, prompt, context}); use {previous} or $PREVIOUS in prompt to reference prior step output.'
                            items = @{
                                type = 'object'
                                properties = @{
                                    role = @{ type = 'string' }
                                    prompt = @{ type = 'string' }
                                    context = @{ type = 'string' }
                                }
                                required = @('prompt')
                            }
                        }
                    }
                    required = @()
                }
            }
        }
    }
    $canRead = [bool]($toolNames | Where-Object { $_ -in @('list_files', 'read_file', 'find_files', 'grep_files') })
    $canWrite = [bool]($toolNames | Where-Object { $_ -in @('write_file', 'edit_file') })
    $canExec = ($toolNames -contains 'run_command')
    return @{
        permission = $perm
        no_tools = [bool]$script:NoTools
        enabled_filter = @($script:EnabledTools)
        excluded_filter = @($script:ExcludedTools)
        tool_names = $toolNames
        tools = $tools
        can_read = $canRead
        can_write = $canWrite
        can_exec = $canExec
        write_requires_confirmation = (($perm -eq 'Ask') -and $canWrite)
        exec_requires_confirmation = (($perm -in @('Ask', 'AutoEdit')) -and $canExec)
        environment = $envInfo
        signature = ("{0}|{1}" -f $perm, ($toolNames -join ','))
    }
}

function Get-AgentTools {
    return @((Get-AgentCapabilities).tools)
}

function Get-ObjectPropertyNames {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [hashtable]) { return @($InputObject.Keys) }
    return @(Get-Member -InputObject $InputObject -MemberType NoteProperty | ForEach-Object { $_.Name })
}

function Format-EditArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $out = @{}
    foreach ($p in $props) {
        if ($p -eq 'oldText') { $out['old_text'] = $Arguments.$p }
        elseif ($p -eq 'newText') { $out['new_text'] = $Arguments.$p }
        else { $out[$p] = $Arguments.$p }
    }
    if ($out.ContainsKey('edits') -and $null -ne $out['edits']) {
        $rawEdits = $out['edits']
        if ($rawEdits -is [string]) {
            try {
                $parsed = $rawEdits | ConvertFrom-Json -ErrorAction Stop
                if ($parsed -is [array]) { $rawEdits = $parsed }
                elseif ($null -ne $parsed) { $rawEdits = @($parsed) }
            }
            catch {}
        }
        elseif ($rawEdits -isnot [array] -and $rawEdits -isnot [ValueType]) {
            $edItemProps = @(Get-ObjectPropertyNames -InputObject $rawEdits)
            if (($edItemProps -contains 'old_text' -or $edItemProps -contains 'oldText') -and ($edItemProps -contains 'new_text' -or $edItemProps -contains 'newText')) {
                $rawEdits = @($rawEdits)
            }
        }
        if ($rawEdits -is [array]) {
            $normArr = @()
            foreach ($item in $rawEdits) {
                if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array]) {
                    $ip = @(Get-ObjectPropertyNames -InputObject $item)
                    $normItem = @{}
                    foreach ($k in $ip) {
                        if ($k -eq 'oldText') { $normItem['old_text'] = $item.$k }
                        elseif ($k -eq 'newText') { $normItem['new_text'] = $item.$k }
                        else { $normItem[$k] = $item.$k }
                    }
                    $normArr += $normItem
                }
                else {
                    $normArr += $item
                }
            }
            $out['edits'] = $normArr
        }
    }
    return $out
}

function Format-RunAgentArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $out = @{}
    foreach ($p in $props) {
        if ($p -eq 'task' -and ($props -notcontains 'prompt')) { $out['prompt'] = $Arguments.$p }
        elseif ($p -eq 'agent' -and ($props -notcontains 'role')) { $out['role'] = $Arguments.$p }
        elseif ($p -eq 'tasks' -and ($props -notcontains 'parallel')) { $out['parallel'] = $Arguments.$p }
        elseif (($p -eq 'chain' -or $p -eq 'steps') -and ($props -notcontains 'pipeline')) { $out['pipeline'] = $Arguments.$p }
        elseif ($p -eq 'maxSteps' -and ($props -notcontains 'max_steps')) { $out['max_steps'] = $Arguments.$p }
        else { $out[$p] = $Arguments.$p }
    }
    foreach ($arrField in @('parallel', 'pipeline')) {
        if ($out.ContainsKey($arrField) -and $null -ne $out[$arrField]) {
            $rawArr = $out[$arrField]
            if ($rawArr -is [string]) {
                try {
                    $parsed = $rawArr | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed -is [array]) { $rawArr = $parsed }
                    elseif ($null -ne $parsed) { $rawArr = @($parsed) }
                }
                catch {}
            }
            elseif ($rawArr -isnot [array] -and $rawArr -isnot [ValueType]) {
                $itemProps = @(Get-ObjectPropertyNames -InputObject $rawArr)
                if ($itemProps -contains 'prompt' -or $itemProps -contains 'task') {
                    $rawArr = @($rawArr)
                }
            }
            if ($rawArr -is [array]) {
                $normArr = @()
                foreach ($item in $rawArr) {
                    if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array]) {
                        $ip = @(Get-ObjectPropertyNames -InputObject $item)
                        $normItem = @{}
                        foreach ($k in $ip) {
                            if ($k -eq 'task' -and ($ip -notcontains 'prompt')) { $normItem['prompt'] = $item.$k }
                            elseif ($k -eq 'agent' -and ($ip -notcontains 'role')) { $normItem['role'] = $item.$k }
                            else { $normItem[$k] = $item.$k }
                        }
                        $normArr += $normItem
                    }
                    else {
                        $normArr += $item
                    }
                }
                $out[$arrField] = $normArr
            }
        }
    }
    return $out
}

function Format-TodoArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $out = @{}
    foreach ($p in $props) {
        if (($p -eq 'tasks' -or $p -eq 'items' -or $p -eq 'checklist') -and ($props -notcontains 'todos')) {
            $out['todos'] = $Arguments.$p
        }
        else {
            $out[$p] = $Arguments.$p
        }
    }
    if ($out.ContainsKey('todos') -and $null -ne $out['todos']) {
        $rawTodos = $out['todos']
        if ($rawTodos -is [string]) {
            try {
                $parsed = $rawTodos | ConvertFrom-Json -ErrorAction Stop
                if ($parsed -is [array]) { $rawTodos = $parsed }
                elseif ($null -ne $parsed) { $rawTodos = @($parsed) }
            }
            catch {}
        }
        elseif ($rawTodos -isnot [array] -and $rawTodos -isnot [ValueType]) {
            $rawTodos = @($rawTodos)
        }
        if ($rawTodos -is [array]) {
            $normArr = @()
            foreach ($item in $rawTodos) {
                if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array]) {
                    $ip = @(Get-ObjectPropertyNames -InputObject $item)
                    $normItem = @{}
                    foreach ($k in $ip) {
                        if (($k -eq 'task' -or $k -eq 'title' -or $k -eq 'text' -or $k -eq 'description') -and ($ip -notcontains 'content')) {
                            $normItem['content'] = $item.$k
                        }
                        elseif (($k -eq 'state' -or $k -eq 'done') -and ($ip -notcontains 'status')) {
                            if ($k -eq 'done' -and $item.$k -is [bool]) {
                                $normItem['status'] = if ($item.$k) { 'completed' } else { 'pending' }
                            }
                            else {
                                $normItem['status'] = $item.$k
                            }
                        }
                        else {
                            $normItem[$k] = $item.$k
                        }
                    }
                    $normArr += $normItem
                }
                else {
                    $normArr += $item
                }
            }
            $out['todos'] = $normArr
        }
    }
    return $out
}

function Test-AgentToolArguments {
    param([string]$Name, $Arguments)
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        throw 'Tool arguments must be a JSON object.'
    }
    $schemas = @{
        list_files = @{
            required = @('path')
            types = @{ path = 'string'; limit = 'integer' }
        }
        read_file = @{
            required = @('path')
            types = @{ path = 'string'; start_line = 'integer'; max_lines = 'integer'; start_char = 'integer'; offset = 'integer'; limit = 'integer' }
        }
        find_files = @{
            required = @('path', 'pattern')
            types = @{ path = 'string'; pattern = 'string'; limit = 'integer' }
        }
        grep_files = @{
            required = @('path', 'pattern')
            types = @{ path = 'string'; pattern = 'string'; literal = 'boolean'; case_sensitive = 'boolean'; include = 'string'; glob = 'string'; context_lines = 'integer'; limit = 'integer'; file_offset = 'integer'; start_line = 'integer' }
        }
        write_file = @{
            required = @('path', 'content')
            types = @{ path = 'string'; content = 'string'; overwrite = 'boolean' }
        }
        edit_file = @{
            required = @('path')
            types = @{ path = 'string'; old_text = 'string'; new_text = 'string'; edits = 'array' }
        }
        run_command = @{
            required = @('command')
            types = @{ command = 'string'; timeout_sec = 'integer' }
        }
        run_agent = @{
            required = @()
            types = @{ role = 'string'; prompt = 'string'; context = 'string'; max_steps = 'integer'; parallel = 'array'; pipeline = 'array' }
        }
        fetch_url = @{
            required = @('url')
            types = @{ url = 'string'; max_chars = 'integer'; raw = 'boolean' }
        }
        web_search = @{
            required = @('query')
            types = @{ query = 'string'; limit = 'integer' }
        }
        todo = @{
            required = @('todos')
            types = @{ todos = 'array' }
        }
    }
    $schema = $schemas[$Name]
    if (-not $schema) { throw 'Unknown tool.' }
    $propNames = @(Get-ObjectPropertyNames -InputObject $Arguments)
    foreach ($p in $propNames) {
        if ($schema.types.Keys -notcontains $p) {
            throw "Unknown argument '$p' for tool '$Name'."
        }
    }
    foreach ($req in $schema.required) {
        if ($propNames -notcontains $req -or $null -eq $Arguments.$req) {
            throw "Missing required argument '$req' for tool '$Name'."
        }
    }
    foreach ($p in $propNames) {
        $val = $Arguments.$p
        if ($null -eq $val) { continue }
        $expectedType = $schema.types[$p]
        if ($expectedType -eq 'string') {
            if ($val -isnot [string]) { throw "Argument '$p' must be a string." }
        }
        elseif ($expectedType -eq 'boolean') {
            if ($val -isnot [bool]) { throw "Argument '$p' must be a boolean." }
        }
        elseif ($expectedType -eq 'integer') {
            if (($val -isnot [int] -and $val -isnot [long]) -or ($val -is [bool])) {
                throw "Argument '$p' must be an integer."
            }
        }
        elseif ($expectedType -eq 'array') {
            if ($val -isnot [array]) { throw "Argument '$p' must be an array." }
        }
    }
    if ($Name -eq 'edit_file') {
        $hasEdits = ($propNames -contains 'edits' -and $null -ne $Arguments.edits)
        $hasSingle = ($propNames -contains 'old_text' -or $propNames -contains 'new_text')
        if ($hasEdits -and $hasSingle) {
            throw 'Provide either old_text/new_text or edits[], not both.'
        }
        if ($hasEdits) {
            if ($Arguments.edits.Count -eq 0) { throw 'edits array must not be empty.' }
            foreach ($ed in $Arguments.edits) {
                if ($null -eq $ed -or $ed -is [string] -or $ed -is [ValueType] -or $ed -is [array]) {
                    throw 'Each edit in edits[] must be an object.'
                }
                $edProps = @(Get-ObjectPropertyNames -InputObject $ed)
                foreach ($ep in $edProps) {
                    if ($ep -notin @('old_text', 'new_text')) {
                        throw "Unknown property '$ep' in edits[] item."
                    }
                }
                if ($edProps -notcontains 'old_text' -or $edProps -notcontains 'new_text' -or $ed.old_text -isnot [string] -or -not $ed.old_text -or $ed.new_text -isnot [string]) {
                    throw 'Each edit must have nonempty string old_text and string new_text.'
                }
            }
        }
        else {
            if ($propNames -notcontains 'old_text' -or $propNames -notcontains 'new_text' -or $Arguments.old_text -isnot [string] -or -not $Arguments.old_text -or $Arguments.new_text -isnot [string]) {
                throw 'Expected nonempty old_text and string new_text.'
            }
        }
    }
    if ($Name -eq 'run_agent') {
        $hasPrompt = ($propNames -contains 'prompt' -and $null -ne $Arguments.prompt)
        $hasParallel = ($propNames -contains 'parallel' -and $null -ne $Arguments.parallel)
        $hasPipeline = ($propNames -contains 'pipeline' -and $null -ne $Arguments.pipeline)
        $modeCount = ($(if ($hasPrompt) { 1 } else { 0 }) + $(if ($hasParallel) { 1 } else { 0 }) + $(if ($hasPipeline) { 1 } else { 0 }))
        if ($modeCount -eq 0) {
            throw 'run_agent requires one of: prompt, parallel[], or pipeline[].'
        }
        if ($modeCount -gt 1) {
            throw 'Provide only one execution mode: prompt, parallel[], or pipeline[].'
        }
        if ($propNames -contains 'context' -and $null -ne $Arguments.context) {
            if ($Arguments.context -notin @('clean', 'fork')) {
                throw "Argument 'context' must be 'clean' or 'fork'."
            }
            if ($hasParallel -and $Arguments.context -eq 'fork') {
                throw "Argument 'context' cannot be 'fork' when using parallel[]."
            }
        }
        if ($propNames -contains 'max_steps' -and $null -ne $Arguments.max_steps) {
            if ($Arguments.max_steps -lt 1 -or $Arguments.max_steps -gt 50) {
                throw 'max_steps must be between 1 and 50.'
            }
        }
        if ($hasPrompt) {
            if (-not $Arguments.prompt.Trim()) {
                throw 'prompt must be a nonempty string.'
            }
        }
        if ($hasParallel) {
            if ($Arguments.parallel.Count -lt 1 -or $Arguments.parallel.Count -gt 8) {
                throw 'parallel[] must contain between 1 and 8 tasks.'
            }
            foreach ($pt in $Arguments.parallel) {
                if ($null -eq $pt -or $pt -is [string] -or $pt -is [ValueType] -or $pt -is [array]) {
                    throw 'Each task in parallel[] must be an object.'
                }
                $ptProps = @(Get-ObjectPropertyNames -InputObject $pt)
                foreach ($pp in $ptProps) {
                    if ($pp -notin @('role', 'prompt')) {
                        throw "Unknown property '$pp' in parallel[] item."
                    }
                }
                if ($ptProps -notcontains 'prompt' -or $pt.prompt -isnot [string] -or -not $pt.prompt.Trim()) {
                    throw 'Each task in parallel[] must have a nonempty string prompt.'
                }
                if ($ptProps -contains 'role' -and $null -ne $pt.role -and $pt.role -isnot [string]) {
                    throw "Property 'role' in parallel[] item must be a string."
                }
            }
        }
        if ($hasPipeline) {
            if ($Arguments.pipeline.Count -lt 1 -or $Arguments.pipeline.Count -gt 8) {
                throw 'pipeline[] must contain between 1 and 8 steps.'
            }
            foreach ($ps in $Arguments.pipeline) {
                if ($null -eq $ps -or $ps -is [string] -or $ps -is [ValueType] -or $ps -is [array]) {
                    throw 'Each step in pipeline[] must be an object.'
                }
                $psProps = @(Get-ObjectPropertyNames -InputObject $ps)
                foreach ($sp in $psProps) {
                    if ($sp -notin @('role', 'prompt', 'context')) {
                        throw "Unknown property '$sp' in pipeline[] item."
                    }
                }
                if ($psProps -notcontains 'prompt' -or $ps.prompt -isnot [string] -or -not $ps.prompt.Trim()) {
                    throw 'Each step in pipeline[] must have a nonempty string prompt.'
                }
                if ($psProps -contains 'role' -and $null -ne $ps.role -and $ps.role -isnot [string]) {
                    throw "Property 'role' in pipeline[] item must be a string."
                }
                if ($psProps -contains 'context' -and $null -ne $ps.context) {
                    if ($ps.context -isnot [string] -or $ps.context -notin @('clean', 'fork')) {
                        throw "Property 'context' in pipeline[] item must be 'clean' or 'fork'."
                    }
                }
            }
        }
    }
    if ($Name -eq 'todo') {
        if ($null -eq $Arguments.todos -or $Arguments.todos -isnot [array]) {
            throw 'todos must be an array.'
        }
        foreach ($item in $Arguments.todos) {
            if ($null -eq $item -or $item -is [string] -or $item -is [ValueType] -or $item -is [array]) {
                throw 'Each item in todos[] must be an object with content and status.'
            }
            $itemProps = @(Get-ObjectPropertyNames -InputObject $item)
            foreach ($ip in $itemProps) {
                if ($ip -notin @('content', 'status')) {
                    throw "Unknown property '$ip' in todo item."
                }
            }
            if ($itemProps -notcontains 'content' -or $item.content -isnot [string] -or -not $item.content.Trim()) {
                throw 'Each todo item must have a nonempty string content.'
            }
            if ($itemProps -notcontains 'status' -or $item.status -isnot [string] -or $item.status.ToLower() -notin @('pending', 'in_progress', 'completed')) {
                throw "Each todo item must have status 'pending', 'in_progress', or 'completed'."
            }
        }
    }
}

function Get-AgentProcessParents {
    if ($env:OS -eq 'Windows_NT') {
        # Built-in CIM cmdlets work in Windows PowerShell 5.1/ConstrainedLanguage.
        # Get-Process only exposes Parent in newer PowerShell versions.
        $startTimes = @{}
        foreach ($p in @(Get-Process -ErrorAction Stop)) {
            try {
                if ($p.StartTime) { $startTimes[[string]$p.Id] = $p.StartTime.Ticks }
            }
            catch { }
        }
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -OperationTimeoutSec 2 -ErrorAction Stop)) {
            $key = [string]$p.ProcessId
            if ($startTimes.ContainsKey($key)) {
                @{ id = [int]$p.ProcessId; parent_id = [int]$p.ParentProcessId; start_ticks = $startTimes[$key] }
            }
        }
    }
    else {
        foreach ($p in @(Get-Process -ErrorAction Stop)) {
            try {
                $parent = $p.Parent
                if ($parent) { @{ id = [int]$p.Id; parent_id = [int]$parent.Id; start_ticks = $p.StartTime.Ticks } }
            }
            catch { } # Processes can exit while the snapshot is being collected.
        }
    }
}

function Update-AgentProcessTree {
    param([hashtable]$Tracked)
    $parents = @(Get-AgentProcessParents)
    $live = @{}
    foreach ($key in @($Tracked.Keys)) {
        $p = Get-Process -Id $Tracked[$key].id -ErrorAction SilentlyContinue
        if ($p) {
            try {
                if ($p.StartTime.Ticks -eq $Tracked[$key].start_ticks) { $live[$key] = $true }
            }
            catch { }
        }
    }
    # Repeat to discover grandchildren even if they precede their parents in
    # the snapshot. Retain discovered identities after a parent exits/reparents.
    do {
        $added = $false
        foreach ($row in $parents) {
            $key = [string]$row.id
            $parentKey = [string]$row.parent_id
            if ($Tracked.ContainsKey($key) -or -not $live.ContainsKey($parentKey)) { continue }
            $p = Get-Process -Id $row.id -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            try { $ticks = $p.StartTime.Ticks } catch { continue }
            if ($ticks -ne $row.start_ticks -or $ticks -lt $Tracked[$parentKey].start_ticks) { continue }
            $Tracked[$key] = @{ id = $row.id; start_ticks = $ticks; depth = $Tracked[$parentKey].depth + 1 }
            $live[$key] = $true
            $added = $true
        }
    } while ($added)
}

function Stop-AgentProcessTree {
    param($Process, [hashtable]$Tracked)
    $cleanupErrors = @()
    try { Update-AgentProcessTree -Tracked $Tracked }
    catch { $cleanupErrors += "Cannot inspect process descendants: $($_.Exception.Message)" }
    # Stop parents first to prevent them starting more work while cleaning up
    # the descendants already discovered. Check identity to avoid PID reuse.
    foreach ($entry in @($Tracked.Values | Sort-Object { $_.depth })) {
        $p = Get-Process -Id $entry.id -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        try {
            if ($p.StartTime.Ticks -ne $entry.start_ticks) { continue }
            Stop-Process -InputObject $p -Force -ErrorAction Stop
            Wait-Process -InputObject $p -Timeout 2 -ErrorAction SilentlyContinue
            if (-not $p.HasExited) { throw 'Process is still running.' }
        }
        catch { $cleanupErrors += "Cannot terminate process $($entry.id): $($_.Exception.Message)" }
    }
    # Covers cancellation immediately after Start-Process, before registration.
    if ($Process -and -not $Process.HasExited) {
        try {
            Stop-Process -InputObject $Process -Force -ErrorAction Stop
            Wait-Process -InputObject $Process -Timeout 2 -ErrorAction SilentlyContinue
        }
        catch { $cleanupErrors += "Cannot terminate command process: $($_.Exception.Message)" }
    }
    return $cleanupErrors
}

function Invoke-ShellCommand {
    param([string]$Root, [string]$Command, [int]$TimeoutSec = 60)
    if (-not $Command -or -not $Command.Trim()) { throw 'Command must not be empty.' }
    if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 600) { throw 'timeout_sec must be between 1 and 600.' }
    $rootFull = (Get-Item -LiteralPath $Root -Force -ErrorAction Stop).FullName
    $envInfo = Get-AgentEnvironment -Root $rootFull
    $shellExe = $envInfo.shell_exe
    $outTemp = New-TemporaryFile -ErrorAction Stop
    $errTemp = New-TemporaryFile -ErrorAction Stop
    $savedSKey = $env:SHELLOSSUS_API_KEY
    $savedHKey = $env:H_AGENT_API_KEY
    $savedOKey = $env:OPENAI_API_KEY
    $savedSSess = $env:SHELLOSSUS_SESSION_ID
    $savedSFile = $env:SHELLOSSUS_SESSION_FILE
    $savedSMod = $env:SHELLOSSUS_MODEL
    $savedSReas = $env:SHELLOSSUS_REASONING_LEVEL
    $timedOut = $false
    $proc = $null
    $trackedProcesses = @{}
    $commandFinished = $false
    $terminationErrors = @()
    $exitCode = 0
    $startTime = Get-Date
    try {
        try {
            $env:SHELLOSSUS_API_KEY = $null
            $env:H_AGENT_API_KEY = $null
            $env:OPENAI_API_KEY = $null
            if ($script:ActiveSessionId) {
                $env:SHELLOSSUS_SESSION_ID = $script:ActiveSessionId
            }
            if ($script:ActiveSessionFile) {
                $env:SHELLOSSUS_SESSION_FILE = $script:ActiveSessionFile
            }
            if ($script:ActiveModelId) {
                $env:SHELLOSSUS_MODEL = $script:ActiveModelId
            }
            if ($script:ReasoningEffort) {
                $env:SHELLOSSUS_REASONING_LEVEL = $script:ReasoningEffort
            }
            $wrappedCmd = "try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}`n" + $Command
            $argList = if ($env:OS -eq 'Windows_NT') {
                $escaped = ($wrappedCmd -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
                "-NoProfile -NonInteractive -Command `"$escaped`""
            }
            else {
                @('-NoProfile', '-NonInteractive', '-Command', $wrappedCmd)
            }
            $proc = Start-Process -FilePath $shellExe -ArgumentList $argList -WorkingDirectory $rootFull -RedirectStandardOutput $outTemp.FullName -RedirectStandardError $errTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
            if (-not $proc.HasExited) {
                try {
                    $trackedProcesses[[string]$proc.Id] = @{ id = $proc.Id; start_ticks = $proc.StartTime.Ticks; depth = 0 }
                }
                catch { if (-not $proc.HasExited) { throw } }
            }
            $waitStart = Get-Date
            while (-not $proc.HasExited) {
                Update-AgentProcessTree -Tracked $trackedProcesses
                if ($proc.HasExited) { break }
                $remainingSeconds = $TimeoutSec - ((Get-Date) - $waitStart).TotalSeconds
                if ($remainingSeconds -le 0) {
                    $timedOut = $true
                    $terminationErrors = @(Stop-AgentProcessTree -Process $proc -Tracked $trackedProcesses)
                    break
                }
                if ($remainingSeconds -ge 1) { Wait-Process -InputObject $proc -Timeout 1 -ErrorAction SilentlyContinue }
                else { Start-Sleep -Milliseconds 50 }
            }
            $commandFinished = $true
            if (-not $timedOut) {
                if ($null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode }
            }
            else {
                $exitCode = -1
            }
        }
        finally {
            $env:SHELLOSSUS_API_KEY = $savedSKey
            $env:H_AGENT_API_KEY = $savedHKey
            $env:OPENAI_API_KEY = $savedOKey
            $env:SHELLOSSUS_SESSION_ID = $savedSSess
            $env:SHELLOSSUS_SESSION_FILE = $savedSFile
            $env:SHELLOSSUS_MODEL = $savedSMod
            $env:SHELLOSSUS_REASONING_LEVEL = $savedSReas
        }
        $elapsedSec = [int](((Get-Date) - $startTime).TotalSeconds * 10) / 10.0
        $outItem = Get-Item -LiteralPath $outTemp.FullName -Force -ErrorAction Stop
        $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction Stop
        $outRaw = if ($outItem.Length -gt 0 -and $outItem.Length -le 2MB) { Get-Content -LiteralPath $outTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } elseif ($outItem.Length -gt 2MB) { (Get-Content -LiteralPath $outTemp.FullName -Tail 400 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        $errRaw = if ($errItem.Length -gt 0 -and $errItem.Length -le 2MB) { Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } elseif ($errItem.Length -gt 2MB) { (Get-Content -LiteralPath $errTemp.FullName -Tail 400 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        $combinedRaw = if ($outRaw -and $errRaw) { $outRaw.TrimEnd("`r", "`n") + "`n" + $errRaw } elseif ($outRaw) { [string]$outRaw } elseif ($errRaw) { [string]$errRaw } else { '' }
        $tailRes = Invoke-TruncateTail -Content $combinedRaw -MaxLines 300 -MaxBytes 20000
        $truncated = $tailRes.truncated -or ($outItem.Length -gt 2MB) -or ($errItem.Length -gt 2MB)
        $text = $tailRes.content
        $fullLogRel = $null
        if ($truncated) {
            try {
                $outDir = Join-Path (Join-Path $rootFull '.shellossus') 'output'
                if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop | Out-Null }
                $logName = 'cmd-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999) + '.log'
                $logFull = Join-Path $outDir $logName
                Copy-Item -LiteralPath $outTemp.FullName -Destination $logFull -Force -ErrorAction Stop
                if ($errItem.Length -gt 0) {
                    Get-Content -LiteralPath $errTemp.FullName -ReadCount 500 -Encoding UTF8 -ErrorAction SilentlyContinue | Add-Content -LiteralPath $logFull -Encoding UTF8 -ErrorAction SilentlyContinue
                }
                $fullLogRel = Get-WorkspaceRelativePath -Root $Root -FullPath $logFull
            }
            catch {}
        }
        if ($timedOut) {
            $timeoutNote = if ($terminationErrors.Count -eq 0) {
                "[Command timed out after ${TimeoutSec}s; command and tracked descendants were terminated]"
            }
            else {
                "[Command timed out after ${TimeoutSec}s; process cleanup incomplete: " + ($terminationErrors -join '; ') + ']'
            }
            $text = if ($text) { $text + "`n" + $timeoutNote } else { $timeoutNote }
        }
        return @{
            exit_code = $exitCode
            output = $text
            truncated = $truncated
            full_output_path = $fullLogRel
            timed_out = $timedOut
            termination_errors = @($terminationErrors)
            wall_time_seconds = $elapsedSec
        }
    }
    finally {
        if ($proc -and -not $commandFinished) {
            $null = Stop-AgentProcessTree -Process $proc -Tracked $trackedProcesses
        }
        if (Test-Path -LiteralPath $outTemp.FullName) { Remove-Item -LiteralPath $outTemp.FullName -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $errTemp.FullName) { Remove-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-AgentCommand {
    param([string]$Root, $Arguments)
    if ($Arguments.command -isnot [string] -or -not $Arguments.command.Trim()) { throw 'command must be a nonempty string.' }
    $cmdText = $Arguments.command
    if ($cmdText.Length -gt 8000) { throw 'Command is too long.' }
    $timeoutSec = 60
    if ($null -ne $Arguments.timeout_sec) {
        $timeoutSec = [int]$Arguments.timeout_sec
        if ($timeoutSec -lt 1 -or $timeoutSec -gt 600) { throw 'timeout_sec must be between 1 and 600.' }
    }
    if ($script:OutputMode -ne 'json') {
        Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.BoldYellow + $script:Box.Arrow + ' run_command ' + $script:Gm.Grey1 + '(' + $Root + ')' + $script:Gm.Reset)
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Bg1 + $script:Gm.Yellow + '  ' + (Format-PreviewText $cmdText) + '  ' + $script:Gm.Reset)
    }
    if ($script:AgentPermission -eq 'Auto') {
        if ($script:OutputMode -ne 'json') {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [auto-approved by Auto mode]' + $script:Gm.Reset)
        }
    }
    else {
        if ($script:OutputMode -eq 'json') {
            return (@{ status = 'cancelled'; message = 'Interactive confirmation is disabled in JSON mode. Use -Permission Auto to allow command execution.' } | ConvertTo-Json -Compress)
        }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.BoldYellow + 'Confirm (' + $script:Gm.Fg1 + 'RUN' + $script:Gm.BoldYellow + ' to execute, Enter cancels): ' + $script:Gm.Fg) -NoNewline
        $approval = Read-Host 'Type RUN to execute this command; Enter cancels'
        Write-Host $script:Gm.Reset -NoNewline
        if ($approval -cne 'RUN') {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
            return (@{ status = 'cancelled'; message = 'User declined command execution. Do not retry without a new user request.' } | ConvertTo-Json -Compress)
        }
    }
    $res = Invoke-ShellCommand -Root $Root -Command $cmdText -TimeoutSec $timeoutSec
    if ($script:OutputMode -ne 'json') {
        if ($res.output) {
            $previewLines = @($res.output -split "`r?`n" | Select-Object -First 15)
            foreach ($pLine in $previewLines) {
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + '   ' + $script:Gm.Grey1 + (Format-PreviewText $pLine) + $script:Gm.Reset)
            }
            if (($res.output -split "`r?`n").Count -gt 15) {
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + '   ... (output truncated in terminal preview)' + $script:Gm.Reset)
            }
        }
        $cmdIcon = if ($res.timed_out -or $res.exit_code -ne 0) { $script:Gm.Red + $script:Box.Cross + $script:Gm.Reset } else { $script:Gm.Green + $script:Box.Check + $script:Gm.Reset }
        $cmdColor = if ($res.timed_out -or $res.exit_code -ne 0) { $script:Gm.Red } else { $script:Gm.Grey2 }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $cmdIcon + ' ' + $cmdColor + ("exit {0}" -f $res.exit_code) + $script:Gm.Grey0 + ' | ' + $script:Gm.Grey1 + ("{0}s" -f $res.wall_time_seconds) + $script:Gm.Reset)
    }
    $status = if ($res.timed_out) { 'timed_out' } else { 'executed' }
    return (@{
        status = $status
        exit_code = $res.exit_code
        output = $res.output
        truncated = $res.truncated
        full_output_path = $res.full_output_path
        timed_out = $res.timed_out
        termination_errors = @($res.termination_errors)
        wall_time_seconds = $res.wall_time_seconds
    } | ConvertTo-Json -Compress)
}

function Format-FuzzyLine {
    param([string]$Line)
    $s = $Line.TrimEnd()
    $s = $s -replace '^\uFEFF', ''
    $s = $s -replace '[\u2018\u2019\u201A\u201B]', "'"
    $s = $s -replace '[\u201C\u201D\u201E\u201F]', '"'
    $s = $s -replace '[\u2010-\u2015\u2212]', '-'
    $s = $s -replace '[\u00A0\u2002-\u200A\u202F\u205F\u3000]', ' '
    return $s
}

function Find-EditMatch {
    param([string]$Content, [string]$OldText)
    $idx = $Content.IndexOf($OldText, [StringComparison]::Ordinal)
    if ($idx -ge 0) {
        if ($Content.IndexOf($OldText, $idx + $OldText.Length, [StringComparison]::Ordinal) -ge 0) {
            throw 'old_text occurs more than once. Provide more context.'
        }
        return @{ index = $idx; length = $OldText.Length; matched_text = $OldText }
    }
    if ($Content.Contains("`r`n")) {
        $crlfOld = $OldText.Replace("`r`n", "`n").Replace("`n", "`r`n")
        $idx = $Content.IndexOf($crlfOld, [StringComparison]::Ordinal)
        if ($idx -ge 0) {
            if ($Content.IndexOf($crlfOld, $idx + $crlfOld.Length, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text occurs more than once. Provide more context.'
            }
            return @{ index = $idx; length = $crlfOld.Length; matched_text = $crlfOld }
        }
    }
    $contentLines = @($Content -split "`n")
    $oldLines = @($OldText -split "`r?`n")
    if ($oldLines.Count -gt 0 -and $oldLines.Count -le $contentLines.Count) {
        $lineStarts = @()
        $pos = 0
        for ($i = 0; $i -lt $contentLines.Count; $i++) {
            $lineStarts += $pos
            $pos += $contentLines[$i].Length + 1
        }
        $normContent = @($contentLines | ForEach-Object { Format-FuzzyLine -Line $_ })
        $normOld = @($oldLines | ForEach-Object { Format-FuzzyLine -Line $_ })
        $matchesFound = @()
        $maxStart = $contentLines.Count - $oldLines.Count
        for ($i = 0; $i -le $maxStart; $i++) {
            $ok = $true
            for ($j = 0; $j -lt $oldLines.Count; $j++) {
                if ($normContent[$i + $j] -cne $normOld[$j]) { $ok = $false; break }
            }
            if ($ok) { $matchesFound += $i }
        }
        if ($matchesFound.Count -gt 1) {
            throw 'old_text occurs more than once. Provide more context.'
        }
        if ($matchesFound.Count -eq 1) {
            $startLineIdx = $matchesFound[0]
            $endLineIdx = $startLineIdx + $oldLines.Count - 1
            $charStart = $lineStarts[$startLineIdx]
            $endLineRaw = $contentLines[$endLineIdx]
            $endLineCleanLen = if ($endLineRaw.EndsWith("`r")) { $endLineRaw.Length - 1 } else { $endLineRaw.Length }
            $charEnd = $lineStarts[$endLineIdx] + $endLineCleanLen
            $matchedLen = $charEnd - $charStart
            return @{
                index = $charStart
                length = $matchedLen
                matched_text = $Content.Substring($charStart, $matchedLen)
            }
        }
    }
    throw 'old_text was not found. Read the file again.'
}

function Format-DiffSnippet {
    param([string]$Text, [int]$MaxChars = 4000, [switch]$KeepTail)
    if (-not $Text) { return '' }
    if ($Text.Length -le $MaxChars) { return (Format-PreviewText $Text) }
    if ($KeepTail) {
        return ('... ' + (Format-PreviewText $Text.Substring($Text.Length - $MaxChars)))
    }
    return ((Format-PreviewText $Text.Substring(0, $MaxChars)) + ' ...')
}

function ConvertTo-ExistingLineEndings {
    param([string]$Content, [string]$Original)
    if ($Original.Contains("`r`n")) {
        return $Content.Replace("`r`n", "`n").Replace("`n", "`r`n")
    }
    if ($Original.Contains("`n")) { return $Content.Replace("`r`n", "`n") }
    # Empty and single-line files do not establish a newline convention.
    return $Content
}

function Invoke-AgentWrite {
    param([string]$Root, [string]$Name, $Arguments)
    $before = $null
    $prefixText = ''
    $suffixText = ''
    $editsApplied = 1
    $firstChangedLine = 1
    if ($Name -eq 'write_file') {
        if ($Arguments.path -match '[/\\]$') { throw 'Invalid file name.' }
        $parent = Resolve-AgentPath -Root $Root -RelativePath (Split-Path $Arguments.path -Parent)
        if (-not (Get-Item -LiteralPath $parent -Force).PSIsContainer) { throw 'Parent must be a directory.' }
        $leaf = Split-Path $Arguments.path -Leaf
        if (-not $leaf -or $leaf -match '[<>:"/\\|?*\x00-\x1f]' -or $leaf -match '[. ]$') { throw 'Invalid file name.' }
        if ($leaf -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Reserved file name.' }
        $path = Join-Path $parent $leaf
        if ($leaf -eq '.env' -or ($leaf -like '.env.*' -and $leaf -ne '.env.example') -or $path -eq $script:AgentConfigPath) { throw 'Agent tools cannot write credential configuration files.' }
        if ($Arguments.content -isnot [string]) { throw 'content must be a string.' }
        $allowOverwrite = ($Arguments.overwrite -eq $true)
        if (Test-Path -LiteralPath $path) {
            if (-not $allowOverwrite) { throw 'File already exists. Use edit_file or set overwrite=true.' }
            $existingItem = Get-Item -LiteralPath $path -Force
            if ($existingItem.PSIsContainer -or $existingItem.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
            $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -eq $before) { $before = '' }
            $oldText = $before
            $newText = $Arguments.content
        }
        $after = if ($null -ne $before) {
            ConvertTo-ExistingLineEndings -Content $Arguments.content -Original $before
        }
        else { $Arguments.content }
    }
    else {
        $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or $item.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
        $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $before) { $before = '' }
        $rawEdits = if ($null -ne $Arguments.edits) {
            @($Arguments.edits)
        }
        else {
            @(@{ old_text = $Arguments.old_text; new_text = $Arguments.new_text })
        }
        $resolvedEdits = @()
        foreach ($ed in $rawEdits) {
            if ($ed.old_text -isnot [string] -or -not $ed.old_text -or $ed.new_text -isnot [string]) { throw 'Each edit must have nonempty old_text and string new_text.' }
            $m = Find-EditMatch -Content $before -OldText $ed.old_text
            $repText = ConvertTo-ExistingLineEndings -Content $ed.new_text -Original $before
            $resolvedEdits += @{ index = $m.index; length = $m.length; matched_text = $m.matched_text; new_text = $repText }
        }
        for ($i = 0; $i -lt $resolvedEdits.Count; $i++) {
            for ($j = $i + 1; $j -lt $resolvedEdits.Count; $j++) {
                $a = $resolvedEdits[$i]
                $b = $resolvedEdits[$j]
                if ($a.index -lt ($b.index + $b.length) -and $b.index -lt ($a.index + $a.length)) {
                    throw 'Batch edits overlap. Provide non-overlapping edit blocks.'
                }
            }
        }
        $sortedAsc = @($resolvedEdits | Sort-Object { $_.index })
        $minIdx = $sortedAsc[0].index
        $lastEd = $sortedAsc[$sortedAsc.Count - 1]
        $maxEndIdx = $lastEd.index + $lastEd.length
        $firstChangedLine = (@($before.Substring(0, $minIdx) -split "`n")).Count
        $editsApplied = $resolvedEdits.Count
        $after = $before
        foreach ($ed in @($resolvedEdits | Sort-Object { $_.index } -Descending)) {
            $after = $after.Substring(0, $ed.index) + $ed.new_text + $after.Substring($ed.index + $ed.length)
        }
        if ($after -ceq $before) { return (@{ status = 'unchanged' } | ConvertTo-Json -Compress) }
        $prefixText = $before.Substring(0, $minIdx)
        $suffixText = $before.Substring($maxEndIdx)
        if ($resolvedEdits.Count -eq 1) {
            $only = $resolvedEdits[0]
            $oldText = $only.matched_text
            $newText = $only.new_text
        }
        else {
            $oldSpanLen = $maxEndIdx - $minIdx
            $newSpanLen = $after.Length - $prefixText.Length - $suffixText.Length
            $oldText = $before.Substring($minIdx, $oldSpanLen)
            $newText = $after.Substring($minIdx, $newSpanLen)
        }
    }
    if ($after.Length -gt 1MB -or ($null -ne $before -and $before.Length -gt 1MB)) { throw 'File content exceeds 1 MiB limit.' }
    if ($after -match '\x00' -or ($null -ne $before -and $before -match '\x00')) { throw 'Binary content is not supported.' }
    if ($script:OutputMode -ne 'json') {
        Write-Host ''
        Write-UnifiedDiffCard -Path $Arguments.path -ToolName $Name -Before $before -After $after
    }
    if ($script:AgentPermission -in @('AutoEdit', 'Auto')) {
        if ($script:OutputMode -ne 'json') {
            Write-Host ('  ' + $script:Gm.Aqua + $script:Box.Check + ' [auto-approved by ' + $script:AgentPermission + ' mode]' + $script:Gm.Reset)
        }
    }
    else {
        if ($script:OutputMode -eq 'json') {
            return (@{ status = 'cancelled'; message = 'Interactive confirmation is disabled in JSON mode. Use -Permission AutoEdit or Auto to allow file modifications.' } | ConvertTo-Json -Compress)
        }
        Write-Host ('  ' + $script:Gm.BoldYellow + $script:Box.Arrow + ' Confirm (' + $script:Gm.Fg1 + 'WRITE' + $script:Gm.BoldYellow + ' to apply, Enter cancels): ' + $script:Gm.Fg) -NoNewline
        $approval = Read-Host 'Type WRITE to approve this file change; Enter cancels'
        Write-Host $script:Gm.Reset -NoNewline
        if ($approval -cne 'WRITE') {
            Write-Host ('  ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
            return (@{ status = 'cancelled'; message = 'User declined. Do not retry without a new user request.' } | ConvertTo-Json -Compress)
        }
    }
    $stageFile = New-TemporaryFile -ErrorAction Stop
    $backupPath = $null
    try {
        Set-Content -LiteralPath $stageFile.FullName -Value $after -Encoding UTF8 -NoNewline -ErrorAction Stop
        $stagedCheck = Get-Content -LiteralPath $stageFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $stagedCheck) { $stagedCheck = '' }
        if ($stagedCheck -cne $after) { throw 'Staged file verification failed. No write performed.' }
        if ($null -ne $before) {
            $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
            $current = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -eq $current) { $current = '' }
            if ($current -cne $before) { throw 'File changed during confirmation. No write performed.' }
            $backup = New-TemporaryFile -ErrorAction Stop
            Copy-Item -LiteralPath $path -Destination $backup.FullName -Force -ErrorAction Stop
            $backupCheck = Get-Content -LiteralPath $backup.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -eq $backupCheck) { $backupCheck = '' }
            if ($backupCheck -cne $before) {
                Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue
                throw 'Backup verification failed. No write performed.'
            }
            $backupPath = $backup.FullName
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Grey1 + 'Backup: ' + $backupPath + $script:Gm.Reset)
            }
            $script:CurrentTurnWrites += @{
                action = 'modified'
                full_path = $path
                rel_path = $Arguments.path
                backup = $backupPath
                before_content = $before
                after_content = $after
            }
            Move-Item -LiteralPath $stageFile.FullName -Destination $path -Force -ErrorAction Stop
        }
        else {
            $parent = Resolve-AgentPath -Root $Root -RelativePath (Split-Path $Arguments.path -Parent)
            $path = Join-Path $parent $leaf
            if (Test-Path -LiteralPath $path) { throw 'File was created during confirmation. No write performed.' }
            $script:CurrentTurnWrites += @{
                action = 'created'
                full_path = $path
                rel_path = $Arguments.path
                after_content = $after
            }
            Move-Item -LiteralPath $stageFile.FullName -Destination $path -Force -ErrorAction Stop
        }
        $writtenCheck = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $writtenCheck) { $writtenCheck = '' }
        if ($writtenCheck -cne $after) { throw 'Written file verification failed.' }
    }
    finally {
        if (Test-Path -LiteralPath $stageFile.FullName) {
            Remove-Item -LiteralPath $stageFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return (@{ status = 'written'; path = $Arguments.path; backup = $backupPath; edits_applied = $editsApplied; first_changed_line = $firstChangedLine } | ConvertTo-Json -Compress)
}

function Invoke-AgentUndo {
    param($State, $UndoEntry)
    if (-not $UndoEntry) { return }
    $writes = @($UndoEntry.writes)
    $preflightErrors = @()
    $expectedByPath = @{}
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if (-not $w -or $w.undone) { continue }
        $fullKey = [string]$w.full_path
        $isLatestForPath = (-not $expectedByPath.ContainsKey($fullKey))
        if ($w.action -eq 'modified') {
            if (-not $w.backup -or -not (Test-Path -LiteralPath $w.backup)) {
                $preflightErrors += "Backup file missing for $($w.rel_path)."
                continue
            }
            try {
                $backupContent = Get-Content -LiteralPath $w.backup -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $backupContent) { $backupContent = '' }
                if ($null -eq $w.before_content -or $backupContent -cne $w.before_content) {
                    throw 'Backup does not match the recorded original content.'
                }
            }
            catch {
                $preflightErrors += "Backup verification failed for $($w.rel_path); backup kept at $($w.backup): $($_.Exception.Message)"
                continue
            }
            if ($isLatestForPath) {
                if (Test-Path -LiteralPath $w.full_path) {
                    $targetItem = Get-Item -LiteralPath $w.full_path -Force -ErrorAction SilentlyContinue
                    if ($targetItem -and $targetItem.PSIsContainer) {
                        $preflightErrors += "Target path $($w.rel_path) is now a directory."
                        continue
                    }
                    if ($null -ne $w.after_content) {
                        $diskNow = Get-Content -LiteralPath $w.full_path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($null -eq $diskNow) { $diskNow = '' }
                        if (($diskNow -cne $w.after_content) -and ($null -eq $w.before_content -or $diskNow -cne $w.before_content)) {
                            $preflightErrors += "File $($w.rel_path) was modified after the agent write; refusing to overwrite manual changes (backup kept at $($w.backup))."
                            continue
                        }
                    }
                }
            }
            else {
                $expectedAfter = $expectedByPath[$fullKey]
                if ($null -ne $expectedAfter -and $null -ne $w.after_content -and ($w.after_content -cne $expectedAfter)) {
                    $preflightErrors += "Undo chain mismatch for $($w.rel_path)."
                    continue
                }
            }
            $expectedByPath[$fullKey] = $w.before_content
        }
        elseif ($w.action -eq 'created') {
            if ($isLatestForPath) {
                if (Test-Path -LiteralPath $w.full_path) {
                    $targetItem = Get-Item -LiteralPath $w.full_path -Force -ErrorAction SilentlyContinue
                    if ($targetItem -and $targetItem.PSIsContainer) {
                        $preflightErrors += "Created path $($w.rel_path) is now a directory."
                        continue
                    }
                    if ($null -ne $w.after_content) {
                        $diskNow = Get-Content -LiteralPath $w.full_path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($null -eq $diskNow) { $diskNow = '' }
                        if ($diskNow -cne $w.after_content) {
                            $preflightErrors += "Created file $($w.rel_path) was modified after creation; refusing to delete manual changes."
                            continue
                        }
                    }
                }
            }
            else {
                $expectedAfter = $expectedByPath[$fullKey]
                if ($null -ne $expectedAfter -and $null -ne $w.after_content -and ($w.after_content -cne $expectedAfter)) {
                    $preflightErrors += "Undo chain mismatch for $($w.rel_path)."
                    continue
                }
            }
            $expectedByPath[$fullKey] = $null
        }
    }
    if ($preflightErrors.Count -gt 0) {
        throw ('Undo failed: ' + ($preflightErrors -join '; '))
    }
    $undoErrors = @()
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if (-not $w -or $w.undone) { continue }
        try {
            if ($w.action -eq 'modified') {
                $expectedOrig = [string]$w.before_content
                $backupNow = Get-Content -LiteralPath $w.backup -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $backupNow) { $backupNow = '' }
                if ($backupNow -cne $expectedOrig) { throw "Backup changed after preflight for $($w.rel_path)." }
                Copy-Item -LiteralPath $w.backup -Destination $w.full_path -Force -ErrorAction Stop
                $restoredNow = Get-Content -LiteralPath $w.full_path -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $restoredNow) { $restoredNow = '' }
                if ($restoredNow -cne $expectedOrig) {
                    throw "Restored content verification failed for $($w.rel_path) (backup kept at $($w.backup))."
                }
                Remove-Item -LiteralPath $w.backup -Force -ErrorAction Stop
                $w.undone = $true
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + '  [undo] Restored ' + $w.rel_path + $script:Gm.Reset)
                }
            }
            elseif ($w.action -eq 'created') {
                if (Test-Path -LiteralPath $w.full_path) {
                    Remove-Item -LiteralPath $w.full_path -Force -ErrorAction Stop
                    if ($script:OutputMode -ne 'json') {
                        Write-Host ($script:Gm.Aqua + '  [undo] Removed created file ' + $w.rel_path + $script:Gm.Reset)
                    }
                }
                $w.undone = $true
            }
        }
        catch {
            $undoErrors += $_.Exception.Message
        }
    }
    if ($undoErrors.Count -gt 0) {
        throw ('Undo failed: ' + ($undoErrors -join '; '))
    }
    $State.messages = @($UndoEntry.messages)
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
}

function Get-ForkedSubagentMessages {
    param($ParentState, [string]$SystemPrompt)
    $forked = @(@{ role = 'system'; content = $SystemPrompt })
    if (-not $ParentState -or -not $ParentState.messages -or $ParentState.messages.Count -le 1) {
        return $forked
    }
    $msgs = @($ParentState.messages)
    $endIdx = $msgs.Count - 1
    while ($endIdx -ge 1 -and $msgs[$endIdx].role -eq 'tool') {
        $endIdx--
    }
    if ($endIdx -ge 1 -and $msgs[$endIdx].role -eq 'assistant' -and $msgs[$endIdx].tool_calls -and @($msgs[$endIdx].tool_calls).Count -gt 0) {
        $endIdx--
    }
    for ($i = 1; $i -le $endIdx; $i++) {
        $m = $msgs[$i]
        if ($m.role -eq 'system') { continue }
        if ($m.role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Capability State Change]')) { continue }
        $copyMsg = @{ role = [string]$m.role; content = $m.content }
        if ($m.reasoning_content) { $copyMsg.reasoning_content = $m.reasoning_content }
        if ($m.tool_calls) { $copyMsg.tool_calls = @($m.tool_calls) }
        if ($m.tool_call_id) { $copyMsg.tool_call_id = [string]$m.tool_call_id }
        $forked += $copyMsg
    }
    if (-not (Test-ValidConversationBoundary -Messages $forked)) {
        return @(@{ role = 'system'; content = $SystemPrompt })
    }
    return $forked
}

function Get-SubagentToolNames {
    param($Role, [switch]$ForceReadOnly)
    # Resolve patterns against the parent's effective capabilities, including
    # exclusions and NoTools. Never interpret an empty intersection as allow-all.
    foreach ($tool in @(Get-AgentTools)) {
        $name = [string]$tool.function.name
        if ($name -eq 'run_agent') { continue }
        if (($ForceReadOnly -or $Role.permission -eq 'ReadOnly') -and $name -in @('write_file', 'edit_file', 'run_command')) { continue }
        if ($Role.tools -and $Role.tools.Count -gt 0) {
            $matched = $false
            foreach ($pattern in $Role.tools) {
                if ($name -like (Resolve-ToolCanonicalName -Name $pattern)) { $matched = $true; break }
            }
            if (-not $matched) { continue }
        }
        $name
    }
}

function Invoke-SubagentInProcess {
    param(
        [string]$Root,
        [string]$RoleName = 'craft',
        [string]$TaskPrompt,
        [string]$ContextMode = 'clean',
        [int]$MaxSteps = 15,
        [switch]$ForceReadOnly
    )
    $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
    $roleObj = Resolve-AgentRole -Name $RoleName -Root $Root -ConfigDir $configDir
    $effPerm = if ($ForceReadOnly -or $script:AgentPermission -eq 'ReadOnly' -or $roleObj.permission -eq 'ReadOnly') {
        'ReadOnly'
    }
    else {
        $script:AgentPermission
    }
    $effEndpoint = if ($script:ActiveEndpoint) { $script:ActiveEndpoint } else { 'https://example.invalid/v1/chat/completions' }
    $effModel = if ($roleObj.model) { [string]$roleObj.model } elseif ($script:ActiveModelId) { $script:ActiveModelId } else { 'test-model' }
    $effKey = if ($script:ActiveApiKey) { $script:ActiveApiKey } else { 'subagent-key' }
    $savedPerm = $script:AgentPermission
    $savedDepth = $script:SubagentDepth
    $savedTools = @($script:EnabledTools)
    $savedNoTools = $script:NoTools
    $childTools = @(Get-SubagentToolNames -Role $roleObj -ForceReadOnly:$ForceReadOnly)
    $savedModel = $script:ActiveModelId
    $savedState = $script:ActiveState
    try {
        $script:SubagentDepth = $savedDepth + 1
        $script:AgentPermission = $effPerm
        $script:EnabledTools = $childTools
        $script:NoTools = ($savedNoTools -or $childTools.Count -eq 0)
        $baseSys = Build-SystemPrompt -Root $Root -ConfigDir $configDir
        $subSys = $baseSys + "`n`n[Subagent Role: $($roleObj.name)]`n" + $roleObj.system_prompt
        $initMsgs = @(if ($ContextMode -eq 'fork') {
            Get-ForkedSubagentMessages -ParentState $savedState -SystemPrompt $subSys
        }
        else {
            @{ role = 'system'; content = $subSys }
        })
        $expandedTask = Expand-UserPrompt -Root $Root -Prompt $TaskPrompt
        $initMsgs += @{ role = 'user'; content = $expandedTask }
        $childState = @{
            session_id = 'sub-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 1000 -Maximum 9999)
            workspace = $Root
            model = $effModel
            messages = $initMsgs
            tree_entries = @()
            usage_input_tokens = 0
            usage_output_tokens = 0
        }
        Sync-AgentCapabilities -State $childState -Root $Root | Out-Null
        if ($script:OutputMode -ne 'json') {
            Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.Aqua + $script:Box.Arrow + (" run_agent:{0} " -f $roleObj.name) + $script:Gm.Yellow + ("[{0}; context={1}] " -f $effPerm, $ContextMode) + $script:Gm.Grey1 + (Invoke-TruncateLine -Line $TaskPrompt -MaxChars 80).text + $script:Gm.Reset)
        }
        Invoke-AgentTurn -State $childState -Endpoint $effEndpoint -ModelId $effModel -ApiKey $effKey -Root $Root -Steps $MaxSteps
        if ($null -ne $savedState) {
            if ($childState.usage_input_tokens) { $savedState.usage_input_tokens = [int]$savedState.usage_input_tokens + [int]$childState.usage_input_tokens }
            if ($childState.usage_output_tokens) { $savedState.usage_output_tokens = [int]$savedState.usage_output_tokens + [int]$childState.usage_output_tokens }
        }
        $replyText = ''
        $assistantSteps = 0
        foreach ($cm in @($childState.messages)) {
            if ($cm.role -eq 'assistant') {
                $assistantSteps++
                if ($cm.content) { $replyText = [string]$cm.content }
            }
        }
        $fileOps = Get-CompactionFileOperations -Messages $childState.messages
        $subStatus = if ($childState.step_limit_reached) { 'step_limit_reached' } elseif ($childState.loop_detected) { 'loop_detected' } else { 'completed' }
        if ($script:OutputMode -ne 'json') {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Green + $script:Box.Check + ' ' + $script:Gm.Grey2 + ("run_agent:{0} {1} ({2} steps, read:{3}, modified:{4})" -f $roleObj.name, $subStatus, $assistantSteps, @($fileOps.read_files).Count, @($fileOps.modified_files).Count) + $script:Gm.Reset)
        }
        return @{
            role = $roleObj.name
            permission = $effPerm
            context = $ContextMode
            status = $subStatus
            output = $replyText
            steps_used = $assistantSteps
            read_files = @($fileOps.read_files)
            modified_files = @($fileOps.modified_files)
            usage_input_tokens = [int]$childState.usage_input_tokens
            usage_output_tokens = [int]$childState.usage_output_tokens
        }
    }
    finally {
        $script:AgentPermission = $savedPerm
        $script:SubagentDepth = $savedDepth
        $script:EnabledTools = $savedTools
        $script:NoTools = $savedNoTools
        $script:ActiveModelId = $savedModel
        $script:ActiveState = $savedState
    }
}

function Resolve-StandaloneScriptPath {
    if ($script:StandaloneScriptPath -and (Test-Path -LiteralPath $script:StandaloneScriptPath)) {
        return (Get-Item -LiteralPath $script:StandaloneScriptPath -Force).FullName
    }
    $cands = @()
    if ($PSScriptRoot) {
        $cands += (Join-Path $PSScriptRoot 'shellossus.ps1')
        $parentDir = Split-Path $PSScriptRoot -Parent
        if ($parentDir) { $cands += (Join-Path $parentDir 'shellossus.ps1') }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Get-Item -LiteralPath $c -Force).FullName
        }
    }
    return ''
}

function Invoke-ParallelSubagentProcesses {
    param([string]$Root, [array]$Tasks, [int]$MaxSteps = 15, [string]$ScriptPath)
    $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
    $shellExe = (Get-AgentEnvironment -Root $Root).shell_exe
    $effEndpoint = if ($script:ActiveEndpoint) { $script:ActiveEndpoint } else { 'https://example.invalid/v1/chat/completions' }
    $baseUrl = $effEndpoint -replace '/chat/completions/?$', ''
    $effKey = if ($script:ActiveApiKey) { $script:ActiveApiKey } else { 'subagent-key' }
    $workerCmd = @'
$ErrorActionPreference = 'Stop'
$pText = Get-Content -LiteralPath $env:SHELLOSSUS_SUB_PROMPT -Raw -Encoding UTF8
$workerArgs = @{
    Workspace = $env:SHELLOSSUS_SUB_ROOT
    BaseUrl = $env:SHELLOSSUS_SUB_BASEURL
    Model = $env:SHELLOSSUS_SUB_MODEL
    Permission = 'ReadOnly'
    Mode = 'json'
    NoSession = $true
    MaxSteps = [int]$env:SHELLOSSUS_SUB_STEPS
    Tools = $env:SHELLOSSUS_SUB_TOOLS
    NoTools = ($env:SHELLOSSUS_SUB_NO_TOOLS -eq '1')
    ExcludeTools = 'run_agent'
    Prompt = $pText
}
if ($env:SHELLOSSUS_SUB_CONFIG) { $workerArgs.ConfigPath = $env:SHELLOSSUS_SUB_CONFIG }
& $env:SHELLOSSUS_SUB_SCRIPT @workerArgs
'@
    $argList = if ($env:OS -eq 'Windows_NT') {
        $escaped = ($workerCmd -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
        "-NoProfile -NonInteractive -Command `"$escaped`""
    }
    else {
        @('-NoProfile', '-NonInteractive', '-Command', $workerCmd)
    }
    $allResults = @()
    $batchSize = 4
    for ($offset = 0; $offset -lt $Tasks.Count; $offset += $batchSize) {
        $endIdx = $offset + $batchSize - 1
        if ($endIdx -ge $Tasks.Count) { $endIdx = $Tasks.Count - 1 }
        $workers = @()
        try {
            for ($i = $offset; $i -le $endIdx; $i++) {
                $t = $Tasks[$i]
                $rName = if ($t.role) { [string]$t.role } else { 'recon' }
                $roleObj = Resolve-AgentRole -Name $rName -Root $Root -ConfigDir $configDir
                $childTools = @(Get-SubagentToolNames -Role $roleObj -ForceReadOnly)
                $effModel = if ($roleObj.model) { [string]$roleObj.model } elseif ($script:ActiveModelId) { $script:ActiveModelId } else { 'test-model' }
                $promptTemp = New-TemporaryFile -ErrorAction Stop
                $outTemp = New-TemporaryFile -ErrorAction Stop
                $errTemp = New-TemporaryFile -ErrorAction Stop
                $fullPrompt = "[Subagent Role: $($roleObj.name)]`n$($roleObj.system_prompt)`n`nTask:`n$($t.prompt)"
                Set-Content -LiteralPath $promptTemp.FullName -Value $fullPrompt -Encoding UTF8 -NoNewline -ErrorAction Stop
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + ("  [run_agent:{0}] (parallel ReadOnly) " -f $roleObj.name) + $script:Gm.Grey1 + (Invoke-TruncateLine -Line ([string]$t.prompt) -MaxChars 90).text + $script:Gm.Reset)
                }
                $proc = $null
                $savedSKey = $env:SHELLOSSUS_API_KEY
                $savedWorkerEnv = @{}
                foreach ($envName in @('SHELLOSSUS_SUB_SCRIPT', 'SHELLOSSUS_SUB_ROOT', 'SHELLOSSUS_SUB_BASEURL', 'SHELLOSSUS_SUB_MODEL', 'SHELLOSSUS_SUB_STEPS', 'SHELLOSSUS_SUB_PROMPT', 'SHELLOSSUS_SUB_TOOLS', 'SHELLOSSUS_SUB_NO_TOOLS', 'SHELLOSSUS_SUB_CONFIG')) {
                    $savedWorkerEnv[$envName] = (Get-Item -LiteralPath ("Env:" + $envName) -ErrorAction SilentlyContinue).Value
                }
                try {
                    $env:SHELLOSSUS_API_KEY = $effKey
                    $env:SHELLOSSUS_SUB_SCRIPT = $ScriptPath
                    $env:SHELLOSSUS_SUB_ROOT = $Root
                    $env:SHELLOSSUS_SUB_BASEURL = $baseUrl
                    $env:SHELLOSSUS_SUB_MODEL = $effModel
                    $env:SHELLOSSUS_SUB_STEPS = [string]$MaxSteps
                    $env:SHELLOSSUS_SUB_PROMPT = $promptTemp.FullName
                    $env:SHELLOSSUS_SUB_TOOLS = $childTools -join ','
                    $env:SHELLOSSUS_SUB_NO_TOOLS = if ($childTools.Count -eq 0) { '1' } else { '0' }
                    $env:SHELLOSSUS_SUB_CONFIG = $script:AgentConfigPath
                    $proc = Start-Process -FilePath $shellExe -ArgumentList $argList -WorkingDirectory $Root -RedirectStandardOutput $outTemp.FullName -RedirectStandardError $errTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
                }
                finally {
                    $env:SHELLOSSUS_API_KEY = $savedSKey
                    foreach ($envName in $savedWorkerEnv.Keys) {
                        if ($null -eq $savedWorkerEnv[$envName]) { Remove-Item -LiteralPath ("Env:" + $envName) -ErrorAction SilentlyContinue }
                        else { Set-Item -LiteralPath ("Env:" + $envName) -Value $savedWorkerEnv[$envName] }
                    }
                }
                $workers += @{
                    role = $roleObj.name
                    proc = $proc
                    prompt_file = $promptTemp.FullName
                    out_file = $outTemp.FullName
                    err_file = $errTemp.FullName
                }
            }
            $startWait = Get-Date
            while ($true) {
                $running = @($workers | Where-Object { -not $_.proc.HasExited })
                if ($running.Count -eq 0) { break }
                if (((Get-Date) - $startWait).TotalSeconds -ge 180) {
                    foreach ($rw in $running) {
                        Stop-Process -InputObject $rw.proc -Force -ErrorAction SilentlyContinue
                    }
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            foreach ($w in $workers) {
                $replyText = ''
                $stepsUsed = 0
                $wReadSet = @{}
                $wStatus = 'completed'
                if (Test-Path -LiteralPath $w.out_file) {
                    foreach ($line in @(Get-Content -LiteralPath $w.out_file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                        $trimmed = ([string]$line).Trim()
                        if (-not $trimmed.StartsWith('{')) { continue }
                        try {
                            $ev = $trimmed | ConvertFrom-Json -ErrorAction Stop
                            if ($ev.type -eq 'message_end' -and $ev.role -eq 'assistant') {
                                $stepsUsed++
                                if ($ev.content) { $replyText = [string]$ev.content }
                                if ($ev.tool_calls) {
                                    foreach ($tc in @($ev.tool_calls)) {
                                        $fn = if ($tc.function -and $tc.function.name) { [string]$tc.function.name } else { '' }
                                        if ($fn -in @('read_file', 'read') -and $tc.function.arguments) {
                                            try {
                                                $pa = ([string]$tc.function.arguments) | ConvertFrom-Json -ErrorAction Stop
                                                if ($pa.path) { $wReadSet[[string]$pa.path] = $true }
                                            }
                                            catch {}
                                        }
                                    }
                                }
                            }
                            elseif ($ev.type -eq 'turn_end' -and $ev.status) {
                                $wStatus = [string]$ev.status
                            }
                        }
                        catch {}
                    }
                }
                if (-not $replyText -and (Test-Path -LiteralPath $w.err_file)) {
                    $errRaw = Get-Content -LiteralPath $w.err_file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($errRaw -and $errRaw.Trim()) {
                        $wStatus = 'error'
                        $replyText = 'Subagent error: ' + $errRaw.Trim()
                    }
                }
                $allResults += @{
                    role = $w.role
                    permission = 'ReadOnly'
                    context = 'clean'
                    status = $wStatus
                    output = $replyText
                    steps_used = $stepsUsed
                    read_files = @($wReadSet.Keys | Sort-Object)
                    modified_files = @()
                }
            }
        }
        finally {
            foreach ($w in $workers) {
                if ($w.proc -and (-not $w.proc.HasExited)) {
                    Stop-Process -InputObject $w.proc -Force -ErrorAction SilentlyContinue
                }
                Remove-Item -LiteralPath $w.prompt_file -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $w.out_file -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $w.err_file -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $allResults
}

function Invoke-AgentSubagent {
    param([string]$Root, $Arguments)
    if ($script:SubagentDepth -ge $script:MaxSubagentDepth) {
        throw 'Maximum subagent nesting depth reached.'
    }
    $maxSteps = if ($null -ne $Arguments.max_steps) { [int]$Arguments.max_steps } else { 15 }
    $ctxMode = if ($Arguments.context) { [string]$Arguments.context } else { 'clean' }
    $propNames = @(Get-ObjectPropertyNames -InputObject $Arguments)
    if ($propNames -contains 'parallel' -and $null -ne $Arguments.parallel) {
        $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
        foreach ($pt in $Arguments.parallel) {
            $rName = if ($pt.role) { [string]$pt.role } else { 'recon' }
            $null = Resolve-AgentRole -Name $rName -Root $Root -ConfigDir $configDir
        }
        $iwrCmd = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
        $isMockedHttp = (($iwrCmd -and $iwrCmd.CommandType -eq 'Function') -or $script:DisableAsyncHttp)
        $standaloneScript = Resolve-StandaloneScriptPath
        $useWorkerProcs = ($Arguments.parallel.Count -gt 1) -and (-not $isMockedHttp) -and ($ExecutionContext.SessionState.LanguageMode -ne 'ConstrainedLanguage') -and ([bool]$standaloneScript)
        $results = @()
        $readSet = @{}
        if ($useWorkerProcs) {
            $results = @(Invoke-ParallelSubagentProcesses -Root $Root -Tasks @($Arguments.parallel) -MaxSteps $maxSteps -ScriptPath $standaloneScript)
            foreach ($subRes in $results) {
                foreach ($rf in @($subRes.read_files)) {
                    if ($rf) { $readSet[[string]$rf] = $true }
                }
            }
        }
        else {
            foreach ($pt in $Arguments.parallel) {
                $rName = if ($pt.role) { [string]$pt.role } else { 'recon' }
                $subRes = Invoke-SubagentInProcess -Root $Root -RoleName $rName -TaskPrompt ([string]$pt.prompt) -ContextMode 'clean' -MaxSteps $maxSteps -ForceReadOnly
                $results += $subRes
                foreach ($rf in @($subRes.read_files)) {
                    if ($rf) { $readSet[[string]$rf] = $true }
                }
            }
        }
        $summaryParts = @()
        for ($i = 0; $i -lt $results.Count; $i++) {
            $rItem = $results[$i]
            $summaryParts += ("### Task {0} ({1})`n{2}" -f ($i + 1), $rItem.role, $rItem.output)
        }
        return (@{
            status = 'completed'
            mode = 'parallel'
            tasks_count = $results.Count
            output = ($summaryParts -join "`n`n")
            results = $results
            read_files = @($readSet.Keys | Sort-Object)
            modified_files = @()
        } | ConvertTo-Json -Depth 10 -Compress)
    }
    if ($propNames -contains 'pipeline' -and $null -ne $Arguments.pipeline) {
        $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
        foreach ($ps in $Arguments.pipeline) {
            $rName = if ($ps.role) { [string]$ps.role } else { 'craft' }
            $null = Resolve-AgentRole -Name $rName -Root $Root -ConfigDir $configDir
        }
        $stepResults = @()
        $readSet = @{}
        $modSet = @{}
        $prevOutput = ''
        for ($i = 0; $i -lt $Arguments.pipeline.Count; $i++) {
            $ps = $Arguments.pipeline[$i]
            $rName = if ($ps.role) { [string]$ps.role } else { 'craft' }
            $stepCtx = if ($ps.context) { [string]$ps.context } else { $ctxMode }
            $rawPrompt = [string]$ps.prompt
            $resolvedPrompt = $rawPrompt.Replace('{previous}', $prevOutput).Replace('$PREVIOUS', $prevOutput)
            $stepRes = Invoke-SubagentInProcess -Root $Root -RoleName $rName -TaskPrompt $resolvedPrompt -ContextMode $stepCtx -MaxSteps $maxSteps
            $stepResults += $stepRes
            $prevOutput = [string]$stepRes.output
            foreach ($rf in @($stepRes.read_files)) {
                if ($rf) { $readSet[[string]$rf] = $true }
            }
            foreach ($mf in @($stepRes.modified_files)) {
                if ($mf) { $modSet[[string]$mf] = $true }
            }
        }
        $readOnlyList = @($readSet.Keys | Where-Object { -not $modSet.ContainsKey($_) } | Sort-Object)
        $modList = @($modSet.Keys | Sort-Object)
        return (@{
            status = 'completed'
            mode = 'pipeline'
            steps_count = $stepResults.Count
            output = $prevOutput
            results = $stepResults
            read_files = $readOnlyList
            modified_files = $modList
        } | ConvertTo-Json -Depth 10 -Compress)
    }
    $roleName = if ($Arguments.role) { [string]$Arguments.role } else { 'craft' }
    $singleRes = Invoke-SubagentInProcess -Root $Root -RoleName $roleName -TaskPrompt ([string]$Arguments.prompt) -ContextMode $ctxMode -MaxSteps $maxSteps
    return (@{
        status = $singleRes.status
        mode = 'single'
        role = $singleRes.role
        permission = $singleRes.permission
        context = $singleRes.context
        output = $singleRes.output
        steps_used = $singleRes.steps_used
        read_files = $singleRes.read_files
        modified_files = $singleRes.modified_files
    } | ConvertTo-Json -Depth 10 -Compress)
}

function ConvertTo-UrlEncodedString {
    param([string]$Text)
    if (-not $Text) { return '' }
    $out = foreach ($ch in [char[]]$Text) {
        $cp = [int][char]$ch
        if (($cp -ge 0x30 -and $cp -le 0x39) -or ($cp -ge 0x41 -and $cp -le 0x5A) -or ($cp -ge 0x61 -and $cp -le 0x7A) -or $cp -in @(0x2D, 0x5F, 0x2E, 0x7E)) {
            [string]$ch
        }
        elseif ($cp -eq 0x20) {
            '+'
        }
        elseif ($cp -le 0x7F) {
            '%{0:X2}' -f $cp
        }
        elseif ($cp -le 0x7FF) {
            $b2 = 0x80 + ($cp % 64)
            $b1 = 0xC0 + [int](($cp - ($cp % 64)) / 64)
            '%{0:X2}%{1:X2}' -f $b1, $b2
        }
        else {
            $low6 = $cp % 64
            $mid = [int](($cp - $low6) / 64)
            $mid6 = $mid % 64
            $hi4 = [int](($mid - $mid6) / 64)
            '%{0:X2}%{1:X2}%{2:X2}' -f (0xE0 + $hi4), (0x80 + $mid6), (0x80 + $low6)
        }
    }
    return ($out -join '')
}

function ConvertFrom-UrlEncodedString {
    param([string]$Text)
    if (-not $Text) { return '' }
    $work = $Text.Replace('+', ' ')
    $parts = @($work -split '(%[0-9A-Fa-f]{2})')
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $hex = $parts[$i].Substring(1)
        $byteVal = [int]('0x' + $hex)
        if ($byteVal -ge 0x20 -and $byteVal -le 0x7E) {
            $parts[$i] = [string][char]$byteVal
        }
    }
    return ($parts -join '')
}

function ConvertFrom-HtmlToText {
    param([string]$Html)
    if (-not $Html) { return '' }
    $s = $Html
    $s = $s -replace '(?is)<!--.*?-->', ''
    $s = $s -replace '(?is)<(script|style|noscript|svg|head)\b[^>]*>.*?</\1>', ''
    $s = $s -replace '(?is)<br\s*/?>', "`n"
    $s = $s -replace '(?is)</(p|div|section|article|header|footer|tr|table|ul|ol|blockquote|pre|h[1-6])>', "`n"
    $s = $s -replace '(?is)<li\b[^>]*>', "`n- "
    $s = $s -replace '(?is)<h([1-6])\b[^>]*>', "`n# "
    $s = $s -replace '(?is)<[^>]+>', ' '
    $s = $s.Replace('&nbsp;', ' ').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&apos;', "'").Replace('&mdash;', '--').Replace('&ndash;', '-')
    $lines = @()
    foreach ($ln in @($s -split '\r?\n')) {
        $cleanLn = ($ln -replace '[ \t]+', ' ').Trim()
        $lines += $cleanLn
    }
    $joined = ($lines -join "`n") -replace '\n{3,}', "`n`n"
    return $joined.Trim()
}

function Invoke-AgentFetchUrl {
    param($Arguments)
    $toolStart = Get-Date
    $url = if ($Arguments.url) { $Arguments.url.Trim() } else { '' }
    if ($url -notmatch '^https?://[^\s]+$') {
        throw 'url must be a valid http:// or https:// URL.'
    }
    $maxChars = 20000
    if ($null -ne $Arguments.max_chars) {
        $maxChars = [int]$Arguments.max_chars
        if ($maxChars -lt 500 -or $maxChars -gt 50000) { throw 'max_chars must be between 500 and 50000.' }
    }
    $rawMode = ($Arguments.raw -eq $true)
    $tempOut = New-TemporaryFile -ErrorAction Stop
    try {
        $reqParams = @{
            Uri = $url
            Method = 'Get'
            Headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Shellossus/1.0' }
            TimeoutSec = 30
            UseBasicParsing = $true
            OutFile = $tempOut.FullName
            ErrorAction = 'Stop'
        }
        Invoke-WebRequest @reqParams
        $rawText = Get-Content -LiteralPath $tempOut.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $rawText) { $rawText = '' }
        $isHtml = ($rawText -match '(?is)<\s*(!doctype\s+html|html|body|div|p|article|main|section|table|h1)\b')
        $content = if ((-not $rawMode) -and $isHtml) {
            ConvertFrom-HtmlToText -Html $rawText
        }
        else {
            $rawText.Trim()
        }
        $truncated = $false
        $totalLen = $content.Length
        if ($content.Length -gt $maxChars) {
            $content = $content.Substring(0, $maxChars) + "`n...(truncated at $maxChars chars)"
            $truncated = $true
        }
        $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
        $sumStr = "$($content.Length) chars" + $(if ($truncated) { " (of $totalLen)" } else { '' })
        Write-ToolCallCard -Name 'fetch_url' -Target $url -Status 'ok' -Summary $sumStr -ElapsedMs $elapsedMs
        return (@{
            url = $url
            content = $content
            length = $totalLen
            truncated = $truncated
        } | ConvertTo-Json -Depth 5 -Compress)
    }
    finally {
        Remove-Item -LiteralPath $tempOut.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AgentWebSearch {
    param($Arguments)
    $toolStart = Get-Date
    $query = if ($Arguments.query) { $Arguments.query.Trim() } else { '' }
    if (-not $query) { throw 'query must be a nonempty string.' }
    $limit = 8
    if ($null -ne $Arguments.limit) {
        $limit = [int]$Arguments.limit
        if ($limit -lt 1 -or $limit -gt 20) { throw 'limit must be between 1 and 20.' }
    }
    $encodedQ = ConvertTo-UrlEncodedString -Text $query
    $baseSearchUrl = if ($env:SHELLOSSUS_SEARCH_URL) { $env:SHELLOSSUS_SEARCH_URL } else { 'https://html.duckduckgo.com/html/?q=' }
    $searchUri = $baseSearchUrl + $encodedQ
    $tempOut = New-TemporaryFile -ErrorAction Stop
    try {
        $reqParams = @{
            Uri = $searchUri
            Method = 'Get'
            Headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Shellossus/1.0' }
            TimeoutSec = 30
            UseBasicParsing = $true
            OutFile = $tempOut.FullName
            ErrorAction = 'Stop'
        }
        Invoke-WebRequest @reqParams
        $html = Get-Content -LiteralPath $tempOut.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $html) { $html = '' }
        $results = @()
        $blocks = @($html -split '(?i)<div[^>]+class="[^"]*\bresult\b[^"]*"[^>]*>')
        if ($blocks.Count -gt 1) {
            for ($b = 1; $b -lt $blocks.Count; $b++) {
                if ($results.Count -ge $limit) { break }
                $blk = $blocks[$b]
                $href = ''
                $titleRaw = ''
                if ($blk -match '(?is)<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>(.*?)</a>') {
                    $href = $Matches[1]
                    $titleRaw = $Matches[2]
                }
                elseif ($blk -match '(?is)<a[^>]+href="([^"]+)"[^>]+class="[^"]*result__a[^"]*"[^>]*>(.*?)</a>') {
                    $href = $Matches[1]
                    $titleRaw = $Matches[2]
                }
                if (-not $href) { continue }
                if ($href -match '[?&]uddg=([^&"]+)') {
                    $href = ConvertFrom-UrlEncodedString -Text $Matches[1]
                }
                elseif ($href.StartsWith('//')) {
                    $href = 'https:' + $href
                }
                $title = (ConvertFrom-HtmlToText -Html $titleRaw) -replace '\s+', ' '
                $snippet = ''
                if ($blk -match '(?is)<(?:a|td|div|span)[^>]+class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|td|div|span)>') {
                    $snippet = (ConvertFrom-HtmlToText -Html $Matches[1]) -replace '\s+', ' '
                }
                $results += @{
                    title = $title.Trim()
                    url = $href.Trim()
                    snippet = $snippet.Trim()
                }
            }
        }
        $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
        Write-ToolCallCard -Name 'web_search' -Target $query -Status 'ok' -Summary "$($results.Count) results" -ElapsedMs $elapsedMs
        return (@{
            query = $query
            results = @($results)
            count = $results.Count
        } | ConvertTo-Json -Depth 6 -Compress)
    }
    finally {
        Remove-Item -LiteralPath $tempOut.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AgentTodo {
    param($Arguments)
    $toolStart = Get-Date
    $normList = @()
    foreach ($item in @($Arguments.todos)) {
        $cnt = [string]$item.content
        $st = ([string]$item.status).Trim().ToLower()
        if ($st -notin @('pending', 'in_progress', 'completed')) {
            $st = 'pending'
        }
        $normList += @{
            content = $cnt.Trim()
            status = $st
        }
    }
    $script:ActiveSessionTodos = @($normList)
    if ($null -ne $script:ActiveState) {
        $script:ActiveState.todos = @($normList)
    }
    $total = $normList.Count
    $completed = @($normList | Where-Object { $_.status -eq 'completed' }).Count
    $inProgress = @($normList | Where-Object { $_.status -eq 'in_progress' }).Count
    $pending = @($normList | Where-Object { $_.status -eq 'pending' }).Count
    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)

    $summaryText = "$completed/$total completed" + $(if ($inProgress -gt 0) { ", $inProgress in progress" } else { '' })
    Write-ToolCallCard -Name 'todo' -Target "$total tasks" -Status 'ok' -Summary $summaryText -ElapsedMs $elapsedMs
    Write-TodoCard -Todos $normList

    $resultObj = @{
        success = $true
        total = $total
        completed = $completed
        in_progress = $inProgress
        pending = $pending
        todos = @($normList)
    }
    return ($resultObj | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-AgentTool {
    param([string]$Root, $Call)
    try {
        $rawName = [string]$Call.function.name
        $name = Resolve-ToolCanonicalName -Name $rawName
        if ($name -notin @('list_files', 'read_file', 'find_files', 'grep_files', 'fetch_url', 'web_search', 'write_file', 'edit_file', 'run_command', 'run_agent', 'todo')) { throw 'Unknown tool.' }
        if ($script:AgentPermission -eq 'ReadOnly' -and $name -in @('write_file', 'edit_file', 'run_command')) {
            throw 'Permission mode ReadOnly does not allow file modifications or commands.'
        }
        if (-not (Test-IsToolEnabled -Name $name)) {
            throw "Tool '$name' is disabled by current tool configuration."
        }
        $arguments = $Call.function.arguments | ConvertFrom-Json -ErrorAction Stop
        if ($name -eq 'edit_file') {
            $arguments = Format-EditArguments -Arguments $arguments
        }
        elseif ($name -eq 'run_agent') {
            $arguments = Format-RunAgentArguments -Arguments $arguments
        }
        elseif ($name -eq 'todo') {
            $arguments = Format-TodoArguments -Arguments $arguments
        }
        Test-AgentToolArguments -Name $name -Arguments $arguments
        if ($name -eq 'todo') { return (Invoke-AgentTodo -Arguments $arguments) }
        if ($name -eq 'fetch_url') { return (Invoke-AgentFetchUrl -Arguments $arguments) }
        if ($name -eq 'web_search') { return (Invoke-AgentWebSearch -Arguments $arguments) }
        if ($name -eq 'run_agent') { return (Invoke-AgentSubagent -Root $Root -Arguments $arguments) }
        if ($name -eq 'run_command') { return (Invoke-AgentCommand -Root $Root -Arguments $arguments) }
        if ($name -in @('write_file', 'edit_file')) { return (Invoke-AgentWrite -Root $Root -Name $name -Arguments $arguments) }
        $toolStart = Get-Date
        $allowSkill = ($name -eq 'read_file')
        $path = Resolve-AgentPath -Root $Root -RelativePath $arguments.path -AllowRegisteredSkill:$allowSkill
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($name -eq 'list_files') {
            if (-not $item.PSIsContainer) { throw 'Expected a directory.' }
            $maxEntries = 200
            if ($null -ne $arguments.limit) {
                $maxEntries = [int]$arguments.limit
                if ($maxEntries -lt 1 -or $maxEntries -gt 500) { throw 'limit must be between 1 and 500.' }
            }
            $entries = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Where-Object {
                -not (Test-IsSecretFile $_)
            } | Sort-Object { $_.Name.ToLower() } | Select-Object -First ($maxEntries + 1))
            $isTrunc = ($entries.Count -gt $maxEntries)
            $shownEntries = @($entries | Select-Object -First $maxEntries -Property Name, PSIsContainer, Length)
            $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
            $sumText = "$($shownEntries.Count) entries" + $(if ($isTrunc) { ' (truncated)' } else { '' })
            Write-ToolCallCard -Name 'list_files' -Target $arguments.path -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
            $notice = if ($isTrunc) { "[${maxEntries} entries limit reached]" } else { $null }
            return (@{
                entries = $shownEntries
                truncated = $isTrunc
                notice = $notice
            } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($name -eq 'find_files') {
            if (-not $item.PSIsContainer) { throw 'Expected a directory.' }
            if (-not $arguments.pattern.Trim()) { throw 'pattern must be a nonempty string.' }
            $maxFind = 200
            if ($null -ne $arguments.limit) {
                $maxFind = [int]$arguments.limit
                if ($maxFind -lt 1 -or $maxFind -gt 1000) { throw 'limit must be between 1 and 1000.' }
            }
            $rawPat = $arguments.pattern.Trim()
            $isPathPat = ($rawPat.Contains('/') -or $rawPat.Contains('\'))
            $normPat = $rawPat.Replace('\', '/').TrimStart('/')
            $altPat = if ($normPat.StartsWith('**/')) { $normPat.Substring(3) } else { '' }
            $truncated = $false
            $matchCount = 0
            $found = @(foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $Root -SearchPath $path)) {
                $child = $walkEntry.item
                $relPath = $walkEntry.rel_path
                $relToSearch = Get-WorkspaceRelativePath -Root $path -FullPath $child.FullName
                $isMatch = if ($isPathPat) {
                    ($relPath -like $normPat) -or ($relToSearch -like $normPat) -or ($altPat -and (($relPath -like $altPat) -or ($relToSearch -like $altPat)))
                }
                else {
                    ($child.Name -like $rawPat)
                }
                if ($isMatch) {
                    if ($matchCount -ge $maxFind) { $truncated = $true; break }
                    $matchCount++
                    @{
                        path = $relPath
                        relative_path = $relToSearch
                        is_dir = [bool]$walkEntry.is_dir
                        length = if ($walkEntry.is_dir) { $null } else { $child.Length }
                    }
                }
            })
            $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
            $sumText = "$($found.Count) matches" + $(if ($truncated) { ' (truncated)' } else { '' })
            Write-ToolCallCard -Name 'find_files' -Target $arguments.path -Detail "pattern=$rawPat" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
            $notice = if ($truncated) { "[${maxFind} results limit reached. Refine pattern or increase limit]" } else { $null }
            return (@{ matches = @($found); files = @($found); count = $found.Count; truncated = $truncated; notice = $notice } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($name -eq 'grep_files') {
            if (-not $arguments.pattern) { throw 'pattern must be a nonempty string.' }
            $isLiteral = ($arguments.literal -eq $true)
            $isCaseSensitive = ($arguments.case_sensitive -eq $true)
            $includeFilter = if ($arguments.include -is [string] -and $arguments.include.Trim()) {
                $arguments.include.Trim()
            }
            elseif ($arguments.glob -is [string] -and $arguments.glob.Trim()) {
                $arguments.glob.Trim()
            }
            else {
                ''
            }
            $ctxLines = 0
            if ($null -ne $arguments.context_lines) {
                $ctxLines = [int]$arguments.context_lines
                if ($ctxLines -lt 0 -or $ctxLines -gt 5) { throw 'context_lines must be between 0 and 5.' }
            }
            $maxMatches = 100
            if ($null -ne $arguments.limit) {
                $maxMatches = [int]$arguments.limit
                if ($maxMatches -lt 1 -or $maxMatches -gt 500) { throw 'limit must be between 1 and 500.' }
            }
            $fileOffset = 0
            if ($null -ne $arguments.file_offset) {
                $fileOffset = [int]$arguments.file_offset
                if ($fileOffset -lt 0) { throw 'file_offset must be at least 0.' }
            }
            $startLine = 1
            if ($null -ne $arguments.start_line) {
                $startLine = [int]$arguments.start_line
                if ($startLine -lt 1) { throw 'start_line must be at least 1.' }
            }
            $allCandidateFiles = @(if ($item.PSIsContainer) {
                foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $Root -SearchPath $path -FilesOnly)) {
                    $child = $walkEntry.item
                    $relCandidate = $walkEntry.rel_path
                    if ($includeFilter -and ($child.Name -notlike $includeFilter) -and ($relCandidate -notlike $includeFilter)) { continue }
                    if ($child.Length -le 1MB) { $child.FullName }
                }
            }
            else {
                if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
                $item.FullName
            })
            # Offsets are stable while the candidate file set is unchanged.
            $allCandidateFiles = @($allCandidateFiles | Sort-Object -CaseSensitive)
            $totalFiles = $allCandidateFiles.Count
            $filesScanned = 0
            $fileLimitReached = $false
            $matchLimitReached = $false
            $linesTruncated = $false
            $hitCount = 0
            $hits = @()
            $nextFileOffset = $null
            $nextStartLine = $null
            for ($fileIndex = $fileOffset; $fileIndex -lt $totalFiles -and $filesScanned -lt 500; $fileIndex++) {
                $filesScanned++
                $firstLine = if ($fileIndex -eq $fileOffset) { $startLine } else { 1 }
                $selParams = @{ LiteralPath = $allCandidateFiles[$fileIndex]; Pattern = $arguments.pattern; Encoding = 'UTF8'; ErrorAction = 'Stop' }
                if ($isLiteral) { $selParams.SimpleMatch = $true }
                if ($isCaseSensitive) { $selParams.CaseSensitive = $true }
                if ($ctxLines -gt 0) { $selParams.Context = @($ctxLines, $ctxLines) }
                # Keep one lookahead match so continuation within a file starts
                # at the first result not returned, without buffering all matches.
                $pageMatches = @(Select-String @selParams | Where-Object { $_.LineNumber -ge $firstLine } | Select-Object -First ($maxMatches - $hitCount + 1))
                foreach ($m in $pageMatches) {
                    if ($hitCount -ge $maxMatches) {
                        $matchLimitReached = $true
                        $nextFileOffset = $fileIndex
                        $nextStartLine = [int]$m.LineNumber
                        break
                    }
                    $hitCount++
                    $lineText = [string]$m.Line
                    if ($lineText.Length -gt 300) {
                        $lineText = $lineText.Substring(0, 300) + '...'
                        $linesTruncated = $true
                    }
                    $hitObj = @{
                        path = (Get-WorkspaceRelativePath -Root $Root -FullPath $m.Path)
                        file = (Get-WorkspaceRelativePath -Root $path -FullPath $m.Path)
                        line_number = [int]$m.LineNumber
                        line = $lineText
                    }
                    if ($ctxLines -gt 0 -and $m.Context) {
                        $hitObj.context = @($m.Context.PreContext) + @($lineText) + @($m.Context.PostContext)
                    }
                    $hits += $hitObj
                }
                if ($matchLimitReached) { break }
                if ($fileIndex + 1 -lt $totalFiles) {
                    $matchLimitReached = ($hitCount -ge $maxMatches)
                    $fileLimitReached = ($filesScanned -ge 500)
                    if ($matchLimitReached -or $fileLimitReached) {
                        $nextFileOffset = $fileIndex + 1
                        $nextStartLine = 1
                        break
                    }
                }
            }
            $truncated = ($fileLimitReached -or $matchLimitReached)
            $truncReason = if ($matchLimitReached -and $fileLimitReached) {
                'max_matches_and_max_files'
            }
            elseif ($matchLimitReached) {
                'max_matches'
            }
            elseif ($fileLimitReached) {
                'max_files'
            }
            else {
                $null
            }
            $notices = @()
            if ($matchLimitReached) { $notices += "${maxMatches} matches limit reached" }
            if ($fileLimitReached) { $notices += "Scanned ${filesScanned} of ${totalFiles} files" }
            if ($truncated) { $notices += "Continue with file_offset=${nextFileOffset} and start_line=${nextStartLine} using the same search arguments" }
            if ($linesTruncated) { $notices += 'Some lines truncated to 300 chars; use read_file for full lines' }
            $noticeStr = if ($notices.Count -gt 0) { '[' + ($notices -join '. ') + ']' } else { $null }
            $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
            $sumText = "$($hits.Count) matches in $filesScanned files" + $(if ($truncated) { ' (truncated)' } else { '' })
            Write-ToolCallCard -Name 'grep_files' -Target $arguments.path -Detail "pattern=$($arguments.pattern)" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
            return (@{
                matches = @($hits)
                truncated = $truncated
                truncation_reason = $truncReason
                files_scanned = $filesScanned
                total_files = $totalFiles
                next_file_offset = $nextFileOffset
                next_start_line = $nextStartLine
                lines_truncated = $linesTruncated
                notice = $noticeStr
            } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($item.PSIsContainer) { throw 'Expected a text file.' }
        if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
        $startLine = 1
        if ($null -ne $arguments.start_line) {
            $startLine = [int]$arguments.start_line
            if ($startLine -lt 1) { throw 'start_line must be at least 1.' }
        }
        elseif ($null -ne $arguments.offset) {
            $startLine = [int]$arguments.offset
            if ($startLine -lt 1) { throw 'offset must be at least 1.' }
        }
        $startChar = 1
        if ($null -ne $arguments.start_char) {
            $startChar = [int]$arguments.start_char
            if ($startChar -lt 1) { throw 'start_char must be at least 1.' }
        }
        $maxLines = 300
        if ($null -ne $arguments.max_lines) {
            $maxLines = [int]$arguments.max_lines
            if ($maxLines -lt 1 -or $maxLines -gt 300) { throw 'max_lines must be between 1 and 300.' }
        }
        elseif ($null -ne $arguments.limit) {
            $maxLines = [int]$arguments.limit
            if ($maxLines -lt 1 -or $maxLines -gt 300) { throw 'limit must be between 1 and 300.' }
        }
        $allLines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)
        $totalLines = $allLines.Count
        $charBudget = 20000
        if ($totalLines -eq 0 -or $startLine -gt $totalLines) {
            $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
            Write-ToolCallCard -Name 'read_file' -Target $arguments.path -Detail "lines $startLine..$totalLines" -Status 'ok' -Summary "0 lines ($totalLines total)" -ElapsedMs $elapsedMs
            return (@{
                text = ''
                start_line = $startLine
                start_char = $startChar
                end_line = $totalLines
                total_lines = $totalLines
                truncated = $false
                next_start_line = $null
                next_start_char = $null
                notice = $null
            } | ConvertTo-Json -Compress)
        }
        $limitIdx = $startLine - 1 + $maxLines - 1
        if ($limitIdx -ge $totalLines) { $limitIdx = $totalLines - 1 }
        $pageLines = @()
        $currentLen = 0
        $endLine = $startLine - 1
        $truncated = $false
        $nextStartLine = $null
        $nextStartChar = $null
        for ($i = $startLine - 1; $i -le $limitIdx; $i++) {
            $lineStr = [string]$allLines[$i]
            if ($i -eq ($startLine - 1) -and $startChar -gt 1) {
                if ($startChar -gt ($lineStr.Length + 1)) {
                    $lineStr = ''
                }
                else {
                    $lineStr = $lineStr.Substring($startChar - 1)
                }
            }
            if ($pageLines.Count -eq 0 -and $lineStr.Length -gt $charBudget) {
                $pageLines += $lineStr.Substring(0, $charBudget)
                $endLine = $i + 1
                $truncated = $true
                $nextStartLine = $i + 1
                $nextStartChar = $startChar + $charBudget
                break
            }
            $addedLen = if ($pageLines.Count -eq 0) { $lineStr.Length } else { 1 + $lineStr.Length }
            if (($currentLen + $addedLen) -gt $charBudget) {
                $truncated = $true
                $nextStartLine = $i + 1
                $nextStartChar = $null
                break
            }
            $pageLines += $lineStr
            $currentLen += $addedLen
            $endLine = $i + 1
        }
        if (-not $truncated -and $endLine -lt $totalLines) {
            $truncated = $true
            $nextStartLine = $endLine + 1
            $nextStartChar = $null
        }
        $readNotice = if ($truncated -and $null -ne $nextStartChar) {
            "[Showing line ${startLine} chars ${startChar}..$($nextStartChar - 1). Use start_line=${nextStartLine}, start_char=${nextStartChar} to continue.]"
        }
        elseif ($truncated) {
            "[Showing lines ${startLine}-${endLine} of ${totalLines}. Use start_line=${nextStartLine} to continue.]"
        }
        else {
            $null
        }
        $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
        $sumText = "$($pageLines.Count) lines ($totalLines total)" + $(if ($truncated) { ' [paginated]' } else { '' })
        Write-ToolCallCard -Name 'read_file' -Target $arguments.path -Detail "lines $startLine..$endLine" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
        return (@{
            text = ($pageLines -join "`n")
            start_line = $startLine
            start_char = $startChar
            end_line = $endLine
            total_lines = $totalLines
            truncated = $truncated
            next_start_line = $nextStartLine
            next_start_char = $nextStartChar
            notice = $readNotice
        } | ConvertTo-Json -Compress)
    }
    catch { return (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
}
