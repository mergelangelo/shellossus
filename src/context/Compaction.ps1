# Token budgeting, message token estimation, and structured context handoff compaction.

function Resolve-TokenBudgetValue {
    param([string]$Spec, [int]$BaseTokens = 0)
    if (-not $Spec -or -not $Spec.Trim()) { return 0 }
    $s = $Spec.Trim().ToLower()
    if ($s -match '^(\d+(?:\.\d+)?)%$') {
        if ($BaseTokens -le 0) { throw "Percentage '$Spec' requires a base context window." }
        $pct = [double]$Matches[1]
        if ($pct -lt 10 -or $pct -gt 100) { throw 'Auto-compact percentage must be between 10% and 100%.' }
        return [int](($BaseTokens * $pct) / 100.0)
    }
    if ($s -match '^(\d+(?:\.\d+)?)k$') {
        return [int](([double]$Matches[1]) * 1000.0)
    }
    if ($s -match '^(\d+(?:\.\d+)?)m$') {
        return [int](([double]$Matches[1]) * 1000000.0)
    }
    if ($s -match '^\d+$') {
        return [int]$s
    }
    throw "Invalid token value '$Spec'. Use a number like 128k, 96k, 64000, or a percentage like 75%."
}

function Set-AgentContextLimits {
    param([string]$WindowSpec = '', [string]$CompactSpec = '')
    $winTok = if ($WindowSpec -and $WindowSpec.Trim()) {
        Resolve-TokenBudgetValue -Spec $WindowSpec
    }
    elseif ($script:ContextWindowTokens -gt 0) {
        [int]$script:ContextWindowTokens
    }
    else {
        128000
    }
    if ($winTok -lt 4000 -or $winTok -gt 2000000) {
        throw 'Context window must be between 4k and 2000k tokens.'
    }
    $compTok = if ($CompactSpec -and $CompactSpec.Trim()) {
        Resolve-TokenBudgetValue -Spec $CompactSpec -BaseTokens $winTok
    }
    elseif ($WindowSpec -and $WindowSpec.Trim()) {
        [int](($winTok * 75) / 100)
    }
    elseif ($script:CompactThresholdTokens -gt 0 -and $script:CompactThresholdTokens -le $winTok) {
        [int]$script:CompactThresholdTokens
    }
    else {
        [int](($winTok * 75) / 100)
    }
    if ($compTok -lt 2000 -or $compTok -gt $winTok) {
        throw "Auto-compact threshold ($compTok) must be between 2k and context window ($winTok)."
    }
    $script:ContextWindowTokens = $winTok
    $script:CompactThresholdTokens = $compTok
    return @{
        context_window_tokens = $script:ContextWindowTokens
        compact_threshold_tokens = $script:CompactThresholdTokens
        compact_pct = [int](($script:CompactThresholdTokens * 100) / $script:ContextWindowTokens)
    }
}

function Get-MessageEstimatedTokens {
    param($Message)
    if ($null -eq $Message) { return 0 }
    $chars = 0
    if ($Message.content) { $chars += ([string]$Message.content).Length }
    if ($Message.reasoning_content) { $chars += ([string]$Message.reasoning_content).Length }
    if ($Message.tool_calls) { $chars += (($Message.tool_calls | ConvertTo-Json -Depth 10 -Compress)).Length }
    return [int](($chars + 3) / 4)
}

function Get-ContextStats {
    param($State)
    $chars = 0
    $msgCount = 0
    if ($State -and $State.messages) {
        $msgCount = $State.messages.Count
        foreach ($m in @($State.messages)) {
            if ($m.content) { $chars += ([string]$m.content).Length }
            if ($m.reasoning_content) { $chars += ([string]$m.reasoning_content).Length }
            if ($m.tool_calls) { $chars += (($m.tool_calls | ConvertTo-Json -Depth 10 -Compress)).Length }
        }
    }
    $charTokens = [int](($chars + 3) / 4)
    $tokens = if ($State -and $State.last_prompt_tokens -gt 0 -and $State.last_prompt_chars -gt 0 -and $chars -ge [int]$State.last_prompt_chars) {
        [int]$State.last_prompt_tokens + [int]((($chars - [int]$State.last_prompt_chars) + 3) / 4)
    }
    else {
        $charTokens
    }
    $winTok = if ($script:ContextWindowTokens -gt 0) { [int]$script:ContextWindowTokens } else { 128000 }
    $compTok = if ($script:CompactThresholdTokens -gt 0 -and $script:CompactThresholdTokens -le $winTok) { [int]$script:CompactThresholdTokens } else { [int](($winTok * 75) / 100) }
    $compPct = [int](($compTok * 100) / $winTok)
    $usageIn = if ($State -and $State.usage_input_tokens) { [int]$State.usage_input_tokens } else { 0 }
    $usageOut = if ($State -and $State.usage_output_tokens) { [int]$State.usage_output_tokens } else { 0 }
    return @{
        messages = $msgCount
        chars = $chars
        est_tokens = $tokens
        context_window_tokens = $winTok
        compact_threshold_tokens = $compTok
        compact_pct = $compPct
        usage_input_tokens = $usageIn
        usage_output_tokens = $usageOut
        usage_total_tokens = ($usageIn + $usageOut)
    }
}

