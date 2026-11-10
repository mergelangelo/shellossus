# Interactive REPL command aliases, TUI dashboard/tree/help cards, and REPL command helpers.

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
    if ($t -match '^/th(?:\s+(.+))?$') {
        return $(if ($Matches[1]) { '/theme ' + $Matches[1] } else { '/theme' })
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
    $body = @(
        ($script:Gm.Grey1 + 'Model:       ' + $script:Gm.Fg1 + (Format-TuiText $Model) + $script:Gm.Grey1 + " (reasoning: view=$($script:ShowReasoning), effort=$effLabel)" + $script:Gm.Reset),
        ($script:Gm.Grey1 + 'Permission:  ' + (Format-PermissionBadge -Permission $script:AgentPermission) + $script:Gm.Grey1 + " | Theme: $($script:ActiveTheme) | MaxSteps: $MaxSteps | Undo stack: $UndoCount" + $script:Gm.Reset),
        ($script:Gm.Grey1 + 'Context:     ' + (Format-ContextGauge -Tokens $st.est_tokens -MaxTokens $st.context_window_tokens -CompactTokens $st.compact_threshold_tokens -Width 12) + $script:Gm.Grey1 + " | Auto-compact: $compLabel | Msgs: $($st.messages)" + $script:Gm.Reset),
        ($script:Gm.Grey1 + 'API Tokens:  ' + $script:Gm.Aqua + "in=$inTok out=$outTok" + $script:Gm.Grey1 + " (total=$(Format-TokenCount -Tokens ($inTok + $outTok)))" + $script:Gm.Reset),
        ($script:Gm.Grey1 + 'Session:     ' + $script:Gm.Fg + "$(Format-TuiText $State.session_id) " + $script:Gm.Grey1 + "| Name: $(Format-TuiText $nmInfo) | Leaf: $(Format-TuiText $leafInfo)" + $script:Gm.Reset),
        ($script:Gm.Grey1 + 'File:        ' + $script:Gm.Grey2 + (Format-TuiText $sessFileStr) + $script:Gm.Reset),
        ($script:Gm.Grey1 + 'Tools:       ' + $script:Gm.Aqua + $toolsStr + $script:Gm.Reset)
    )
    $tdList = @(if ($script:ActiveSessionTodos -and @($script:ActiveSessionTodos).Count -gt 0) { @($script:ActiveSessionTodos) } elseif ($State -and $State.todos -and @($State.todos).Count -gt 0) { @($State.todos) })
    if ($tdList.Count -gt 0) {
        $tDone = @($tdList | Where-Object { $_.status -eq 'completed' }).Count
        $tTot = $tdList.Count
        $body += ($script:Gm.Grey1 + 'Tasks (Todo): ' + $script:Gm.BoldAqua + "$tDone/$tTot completed" + $script:Gm.Reset)
    }
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
}

function Format-TuiTreeCard {
    param($State)
    $w = Get-TerminalWidth
    $treeNodes = @(Get-SessionTree -State $State)
    $hdr = ' ' + $script:Gm.BoldOrange + 'Conversation Tree' + $script:Gm.Reset + ' '
    $body = @()
    if ($treeNodes.Count -eq 0) {
        $body += ($script:Gm.Grey1 + 'Session tree is empty.' + $script:Gm.Reset)
    }
    else {
        foreach ($node in $treeNodes) {
            $marker = if ($node.is_leaf) { $script:Box.Dot } elseif ($node.active) { $script:Box.Arrow } else { '-' }
            $parentInfo = if ($node.parent_id) { " <- $(Format-TuiText $node.parent_id)" } else { ' (root)' }
            $color = if ($node.is_leaf) { $script:Gm.BoldGreen } elseif ($node.active) { $script:Gm.Aqua } else { $script:Gm.Grey1 }
            $body += ($color + ("{0} [{1}] ({2}{3}) " -f $marker, (Format-TuiText $node.id), (Format-TuiText $node.role), $parentInfo) + $script:Gm.Fg + (Format-TuiText $node.preview) + $script:Gm.Reset)
        }
        $body += ($script:Gm.Grey1 + '(Use /tree <entry-id> to switch branch, or /fork <entry-id> to fork)' + $script:Gm.Reset)
    }
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
}

