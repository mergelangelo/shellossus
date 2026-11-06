# CLI entrypoint: interactive setup, configuration resolution, single-shot execution, and interactive REPL loop.

if (-not $LibraryOnly) {
    if ($Install) {
        $targetAgentPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'shellossus.ps1' }
        Invoke-AgentProfileInstall -AgentPath $targetAgentPath -ProfilePath $ProfilePath -Shortcut $Shortcut -ShortcutSpecified:($PSBoundParameters.Keys -contains 'Shortcut') -NoShortcut:$NoShortcut
        if (-not $Setup -and -not $Doctor) { return }
    }
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
    if (-not $Theme -and $config.SHELLOSSUS_THEME) { $Theme = $config.SHELLOSSUS_THEME }
    if ($Theme) {
        try {
            $null = Set-AgentTheme -Name $Theme
        }
        catch {
            if (-not $Doctor) { throw }
        }
    }
    if ($Setup -and -not $Doctor) {
        Write-Host ($script:Gm.OscInit + $script:Gm.Fg + "Save settings to: $ConfigPath" + $script:Gm.Reset)
        Write-Host ($script:Gm.Yellow + 'API key is stored as plain text in your user profile, outside the project.' + $script:Gm.Reset)
        $defaultUrl = $BaseUrl
        if (-not $defaultUrl) { $defaultUrl = $env:H_AGENT_BASE_URL }
        if (-not $defaultUrl) { $defaultUrl = $config.SHELLOSSUS_BASE_URL }
        $inputUrl = Read-Host "API base URL including /v1 [$defaultUrl]"
        if (-not $inputUrl) { $inputUrl = $defaultUrl }
        if (-not (Test-ValidAgentBaseUrl -Url $inputUrl)) { throw 'An HTTPS base URL (or http://localhost / http://127.0.0.1 for local servers) is required. Run: shellossus -Setup' }
        $defaultModel = $Model
        if (-not $defaultModel) { $defaultModel = $env:H_AGENT_MODEL }
        if (-not $defaultModel) { $defaultModel = $config.SHELLOSSUS_MODEL }
        $inputModel = Read-Host "Model ID [$defaultModel]"
        if (-not $inputModel) { $inputModel = $defaultModel }
        if (-not $inputModel) { throw 'Model ID is required.' }
        Write-Host ($script:Gm.Yellow + 'Key input is visible. Enter keeps the saved key, if any.' + $script:Gm.Reset)
        $inputKey = Read-Host 'API key'
        if (-not $inputKey) { $inputKey = $config.SHELLOSSUS_API_KEY }
        if (-not $inputKey -and (Test-IsLoopbackBaseUrl -Url $inputUrl)) { $inputKey = 'local' }
        if (-not $inputKey) { throw 'API key is required.' }
        $defaultWorkspace = ''
        if ($PSBoundParameters.Keys -contains 'Workspace') { $defaultWorkspace = $Workspace }
        elseif ($env:SHELLOSSUS_WORKSPACE) { $defaultWorkspace = $env:SHELLOSSUS_WORKSPACE }
        elseif ($env:H_AGENT_WORKSPACE) { $defaultWorkspace = $env:H_AGENT_WORKSPACE }
        elseif ($config.SHELLOSSUS_WORKSPACE) { $defaultWorkspace = $config.SHELLOSSUS_WORKSPACE }
        $wsPrompt = if ($defaultWorkspace) { "Default workspace [$defaultWorkspace] (Enter keeps saved, '-' clears)" } else { 'Default workspace (Enter = current folder at each launch)' }
        $inputWorkspace = Read-Host $wsPrompt
        if (-not $inputWorkspace) { $inputWorkspace = $defaultWorkspace }
        elseif ($inputWorkspace.Trim() -eq '-') { $inputWorkspace = '' }
        $newCfg = @{
            SHELLOSSUS_BASE_URL = $inputUrl
            SHELLOSSUS_MODEL = $inputModel
            SHELLOSSUS_API_KEY = $inputKey
            SHELLOSSUS_WORKSPACE = $inputWorkspace
        }
        foreach ($optK in @('SHELLOSSUS_CONTEXT_WINDOW', 'SHELLOSSUS_COMPACT_THRESHOLD', 'SHELLOSSUS_THEME')) {
            if ($config.ContainsKey($optK) -and $config[$optK]) { $newCfg[$optK] = $config[$optK] }
        }
        if (($PSBoundParameters.Keys -contains 'ContextWindow') -and $ContextWindow) { $newCfg['SHELLOSSUS_CONTEXT_WINDOW'] = $ContextWindow }
        if (($PSBoundParameters.Keys -contains 'CompactThreshold') -and $CompactThreshold) { $newCfg['SHELLOSSUS_COMPACT_THRESHOLD'] = $CompactThreshold }
        if (($PSBoundParameters.Keys -contains 'Theme') -and $Theme -and $script:ActiveTheme) { $newCfg['SHELLOSSUS_THEME'] = $script:ActiveTheme }
        Save-AgentConfig -Path $ConfigPath -Config $newCfg
        Remove-Variable inputKey -ErrorAction SilentlyContinue
        Write-Host ($script:Gm.BoldGreen + 'Settings saved. Run shellossus -Doctor to check them, then start shellossus from your working folder.' + $script:Gm.Reset)
        return
    }
    if ($Mascot) {
        if ($Mode -ine 'json') { Write-TuiMascotCard -Mode 'full' }
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
    if (-not (Test-ValidAgentBaseUrl -Url $BaseUrl)) { throw 'An HTTPS base URL (or http://localhost / http://127.0.0.1 for local servers) is required. Run: shellossus -Setup' }
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
    $script:EnabledTools = @(if ($Tools) { $Tools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $script:ExcludedTools = @(if ($ExcludeTools) { $ExcludeTools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
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
    if (-not $agentKey -and (Test-IsLoopbackBaseUrl -Url $BaseUrl)) {
        $agentKey = 'local'
    }
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
            $beforeTurn = @(Copy-SessionHashtableArray -Items $state.messages)
            $beforeLeafId = if ($state.leaf_id) { [string]$state.leaf_id } else { '' }
            $beforeTreeEntries = @(Copy-SessionHashtableArray -Items $state.tree_entries)
            $stBefore = Get-ContextStats -State $state
            if ($stBefore.est_tokens -gt $stBefore.compact_threshold_tokens) {
                if ($script:OutputMode -ne 'json') {
                    $limStr = Format-TokenCount -Tokens $stBefore.compact_threshold_tokens
                    Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
                }
                try { Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey | Out-Null } catch {}
            }
            $script:CurrentTurnWrites = @()
            $tplPrompt = Resolve-PromptTemplate -Root $rootPath -ConfigDir $configDir -InputText $Prompt.Trim()
            $effectivePrompt = if ($null -ne $tplPrompt) { $tplPrompt } else { $Prompt }
            $expandedPrompt = Expand-UserPrompt -Root $rootPath -Prompt $effectivePrompt
            $state.messages += @{ role = 'user'; content = $expandedPrompt }
            try {
                Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
                Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
            }
            catch {
                $errMsg = Format-AgentError -ErrorRecord $_
                $state.messages = $beforeTurn
                try {
                    Invoke-AgentUndo -State $state -UndoEntry @{ messages = $beforeTurn; leaf_id = $beforeLeafId; tree_entries = $beforeTreeEntries; writes = @($script:CurrentTurnWrites) }
                }
                catch {
                    if ($script:OutputMode -ne 'json') {
                        Write-Host ($script:Gm.Red + 'Rollback warning: ' + $_.Exception.Message + $script:Gm.Reset)
                    }
                }
                Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $errMsg }
                throw
            }
            return
        }
        Write-TuiStartupBanner -RootPath $rootPath -ConfigDir $configDir -Model $Model
        while ($true) {
            Write-TuiPromptFrame -State $state -Root $rootPath -Model $Model -UndoCount $undoStack.Count
            Write-Host ('  ' + $script:Gm.BoldBlue + $script:Box.Arrow + ' You: ' + $script:Gm.Fg) -NoNewline
            $question = Read-TuiMultilineInput
            Write-Host $script:Gm.Reset -NoNewline
            if ($null -eq $question) { break }
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
                    $currTodos = @(if ($script:ActiveSessionTodos -and @($script:ActiveSessionTodos).Count -gt 0) { @($script:ActiveSessionTodos) } elseif ($state -and $state.todos -and @($state.todos).Count -gt 0) { @($state.todos) })
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
                Invoke-ReplMemoryCommand -State $state -RootPath $rootPath -ConfigDir $configDir -MemArg $memSub
                continue
            }
            if ($trimmedQ -eq '/help' -or $trimmedQ -eq '/hotkeys') {
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
                Write-TuiAgentsCard -RootPath $rootPath -ConfigDir $configDir
                continue
            }
            if ($trimmedQ -eq '/skills') {
                Write-TuiSkillsCard -RootPath $rootPath -ConfigDir $configDir
                continue
            }
            if ($trimmedQ -match '^/permission(?:\s+(.+))?$') {
                $reqPerm = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                Invoke-ReplPermissionCommand -State $state -ReqPerm $reqPerm
                continue
            }
            if ($trimmedQ -match '^/diagnostics(?:\s+(.+))?$') {
                $diagArg = if ($Matches[1]) { $Matches[1] } else { '' }
                Invoke-ReplDiagnosticsCommand -RootPath $rootPath -Arg $diagArg
                continue
            }
            if ($trimmedQ -match '^/(?:reasoning|thinking)(?:\s+(.+))?$') {
                $argR = if ($Matches[1]) { $Matches[1].Trim().ToLower() } else { '' }
                Invoke-ReplReasoningCommand -ArgR $argR
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
                $state.scoped_instr_cache = @{}
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
                Invoke-ReplContextCommand -State $state -CtxArg $ctxArg
                continue
            }
            if ($trimmedQ -match '^/model(?:\s+(.+))?$') {
                $reqModel = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                $newModel = Select-ReplModelId -CurrentModel $Model -SessionDir $sessionDir -NewModel $reqModel
                if ($newModel) {
                    $Model = $newModel
                    $state.model = $Model
                    $script:ActiveModelId = $Model
                    if ($script:AgentConfigPath) {
                        $null = Update-AgentConfigOptionalKey -Path $script:AgentConfigPath -Key 'SHELLOSSUS_MODEL' -Value $Model
                    }
                    Write-Host ($script:Gm.Green + "  Model switched to: $Model" + $script:Gm.Reset)
                }
                continue
            }
            if ($trimmedQ -match '^/theme(?:\s+(.+))?$') {
                $thArg = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
                Invoke-ReplThemeCommand -ThemeArg $thArg
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
                        $sName = if ($meta -and $meta.session_name) { [string]$meta.session_name } elseif ($meta -and $meta.name) { [string]$meta.name } else { '' }
                        $nmTag = if ($sName) { "[$sName] " } else { '' }
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
                $beforeTurn = @(Copy-SessionHashtableArray -Items $state.messages)
                $beforeLeafId = if ($state.leaf_id) { [string]$state.leaf_id } else { '' }
                $beforeTreeEntries = @(Copy-SessionHashtableArray -Items $state.tree_entries)
                $stBefore = Get-ContextStats -State $state
                if ($stBefore.est_tokens -gt $stBefore.compact_threshold_tokens) {
                    $limStr = Format-TokenCount -Tokens $stBefore.compact_threshold_tokens
                    Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
                    try { Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey | Out-Null } catch {}
                }
                $script:CurrentTurnWrites = @()
                Write-Host ($script:Gm.Aqua + "  [continue] Continuing agent turn (up to $contSteps steps)..." + $script:Gm.Reset)
                try {
                    Invoke-AgentContinue -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $contSteps | Out-Null
                    $lastFailedQuestion = ''
                    $undoStack += @{ messages = $beforeTurn; leaf_id = $beforeLeafId; tree_entries = $beforeTreeEntries; writes = @($script:CurrentTurnWrites) }
                    Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                }
                catch {
                    $state.messages = $beforeTurn
                    try {
                        Invoke-AgentUndo -State $state -UndoEntry @{ messages = $beforeTurn; leaf_id = $beforeLeafId; tree_entries = $beforeTreeEntries; writes = @($script:CurrentTurnWrites) }
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
                        $state.messages += @{ role = 'user'; content = ("[Shell command $cmdStr exit=$($res.exit_code)]`n" + $res.output) }
                        Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                        Write-Host ($script:Gm.Aqua + '  (Output added to conversation context)' + $script:Gm.Reset)
                    }
                }
                catch {
                    Write-Host ($script:Gm.Red + '  Command error: ' + $_.Exception.Message + $script:Gm.Reset)
                }
                continue
            }
            $beforeTurn = @(Copy-SessionHashtableArray -Items $state.messages)
            $beforeLeafId = if ($state.leaf_id) { [string]$state.leaf_id } else { '' }
            $beforeTreeEntries = @(Copy-SessionHashtableArray -Items $state.tree_entries)
            $stBefore = Get-ContextStats -State $state
            if ($stBefore.est_tokens -gt $stBefore.compact_threshold_tokens) {
                $limStr = Format-TokenCount -Tokens $stBefore.compact_threshold_tokens
                Write-Host ($script:Gm.Yellow + "  [auto-compact] Context exceeds $limStr tokens, compacting older history..." + $script:Gm.Reset)
                try { Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey | Out-Null } catch {}
            }
            $script:CurrentTurnWrites = @()
            $expandedQuestion = Expand-UserPrompt -Root $rootPath -Prompt $question
            $state.messages += @{ role = 'user'; content = $expandedQuestion }
            try {
                Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
                $lastFailedQuestion = ''
                $undoStack += @{ messages = $beforeTurn; leaf_id = $beforeLeafId; tree_entries = $beforeTreeEntries; writes = @($script:CurrentTurnWrites) }
                Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
            }
            catch {
                $lastFailedQuestion = $question
                $state.messages = $beforeTurn
                try {
                    Invoke-AgentUndo -State $state -UndoEntry @{ messages = $beforeTurn; leaf_id = $beforeLeafId; tree_entries = $beforeTreeEntries; writes = @($script:CurrentTurnWrites) }
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
