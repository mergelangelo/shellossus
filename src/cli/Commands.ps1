# Session export helper and interactive REPL slash-command handlers.

function Export-AgentSessionOutput {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ExportPath,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [string]$Model = '',
        [string]$Indent = ''
    )
    if ($ExportPath -match '\.jsonl$') {
        Save-AgentSession -SessionFile $ExportPath -State $State -Workspace $RootPath -Model $Model
        Write-Host ($script:Gm.Green + "${Indent}Exported session JSONL: $ExportPath" + $script:Gm.Reset)
        return $ExportPath
    }
    $outHtml = if ($ExportPath -match '\.html?$') { $ExportPath } else { $ExportPath + '.html' }
    $exported = Export-AgentSessionHtml -State $State -OutputPath $outHtml
    Write-Host ($script:Gm.Green + "${Indent}Exported session HTML: $exported" + $script:Gm.Reset)
    return $exported
}

function Reset-AgentSessionApprovals {
    param($State)
    $script:AutoApproveWeb = $false
    $script:AutoApproveCommands = $false
    if ($script:StartupPermissionSpecified) {
        $startupPerm = [string]$script:StartupAgentPermission
        if ($startupPerm -in @('ReadOnly', 'Ask', 'AutoEdit', 'Auto')) {
            $script:AgentPermission = $startupPerm
        }
        else {
            $script:AgentPermission = 'Ask'
        }
    }
    else {
        $script:AgentPermission = 'Ask'
    }
    if ($State) {
        Sync-AgentCapabilities -State $State | Out-Null
    }
}

function Invoke-ReplNewSessionCommand {
    param($State, [string]$RootPath, [string]$ConfigDir = '', [string]$Model = '', [string]$SessionDir = '', [switch]$NoSession, [AllowEmptyCollection()][array]$UndoStack = @())
    $newId = 'sess-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999)
    $fullSystemPrompt = Build-SystemPrompt -Root $RootPath -ConfigDir $ConfigDir
    $system = @{ role = 'system'; content = $fullSystemPrompt }
    $State.session_id = $newId
    $State.session_name = ''
    $State.parent_session = ''
    $State.workspace = $RootPath
    $State.model = $Model
    $State.messages = @($system)
    $State.tree_entries = @()
    $State.leaf_id = $null
    $State.todos = @()
    $State.usage_input_tokens = 0
    $State.usage_output_tokens = 0
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
    $State.scoped_instr_cache = @{}
    $State.step_limit_reached = $false
    $State.loop_detected = $false
    $State.last_failed_question = ''
    $script:ActiveSessionTodos = @()
    Reset-AgentSessionApprovals -State $State
    Clear-AgentUndoBackups -UndoEntries $UndoStack
    $sessionFile = if ($NoSession) { '' } else { Join-Path $SessionDir ($newId + '.jsonl') }
    $script:ActiveSessionId = $newId
    $script:ActiveSessionFile = $sessionFile
    Write-Host ($script:Gm.Grey1 + '  Started a new conversation session.' + $script:Gm.Reset)
    return @{ state = $State; system = $system; full_system_prompt = $fullSystemPrompt; session_file = $sessionFile; undo_stack = @() }
}

function Invoke-ReplTodoCommand {
    param($State, [string]$TodoArg = '')
    $sub = if ($TodoArg) { $TodoArg.Trim().ToLower() } else { '' }
    if ($sub -eq 'clear') {
        $script:ActiveSessionTodos = @()
        if ($State) { $State.todos = @() }
        Write-Host ($script:Gm.Grey1 + '  Cleared active todo list.' + $script:Gm.Reset)
        return
    }
    $currTodos = @(if ($script:ActiveSessionTodos -and @($script:ActiveSessionTodos).Count -gt 0) { @($script:ActiveSessionTodos) } elseif ($State -and $State.todos -and @($State.todos).Count -gt 0) { @($State.todos) })
    if ($currTodos.Count -gt 0) {
        Write-TodoCard -Todos $currTodos
    }
    else {
        Write-Host ($script:Gm.Grey1 + '  No active tasks in todo list.' + $script:Gm.Reset)
    }
}

