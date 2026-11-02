# Agent turn loop (HTTP retries, finish_reason check, overflow auto-compaction, tool dispatch, JSON event stream) and interactive CLI REPL.

function Write-AgentJsonEvent {
    param([string]$EventType, [hashtable]$Payload = @{})
    if ($script:OutputMode -ne 'json') { return }
    $ev = @{
        type = $EventType
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    }
    foreach ($k in $Payload.Keys) { $ev[$k] = $Payload[$k] }
    Write-Host ($ev | ConvertTo-Json -Depth 20 -Compress)
}

function Wait-AgentProcessWithSpinner {
    param($Process, [string]$StatusLabel = 'Waiting for model', [int]$TimeoutSec = 180, [int]$PollMs = 200)
    $frames = @('|', '/', '-', '\')
    $frameIdx = 0
    $startWait = Get-Date
    $showSpinner = ($script:OutputMode -ne 'json') -and (-not $script:HideSpinner)
    try {
        while (-not $Process.HasExited) {
            $elapsed = ((Get-Date) - $startWait).TotalSeconds
            if ($showSpinner) {
                $spinChar = $frames[$frameIdx % $frames.Count]
                $frameIdx++
                $statusLine = ("`r" + $script:Gm.Grey1 + ("  [{0}] {1} ({2:0.0}s)..." -f $spinChar, $StatusLabel, $elapsed) + $script:Gm.Reset)
                Write-Host $statusLine -NoNewline
            }
            if ($elapsed -ge ($TimeoutSec + 5)) {
                if (-not $Process.HasExited) {
                    Stop-Process -InputObject $Process -Force -ErrorAction SilentlyContinue
                    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                }
                throw "Request timed out after ${TimeoutSec}s."
            }
            Start-Sleep -Milliseconds $PollMs
        }
    }
    finally {
        if ($showSpinner -and $frameIdx -gt 0) {
            $clearLine = "`r" + (' ' * ($StatusLabel.Length + 28)) + "`r"
            Write-Host $clearLine -NoNewline
        }
        if (-not $Process.HasExited) {
            Stop-Process -InputObject $Process -Force -ErrorAction SilentlyContinue
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -InputObject $Process -Timeout 2 -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AgentHttpRequest {
    param(
        [string]$Uri,
        [string]$ApiKey,
        [string]$Body,
        [string]$OutFile,
        [int]$TimeoutSec = 180,
        [string]$StatusLabel = 'Waiting for model',
        [switch]$ForceBackgroundWorker
    )
    $iwrCmd = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ((-not $ForceBackgroundWorker) -and (($iwrCmd -and $iwrCmd.CommandType -eq 'Function') -or $script:DisableAsyncHttp)) {
        $request = @{
            Uri = $Uri
            Method = 'Post'
            Headers = @{ Authorization = "Bearer $ApiKey" }
            ContentType = 'application/json; charset=utf-8'
            Body = $Body
            TimeoutSec = $TimeoutSec
            ErrorAction = 'Stop'
        }
        Invoke-WebRequest @request -UseBasicParsing -OutFile $OutFile
        return
    }
    $shellExe = (Get-AgentEnvironment).shell_exe
    $reqTemp = New-TemporaryFile -ErrorAction Stop
    $errTemp = New-TemporaryFile -ErrorAction Stop
    $stdoutTemp = New-TemporaryFile -ErrorAction Stop
    $stderrTemp = New-TemporaryFile -ErrorAction Stop
    try {
        Set-Content -LiteralPath $reqTemp.FullName -Value $Body -Encoding UTF8 -NoNewline -ErrorAction Stop
        $workerCmd = @'
$ErrorActionPreference = 'Stop'
try {
    Invoke-WebRequest -Uri $env:SHELLOSSUS_HTTP_URI -Method 'Post' -Headers @{ Authorization = ('Bearer ' + $env:SHELLOSSUS_HTTP_KEY) } -ContentType 'application/json; charset=utf-8' -InFile $env:SHELLOSSUS_HTTP_IN -OutFile $env:SHELLOSSUS_HTTP_OUT -TimeoutSec ([int]$env:SHELLOSSUS_HTTP_TIMEOUT) -UseBasicParsing -ErrorAction Stop
}
catch {
    $msg = $_.Exception.Message
    $details = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        $details = $_.ErrorDetails.Message.Trim()
    }
    if ($details) {
        try {
            $parsed = $details | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error -and $parsed.error.message) { $details = [string]$parsed.error.message }
        }
        catch {}
        if ($details.Length -gt 300) { $details = $details.Substring(0, 300) + '...' }
        $msg = $msg + ' (' + $details + ')'
    }
    Set-Content -LiteralPath $env:SHELLOSSUS_HTTP_ERR -Value $msg -Encoding UTF8 -NoNewline
    exit 1
}
'@
        $argList = if ($env:OS -eq 'Windows_NT') {
            $escaped = ($workerCmd -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
            "-NoProfile -NonInteractive -Command `"$escaped`""
        }
        else {
            @('-NoProfile', '-NonInteractive', '-Command', $workerCmd)
        }
        $proc = $null
        try {
            $env:SHELLOSSUS_HTTP_URI = $Uri
            $env:SHELLOSSUS_HTTP_KEY = $ApiKey
            $env:SHELLOSSUS_HTTP_IN = $reqTemp.FullName
            $env:SHELLOSSUS_HTTP_OUT = $OutFile
            $env:SHELLOSSUS_HTTP_ERR = $errTemp.FullName
            $env:SHELLOSSUS_HTTP_TIMEOUT = [string]$TimeoutSec
            $proc = Start-Process -FilePath $shellExe -ArgumentList $argList -RedirectStandardOutput $stdoutTemp.FullName -RedirectStandardError $stderrTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
        }
        finally {
            $env:SHELLOSSUS_HTTP_URI = $null
            $env:SHELLOSSUS_HTTP_KEY = $null
            $env:SHELLOSSUS_HTTP_IN = $null
            $env:SHELLOSSUS_HTTP_OUT = $null
            $env:SHELLOSSUS_HTTP_ERR = $null
            $env:SHELLOSSUS_HTTP_TIMEOUT = $null
        }
        Wait-AgentProcessWithSpinner -Process $proc -StatusLabel $StatusLabel -TimeoutSec $TimeoutSec
        $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        if ($errItem -and $errItem.Length -gt 0) {
            $errText = Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($errText) { throw $errText.Trim() }
        }
        if ($null -ne $proc.ExitCode -and [int]$proc.ExitCode -ne 0) {
            $stdErrText = Get-Content -LiteralPath $stderrTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($stdErrText -and $stdErrText.Trim()) { throw $stdErrText.Trim() }
            throw "HTTP worker exited with code $($proc.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $reqTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrTemp.FullName -Force -ErrorAction SilentlyContinue
    }
}

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

function Invoke-AgentTurn {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [string]$Root, [int]$Steps = 50, [int]$MaxRepeatCalls = 0)
    $overflowRetried = $false
    $script:ActiveModelId = $ModelId
    if ($Root) { $script:ActiveWorkspace = $Root }
    $State.step_limit_reached = $false
    $State.loop_detected = $false
    $State.repeated_tool = $null
    $repeatLimit = if ($MaxRepeatCalls -gt 0) { $MaxRepeatCalls } elseif ($script:MaxRepeatToolCalls -gt 0) { [int]$script:MaxRepeatToolCalls } else { 3 }
    $mutationEpoch = 0
    $toolCallCounts = @{}
    for ($step = 0; $step -lt $Steps; $step++) {
        if ($step -gt 0) {
            $stStep = Get-ContextStats -State $State
            if ($stStep.chars -gt 60000) {
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Yellow + '  [auto-compact] Context exceeds 60k chars, compacting older history...' + $script:Gm.Reset)
                }
                try {
                    if (Invoke-AgentCompact -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey) {
                        $mutationEpoch++
                        $toolCallCounts = @{}
                    }
                }
                catch {}
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
        $tempResponse = New-TemporaryFile -ErrorAction Stop
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
        Ensure-SessionTree -State $State
        Write-AgentJsonEvent -EventType 'message_end' -Payload @{
            role = 'assistant'
            content = $message.content
            tool_calls = if ($message.tool_calls) { @($message.tool_calls) } else { @() }
        }
        if ($message.content -and $script:OutputMode -ne 'json') { Write-AgentReply -Content $message.content }
        if (-not $message.tool_calls) {
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ step = $step; status = 'completed' }
            return
        }
        $loopAborted = $false
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
            $output = Invoke-AgentTool -Root $Root -Call $call
            Write-AgentJsonEvent -EventType 'tool_execution_end' -Payload @{ id = [string]$call.id; name = [string]$call.function.name; result = $output }
            $State.messages += @{ role = 'tool'; tool_call_id = $call.id; content = $output }
            Ensure-SessionTree -State $State
            if ($canonToolName -in @('write_file', 'edit_file', 'run_command')) {
                try {
                    $parsedOut = $output | ConvertFrom-Json -ErrorAction Stop
                    if ($parsedOut.status -in @('written', 'executed', 'timed_out')) {
                        $mutationEpoch++
                    }
                }
                catch {}
            }
        }
        if ($loopAborted) {
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Yellow + "Loop detected: repeated identical calls to '$($State.repeated_tool)'. Turn stopped (completed edits are preserved; use /undo to revert)." + $script:Gm.Reset)
            }
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ step = $step; status = 'loop_detected'; tool = $State.repeated_tool }
            return
        }
    }
    $State.step_limit_reached = $true
    if ($script:OutputMode -ne 'json') {
        Write-Host ($script:Gm.Yellow + 'Step limit reached. Use /continue to keep going, or /clear to start over.' + $script:Gm.Reset)
    }
    Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ step = $Steps; status = 'step_limit_reached' }
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

if (-not $LibraryOnly) {
    $script:AgentConfigPath = Format-ConfigPath -Path $ConfigPath
    $resolvedCfg = Resolve-AgentConfigPath -Path $ConfigPath
    $script:LegacyAgentConfigPath = if ($resolvedCfg -and ($resolvedCfg -ne $ConfigPath)) { Format-ConfigPath -Path $resolvedCfg } else { '' }
    $config = Read-AgentConfig -Path $ConfigPath
    if ($Setup) {
        Write-Host ($script:Gm.OscInit + $script:Gm.Fg + "Save settings to: $ConfigPath" + $script:Gm.Reset)
        Write-Host ($script:Gm.Yellow + 'API key is stored as plain text in your user profile, outside the project.' + $script:Gm.Reset)
        $defaultUrl = $BaseUrl
        if (-not $defaultUrl) { $defaultUrl = $env:H_AGENT_BASE_URL }
        if (-not $defaultUrl) { $defaultUrl = $config.SHELLOSSUS_BASE_URL }
        $inputUrl = Read-Host "API base URL including /v1 [$defaultUrl]"
        if (-not $inputUrl) { $inputUrl = $defaultUrl }
        if ($inputUrl -notmatch '^https://[^\s]+$') { throw 'Use an HTTPS API base URL.' }
        $defaultModel = $Model
        if (-not $defaultModel) { $defaultModel = $env:H_AGENT_MODEL }
        if (-not $defaultModel) { $defaultModel = $config.SHELLOSSUS_MODEL }
        $inputModel = Read-Host "Model ID [$defaultModel]"
        if (-not $inputModel) { $inputModel = $defaultModel }
        if (-not $inputModel) { throw 'Model ID is required.' }
        Write-Host ($script:Gm.Yellow + 'Key input is visible. Enter keeps the saved key, if any.' + $script:Gm.Reset)
        $inputKey = Read-Host 'API key'
        if (-not $inputKey) { $inputKey = $config.SHELLOSSUS_API_KEY }
        if (-not $inputKey) { throw 'API key is required.' }
        $inputWorkspace = Read-Host 'Default workspace (Enter = current folder at each launch)'
        Save-AgentConfig -Path $ConfigPath -Config @{
            SHELLOSSUS_BASE_URL = $inputUrl
            SHELLOSSUS_MODEL = $inputModel
            SHELLOSSUS_API_KEY = $inputKey
            SHELLOSSUS_WORKSPACE = $inputWorkspace
        }
        Remove-Variable inputKey -ErrorAction SilentlyContinue
        Write-Host ($script:Gm.BoldGreen + 'Settings saved. Start shellossus from your working folder.' + $script:Gm.Reset)
        return
    }
    if (-not $BaseUrl) { $BaseUrl = $env:H_AGENT_BASE_URL }
    if (-not $BaseUrl) { $BaseUrl = $config.SHELLOSSUS_BASE_URL }
    if (-not $Model) { $Model = $env:H_AGENT_MODEL }
    if (-not $Model) { $Model = $config.SHELLOSSUS_MODEL }
    if ($PSBoundParameters.Keys -notcontains 'Workspace') {
        if ($env:SHELLOSSUS_WORKSPACE) { $Workspace = $env:SHELLOSSUS_WORKSPACE }
        elseif ($env:H_AGENT_WORKSPACE) { $Workspace = $env:H_AGENT_WORKSPACE }
        elseif ($config.SHELLOSSUS_WORKSPACE) { $Workspace = $config.SHELLOSSUS_WORKSPACE }
    }
    $rootItem = Get-Item -LiteralPath $Workspace -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Workspace must be a directory.' }
    $rootPath = Resolve-AgentPath -Root $rootItem.FullName -RelativePath '.'
    $script:ActiveWorkspace = $rootPath
    $configDir = Split-Path $script:AgentConfigPath -Parent
    $sessionDir = if ($SessionDir) { $SessionDir } else { Join-Path $configDir 'sessions' }
    if ($Export -and ($Export -match '\.jsonl$') -and (Test-Path -LiteralPath $Export)) {
        $expState = @{ session_id = ''; workspace = $rootPath; model = $Model; messages = @() }
        Invoke-SessionResume -SessionFile $Export -State $expState | Out-Null
        $outHtml = $Export -replace '\.jsonl$', '.html'
        $exported = Export-AgentSessionHtml -State $expState -OutputPath $outHtml
        Write-Host ($script:Gm.Green + "Exported session HTML: $exported" + $script:Gm.Reset)
        return
    }
    if (-not $BaseUrl) { $BaseUrl = Read-Host 'API base URL (including /v1)' }
    if ($BaseUrl -notmatch '^https://[^\s]+$') { throw 'Use an HTTPS API base URL.' }
    if (-not $Model) { $Model = Read-Host 'Model ID' }
    if (-not $Model) { throw 'Model ID is required.' }
    if ($MaxSteps -lt 1 -or $MaxSteps -gt 500) { throw 'MaxSteps must be between 1 and 500.' }
    if ($MaxRepeatCalls -lt 1 -or $MaxRepeatCalls -gt 50) { throw 'MaxRepeatCalls must be between 1 and 50.' }
    $script:MaxRepeatToolCalls = $MaxRepeatCalls
    if ($Permission -notin @('ReadOnly', 'Ask', 'AutoEdit', 'Auto')) { throw 'Permission must be one of: ReadOnly, Ask, AutoEdit, Auto.' }
    $script:AgentPermission = $Permission
    $script:Diagnostics = [bool]$Diagnostics
    $script:OutputMode = if ($Mode) { $Mode.ToLower() } else { 'text' }
    if ($script:OutputMode -notin @('text', 'json')) { throw 'Mode must be text or json.' }
    $script:NoTools = [bool]$NoTools
    $script:EnabledTools = if ($Tools) { @($Tools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    $script:ExcludedTools = if ($ExcludeTools) { @($ExcludeTools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    $script:NoSkills = [bool]$NoSkills
    $script:NoPromptTemplates = [bool]$NoPromptTemplates
    $script:NoContextFiles = [bool]$NoContextFiles
    if ($HideReasoning) { $script:ShowReasoning = 'hide' }
    if ($ReasoningEffort) {
        if ($ReasoningEffort -notin @('low', 'medium', 'high')) { throw 'ReasoningEffort must be low, medium, or high.' }
        $script:ReasoningEffort = $ReasoningEffort
    }
    $endpoint = $BaseUrl.TrimEnd('/') + '/chat/completions'
    $agentKey = $env:SHELLOSSUS_API_KEY
    if (-not $agentKey) { $agentKey = $env:H_AGENT_API_KEY }
    if (-not $agentKey) { $agentKey = $config.SHELLOSSUS_API_KEY }
    $config.Clear()
    if (-not $agentKey) {
        Write-Host ($script:Gm.Yellow + 'Key input is visible. Run shellossus -Setup to save settings for next time.' + $script:Gm.Reset)
        $agentKey = Read-Host 'API key'
    }
    if (-not $agentKey) { throw 'API key is required.' }
    $sessionId = 'sess-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999)
    $sessionFile = if ($NoSession) { '' } else { Join-Path $sessionDir ($sessionId + '.jsonl') }
    $fullSystemPrompt = Build-SystemPrompt -Root $rootPath -ConfigDir $configDir
    $system = @{ role = 'system'; content = $fullSystemPrompt }
    $state = @{
        session_id = $sessionId
        session_name = $SessionName
        workspace = $rootPath
        model = $Model
        messages = @($system)
        tree_entries = @()
        usage_input_tokens = 0
        usage_output_tokens = 0
    }
    $script:ActiveSessionId = $sessionId
    $script:ActiveSessionFile = $sessionFile
    $script:ActiveModelId = $Model
    Sync-AgentCapabilities -State $state | Out-Null
    $undoStack = @()
    $lastFailedQuestion = ''
    if ($Session) {
        $candSess = if (Test-Path -LiteralPath $Session) { $Session } else { Join-Path $sessionDir (Split-Path $Session -Leaf) }
        if (-not (Test-Path -LiteralPath $candSess) -and ($candSess -notmatch '\.jsonl$')) { $candSess += '.jsonl' }
        if (Test-Path -LiteralPath $candSess) {
            $sessionFile = if ($NoSession) { '' } else { $candSess }
            Invoke-SessionResume -SessionFile $candSess -State $state -CurrentWorkspace $rootPath | Out-Null
            if ($PSBoundParameters.Keys -notcontains 'Model' -and $state.model) { $Model = $state.model }
        }
        elseif (-not $NoSession) {
            $sessionFile = $candSess
        }
    }
    elseif ($Fork) {
        $candFork = if (Test-Path -LiteralPath $Fork) { $Fork } else { Join-Path $sessionDir (Split-Path $Fork -Leaf) }
        if (-not (Test-Path -LiteralPath $candFork) -and ($candFork -notmatch '\.jsonl$')) { $candFork += '.jsonl' }
        if (-not (Test-Path -LiteralPath $candFork)) { throw "Session file to fork not found: $Fork" }
        $srcState = @{ session_id = ''; workspace = $rootPath; model = $Model; messages = @() }
        Invoke-SessionResume -SessionFile $candFork -State $srcState -CurrentWorkspace $rootPath | Out-Null
        $forkRes = Invoke-SessionFork -State $srcState -SessionDir $sessionDir -NewName $SessionName
        $state = $forkRes.state
        $sessionFile = if ($NoSession) { '' } else { $forkRes.session_file }
    }
    elseif ($Continue) {
        $latestProjectSession = Find-ProjectSession -SessionDir $sessionDir -Workspace $rootPath
        if ($latestProjectSession) {
            $sessionFile = if ($NoSession) { '' } else { $latestProjectSession }
            Invoke-SessionResume -SessionFile $latestProjectSession -State $state -CurrentWorkspace $rootPath | Out-Null
            if ($PSBoundParameters.Keys -notcontains 'Model' -and $state.model) { $Model = $state.model }
        }
    }
    if ($Export) {
        $exported = Export-AgentSessionHtml -State $state -OutputPath $Export
        Write-Host ($script:Gm.Green + "Exported session HTML: $exported" + $script:Gm.Reset)
        return
    }
    try {
        if ($Prompt) {
            $tplPrompt = Resolve-PromptTemplate -Root $rootPath -ConfigDir $configDir -InputText $Prompt.Trim()
            $effectivePrompt = if ($null -ne $tplPrompt) { $tplPrompt } else { $Prompt }
            $expandedPrompt = Expand-UserPrompt -Root $rootPath -Prompt $effectivePrompt
            $state.messages += @{ role = 'user'; content = $expandedPrompt }
            Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
            Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
            return
        }
        Write-Host ($script:Gm.OscInit + $script:Gm.BoldGreen + "shellossus | model: $Model | permission: $($script:AgentPermission) | workspace: $rootPath" + $script:Gm.Reset)
        if (Get-AgentsContext -Root $rootPath -ConfigDir $configDir) { Write-Host ($script:Gm.Aqua + 'Loaded AGENTS.md/CLAUDE.md instructions.' + $script:Gm.Reset) }
        if (Get-SkillsCatalog -Root $rootPath -ConfigDir $configDir) { Write-Host ($script:Gm.Aqua + 'Loaded skills catalog.' + $script:Gm.Reset) }
        Write-Host ($script:Gm.Grey1 + 'Commands: /help /status /session /permission /reasoning /continue /undo /retry /compact /tree /fork /export /copy /reload /model /sessions /resume /save /new /exit' + $script:Gm.Reset)
        while ($true) {
            Write-Host ("`n" + $script:Gm.Grey0 + ('-' * 40) + $script:Gm.Reset)
            Write-Host ($script:Gm.BoldBlue + 'You: ' + $script:Gm.Fg) -NoNewline
            $question = Read-Host
            Write-Host $script:Gm.Reset -NoNewline
            if (-not $question) { continue }
            $trimmedQ = $question.Trim()
            if ($trimmedQ -eq '/exit' -or $trimmedQ -eq '/quit') { break }
            if ($trimmedQ -eq '/clear' -or $trimmedQ -eq '/new') {
                $newId = 'sess-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999)
                $fullSystemPrompt = Build-SystemPrompt -Root $rootPath -ConfigDir $configDir
                $system = @{ role = 'system'; content = $fullSystemPrompt }
                $state.session_id = $newId
                $state.session_name = ''
                $state.parent_session = ''
                $state.workspace = $rootPath
                $state.model = $Model
                $state.messages = @($system)
                $state.tree_entries = @()
                $state.leaf_id = $null
                Sync-AgentCapabilities -State $state | Out-Null
                $undoStack = @()
                $sessionFile = if ($NoSession) { '' } else { Join-Path $sessionDir ($newId + '.jsonl') }
                $script:ActiveSessionId = $newId
                $script:ActiveSessionFile = $sessionFile
                Write-Host ($script:Gm.Grey1 + 'Started a new conversation session.' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/help') {
                Write-Host ($script:Gm.Aqua + '  /status (/session, /tokens)  ' + $script:Gm.Fg + 'Show context size, token usage, model, permission, and session info' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /permission <mode>           ' + $script:Gm.Fg + 'Set mode: ReadOnly | Ask | AutoEdit (no-ask writes) | Auto' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /diagnostics [on|off]        ' + $script:Gm.Fg + 'Show or toggle pre-request capability/tool diagnostics' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /reasoning (/thinking) <arg> ' + $script:Gm.Fg + 'View: compact | full | hide; Effort: low | medium | high | off' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /continue [steps]            ' + $script:Gm.Fg + 'Continue after hitting step limit (or continue last response)' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /undo                        ' + $script:Gm.Fg + 'Revert last turn AND restore modified/created files on disk' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /retry                       ' + $script:Gm.Fg + 'Retry the last failed user request' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /compact [focus]             ' + $script:Gm.Fg + 'Summarize older turns into a structured context handoff' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /name [name]                 ' + $script:Gm.Fg + 'Set or display the human-friendly session name' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /tree [entry-id]             ' + $script:Gm.Fg + 'Show conversation tree or switch active branch to <entry-id>' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /fork [entry-id] (/clone)    ' + $script:Gm.Fg + 'Fork current branch (or from <entry-id>) into a new session file' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /export [path.html|.jsonl]   ' + $script:Gm.Fg + 'Export session to standalone HTML (or JSONL)' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /import <path.jsonl>         ' + $script:Gm.Fg + 'Import and resume a JSONL session file' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /copy                        ' + $script:Gm.Fg + 'Copy the last assistant response to clipboard' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /reload                      ' + $script:Gm.Fg + 'Reload AGENTS.md, CLAUDE.md, SYSTEM.md, skills, and prompt templates' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /hotkeys                     ' + $script:Gm.Fg + 'Display input shortcuts and syntax reference' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /model <id>                  ' + $script:Gm.Fg + 'Switch active model ID for this session' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /sessions                    ' + $script:Gm.Fg + 'List saved sessions in ~/.shellossus/sessions' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /resume <num|name>           ' + $script:Gm.Fg + 'Resume a saved session by number or filename' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /save [name]                 ' + $script:Gm.Fg + 'Save conversation to current or named session file' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /new (/clear)                ' + $script:Gm.Fg + 'Start a fresh session while keeping old session files' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /exit (/quit)                ' + $script:Gm.Fg + 'Exit shellossus' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /skill:<name> [args]         ' + $script:Gm.Fg + 'Invoke a skill directly with arguments' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /<template> [args]           ' + $script:Gm.Fg + 'Run a custom Markdown prompt from .shellossus/prompts/<name>.md' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  @path/to/file                ' + $script:Gm.Fg + 'Inline-attach a workspace file into your prompt' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  !command / !!command         ' + $script:Gm.Fg + 'Run shell command (! adds to context, !! local only)' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/hotkeys') {
                Write-Host ($script:Gm.Aqua + '  @path/to/file     ' + $script:Gm.Fg + 'Attach file contents inline into prompt' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  !cmd              ' + $script:Gm.Fg + 'Execute shell command and append output to conversation context' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  !!cmd             ' + $script:Gm.Fg + 'Execute shell command locally without adding to context' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /skill:<name>     ' + $script:Gm.Fg + 'Expand a skill SKILL.md into the prompt' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /<template>       ' + $script:Gm.Fg + 'Expand a prompt template with $1, $2, $@, ${1:-default}' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  Ctrl+C            ' + $script:Gm.Fg + 'Interrupt running command or exit interactive prompt' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -match '^/permission(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $reqPerm = $Matches[1].Trim()
                    $matchedPerm = @('ReadOnly', 'Ask', 'AutoEdit', 'Auto') | Where-Object { $_ -ieq $reqPerm } | Select-Object -First 1
                    if ($matchedPerm) {
                        $script:AgentPermission = $matchedPerm
                        $syncRes = Sync-AgentCapabilities -State $state -RecordTransition
                        $toolsInfo = if ($syncRes.tools.Count -gt 0) { $syncRes.tools -join ', ' } else { 'none' }
                        Write-Host ($script:Gm.Green + "  Permission mode set to: $($script:AgentPermission) (tools: $toolsInfo)" + $script:Gm.Reset)
                    }
                    else {
                        Write-Host ($script:Gm.Red + '  Invalid permission mode. Choose: ReadOnly, Ask, AutoEdit, Auto' + $script:Gm.Reset)
                    }
                }
                else {
                    Write-Host ($script:Gm.Aqua + "  Current permission mode: $($script:AgentPermission) (use /permission ReadOnly|Ask|AutoEdit|Auto)" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/diagnostics(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $dArg = $Matches[1].Trim().ToLower()
                    if ($dArg -in @('on', 'true', '1')) {
                        $script:Diagnostics = $true
                        Write-Host ($script:Gm.Green + '  Diagnostics enabled.' + $script:Gm.Reset)
                    }
                    elseif ($dArg -in @('off', 'false', '0')) {
                        $script:Diagnostics = $false
                        Write-Host ($script:Gm.Green + '  Diagnostics disabled.' + $script:Gm.Reset)
                    }
                    else {
                        Write-Host ($script:Gm.Red + '  Usage: /diagnostics [on|off]' + $script:Gm.Reset)
                    }
                }
                else {
                    $capNow = Get-AgentCapabilities -Root $rootPath
                    $tList = if ($capNow.tool_names.Count -gt 0) { $capNow.tool_names -join ', ' } else { 'none' }
                    Write-Host ($script:Gm.Aqua + "  Diagnostics: $($script:Diagnostics) | Mode: $($capNow.permission) | Shell: $($capNow.environment.shell_exe) $($capNow.environment.shell_version) | Tools: $tList" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/(?:reasoning|thinking)(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $argR = $Matches[1].Trim().ToLower()
                    if ($argR -in @('compact', 'full', 'hide')) {
                        $script:ShowReasoning = $argR
                        Write-Host ($script:Gm.Green + "  Reasoning display set to: $($script:ShowReasoning)" + $script:Gm.Reset)
                    }
                    elseif ($argR -in @('low', 'medium', 'high')) {
                        $script:ReasoningEffort = $argR
                        Write-Host ($script:Gm.Green + "  Reasoning effort set to: $($script:ReasoningEffort)" + $script:Gm.Reset)
                    }
                    elseif ($argR -eq 'default' -or $argR -eq 'off') {
                        $script:ReasoningEffort = ''
                        Write-Host ($script:Gm.Green + '  Reasoning effort reset to provider default.' + $script:Gm.Reset)
                    }
                    else {
                        Write-Host ($script:Gm.Red + '  Usage: /reasoning [compact|full|hide|low|medium|high|default]' + $script:Gm.Reset)
                    }
                }
                else {
                    $effLabel = if ($script:ReasoningEffort) { $script:ReasoningEffort } else { 'default' }
                    Write-Host ($script:Gm.Aqua + "  Reasoning view: $($script:ShowReasoning) | effort: $effLabel" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/name(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $state.session_name = $Matches[1].Trim()
                    Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                    Write-Host ($script:Gm.Green + "  Session name set to: $($state.session_name)" + $script:Gm.Reset)
                }
                else {
                    $nm = if ($state.session_name) { $state.session_name } else { '(unnamed)' }
                    Write-Host ($script:Gm.Aqua + "  Session name: $nm (use /name <text> to set)" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/tree(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $targetEntryId = $Matches[1].Trim()
                    try {
                        Switch-SessionBranch -State $state -TargetId $targetEntryId | Out-Null
                        $undoStack = @()
                        Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                        Write-Host ($script:Gm.Green + "  Switched active branch to entry $targetEntryId ($($state.messages.Count) messages in active path)." + $script:Gm.Reset)
                    }
                    catch {
                        Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
                    }
                }
                else {
                    $treeNodes = @(Get-SessionTree -State $state)
                    if ($treeNodes.Count -eq 0) {
                        Write-Host ($script:Gm.Grey1 + '  Session tree is empty.' + $script:Gm.Reset)
                    }
                    else {
                        foreach ($node in $treeNodes) {
                            $marker = if ($node.is_leaf) { '*' } elseif ($node.active) { '+' } else { '-' }
                            $parentInfo = if ($node.parent_id) { " <- $($node.parent_id)" } else { ' (root)' }
                            $color = if ($node.is_leaf) { $script:Gm.BoldGreen } elseif ($node.active) { $script:Gm.Aqua } else { $script:Gm.Grey1 }
                            Write-Host ($color + ("  {0} [{1}] ({2}{3}) " -f $marker, $node.id, $node.role, $parentInfo) + $script:Gm.Fg + $node.preview + $script:Gm.Reset)
                        }
                        Write-Host ($script:Gm.Grey1 + '  (Use /tree <entry-id> to switch branch, or /fork <entry-id> to fork)' + $script:Gm.Reset)
                    }
                }
                continue
            }
            if ($trimmedQ -match '^/(?:fork|clone)(?:\s+(.+))?$') {
                $forkEntryId = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                try {
                    $forkRes = Invoke-SessionFork -State $state -SessionDir $sessionDir -EntryId $forkEntryId
                    $state = $forkRes.state
                    $sessionFile = if ($NoSession) { '' } else { $forkRes.session_file }
                    $undoStack = @()
                    Write-Host ($script:Gm.Green + "  Forked session to: $($forkRes.session_file) (id=$($forkRes.session_id))" + $script:Gm.Reset)
                }
                catch {
                    Write-Host ($script:Gm.Red + '  Fork failed: ' + $_.Exception.Message + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/(?:export|share)(?:\s+(.+))?$') {
                $expArg = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                try {
                    if (-not $expArg) {
                        $baseName = if ($state.session_id) { [string]$state.session_id } else { 'session-export' }
                        $expArg = Join-Path $rootPath ($baseName + '.html')
                    }
                    elseif ($expArg -notmatch '^([a-zA-Z]:[\\/]|[\\/])') {
                        $expArg = Join-Path $rootPath $expArg
                    }
                    if ($expArg -match '\.jsonl$') {
                        Save-AgentSession -SessionFile $expArg -State $state -Workspace $rootPath -Model $Model
                        Write-Host ($script:Gm.Green + "  Exported session JSONL: $expArg" + $script:Gm.Reset)
                    }
                    else {
                        if ($expArg -notmatch '\.html?$') { $expArg += '.html' }
                        $outHtml = Export-AgentSessionHtml -State $state -OutputPath $expArg
                        Write-Host ($script:Gm.Green + "  Exported session HTML: $outHtml" + $script:Gm.Reset)
                    }
                }
                catch {
                    Write-Host ($script:Gm.Red + '  Export failed: ' + $_.Exception.Message + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/import(?:\s+(.+))?$') {
                if (-not $Matches[1]) {
                    Write-Host ($script:Gm.Red + '  Usage: /import <path-to-session.jsonl>' + $script:Gm.Reset)
                    continue
                }
                $impArg = $Matches[1].Trim()
                $impPath = if (Test-Path -LiteralPath $impArg) { $impArg } else { Join-Path $rootPath $impArg }
                if (-not (Test-Path -LiteralPath $impPath)) {
                    Write-Host ($script:Gm.Red + "  File not found: $impArg" + $script:Gm.Reset)
                    continue
                }
                try {
                    Invoke-SessionResume -SessionFile $impPath -State $state -CurrentWorkspace $rootPath | Out-Null
                    $sessionFile = if ($NoSession) { '' } else { $impPath }
                    $undoStack = @()
                    $lastFailedQuestion = ''
                    if ($state.model) { $Model = $state.model }
                    Write-Host ($script:Gm.Green + "  Imported session: $impPath ($($state.messages.Count) messages)" + $script:Gm.Reset)
                }
                catch {
                    Write-Host ($script:Gm.Red + '  Import failed: ' + $_.Exception.Message + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -eq '/copy') {
                $lastAssistant = $null
                for ($i = $state.messages.Count - 1; $i -ge 0; $i--) {
                    if ($state.messages[$i].role -eq 'assistant' -and $state.messages[$i].content) {
                        $lastAssistant = [string]$state.messages[$i].content
                        break
                    }
                }
                if (-not $lastAssistant) {
                    Write-Host ($script:Gm.Grey1 + '  No assistant message to copy.' + $script:Gm.Reset)
                }
                else {
                    try {
                        Set-Clipboard -Value $lastAssistant -ErrorAction Stop
                        Write-Host ($script:Gm.Green + "  Copied last assistant response ($($lastAssistant.Length) chars) to clipboard." + $script:Gm.Reset)
                    }
                    catch {
                        Write-Host ($script:Gm.Red + '  Clipboard copy failed: ' + $_.Exception.Message + $script:Gm.Reset)
                    }
                }
                continue
            }
            if ($trimmedQ -eq '/reload') {
                $fullSystemPrompt = Build-SystemPrompt -Root $rootPath -ConfigDir $configDir
                $system.content = $fullSystemPrompt
                if ($state.messages.Count -gt 0 -and $state.messages[0].role -eq 'system') {
                    $state.messages[0].content = $fullSystemPrompt
                }
                Sync-AgentCapabilities -State $state | Out-Null
                Write-Host ($script:Gm.Green + '  Reloaded AGENTS.md/CLAUDE.md, SYSTEM.md, skills catalog, and prompt templates.' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -match '^/save(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $nameArg = $Matches[1].Trim()
                    if ($nameArg -notmatch '\.jsonl$') { $nameArg += '.jsonl' }
                    $sessionFile = Join-Path $sessionDir (Split-Path $nameArg -Leaf)
                }
                Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                Write-Host ($script:Gm.Green + "  Saved session: $sessionFile" + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/undo') {
                if ($undoStack.Count -eq 0) {
                    Write-Host ($script:Gm.Grey1 + '  Nothing to undo.' + $script:Gm.Reset)
                    continue
                }
                $lastUndo = $undoStack[$undoStack.Count - 1]
                try {
                    Invoke-AgentUndo -State $state -UndoEntry $lastUndo
                    if ($undoStack.Count -eq 1) { $undoStack = @() }
                    else { $undoStack = @($undoStack[0..($undoStack.Count - 2)]) }
                    Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                    Write-Host ($script:Gm.Green + '  Reverted last turn and restored disk state.' + $script:Gm.Reset)
                }
                catch {
                    Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -eq '/status' -or $trimmedQ -eq '/tokens' -or $trimmedQ -eq '/session') {
                $st = Get-ContextStats -State $state
                $inTok = if ($state.usage_input_tokens) { [int]$state.usage_input_tokens } else { 0 }
                $outTok = if ($state.usage_output_tokens) { [int]$state.usage_output_tokens } else { 0 }
                $nmInfo = if ($state.session_name) { " | Name: $($state.session_name)" } else { '' }
                $leafInfo = if ($state.leaf_id) { " | Leaf: $($state.leaf_id)" } else { '' }
                Write-Host ($script:Gm.Aqua + "  Model: $($Model) | Permission: $($script:AgentPermission) | MaxSteps: $($MaxSteps) | Messages: $($st.messages) | Chars: $($st.chars) (~$($st.est_tokens) tokens)" + $script:Gm.Reset)
                Write-Host ($script:Gm.Grey1 + "  Session ID: $($state.session_id)$nmInfo$leafInfo | API Usage: in=$inTok out=$outTok" + $script:Gm.Reset)
                Write-Host ($script:Gm.Grey1 + "  Session File: $(if ($sessionFile) { $sessionFile } else { '(ephemeral -NoSession)' })" + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -match '^/model(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $Model = $Matches[1].Trim()
                    $state.model = $Model
                    Write-Host ($script:Gm.Green + "  Model switched to: $Model" + $script:Gm.Reset)
                }
                else {
                    Write-Host ($script:Gm.Aqua + "  Current model: $Model (use /model <id> to change)" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/compact(?:\s+(.+))?$') {
                $focus = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                try {
                    if (Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Focus $focus) {
                        Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                        $st = Get-ContextStats -State $state
                        Write-Host ($script:Gm.Green + "  Context compacted (~$($st.est_tokens) tokens remaining)." + $script:Gm.Reset)
                    }
                    else {
                        Write-Host ($script:Gm.Grey1 + '  Not enough history to compact yet.' + $script:Gm.Reset)
                    }
                }
                catch {
                    Write-Host ($script:Gm.Red + '  Compaction failed: ' + (Format-AgentError -ErrorRecord $_) + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -eq '/sessions') {
                if (-not (Test-Path -LiteralPath $sessionDir)) {
                    Write-Host ($script:Gm.Grey1 + '  No saved sessions yet.' + $script:Gm.Reset)
                    continue
                }
                $wsNorm = $rootPath.TrimEnd('\').TrimEnd('/')
                $list = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending | Where-Object {
                    $m = Get-AgentSessionMeta -SessionFile $_.FullName
                    (-not $m) -or (-not $m.workspace) -or ($m.workspace.TrimEnd('\').TrimEnd('/') -ieq $wsNorm)
                } | Select-Object -First 15)
                if ($list.Count -eq 0) {
                    Write-Host ($script:Gm.Grey1 + '  No saved sessions for this workspace.' + $script:Gm.Reset)
                    continue
                }
                for ($i = 0; $i -lt $list.Count; $i++) {
                    $meta = Get-AgentSessionMeta -SessionFile $list[$i].FullName
                    $mdlInfo = if ($meta -and $meta.model) { " [model: $($meta.model)]" } else { '' }
                    Write-Host ($script:Gm.Yellow + ("  [{0}] " -f ($i + 1)) + $script:Gm.Fg + $list[$i].Name + $script:Gm.Grey1 + (" ({0}){1}" -f $list[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $mdlInfo) + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/resume(?:\s+(.+))?$') {
                $arg = if ($Matches[1]) { $Matches[1].Trim() } else { '1' }
                if (-not (Test-Path -LiteralPath $sessionDir)) {
                    Write-Host ($script:Gm.Grey1 + '  No saved sessions found.' + $script:Gm.Reset)
                    continue
                }
                $wsNorm = $rootPath.TrimEnd('\').TrimEnd('/')
                $list = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending | Where-Object {
                    $m = Get-AgentSessionMeta -SessionFile $_.FullName
                    (-not $m) -or (-not $m.workspace) -or ($m.workspace.TrimEnd('\').TrimEnd('/') -ieq $wsNorm)
                })
                $chosen = $null
                if ($arg -match '^\d+$') {
                    $idx = [int]$arg - 1
                    if ($idx -ge 0 -and $idx -lt $list.Count) { $chosen = $list[$idx].FullName }
                }
                else {
                    $cand = Join-Path $sessionDir (Split-Path $arg -Leaf)
                    if (Test-Path -LiteralPath $cand) { $chosen = $cand }
                    elseif (-not ($arg -match '\.jsonl$')) {
                        $candJsonl = Join-Path $sessionDir ((Split-Path $arg -Leaf) + '.jsonl')
                        if (Test-Path -LiteralPath $candJsonl) { $chosen = $candJsonl }
                    }
                }
                if ($chosen) {
                    try {
                        Invoke-SessionResume -SessionFile $chosen -State $state -CurrentWorkspace $rootPath | Out-Null
                        $sessionFile = $chosen
                        $undoStack = @()
                        $lastFailedQuestion = ''
                        if ($state.model) { $Model = $state.model }
                        if ($PSBoundParameters.Keys -notcontains 'Permission') { $script:AgentPermission = 'Ask' }
                        Sync-AgentCapabilities -State $state | Out-Null
                        Write-Host ($script:Gm.Green + "  Resumed session: $sessionFile ($($state.messages.Count) messages, model=$Model, permission=$($script:AgentPermission))" + $script:Gm.Reset)
                    }
                    catch {
                        Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
                    }
                }
                else {
                    Write-Host ($script:Gm.Red + "  Session not found: $arg" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/continue(?:\s+(.+))?$') {
                $contSteps = $MaxSteps
                if ($Matches[1]) {
                    $rawSteps = $Matches[1].Trim()
                    if ($rawSteps -notmatch '^\d+$') {
                        Write-Host ($script:Gm.Red + '  Usage: /continue [steps]' + $script:Gm.Reset)
                        continue
                    }
                    $contSteps = [int]$rawSteps
                    if ($contSteps -lt 1 -or $contSteps -gt 500) {
                        Write-Host ($script:Gm.Red + '  Steps must be between 1 and 500.' + $script:Gm.Reset)
                        continue
                    }
                }
                $nonSys = @($state.messages | Where-Object { $_.role -ne 'system' })
                if ($nonSys.Count -eq 0) {
                    Write-Host ($script:Gm.Grey1 + '  Nothing to continue.' + $script:Gm.Reset)
                    continue
                }
                $beforeTurn = @($state.messages)
                $script:CurrentTurnWrites = @()
                $stBefore = Get-ContextStats -State $state
                if ($stBefore.chars -gt 60000) {
                    Write-Host ($script:Gm.Yellow + '  [auto-compact] Context exceeds 60k chars, compacting older history...' + $script:Gm.Reset)
                    try { Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey | Out-Null } catch {}
                }
                Write-Host ($script:Gm.Aqua + "  [continue] Continuing agent turn (up to $contSteps steps)..." + $script:Gm.Reset)
                try {
                    Invoke-AgentContinue -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $contSteps | Out-Null
                    $lastFailedQuestion = ''
                    $undoStack += @{ messages = $beforeTurn; writes = @($script:CurrentTurnWrites) }
                    Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                }
                catch {
                    $state.messages = $beforeTurn
                    try {
                        Invoke-AgentUndo -State $state -UndoEntry @{ messages = $beforeTurn; writes = @($script:CurrentTurnWrites) }
                    }
                    catch {
                        Write-Host ($script:Gm.Red + 'Rollback warning: ' + $_.Exception.Message + $script:Gm.Reset)
                    }
                    Write-Host ($script:Gm.Red + 'Continue failed; turn rolled back: ' + (Format-AgentError -ErrorRecord $_) + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -eq '/retry') {
                if (-not $lastFailedQuestion) {
                    Write-Host ($script:Gm.Grey1 + '  No failed request to retry.' + $script:Gm.Reset)
                    continue
                }
                $question = $lastFailedQuestion
                $trimmedQ = $question.Trim()
                Write-Host ($script:Gm.Aqua + '  [retry] Resending last failed prompt...' + $script:Gm.Reset)
            }
            elseif ($trimmedQ.StartsWith('/')) {
                $tplText = Resolve-PromptTemplate -Root $rootPath -ConfigDir $configDir -InputText $trimmedQ
                if ($null -eq $tplText) {
                    Write-Host ($script:Gm.Red + "  Unknown command or prompt template: $trimmedQ (use /help)" + $script:Gm.Reset)
                    continue
                }
                Write-Host ($script:Gm.Aqua + "  [template] Expanded $trimmedQ" + $script:Gm.Reset)
                $question = $tplText
            }
            if ($trimmedQ.StartsWith('!')) {
                $localOnly = $trimmedQ.StartsWith('!!')
                $cmdStr = if ($localOnly) { $trimmedQ.Substring(2).Trim() } else { $trimmedQ.Substring(1).Trim() }
                if (-not $cmdStr) { continue }
                try {
                    $res = Invoke-ShellCommand -Root $rootPath -Command $cmdStr
                    if ($res.output) { Write-Host ($script:Gm.Fg + $res.output + $script:Gm.Reset) }
                    Write-Host ($script:Gm.Grey1 + "  [exit $($res.exit_code)]" + $script:Gm.Reset)
                    if (-not $localOnly) {
                        $state.messages += @{ role = 'user'; content = ("[Shell command `$cmdStr` exit=$($res.exit_code)]`n" + $res.output) }
                        Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                        Write-Host ($script:Gm.Aqua + '  (Output added to conversation context)' + $script:Gm.Reset)
                    }
                }
                catch {
                    Write-Host ($script:Gm.Red + '  Command error: ' + $_.Exception.Message + $script:Gm.Reset)
                }
                continue
            }
            $beforeTurn = @($state.messages)
            $script:CurrentTurnWrites = @()
            $stBefore = Get-ContextStats -State $state
            if ($stBefore.chars -gt 60000) {
                Write-Host ($script:Gm.Yellow + '  [auto-compact] Context exceeds 60k chars, compacting older history...' + $script:Gm.Reset)
                try { Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey | Out-Null } catch {}
            }
            $expandedQuestion = Expand-UserPrompt -Root $rootPath -Prompt $question
            $state.messages += @{ role = 'user'; content = $expandedQuestion }
            try {
                Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
                $lastFailedQuestion = ''
                $undoStack += @{ messages = $beforeTurn; writes = @($script:CurrentTurnWrites) }
                Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
            }
            catch {
                $lastFailedQuestion = $question
                $state.messages = $beforeTurn
                try {
                    Invoke-AgentUndo -State $state -UndoEntry @{ messages = $beforeTurn; writes = @($script:CurrentTurnWrites) }
                }
                catch {
                    Write-Host ($script:Gm.Red + 'Rollback warning: ' + $_.Exception.Message + $script:Gm.Reset)
                }
                Write-Host ($script:Gm.Red + 'Request failed; turn rolled back (use /retry to resend): ' + (Format-AgentError -ErrorRecord $_) + $script:Gm.Reset)
            }
        }
    }
    finally { Remove-Variable agentKey -ErrorAction SilentlyContinue }
}
