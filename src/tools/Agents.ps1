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
    $savedTodos = @($script:ActiveSessionTodos)
    try {
        $script:SubagentDepth = $savedDepth + 1
        $script:AgentPermission = $effPerm
        $script:EnabledTools = $childTools
        $script:NoTools = ($savedNoTools -or $childTools.Count -eq 0)
        $script:ActiveSessionTodos = @()
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
        $script:ActiveSessionTodos = $savedTodos
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

function Resolve-SubagentAggregateStatus {
    param([array]$Results)
    if (-not $Results -or $Results.Count -eq 0) { return 'completed' }
    $statuses = @($Results | ForEach-Object { [string]$_.status })
    if ($statuses -contains 'error') { return 'error' }
    if ($statuses -contains 'timed_out') { return 'timed_out' }
    if ($statuses -contains 'loop_detected') { return 'loop_detected' }
    if ($statuses -contains 'step_limit_reached') { return 'step_limit_reached' }
    foreach ($st in $statuses) {
        if ($st -and $st -ne 'completed') { return $st }
    }
    return 'completed'
}

function Invoke-ParallelSubagentProcesses {
    param([string]$Root, [array]$Tasks, [int]$MaxSteps = 15, [string]$ScriptPath, [int]$TimeoutSec = 180)
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
if ($env:SHELLOSSUS_SUB_NO_SKILLS -eq '1') { $workerArgs.NoSkills = $true }
if ($env:SHELLOSSUS_SUB_NO_TEMPLATES -eq '1') { $workerArgs.NoPromptTemplates = $true }
if ($env:SHELLOSSUS_SUB_NO_CONTEXT -eq '1') { $workerArgs.NoContextFiles = $true }
if ($env:SHELLOSSUS_SUB_REASONING_EFFORT) { $workerArgs.ReasoningEffort = $env:SHELLOSSUS_SUB_REASONING_EFFORT }
& $env:SHELLOSSUS_SUB_SCRIPT @workerArgs
'@
    $argList = if ($env:OS -eq 'Windows_NT') {
        $escaped = ($workerCmd -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
        "-NoProfile -NonInteractive -Command `"$escaped`""
    }
    else {
        @('-NoProfile', '-NonInteractive', '-Command', $workerCmd)
    }
    $workerEnvNames = @(
        'SHELLOSSUS_SUB_SCRIPT',
        'SHELLOSSUS_SUB_ROOT',
        'SHELLOSSUS_SUB_BASEURL',
        'SHELLOSSUS_SUB_MODEL',
        'SHELLOSSUS_SUB_STEPS',
        'SHELLOSSUS_SUB_PROMPT',
        'SHELLOSSUS_SUB_TOOLS',
        'SHELLOSSUS_SUB_NO_TOOLS',
        'SHELLOSSUS_SUB_CONFIG',
        'SHELLOSSUS_SUB_NO_SKILLS',
        'SHELLOSSUS_SUB_NO_TEMPLATES',
        'SHELLOSSUS_SUB_NO_CONTEXT',
        'SHELLOSSUS_SUB_REASONING_EFFORT',
        'SHELLOSSUS_SUB_ROLE',
        'SHELLOSSUS_SUB_ROLE_PROMPT'
    )
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
                $childTools = @(Get-SubagentToolNames -Role $roleObj -ForceReadOnly -NonInteractive)
                $effModel = if ($roleObj.model) { [string]$roleObj.model } elseif ($script:ActiveModelId) { $script:ActiveModelId } else { 'test-model' }
                $promptTemp = New-AgentTempFile
                $outTemp = New-AgentTempFile
                $errTemp = New-AgentTempFile
                $fullPrompt = [string]$t.prompt
                Set-AgentUtf8Content -LiteralPath $promptTemp.FullName -Value $fullPrompt
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + ("  [run_agent:{0}] (parallel ReadOnly) " -f $roleObj.name) + $script:Gm.Grey1 + (Invoke-TruncateLine -Line ([string]$t.prompt) -MaxChars 90).text + $script:Gm.Reset)
                }
                $proc = $null
                $savedSKey = $env:SHELLOSSUS_API_KEY
                $savedWorkerEnv = @{}
                foreach ($envName in $workerEnvNames) {
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
                    $env:SHELLOSSUS_SUB_NO_SKILLS = if ($script:NoSkills) { '1' } else { '0' }
                    $env:SHELLOSSUS_SUB_NO_TEMPLATES = if ($script:NoPromptTemplates) { '1' } else { '0' }
                    $env:SHELLOSSUS_SUB_NO_CONTEXT = if ($script:NoContextFiles) { '1' } else { '0' }
                    $env:SHELLOSSUS_SUB_REASONING_EFFORT = if ($script:ReasoningEffort) { [string]$script:ReasoningEffort } else { '' }
                    $env:SHELLOSSUS_SUB_ROLE = [string]$roleObj.name
                    $env:SHELLOSSUS_SUB_ROLE_PROMPT = [string]$roleObj.system_prompt
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
                    timed_out = $false
                }
            }
            $startWait = Get-Date
            while ($true) {
                $running = @($workers | Where-Object { -not $_.proc.HasExited })
                if ($running.Count -eq 0) { break }
                if (((Get-Date) - $startWait).TotalSeconds -ge $TimeoutSec) {
                    foreach ($rw in $running) {
                        $rw.timed_out = $true
                        $null = Stop-AgentProcessTree -Process $rw.proc
                        Wait-Process -InputObject $rw.proc -Timeout 2 -ErrorAction SilentlyContinue
                    }
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            foreach ($w in $workers) {
                $replyText = ''
                $stepsUsed = 0
                $wReadSet = @{}
                $pendingReadsById = @{}
                $untrackedReads = @()
                $sawToolExecEnd = $false
                $sawTurnEnd = $false
                $msgUsageIn = 0
                $msgUsageOut = 0
                $turnUsageIn = -1
                $turnUsageOut = -1
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
                                if ($ev.usage) {
                                    if ($ev.usage.prompt_tokens) { $msgUsageIn += [int]$ev.usage.prompt_tokens }
                                    elseif ($ev.usage.input_tokens) { $msgUsageIn += [int]$ev.usage.input_tokens }
                                    if ($ev.usage.completion_tokens) { $msgUsageOut += [int]$ev.usage.completion_tokens }
                                    elseif ($ev.usage.output_tokens) { $msgUsageOut += [int]$ev.usage.output_tokens }
                                }
                                if ($ev.usage_input_tokens) { $msgUsageIn += [int]$ev.usage_input_tokens }
                                if ($ev.usage_output_tokens) { $msgUsageOut += [int]$ev.usage_output_tokens }
                                if ($ev.tool_calls) {
                                    foreach ($tc in @($ev.tool_calls)) {
                                        $fn = if ($tc.function -and $tc.function.name) { [string]$tc.function.name } else { '' }
                                        if ($fn -in @('read_file', 'read') -and $tc.function.arguments) {
                                            try {
                                                $pa = ([string]$tc.function.arguments) | ConvertFrom-Json -ErrorAction Stop
                                                if ($pa.path) {
                                                    if ($tc.id) { $pendingReadsById[[string]$tc.id] = [string]$pa.path }
                                                    else { $untrackedReads += [string]$pa.path }
                                                }
                                            }
                                            catch {}
                                        }
                                    }
                                }
                            }
                            elseif ($ev.type -eq 'tool_execution_end') {
                                $sawToolExecEnd = $true
                                $evId = if ($ev.id) { [string]$ev.id } else { '' }
                                if ($evId -and $pendingReadsById.ContainsKey($evId)) {
                                    $rPath = $pendingReadsById[$evId]
                                    try {
                                        $parsedToolRes = ([string]$ev.result) | ConvertFrom-Json -ErrorAction Stop
                                        if ($null -ne $parsedToolRes -and (-not $parsedToolRes.error) -and ($parsedToolRes.status -notin @('cancelled', 'instructions_required', 'repeated_call_warning', 'loop_detected', 'error'))) {
                                            $wReadSet[$rPath] = $true
                                        }
                                    }
                                    catch {}
                                }
                            }
                            elseif ($ev.type -eq 'turn_end') {
                                $sawTurnEnd = $true
                                if ($ev.status) { $wStatus = [string]$ev.status }
                                if ($null -ne $ev.usage_input_tokens) { $turnUsageIn = [int]$ev.usage_input_tokens }
                                if ($null -ne $ev.usage_output_tokens) { $turnUsageOut = [int]$ev.usage_output_tokens }
                                if ($ev.usage) {
                                    if ($null -ne $ev.usage.prompt_tokens) { $turnUsageIn = [int]$ev.usage.prompt_tokens }
                                    elseif ($null -ne $ev.usage.input_tokens) { $turnUsageIn = [int]$ev.usage.input_tokens }
                                    if ($null -ne $ev.usage.completion_tokens) { $turnUsageOut = [int]$ev.usage.completion_tokens }
                                    elseif ($null -ne $ev.usage.output_tokens) { $turnUsageOut = [int]$ev.usage.output_tokens }
                                }
                            }
                        }
                        catch {}
                    }
                }
                if (-not $sawToolExecEnd) {
                    foreach ($ur in $untrackedReads) { $wReadSet[$ur] = $true }
                    foreach ($pr in $pendingReadsById.Values) { $wReadSet[$pr] = $true }
                }
                if (Test-Path -LiteralPath $w.err_file) {
                    $errRaw = Get-Content -LiteralPath $w.err_file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($errRaw -and $errRaw.Trim() -and (-not $sawTurnEnd -or -not $replyText)) {
                        $wStatus = 'error'
                        $replyText = if ($replyText) { $replyText + "`nSubagent error: " + $errRaw.Trim() } else { 'Subagent error: ' + $errRaw.Trim() }
                    }
                }
                if (-not $sawTurnEnd -and $w.timed_out) {
                    $wStatus = 'timed_out'
                    if (-not $replyText) {
                        $replyText = "Subagent timed out after ${TimeoutSec}s."
                    }
                }
                elseif (-not $sawTurnEnd -and $wStatus -eq 'completed' -and $w.proc -and $w.proc.HasExited -and $w.proc.ExitCode -ne 0) {
                    $wStatus = 'error'
                }
                $wUsageIn = if ($turnUsageIn -ge 0) { $turnUsageIn } else { $msgUsageIn }
                $wUsageOut = if ($turnUsageOut -ge 0) { $turnUsageOut } else { $msgUsageOut }
                if ($null -ne $script:ActiveState) {
                    if ($wUsageIn -gt 0) { $script:ActiveState.usage_input_tokens = [int]$script:ActiveState.usage_input_tokens + $wUsageIn }
                    if ($wUsageOut -gt 0) { $script:ActiveState.usage_output_tokens = [int]$script:ActiveState.usage_output_tokens + $wUsageOut }
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
                    usage_input_tokens = $wUsageIn
                    usage_output_tokens = $wUsageOut
                }
            }
        }
        finally {
            foreach ($w in $workers) {
                if ($w.proc -and (-not $w.proc.HasExited)) {
                    $null = Stop-AgentProcessTree -Process $w.proc
                    Wait-Process -InputObject $w.proc -Timeout 2 -ErrorAction SilentlyContinue
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
                try {
                    $subRes = Invoke-SubagentInProcess -Root $Root -RoleName $rName -TaskPrompt ([string]$pt.prompt) -ContextMode 'clean' -MaxSteps $maxSteps -ForceReadOnly
                }
                catch {
                    $subRes = @{
                        role = $rName
                        permission = 'ReadOnly'
                        context = 'clean'
                        status = 'error'
                        output = ('Subagent error: ' + $_.Exception.Message)
                        steps_used = 0
                        read_files = @()
                        modified_files = @()
                        usage_input_tokens = 0
                        usage_output_tokens = 0
                    }
                }
                $results += $subRes
                foreach ($rf in @($subRes.read_files)) {
                    if ($rf) { $readSet[[string]$rf] = $true }
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
        return (@{
            status = $aggStatus
            mode = 'parallel'
            tasks_count = $results.Count
            output = ($summaryParts -join "`n`n")
            results = $results
            read_files = @($readSet.Keys | Sort-Object)
            modified_files = @()
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
            try {
                $stepRes = Invoke-SubagentInProcess -Root $Root -RoleName $rName -TaskPrompt $resolvedPrompt -ContextMode $stepCtx -MaxSteps $maxSteps
            }
            catch {
                $stepRes = @{
                    role = $rName
                    permission = $script:AgentPermission
                    context = $stepCtx
                    status = 'error'
                    output = ('Subagent error: ' + $_.Exception.Message)
                    steps_used = 0
                    read_files = @()
                    modified_files = @()
                    usage_input_tokens = 0
                    usage_output_tokens = 0
                }
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
        usage_input_tokens = [int]$singleRes.usage_input_tokens
        usage_output_tokens = [int]$singleRes.usage_output_tokens
    } | ConvertTo-Json -Depth 10 -Compress)
}