function Invoke-ReplNameCommand {
    param($State, [string]$SessionFile = '', [string]$RootPath, [string]$Model = '', [string]$NameArg = '')
    $trimmedName = if ($NameArg) { $NameArg.Trim() } else { '' }
    if ($trimmedName) {
        $State.session_name = $trimmedName
        Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
        Write-Host ($script:Gm.Green + "  Session name set to: $($State.session_name)" + $script:Gm.Reset)
    }
    else {
        $nm = if ($State.session_name) { $State.session_name } else { '(unnamed)' }
        Write-Host ($script:Gm.Aqua + "  Session name: $nm (use /name <text> to set)" + $script:Gm.Reset)
    }
}

function Invoke-ReplTreeCommand {
    param($State, [string]$SessionFile = '', [string]$RootPath, [string]$Model = '', [AllowEmptyCollection()][array]$UndoStack = @(), [string]$TargetEntryId = '')
    $targetId = if ($TargetEntryId) { $TargetEntryId.Trim() } else { '' }
    if ($targetId) {
        try {
            Switch-SessionBranch -State $State -TargetId $targetId | Out-Null
            Clear-AgentUndoBackups -UndoEntries $UndoStack
            $UndoStack = @()
            Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
            Write-Host ($script:Gm.Green + "  Switched active branch to entry $targetId ($($State.messages.Count) messages in active path)." + $script:Gm.Reset)
        }
        catch {
            Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
        }
    }
    else {
        foreach ($tLn in @(Format-TuiTreeCard -State $State)) {
            Write-Host $tLn
        }
    }
    return @{ state = $State; undo_stack = @($UndoStack) }
}

function Invoke-ReplForkCommand {
    param($State, [string]$SessionDir, [string]$SessionFile = '', [switch]$NoSession, [AllowEmptyCollection()][array]$UndoStack = @(), [string]$ForkEntryId = '')
    $entryId = if ($ForkEntryId) { $ForkEntryId.Trim() } else { '' }
    try {
        $forkRes = Invoke-SessionFork -State $State -SessionDir $SessionDir -EntryId $entryId -NoSession:$NoSession
        $State = $forkRes.state
        $SessionFile = if ($NoSession) { '' } else { $forkRes.session_file }
        Clear-AgentUndoBackups -UndoEntries $UndoStack
        $UndoStack = @()
        Reset-AgentSessionApprovals -State $State
        Write-Host ($script:Gm.Green + "  Forked session to: $($forkRes.session_file) (id=$($forkRes.session_id))" + $script:Gm.Reset)
    }
    catch {
        Write-Host ($script:Gm.Red + '  Fork failed: ' + $_.Exception.Message + $script:Gm.Reset)
    }
    return @{ state = $State; session_file = $SessionFile; undo_stack = @($UndoStack) }
}

function Invoke-ReplExportCommand {
    param($State, [string]$RootPath, [string]$Model = '', [string]$ExportArg = '')
    $expArg = if ($ExportArg) { $ExportArg.Trim() } else { '' }
    try {
        if (-not $expArg) {
            $baseName = if ($State.session_id) { [string]$State.session_id } else { 'session-export' }
            $expArg = Join-Path $RootPath ($baseName + '.html')
        }
        elseif ($expArg -notmatch '^([a-zA-Z]:[\\/]|[\\/])') {
            $expArg = Join-Path $RootPath $expArg
        }
        $null = Export-AgentSessionOutput -State $State -ExportPath $expArg -RootPath $RootPath -Model $Model -Indent '  '
    }
    catch {
        Write-Host ($script:Gm.Red + '  Export failed: ' + $_.Exception.Message + $script:Gm.Reset)
    }
}