function Find-CompactionCutPoint {
    param([array]$Messages, [int]$StartIndex = 1, [int]$KeepRecent = 4, [int]$KeepRecentTokens = 0)
    $startIdx = if ($StartIndex -gt 1) { $StartIndex } else { 1 }
    $validCuts = @()
    for ($i = $startIdx; $i -lt $Messages.Count; $i++) {
        if ($Messages[$i].role -ne 'tool') {
            $validCuts += $i
        }
    }
    if ($validCuts.Count -eq 0) {
        return @{ cut_index = $startIdx; first_kept_index = $startIdx; turn_start_index = -1; is_split_turn = $false }
    }
    $targetCut = $Messages.Count - $KeepRecent
    if ($KeepRecentTokens -gt 0) {
        $accTokens = 0
        $tokenCut = $validCuts[0]
        for ($i = $Messages.Count - 1; $i -ge $startIdx; $i--) {
            $accTokens += (Get-MessageEstimatedTokens -Message $Messages[$i])
            if ($accTokens -ge $KeepRecentTokens) {
                $foundCand = $null
                foreach ($vc in $validCuts) {
                    if ($vc -ge $i) { $foundCand = $vc; break }
                }
                $tokenCut = if ($null -ne $foundCand) { $foundCand } else { $validCuts[$validCuts.Count - 1] }
                break
            }
        }
        $targetCut = $tokenCut
    }
    if ($targetCut -lt $startIdx) { $targetCut = $startIdx }
    if ($targetCut -ge $Messages.Count) { $targetCut = $Messages.Count - 1 }
    while ($targetCut -gt $startIdx -and $Messages[$targetCut].role -eq 'tool') {
        $targetCut--
    }
    if ($targetCut -le $startIdx) {
        $targetCut = $Messages.Count - $KeepRecent
        if ($targetCut -lt $startIdx) { $targetCut = $startIdx }
        while ($targetCut -lt ($Messages.Count - 1) -and $Messages[$targetCut].role -eq 'tool') {
            $targetCut++
        }
    }
    $isSplit = $false
    $turnStart = -1
    if ($targetCut -gt $startIdx -and $Messages[$targetCut].role -eq 'assistant') {
        for ($j = $targetCut - 1; $j -ge $startIdx; $j--) {
            if ($Messages[$j].role -eq 'user') {
                $turnStart = $j
                $isSplit = $true
                break
            }
        }
    }
    return @{
        cut_index = $targetCut
        first_kept_index = $targetCut
        turn_start_index = $turnStart
        is_split_turn = $isSplit
    }
}

