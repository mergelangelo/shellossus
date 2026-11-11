# Subagent delegation, parallel execution, and role profiles (run_agent).

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
        Copy-MessageOptionalFields -Source $m -Target $copyMsg
        $forked += $copyMsg
    }
    if (-not (Test-ValidConversationBoundary -Messages $forked)) {
        return @(@{ role = 'system'; content = $SystemPrompt })
    }
    return $forked
}

function Get-SubagentToolNames {
    param($Role, [switch]$ForceReadOnly, [switch]$NonInteractive)
    $isReadOnly = ($ForceReadOnly -or $script:AgentPermission -eq 'ReadOnly' -or ($Role -and $Role.permission -eq 'ReadOnly'))
    $isNonInteractive = ($NonInteractive -or $script:OutputMode -eq 'json')
    # Resolve patterns against the parent's effective capabilities, including
    # exclusions and NoTools. Never interpret an empty intersection as allow-all.
    foreach ($tool in @(Get-AgentTools)) {
        $name = [string]$tool.function.name
        if ($name -eq 'run_agent') { continue }
        if ($isReadOnly) {
            if ($name -in @('write_file', 'edit_file', 'run_command', 'memory', 'todo', 'ask_user')) { continue }
            if ($isNonInteractive -and (-not $script:AutoApproveWeb) -and $name -in @('fetch_url', 'web_search')) { continue }
        }
        if ($Role -and $Role.tools -and $Role.tools.Count -gt 0) {
            $matched = $false
            foreach ($pattern in $Role.tools) {
                if ($name -like (Resolve-ToolCanonicalName -Name $pattern)) { $matched = $true; break }
            }
            if (-not $matched) { continue }
        }
        $name
    }
}

function Enter-SubagentExecutionScope {
    param(
        [hashtable]$ParentContext = $null,
        $Role,
        [switch]$ForceReadOnly
    )
    if ($null -eq $ParentContext) {
        $ParentContext = Get-AgentExecutionContext
    }
    $effPerm = if ($ForceReadOnly -or $ParentContext.agent_permission -eq 'ReadOnly' -or ($Role -and $Role.permission -eq 'ReadOnly')) {
        'ReadOnly'
    }
    else {
        [string]$ParentContext.agent_permission
    }
    $allowPermUpgrade = (-not $ForceReadOnly -and $ParentContext.agent_permission -ne 'ReadOnly' -and (-not $Role -or $Role.permission -ne 'ReadOnly'))
    $childTools = @(Get-SubagentToolNames -Role $Role -ForceReadOnly:$ForceReadOnly)
    $script:SubagentDepth = [int]$ParentContext.subagent_depth + 1
    $script:AgentPermission = $effPerm
    $script:EnabledTools = $childTools
    $script:NoTools = ([bool]$ParentContext.no_tools -or $childTools.Count -eq 0)
    $script:ActiveSessionTodos = @()
    return @{
        parent_context = $ParentContext
        effective_permission = $effPerm
        allow_permission_upgrade = [bool]$allowPermUpgrade
        child_tools = $childTools
    }
}

function Exit-SubagentExecutionScope {
    param(
        [hashtable]$ParentContext = $null,
        [hashtable]$Scope = $null,
        [bool]$AllowPermissionUpgrade = $false,
        [string]$Root = '',
        [string]$ConfigDir = ''
    )
    if ($null -eq $ParentContext -and $null -ne $Scope) {
        $ParentContext = $Scope.parent_context
        if (-not ($PSBoundParameters.Keys -contains 'AllowPermissionUpgrade')) {
            $AllowPermissionUpgrade = [bool]$Scope.allow_permission_upgrade
        }
    }
    Clear-WorkspaceWalkCache
    if ($null -eq $ParentContext) { return }
    Restore-AgentExecutionContext -Context $ParentContext -PreserveSessionPermissionUpgrade -AllowPermissionUpgrade $AllowPermissionUpgrade
    $parentState = $ParentContext.active_state
    if ($null -ne $parentState -and $parentState.messages -and $parentState.messages.Count -gt 0) {
        Sync-AgentMemoryContext -State $parentState -Root $Root -ConfigDir $ConfigDir | Out-Null
    }
}

