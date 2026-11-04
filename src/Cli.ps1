# Agent turn loop (HTTP retries, finish_reason check, overflow auto-compaction, tool dispatch, JSON event stream) and interactive CLI REPL.

function ConvertTo-AsciiJson {
    param([string]$Json)
    if (-not $Json -or ($Json -notmatch '[^\x00-\x7F]')) { return $Json }
    $parts = @($Json -split '([^\x00-\x7F]+)')
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $escaped = foreach ($ch in [char[]]$parts[$i]) {
            '\u{0:x4}' -f [int][char]$ch
        }
        $parts[$i] = ($escaped -join '')
    }
    return ($parts -join '')
}

function Write-AgentJsonEvent {
    param([string]$EventType, [hashtable]$Payload = @{})
    if ($script:OutputMode -ne 'json') { return }
    $ev = @{
        type = $EventType
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    }
    foreach ($k in $Payload.Keys) { $ev[$k] = $Payload[$k] }
    Write-Host (ConvertTo-AsciiJson -Json ($ev | ConvertTo-Json -Depth 20 -Compress))
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
    $asciiBody = ConvertTo-AsciiJson -Json $Body
    $iwrCmd = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ((-not $ForceBackgroundWorker) -and (($iwrCmd -and $iwrCmd.CommandType -eq 'Function') -or $script:DisableAsyncHttp)) {
        $request = @{
            Uri = $Uri
            Method = 'Post'
            Headers = @{ Authorization = "Bearer $ApiKey" }
            ContentType = 'application/json; charset=utf-8'
            Body = $asciiBody
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
        Set-Content -LiteralPath $reqTemp.FullName -Value $asciiBody -Encoding Ascii -NoNewline -ErrorAction Stop
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
    for ($step = 0; $step -lt $Steps; $step++) {
        if ($step -gt 0) {
            $stStep = Get-ContextStats -State $State
            if ($stStep.est_tokens -gt $stStep.compact_threshold_tokens) {
                if ($script:OutputMode -ne 'json') {
                    $limStr = Format-TokenCount -Tokens $stStep.compact_threshold_tokens
                    Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
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
                if ($m.tool_calls) { $curChars += (($m.tool_calls | ConvertTo-Json -Depth 10 -Compress)).Length }
            }
            $State.last_prompt_chars = $curChars
        }
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
            elseif ($canonToolName -eq 'run_agent') {
                try {
                    $parsedOut = $output | ConvertFrom-Json -ErrorAction Stop
                    if ($parsedOut.modified_files -and @($parsedOut.modified_files).Count -gt 0) {
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

function Resolve-ReplCommandAlias {
    param([string]$InputText)
    if (-not $InputText) { return '' }
    $t = $InputText.Trim()
    if ($t -eq '?' -or $t -eq '/?' -or $t -eq '/h') { return '/help' }
    if ($t -eq '/q') { return '/exit' }
    if ($t -eq '/u') { return '/undo' }
    if ($t -eq '/s') { return '/status' }
    if ($t -match '^/(?:p|perm)(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/permission ' + $Matches[1] } else { '/permission' })
    }
    if ($t -match '^/m(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/model ' + $Matches[1] } else { '/model' })
    }
    if ($t -match '^/c(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/compact ' + $Matches[1] } else { '/compact' })
    }
    if ($t -match '^/t(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/tree ' + $Matches[1] } else { '/tree' })
    }
    if ($t -match '^/r(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/resume ' + $Matches[1] } else { '/resume' })
    }
    if ($t -match '^/ctx(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/context ' + $Matches[1] } else { '/context' })
    }
    if ($t -match '^/td(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/todo ' + $Matches[1] } else { '/todo' })
    }
    if ($t -match '^/mem(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/memory ' + $Matches[1] } else { '/memory' })
    }
    return $t
}

