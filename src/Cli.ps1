# CLI entrypoint: interactive setup, configuration resolution, single-shot execution, and interactive REPL loop.

if (-not $LibraryOnly) {
    $script:OutputMode = if ($Mode) { $Mode.ToLower() } else { 'text' }
    if ($script:OutputMode -notin @('text', 'json')) { throw 'Mode must be text or json.' }
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
        if (-not (Test-Path -LiteralPath $ConfigPath)) { $doctorConfigState = 'missing' }
        $config = Read-AgentConfig -Path $ConfigPath
    }
    catch {
        if ($Doctor) {
            $doctorConfigState = 'invalid'
        }
        elseif ($Setup) {
            $config = @{}
        }
        else {
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $_.Exception.Message }
            throw
        }
    }
    if (-not $Theme -and $config.SHELLOSSUS_THEME) { $Theme = $config.SHELLOSSUS_THEME }
    if ($Theme) {
        try {
            $null = Set-AgentTheme -Name $Theme
        }
        catch {
            if (-not $Doctor) {
                Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $_.Exception.Message }
                throw
            }
        }
    }
    if ($Setup -and -not $Doctor) {
        Write-Host ($script:Gm.OscInit + $script:Gm.Fg + "Save settings to: $ConfigPath" + $script:Gm.Reset)
        Write-Host ($script:Gm.Yellow + 'API key is stored as plain text in your user profile, outside the project.' + $script:Gm.Reset)
        $defaultUrl = $BaseUrl
        if (-not $defaultUrl) { $defaultUrl = $config.SHELLOSSUS_BASE_URL }
        $inputUrl = Read-Host "API base URL including /v1 [$defaultUrl]"
        if (-not $inputUrl) { $inputUrl = $defaultUrl }
        if (-not (Test-ValidAgentBaseUrl -Url $inputUrl)) { throw 'An HTTPS base URL (or http://localhost / http://127.0.0.1 for local servers) is required. Run: shellossus -Setup' }
        $defaultModel = $Model
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
    if (-not $BaseUrl) { $BaseUrl = $config.SHELLOSSUS_BASE_URL }
    if (-not $Model) { $Model = $config.SHELLOSSUS_MODEL }
    if ($PSBoundParameters.Keys -notcontains 'Workspace') {
        if ($env:SHELLOSSUS_WORKSPACE) { $Workspace = $env:SHELLOSSUS_WORKSPACE }
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
    if (-not $Session -and -not $Continue -and -not $Fork -and $Export -and ($Export -match '\.jsonl$') -and (Test-Path -LiteralPath $Export)) {
        $config.Clear()
        $expState = @{ session_id = ''; workspace = $rootPath; model = $Model; messages = @() }
        Invoke-SessionResume -SessionFile $Export -State $expState -CurrentWorkspace $rootPath | Out-Null
        $outHtml = $Export -replace '\.jsonl$', '.html'
        $null = Export-AgentSessionOutput -State $expState -ExportPath $outHtml -RootPath $rootPath -Model $Model
        return
    }
    if (-not $Export) {
        if (-not $BaseUrl -and $script:OutputMode -ne 'json') { $BaseUrl = Read-Host 'API base URL (including /v1)' }
        if (-not (Test-ValidAgentBaseUrl -Url $BaseUrl)) {
            $urlErr = 'An HTTPS base URL (or http://localhost / http://127.0.0.1 for local servers) is required. Run: shellossus -Setup'
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $urlErr }
            throw $urlErr
        }
        if (-not $Model -and $script:OutputMode -ne 'json') { $Model = Read-Host 'Model ID' }
        if (-not $Model) {
            $mdlErr = 'Model ID is required.'
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $mdlErr }
            throw $mdlErr
        }
    }
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
    $script:StartupAgentPermission = $Permission
    $script:StartupPermissionSpecified = ($PSBoundParameters.Keys -contains 'Permission')
    if ($env:SHELLOSSUS_SUB_AUTO_WEB -eq '1') { $script:AutoApproveWeb = $true }
    $script:Diagnostics = [bool]$Diagnostics
    $script:NoTools = [bool]$NoTools
    $script:EnabledTools = @(if ($Tools) { $Tools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $script:ExcludedTools = @(if ($ExcludeTools) { $ExcludeTools -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $script:NoSkills = [bool]$NoSkills
    $script:NoPromptTemplates = [bool]$NoPromptTemplates
    if ($HideReasoning) { $script:ShowReasoning = 'hide' }
    if ($ReasoningEffort) {
        if ($ReasoningEffort -notin @('low', 'medium', 'high')) { throw 'ReasoningEffort must be low, medium, or high.' }
        $script:ReasoningEffort = $ReasoningEffort
    }
    $endpoint = ''
    $agentKey = ''
    if (-not $Export) {
        $endpoint = $BaseUrl.TrimEnd('/') + '/chat/completions'
        $agentKey = $env:SHELLOSSUS_API_KEY
        if (-not $agentKey) { $agentKey = $config.SHELLOSSUS_API_KEY }
        $config.Clear()
        if (-not $agentKey -and (Test-IsLoopbackBaseUrl -Url $BaseUrl)) {
            $agentKey = 'local'
        }
        if (-not $agentKey -and $script:OutputMode -ne 'json') {
            Write-Host ($script:Gm.Yellow + 'Key input is visible. Run shellossus -Setup to save settings for next time.' + $script:Gm.Reset)
            $agentKey = Read-Host 'API key'
        }
        if (-not $agentKey) {
            $keyErr = 'API key is required.'
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $keyErr }
            throw $keyErr
        }
    }
    else {
        $config.Clear()
    }
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
    $lastFailedAttachmentSource = ''
    if ($Session) {
        $candSess = if (Test-Path -LiteralPath $Session) { $Session } else { Join-Path $sessionDir (Split-Path $Session -Leaf) }
        if (-not (Test-Path -LiteralPath $candSess) -and ($candSess -notmatch '\.jsonl$')) { $candSess += '.jsonl' }
        if (Test-Path -LiteralPath $candSess) {
            $sessionFile = if ($NoSession) { '' } else { $candSess }
            Invoke-SessionResume -SessionFile $candSess -State $state -CurrentWorkspace $rootPath | Out-Null
            if ($NoSession) { $script:ActiveSessionFile = '' }
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
        $forkRes = Invoke-SessionFork -State $srcState -SessionDir $sessionDir -NewName $SessionName -NoSession:$NoSession
        $state = $forkRes.state
        $sessionFile = if ($NoSession) { '' } else { $forkRes.session_file }
        if ($PSBoundParameters.Keys -notcontains 'Model' -and $state.model) { $Model = $state.model }
    }
    elseif ($Continue) {
        $latestProjectSession = Find-ProjectSession -SessionDir $sessionDir -Workspace $rootPath
        if ($latestProjectSession) {
            $sessionFile = if ($NoSession) { '' } else { $latestProjectSession }
            Invoke-SessionResume -SessionFile $latestProjectSession -State $state -CurrentWorkspace $rootPath | Out-Null
            if ($NoSession) { $script:ActiveSessionFile = '' }
            if ($PSBoundParameters.Keys -notcontains 'Model' -and $state.model) { $Model = $state.model }
        }
    }
    $script:ActiveSessionFile = $sessionFile
    if ($Export) {
        $null = Export-AgentSessionOutput -State $state -ExportPath $Export -RootPath $rootPath -Model $Model
        return
    }
    try {
        if ($Prompt) {
            Ensure-SessionTree -State $state
            $turnSnapshot = New-AgentTurnSnapshot -State $state
            $null = Invoke-ThresholdAutoCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey
            $script:CurrentTurnWrites = @()
            $expandedPrompt = $Prompt
            if (-not $LiteralPrompt) {
                $tplPrompt = Resolve-PromptTemplate -Root $rootPath -ConfigDir $configDir -InputText $Prompt.Trim()
                $effectivePrompt = if ($null -ne $tplPrompt) { $tplPrompt } else { $Prompt }
                $expandedPrompt = Expand-UserPrompt -Root $rootPath -Prompt $effectivePrompt -AttachmentSource $Prompt
            }
            $state.messages += @{ role = 'user'; content = $expandedPrompt }
            try {
                Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
                Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
            }
            catch {
                $errMsg = Format-AgentError -ErrorRecord $_
                $rollback = Invoke-AgentTurnRollback -State $state -Snapshot $turnSnapshot -Writes @($script:CurrentTurnWrites)
                $errorPayload = @{ status = 'error'; error = $errMsg }
                if (-not $rollback.succeeded) {
                    $errorPayload.rollback_error = $rollback.error
                    if ($script:OutputMode -ne 'json') {
                        Write-Host ($script:Gm.Red + 'Rollback did not succeed: ' + $rollback.error + $script:Gm.Reset)
                    }
                }
                Write-AgentJsonEvent -EventType 'turn_end' -Payload $errorPayload
                throw
            }
            return
        }
        if ($script:OutputMode -eq 'json') {
            $jsonReplErr = '-Mode json requires -Prompt.'
            Write-AgentJsonEvent -EventType 'turn_end' -Payload @{ status = 'error'; error = $jsonReplErr }
            throw $jsonReplErr
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
                $newRes = Invoke-ReplNewSessionCommand -State $state -RootPath $rootPath -ConfigDir $configDir -Model $Model -SessionDir $sessionDir -NoSession:$NoSession -UndoStack $undoStack
                $fullSystemPrompt = $newRes.full_system_prompt; $system = $newRes.system
                $sessionFile = $newRes.session_file; $undoStack = @($newRes.undo_stack); $lastFailedQuestion = ''
                continue
            }
            if ($trimmedQ -match '^/(?:todo|todos)(?:\s+(.+))?$') { Invoke-ReplTodoCommand -State $state -TodoArg $Matches[1]; continue }
            if ($trimmedQ -match '^/(?:memory|mem)(?:\s+(.+))?$') { Invoke-ReplMemoryCommand -State $state -RootPath $rootPath -ConfigDir $configDir -MemArg $Matches[1]; continue }
            if ($trimmedQ -eq '/help' -or $trimmedQ -eq '/hotkeys') { Write-TuiHelpCard; continue }
            if ($trimmedQ -eq '/doctor') {
                $doctorSessionDir = if ($sessionFile) { Split-Path $sessionFile -Parent } else { $sessionDir }
                $report = Get-AgentDoctorReport -BaseUrl $BaseUrl -ModelId $Model -ApiKey $agentKey -Workspace $rootPath -SessionDir $doctorSessionDir -NoSession:(-not $sessionFile) -ConfigState $doctorConfigState
                Write-AgentDoctorReport -Report $report -Mode $script:OutputMode
                continue
            }
            if ($trimmedQ -eq '/mascot') { Write-TuiMascotCard -Mode 'full'; continue }
            if ($trimmedQ -eq '/agents') { Write-TuiAgentsCard -RootPath $rootPath -ConfigDir $configDir; continue }
            if ($trimmedQ -eq '/skills') { Write-TuiSkillsCard -RootPath $rootPath -ConfigDir $configDir; continue }
            if ($trimmedQ -match '^/permission(?:\s+(.+))?$') { Invoke-ReplPermissionCommand -State $state -ReqPerm $(if ($Matches[1]) { $Matches[1].Trim() } else { '' }); continue }
            if ($trimmedQ -match '^/diagnostics(?:\s+(.+))?$') { Invoke-ReplDiagnosticsCommand -RootPath $rootPath -Arg $Matches[1]; continue }
            if ($trimmedQ -match '^/(?:reasoning|thinking)(?:\s+(.+))?$') { Invoke-ReplReasoningCommand -ArgR $(if ($Matches[1]) { $Matches[1].Trim().ToLower() } else { '' }); continue }
            if ($trimmedQ -match '^/name(?:\s+(.+))?$') { Invoke-ReplNameCommand -State $state -SessionFile $sessionFile -RootPath $rootPath -Model $Model -NameArg $Matches[1]; continue }
            if ($trimmedQ -match '^/tree(?:\s+(.+))?$') {
                $treeRes = Invoke-ReplTreeCommand -State $state -SessionFile $sessionFile -RootPath $rootPath -Model $Model -UndoStack $undoStack -TargetEntryId $Matches[1]
                $undoStack = @($treeRes.undo_stack)
                continue
            }
            if ($trimmedQ -match '^/(?:fork|clone)(?:\s+(.+))?$') {
                $forkRes = Invoke-ReplForkCommand -State $state -SessionDir $sessionDir -SessionFile $sessionFile -NoSession:$NoSession -UndoStack $undoStack -ForkEntryId $Matches[1]
                $state = $forkRes.state; $sessionFile = $forkRes.session_file; $undoStack = @($forkRes.undo_stack)
                continue
            }
            if ($trimmedQ -match '^/(?:export|share)(?:\s+(.+))?$') { Invoke-ReplExportCommand -State $state -RootPath $rootPath -Model $Model -ExportArg $Matches[1]; continue }
            if ($trimmedQ -match '^/import(?:\s+(.+))?$') {
                $impRes = Invoke-ReplImportCommand -State $state -RootPath $rootPath -SessionFile $sessionFile -Model $Model -NoSession:$NoSession -UndoStack $undoStack -LastFailedQuestion $lastFailedQuestion -ImportArg $Matches[1]
                $sessionFile = $impRes.session_file; $Model = $impRes.model
                $undoStack = @($impRes.undo_stack); $lastFailedQuestion = $impRes.last_failed_question
                continue
            }
            if ($trimmedQ -eq '/copy') { Invoke-ReplCopyCommand -State $state; continue }
            if ($trimmedQ -eq '/reload') {
                $reloadRes = Invoke-ReplReloadCommand -State $state -SystemMessage $system -RootPath $rootPath -ConfigDir $configDir
                $fullSystemPrompt = $reloadRes.full_system_prompt; $system = $reloadRes.system
                continue
            }
            if ($trimmedQ -match '^/save(?:\s+(.+))?$') {
                $saveRes = Invoke-ReplSaveCommand -State $state -SessionDir $sessionDir -SessionFile $sessionFile -RootPath $rootPath -Model $Model -SaveArg $Matches[1]
                $sessionFile = $saveRes.session_file
                continue
            }
            if ($trimmedQ -eq '/undo') {
                $undoRes = Invoke-ReplUndoCommand -State $state -SessionFile $sessionFile -RootPath $rootPath -Model $Model -UndoStack $undoStack
                $undoStack = @($undoRes.undo_stack)
                continue
            }
            if ($trimmedQ -eq '/status' -or $trimmedQ -eq '/tokens' -or $trimmedQ -eq '/session') {
                foreach ($sLn in @(Format-TuiStatusCard -State $state -Model $Model -MaxSteps $MaxSteps -SessionFile $sessionFile -UndoCount $undoStack.Count)) { Write-Host $sLn }
                continue
            }
            if ($trimmedQ -match '^/context(?:\s+(.+))?$') { Invoke-ReplContextCommand -State $state -CtxArg $(if ($Matches[1]) { $Matches[1].Trim() } else { '' }); continue }
            if ($trimmedQ -match '^/model(?:\s+(.+))?$') { $Model = Invoke-ReplModelCommand -State $state -CurrentModel $Model -SessionDir $sessionDir -NewModel $Matches[1] -SessionFile $sessionFile -RootPath $rootPath; continue }
            if ($trimmedQ -match '^/theme(?:\s+(.+))?$') { Invoke-ReplThemeCommand -ThemeArg $(if ($Matches[1]) { $Matches[1].Trim() } else { '' }); continue }
            if ($trimmedQ -match '^/compact(?:\s+(.+))?$') { Invoke-ReplCompactCommand -State $state -Endpoint $endpoint -Model $Model -ApiKey $agentKey -SessionFile $sessionFile -RootPath $rootPath -Focus $Matches[1]; continue }
            if ($trimmedQ -eq '/sessions' -or $trimmedQ -match '^/resume(?:\s+(.+))?$') {
                $resArg = if ($trimmedQ -ne '/sessions' -and $Matches[1]) { $Matches[1] } else { '' }
                $sessRes = Invoke-ReplSessionsCommand -State $state -SessionDir $sessionDir -SessionFile $sessionFile -RootPath $rootPath -Model $Model -UndoStack $undoStack -LastFailedQuestion $lastFailedQuestion -ResumeArg $resArg -NoSession:$NoSession
                $sessionFile = $sessRes.session_file; $Model = $sessRes.model
                $undoStack = @($sessRes.undo_stack); $lastFailedQuestion = $sessRes.last_failed_question
                continue
            }
            if ($trimmedQ -match '^/continue(?:\s+(.+))?$') {
                $contRes = Invoke-ReplContinueCommand -State $state -Endpoint $endpoint -Model $Model -ApiKey $agentKey -RootPath $rootPath -SessionFile $sessionFile -MaxSteps $MaxSteps -UndoStack $undoStack -LastFailedQuestion $lastFailedQuestion -ContinueArg $Matches[1]
                $undoStack = @($contRes.undo_stack); $lastFailedQuestion = $contRes.last_failed_question
                continue
            }
            $attachmentSource = $question
            if ($trimmedQ -eq '/retry') {
                if (-not $lastFailedQuestion) {
                    Write-Host ($script:Gm.Grey1 + '  No failed request to retry.' + $script:Gm.Reset)
                    continue
                }
                $question = $lastFailedQuestion
                $attachmentSource = $lastFailedAttachmentSource
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
                Invoke-ReplBangCommand -State $state -InputText $trimmedQ -RootPath $rootPath -SessionFile $sessionFile -Model $Model
                continue
            }
            Ensure-SessionTree -State $state
            $turnSnapshot = New-AgentTurnSnapshot -State $state
            $null = Invoke-ThresholdAutoCompact -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey
            $script:CurrentTurnWrites = @()
            $expandedQuestion = Expand-UserPrompt -Root $rootPath -Prompt $question -AttachmentSource $attachmentSource
            $state.messages += @{ role = 'user'; content = $expandedQuestion }
            try {
                Invoke-AgentTurn -State $state -Endpoint $endpoint -ModelId $Model -ApiKey $agentKey -Root $rootPath -Steps $MaxSteps
                $lastFailedQuestion = ''
                Save-AgentSession -SessionFile $sessionFile -State $state -Workspace $rootPath -Model $Model
                $undoStack += (New-AgentUndoFrame -Snapshot $turnSnapshot -Writes @($script:CurrentTurnWrites))
            }
            catch {
                $lastFailedQuestion = $question
                $lastFailedAttachmentSource = $attachmentSource
                $requestErr = Format-AgentError -ErrorRecord $_
                $rollback = Invoke-AgentTurnRollback -State $state -Snapshot $turnSnapshot -Writes @($script:CurrentTurnWrites) -UndoStack $undoStack
                if ($rollback.succeeded) {
                    Write-Host ($script:Gm.Red + 'Request failed; turn rolled back (use /retry to resend): ' + $requestErr + $script:Gm.Reset)
                }
                else {
                    $undoStack = @($rollback.undo_stack)
                    Write-Host ($script:Gm.Red + 'Request failed; rollback did not succeed: ' + $rollback.error + $script:Gm.Reset)
                }
            }
        }
    }
    finally {
        Clear-AgentUndoBackups -UndoEntries $undoStack -Writes $script:CurrentTurnWrites
        $script:CurrentTurnWrites = @()
        Remove-Variable agentKey -ErrorAction SilentlyContinue
    }
}