function Invoke-SubagentInProcess {
    param(
        [string]$Root,
        [string]$RoleName = 'craft',
        [string]$TaskPrompt,
        [string]$ContextMode = 'clean',
        [int]$MaxSteps = 15,
        [switch]$ForceReadOnly,
        [string]$ApiKey
    )
    $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
    $roleObj = Resolve-AgentRole -Name $RoleName -Root $Root -ConfigDir $configDir
    $parentCtx = Get-AgentExecutionContext
    $effEndpoint = if ($parentCtx.active_endpoint) { $parentCtx.active_endpoint } else { 'https://example.invalid/v1/chat/completions' }
    $effModel = if ($roleObj.model) { [string]$roleObj.model } elseif ($parentCtx.active_model_id) { $parentCtx.active_model_id } else { 'test-model' }
    $effKey = if ($ApiKey) { $ApiKey } else { 'subagent-key' }
    $allowPermUpgrade = (-not $ForceReadOnly -and $parentCtx.agent_permission -ne 'ReadOnly' -and $roleObj.permission -ne 'ReadOnly')
    $savedState = $parentCtx.active_state
    try {
        $scope = Enter-SubagentExecutionScope -ParentContext $parentCtx -Role $roleObj -ForceReadOnly:$ForceReadOnly
        $effPerm = $scope.effective_permission
        $baseSys = Build-SystemPrompt -Root $Root -ConfigDir $configDir
        $subSys = $baseSys + "`n`n[Subagent Role: $($roleObj.name)]`n" + $roleObj.system_prompt
        $initMsgs = @(if ($ContextMode -eq 'fork') {
            Get-ForkedSubagentMessages -ParentState $savedState -SystemPrompt $subSys
        }
        else {
            @{ role = 'system'; content = $subSys }
        })
        # Tool arguments and prior step output are task text, never attachment requests.
        $initMsgs += @{ role = 'user'; content = $TaskPrompt }
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
            Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.Aqua + $script:Box.Arrow + (" run_agent:{0} " -f (Format-TuiText $roleObj.name)) + $script:Gm.Yellow + ("[{0}; context={1}] " -f $effPerm, $ContextMode) + $script:Gm.Grey1 + (Invoke-TruncateLine -Line (Format-TuiText $TaskPrompt) -MaxChars 80).text + $script:Gm.Reset)
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
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Green + $script:Box.Check + ' ' + $script:Gm.Grey2 + ("run_agent:{0} {1} ({2} steps, read:{3}, modified:{4})" -f (Format-TuiText $roleObj.name), (Format-TuiText $subStatus), $assistantSteps, @($fileOps.read_files).Count, @($fileOps.modified_files).Count) + $script:Gm.Reset)
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
        Exit-SubagentExecutionScope -ParentContext $parentCtx -AllowPermissionUpgrade $allowPermUpgrade -Root $Root -ConfigDir $configDir
    }
}