function Format-TuiHelpCard {
    $w = Get-TerminalWidth
    $hdr = ' ' + $script:Gm.BoldOrange + 'Shellossus TUI Commands & Shortcuts' + $script:Gm.Reset + ' '
    $body = @(
        ($script:Gm.BoldYellow + 'Mode & Model (call without args for interactive picker)' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /permission (/p) [mode]      ' + $script:Gm.Fg + 'Pick or set: ReadOnly|Ask|AutoEdit|Auto' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /model (/m) [id]             ' + $script:Gm.Fg + 'Pick or switch active model ID' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /theme (/th) [name]          ' + $script:Gm.Fg + 'Pick or switch TUI color theme' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /context (/ctx) [win] [comp] ' + $script:Gm.Fg + 'Set context window & compact threshold' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /reasoning [arg]             ' + $script:Gm.Fg + 'Set view (compact|full|hide) or effort' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /status (/s, /tokens)        ' + $script:Gm.Fg + 'Show status dashboard, context & tokens' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /diagnostics [on|off]        ' + $script:Gm.Fg + 'Toggle capability/tool diagnostics' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /doctor                      ' + $script:Gm.Fg + 'Check runtime, config, endpoint & storage' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /mascot                      ' + $script:Gm.Fg + 'Display the Shellossus pixel mascot' + $script:Gm.Reset),
        ($script:Gm.BoldYellow + 'History, Undo & Compaction' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /todo (/td) [clear]          ' + $script:Gm.Fg + 'View or clear active task plan checklist' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /memory (/mem) [ws|global] ..' + $script:Gm.Fg + 'View, add, set, or clear agent memory' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /undo (/u)                   ' + $script:Gm.Fg + 'Revert last turn and its file changes' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /retry                       ' + $script:Gm.Fg + 'Retry the last failed user request' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /continue [steps]            ' + $script:Gm.Fg + 'Continue after step limit or last reply' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /compact (/c) [focus]        ' + $script:Gm.Fg + 'Summarize older turns into a handoff' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /copy                        ' + $script:Gm.Fg + 'Copy last assistant response to clipboard' + $script:Gm.Reset),
        ($script:Gm.BoldYellow + 'Sessions & Branch Tree' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /sessions                    ' + $script:Gm.Fg + 'Browse and resume workspace sessions' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /resume (/r) [num|name]      ' + $script:Gm.Fg + 'Resume saved session (picker when no arg)' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /tree (/t) [entry-id]        ' + $script:Gm.Fg + 'View session tree or switch active branch' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /fork [entry-id] (/clone)    ' + $script:Gm.Fg + 'Fork current branch into a new session' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /name [name] | /save [name]  ' + $script:Gm.Fg + 'Name or save current session' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /export [path] | /import <p> ' + $script:Gm.Fg + 'Export HTML/JSONL or import JSONL session' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /new (/clear) | /exit (/q)   ' + $script:Gm.Fg + 'Start a fresh session or exit shellossus' + $script:Gm.Reset),
        ($script:Gm.BoldYellow + 'Delegation, Skills & Input Syntax' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /agents | /agent:<role> <q>  ' + $script:Gm.Fg + 'List or run subagents (recon|audit|craft)' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /skills | /skill:<name> [a]  ' + $script:Gm.Fg + 'List or invoke a SKILL.md skill directly' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  /<template> [args] | /reload ' + $script:Gm.Fg + 'Run prompt template or reload context' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  @path/to/file                ' + $script:Gm.Fg + 'Inline-attach workspace file into prompt' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  !cmd / !!cmd                 ' + $script:Gm.Fg + 'Run directly (! adds output, !! local)' + $script:Gm.Reset),
        ($script:Gm.Aqua + '  """ ... """ or trailing \    ' + $script:Gm.Fg + 'Multi-line prompt input block' + $script:Gm.Reset)
    )
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
}

function Write-TuiHelpCard {
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-TuiHelpCard)) {
        Write-Host $ln
    }
}

function Write-TuiStartupBanner {
    param([string]$RootPath, [string]$ConfigDir, [string]$Model)
    if ($script:OutputMode -eq 'json') { return }
    $wInit = Get-TerminalWidth
    $hdrInit = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' shellossus ' + $script:Gm.Grey1 + 'inline TUI' + $script:Gm.Reset + ' '
    $ctxLoaded = @()
    if (Get-SoulContext -Root $RootPath -ConfigDir $ConfigDir) { $ctxLoaded += 'SOUL.md' }
    if (Get-MemoryContext -Root $RootPath -ConfigDir $ConfigDir) { $ctxLoaded += 'MEMORY.md' }
    if (Get-AgentsContext -Root $RootPath -ConfigDir $ConfigDir) { $ctxLoaded += 'AGENTS.md' }
    if (Get-SkillsCatalog -Root $RootPath -ConfigDir $ConfigDir) { $ctxLoaded += "skills ($($script:SkillsByName.Count))" }
    $null = Get-AgentRolesCatalog -Root $RootPath -ConfigDir $ConfigDir
    if ($script:AgentRolesByName -and $script:AgentRolesByName.Count -gt 0) { $ctxLoaded += "agents ($($script:AgentRolesByName.Count))" }
    $loadedStr = if ($ctxLoaded.Count -gt 0) { $script:Gm.Aqua + 'Loaded: ' + $script:Gm.Fg + ($ctxLoaded -join ' | ') + $script:Gm.Reset } else { $script:Gm.Grey1 + 'Workspace ready' + $script:Gm.Reset }
    $modelStr = $script:Gm.Aqua + 'Model: ' + $script:Gm.Fg + (Format-TuiText $Model) + $script:Gm.Grey1 + ' | ' + $script:Gm.Aqua + 'Mode: ' + $script:Gm.Fg + $script:AgentPermission + $script:Gm.Reset
    $shortcutsStr = $script:Gm.Grey1 + 'Shortcuts: ' + $script:Gm.Aqua + '? (/help)' + $script:Gm.Grey1 + ' | ' + $script:Gm.Aqua + '/p' + $script:Gm.Grey1 + ' mode | ' + $script:Gm.Aqua + '/m' + $script:Gm.Grey1 + ' model | ' + $script:Gm.Aqua + '/s' + $script:Gm.Grey1 + ' status | ' + $script:Gm.Aqua + '/u' + $script:Gm.Grey1 + ' undo' + $script:Gm.Reset
    $textLines = @($loadedStr, $modelStr, $shortcutsStr)

    $mascotLines = @(Get-TuiMascotLines -Mode 'compact')
    $body = @()
    if ($wInit -ge 76) {
        $mascotVisW = if ($mascotLines.Count -gt 0) { (Strip-AnsiCodes -Text $mascotLines[0]).Length } else { 10 }
        $maxBannerTextW = $wInit - $mascotVisW - 9
        for ($mIdx = 0; $mIdx -lt $mascotLines.Count; $mIdx++) {
            $mLine = $mascotLines[$mIdx]
            $rawTextLine = if ($mIdx -lt $textLines.Count) { $textLines[$mIdx] } else { '' }
            $tLine = Limit-AnsiLineToWidth -Text $rawTextLine -MaxWidth $maxBannerTextW
            $body += ('  ' + $mLine + '   ' + $tLine)
        }
    }
    else {
        if ($ctxLoaded.Count -gt 0) {
            $body += $loadedStr
        }
        $body += $shortcutsStr
    }
    $boxLines = @(Format-TuiCardBox -Header $hdrInit -BodyLines $body -Indent '' -Width $wInit)
    for ($bIdx = 0; $bIdx -lt $boxLines.Count; $bIdx++) {
        if ($bIdx -eq 0) {
            Write-Host ($script:Gm.OscInit + $boxLines[$bIdx])
        }
        else {
            Write-Host $boxLines[$bIdx]
        }
    }
}

function Write-TuiAgentsCard {
    param([string]$RootPath, [string]$ConfigDir)
    $null = Get-AgentRolesCatalog -Root $RootPath -ConfigDir $ConfigDir
    $w = Get-TerminalWidth
    $hdr = ' ' + $script:Gm.BoldOrange + 'Subagent Roles' + $script:Gm.Reset + ' '
    $body = @()
    foreach ($rKey in @($script:AgentRolesByName.Keys | Sort-Object)) {
        $rObj = $script:AgentRolesByName[$rKey]
        $srcTag = if ($rObj.builtin) { 'built-in' } else { $rObj.rel_path }
        $body += ($script:Gm.Aqua + ("{0,-12} " -f (Format-TuiText $rObj.name)) + $script:Gm.Yellow + ("[{0}; {1}] " -f (Format-TuiText $rObj.permission), (Format-TuiText $srcTag)) + $script:Gm.Fg + (Format-TuiText $rObj.description) + $script:Gm.Reset)
    }
    $body += ($script:Gm.Grey1 + '(Invoke via /agent:<role> <task> or let the model call run_agent)' + $script:Gm.Reset)
    foreach ($ln in @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)) {
        Write-Host $ln
    }
}

function Write-TuiSkillsCard {
    param([string]$RootPath, [string]$ConfigDir)
    $null = Get-SkillsCatalog -Root $RootPath -ConfigDir $ConfigDir
    $w = Get-TerminalWidth
    $hdr = ' ' + $script:Gm.BoldOrange + 'Available Skills' + $script:Gm.Reset + ' '
    $body = @()
    if (-not $script:SkillsByName -or $script:SkillsByName.Count -eq 0) {
        $body += ($script:Gm.Grey1 + 'No skills found in .shellossus/skills or ~/.shellossus/skills.' + $script:Gm.Reset)
    }
    else {
        foreach ($sKey in @($script:SkillsByName.Keys | Sort-Object)) {
            $sObj = $script:SkillsByName[$sKey]
            $body += ($script:Gm.Aqua + ("{0,-18} " -f (Format-TuiText $sObj.name)) + $script:Gm.Fg + (Format-TuiText $sObj.description) + $script:Gm.Reset)
        }
        $body += ($script:Gm.Grey1 + '(Invoke via /skill:<name> [args])' + $script:Gm.Reset)
    }
    foreach ($ln in @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)) {
        Write-Host $ln
    }
}