function Invoke-ReplImportCommand {
    param($State, [string]$RootPath, [string]$SessionFile = '', [string]$Model = '', [switch]$NoSession, [AllowEmptyCollection()][array]$UndoStack = @(), [string]$LastFailedQuestion = '', [string]$ImportArg = '')
    $impArg = if ($ImportArg) { $ImportArg.Trim() } else { '' }
    if (-not $impArg) {
        Write-Host ($script:Gm.Red + '  Usage: /import <path-to-session.jsonl>' + $script:Gm.Reset)
        return @{ state = $State; session_file = $SessionFile; model = $Model; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
    }
    $impPath = if (Test-Path -LiteralPath $impArg) { $impArg } else { Join-Path $RootPath $impArg }
    if (-not (Test-Path -LiteralPath $impPath)) {
        Write-Host ($script:Gm.Red + "  File not found: $impArg" + $script:Gm.Reset)
        return @{ state = $State; session_file = $SessionFile; model = $Model; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
    }
    try {
        Invoke-SessionResume -SessionFile $impPath -State $State -CurrentWorkspace $RootPath | Out-Null
        $SessionFile = if ($NoSession) { '' } else { $impPath }
        if ($NoSession) { $script:ActiveSessionFile = '' }
        Clear-AgentUndoBackups -UndoEntries $UndoStack
        $UndoStack = @()
        $LastFailedQuestion = ''
        if ($State.model) { $Model = $State.model }
        Reset-AgentSessionApprovals -State $State
        Write-Host ($script:Gm.Green + "  Imported session: $impPath ($($State.messages.Count) messages)" + $script:Gm.Reset)
    }
    catch {
        Write-Host ($script:Gm.Red + '  Import failed: ' + $_.Exception.Message + $script:Gm.Reset)
    }
    return @{ state = $State; session_file = $SessionFile; model = $Model; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
}

function Invoke-ReplCopyCommand {
    param($State)
    $lastAssistant = $null
    for ($i = $State.messages.Count - 1; $i -ge 0; $i--) {
        if ($State.messages[$i].role -eq 'assistant' -and $State.messages[$i].content) {
            $lastAssistant = [string]$State.messages[$i].content
            break
        }
    }
    if (-not $lastAssistant) {
        Write-Host ($script:Gm.Grey1 + '  No assistant message to copy.' + $script:Gm.Reset)
        return
    }
    try {
        Set-Clipboard -Value $lastAssistant -ErrorAction Stop
        Write-Host ($script:Gm.Green + "  Copied last assistant response ($($lastAssistant.Length) chars) to clipboard." + $script:Gm.Reset)
    }
    catch {
        Write-Host ($script:Gm.Red + '  Clipboard copy failed: ' + $_.Exception.Message + $script:Gm.Reset)
    }
}

function Invoke-ReplReloadCommand {
    param($State, $SystemMessage, [string]$RootPath, [string]$ConfigDir = '')
    $State.scoped_instr_cache = @{}
    $fullSystemPrompt = Build-SystemPrompt -Root $RootPath -ConfigDir $ConfigDir
    $SystemMessage.content = $fullSystemPrompt
    if ($State.messages.Count -gt 0 -and $State.messages[0].role -eq 'system') {
        $State.messages[0].content = $fullSystemPrompt
    }
    Sync-AgentCapabilities -State $State | Out-Null
    Write-Host ($script:Gm.Green + '  Reloaded context files (AGENTS.md, SOUL.md, MEMORY.md, SYSTEM.md), skills, and templates.' + $script:Gm.Reset)
    return @{ state = $State; system = $SystemMessage; full_system_prompt = $fullSystemPrompt }
}

function Invoke-ReplSaveCommand {
    param($State, [string]$SessionDir, [string]$SessionFile = '', [string]$RootPath, [string]$Model = '', [string]$SaveArg = '')
    if ($SaveArg -and $SaveArg.Trim()) {
        $nameArg = $SaveArg.Trim()
        if ($nameArg -notmatch '\.jsonl$') { $nameArg += '.jsonl' }
        $SessionFile = Join-Path $SessionDir (Split-Path $nameArg -Leaf)
    }
    Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
    Write-Host ($script:Gm.Green + "  Saved session: $SessionFile" + $script:Gm.Reset)
    return @{ session_file = $SessionFile }
}

function Invoke-ReplUndoCommand {
    param($State, [string]$SessionFile = '', [string]$RootPath, [string]$Model = '', [AllowEmptyCollection()][array]$UndoStack = @())
    if ($UndoStack.Count -eq 0) {
        Write-Host ($script:Gm.Grey1 + '  Nothing to undo.' + $script:Gm.Reset)
        return @{ state = $State; undo_stack = @() }
    }
    $lastUndo = $UndoStack[$UndoStack.Count - 1]
    try {
        Invoke-AgentUndo -State $State -UndoEntry $lastUndo
        if ($UndoStack.Count -eq 1) { $UndoStack = @() }
        else { $UndoStack = @($UndoStack[0..($UndoStack.Count - 2)]) }
        Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
        Write-Host ($script:Gm.Green + '  Reverted last turn and restored disk state.' + $script:Gm.Reset)
    }
    catch {
        Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
    }
    return @{ state = $State; undo_stack = @($UndoStack) }
}

function Invoke-ReplModelCommand {
    param($State, [string]$CurrentModel, [string]$SessionDir, [string]$NewModel = '', [string]$SessionFile = '', [string]$RootPath)
    $reqModel = if ($NewModel) { $NewModel.Trim() } else { '' }
    $selectedModel = Select-ReplModelId -CurrentModel $CurrentModel -SessionDir $SessionDir -NewModel $reqModel
    if ($selectedModel) {
        $CurrentModel = $selectedModel
        $State.model = $CurrentModel
        $script:ActiveModelId = $CurrentModel
        if ($SessionFile) {
            Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $CurrentModel
        }
        if ($script:AgentConfigPath) {
            $null = Update-AgentConfigOptionalKey -Path $script:AgentConfigPath -Key 'SHELLOSSUS_MODEL' -Value $CurrentModel
        }
        Write-Host ($script:Gm.Green + "  Model switched to: $CurrentModel" + $script:Gm.Reset)
    }
    return $CurrentModel
}

function Invoke-ReplCompactCommand {
    param($State, [string]$Endpoint, [string]$Model, [string]$ApiKey, [string]$SessionFile = '', [string]$RootPath, [string]$Focus = '')
    $trimmedFocus = if ($Focus) { $Focus.Trim() } else { '' }
    try {
        if (Invoke-AgentCompact -State $State -Endpoint $Endpoint -ModelId $Model -ApiKey $ApiKey -Focus $trimmedFocus) {
            Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
            $st = Get-ContextStats -State $State
            Write-Host ($script:Gm.Green + "  Context compacted (~$($st.est_tokens) tokens remaining)." + $script:Gm.Reset)
        }
        else {
            Write-Host ($script:Gm.Grey1 + '  Not enough history to compact yet.' + $script:Gm.Reset)
        }
    }
    catch {
        Write-Host ($script:Gm.Red + '  Compaction failed: ' + (Format-AgentError -ErrorRecord $_) + $script:Gm.Reset)
    }
}

function Invoke-ReplSessionsCommand {
    param($State, [string]$SessionDir, [string]$SessionFile = '', [string]$RootPath, [string]$Model = '', [AllowEmptyCollection()][array]$UndoStack = @(), [string]$LastFailedQuestion = '', [string]$ResumeArg = '', [switch]$NoSession)
    $arg = if ($ResumeArg) { $ResumeArg.Trim() } else { '' }
    if (-not (Test-Path -LiteralPath $SessionDir)) {
        Write-Host ($script:Gm.Grey1 + '  No saved sessions found.' + $script:Gm.Reset)
        return @{ state = $State; session_file = $SessionFile; model = $Model; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
    }
    $wsNorm = $RootPath.TrimEnd('\').TrimEnd('/')
    $list = @(Get-ChildItem -LiteralPath $SessionDir -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending | Where-Object {
        $m = Get-AgentSessionMeta -SessionFile $_.FullName
        (-not $m) -or (-not $m.workspace) -or ($m.workspace.TrimEnd('\').TrimEnd('/') -ieq $wsNorm)
    } | Select-Object -First 15)
    if ($list.Count -eq 0) {
        Write-Host ($script:Gm.Grey1 + '  No saved sessions for this workspace.' + $script:Gm.Reset)
        return @{ state = $State; session_file = $SessionFile; model = $Model; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
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
                label       = $list[$i].Name
                value       = $list[$i].FullName
                description = $desc
                active      = ($SessionFile -and ($list[$i].FullName -ieq $SessionFile))
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
        $cand = Join-Path $SessionDir (Split-Path $arg -Leaf)
        if (Test-Path -LiteralPath $cand) { $chosen = $cand }
        elseif (-not ($arg -match '\.jsonl$')) {
            $candJsonl = Join-Path $SessionDir ((Split-Path $arg -Leaf) + '.jsonl')
            if (Test-Path -LiteralPath $candJsonl) { $chosen = $candJsonl }
        }
    }
    if ($chosen) {
        try {
            Invoke-SessionResume -SessionFile $chosen -State $State -CurrentWorkspace $RootPath | Out-Null
            $SessionFile = if ($NoSession) { '' } else { $chosen }
            if ($NoSession) { $script:ActiveSessionFile = '' }
            Clear-AgentUndoBackups -UndoEntries $UndoStack
            $UndoStack = @()
            $LastFailedQuestion = ''
            if ($State.model) { $Model = $State.model }
            Reset-AgentSessionApprovals -State $State
            Write-Host ($script:Gm.Green + "  Resumed session: $chosen ($($State.messages.Count) messages, model=$Model, permission=$($script:AgentPermission))" + $script:Gm.Reset)
        }
        catch {
            Write-Host ($script:Gm.Red + '  ' + $_.Exception.Message + $script:Gm.Reset)
        }
    }
    elseif ($arg) {
        Write-Host ($script:Gm.Red + "  Session not found: $arg" + $script:Gm.Reset)
    }
    return @{ state = $State; session_file = $SessionFile; model = $Model; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
}

function Invoke-ReplContinueCommand {
    param($State, [string]$Endpoint, [string]$Model, [string]$ApiKey, [string]$RootPath, [string]$SessionFile = '', [int]$MaxSteps = 50, [AllowEmptyCollection()][array]$UndoStack = @(), [string]$LastFailedQuestion = '', [string]$ContinueArg = '')
    $contSteps = $MaxSteps
    if ($ContinueArg -and $ContinueArg.Trim()) {
        $rawSteps = $ContinueArg.Trim()
        if ($rawSteps -notmatch '^\d+$') {
            Write-Host ($script:Gm.Red + '  Usage: /continue [steps]' + $script:Gm.Reset)
            return @{ state = $State; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
        }
        $contSteps = [int]$rawSteps
        if ($contSteps -lt 1 -or $contSteps -gt 500) {
            Write-Host ($script:Gm.Red + '  Steps must be between 1 and 500.' + $script:Gm.Reset)
            return @{ state = $State; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
        }
    }
    $nonSys = @($State.messages | Where-Object { $_.role -ne 'system' })
    if ($nonSys.Count -eq 0) {
        Write-Host ($script:Gm.Grey1 + '  Nothing to continue.' + $script:Gm.Reset)
        return @{ state = $State; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
    }
    Ensure-SessionTree -State $State
    $turnSnapshot = New-AgentTurnSnapshot -State $State
    $null = Invoke-ThresholdAutoCompact -State $State -Endpoint $Endpoint -ModelId $Model -ApiKey $ApiKey
    $script:CurrentTurnWrites = @()
    Write-Host ($script:Gm.Aqua + "  [continue] Continuing agent turn (up to $contSteps steps)..." + $script:Gm.Reset)
    try {
        Invoke-AgentContinue -State $State -Endpoint $Endpoint -ModelId $Model -ApiKey $ApiKey -Root $RootPath -Steps $contSteps | Out-Null
        $LastFailedQuestion = ''
        $UndoStack += @{ messages = $turnSnapshot.messages; leaf_id = $turnSnapshot.leaf_id; tree_entries = $turnSnapshot.tree_entries; writes = @($script:CurrentTurnWrites) }
        Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
    }
    catch {
        $requestErr = Format-AgentError -ErrorRecord $_
        $rollback = Invoke-AgentTurnRollback -State $State -Snapshot $turnSnapshot -Writes @($script:CurrentTurnWrites) -UndoStack $UndoStack
        $UndoStack = @($rollback.undo_stack)
        if ($rollback.succeeded) {
            Write-Host ($script:Gm.Red + 'Continue failed; turn rolled back: ' + $requestErr + $script:Gm.Reset)
        }
        else {
            Write-Host ($script:Gm.Red + 'Continue failed; rollback did not succeed: ' + $rollback.error + $script:Gm.Reset)
        }
    }
    return @{ state = $State; undo_stack = @($UndoStack); last_failed_question = $LastFailedQuestion }
}

function Invoke-ReplBangCommand {
    param($State, [string]$InputText, [string]$RootPath, [string]$SessionFile = '', [string]$Model = '')
    $localOnly = $InputText.StartsWith('!!')
    $cmdStr = if ($localOnly) { $InputText.Substring(2).Trim() } else { $InputText.Substring(1).Trim() }
    if (-not $cmdStr) { return }
    try {
        $res = Invoke-ShellCommand -Root $RootPath -Command $cmdStr
        if ($res.output) { Write-Host ($script:Gm.Fg + $res.output + $script:Gm.Reset) }
        Write-Host ($script:Gm.Grey1 + "  [exit $($res.exit_code)]" + $script:Gm.Reset)
        if (-not $localOnly) {
            $State.messages += @{ role = 'user'; content = ("[Shell command $cmdStr exit=$($res.exit_code)]`n" + $res.output) }
            Ensure-SessionTree -State $State
            Save-AgentSession -SessionFile $SessionFile -State $State -Workspace $RootPath -Model $Model
            Write-Host ($script:Gm.Aqua + '  (Output added to conversation context)' + $script:Gm.Reset)
        }
    }
    catch {
        Write-Host ($script:Gm.Red + '  Command error: ' + $_.Exception.Message + $script:Gm.Reset)
    }
}