function Format-TuiStatusCard {
    param($State, [string]$Model, [int]$MaxSteps = 50, [string]$SessionFile = '', [int]$UndoCount = 0)
    $w = Get-TerminalWidth
    $st = Get-ContextStats -State $State
    $inTok = if ($State -and $State.usage_input_tokens) { [int]$State.usage_input_tokens } else { 0 }
    $outTok = if ($State -and $State.usage_output_tokens) { [int]$State.usage_output_tokens } else { 0 }
    $nmInfo = if ($State -and $State.session_name) { [string]$State.session_name } else { '(unnamed)' }
    $leafInfo = if ($State -and $State.leaf_id) { [string]$State.leaf_id } else { '(root)' }
    $sessFileStr = if ($SessionFile) { $SessionFile } else { '(ephemeral -NoSession)' }
    $effLabel = if ($script:ReasoningEffort) { $script:ReasoningEffort } else { 'default' }
    $capNow = Get-AgentCapabilities -Root $script:ActiveWorkspace
    $toolsStr = if ($capNow.tool_names.Count -gt 0) { $capNow.tool_names -join ', ' } else { 'none' }
    $compLabel = (Format-TokenCount -Tokens $st.compact_threshold_tokens) + " ($($st.compact_pct)%)"
    $hdr = ' ' + $script:Gm.BoldOrange + 'Session Status' + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $barV = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Reset
    $lines = @(
        ('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'Model:       ' + $script:Gm.Fg1 + $Model + $script:Gm.Grey1 + " (reasoning: view=$($script:ShowReasoning), effort=$effLabel)" + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'Permission:  ' + (Format-PermissionBadge -Permission $script:AgentPermission) + $script:Gm.Grey1 + " | MaxSteps: $MaxSteps | Undo stack: $UndoCount" + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'Context:     ' + (Format-ContextGauge -Tokens $st.est_tokens -MaxTokens $st.context_window_tokens -CompactTokens $st.compact_threshold_tokens -Width 12) + $script:Gm.Grey1 + " | Auto-compact: $compLabel | Msgs: $($st.messages)" + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'API Tokens:  ' + $script:Gm.Aqua + "in=$inTok out=$outTok" + $script:Gm.Grey1 + " (total=$(Format-TokenCount -Tokens ($inTok + $outTok)))" + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'Session:     ' + $script:Gm.Fg + "$($State.session_id) " + $script:Gm.Grey1 + "| Name: $nmInfo | Leaf: $leafInfo" + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'File:        ' + $script:Gm.Grey2 + $sessFileStr + $script:Gm.Reset),
        ($barV + $script:Gm.Grey1 + 'Tools:       ' + $script:Gm.Aqua + $toolsStr + $script:Gm.Reset)
    )
    $tdList = if ($script:ActiveSessionTodos -and $script:ActiveSessionTodos.Count -gt 0) { $script:ActiveSessionTodos } elseif ($State -and $State.todos -and $State.todos.Count -gt 0) { $State.todos } else { @() }
    if ($tdList.Count -gt 0) {
        $tDone = @($tdList | Where-Object { $_.status -eq 'completed' }).Count
        $tTot = $tdList.Count
        $lines += ($barV + $script:Gm.Grey1 + 'Tasks (Todo): ' + $script:Gm.BoldAqua + "$tDone/$tTot completed" + $script:Gm.Reset)
    }
    $lines += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
    return $lines
}

function Format-TuiTreeCard {
    param($State)
    $w = Get-TerminalWidth
    $treeNodes = @(Get-SessionTree -State $State)
    $hdr = ' ' + $script:Gm.BoldOrange + 'Conversation Tree' + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $barV = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Reset
    $out = @('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    if ($treeNodes.Count -eq 0) {
        $out += ($barV + $script:Gm.Grey1 + 'Session tree is empty.' + $script:Gm.Reset)
    }
    else {
        foreach ($node in $treeNodes) {
            $marker = if ($node.is_leaf) { $script:Box.Dot } elseif ($node.active) { $script:Box.Arrow } else { '-' }
            $parentInfo = if ($node.parent_id) { " <- $($node.parent_id)" } else { ' (root)' }
            $color = if ($node.is_leaf) { $script:Gm.BoldGreen } elseif ($node.active) { $script:Gm.Aqua } else { $script:Gm.Grey1 }
            $out += ($barV + $color + ("{0} [{1}] ({2}{3}) " -f $marker, $node.id, $node.role, $parentInfo) + $script:Gm.Fg + $node.preview + $script:Gm.Reset)
        }
        $out += ($barV + $script:Gm.Grey1 + '(Use /tree <entry-id> to switch branch, or /fork <entry-id> to fork)' + $script:Gm.Reset)
    }
    $out += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
    return $out
}

function Write-TuiHelpCard {
    if ($script:OutputMode -eq 'json') { return }
    $w = Get-TerminalWidth
    $hdr = ' ' + $script:Gm.BoldOrange + 'Shellossus TUI Commands & Shortcuts' + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $barV = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Reset
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.BoldYellow + 'Mode & Model (call without args for interactive picker)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /permission (/p) [mode]      ' + $script:Gm.Fg + 'Pick or set: ReadOnly | Ask | AutoEdit | Auto' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /model (/m) [id]             ' + $script:Gm.Fg + 'Pick or switch active model ID' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /context (/ctx) [win] [comp] ' + $script:Gm.Fg + 'Pick or set context window & auto-compact threshold (default 128k / 96k)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /reasoning [arg]             ' + $script:Gm.Fg + 'Pick view (compact|full|hide) or effort (low|medium|high|off)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /status (/s, /tokens)        ' + $script:Gm.Fg + 'Show TUI dashboard (context gauge, tokens, tools, session)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /diagnostics [on|off]        ' + $script:Gm.Fg + 'Toggle pre-request capability/tool diagnostics' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /doctor                      ' + $script:Gm.Fg + 'Check runtime, configuration, endpoint, model, and session storage' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /mascot                      ' + $script:Gm.Fg + 'Display the Shellossus pixel mascot' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.BoldYellow + 'History, Undo & Compaction' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /todo (/td) [clear]          ' + $script:Gm.Fg + 'View or clear active task plan checklist' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /memory (/mem) [clear|add ..]' + $script:Gm.Fg + 'View, clear, or add persistent project memory' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /undo (/u)                   ' + $script:Gm.Fg + 'Revert last tracked turn and its write_file/edit_file changes' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /retry                       ' + $script:Gm.Fg + 'Retry the last failed user request' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /continue [steps]            ' + $script:Gm.Fg + 'Continue after hitting step limit (or continue last response)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /compact (/c) [focus]        ' + $script:Gm.Fg + 'Summarize older turns into a structured context handoff' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /copy                        ' + $script:Gm.Fg + 'Copy the last assistant response to clipboard' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.BoldYellow + 'Sessions & Branch Tree' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /sessions                    ' + $script:Gm.Fg + 'Browse and interactively resume saved workspace sessions' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /resume (/r) [num|name]      ' + $script:Gm.Fg + 'Resume a saved session (interactive picker when no arg)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /tree (/t) [entry-id]        ' + $script:Gm.Fg + 'View conversation tree or switch active branch' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /fork [entry-id] (/clone)    ' + $script:Gm.Fg + 'Fork current branch into a new session file' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /name [name] | /save [name]  ' + $script:Gm.Fg + 'Name or save current session' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /export [path] | /import <p> ' + $script:Gm.Fg + 'Export HTML/JSONL or import a JSONL session' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /new (/clear) | /exit (/q)   ' + $script:Gm.Fg + 'Start a fresh session or exit shellossus' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.BoldYellow + 'Delegation, Skills & Input Syntax' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /agents | /agent:<role> <q>  ' + $script:Gm.Fg + 'List or run subagent roles (recon, audit, craft, custom)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /skills | /skill:<name> [a]  ' + $script:Gm.Fg + 'List or invoke a SKILL.md skill directly' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  /<template> [args] | /reload ' + $script:Gm.Fg + 'Run .shellossus/prompts/<name>.md or reload context files' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  @path/to/file                ' + $script:Gm.Fg + 'Inline-attach a workspace file into your prompt' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  !cmd / !!cmd                 ' + $script:Gm.Fg + 'Run shell command (! adds to context, !! local only)' + $script:Gm.Reset)
    Write-Host ($barV + $script:Gm.Aqua + '  """ ... """ or trailing \    ' + $script:Gm.Fg + 'Multi-line prompt input block' + $script:Gm.Reset)
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
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
    $config = @{}
    $script:AgentConfigPath = $ConfigPath
    $doctorConfigState = 'loaded'
    try {
        $script:AgentConfigPath = Format-ConfigPath -Path $ConfigPath
        $resolvedCfg = Resolve-AgentConfigPath -Path $ConfigPath
        $script:LegacyAgentConfigPath = if ($resolvedCfg -and ($resolvedCfg -ne $ConfigPath)) { Format-ConfigPath -Path $resolvedCfg } else { '' }
        if (-not (Test-Path -LiteralPath $resolvedCfg)) { $doctorConfigState = 'missing' }
        $config = Read-AgentConfig -Path $ConfigPath
    }
    catch {
        if (-not $Doctor) { throw }
        $doctorConfigState = 'invalid'
    }
    if ($Setup -and -not $Doctor) {
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
        Write-Host ($script:Gm.BoldGreen + 'Settings saved. Run shellossus -Doctor to check them, then start shellossus from your working folder.' + $script:Gm.Reset)
        return
    }
    if ($Mascot) {
        Write-TuiMascotCard -Mode 'full'
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
    try {
        $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
        if (-not $configDir) { $configDir = '.' }
        $sessionDir = if ($SessionDir) { $SessionDir } else { Join-Path $configDir 'sessions' }
    }
    catch {
        if (-not $Doctor) { throw }
        $doctorConfigState = 'invalid'
        $sessionDir = $SessionDir
    }
    if ($Doctor) {
        $doctorKey = $env:SHELLOSSUS_API_KEY
        if (-not $doctorKey) { $doctorKey = $env:H_AGENT_API_KEY }
        if (-not $doctorKey) { $doctorKey = $config.SHELLOSSUS_API_KEY }
        try {
            $report = Get-AgentDoctorReport -BaseUrl $BaseUrl -ModelId $Model -ApiKey $doctorKey -Workspace $Workspace -SessionDir $sessionDir -NoSession:$NoSession -ConfigState $doctorConfigState
            Write-AgentDoctorReport -Report $report -Mode $Mode
        }
        finally { Remove-Variable doctorKey -ErrorAction SilentlyContinue; $config.Clear() }
        exit $report.exit_code
    }
    $rootItem = Get-Item -LiteralPath $Workspace -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Workspace must be a directory.' }
    $rootPath = Resolve-AgentPath -Root $rootItem.FullName -RelativePath '.'
    $script:ActiveWorkspace = $rootPath
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
    if (-not $ContextWindow -and $config.SHELLOSSUS_CONTEXT_WINDOW) { $ContextWindow = $config.SHELLOSSUS_CONTEXT_WINDOW }
    if (-not $CompactThreshold -and $config.SHELLOSSUS_COMPACT_THRESHOLD) { $CompactThreshold = $config.SHELLOSSUS_COMPACT_THRESHOLD }
    if ($ContextWindow -or $CompactThreshold) {
        $null = Set-AgentContextLimits -WindowSpec $ContextWindow -CompactSpec $CompactThreshold
    }
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
        $wInit = Get-TerminalWidth
        $hdrInit = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' shellossus ' + $script:Gm.Grey1 + 'inline TUI' + $script:Gm.Reset + ' '
        $hdrInitVis = (Strip-AnsiCodes -Text $hdrInit).Length
        $initDashes = $wInit - 3 - $hdrInitVis
        if ($initDashes -lt 2) { $initDashes = 2 }
        Write-Host ($script:Gm.OscInit + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdrInit + $script:Gm.Grey0 + ($script:Box.H * $initDashes) + $script:Box.TR + $script:Gm.Reset)
        $ctxLoaded = @()
        if (Get-SoulContext -Root $rootPath -ConfigDir $configDir) { $ctxLoaded += 'SOUL.md' }
        if (Get-MemoryContext -Root $rootPath -ConfigDir $configDir) { $ctxLoaded += 'MEMORY.md' }
        if (Get-AgentsContext -Root $rootPath -ConfigDir $configDir) { $ctxLoaded += 'AGENTS.md/CLAUDE.md' }
        if (Get-SkillsCatalog -Root $rootPath -ConfigDir $configDir) { $ctxLoaded += "skills ($($script:SkillsByName.Count))" }
        $null = Get-AgentRolesCatalog -Root $rootPath -ConfigDir $configDir
        if ($script:AgentRolesByName -and $script:AgentRolesByName.Count -gt 0) { $ctxLoaded += "agents ($($script:AgentRolesByName.Count))" }
        $loadedStr = if ($ctxLoaded.Count -gt 0) { $script:Gm.Aqua + 'Loaded: ' + $script:Gm.Fg + ($ctxLoaded -join ' | ') + $script:Gm.Reset } else { $script:Gm.Grey1 + 'Workspace ready' + $script:Gm.Reset }
        $modelStr = $script:Gm.Aqua + 'Model: ' + $script:Gm.Fg + $Model + $script:Gm.Grey1 + ' | ' + $script:Gm.Aqua + 'Mode: ' + $script:Gm.Fg + $script:AgentPermission + $script:Gm.Reset
        $shortcutsStr = $script:Gm.Grey1 + 'Shortcuts: ' + $script:Gm.Aqua + '? (/help)' + $script:Gm.Grey1 + ' | ' + $script:Gm.Aqua + '/p' + $script:Gm.Grey1 + ' mode | ' + $script:Gm.Aqua + '/m' + $script:Gm.Grey1 + ' model | ' + $script:Gm.Aqua + '/s' + $script:Gm.Grey1 + ' status | ' + $script:Gm.Aqua + '/u' + $script:Gm.Grey1 + ' undo' + $script:Gm.Reset
        $footerStr = $script:Gm.Grey1 + 'Zero dependencies - 100% ConstrainedLanguage' + $script:Gm.Reset
        $textLines = @($loadedStr, $modelStr, $shortcutsStr, $footerStr, '')

        $mascot = @(Get-TuiMascotLines -Mode 'compact')
        if ($wInit -ge 76) {
            for ($mIdx = 0; $mIdx -lt 5; $mIdx++) {
                $mLine = $mascot[$mIdx]
                $tLine = $textLines[$mIdx]
                $contentVis = 14 + 3 + (Strip-AnsiCodes -Text $tLine).Length
                $padLen = $wInit - 6 - $contentVis
                if ($padLen -lt 0) { $padLen = 0 }
                $pad = ' ' * $padLen
                Write-Host ($script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Reset + '  ' + $mLine + '   ' + $tLine + $pad)
            }
        }
        else {
            if ($ctxLoaded.Count -gt 0) {
                Write-Host ($script:Gm.Grey0 + $script:Box.V + ' ' + $loadedStr)
            }
            Write-Host ($script:Gm.Grey0 + $script:Box.V + ' ' + $shortcutsStr)
        }
        Write-Host ($script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($wInit - 2)) + $script:Box.BR + $script:Gm.Reset)
        while ($true) {
            Write-TuiPromptFrame -State $state -Root $rootPath -Model $Model -UndoCount $undoStack.Count
            Write-Host ('  ' + $script:Gm.BoldBlue + $script:Box.Arrow + ' You: ' + $script:Gm.Fg) -NoNewline
            $question = Read-TuiMultilineInput
            Write-Host $script:Gm.Reset -NoNewline
            if (-not $question) { continue }
            $rawTrimmed = $question.Trim()
            $trimmedQ = Resolve-ReplCommandAlias -InputText $rawTrimmed
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
                $state.todos = @()
                $script:ActiveSessionTodos = @()
                Sync-AgentCapabilities -State $state | Out-Null
                $undoStack = @()
                $sessionFile = if ($NoSession) { '' } else { Join-Path $sessionDir ($newId + '.jsonl') }
                $script:ActiveSessionId = $newId
                $script:ActiveSessionFile = $sessionFile
                Write-Host ($script:Gm.Grey1 + '  Started a new conversation session.' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -match '^/(?:todo|todos)(?:\s+(.+))?$') {
                $sub = if ($Matches[1]) { $Matches[1].Trim().ToLower() } else { '' }
                if ($sub -eq 'clear') {
                    $script:ActiveSessionTodos = @()
                    if ($state) { $state.todos = @() }
                    Write-Host ($script:Gm.Grey1 + '  Cleared active todo list.' + $script:Gm.Reset)
                }
                else {
                    $currTodos = if ($script:ActiveSessionTodos -and $script:ActiveSessionTodos.Count -gt 0) { $script:ActiveSessionTodos } elseif ($state -and $state.todos -and $state.todos.Count -gt 0) { $state.todos } else { @() }
                    if ($currTodos.Count -gt 0) {
                        Write-TodoCard -Todos $currTodos
                    }
                    else {
                        Write-Host ($script:Gm.Grey1 + '  No active tasks in todo list.' + $script:Gm.Reset)
                    }
                }
                continue
            }
            if ($trimmedQ -match '^/(?:memory|mem)(?:\s+(.+))?$') {
                $memSub = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                if ($memSub -eq 'clear') {
                    $callArg = @{ action = 'clear'; scope = 'workspace' }
                    $null = Invoke-AgentMemory -Root $rootPath -Arguments $callArg
                    Write-Host ($script:Gm.Grey1 + '  Cleared workspace memory.' + $script:Gm.Reset)
                }
                elseif ($memSub -match '^add\s+(.+)$') {
                    $callArg = @{ action = 'append'; scope = 'workspace'; content = $Matches[1].Trim() }
                    $null = Invoke-AgentMemory -Root $rootPath -Arguments $callArg
                    Write-Host ($script:Gm.Green + '  Added memory entry.' + $script:Gm.Reset)
                }
                else {
                    $callArg = @{ action = 'view'; scope = 'workspace' }
                    $null = Invoke-AgentMemory -Root $rootPath -Arguments $callArg
                }
                continue
            }
            if ($trimmedQ -eq '/help') {
                Write-TuiHelpCard
                continue
            }
            if ($trimmedQ -eq '/doctor') {
                $doctorSessionDir = if ($sessionFile) { Split-Path $sessionFile -Parent } else { $sessionDir }
                $report = Get-AgentDoctorReport -BaseUrl $BaseUrl -ModelId $Model -ApiKey $agentKey -Workspace $rootPath -SessionDir $doctorSessionDir -NoSession:(-not $sessionFile) -ConfigState $doctorConfigState
                Write-AgentDoctorReport -Report $report -Mode $script:OutputMode
                continue
            }
            if ($trimmedQ -eq '/mascot') {
                Write-TuiMascotCard -Mode 'full'
                continue
            }
            if ($trimmedQ -eq '/agents') {
                $null = Get-AgentRolesCatalog -Root $rootPath -ConfigDir $configDir
                $w = Get-TerminalWidth
                $hdr = ' ' + $script:Gm.BoldOrange + 'Subagent Roles' + $script:Gm.Reset + ' '
                $dashes = $w - 5 - (Strip-AnsiCodes -Text $hdr).Length
                if ($dashes -lt 2) { $dashes = 2 }
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
                foreach ($rKey in @($script:AgentRolesByName.Keys | Sort-Object)) {
                    $rObj = $script:AgentRolesByName[$rKey]
                    $srcTag = if ($rObj.builtin) { 'built-in' } else { $rObj.rel_path }
                    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + ("{0,-12} " -f $rObj.name) + $script:Gm.Yellow + ("[{0}; {1}] " -f $rObj.permission, $srcTag) + $script:Gm.Fg + $rObj.description + $script:Gm.Reset)
                }
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + '(Invoke via /agent:<role> <task> or let the model call run_agent)' + $script:Gm.Reset)
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/skills') {
                $null = Get-SkillsCatalog -Root $rootPath -ConfigDir $configDir
                $w = Get-TerminalWidth
                $hdr = ' ' + $script:Gm.BoldOrange + 'Available Skills' + $script:Gm.Reset + ' '
                $dashes = $w - 5 - (Strip-AnsiCodes -Text $hdr).Length
                if ($dashes -lt 2) { $dashes = 2 }
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
                if (-not $script:SkillsByName -or $script:SkillsByName.Count -eq 0) {
                    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + 'No skills found in .shellossus/skills or ~/.shellossus/skills.' + $script:Gm.Reset)
                }
                else {
                    foreach ($sKey in @($script:SkillsByName.Keys | Sort-Object)) {
                        $sObj = $script:SkillsByName[$sKey]
                        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + ("{0,-18} " -f $sObj.name) + $script:Gm.Fg + $sObj.description + $script:Gm.Reset)
                    }
                    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + '(Invoke via /skill:<name> [args])' + $script:Gm.Reset)
                }
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/hotkeys') {
                Write-TuiHelpCard
                continue
            }
            if ($trimmedQ -match '^/permission(?:\s+(.+))?$') {
                $reqPerm = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                if (-not $reqPerm) {
                    $permItems = @(
                        @{ label = 'ReadOnly'; value = 'ReadOnly'; description = 'Read/search only; no file writes or shell commands'; active = ($script:AgentPermission -eq 'ReadOnly') },
                        @{ label = 'Ask'; value = 'Ask'; description = 'Preview and confirm both file writes (WRITE) and commands (RUN)'; active = ($script:AgentPermission -eq 'Ask') },
                        @{ label = 'AutoEdit'; value = 'AutoEdit'; description = 'Auto-approve file edits; still confirm shell commands (RUN)'; active = ($script:AgentPermission -eq 'AutoEdit') },
                        @{ label = 'Auto'; value = 'Auto'; description = 'Auto-approve all workspace file writes and shell commands'; active = ($script:AgentPermission -eq 'Auto') }
                    )
                    $pickedPerm = Invoke-TuiSelector -Title "Permission Mode (current: $($script:AgentPermission))" -Items $permItems
                    if ($pickedPerm) { $reqPerm = [string]$pickedPerm }
                }
                if ($reqPerm) {
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
                $argR = if ($Matches[1]) { $Matches[1].Trim().ToLower() } else { '' }
                if (-not $argR) {
                    $effLabel = if ($script:ReasoningEffort) { $script:ReasoningEffort } else { 'default' }
                    $rItems = @(
                        @{ label = 'compact'; value = 'compact'; description = 'Show last 3 lines of reasoning block'; active = ($script:ShowReasoning -eq 'compact') },
                        @{ label = 'full'; value = 'full'; description = 'Show full reasoning block'; active = ($script:ShowReasoning -eq 'full') },
                        @{ label = 'hide'; value = 'hide'; description = 'Hide reasoning display'; active = ($script:ShowReasoning -eq 'hide') },
                        @{ label = 'low'; value = 'low'; description = 'Set API reasoning_effort = low'; active = ($script:ReasoningEffort -eq 'low') },
                        @{ label = 'medium'; value = 'medium'; description = 'Set API reasoning_effort = medium'; active = ($script:ReasoningEffort -eq 'medium') },
                        @{ label = 'high'; value = 'high'; description = 'Set API reasoning_effort = high'; active = ($script:ReasoningEffort -eq 'high') },
                        @{ label = 'default'; value = 'default'; description = 'Reset API reasoning_effort to provider default'; active = (-not $script:ReasoningEffort) }
                    )
                    $pickedR = Invoke-TuiSelector -Title "Reasoning (view: $($script:ShowReasoning) | effort: $effLabel)" -Items $rItems
                    if ($pickedR) { $argR = ([string]$pickedR).ToLower() }
                }
                if ($argR) {
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
                    foreach ($tLn in @(Format-TuiTreeCard -State $state)) {
                        Write-Host $tLn
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
                Write-Host ($script:Gm.Green + '  Reloaded context files (AGENTS.md, SOUL.md, MEMORY.md, SYSTEM.md), skills, and templates.' + $script:Gm.Reset)
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
                foreach ($sLn in @(Format-TuiStatusCard -State $state -Model $Model -MaxSteps $MaxSteps -SessionFile $sessionFile -UndoCount $undoStack.Count)) {
                    Write-Host $sLn
                }
                continue
            }
            if ($trimmedQ -match '^/context(?:\s+(.+))?$') {
                $ctxArg = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                if (-not $ctxArg) {
                    $curSt = Get-ContextStats -State $state
                    $curWinFmt = Format-TokenCount -Tokens $curSt.context_window_tokens
                    $curCompFmt = Format-TokenCount -Tokens $curSt.compact_threshold_tokens
                    $ctxItems = @(
                        @{ label = '128k / 96k (75%)'; value = '128k 96k'; description = 'Default for 128k models (gpt-oss-120b, GPT-4o, DeepSeek, GLM)'; active = ($curSt.context_window_tokens -eq 128000 -and $curSt.compact_threshold_tokens -eq 96000) },
                        @{ label = '128k / 80k (62%)'; value = '128k 80k'; description = '128k window with earlier compaction for faster prefill & deep reasoning'; active = ($curSt.context_window_tokens -eq 128000 -and $curSt.compact_threshold_tokens -eq 80000) },
                        @{ label = '64k / 48k (75%)'; value = '64k 48k'; description = 'vLLM / corporate server with max_model_len=64k'; active = ($curSt.context_window_tokens -eq 64000 -and $curSt.compact_threshold_tokens -eq 48000) },
                        @{ label = '32k / 24k (75%)'; value = '32k 24k'; description = 'Compact deployment with max_model_len=32k'; active = ($curSt.context_window_tokens -eq 32000 -and $curSt.compact_threshold_tokens -eq 24000) },
                        @{ label = '200k / 150k (75%)'; value = '200k 150k'; description = 'Large context window (200k tokens)'; active = ($curSt.context_window_tokens -eq 200000 -and $curSt.compact_threshold_tokens -eq 150000) },
                        @{ label = '[Custom limits...]'; value = '__custom__'; description = 'Enter "<window> [compact]" e.g. "128k 85k" or "128k 70%"'; active = $false }
                    )
                    $pickedCtx = Invoke-TuiSelector -Title "Context Window & Auto-Compact (current: $curWinFmt / compact at $curCompFmt)" -Items $ctxItems -PromptText 'Select preset or type "<window> [compact]" (Enter cancels)'
                    if ($pickedCtx -eq '__custom__') {
                        Write-Host ('  ' + $script:Gm.BoldYellow + 'Enter "<window> [compact]" (e.g. 128k 80k or 128k 70%): ' + $script:Gm.Fg) -NoNewline
                        $customCtx = Read-Host
                        Write-Host $script:Gm.Reset -NoNewline
                        if ($customCtx -and $customCtx.Trim()) { $ctxArg = $customCtx.Trim() }
                    }
                    elseif ($pickedCtx) {
                        $ctxArg = [string]$pickedCtx
                    }
                }
                if ($ctxArg) {
                    try {
                        $tokensParts = @($ctxArg -split '\s+' | Where-Object { $_ })
                        $limRes = if ($tokensParts.Count -ge 2 -and ($tokensParts[0] -ieq 'compact' -or $tokensParts[0] -ieq 'threshold')) {
                            Set-AgentContextLimits -CompactSpec $tokensParts[1]
                        }
                        elseif ($tokensParts.Count -ge 2) {
                            Set-AgentContextLimits -WindowSpec $tokensParts[0] -CompactSpec $tokensParts[1]
                        }
                        else {
                            Set-AgentContextLimits -WindowSpec $tokensParts[0]
                        }
                        $wFmt = Format-TokenCount -Tokens $limRes.context_window_tokens
                        $cFmt = Format-TokenCount -Tokens $limRes.compact_threshold_tokens
                        Write-Host ($script:Gm.Green + "  Context window set to $wFmt tokens | Auto-compact threshold: $cFmt ($($limRes.compact_pct)%)" + $script:Gm.Reset)
                    }
                    catch {
                        Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
                    }
                }
                continue
            }
            if ($trimmedQ -match '^/model(?:\s+(.+))?$') {
                $newModel = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                if (-not $newModel) {
                    $knownModels = @($Model)
                    if (Test-Path -LiteralPath $sessionDir) {
                        foreach ($sf in @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15)) {
                            $mMeta = Get-AgentSessionMeta -SessionFile $sf.FullName
                            if ($mMeta -and $mMeta.model -and ($knownModels -notcontains [string]$mMeta.model)) {
                                $knownModels += [string]$mMeta.model
                            }
                        }
                    }
                    $mItems = @()
                    foreach ($km in $knownModels) {
                        $mItems += @{ label = $km; value = $km; description = $(if ($km -eq $Model) { 'active model' } else { 'recent session model' }); active = ($km -eq $Model) }
                    }
                    $mItems += @{ label = '[Custom model ID...]'; value = '__custom__'; description = 'Type any OpenAI-compatible model ID'; active = $false }
                    $pickedM = Invoke-TuiSelector -Title "Select Model (current: $Model)" -Items $mItems -PromptText 'Select number or type model ID (Enter cancels)'
                    if ($pickedM -eq '__custom__') {
                        Write-Host ('  ' + $script:Gm.BoldYellow + 'Enter model ID: ' + $script:Gm.Fg) -NoNewline
                        $customM = Read-Host
                        Write-Host $script:Gm.Reset -NoNewline
                        if ($customM -and $customM.Trim()) { $newModel = $customM.Trim() }
                    }
                    elseif ($pickedM) {
                        $newModel = [string]$pickedM
                    }
                }
                if ($newModel) {
                    $Model = $newModel
                    $state.model = $Model
                    $script:ActiveModelId = $Model
                    Write-Host ($script:Gm.Green + "  Model switched to: $Model" + $script:Gm.Reset)
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
            if ($trimmedQ -eq '/sessions' -or $trimmedQ -match '^/resume(?:\s+(.+))?$') {
                $isResumeCmd = ($trimmedQ -match '^/resume')
                $arg = if ($isResumeCmd -and $Matches[1]) { $Matches[1].Trim() } else { '' }
                if (-not (Test-Path -LiteralPath $sessionDir)) {
                    Write-Host ($script:Gm.Grey1 + '  No saved sessions found.' + $script:Gm.Reset)
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
                $chosen = $null
                if (-not $arg) {
                    $sItems = @()
                    for ($i = 0; $i -lt $list.Count; $i++) {
                        $meta = Get-AgentSessionMeta -SessionFile $list[$i].FullName
                        $mdlInfo = if ($meta -and $meta.model) { "model: $($meta.model)" } else { '' }
                        $nmTag = if ($meta -and $meta.session_name) { "[$($meta.session_name)] " } else { '' }
                        $desc = ("{0}{1} ({2})" -f $nmTag, $list[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $mdlInfo)
                        $sItems += @{
                            label = $list[$i].Name
                            value = $list[$i].FullName
                            description = $desc
                            active = ($sessionFile -and ($list[$i].FullName -ieq $sessionFile))
                        }
                    }
                    $pickedSess = Invoke-TuiSelector -Title 'Saved Workspace Sessions' -Items $sItems -PromptText 'Select session number to resume (Enter cancels)'
                    if ($pickedSess) { $chosen = [string]$pickedSess }
                }
                elseif ($arg -match '^\d+$') {
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
                elseif ($arg) {
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
                if ($stBefore.est_tokens -gt $stBefore.compact_threshold_tokens) {
                    $limStr = Format-TokenCount -Tokens $stBefore.compact_threshold_tokens
                    Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
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
            if ($stBefore.est_tokens -gt $stBefore.compact_threshold_tokens) {
                $limStr = Format-TokenCount -Tokens $stBefore.compact_threshold_tokens
                Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
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