function Invoke-ReplMemoryCommand {
    param(
        $State,
        [string]$RootPath,
        [string]$ConfigDir = '',
        [string]$MemArg = ''
    )
    $effConfigDir = if ($ConfigDir) {
        $ConfigDir
    }
    elseif ($script:AgentConfigPath) {
        Split-Path $script:AgentConfigPath -Parent
    }
    else {
        Join-Path (Get-AgentUserRoot) '.shellossus'
    }
    $raw = if ($MemArg) { $MemArg.Trim() } else { '' }
    if ($raw -match '^(?i)all(?:\s+view)?$') {
        $null = Invoke-AgentMemory -Root $RootPath -Arguments @{ action = 'view'; scope = 'workspace'; config_dir = $effConfigDir }
        $null = Invoke-AgentMemory -Root $RootPath -Arguments @{ action = 'view'; scope = 'global'; config_dir = $effConfigDir }
        return
    }
    $scope = 'workspace'
    $rest = $raw
    if ($rest -match '^(?i)(global|g|--global|-g|workspace|ws|--workspace|-w)(?:\s+([\s\S]*))?$') {
        $scTok = $Matches[1].ToLower()
        $scope = if ($scTok -in @('global', 'g', '--global', '-g')) { 'global' } else { 'workspace' }
        $rest = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
    }
    $action = 'view'
    $content = ''
    if (-not $rest -or $rest -match '^(?i)view$') {
        $action = 'view'
    }
    elseif ($rest -match '^(?i)view\s+(global|g|--global|-g|workspace|ws|--workspace|-w)$') {
        $scTok = $Matches[1].ToLower()
        $scope = if ($scTok -in @('global', 'g', '--global', '-g')) { 'global' } else { 'workspace' }
        $action = 'view'
    }
    elseif ($rest -match '^(?i)clear(?:\s+(global|g|--global|-g|workspace|ws|--workspace|-w))?$') {
        if ($Matches[1]) {
            $scTok = $Matches[1].ToLower()
            $scope = if ($scTok -in @('global', 'g', '--global', '-g')) { 'global' } else { 'workspace' }
        }
        $action = 'clear'
    }
    elseif ($rest -match '^(?i)(?:add|append)\s+(?:(--global|-g|--workspace|-w)\s+)?([\s\S]+)$') {
        if ($Matches[1]) {
            $scTok = $Matches[1].ToLower()
            $scope = if ($scTok -in @('--global', '-g')) { 'global' } else { 'workspace' }
        }
        $action = 'append'
        $content = $Matches[2].Trim()
    }
    elseif ($rest -match '^(?i)set\s+(?:(--global|-g|--workspace|-w)\s+)?([\s\S]+)$') {
        if ($Matches[1]) {
            $scTok = $Matches[1].ToLower()
            $scope = if ($scTok -in @('--global', '-g')) { 'global' } else { 'workspace' }
        }
        $action = 'set'
        $content = $Matches[2].Trim()
    }
    else {
        Write-Host ($script:Gm.Red + '  Usage: /memory [workspace|global|all] [view | add <text> | set <text> | clear]' + $script:Gm.Reset)
        return
    }

    try {
        $callArg = @{ action = $action; scope = $scope; content = $content; config_dir = $effConfigDir; user_initiated = $true }
        $null = Invoke-AgentMemory -Root $RootPath -Arguments $callArg
        if ($action -in @('append', 'set', 'clear')) {
            Sync-AgentMemoryContext -State $State -Root $RootPath -ConfigDir $effConfigDir | Out-Null
            if ($action -eq 'clear') {
                Write-Host ($script:Gm.Grey1 + "  Cleared $scope memory." + $script:Gm.Reset)
            }
            elseif ($action -eq 'set') {
                Write-Host ($script:Gm.Green + "  Updated $scope memory." + $script:Gm.Reset)
            }
            else {
                Write-Host ($script:Gm.Green + "  Added $scope memory entry." + $script:Gm.Reset)
            }
        }
    }
    catch {
        Write-Host ($script:Gm.Red + '  ' + (Format-TuiText $_.Exception.Message) + $script:Gm.Reset)
    }
}

