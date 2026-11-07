# Agent turn loop (HTTP retries, finish_reason check, overflow auto-compaction, repetition loop-guard, and tool dispatch).

function ConvertTo-CanonicalToolArgs {
    param([string]$RawArguments)
    if (-not $RawArguments -or -not $RawArguments.Trim()) { return '{}' }
    try {
        $parsed = $RawArguments | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed -or $parsed -is [string] -or $parsed -is [ValueType] -or $parsed -is [array]) {
            return $RawArguments.Trim()
        }
        $props = @(Get-ObjectPropertyNames -InputObject $parsed | Sort-Object)
        $parts = @()
        foreach ($p in $props) {
            $valJson = ($parsed.$p | ConvertTo-Json -Depth 10 -Compress)
            $parts += ($p + ':' + $valJson)
        }
        return '{' + ($parts -join ',') + '}'
    }
    catch {
        return $RawArguments.Trim()
    }
}

function Get-ToolCallSignature {
    param($Call, [int]$Epoch = 0)
    $fnName = if ($Call -and $Call.function -and $Call.function.name) { Resolve-ToolCanonicalName -Name ([string]$Call.function.name) } else { '' }
    $rawArgs = if ($Call -and $Call.function -and $Call.function.arguments) { [string]$Call.function.arguments } else { '{}' }
    $canonArgs = ConvertTo-CanonicalToolArgs -RawArguments $rawArgs
    return ("{0}|{1}|{2}" -f $Epoch, $fnName, $canonArgs)
}

function New-AgentTurnSnapshot {
    param($State)
    $leafId = if ($State.leaf_id) { [string]$State.leaf_id } else { '' }
    $messages = @(Copy-SessionHashtableArray -Items $State.messages)
    $treeEntries = @(Copy-SessionHashtableArray -Items $State.tree_entries)
    return @{
        messages = $messages
        leaf_id = $leafId
        tree_entries = $treeEntries
    }
}

function Restore-AgentTurnSnapshot {
    param($State, $Snapshot, [AllowEmptyCollection()][array]$Writes = @())
    Invoke-AgentUndo -State $State -UndoEntry @{
        messages = @($Snapshot.messages)
        leaf_id = [string]$Snapshot.leaf_id
        tree_entries = @($Snapshot.tree_entries)
        writes = @($Writes)
    }
}

function Invoke-AgentTurnRollback {
    param($State, $Snapshot, [AllowEmptyCollection()][array]$Writes = @(), [AllowEmptyCollection()][array]$UndoStack = @())
    try {
        Restore-AgentTurnSnapshot -State $State -Snapshot $Snapshot -Writes $Writes
        return @{
            succeeded = $true
            undo_stack = @($UndoStack)
            error = ''
        }
    }
    catch {
        foreach ($w in @($Writes)) {
            if ($w) { $w.preserve_backup = $true }
        }
        $kept = @{
            messages = $Snapshot.messages
            leaf_id = $Snapshot.leaf_id
            tree_entries = $Snapshot.tree_entries
            writes = @($Writes)
            preserve_backups = $true
        }
        $stack = @($UndoStack)
        $stack += $kept
        return @{
            succeeded = $false
            undo_stack = @($stack)
            error = (Format-AgentError -ErrorRecord $_)
        }
    }
}

function Invoke-ThresholdAutoCompact {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey)
    $stats = Get-ContextStats -State $State
    if ($stats.est_tokens -gt $stats.compact_threshold_tokens) {
        if ($script:OutputMode -ne 'json') {
            $limStr = Format-TokenCount -Tokens $stats.compact_threshold_tokens
            Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
        }
        try {
            if (Invoke-AgentCompact -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey) {
                return $true
            }
        }
        catch {}
    }
    return $false
}