function Get-CompactionFileOperations {
    param([array]$Messages)
    $readSet = @{}
    $modSet = @{}
    $toolResultsById = @{}
    foreach ($m in $Messages) {
        if ($m -and $m.role -eq 'tool' -and $m.tool_call_id -and $m.content -is [string]) {
            $toolResultsById[[string]$m.tool_call_id] = [string]$m.content
        }
    }
    foreach ($m in $Messages) {
        if ($m.role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Compacted Conversation Summary]')) {
            $cText = [string]$m.content
            if ($cText -match '(?s)<read-files>\r?\n(.*?)\r?\n</read-files>') {
                foreach ($rf in @($Matches[1] -split '\r?\n')) {
                    if ($rf.Trim()) { $readSet[$rf.Trim()] = $true }
                }
            }
            if ($cText -match '(?s)<modified-files>\r?\n(.*?)\r?\n</modified-files>') {
                foreach ($mf in @($Matches[1] -split '\r?\n')) {
                    if ($mf.Trim()) { $modSet[$mf.Trim()] = $true }
                }
            }
        }
        if ($m.tool_calls) {
            foreach ($tc in @($m.tool_calls)) {
                $tcId = if ($tc -and $tc.id) { [string]$tc.id } else { '' }
                if (-not $tcId -or -not $toolResultsById.ContainsKey($tcId)) { continue }
                $rawToolOut = $toolResultsById[$tcId]
                if (-not $rawToolOut) { continue }
                $parsedToolRes = $null
                try {
                    $parsedToolRes = $rawToolOut | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    continue
                }
                if ($null -eq $parsedToolRes -or $parsedToolRes.error) { continue }
                $rawFnName = if ($tc.function -and $tc.function.name) { [string]$tc.function.name } else { '' }
                $fnName = if (Get-Command -Name 'Resolve-ToolCanonicalName' -ErrorAction SilentlyContinue) {
                    Resolve-ToolCanonicalName -Name $rawFnName
                }
                else {
                    $rawFnName
                }
                $fnArgsRaw = if ($tc.function -and $tc.function.arguments) { [string]$tc.function.arguments } else { '' }
                if (-not $fnArgsRaw) { continue }
                try {
                    $parsedArgs = $fnArgsRaw | ConvertFrom-Json -ErrorAction Stop
                    $p = if ($parsedArgs.path) { [string]$parsedArgs.path } else { '' }
                    if ($p) {
                        if ($fnName -in @('read_file', 'read')) {
                            if ($parsedToolRes.status -notin @('cancelled', 'instructions_required', 'repeated_call_warning', 'loop_detected', 'error')) {
                                $readSet[$p] = $true
                            }
                        }
                        elseif ($fnName -in @('write_file', 'edit_file', 'write', 'edit')) {
                            if ($parsedToolRes.status -eq 'written') {
                                $modSet[$p] = $true
                            }
                        }
                    }
                }
                catch {}
            }
        }
        if ($m.role -eq 'tool' -and $m.content -is [string] -and ($m.content.Contains('"read_files"') -or $m.content.Contains('"modified_files"'))) {
            try {
                $parsedToolOut = $m.content | ConvertFrom-Json -ErrorAction Stop
                if (-not $parsedToolOut.error) {
                    if ($parsedToolOut.read_files) {
                        foreach ($srf in @($parsedToolOut.read_files)) {
                            if ($srf -and ([string]$srf).Trim()) { $readSet[([string]$srf).Trim()] = $true }
                        }
                    }
                    if ($parsedToolOut.modified_files) {
                        foreach ($smf in @($parsedToolOut.modified_files)) {
                            if ($smf -and ([string]$smf).Trim()) { $modSet[([string]$smf).Trim()] = $true }
                        }
                    }
                }
            }
            catch {}
        }
    }
    $readOnly = @($readSet.Keys | Where-Object { -not $modSet.ContainsKey($_) } | Sort-Object)
    $modified = @($modSet.Keys | Sort-Object)
    $sections = @()
    if ($readOnly.Count -gt 0) {
        $sections += ("<read-files>`n" + ($readOnly -join "`n") + "`n</read-files>")
    }
    if ($modified.Count -gt 0) {
        $sections += ("<modified-files>`n" + ($modified -join "`n") + "`n</modified-files>")
    }
    $xmlSuffix = if ($sections.Count -gt 0) { "`n`n" + ($sections -join "`n`n") } else { '' }
    return @{
        read_files = $readOnly
        modified_files = $modified
        xml = $xmlSuffix
    }
}