function Invoke-ReplPermissionCommand {
    param($State, [string]$ReqPerm = '')
    if (-not $ReqPerm) {
        $permItems = @(
            @{ label = 'ReadOnly'; value = 'ReadOnly'; description = 'Read/search only; no file writes or shell commands'; active = ($script:AgentPermission -eq 'ReadOnly') },
            @{ label = 'Ask'; value = 'Ask'; description = 'Confirm file writes, shell commands, and web requests'; active = ($script:AgentPermission -eq 'Ask') },
            @{ label = 'AutoEdit'; value = 'AutoEdit'; description = 'Auto-approve file edits. Confirm shell commands and web requests'; active = ($script:AgentPermission -eq 'AutoEdit') },
            @{ label = 'Auto'; value = 'Auto'; description = 'Auto-approve file writes, shell commands, and web requests'; active = ($script:AgentPermission -eq 'Auto') }
        )
        $pickedPerm = Invoke-TuiSelector -Title "Permission Mode (current: $($script:AgentPermission))" -Items $permItems
        if ($pickedPerm) { $ReqPerm = [string]$pickedPerm }
    }
    if ($ReqPerm) {
        $matchedPerm = @('ReadOnly', 'Ask', 'AutoEdit', 'Auto') | Where-Object { $_ -ieq $ReqPerm } | Select-Object -First 1
        if ($matchedPerm) {
            $rank = @{ ReadOnly = 0; Ask = 1; AutoEdit = 2; Auto = 3 }
            if ($matchedPerm -ne 'Auto' -and $rank[$matchedPerm] -le $rank[[string]$script:AgentPermission]) {
                $script:AutoApproveCommands = $false
                $script:AutoApproveWeb = $false
            }
            # Older turns cannot restore approvals across an explicit permission selection.
            $script:PermissionRevision++
            $script:AgentPermission = $matchedPerm
            $syncRes = Sync-AgentCapabilities -State $State -RecordTransition
            $toolsInfo = if ($syncRes.tools.Count -gt 0) { $syncRes.tools -join ', ' } else { 'none' }
            Write-Host ($script:Gm.Green + "  Permission mode set to: $($script:AgentPermission) (tools: $toolsInfo)" + $script:Gm.Reset)
        }
        else {
            Write-Host ($script:Gm.Red + '  Invalid permission mode. Choose: ReadOnly, Ask, AutoEdit, Auto' + $script:Gm.Reset)
        }
    }
}

