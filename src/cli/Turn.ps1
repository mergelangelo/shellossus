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
    $execCtx = Get-AgentExecutionContext
    $leafId = if ($State.leaf_id) { [string]$State.leaf_id } else { '' }
    $messages = @(Copy-SessionHashtableArray -Items $State.messages)
    $treeEntries = @(Copy-SessionHashtableArray -Items $State.tree_entries)
    return @{
        messages = $messages
        leaf_id = $leafId
        tree_entries = $treeEntries
        todos = @(Copy-SessionHashtableArray -Items $State.todos)
        active_session_todos = @($execCtx.active_session_todos)
        agent_permission = $execCtx.agent_permission
        permission_revision = $execCtx.permission_revision
        auto_approve_commands = $execCtx.auto_approve_commands
        auto_approve_web = $execCtx.auto_approve_web
    }
}

function Test-AgentTurnFrameHasPermission {
    param($Frame)
    if ($null -eq $Frame) { return $false }
    foreach ($name in @(Get-ObjectPropertyNames -InputObject $Frame)) {
        if ($name -eq 'agent_permission') { return $true }
    }
    return $false
}

function Restore-AgentTurnPermission {
    param($Frame, $State)
    if (-not (Test-AgentTurnFrameHasPermission -Frame $Frame)) { return }
    if ([long]$Frame.permission_revision -eq $script:PermissionRevision) {
        $script:AgentPermission = [string]$Frame.agent_permission
        $script:AutoApproveCommands = [bool]$Frame.auto_approve_commands
        $script:AutoApproveWeb = [bool]$Frame.auto_approve_web
    }
    if ($State) {
        Sync-AgentCapabilities -State $State | Out-Null
    }
}

function New-AgentUndoFrame {
    param($Snapshot, [AllowEmptyCollection()][array]$Writes = @())
    $frame = @{
        messages = @($Snapshot.messages)
        leaf_id = [string]$Snapshot.leaf_id
        tree_entries = @($Snapshot.tree_entries)
        writes = @($Writes)
    }
    if ($null -ne $Snapshot.todos) { $frame.todos = @($Snapshot.todos) }
    if ($null -ne $Snapshot.active_session_todos) { $frame.active_session_todos = @($Snapshot.active_session_todos) }
    if (Test-AgentTurnFrameHasPermission -Frame $Snapshot) {
        $frame.agent_permission = [string]$Snapshot.agent_permission
        $frame.permission_revision = [long]$Snapshot.permission_revision
        $frame.auto_approve_commands = [bool]$Snapshot.auto_approve_commands
        $frame.auto_approve_web = [bool]$Snapshot.auto_approve_web
    }
    return $frame
}

function Add-AgentUndoFrame {
    param([array]$UndoStack, $Frame)
    $stack = @($UndoStack) + @($Frame)
    $excess = $stack.Count - $script:AgentMaxUndoFrames
    if ($excess -gt 0) {
        Clear-AgentUndoBackups -UndoEntries @($stack | Select-Object -First $excess)
        $stack | Select-Object -Skip $excess
    }
    else {
        $stack
    }
}

function Restore-AgentTurnSnapshot {
    param($State, $Snapshot, [AllowEmptyCollection()][array]$Writes = @())
    Invoke-AgentUndo -State $State -UndoEntry (New-AgentUndoFrame -Snapshot $Snapshot -Writes @($Writes))
    Restore-AgentTurnPermission -Frame $Snapshot -State $State
}

