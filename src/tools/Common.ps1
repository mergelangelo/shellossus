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
$script:ActiveState = $null
$script:SubagentDepth = 0
$script:MaxSubagentDepth = 1
$script:ActiveSessionTodos = @()
$script:AutoApproveWeb = $false
$script:AutoApproveCommands = $false
$script:PermissionRevision = 0
$script:StartupAgentPermission = 'Ask'
$script:StartupPermissionSpecified = $false
if (-not (Get-Variable -Name StandaloneScriptPath -Scope Script -ErrorAction SilentlyContinue)) {
    $script:StandaloneScriptPath = ''
}
$script:InternalWorkerFailed = $false

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
$script:RequestTimeoutSec = 180
$script:MinRequestTimeoutSec = 10
$script:MaxRequestTimeoutSec = 1800
$script:MaxStepRetryBudgetSec = 3600

function ConvertTo-AgentRequestTimeout {
    param([AllowEmptyString()][string]$TimeoutSpec)
    $err = 'RequestTimeoutSec must be an integer between 10 and 1800.'
    if ($null -eq $TimeoutSpec) { throw $err }
    $trimmed = $TimeoutSpec.Trim()
    if ($trimmed -notmatch '^\d{1,4}$') { throw $err }
    $val = [int]$trimmed
    if ($val -lt $script:MinRequestTimeoutSec -or $val -gt $script:MaxRequestTimeoutSec) {
        throw $err
    }
    return $val
}

function Set-AgentRequestTimeout {
    param([AllowEmptyString()][string]$TimeoutSpec)
    $val = ConvertTo-AgentRequestTimeout -TimeoutSpec $TimeoutSpec
    $script:RequestTimeoutSec = $val
    return $script:RequestTimeoutSec
}

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

function Get-AgentExecutionContext {
    return @{
        agent_permission = [string]$script:AgentPermission
        permission_revision = [long]$script:PermissionRevision
        auto_approve_commands = [bool]$script:AutoApproveCommands
        auto_approve_web = [bool]$script:AutoApproveWeb
        enabled_tools = @(if ($null -ne $script:EnabledTools) { @($script:EnabledTools) })
        excluded_tools = @(if ($null -ne $script:ExcludedTools) { @($script:ExcludedTools) })
        no_tools = [bool]$script:NoTools
        subagent_depth = [int]$script:SubagentDepth
        active_model_id = [string]$script:ActiveModelId
        active_endpoint = [string]$script:ActiveEndpoint
        active_workspace = [string]$script:ActiveWorkspace
        active_state = $script:ActiveState
        active_session_todos = @(if ($null -ne $script:ActiveSessionTodos) { Copy-SessionHashtableArray -Items $script:ActiveSessionTodos } else { @() })
        writes_count = @(if ($null -ne $script:CurrentTurnWrites) { @($script:CurrentTurnWrites) }).Count
    }
}

function Restore-AgentExecutionContext {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [switch]$PreserveSessionPermissionUpgrade,
        [bool]$AllowPermissionUpgrade = $false
    )
    $permRank = @{ ReadOnly = 0; Ask = 1; AutoEdit = 2; Auto = 3 }
    if ($PreserveSessionPermissionUpgrade -and $AllowPermissionUpgrade -and $Context.agent_permission -ne 'ReadOnly') {
        $curPerm = [string]$script:AgentPermission
        $ctxPerm = [string]$Context.agent_permission
        $curRank = if ($curPerm -and $null -ne $permRank[$curPerm]) { [int]$permRank[$curPerm] } else { -1 }
        $ctxRank = if ($ctxPerm -and $null -ne $permRank[$ctxPerm]) { [int]$permRank[$ctxPerm] } else { 0 }
        if ($curRank -gt $ctxRank) {
            # Keep session-wide [a]ll permission upgrade approved by the user during craft subagent
            $script:AgentPermission = $curPerm
        }
        else {
            $script:AgentPermission = $ctxPerm
        }
        if ([long]$script:PermissionRevision -gt [long]$Context.permission_revision) {
            $script:PermissionRevision = [long]$script:PermissionRevision
        }
        else {
            $script:PermissionRevision = [long]$Context.permission_revision
        }
        $script:AutoApproveCommands = [bool]($Context.auto_approve_commands -or $script:AutoApproveCommands)
        $script:AutoApproveWeb = [bool]($Context.auto_approve_web -or $script:AutoApproveWeb)
    }
    else {
        $script:AgentPermission = [string]$Context.agent_permission
        $script:PermissionRevision = [long]$Context.permission_revision
        $script:AutoApproveCommands = [bool]$Context.auto_approve_commands
        $script:AutoApproveWeb = [bool]$Context.auto_approve_web
    }
    $script:EnabledTools = @(if ($null -ne $Context.enabled_tools) { @($Context.enabled_tools) })
    $script:ExcludedTools = @(if ($null -ne $Context.excluded_tools) { @($Context.excluded_tools) })
    $script:NoTools = [bool]$Context.no_tools
    $script:SubagentDepth = [int]$Context.subagent_depth
    $script:ActiveModelId = [string]$Context.active_model_id
    $script:ActiveEndpoint = [string]$Context.active_endpoint
    $script:ActiveWorkspace = [string]$Context.active_workspace
    $script:ActiveState = $Context.active_state
    $script:ActiveSessionTodos = @(if ($null -ne $Context.active_session_todos) { Copy-SessionHashtableArray -Items $Context.active_session_todos } else { @() })
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