function Invoke-ReplDiagnosticsCommand {
    param([string]$RootPath, [string]$Arg = '')
    if ($Arg) {
        $dArg = $Arg.Trim().ToLower()
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
        $capNow = Get-AgentCapabilities -Root $RootPath
        $tList = if ($capNow.tool_names.Count -gt 0) { $capNow.tool_names -join ', ' } else { 'none' }
        Write-Host ($script:Gm.Aqua + "  Diagnostics: $($script:Diagnostics) | Mode: $($capNow.permission) | Shell: $(Format-TuiText $capNow.environment.shell_exe) $(Format-TuiText $capNow.environment.shell_version) | Tools: $tList" + $script:Gm.Reset)
    }
}

function Invoke-ReplReasoningCommand {
    param([string]$ArgR = '')
    if (-not $ArgR) {
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
        if ($pickedR) { $ArgR = ([string]$pickedR).ToLower() }
    }
    if ($ArgR) {
        if ($ArgR -in @('compact', 'full', 'hide')) {
            $script:ShowReasoning = $ArgR
            Write-Host ($script:Gm.Green + "  Reasoning display set to: $($script:ShowReasoning)" + $script:Gm.Reset)
        }
        elseif ($ArgR -in @('low', 'medium', 'high')) {
            $script:ReasoningEffort = $ArgR
            Write-Host ($script:Gm.Green + "  Reasoning effort set to: $($script:ReasoningEffort)" + $script:Gm.Reset)
        }
        elseif ($ArgR -eq 'default' -or $ArgR -eq 'off') {
            $script:ReasoningEffort = ''
            Write-Host ($script:Gm.Green + '  Reasoning effort reset to provider default.' + $script:Gm.Reset)
        }
        else {
            Write-Host ($script:Gm.Red + '  Usage: /reasoning [compact|full|hide|low|medium|high|default]' + $script:Gm.Reset)
        }
    }
}

