# Tool runtime state, canonical name resolution, enablement checks, output truncation, and environment inspection.

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
$script:AutoApproveWeb = $false
$script:AutoApproveCommands = $false
$script:PermissionRevision = 0
$script:StartupAgentPermission = 'Ask'
$script:StartupPermissionSpecified = $false

$script:AgentMaxApiResponseBytes = 8MB
$script:AgentMaxToolArgumentBytes = 1MB
$script:AgentMaxTurnToolCalls = 128
$script:AgentMaxTurnPayloadBytes = 32MB
$script:AgentMaxBatchEdits = 64
$script:AgentMaxMemoryBytes = 256KB
$script:AgentMaxSessionBytes = 32MB
$script:AgentMaxSessionRecords = 10000
$script:AgentMaxTreeEntries = 5000
$script:AgentMaxUndoFrames = 20
$script:AgentMaxDiagnosticsEntries = 100
$script:AgentMaxWalkEntries = 10000

function Get-CurrentTurnWritePathsSince {
    param([int]$StartCount)
    $paths = @()
    $seen = @{}
    $writes = @($script:CurrentTurnWrites)
    if ($StartCount -lt 0) { $StartCount = 0 }
    for ($i = $StartCount; $i -lt $writes.Count; $i++) {
        $entry = $writes[$i]
        if (-not $entry) { continue }
        $rel = ''
        if ($entry.rel_path) { $rel = [string]$entry.rel_path }
        if (-not $rel) { continue }
        if ($seen.ContainsKey($rel)) { continue }
        $seen[$rel] = $true
        $paths += $rel
    }
    return ,$paths
}

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
        'ask_user' { return 'ask_user' }
        'ask' { return 'ask_user' }
        'ask_question' { return 'ask_user' }
        'ask_user_question' { return 'ask_user' }
        'plan_review' { return 'ask_user' }
        'plan-review' { return 'ask_user' }
        'question' { return 'ask_user' }
        'user_question' { return 'ask_user' }
        'memory' { return 'memory' }
        'remember' { return 'memory' }
        'manage_memory' { return 'memory' }
        'recall' { return 'memory' }
        'note' { return 'memory' }
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