function Invoke-AgentTurnRollback {
    param($State, $Snapshot, [AllowEmptyCollection()][array]$Writes = @(), [AllowEmptyCollection()][array]$UndoStack = @(), [string]$Reason = 'turn_failed')
    Protect-AgentTurnBackups -Writes $Writes
    try {
        Restore-AgentTurnSnapshot -State $State -Snapshot $Snapshot -Writes $Writes
        return @{
            succeeded = $true
            undo_stack = @($UndoStack)
            error = ''
            recovery_manifest = ''
        }
    }
    catch {
        Protect-AgentTurnBackups -Writes $Writes
        $kept = New-AgentUndoFrame -Snapshot $Snapshot -Writes @($Writes)
        $kept.preserve_backups = $true
        $stack = @(Add-AgentUndoFrame -UndoStack $UndoStack -Frame $kept)
        $rbErr = Format-AgentError -ErrorRecord $_
        $ws = if ($State -and $State.workspace) { [string]$State.workspace } elseif ($script:ActiveWorkspace) { [string]$script:ActiveWorkspace } else { '' }
        $sid = if ($State -and $State.session_id) { [string]$State.session_id } elseif ($script:ActiveSessionId) { [string]$script:ActiveSessionId } else { '' }
        $manifestPath = Write-AgentRecoveryManifest -Workspace $ws -SessionId $sid -Reason $Reason -RollbackError $rbErr -Writes $Writes
        return @{
            succeeded = $false
            undo_stack = @($stack)
            error = $rbErr
            recovery_manifest = [string]$manifestPath
        }
    }
}

function Start-AgentTurnTransaction {
    param($State, $UndoBox = $null, [AllowEmptyCollection()][array]$UndoStack = @())
    Clear-WorkspaceWalkCache
    Ensure-SessionTree -State $State
    $snapshot = New-AgentTurnSnapshot -State $State
    $script:CurrentTurnWrites = @()
    if ($null -eq $UndoBox -or $UndoBox -isnot [hashtable]) {
        $UndoBox = @{ undo_stack = @($UndoStack) }
    }
    else {
        $UndoBox.undo_stack = @($UndoStack)
    }
    return @{
        state = 'active'
        snapshot = $snapshot
        undo_box = $UndoBox
        rollback = $null
    }
}

function Complete-AgentTurnTransaction {
    param($Transaction, [switch]$DiscardUndoFrame)
    if ($null -eq $Transaction -or $Transaction.state -ne 'active') { return }
    if ($DiscardUndoFrame) {
        Clear-AgentUndoBackups -Writes @($script:CurrentTurnWrites)
    }
    else {
        $frame = New-AgentUndoFrame -Snapshot $Transaction.snapshot -Writes @($script:CurrentTurnWrites)
        $Transaction.undo_box.undo_stack = @(Add-AgentUndoFrame -UndoStack $Transaction.undo_box.undo_stack -Frame $frame)
    }
    $script:CurrentTurnWrites = @()
    $Transaction.state = 'committed'
    Clear-WorkspaceWalkCache
}

function Undo-AgentTurnTransaction {
    param($Transaction, $State, [string]$Reason = 'turn_failed')
    Clear-WorkspaceWalkCache
    if ($null -eq $Transaction) { return $null }
    if ($Transaction.state -ne 'active') { return $Transaction.rollback }
    Protect-AgentTurnBackups -Writes @($script:CurrentTurnWrites)
    $rollback = Invoke-AgentTurnRollback -State $State -Snapshot $Transaction.snapshot -Writes @($script:CurrentTurnWrites) -UndoStack $Transaction.undo_box.undo_stack -Reason $Reason
    $Transaction.undo_box.undo_stack = @($rollback.undo_stack)
    $Transaction.rollback = $rollback
    if ($rollback.succeeded) {
        $Transaction.state = 'rolled_back'
        $script:CurrentTurnWrites = @()
    }
    else {
        $Transaction.state = 'recovery_required'
    }
    Clear-WorkspaceWalkCache
    return $rollback
}

function Get-AgentRequestEstimatedTokens {
    param([string]$Body, [int]$MessageCount)
    # Gateways use different tokenizers. Estimate from the serialized request
    # before transport escaping and leave room for the chat template.
    return [int](((Get-AgentUtf8TextSize $Body) + 3) / 4) + (4 * $MessageCount) + 16
}