function Invoke-AgentCompact {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [string]$Focus = '', [int]$KeepRecent = 4, [int]$KeepRecentTokens = 0)
    if ($State.messages.Count -le ($KeepRecent + 1)) { return $false }
    Ensure-SessionTree -State $State
    $cutInfo = Find-CompactionCutPoint -Messages $State.messages -KeepRecent $KeepRecent -KeepRecentTokens $KeepRecentTokens
    $cutIndex = $cutInfo.cut_index
    if ($cutIndex -le 1) { return $false }
    $toSummarize = @($State.messages[1..($cutIndex - 1)])
    $recent = @($State.messages[$cutIndex..($State.messages.Count - 1)])
    $fileOps = Get-CompactionFileOperations -Messages $toSummarize
    $previousSummary = ''
    $transcript = @()
    foreach ($m in $toSummarize) {
        $role = [string]$m.role
        if ($role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Compacted Conversation Summary]')) {
            $prevRaw = ([string]$m.content).Substring('[Compacted Conversation Summary]'.Length).Trim()
            $prevRaw = $prevRaw -replace '(?s)\r?\n\r?\n<read-files>.*$', ''
            $prevRaw = $prevRaw -replace '(?s)\r?\n\r?\n<modified-files>.*$', ''
            $previousSummary = $prevRaw.Trim()
            continue
        }
        if ($role -eq 'tool') {
            $tcId = if ($m.tool_call_id) { " id=$($m.tool_call_id)" } else { '' }
            $resText = [string]$m.content
            if ($resText.Length -gt 2000) { $resText = $resText.Substring(0, 2000) + "`n`n[... $(($m.content).Length - 2000) more characters truncated]" }
            $transcript += "[tool_result$tcId]: $resText"
            continue
        }
        $parts = @()
        if ($m.content) {
            $text = [string]$m.content
            if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + '...(truncated)' }
            $parts += $text
        }
        if ($m.tool_calls) {
            foreach ($tc in @($m.tool_calls)) {
                $fnName = if ($tc.function -and $tc.function.name) { [string]$tc.function.name } else { 'unknown_tool' }
                $fnArgs = if ($tc.function -and $tc.function.arguments) { [string]$tc.function.arguments } else { '{}' }
                if ($fnArgs.Length -gt 1000) { $fnArgs = $fnArgs.Substring(0, 1000) + '...(truncated)' }
                $tcId = if ($tc.id) { " id=$($tc.id)" } else { '' }
                $parts += "[tool_call$tcId $fnName($fnArgs)]"
            }
        }
        $transcript += "[$role]: " + ($parts -join "`n")
    }
    $prompt = if ($previousSummary) {
        "Update the existing structured summary in <previous-summary> with the new conversation messages above using these exact Markdown sections:`n## Goal`n## Constraints & Preferences`n## Progress (Done / In Progress / Blocked)`n## Key Decisions`n## Next Steps`n## Critical Context (file paths, schemas, queries, errors)`nPreserve existing information and exact file paths."
    }
    else {
        "Summarize the conversation history above into a structured context handoff using these exact Markdown sections:`n## Goal`n## Constraints & Preferences`n## Progress (Done / In Progress / Blocked)`n## Key Decisions`n## Next Steps`n## Critical Context (file paths, schemas, queries, errors)`nBe concise and factual."
    }
    if ($Focus) { $prompt += "`nFocus especially on: $Focus" }
    $userBody = "<conversation>`n" + ($transcript -join "`n`n") + "`n</conversation>`n`n"
    if ($previousSummary) {
        $userBody += "<previous-summary>`n" + $previousSummary + "`n</previous-summary>`n`n"
    }
    $userBody += $prompt
    $summaryReq = @{
        model = $ModelId
        messages = @(
            @{ role = 'system'; content = 'You are a context compaction assistant. Produce a dense, structured summary in the language of the conversation. Do NOT continue the conversation or call tools.' },
            @{ role = 'user'; content = $userBody }
        )
        stream = $false
    } | ConvertTo-Json -Depth 20 -Compress
    $tempFile = New-TemporaryFile -ErrorAction Stop
    try {
        Invoke-AgentHttpRequest -Uri $Endpoint -ApiKey $ApiKey -Body $summaryReq -OutFile $tempFile.FullName -TimeoutSec 180 -StatusLabel "Compacting context ($ModelId)"
        $reply = Get-Content -LiteralPath $tempFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $tempFile.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($reply -and $reply.usage) {
        if ($reply.usage.prompt_tokens) { $State.usage_input_tokens = [int]$State.usage_input_tokens + [int]$reply.usage.prompt_tokens }
        if ($reply.usage.completion_tokens) { $State.usage_output_tokens = [int]$State.usage_output_tokens + [int]$reply.usage.completion_tokens }
    }
    $choice = $reply.choices[0]
    if (-not $choice -or -not $choice.message) { throw 'Compaction returned no assistant message.' }
    $finishReason = [string]$choice.finish_reason
    if ($finishReason -and ($finishReason -ne 'stop')) {
        throw "Compaction summary was incomplete (finish_reason=$finishReason)."
    }
    if ($choice.message.tool_calls) {
        throw 'Compaction summary attempted to call a tool.'
    }
    $summaryText = $choice.message.content
    if (-not $summaryText) { throw 'Compaction returned empty summary.' }
    $finalSummary = $summaryText.Trim() + $fileOps.xml
    $firstKeptId = if ($recent.Count -gt 0 -and $recent[0].id) { [string]$recent[0].id } else { '' }
    $existingById = @{}
    foreach ($te in @($State.tree_entries)) {
        if ($te -and $te.id) { $existingById[[string]$te.id] = $true }
    }
    $counter = $State.tree_entries.Count + 1
    $compId = ('e{0:D4}' -f $counter)
    while ($existingById.ContainsKey($compId)) {
        $counter++
        $compId = ('e{0:D4}' -f $counter)
    }
    $compEntry = @{
        id = $compId
        parent_id = $State.leaf_id
        entry_type = 'compaction'
        first_kept_entry_id = $firstKeptId
        role = 'user'
        content = ("[Compacted Conversation Summary]`n" + $finalSummary)
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    }
    $State.tree_entries += $compEntry
    $State.leaf_id = $compId
    $State.messages = @(Build-BranchContextMessages -State $State -LeafId $compId)
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
    Sync-AgentCapabilities -State $State | Out-Null
    return $true
}