function Get-AgentFileContentDigest {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$LiteralPath)
    try {
        return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        $errId = [string]$_.FullyQualifiedErrorId
        $nestedId = if ($_.Exception -and $_.Exception.ErrorRecord) { [string]$_.Exception.ErrorRecord.FullyQualifiedErrorId } else { '' }
        $errMsg = [string]$_.Exception.Message
        $innerMsg = if ($_.Exception -and $_.Exception.InnerException) { [string]$_.Exception.InnerException.Message } else { '' }
        $isLanguageModeError = (
            $errId -match 'ConstrainedLanguage' -or
            $nestedId -match 'ConstrainedLanguage' -or
            $errMsg -match 'in this language mode' -or
            $innerMsg -match 'in this language mode'
        )
        if (-not $isLanguageModeError) {
            throw
        }
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "Expected a file at $LiteralPath."
    }
    $rawBytes = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Get-Content -LiteralPath $LiteralPath -Encoding Byte -ReadCount 0 -ErrorAction Stop
    }
    else {
        Get-Content -LiteralPath $LiteralPath -AsByteStream -ReadCount 0 -ErrorAction Stop
    }
    if ($null -eq $rawBytes) {
        $bytes = @()
    }
    elseif ($rawBytes -is [array]) {
        if ($rawBytes.Count -eq 1 -and $rawBytes[0] -is [array]) {
            $bytes = $rawBytes[0]
        }
        else {
            $bytes = $rawBytes
        }
    }
    else {
        $bytes = @([byte]$rawBytes)
    }
    $n = [long]$bytes.Count
    $m = 4294967295L
    $p1 = 16777619L
    $p2 = 15485863L
    $p3 = 16769023L
    $nLo = $n -band $m
    $nHi = ($n -shr 32) -band $m
    $h0 = (2166136261L -bxor $nLo) -band $m
    $h1 = (3266489917L -bxor (($nLo * $p2) -band $m)) -band $m
    $h2 = (668265263L -bxor ((($nLo -shl 7) -band $m) -bxor $nHi)) -band $m
    $h3 = (374761393L -bxor (($nLo * $p1) -band $m)) -band $m
    $h4 = (2654435761L + $nLo + $nHi) -band $m
    $h5 = (2246822519L -bxor (($nLo * 31L) -band $m)) -band $m
    $h6 = (3266489909L + (($nLo * 131L) -band $m)) -band $m
    $h7 = (1597334677L -bxor (($nLo * 8191L) -band $m)) -band $m
    $limit = $n - ($n % 16L)
    for ($i = 0L; $i -lt $limit; $i += 16L) {
        $idx = [int]$i
        $off = $i -band $m
        $w0 = [long]$bytes[$idx] -bor ([long]$bytes[$idx + 1] -shl 8) -bor ([long]$bytes[$idx + 2] -shl 16) -bor ([long]$bytes[$idx + 3] -shl 24)
        $w1 = [long]$bytes[$idx + 4] -bor ([long]$bytes[$idx + 5] -shl 8) -bor ([long]$bytes[$idx + 6] -shl 16) -bor ([long]$bytes[$idx + 7] -shl 24)
        $w2 = [long]$bytes[$idx + 8] -bor ([long]$bytes[$idx + 9] -shl 8) -bor ([long]$bytes[$idx + 10] -shl 16) -bor ([long]$bytes[$idx + 11] -shl 24)
        $w3 = [long]$bytes[$idx + 12] -bor ([long]$bytes[$idx + 13] -shl 8) -bor ([long]$bytes[$idx + 14] -shl 16) -bor ([long]$bytes[$idx + 15] -shl 24)
        $h0 = (((($h0 -bxor $w0 -bxor $off) * $p1) -band $m) + (($h7 -shr 11) -bxor (($h7 -shl 21) -band $m))) -band $m
        $h1 = (((($h1 -bxor $w1) * $p1) -band $m) + (($h0 -shr 13) -bxor (($h0 -shl 19) -band $m))) -band $m
        $h2 = (((($h2 -bxor $w2) * $p1) -band $m) + (($h1 -shr 17) -bxor (($h1 -shl 15) -band $m))) -band $m
        $h3 = (((($h3 -bxor $w3) * $p1) -band $m) + (($h2 -shr 7) -bxor (($h2 -shl 25) -band $m))) -band $m
        $h4 = ((((($h4 + $w2) -band $m) * $p2) -band $m) -bxor $h1) -band $m
        $h5 = ((((($h5 + $w3) -band $m) * $p2) -band $m) -bxor $h2) -band $m
        $h6 = ((((($h6 + $w0) -band $m) * $p3) -band $m) -bxor $h3) -band $m
        $h7 = ((((($h7 + $w1) -band $m) * $p3) -band $m) -bxor $h0) -band $m
    }
    for ($j = [int]$limit; $j -lt $n; $j++) {
        $b = [long]$bytes[$j]
        $h0 = (((($h0 -bxor $b) * $p1) -band $m) + (($j + 1L) -band $m)) -band $m
        $h4 = ((((($h4 + $b + 1L) -band $m) * $p2) -band $m) -bxor $h0) -band $m
        $t = $h0; $h0 = $h1; $h1 = $h2; $h2 = $h3; $h3 = $h4; $h4 = $h5; $h5 = $h6; $h6 = $h7; $h7 = $t
    }
    for ($r = 0; $r -lt 4; $r++) {
        $h0 = (((($h0 -bxor ($h7 -shr 15)) * $p1) -band $m) + $h3) -band $m
        $h1 = (((($h1 -bxor ($h0 -shr 13)) * $p2) -band $m) + $h4) -band $m
        $h2 = (((($h2 -bxor ($h1 -shr 16)) * $p3) -band $m) + $h5) -band $m
        $h3 = (((($h3 -bxor ($h2 -shr 15)) * $p1) -band $m) + $h6) -band $m
        $h4 = (((($h4 -bxor ($h3 -shr 13)) * $p2) -band $m) + $h7) -band $m
        $h5 = (((($h5 -bxor ($h4 -shr 16)) * $p3) -band $m) + $h0) -band $m
        $h6 = (((($h6 -bxor ($h5 -shr 15)) * $p1) -band $m) + $h1) -band $m
        $h7 = (((($h7 -bxor ($h6 -shr 13)) * $p2) -band $m) + $h2) -band $m
    }
    return ('CLM256-{0:X8}{1:X8}{2:X8}{3:X8}{4:X8}{5:X8}{6:X8}{7:X8}-{8:X12}' -f $h0, $h1, $h2, $h3, $h4, $h5, $h6, $h7, $n)
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