function Invoke-ReplContextCommand {
    param($State, [string]$CtxArg = '')
    if (-not $CtxArg) {
        $curSt = Get-ContextStats -State $State
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
        $pickedCtx = Invoke-TuiSelector -Title "Context Window & Auto-Compact (current: $curWinFmt / compact at $curCompFmt)" -Items $ctxItems -PromptText 'Select preset or type "<window> [compact]" (Enter cancels)' -AllowFreeText
        if ($pickedCtx -eq '__custom__') {
            Write-Host ('  ' + $script:Gm.BoldYellow + 'Enter "<window> [compact]" (e.g. 128k 80k or 128k 70%): ' + $script:Gm.Fg) -NoNewline
            $customCtx = Read-Host
            Write-Host $script:Gm.Reset -NoNewline
            if ($customCtx -and $customCtx.Trim()) { $CtxArg = $customCtx.Trim() }
        }
        elseif ($pickedCtx) {
            $CtxArg = [string]$pickedCtx
        }
    }
    if ($CtxArg) {
        try {
            $tokensParts = @($CtxArg -split '\s+' | Where-Object { $_ })
            $limRes = if ($tokensParts.Count -ge 2 -and ($tokensParts[0] -ieq 'compact' -or $tokensParts[0] -ieq 'threshold')) {
                Set-AgentContextLimits -CompactSpec $tokensParts[1]
            }
            elseif ($tokensParts.Count -ge 2) {
                Set-AgentContextLimits -WindowSpec $tokensParts[0] -CompactSpec $tokensParts[1]
            }
            else {
                Set-AgentContextLimits -WindowSpec $tokensParts[0]
            }
            if ($script:AgentConfigPath) {
                $null = Update-AgentConfigOptionalKey -Path $script:AgentConfigPath -Key 'SHELLOSSUS_CONTEXT_WINDOW' -Value "$($limRes.context_window_tokens)"
                $null = Update-AgentConfigOptionalKey -Path $script:AgentConfigPath -Key 'SHELLOSSUS_COMPACT_THRESHOLD' -Value "$($limRes.compact_threshold_tokens)"
            }
            $wFmt = Format-TokenCount -Tokens $limRes.context_window_tokens
            $cFmt = Format-TokenCount -Tokens $limRes.compact_threshold_tokens
            Write-Host ($script:Gm.Green + "  Context window set to $wFmt tokens | Auto-compact threshold: $cFmt ($($limRes.compact_pct)%)" + $script:Gm.Reset)
        }
        catch {
            Write-Host ($script:Gm.Red + '  ' + (Format-TuiText $_.Exception.Message) + $script:Gm.Reset)
        }
    }
}