function New-AgentTurnRequest {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [array]$Tools, [switch]$RecoverOverflow)
    $request = @{
        model = $ModelId
        messages = @(ConvertTo-AgentApiMessages -Messages $State.messages)
        tools = $Tools
        stream = [bool]$script:StreamRequests
    }
    if ($script:ReasoningEffort) { $request.reasoning_effort = $script:ReasoningEffort }
    $body = $request | ConvertTo-Json -Depth 40 -Compress
    $estimated = Get-AgentRequestEstimatedTokens -Body $body -MessageCount $request.messages.Count
    if ($State.last_prompt_tokens -gt 0) {
        $measuredEstimate = (Get-ContextStats -State $State).est_tokens
        if ($measuredEstimate -gt $estimated) { $estimated = $measuredEstimate }
    }
    $window = $script:ContextWindowTokens
    $reserve = [int]($window / 8)
    if ($reserve -gt 4096) { $reserve = 4096 }
    $inputLimit = $window - $reserve
    $overBudget = $estimated -gt $inputLimit
    $advice = 'Shorten the prompt, attachments or tool output, reduce enabled tools, or use a larger context window if the model supports it.'
    $needCompaction = $overBudget -or $RecoverOverflow
    if ($needCompaction -or $estimated -gt $script:CompactThresholdTokens) {
        $keepRecent = if ($needCompaction) { 1 } else { 4 }
        $cut = (Find-CompactionCutPoint -Messages $State.messages -KeepRecent $keepRecent).cut_index
        if ($cut -gt 1 -and $request.messages[0].role -eq 'system') {
            if ($needCompaction) {
                # Keep the newest prompt verbatim, or the newest assistant message
                # together with its tool results. Older history is compressible.
                $request.messages = @($request.messages[0]) + @($request.messages[$cut..($request.messages.Count - 1)])
                $requiredBody = $request | ConvertTo-Json -Depth 40 -Compress
                $required = Get-AgentRequestEstimatedTokens -Body $requiredBody -MessageCount $request.messages.Count
                if ($required -gt $inputLimit) {
                    throw "Required context exceeds the $window-token window ($required estimated input tokens plus $reserve reserved for the reply). $advice"
                }
            }
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Yellow + '  [auto-compact] Compacting older history before sending the request...' + $script:Gm.Reset)
            }
            # Stage the candidate. Compaction may assign message IDs and grow a short history.
            $candidate = @{} + $State
            $candidate.messages = @(Copy-SessionHashtableArray -Items $State.messages)
            $compacted = $false
            try {
                $compacted = Invoke-AgentCompact -State $candidate -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey -KeepRecent $keepRecent
            }
            catch {
                if ($needCompaction) {
                    $detail = Format-AgentError -ErrorRecord $_
                    throw "The request needs context compaction before it can fit the model window. Compaction failed. $detail"
                }
            }
            finally {
                foreach ($key in @('usage_input_tokens', 'usage_output_tokens')) {
                    if ($candidate[$key] -ne $State[$key]) { $State[$key] = $candidate[$key] }
                }
            }
            if ($compacted) {
                $request.messages = @(ConvertTo-AgentApiMessages -Messages $candidate.messages)
                $compactedBody = $request | ConvertTo-Json -Depth 40 -Compress
                $compactedEstimate = Get-AgentRequestEstimatedTokens -Body $compactedBody -MessageCount $request.messages.Count
                if ($compactedEstimate -le $inputLimit) {
                    foreach ($key in $candidate.Keys) { $State[$key] = $candidate[$key] }
                    return @{ body = $compactedBody; compacted = $true }
                }
                if ($needCompaction) {
                    throw "Context after compaction exceeds the $window-token window ($compactedEstimate estimated input tokens plus $reserve reserved for the reply). $advice"
                }
            }
        }
    }
    if ($overBudget) {
        throw "Required context exceeds the $window-token window ($estimated estimated input tokens plus $reserve reserved for the reply). $advice"
    }
    if ($RecoverOverflow) {
        throw "The model rejected the request for context length and no older history could be compacted. $advice"
    }
    return @{ body = $body; compacted = $false }
}

