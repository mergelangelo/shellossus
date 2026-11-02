# Agent turn loop (HTTP retries, overflow auto-compaction, tool dispatch) and interactive CLI REPL.

function Invoke-AgentTurn {
    param($State, [string]$Endpoint, [string]$ModelId, [string]$ApiKey, [string]$Root, [int]$Steps)
    $overflowRetried = $false
    for ($step = 0; $step -lt $Steps; $step++) {
        $bodyObj = @{
            model = $ModelId
            messages = @($State.messages)
            tools = @(Get-AgentTools)
            stream = $false
        }
        if ($script:ReasoningEffort) { $bodyObj.reasoning_effort = $script:ReasoningEffort }
        $body = $bodyObj | ConvertTo-Json -Depth 40 -Compress
        $request = @{
            Uri = $Endpoint
            Method = 'Post'
            Headers = @{ Authorization = "Bearer $ApiKey" }
            ContentType = 'application/json; charset=utf-8'
            Body = $body
            TimeoutSec = 180
            ErrorAction = 'Stop'
        }
        $tempResponse = New-TemporaryFile -ErrorAction Stop
        $reply = $null
        try {
            $maxRetries = 2
            for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
                try {
                    Invoke-WebRequest @request -UseBasicParsing -OutFile $tempResponse.FullName
                    $reply = Get-Content -LiteralPath $tempResponse.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    break
                }
                catch {
                    $errFormatted = Format-AgentError -ErrorRecord $_
                    if (($attempt -lt $maxRetries) -and ($errFormatted -match '(?i)\b(408|429|500|502|503|504|timeout|timed out)\b')) {
                        $delay = ($attempt + 1) * 2
                        Write-Host ($script:Gm.Yellow + ("  [retry {0}/{1}] Transient error ({2}); waiting {3}s..." -f ($attempt + 1), $maxRetries, $errFormatted, $delay) + $script:Gm.Reset)
                        Start-Sleep -Seconds $delay
                        continue
                    }
                    if ((-not $overflowRetried) -and ($errFormatted -match '(?i)(context_length|maximum context|too many tokens|token limit)')) {
                        $overflowRetried = $true
                        Write-Host ($script:Gm.Yellow + '  [auto-recovery] Context overflow detected; compacting history and retrying...' + $script:Gm.Reset)
                        if (Invoke-AgentCompact -State $State -Endpoint $Endpoint -ModelId $ModelId -ApiKey $ApiKey) {
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
        $message = $reply.choices[0].message
        if (-not $message) { throw 'API returned no assistant message.' }
        $assistant = @{ role = 'assistant'; content = $message.content }
        if ($message.reasoning_content) {
            $assistant.reasoning_content = $message.reasoning_content
            Write-AgentReasoning -Text ([string]$message.reasoning_content)
        }
        if ($message.tool_calls) { $assistant.tool_calls = @($message.tool_calls) }
        $State.messages += $assistant
        if ($message.content) { Write-AgentReply -Content $message.content }
        if (-not $message.tool_calls) { return }
        foreach ($call in $message.tool_calls) {
            $output = Invoke-AgentTool -Root $Root -Call $call
            $State.messages += @{ role = 'tool'; tool_call_id = $call.id; content = $output }
        }
    }
    Write-Host ($script:Gm.Yellow + 'Step limit reached. Ask to continue, or use /clear.' + $script:Gm.Reset)
}

if (-not $LibraryOnly) {
    $script:AgentConfigPath = Format-ConfigPath -Path $ConfigPath
    $config = Read-AgentConfig -Path $ConfigPath
    if ($Setup) {
        Write-Host ($script:Gm.OscInit + $script:Gm.Fg + "Save settings to: $ConfigPath" + $script:Gm.Reset)
        Write-Host ($script:Gm.Yellow + 'API key is stored as plain text in your user profile, outside the project.' + $script:Gm.Reset)
        $defaultUrl = $BaseUrl
        if (-not $defaultUrl) { $defaultUrl = $config.H_AGENT_BASE_URL }
        $inputUrl = Read-Host "API base URL including /v1 [$defaultUrl]"
        if (-not $inputUrl) { $inputUrl = $defaultUrl }
        if ($inputUrl -notmatch '^https://[^\s]+$') { throw 'Use an HTTPS API base URL.' }
        $defaultModel = $Model
        if (-not $defaultModel) { $defaultModel = $config.H_AGENT_MODEL }
        $inputModel = Read-Host "Model ID [$defaultModel]"
        if (-not $inputModel) { $inputModel = $defaultModel }
        if (-not $inputModel) { throw 'Model ID is required.' }
        Write-Host ($script:Gm.Yellow + 'Key input is visible. Enter keeps the saved key, if any.' + $script:Gm.Reset)
        $inputKey = Read-Host 'API key'
        if (-not $inputKey) { $inputKey = $config.H_AGENT_API_KEY }
        if (-not $inputKey) { throw 'API key is required.' }
        $inputWorkspace = Read-Host 'Default workspace (Enter = current folder at each launch)'
        Save-AgentConfig -Path $ConfigPath -Config @{
            H_AGENT_BASE_URL = $inputUrl
            H_AGENT_MODEL = $inputModel
            H_AGENT_API_KEY = $inputKey
            H_AGENT_WORKSPACE = $inputWorkspace
        }
        Remove-Variable inputKey -ErrorAction SilentlyContinue
        Write-Host ($script:Gm.BoldGreen + 'Settings saved. Start h-agent from your working folder.' + $script:Gm.Reset)
        return
    }
    if (-not $BaseUrl) { $BaseUrl = $config.H_AGENT_BASE_URL }
    if (-not $Model) { $Model = $config.H_AGENT_MODEL }
    if ($PSBoundParameters.Keys -notcontains 'Workspace') {
        if ($env:H_AGENT_WORKSPACE) { $Workspace = $env:H_AGENT_WORKSPACE }
        elseif ($config.H_AGENT_WORKSPACE) { $Workspace = $config.H_AGENT_WORKSPACE }
    }
    if (-not $BaseUrl) { $BaseUrl = Read-Host 'API base URL (including /v1)' }
    if ($BaseUrl -notmatch '^https://[^\s]+$') { throw 'Use an HTTPS API base URL.' }
    if (-not $Model) { $Model = Read-Host 'Model ID' }
    if (-not $Model) { throw 'Model ID is required.' }
    if ($MaxSteps -lt 1 -or $MaxSteps -gt 30) { throw 'MaxSteps must be between 1 and 30.' }
    if ($Permission -notin @('ReadOnly', 'Ask', 'AutoEdit', 'Auto')) { throw 'Permission must be one of: ReadOnly, Ask, AutoEdit, Auto.' }
    $script:AgentPermission = $Permission
    if ($HideReasoning) { $script:ShowReasoning = 'hide' }
    if ($ReasoningEffort) {
        if ($ReasoningEffort -notin @('low', 'medium', 'high')) { throw 'ReasoningEffort must be low, medium, or high.' }
        $script:ReasoningEffort = $ReasoningEffort
    }
    $rootItem = Get-Item -LiteralPath $Workspace -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Workspace must be a directory.' }
    $rootPath = Resolve-AgentPath -Root $rootItem.FullName -RelativePath '.'
    $endpoint = $BaseUrl.TrimEnd('/') + '/chat/completions'
    $agentKey = $env:H_AGENT_API_KEY
    if (-not $agentKey) { $agentKey = $config.H_AGENT_API_KEY }
    $config.Clear()
    if (-not $agentKey) {
        Write-Host ($script:Gm.Yellow + 'Key input is visible. Run h-agent -Setup to save settings for next time.' + $script:Gm.Reset)
        $agentKey = Read-Host 'API key'
    }
    if (-not $agentKey) { throw 'API key is required.' }
    $configDir = Split-Path $script:AgentConfigPath -Parent
    $sessionDir = Join-Path $configDir 'sessions'
    $sessionFile = Join-Path $sessionDir ('session-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl')
    $fullSystemPrompt = Build-SystemPrompt -Root $rootPath -ConfigDir $configDir
    $system = @{ role = 'system'; content = $fullSystemPrompt }
    $state = @{ messages = @($system) }
    $undoStack = @()
    $lastFailedQuestion = ''
    if ($Continue -and (Test-Path -LiteralPath $sessionDir)) {
        $latest = Get-ChildItem -LiteralPath $sessionDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $sessionFile = $latest.FullName
            $state.messages = @(Read-AgentSession -SessionFile $sessionFile)
        }
    }
    try {
        if ($Prompt) {
            $tplPrompt = Resolve-PromptTemplate -Root $rootPath -ConfigDir $configDir -InputText $Prompt.Trim()
            $effectivePrompt = if ($null -ne $tplPrompt) { $tplPrompt } else { $Prompt }
            $expandedPrompt = Expand-UserPrompt -Root $rootPath -Prompt $effectivePrompt
            $state.messages += @{ role = 'user'; content = $expandedPrompt }
            Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
            Save-AgentSession -SessionFile $sessionFile -State $state
            return
        }
        Write-Host ($script:Gm.OscInit + $script:Gm.BoldGreen + "h-agent | model: $Model | permission: $($script:AgentPermission) | workspace: $rootPath" + $script:Gm.Reset)
        if (Get-AgentsContext -Root $rootPath -ConfigDir $configDir) { Write-Host ($script:Gm.Aqua + 'Loaded AGENTS.md instructions.' + $script:Gm.Reset) }
        if (Get-SkillsCatalog -Root $rootPath -ConfigDir $configDir) { Write-Host ($script:Gm.Aqua + 'Loaded skills catalog.' + $script:Gm.Reset) }
        Write-Host ($script:Gm.Grey1 + 'Commands: /help /status /permission /reasoning /undo /retry /compact /model /sessions /resume /save /new /exit' + $script:Gm.Reset)
        while ($true) {
            Write-Host ("`n" + $script:Gm.Grey0 + ('-' * 40) + $script:Gm.Reset)
            Write-Host ($script:Gm.BoldBlue + 'You: ' + $script:Gm.Fg) -NoNewline
            $question = Read-Host
            Write-Host $script:Gm.Reset -NoNewline
            if (-not $question) { continue }
            $trimmedQ = $question.Trim()
            if ($trimmedQ -eq '/exit') { break }
            if ($trimmedQ -eq '/clear' -or $trimmedQ -eq '/new') {
                $state.messages = @($system)
                $undoStack = @()
                $sessionFile = Join-Path $sessionDir ('session-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl')
                Write-Host ($script:Gm.Grey1 + 'Started a new conversation session.' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/help') {
                Write-Host ($script:Gm.Aqua + '  /status                      ' + $script:Gm.Fg + 'Show context size, model, permission mode, and session file' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /permission <mode>           ' + $script:Gm.Fg + 'Set mode: ReadOnly | Ask | AutoEdit (no-ask writes) | Auto' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /reasoning <mode|effort>     ' + $script:Gm.Fg + 'View: compact | full | hide; Effort: low | medium | high' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /undo                        ' + $script:Gm.Fg + 'Revert last turn AND restore modified/created files on disk' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /retry                       ' + $script:Gm.Fg + 'Retry the last failed user request' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /compact [focus]             ' + $script:Gm.Fg + 'Summarize older turns into a structured context handoff' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /model <id>                  ' + $script:Gm.Fg + 'Switch active model ID for this session' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /sessions                    ' + $script:Gm.Fg + 'List saved sessions in ~/.h-agent/sessions' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /resume <num|name>           ' + $script:Gm.Fg + 'Resume a saved session by number or filename' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /save [name]                 ' + $script:Gm.Fg + 'Save conversation to current or named session file' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /new (/clear)                ' + $script:Gm.Fg + 'Start a fresh session while keeping old session files' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /exit                        ' + $script:Gm.Fg + 'Exit h-agent' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  /<template> [args]           ' + $script:Gm.Fg + 'Run a custom Markdown prompt from .h-agent/prompts/<name>.md' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  @path/to/file                ' + $script:Gm.Fg + 'Inline-attach a workspace file into your prompt' + $script:Gm.Reset)
                Write-Host ($script:Gm.Aqua + '  !command / !!command         ' + $script:Gm.Fg + 'Run shell command (! adds to context, !! local only)' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -match '^/permission(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $reqPerm = $Matches[1].Trim()
                    $matchedPerm = @('ReadOnly', 'Ask', 'AutoEdit', 'Auto') | Where-Object { $_ -ieq $reqPerm } | Select-Object -First 1
                    if ($matchedPerm) {
                        $script:AgentPermission = $matchedPerm
                        Write-Host ($script:Gm.Green + "  Permission mode set to: $($script:AgentPermission)" + $script:Gm.Reset)
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
            if ($trimmedQ -match '^/reasoning(?:\s+(.+))?$') {
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
            if ($trimmedQ -match '^/save(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $nameArg = $Matches[1].Trim()
                    if ($nameArg -notmatch '\.jsonl$') { $nameArg += '.jsonl' }
                    $sessionFile = Join-Path $sessionDir (Split-Path $nameArg -Leaf)
                }
                Save-AgentSession -SessionFile $sessionFile -State $state
                Write-Host ($script:Gm.Green + "  Saved session: $sessionFile" + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/undo') {
                if ($undoStack.Count -eq 0) {
                    Write-Host ($script:Gm.Grey1 + '  Nothing to undo.' + $script:Gm.Reset)
                    continue
                }
                $lastUndo = $undoStack[$undoStack.Count - 1]
                if ($undoStack.Count -eq 1) { $undoStack = @() }
                else { $undoStack = @($undoStack[0..($undoStack.Count - 2)]) }
                Invoke-AgentUndo -State $state -UndoEntry $lastUndo
                Save-AgentSession -SessionFile $sessionFile -State $state
                Write-Host ($script:Gm.Green + '  Reverted last turn and restored disk state.' + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -eq '/status' -or $trimmedQ -eq '/tokens') {
                $st = Get-ContextStats -State $state
                Write-Host ($script:Gm.Aqua + "  Model: $($Model) | Permission: $($script:AgentPermission) | Messages: $($st.messages) | Chars: $($st.chars) (~$($st.est_tokens) tokens)" + $script:Gm.Reset)
                Write-Host ($script:Gm.Grey1 + "  Session: $sessionFile" + $script:Gm.Reset)
                continue
            }
            if ($trimmedQ -match '^/model(?:\s+(.+))?$') {
                if ($Matches[1]) {
                    $Model = $Matches[1].Trim()
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
                        Save-AgentSession -SessionFile $sessionFile -State $state
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
                $list = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
                for ($i = 0; $i -lt $list.Count; $i++) {
                    Write-Host ($script:Gm.Yellow + ("  [{0}] " -f ($i + 1)) + $script:Gm.Fg + $list[$i].Name + $script:Gm.Grey1 + (" ({0})" -f $list[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm')) + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/resume(?:\s+(.+))?$') {
                $arg = if ($Matches[1]) { $Matches[1].Trim() } else { '1' }
                if (-not (Test-Path -LiteralPath $sessionDir)) {
                    Write-Host ($script:Gm.Grey1 + '  No saved sessions found.' + $script:Gm.Reset)
                    continue
                }
                $list = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending)
                $chosen = $null
                if ($arg -match '^\d+$') {
                    $idx = [int]$arg - 1
                    if ($idx -ge 0 -and $idx -lt $list.Count) { $chosen = $list[$idx].FullName }
                }
                else {
                    $cand = Join-Path $sessionDir $arg
                    if (Test-Path -LiteralPath $cand) { $chosen = $cand }
                }
                if ($chosen) {
                    $state.messages = @(Read-AgentSession -SessionFile $chosen)
                    $sessionFile = $chosen
                    if ($PSBoundParameters.Keys -notcontains 'Permission') { $script:AgentPermission = 'Ask' }
                    Write-Host ($script:Gm.Green + "  Resumed session: $sessionFile ($($state.messages.Count) messages, permission=$($script:AgentPermission))" + $script:Gm.Reset)
                }
                else {
                    Write-Host ($script:Gm.Red + "  Session not found: $arg" + $script:Gm.Reset)
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
                        Save-AgentSession -SessionFile $sessionFile -State $state
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
                Save-AgentSession -SessionFile $sessionFile -State $state
            }
            catch {
                $lastFailedQuestion = $question
                Invoke-AgentUndo -State $state -UndoEntry @{ messages = $beforeTurn; writes = @($script:CurrentTurnWrites) }
                Write-Host ($script:Gm.Red + 'Request failed; turn rolled back (use /retry to resend): ' + (Format-AgentError -ErrorRecord $_) + $script:Gm.Reset)
            }
        }
    }
    finally { Remove-Variable agentKey -ErrorAction SilentlyContinue }
}