function Invoke-AgentTurn {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [string]$Root, [int]$Steps = 50, [int]$MaxRepeatCalls = 0)
    $overflowRetried = $false
    $script:ActiveModelId = $ModelId
    $script:ActiveEndpoint = $Endpoint
    $script:ActiveApiKey = $ApiKey
    $script:ActiveState = $State
    if ($Root) { $script:ActiveWorkspace = $Root }
    $State.step_limit_reached = $false
    $State.loop_detected = $false
    $State.repeated_tool = $null
    $repeatLimit = if ($MaxRepeatCalls -gt 0) { $MaxRepeatCalls } elseif ($script:MaxRepeatToolCalls -gt 0) { [int]$script:MaxRepeatToolCalls } else { 3 }
    $mutationEpoch = 0
    $toolCallCounts = @{}
    if ($null -eq $State.scoped_instr_cache -or $State.scoped_instr_cache -isnot [hashtable]) {
        $State.scoped_instr_cache = @{}
    }
    $scopedInstrCache = $State.scoped_instr_cache
    for ($step = 0; $step -lt $Steps; $step++) {
        if ($step -gt 0) {
            if (Invoke-ThresholdAutoCompact -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey) {
                $mutationEpoch++
                $toolCallCounts = @{}
            }
        }
        $capSync = Sync-AgentCapabilities -State $State -Root $Root
        $activeTools = @(Get-AgentTools)
        $diagEntry = @{
            step = $step
            model = $ModelId
            permission = $capSync.permission
            tools = @($capSync.tools)
            capabilities_updated = [bool]$capSync.prompt_updated
            consistent = [bool]$capSync.consistent
        }
        $State.last_diagnostics = $diagEntry
        if ($null -eq $State.diagnostics_log) { $State.diagnostics_log = @() }
        $State.diagnostics_log += $diagEntry
        if ($script:Diagnostics) {
            if ($script:OutputMode -eq 'json') {
                Write-AgentJsonEvent -EventType 'diagnostics' -Payload $diagEntry
            }
            else {
                $toolsCsv = if ($capSync.tools.Count -gt 0) { $capSync.tools -join ',' } else { 'none' }
                Write-Host ($script:Gm.Grey1 + ("  [diag] mode={0} | tools={1} | capabilities_updated={2} | consistent={3}" -f $capSync.permission, $toolsCsv, $capSync.prompt_updated, $capSync.consistent) + $script:Gm.Reset)
            }
        }
        Write-AgentJsonEvent -EventType 'turn_start' -Payload @{ model = $ModelId; step = $step }
        $bodyObj = @{
            model = $ModelId
            messages = @($State.messages)
            tools = $activeTools
            stream = $false
        }
        if ($script:ReasoningEffort) { $bodyObj.reasoning_effort = $script:ReasoningEffort }
        $body = $bodyObj | ConvertTo-Json -Depth 40 -Compress
        $statusLabel = "[step {0}/{1}] Waiting for {2}" -f ($step + 1), $Steps, $ModelId
        $tempResponse = New-AgentTempFile
        $reply = $null
        try {
            $maxRetries = 2
            for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
                try {
                    Invoke-AgentHttpRequest -Uri $Endpoint -ApiKey $ApiKey -Body $body -OutFile $tempResponse.FullName -TimeoutSec 180 -StatusLabel $statusLabel
                    $reply = Get-Content -LiteralPath $tempResponse.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    break
                }
                catch {
                    $errFormatted = Format-AgentError -ErrorRecord $_
                    if (($attempt -lt $maxRetries) -and ($errFormatted -match '(?i)\b(408|429|500|502|503|504|timeout|timed out)\b')) {
                        $delay = ($attempt + 1) * 2
                        if ($script:OutputMode -ne 'json') {
                            Write-Host ($script:Gm.Yellow + ("  [retry {0}/{1}] Transient error ({2}); waiting {3}s..." -f ($attempt + 1), $maxRetries, $errFormatted, $delay) + $script:Gm.Reset)
                        }
                        Start-Sleep -Seconds $delay
                        continue
                    }
                    if ((-not $overflowRetried) -and ($errFormatted -match '(?i)(context_length|maximum context|too many tokens|token limit)')) {
                        $overflowRetried = $true
                        if ($errFormatted -match '(?i)maximum context length is (\d+)') {
                            $srvLim = [int]$Matches[1]
                            if ($srvLim -ge 4000 -and $srvLim -lt $script:ContextWindowTokens) {
                                $null = Set-AgentContextLimits -WindowSpec ([string]$srvLim) -CompactSpec '75%'
                            }
                        }
                        if ($script:OutputMode -ne 'json') {
                            Write-Host ($script:Gm.Yellow + '  [auto-recovery] Context overflow detected; compacting history and retrying...' + $script:Gm.Reset)
                        }
                        if (Invoke-AgentCompact -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey) {
                            $mutationEpoch++
                            $toolCallCounts = @{}
                            $step--
                            $reply = $null
                            break
                        }
                    }
                    throw
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $tempResponse.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $reply) { continue }
        if ($reply.usage) {
            if ($reply.usage.prompt_tokens) { $State.usage_input_tokens = [int]$State.usage_input_tokens + [int]$reply.usage.prompt_tokens }
            if ($reply.usage.completion_tokens) { $State.usage_output_tokens = [int]$State.usage_output_tokens + [int]$reply.usage.completion_tokens }
        }
        $choice = $reply.choices[0]
        if (-not $choice -or -not $choice.message) { throw 'API returned no assistant message.' }
        $finishReason = [string]$choice.finish_reason
        if ($finishReason -and ($finishReason -notin @('stop', 'tool_calls'))) {
            throw "Incomplete model response (finish_reason=$finishReason)."
        }
        $message = $choice.message
        $assistant = @{ role = 'assistant'; content = $message.content }
        if ($message.reasoning_content) {
            $assistant.reasoning_content = $message.reasoning_content
            if ($script:OutputMode -ne 'json') {
                Write-AgentReasoning -Text ([string]$message.reasoning_content)
            }
        }
        if ($message.tool_calls) { $assistant.tool_calls = @($message.tool_calls) }
        $State.messages += $assistant
        if ($reply.usage -and $reply.usage.prompt_tokens) {
            $compTok = if ($reply.usage.completion_tokens) { [int]$reply.usage.completion_tokens } else { 0 }
            $State.last_prompt_tokens = [int]$reply.usage.prompt_tokens + $compTok
            $curChars = 0
            foreach ($m in @($State.messages)) {
                if ($m.content) { $curChars += ([string]$m.content).Length }
                if ($m.reasoning_content) { $curChars += ([string]$m.reasoning_content).Length }
                if ($m.tool_calls) { $curChars += (($m.tool_calls | ConvertTo-Json -Depth 10 -Compress)).Length }
            }
            $State.last_prompt_chars = $curChars
        }
        Ensure-SessionTree -State $State
        Write-AgentJsonEvent -EventType 'message_end' -Payload @{
            role = 'assistant'
            content = $message.content
            tool_calls = @(if ($message.tool_calls) { @($message.tool_calls) })
        }
        if ($message.content -and $script:OutputMode -ne 'json') { Write-AgentReply -Content $message.content }
        if (-not $message.tool_calls) {
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{
                step = $step
                status = 'completed'
                usage_input_tokens = [int]$State.usage_input_tokens
                usage_output_tokens = [int]$State.usage_output_tokens
            }
            return
        }
        $loopAborted = $false
        # Only instructions visible before this model response count as received.
        $scopedMessages = @($State.messages)
        $scopedTreeToolContents = @()
        if ($State.tree_entries -and $State.leaf_id) {
            $byId = @{}
            foreach ($te in @($State.tree_entries)) {
                if ($te -and $te.id) { $byId[[string]$te.id] = $te }
            }
            $curr = if ($byId.ContainsKey([string]$State.leaf_id)) { $byId[[string]$State.leaf_id] } else { $null }
            $guard = 0
            while ($null -ne $curr -and $guard -lt 5000) {
                $guard++
                if ($curr.role -eq 'tool' -and $curr.content) {
                    $scopedTreeToolContents += [string]$curr.content
                }
                if ($curr.parent_id -and $byId.ContainsKey([string]$curr.parent_id)) {
                    $curr = $byId[[string]$curr.parent_id]
                }
                else {
                    $curr = $null
                }
            }
        }
        $priorFileOps = Get-CompactionFileOperations -Messages $scopedMessages
        $priorScopedPaths = @($priorFileOps.read_files) + @($priorFileOps.modified_files)
        foreach ($call in $message.tool_calls) {
            $canonToolName = Resolve-ToolCanonicalName -Name ([string]$call.function.name)
            $sig = Get-ToolCallSignature -Call $call -Epoch $mutationEpoch
            $prevCount = if ($toolCallCounts.ContainsKey($sig)) { [int]$toolCallCounts[$sig] } else { 0 }
            $newCount = $prevCount + 1
            $toolCallCounts[$sig] = $newCount
            Write-AgentJsonEvent -EventType 'tool_execution_start' -Payload @{ id = [string]$call.id; name = [string]$call.function.name }
            if ($loopAborted -or ($newCount -gt $repeatLimit)) {
                if (-not $loopAborted) {
                    $State.loop_detected = $true
                    $State.repeated_tool = $canonToolName
                    $loopAborted = $true
                }
                $stopObj = @{
                    status = 'loop_detected'
                    error = "Turn stopped: tool '$canonToolName' was called repeatedly with identical arguments ($newCount times) without state changes."
                }
                $output = ($stopObj | ConvertTo-Json -Compress)
                Write-AgentJsonEvent -EventType 'tool_execution_end' -Payload @{ id = [string]$call.id; name = [string]$call.function.name; result = $output }
                $State.messages += @{ role = 'tool'; tool_call_id = $call.id; content = $output }
                Ensure-SessionTree -State $State
                continue
            }
            if ($newCount -eq $repeatLimit) {
                $warnObj = @{
                    status = 'repeated_call_warning'
                    warning = "Repeated identical tool call '$canonToolName' with the same arguments without any intervening file or state changes. Do not repeat identical calls; use the result already in context, try different arguments, or explain why you cannot proceed."
                }
                $output = ($warnObj | ConvertTo-Json -Compress)
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Yellow + "  [loop-guard] Repeated identical call to $canonToolName; returning warning." + $script:Gm.Reset)
                }
                Write-AgentJsonEvent -EventType 'tool_execution_end' -Payload @{ id = [string]$call.id; name = [string]$call.function.name; result = $output }
                $State.messages += @{ role = 'tool'; tool_call_id = $call.id; content = $output }
                Ensure-SessionTree -State $State
                continue
            }
            $output = $null
            if ($canonToolName -in @('read_file', 'write_file', 'edit_file') -and ($canonToolName -eq 'read_file' -or $script:AgentPermission -ne 'ReadOnly') -and (Test-IsToolEnabled -Name $canonToolName) -and -not $script:NoContextFiles) {
                $scopeArgs = $null
                $scopeTargetValid = $false
                try {
                    $rawScopeArgs = $call.function.arguments | ConvertFrom-Json -ErrorAction Stop
                    $scopeArgs = Format-AgentToolArguments -Name $canonToolName -Arguments $rawScopeArgs
                    Test-AgentToolArguments -Name $canonToolName -Arguments $scopeArgs
                    if ($scopeArgs.path -is [string] -and $scopeArgs.path) {
                        $rootResolved = Resolve-AgentPath -Root $Root -RelativePath '.'
                        if ($canonToolName -eq 'read_file') {
                            $resolvedTarget = Resolve-AgentPath -Root $rootResolved -RelativePath $scopeArgs.path -AllowRegisteredSkill
                            if (Test-AgentPathWithinRoot -RootPath $rootResolved -TargetPath $resolvedTarget) {
                                $scopeTargetValid = $true
                            }
                        }
                        elseif ($canonToolName -eq 'edit_file') {
                            $null = Resolve-AgentPath -Root $rootResolved -RelativePath $scopeArgs.path
                            $scopeTargetValid = $true
                        }
                        else {
                            $null = Resolve-AgentWriteTarget -Root $rootResolved -RelativePath $scopeArgs.path
                            $scopeTargetValid = $true
                        }
                    }
                }
                catch {
                    $scopeTargetValid = $false
                }
                if ($scopeTargetValid) {
                    try {
                        $instructions = Get-ScopedAgentInstructions -Root $Root -TargetPath $scopeArgs.path -AllowRegisteredSkill:($canonToolName -eq 'read_file')
                        if ($instructions) {
                            $notice = (@{ status = 'instructions_required'; instructions = $instructions; message = 'Apply these scoped AGENTS.md instructions, then retry the file tool call.' } | ConvertTo-Json -Compress)
                            $seen = $false
                            foreach ($prior in $scopedMessages) {
                                if ($prior.role -eq 'tool' -and [string]$prior.content -ceq $notice) { $seen = $true; break }
                            }
                            if (-not $seen) {
                                foreach ($priorToolText in $scopedTreeToolContents) {
                                    if ([string]$priorToolText -ceq $notice) { $seen = $true; break }
                                }
                            }
                            if (-not $seen) {
                                foreach ($priorPath in $priorScopedPaths) {
                                    if (-not $priorPath) { continue }
                                    try {
                                        $priorKey = [string]$priorPath
                                        if (-not $scopedInstrCache.ContainsKey($priorKey)) {
                                            $scopedInstrCache[$priorKey] = Get-ScopedAgentInstructions -Root $Root -TargetPath $priorKey -AllowRegisteredSkill
                                        }
                                        $priorInstr = $scopedInstrCache[$priorKey]
                                        if ($priorInstr -and ($priorInstr -ceq $instructions -or $priorInstr.Contains($instructions))) {
                                            $seen = $true
                                            break
                                        }
                                    }
                                    catch {}
                                }
                            }
                            if (-not $seen) {
                                $output = $notice
                                $toolCallCounts[$sig] = $prevCount
                            }
                        }
                    }
                    catch {
                        $errMsg = 'Cannot verify scoped AGENTS.md instructions: ' + $_.Exception.Message
                        Write-ToolCallCard -Name $canonToolName -Target ([string]$scopeArgs.path) -Status 'error' -Summary $errMsg
                        $output = (@{ error = $errMsg } | ConvertTo-Json -Compress)
                    }
                }
            }
            if ($null -eq $output) { $output = Invoke-AgentTool -Root $Root -Call $call }
            Write-AgentJsonEvent -EventType 'tool_execution_end' -Payload @{ id = [string]$call.id; name = [string]$call.function.name; result = $output }
            $State.messages += @{ role = 'tool'; tool_call_id = $call.id; content = $output }
            Ensure-SessionTree -State $State
            if ($canonToolName -in @('write_file', 'edit_file', 'run_command')) {
                try {
                    $parsedOut = $output | ConvertFrom-Json -ErrorAction Stop
                    if ($parsedOut.status -in @('written', 'executed', 'timed_out')) {
                        $mutationEpoch++
                        $scopedInstrCache.Clear()
                    }
                }
                catch {}
            }
            elseif ($canonToolName -eq 'run_agent') {
                try {
                    $parsedOut = $output | ConvertFrom-Json -ErrorAction Stop
                    if ($parsedOut.modified_files -and @($parsedOut.modified_files).Count -gt 0) {
                        $mutationEpoch++
                        $scopedInstrCache.Clear()
                    }
                }
                catch {}
            }
            elseif ($canonToolName -eq 'memory') {
                try {
                    $parsedOut = $output | ConvertFrom-Json -ErrorAction Stop
                    if ($parsedOut.success -and $parsedOut.action -in @('append', 'set', 'clear')) {
                        $mutationEpoch++
                        Sync-AgentMemoryContext -State $State -Root $Root | Out-Null
                    }
                }
                catch {}
            }
        }
        if ($loopAborted) {
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Yellow + "Loop detected: repeated identical calls to '$($State.repeated_tool)'. Turn stopped (completed edits are preserved; use /undo to revert)." + $script:Gm.Reset)
            }
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{
                step = $step
                status = 'loop_detected'
                tool = $State.repeated_tool
                usage_input_tokens = [int]$State.usage_input_tokens
                usage_output_tokens = [int]$State.usage_output_tokens
            }
            return
        }
    }
    $State.step_limit_reached = $true
    if ($script:OutputMode -ne 'json') {
        Write-Host ($script:Gm.Yellow + 'Step limit reached. Use /continue to keep going, or /clear to start over.' + $script:Gm.Reset)
    }
    Write-AgentJsonEvent -EventType 'turn_end' -Payload @{
        step = $Steps
        status = 'step_limit_reached'
        usage_input_tokens = [int]$State.usage_input_tokens
        usage_output_tokens = [int]$State.usage_output_tokens
    }
}

function Invoke-AgentContinue {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [string]$Root, [int]$Steps = 50)
    if (-not $State -or -not $State.messages -or $State.messages.Count -eq 0) { return $false }
    $nonSystem = @($State.messages | Where-Object { $_.role -ne 'system' })
    if ($nonSystem.Count -eq 0) { return $false }
    $lastMsg = $State.messages[$State.messages.Count - 1]
    if ($lastMsg.role -eq 'assistant' -and (-not $lastMsg.tool_calls -or @($lastMsg.tool_calls).Count -eq 0)) {
        $State.messages += @{ role = 'user'; content = 'Continue.' }
        Ensure-SessionTree -State $State
    }
    Invoke-AgentTurn -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey -Root $Root -Steps $Steps
    return $true
}