function Select-ReplModelId {
    param([string]$CurrentModel, [string]$SessionDir, [string]$NewModel = '')
    if (-not $NewModel) {
        $knownModels = @($CurrentModel)
        if (Test-Path -LiteralPath $SessionDir) {
            foreach ($sf in @(Get-ChildItem -LiteralPath $SessionDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15)) {
                $mMeta = Get-AgentSessionMeta -SessionFile $sf.FullName
                if ($mMeta -and $mMeta.model -and ($knownModels -notcontains [string]$mMeta.model)) {
                    $knownModels += [string]$mMeta.model
                }
            }
        }
        $mItems = @()
        foreach ($km in $knownModels) {
            $mItems += @{ label = $km; value = $km; description = $(if ($km -eq $CurrentModel) { 'active model' } else { 'recent session model' }); active = ($km -eq $CurrentModel) }
        }
        $mItems += @{ label = '[Custom model ID...]'; value = '__custom__'; description = 'Type any OpenAI-compatible model ID'; active = $false }
        $pickedM = Invoke-TuiSelector -Title "Select Model (current: $CurrentModel)" -Items $mItems -PromptText 'Select number or type model ID (Enter cancels)' -AllowFreeText
        if ($pickedM -eq '__custom__') {
            Write-Host ('  ' + $script:Gm.BoldYellow + 'Enter model ID: ' + $script:Gm.Fg) -NoNewline
            $customM = Read-Host
            Write-Host $script:Gm.Reset -NoNewline
            if ($customM -and $customM.Trim()) { $NewModel = $customM.Trim() }
        }
        elseif ($pickedM) {
            $NewModel = [string]$pickedM
        }
    }
    return $NewModel
}

function Invoke-ReplThemeCommand {
    param([string]$ThemeArg = '')
    if (-not $ThemeArg) {
        $catalog = @(Get-AgentThemesCatalog)
        $tItems = @()
        foreach ($th in $catalog) {
            $tItems += @{
                label       = "$($th.id) ($($th.label))"
                value       = $th.id
                description = $th.description
                active      = ($th.id -eq $script:ActiveTheme)
            }
        }
        $pickedTheme = Invoke-TuiSelector -Title "Color Theme (current: $($script:ActiveTheme))" -Items $tItems
        if ($pickedTheme) { $ThemeArg = [string]$pickedTheme }
    }
    if ($ThemeArg) {
        try {
            $applied = Set-AgentTheme -Name $ThemeArg
            if ($script:OutputMode -ne 'json') {
                Write-Host $script:Gm.OscInit -NoNewline
            }
            if ($script:AgentConfigPath) {
                $null = Update-AgentConfigOptionalKey -Path $script:AgentConfigPath -Key 'SHELLOSSUS_THEME' -Value $applied.id
            }
            Write-Host ($script:Gm.Green + "  Theme set to: $($applied.id) ($($applied.label))" + $script:Gm.Reset)
        }
        catch {
            Write-Host ($script:Gm.Red + '  ' + (Format-TuiText $_.Exception.Message) + $script:Gm.Reset)
        }
    }
}