function Get-AgentUtf8ByteCount {
    param([string]$Text)
    if ($Text -cnotmatch '[^\x00-\x7f]') { return $Text.Length }
    # Count UTF-8 bytes using operators available in ConstrainedLanguage.
    # A surrogate pair uses four bytes; an isolated surrogate encodes as U+FFFD.
    return ($Text -creplace '[\ud800-\udbff][\udc00-\udfff]', 'xxxx' -creplace '[\u0080-\u07ff]', 'xx' -creplace '[\u0800-\uffff]', 'xxx').Length
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

function New-TruncateResult {
    param(
        [string]$Content, [bool]$Truncated, $TruncatedBy,
        [int]$TotalLines, [int]$TotalBytes, [int]$OutputLines, [int]$OutputBytes,
        [bool]$LastLinePartial, [bool]$FirstLineExceedsLimit,
        [int]$MaxLines, [int]$MaxBytes
    )
    return @{
        content = $Content
        truncated = $Truncated
        truncatedBy = $TruncatedBy
        truncated_by = $TruncatedBy
        totalLines = $TotalLines
        total_lines = $TotalLines
        totalBytes = $TotalBytes
        total_bytes = $TotalBytes
        outputLines = $OutputLines
        output_lines = $OutputLines
        outputBytes = $OutputBytes
        output_bytes = $OutputBytes
        lastLinePartial = $LastLinePartial
        firstLineExceedsLimit = $FirstLineExceedsLimit
        maxLines = $MaxLines
        maxBytes = $MaxBytes
    }
}

function Invoke-TruncateHead {
    param([string]$Content, [int]$MaxLines = 2000, [int]$MaxBytes = 51200)
    if (-not $Content) {
        return (New-TruncateResult -Content '' -Truncated $false -TruncatedBy $null `
            -TotalLines 0 -TotalBytes 0 -OutputLines 0 -OutputBytes 0 `
            -LastLinePartial $false -FirstLineExceedsLimit $false `
            -MaxLines $MaxLines -MaxBytes $MaxBytes)
    }
    $norm = $Content.Replace("`r`n", "`n")
    $lines = @($norm -split "`n")
    if ($norm.EndsWith("`n") -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $totalLines = $lines.Count
    $totalBytes = Get-AgentUtf8ByteCount $norm
    if ($totalLines -le $MaxLines -and $totalBytes -le $MaxBytes) {
        return (New-TruncateResult -Content $norm -Truncated $false -TruncatedBy $null `
            -TotalLines $totalLines -TotalBytes $totalBytes -OutputLines $totalLines -OutputBytes $totalBytes `
            -LastLinePartial $false -FirstLineExceedsLimit $false `
            -MaxLines $MaxLines -MaxBytes $MaxBytes)
    }
    if ($lines.Count -gt 0 -and (Get-AgentUtf8ByteCount $lines[0]) -gt $MaxBytes) {
        return (New-TruncateResult -Content '' -Truncated $true -TruncatedBy 'bytes' `
            -TotalLines $totalLines -TotalBytes $totalBytes -OutputLines 0 -OutputBytes 0 `
            -LastLinePartial $false -FirstLineExceedsLimit $true `
            -MaxLines $MaxLines -MaxBytes $MaxBytes)
    }
    $outBytes = 0
    $truncBy = 'lines'
    $outLines = @(for ($i = 0; $i -lt $lines.Count -and $i -lt $MaxLines; $i++) {
        $ln = [string]$lines[$i]
        $lnBytes = (Get-AgentUtf8ByteCount $ln) + $(if ($i -gt 0) { 1 } else { 0 })
        if (($outBytes + $lnBytes) -gt $MaxBytes) {
            $truncBy = 'bytes'
            break
        }
        $outBytes += $lnBytes
        $ln
    })
    if ($outLines.Count -ge $MaxLines -and $truncBy -ne 'bytes') {
        $truncBy = 'lines'
    }
    $outText = $outLines -join "`n"
    return (New-TruncateResult -Content $outText -Truncated $true -TruncatedBy $truncBy `
        -TotalLines $totalLines -TotalBytes $totalBytes -OutputLines $outLines.Count -OutputBytes (Get-AgentUtf8ByteCount $outText) `
        -LastLinePartial $false -FirstLineExceedsLimit $false `
        -MaxLines $MaxLines -MaxBytes $MaxBytes)
}

function Invoke-TruncateTail {
    param([string]$Content, [int]$MaxLines = 2000, [int]$MaxBytes = 51200)
    if (-not $Content) {
        return (New-TruncateResult -Content '' -Truncated $false -TruncatedBy $null `
            -TotalLines 0 -TotalBytes 0 -OutputLines 0 -OutputBytes 0 `
            -LastLinePartial $false -FirstLineExceedsLimit $false `
            -MaxLines $MaxLines -MaxBytes $MaxBytes)
    }
    $norm = $Content.Replace("`r`n", "`n")
    $lines = @($norm -split "`n")
    if ($norm.EndsWith("`n") -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $totalLines = $lines.Count
    $totalBytes = Get-AgentUtf8ByteCount $norm
    if ($totalLines -le $MaxLines -and $totalBytes -le $MaxBytes) {
        return (New-TruncateResult -Content $norm -Truncated $false -TruncatedBy $null `
            -TotalLines $totalLines -TotalBytes $totalBytes -OutputLines $totalLines -OutputBytes $totalBytes `
            -LastLinePartial $false -FirstLineExceedsLimit $false `
            -MaxLines $MaxLines -MaxBytes $MaxBytes)
    }
    $outBytes = 0
    $truncBy = 'lines'
    $lastPartial = $false
    $revLines = @(for ($i = $lines.Count - 1; $i -ge 0 -and (($lines.Count - 1 - $i) -lt $MaxLines); $i--) {
        $ln = [string]$lines[$i]
        $isFirst = ($i -eq ($lines.Count - 1))
        $lnBytes = (Get-AgentUtf8ByteCount $ln) + $(if (-not $isFirst) { 1 } else { 0 })
        if (($outBytes + $lnBytes) -gt $MaxBytes) {
            $truncBy = 'bytes'
            if ($isFirst) {
                $lastPartial = $true
                $low = if ($ln.Length -gt $MaxBytes) { $ln.Length - $MaxBytes } else { 0 }
                $high = $ln.Length
                while ($low -lt $high) {
                    $mid = ($low + $high) -shr 1
                    if ((Get-AgentUtf8ByteCount ($ln.Substring($mid))) -gt $MaxBytes) { $low = $mid + 1 }
                    else { $high = $mid }
                }
                if ($low -gt 0 -and $low -lt $ln.Length -and [char]::IsSurrogatePair($ln, $low - 1)) { $low++ }
                $outBytes = Get-AgentUtf8ByteCount ($ln.Substring($low))
                if ($outBytes -gt 0) { $ln.Substring($low) }
            }
            break
        }
        $outBytes += $lnBytes
        $ln
    })
    $outLines = @(for ($j = $revLines.Count - 1; $j -ge 0; $j--) {
        $revLines[$j]
    })
    if ($outLines.Count -ge $MaxLines -and $truncBy -ne 'bytes') {
        $truncBy = 'lines'
    }
    $outText = $outLines -join "`n"
    return (New-TruncateResult -Content $outText -Truncated $true -TruncatedBy $truncBy `
        -TotalLines $totalLines -TotalBytes $totalBytes -OutputLines $outLines.Count -OutputBytes (Get-AgentUtf8ByteCount $outText) `
        -LastLinePartial $lastPartial -FirstLineExceedsLimit $false `
        -MaxLines $MaxLines -MaxBytes $MaxBytes)
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
    $shellExe = if ($editionName -eq 'Core') { 'pwsh' } else { 'powershell' }
    return @{
        os = $osDesc
        ps_version = $psVer
        ps_edition = $editionName
        language_mode = $langMode
        shell_exe = $shellExe
        shell_version = $psVer
        workspace = [string]$effRoot
    }
}

function Get-AgentPowerShellExecutable {
    $name = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' }
    elseif ($IsWindows) { 'pwsh.exe' }
    else { 'pwsh' }
    $path = Join-Path $PSHOME $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)) {
        throw "PowerShell executable was not found in the current installation: $path"
    }
    return $path
}

function Get-AgentWorkerArguments {
    param([string]$CommandText)
    # -EncodedCommand takes Base64 of UTF-16LE. Use operators for CLM compatibility.
    $bytes = [byte[]]::new($CommandText.Length * 2)
    for ($i = 0; $i -lt $CommandText.Length; $i++) {
        $code = [int][char]$CommandText[$i]
        $bytes[2 * $i] = $code -band 255
        $bytes[2 * $i + 1] = $code -shr 8
    }
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $encoded = -join @(for ($i = 0; $i -lt $bytes.Length; $i += 3) {
        $first = $bytes[$i]
        $hasSecond = ($i + 1 -lt $bytes.Length)
        $hasThird = ($i + 2 -lt $bytes.Length)
        $second = if ($hasSecond) { $bytes[$i + 1] } else { 0 }
        $third = if ($hasThird) { $bytes[$i + 2] } else { 0 }
        $alphabet[$first -shr 2]
        $alphabet[(($first -band 3) -shl 4) -bor ($second -shr 4)]
        if ($hasSecond) { $alphabet[(($second -band 15) -shl 2) -bor ($third -shr 6)] } else { '=' }
        if ($hasThird) { $alphabet[$third -band 63] } else { '=' }
    })
    return @('-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $encoded)
}

function Get-AgentCommandArguments {
    param([string]$CommandText)
    # Windows is one argument string. Elsewhere the raw command is the fourth element.
    # Never adds -ExecutionPolicy.
    if ($env:OS -eq 'Windows_NT') {
        $escaped = ($CommandText -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
        return "-NoProfile -NonInteractive -Command `"$escaped`""
    }
    return @('-NoProfile', '-NonInteractive', '-Command', $CommandText)
}

function Invoke-WithProcessEnvironment {
    param([hashtable]$Values, [scriptblock]$Action)
    # A null value removes that name for the action. Any other value is set.
    # A name that was present is restored with Set-Item. A name that was absent is removed.
    $names = @($Values.Keys)
    $present = @{}
    $prior = @{}
    foreach ($name in $names) {
        $item = Get-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            $present[$name] = $false
        }
        else {
            $present[$name] = $true
            $prior[$name] = [string]$item.Value
        }
    }
    try {
        foreach ($name in $names) {
            if ($null -eq $Values[$name]) {
                Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -LiteralPath ('Env:' + $name) -Value ([string]$Values[$name])
            }
        }
        & $Action
    }
    finally {
        foreach ($name in $names) {
            if ($present[$name]) {
                Set-Item -LiteralPath ('Env:' + $name) -Value $prior[$name]
            }
            else {
                Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
            }
        }
    }
}
