# Strict schema and type validation for all agent tool calls.
# Extra checks stay in named functions. Test-AgentToolArguments calls the spec extra name.

function Get-AgentToolCallIdSet {
    param([array]$Calls)
    $ids = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($call in $Calls) {
        if (-not (Test-IsJsonObject $call)) { return $null }
        $id = $call.id
        if ($id -isnot [string] -or -not $id.Trim() -or $ids.ContainsKey($id)) { return $null }
        $ids[$id] = $true
    }
    return $ids
}

function Assert-AgentToolArgumentSize {
    param([string]$RawArguments)
    $limit = $script:AgentMaxToolArgumentBytes
    if ($RawArguments.Length -gt $limit -or (Get-AgentUtf8ByteCount $RawArguments) -gt $limit) {
        throw "Tool arguments exceed the $limit-byte limit."
    }
}

function Assert-AgentToolCallBatch {
    param($Message, [string]$FinishReason, [switch]$Replay)
    if (-not (Test-IsJsonObject $Message) -or
        ($null -ne $Message.role -and ($Message.role -isnot [string] -or $Message.role -cne 'assistant')) -or
        ($null -ne $Message.content -and $Message.content -isnot [string]) -or
        ($null -ne $Message.reasoning_content -and $Message.reasoning_content -isnot [string]) -or
        $null -ne $Message.tool_call_id -or $null -ne $Message.function_call) {
        throw 'API returned an invalid assistant message.'
    }

    $calls = $Message.tool_calls
    if ($null -ne $calls -and $calls -isnot [array]) {
        throw 'Invalid tool_calls batch. Expected an array.'
    }
    if (($FinishReason -eq 'tool_calls' -and $calls.Count -eq 0) -or
        ($FinishReason -eq 'stop' -and $calls.Count -gt 0)) {
        throw 'Invalid tool_calls batch. The call list does not match finish_reason.'
    }
    $limit = 64
    if (-not $Replay -and $calls.Count -gt $limit) {
        throw "Invalid tool_calls batch. A response may contain at most $limit calls."
    }
    if ($calls.Count -eq 0) { return }
    if ($null -eq (Get-AgentToolCallIdSet -Calls $calls)) {
        throw 'Invalid tool_calls batch. Each call needs a unique nonempty string ID.'
    }
    for ($i = 0; $i -lt $calls.Count; $i++) {
        $call = $calls[$i]
        if ($call.type -isnot [string] -or $call.type -cne 'function') {
            throw "Invalid tool_calls batch. Call $($i + 1) must have type 'function'."
        }
        if (-not (Test-IsJsonObject $call.function) -or
            $call.function.name -isnot [string] -or -not $call.function.name.Trim() -or
            $call.function.arguments -isnot [string]) {
            throw "Invalid tool_calls batch. Call $($i + 1) needs a function object with a name and string arguments."
        }
        if (-not $Replay) { Assert-AgentToolArgumentSize -RawArguments $call.function.arguments }
    }
    # Argument JSON and tool schema errors are reported by the dispatcher for each call.
}

function Test-AgentEditFileArguments {
    param($Arguments, $PropNames)
    $propNames = @($PropNames)
    $hasEdits = ($propNames -contains 'edits' -and $null -ne $Arguments.edits)
    $hasSingle = ($propNames -contains 'old_text' -or $propNames -contains 'new_text')
    if ($hasEdits -and $hasSingle) {
        throw 'Provide either old_text/new_text or edits[], not both.'
    }
    if ($hasEdits) {
        if ($Arguments.edits.Count -gt $script:AgentMaxBatchEdits) {
            throw "edits[] may contain at most $($script:AgentMaxBatchEdits) operations."
        }
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

function Test-AgentRunAgentArguments {
    param($Arguments, $PropNames)
    $propNames = @($PropNames)
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

function Test-AgentTodoArguments {
    param($Arguments, $PropNames)
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

function Test-AgentAskUserArguments {
    param($Arguments, $PropNames)
    if (-not $Arguments.question -or -not $Arguments.question.Trim()) {
        throw 'question must be a nonempty string.'
    }
    if ($Arguments.intent -and $Arguments.intent.ToLower() -notin @('question', 'plan-review')) {
        throw "intent must be 'question' or 'plan-review'."
    }
}

function Test-AgentMemoryArguments {
    param($Arguments, $PropNames)
    $act = if ($Arguments.action) { ([string]$Arguments.action).Trim().ToLower() } else { 'append' }
    if ($act -notin @('append', 'view', 'set', 'clear')) {
        throw "action must be 'append', 'view', 'set', or 'clear'."
    }
    $scope = if ($Arguments.scope) { ([string]$Arguments.scope).Trim().ToLower() } else { 'workspace' }
    if ($scope -notin @('workspace', 'global')) {
        throw "scope must be 'workspace' or 'global'."
    }
    if (($act -eq 'append' -or $act -eq 'set') -and (-not $Arguments.content -or -not [string]$Arguments.content.Trim())) {
        throw "content must be a nonempty string for action '$act'."
    }
}

function Test-AgentToolArguments {
    param([string]$Name, $Arguments)
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        throw 'Tool arguments must be a JSON object.'
    }
    $schema = $null
    foreach ($spec in @(Get-AgentToolSpecifications)) {
        if ([string]$spec.name -eq $Name) {
            $schema = $spec
            break
        }
    }
    if (-not $schema) { throw 'Unknown tool.' }
    $propNames = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $knownNames = @($schema.properties.Keys)
    foreach ($p in $propNames) {
        if ($knownNames -notcontains $p) {
            throw "Unknown argument '$p' for tool '$Name'."
        }
    }
    foreach ($req in @($schema.required)) {
        if (-not $req) { continue }
        if ($propNames -notcontains $req -or $null -eq $Arguments.$req) {
            throw "Missing required argument '$req' for tool '$Name'."
        }
    }
    foreach ($p in $propNames) {
        $val = $Arguments.$p
        if ($null -eq $val) { continue }
        $expectedType = [string]$schema.properties[$p].type
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
    $extraName = [string]$schema['extra']
    if ($extraName) {
        & $extraName -Arguments $Arguments -PropNames $propNames
    }
}