function Resolve-ValidatedWorkerScriptPath {
    param([string]$Path)
    if (-not $Path -or -not $Path.Trim()) {
        throw 'Worker script path is required.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Worker script was not found: $Path"
    }
    if (Test-PathHasReparsePoint -Path $Path) {
        throw 'Reparse points are not allowed for worker script paths.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "Worker script must be a file: $Path"
    }
    if (Test-PathHasReparsePoint -Path $item.FullName) {
        throw 'Reparse points are not allowed for worker script paths.'
    }
    return [string]$item.FullName
}

function Resolve-StandaloneScriptPath {
    param([switch]$Required)
    if ($script:StandaloneScriptPath) {
        if ((Test-Path -LiteralPath $script:StandaloneScriptPath -PathType Leaf) -and (-not (Test-PathHasReparsePoint -Path $script:StandaloneScriptPath))) {
            $expItem = Get-Item -LiteralPath $script:StandaloneScriptPath -Force -ErrorAction SilentlyContinue
            if ($expItem -and (-not $expItem.PSIsContainer) -and (-not (Test-PathHasReparsePoint -Path $expItem.FullName))) {
                return [string]$expItem.FullName
            }
        }
        if ($Required) {
            throw 'Standalone script path could not be resolved for background worker.'
        }
        return ''
    }
    $cands = @()
    if ($script:BundledScriptPath) {
        $cands += $script:BundledScriptPath
    }
    if ($PSScriptRoot) {
        $cands += (Join-Path $PSScriptRoot 'shellossus.ps1')
        $parentDir = Split-Path $PSScriptRoot -Parent
        if ($parentDir) {
            $cands += (Join-Path $parentDir 'shellossus.ps1')
            $grandParentDir = Split-Path $parentDir -Parent
            if ($grandParentDir) {
                $cands += (Join-Path $grandParentDir 'shellossus.ps1')
            }
        }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf) -and (-not (Test-PathHasReparsePoint -Path $c))) {
            $item = Get-Item -LiteralPath $c -Force -ErrorAction SilentlyContinue
            if ($item -and (-not $item.PSIsContainer) -and (-not (Test-PathHasReparsePoint -Path $item.FullName))) {
                return [string]$item.FullName
            }
        }
    }
    if ($Required) {
        throw 'Standalone script path could not be resolved for background worker.'
    }
    return ''
}

function Get-AgentWorkerArguments {
    param(
        [string]$ScriptPath,
        [string]$WorkerMode
    )
    if (-not $ScriptPath -or -not $ScriptPath.Trim()) {
        throw 'Worker script path is required.'
    }
    if ($WorkerMode -notin @('http', 'web', 'subagent')) {
        throw 'Unsupported internal worker mode.'
    }
    $escapedPath = ($ScriptPath -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
    if ($env:OS -eq 'Windows_NT') {
        return "-NoProfile -NonInteractive -OutputFormat Text -File `"$escapedPath`" -InternalWorker $WorkerMode"
    }
    # Start-Process joins ArgumentList into ProcessStartInfo.Arguments without quoting spaces.
    $posixFileArg = if ($ScriptPath -match '[\s"]') { "`"$escapedPath`"" } else { $ScriptPath }
    return @('-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-File', $posixFileArg, '-InternalWorker', $WorkerMode)
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