function Invoke-AgentSubagent {
    param([string]$Root, $Arguments, [string]$ApiKey)
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
        $modSet = @{}
        if ($useWorkerProcs) {
            $results = @(Invoke-ParallelSubagentProcesses -Root $Root -Tasks @($Arguments.parallel) -MaxSteps $maxSteps -ScriptPath $standaloneScript -ApiKey $ApiKey)
            foreach ($subRes in $results) {
                foreach ($rf in @($subRes.read_files)) {
                    if ($rf) { $readSet[[string]$rf] = $true }
                }
                foreach ($mf in @($subRes.modified_files)) {
                    if ($mf) { $modSet[[string]$mf] = $true }
                }
            }
        }
        else {
            foreach ($pt in $Arguments.parallel) {
                $rName = if ($pt.role) { [string]$pt.role } else { 'recon' }
                $writeStart = (Get-AgentExecutionContext).writes_count
                try {
                    $subRes = Invoke-SubagentInProcess -Root $Root -RoleName $rName -TaskPrompt ([string]$pt.prompt) -ContextMode 'clean' -MaxSteps $maxSteps -ForceReadOnly -ApiKey $ApiKey
                }
                catch {
                    $written = Get-CurrentTurnWritePathsSince -StartCount $writeStart
                    $subRes = New-SubagentErrorResult -Role $rName -Context 'clean' -Message $_.Exception.Message -ModifiedFiles $written
                }
                $results += $subRes
                foreach ($rf in @($subRes.read_files)) {
                    if ($rf) { $readSet[[string]$rf] = $true }
                }
                foreach ($mf in @($subRes.modified_files)) {
                    if ($mf) { $modSet[[string]$mf] = $true }
                }
            }
        }
        $summaryParts = @()
        $totalUsageIn = 0
        $totalUsageOut = 0
        for ($i = 0; $i -lt $results.Count; $i++) {
            $rItem = $results[$i]
            $summaryParts += ("### Task {0} ({1})`n{2}" -f ($i + 1), $rItem.role, $rItem.output)
            if ($rItem.usage_input_tokens) { $totalUsageIn += [int]$rItem.usage_input_tokens }
            if ($rItem.usage_output_tokens) { $totalUsageOut += [int]$rItem.usage_output_tokens }
        }
        $aggStatus = Resolve-SubagentAggregateStatus -Results $results
        Clear-WorkspaceWalkCache
        return (@{
            status = $aggStatus
            mode = 'parallel'
            tasks_count = $results.Count
            output = ($summaryParts -join "`n`n")
            results = $results
            read_files = @($readSet.Keys | Sort-Object)
            modified_files = @($modSet.Keys | Sort-Object)
            usage_input_tokens = $totalUsageIn
            usage_output_tokens = $totalUsageOut
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
        $totalUsageIn = 0
        $totalUsageOut = 0
        for ($i = 0; $i -lt $Arguments.pipeline.Count; $i++) {
            $ps = $Arguments.pipeline[$i]
            $rName = if ($ps.role) { [string]$ps.role } else { 'craft' }
            $stepCtx = if ($ps.context) { [string]$ps.context } else { $ctxMode }
            $rawPrompt = [string]$ps.prompt
            $resolvedPrompt = $rawPrompt.Replace('{previous}', $prevOutput).Replace('$PREVIOUS', $prevOutput)
            $writeStart = (Get-AgentExecutionContext).writes_count
            try {
                $stepRes = Invoke-SubagentInProcess -Root $Root -RoleName $rName -TaskPrompt $resolvedPrompt -ContextMode $stepCtx -MaxSteps $maxSteps -ApiKey $ApiKey
            }
            catch {
                $written = Get-CurrentTurnWritePathsSince -StartCount $writeStart
                $stepRes = New-SubagentErrorResult -Role $rName -Context $stepCtx -Message $_.Exception.Message -Permission $script:AgentPermission -ModifiedFiles $written
            }
            $stepResults += $stepRes
            $prevOutput = [string]$stepRes.output
            if ($stepRes.usage_input_tokens) { $totalUsageIn += [int]$stepRes.usage_input_tokens }
            if ($stepRes.usage_output_tokens) { $totalUsageOut += [int]$stepRes.usage_output_tokens }
            foreach ($rf in @($stepRes.read_files)) {
                if ($rf) { $readSet[[string]$rf] = $true }
            }
            foreach ($mf in @($stepRes.modified_files)) {
                if ($mf) { $modSet[[string]$mf] = $true }
            }
            if ($stepRes.status -eq 'error') { break }
        }
        $readOnlyList = @($readSet.Keys | Where-Object { -not $modSet.ContainsKey($_) } | Sort-Object)
        $modList = @($modSet.Keys | Sort-Object)
        $aggStatus = Resolve-SubagentAggregateStatus -Results $stepResults
        return (@{
            status = $aggStatus
            mode = 'pipeline'
            steps_count = $stepResults.Count
            output = $prevOutput
            results = $stepResults
            read_files = $readOnlyList
            modified_files = $modList
            usage_input_tokens = $totalUsageIn
            usage_output_tokens = $totalUsageOut
        } | ConvertTo-Json -Depth 10 -Compress)
    }
    $roleName = if ($Arguments.role) { [string]$Arguments.role } else { 'craft' }
    $singleRes = Invoke-SubagentInProcess -Root $Root -RoleName $roleName -TaskPrompt ([string]$Arguments.prompt) -ContextMode $ctxMode -MaxSteps $maxSteps -ApiKey $ApiKey
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
        usage_input_tokens = [int]$singleRes.usage_input_tokens
        usage_output_tokens = [int]$singleRes.usage_output_tokens
    } | ConvertTo-Json -Depth 10 -Compress)
}