function Invoke-AgentTurn {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [string]$Root, [int]$Steps = 50, [int]$MaxRepeatCalls = 0)
    if (-not (Test-ValidConversationBoundary -Messages $State.messages)) {
        Clear-WorkspaceWalkCache
        throw 'Cannot send conversation with inconsistent tool calls or results.'
    }
    Clear-WorkspaceWalkCache
    $overflowRetried = $false
    $recoverOverflow = $false
    $script:ActiveModelId = $ModelId
    $script:ActiveEndpoint = $Endpoint
    $script:ActiveState = $State
    if ($Root) { $script:ActiveWorkspace = $Root }
    $State.step_limit_reached = $false
    $State.loop_detected = $false
    $State.repeated_tool = $null
    $repeatLimit = if ($MaxRepeatCalls -gt 0) { $MaxRepeatCalls } elseif ($script:MaxRepeatToolCalls -gt 0) { [int]$script:MaxRepeatToolCalls } else { 3 }
    # Count attempts, with a warning on a repeat and a stop on the next attempt.
    $repeatWarningAt = if ($repeatLimit -eq 1) { 2 } else { $repeatLimit }
    $mutationEpoch = 0
    $turnToolCalls = 0
    $turnPayloadBytes = 0
    $toolCallCounts = @{}
    if ($null -eq $State.scoped_instr_cache -or $State.scoped_instr_cache -isnot [hashtable]) {
        $State.scoped_instr_cache = @{}
    }
    $scopedInstrCache = $State.scoped_instr_cache
    try {
    for ($step = 0; $step -lt $Steps; $step++) {
        $capSync = Sync-AgentCapabilities -State $State -Root $Root
        $activeTools = @(Get-AgentTools)
        $request = New-AgentTurnRequest -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey -Tools $activeTools -RecoverOverflow:$recoverOverflow
        $recoverOverflow = $false
        if ($request.compacted) {
            $mutationEpoch++
            $toolCallCounts = @{}
        }
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
        if ($State.diagnostics_log.Count -gt $script:AgentMaxDiagnosticsEntries) {
            $State.diagnostics_log = @($State.diagnostics_log | Select-Object -Last $script:AgentMaxDiagnosticsEntries)
        }
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
        $statusLabel = "[step {0}/{1}] Waiting for {2}" -f ($step + 1), $Steps, $ModelId
        $tempResponse = New-AgentTempFile
        $reply = $null
        try {
            $maxRetries = 2
            $stepStart = Get-Date
            $attemptTimeoutSec = [int]$script:RequestTimeoutSec
            for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
                try {
                    # Transient retries reuse the checked body. Context recovery rebuilds it.
                    Invoke-AgentHttpRequest -Uri $Endpoint -ApiKey $ApiKey -Body $request.body -OutFile $tempResponse.FullName -TimeoutSec $attemptTimeoutSec -StatusLabel $statusLabel
                    $responseBytes = (Get-Item -LiteralPath $tempResponse.FullName -ErrorAction Stop).Length
                    if ($turnPayloadBytes + $responseBytes -gt $script:AgentMaxTurnPayloadBytes) {
                        throw "Turn exceeds the $($script:AgentMaxTurnPayloadBytes)-byte payload limit."
                    }
                    $reply = Read-AgentApiResponse -Path $tempResponse.FullName
                    $turnPayloadBytes += $responseBytes
                    break
                }
                catch {
                    $errFormatted = Format-AgentError -ErrorRecord $_
                    $contextError = $errFormatted -match '(?i)(context_length|maximum context|context window)'
                    if (-not $contextError -and ($attempt -lt $maxRetries) -and ($errFormatted -match '(?i)\b(408|429|500|502|503|504|timeout|timed out)\b')) {
                        $delay = ($attempt + 1) * 2
                        $remainingStepBudget = $script:MaxStepRetryBudgetSec - [int](((Get-Date) - $stepStart).TotalSeconds)
                        if ($remainingStepBudget -gt ($delay + $script:MinRequestTimeoutSec)) {
                            $maxRetryTimeout = $remainingStepBudget - $delay
                            $attemptTimeoutSec = if ($script:RequestTimeoutSec -lt $maxRetryTimeout) { [int]$script:RequestTimeoutSec } else { [int]$maxRetryTimeout }
                            if ($script:OutputMode -ne 'json') {
                                Write-Host ($script:Gm.Yellow + ("  [retry {0}/{1}] Transient error ({2}); waiting {3}s..." -f ($attempt + 1), $maxRetries, (Format-TuiText $errFormatted), $delay) + $script:Gm.Reset)
                            }
                            Start-Sleep -Seconds $delay
                            continue
                        }
                    }
                    if (-not $overflowRetried -and ($contextError -or $errFormatted -match '(?i)(too many tokens|token limit)')) {
                        $overflowRetried = $true
                        if ($errFormatted -match '(?i)maximum context length is (\d{1,9})\b') {
                            $srvLim = [int]$Matches[1]
                            if ($srvLim -gt 0 -and $srvLim -lt 4000) {
                                throw "The model reported a $srvLim-token context window. The minimum supported window is 4000 tokens."
                            }
                            if ($srvLim -ge 4000 -and $srvLim -lt $script:ContextWindowTokens) {
                                $null = Set-AgentContextLimits -WindowSpec ([string]$srvLim) -CompactSpec '75%'
                            }
                        }
                        if ($script:OutputMode -ne 'json') {
                            Write-Host ($script:Gm.Yellow + '  [auto-recovery] Model reported a context overflow. Checking the request again...' + $script:Gm.Reset)
                        }
                        $recoverOverflow = $true
                        $step--
                        break
                    }
                    throw
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $tempResponse.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $reply) { continue }
        if ($reply.choices -isnot [array] -or $reply.choices.Count -eq 0) {
            throw 'API returned no assistant choice array.'
        }
        $choice = $reply.choices[0]
        if (-not (Test-IsJsonObject $choice) -or -not $choice.message) { throw 'API returned no assistant message.' }
        if ($null -ne $choice.finish_reason -and $choice.finish_reason -isnot [string]) {
            throw 'API returned an invalid finish_reason.'
        }
        $finishReason = [string]$choice.finish_reason
        if ($finishReason -and ($finishReason -notin @('stop', 'tool_calls'))) {
            throw "Incomplete model response (finish_reason=$finishReason)."
        }
        $message = $choice.message
        Assert-AgentToolCallBatch -Message $message -FinishReason $finishReason
        if ($message.tool_calls) {
            $turnToolCalls += $message.tool_calls.Count
            if ($turnToolCalls -gt $script:AgentMaxTurnToolCalls) {
                throw "Turn exceeds the $($script:AgentMaxTurnToolCalls)-tool-call limit."
            }
        }
        if ($reply.usage) {
            if ($reply.usage.prompt_tokens) { $State.usage_input_tokens = [int]$State.usage_input_tokens + [int]$reply.usage.prompt_tokens }
            if ($reply.usage.completion_tokens) { $State.usage_output_tokens = [int]$State.usage_output_tokens + [int]$reply.usage.completion_tokens }
        }
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
        $ranSubagent = $false
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
            if ($loopAborted -or ($newCount -gt $repeatWarningAt)) {
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
            if ($newCount -eq $repeatWarningAt) {
                $warnObj = @{
                    status = 'repeated_call_warning'
                    warning = "Repeated identical tool call '$canonToolName' with the same arguments without any intervening file or state changes. Do not repeat identical calls; use the result already in context, try different arguments, or explain why you cannot proceed."
                }
                $output = ($warnObj | ConvertTo-Json -Compress)
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Yellow + "  [loop-guard] Repeated identical call to $(Format-TuiText $canonToolName); returning warning." + $script:Gm.Reset)
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
            if ($null -eq $output) { $output = Invoke-AgentTool -Root $Root -Call $call -ApiKey $ApiKey }
            $turnPayloadBytes += Get-AgentUtf8ByteCount $output
            if ($turnPayloadBytes -gt $script:AgentMaxTurnPayloadBytes) {
                throw "Turn exceeds the $($script:AgentMaxTurnPayloadBytes)-byte payload limit."
            }
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
                $ranSubagent = $true
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
        if ($ranSubagent -and (Test-ValidConversationBoundary -Messages @($State.messages))) {
            Sync-AgentCapabilities -State $State -Root $Root | Out-Null
        }
        if ($loopAborted) {
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Yellow + "Loop detected: repeated identical calls to '$(Format-TuiText $State.repeated_tool)'. Turn stopped (completed edits are preserved; use /undo to revert)." + $script:Gm.Reset)
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
    finally {
        Clear-WorkspaceWalkCache
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
