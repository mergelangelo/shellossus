# JSONL session persistence, metadata lookup, resume/fork lifecycle, and standalone HTML export.

function Test-CapabilityNoteInsideOpenToolCalls {
    param([array]$Messages, [int]$NoteIndex)
    $msgs = @($Messages)
    if ($NoteIndex -lt 0 -or $NoteIndex -ge $msgs.Count) { return $false }
    $pending = $null
    for ($i = 0; $i -le $NoteIndex; $i++) {
        if ($i -eq $NoteIndex) {
            return ($null -ne $pending -and $pending.Count -gt 0)
        }
        $m = $msgs[$i]
        if ($null -ne $pending) {
            if ($m.role -eq 'tool' -and $m.tool_call_id) {
                $answeredId = [string]$m.tool_call_id
                if ($pending.ContainsKey($answeredId)) { $pending.Remove($answeredId) | Out-Null }
                if ($pending.Count -eq 0) { $pending = $null }
            }
            continue
        }
        if ($m.role -eq 'assistant' -and $m.tool_calls -and @($m.tool_calls).Count -gt 0) {
            $pending = @{}
            foreach ($tc in @($m.tool_calls)) {
                if ($tc -and $tc.id) { $pending[[string]$tc.id] = $true }
            }
            if ($pending.Count -eq 0) { $pending = $null }
        }
    }
    return $false
}

function Save-AgentSession {
    param([string]$SessionFile, $State, [string]$Workspace = '', [string]$Model = '', [string]$SessionId = '')
    if (-not $SessionFile) { return }
    $parent = Split-Path $SessionFile -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Ensure-SessionTree -State $State
    $sid = if ($SessionId) { $SessionId } elseif ($State.session_id) { [string]$State.session_id } else { 'sess-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999) }
    $ws = if ($Workspace) { $Workspace } elseif ($State.workspace) { [string]$State.workspace } else { '' }
    if ($ws -and (Test-Path -LiteralPath $ws)) { $ws = (Get-Item -LiteralPath $ws -Force).FullName }
    $mdl = if ($Model) { $Model } elseif ($State.model) { [string]$State.model } else { '' }
    $sName = if ($State.session_name) { [string]$State.session_name } else { '' }
    $parentSess = if ($State.parent_session) { [string]$State.parent_session } else { '' }
    $State.session_id = $sid
    $State.workspace = $ws
    $State.model = $mdl
    $script:ActiveSessionId = $sid
    $script:ActiveSessionFile = $SessionFile
    $script:ActiveModelId = $mdl
    $meta = @{
        type = 'session_meta'
        version = 1
        id = $sid
        name = $sName
        workspace = $ws
        model = $mdl
        parent_session = $parentSess
        leaf_id = $State.leaf_id
        updated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    }
    if ($script:ActiveSessionTodos -and $script:ActiveSessionTodos.Count -gt 0) {
        $meta.todos = @($script:ActiveSessionTodos)
    }
    elseif ($State -and $State.todos -and $State.todos.Count -gt 0) {
        $meta.todos = @($State.todos)
    }
    $lines = @($meta | ConvertTo-Json -Depth 5 -Compress)
    $activeIds = @{}
    $sessionMessages = @($State.messages)
    for ($mi = 0; $mi -lt $sessionMessages.Count; $mi++) {
        $m = $sessionMessages[$mi]
        $isCapNote = ($m.role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Capability State Change]'))
        if ($isCapNote -and (Test-CapabilityNoteInsideOpenToolCalls -Messages $sessionMessages -NoteIndex $mi)) {
            continue
        }
        if ($m.id) { $activeIds[[string]$m.id] = $true }
        $lines += ($m | ConvertTo-Json -Depth 20 -Compress)
    }
    foreach ($te in @($State.tree_entries)) {
        if ($te -and $te.id -and -not $activeIds.ContainsKey([string]$te.id)) {
            $bEntry = @{
                type = 'branch_entry'
                id = [string]$te.id
                parent_id = $te.parent_id
                role = [string]$te.role
                content = $te.content
            }
            Copy-MessageOptionalFields -Source $te -Target $bEntry
            $lines += ($bEntry | ConvertTo-Json -Depth 20 -Compress)
        }
    }
    $parentDir = if ($parent) { $parent } else { (Get-Location).Path }
    $tempPath = Join-Path $parentDir ('.session-tmp-' + $PID + '-' + (Get-Random -Minimum 100000 -Maximum 999999) + '.jsonl')
    try {
        Set-Content -LiteralPath $tempPath -Value $lines -Encoding UTF8 -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $tempPath)) {
            throw "Failed to stage session file: $tempPath"
        }
        Move-Item -LiteralPath $tempPath -Destination $SessionFile -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AgentSessionMeta {
    param([string]$SessionFile)
    if (-not (Test-Path -LiteralPath $SessionFile)) { return $null }
    foreach ($line in @(Get-Content -LiteralPath $SessionFile -TotalCount 5 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        try {
            $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
            if ($obj.type -eq 'session_meta') {
                $resolvedName = if ($obj.name) { [string]$obj.name } elseif ($obj.session_name) { [string]$obj.session_name } else { '' }
                return @{
                    version = [int]$obj.version
                    id = [string]$obj.id
                    name = $resolvedName
                    session_name = $resolvedName
                    workspace = [string]$obj.workspace
                    model = [string]$obj.model
                    parent_session = if ($obj.parent_session) { [string]$obj.parent_session } else { '' }
                    leaf_id = if ($obj.leaf_id) { [string]$obj.leaf_id } else { '' }
                    updated_at = [string]$obj.updated_at
                }
            }
        }
        catch {}
        break
    }
    return $null
}

function Read-AgentSession {
    param([string]$SessionFile, $State = $null)
    if (-not (Test-Path -LiteralPath $SessionFile)) { throw "Session file not found: $SessionFile" }
    $messages = @()
    $script:ActiveSessionTodos = @()
    if ($null -ne $State) {
        $State.todos = @()
        $State.tree_entries = @()
        $State.session_name = ''
        $State.parent_session = ''
        $State.leaf_id = ''
    }
    foreach ($line in @(Get-Content -LiteralPath $SessionFile -Encoding UTF8 -ErrorAction Stop)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
        if ($obj.type -eq 'session_meta') {
            $loadedTodos = @(if ($obj.todos) { @($obj.todos) })
            $script:ActiveSessionTodos = @($loadedTodos)
            if ($null -ne $State) {
                $State.session_id = [string]$obj.id
                $State.workspace = [string]$obj.workspace
                $State.model = [string]$obj.model
                $State.session_name = if ($obj.name) { [string]$obj.name } elseif ($obj.session_name) { [string]$obj.session_name } else { '' }
                $State.parent_session = if ($obj.parent_session) { [string]$obj.parent_session } else { '' }
                $State.leaf_id = if ($obj.leaf_id) { [string]$obj.leaf_id } else { '' }
                $State.todos = @($loadedTodos)
            }
            continue
        }
        if ($obj.type -eq 'branch_entry') {
            if ($null -ne $State) {
                if ($null -eq $State.tree_entries) { $State.tree_entries = @() }
                $bMsg = @{
                    id = [string]$obj.id
                    parent_id = $obj.parent_id
                    role = [string]$obj.role
                    content = $obj.content
                }
                Copy-MessageOptionalFields -Source $obj -Target $bMsg
                $State.tree_entries += $bMsg
            }
            continue
        }
        $msg = @{ role = [string]$obj.role; content = $obj.content }
        if ($obj.id) { $msg.id = [string]$obj.id }
        if ($obj.parent_id) { $msg.parent_id = [string]$obj.parent_id }
        Copy-MessageOptionalFields -Source $obj -Target $msg
        $messages += $msg
    }
    return $messages
}

function Find-ProjectSession {
    param([string]$SessionDir, [string]$Workspace)
    if (-not $SessionDir -or -not (Test-Path -LiteralPath $SessionDir)) { return $null }
    $targetWs = if ($Workspace -and (Test-Path -LiteralPath $Workspace)) { (Get-Item -LiteralPath $Workspace -Force).FullName } else { $Workspace }
    $targetNorm = ([string]$targetWs).TrimEnd('\').TrimEnd('/')
    foreach ($file in @(Get-ChildItem -LiteralPath $SessionDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $meta = Get-AgentSessionMeta -SessionFile $file.FullName
        if ($meta -and $meta.workspace) {
            $metaNorm = ([string]$meta.workspace).TrimEnd('\').TrimEnd('/')
            if ($metaNorm -ieq $targetNorm) {
                return $file.FullName
            }
        }
    }
    return $null
}

function Invoke-SessionResume {
    param([string]$SessionFile, $State, [string]$CurrentWorkspace = '')
    if (-not (Test-Path -LiteralPath $SessionFile)) { throw "Session file not found: $SessionFile" }
    $meta = Get-AgentSessionMeta -SessionFile $SessionFile
    if ($meta -and $meta.workspace -and $CurrentWorkspace) {
        $targetWs = if (Test-Path -LiteralPath $CurrentWorkspace) { (Get-Item -LiteralPath $CurrentWorkspace -Force).FullName } else { $CurrentWorkspace }
        $metaNorm = ([string]$meta.workspace).TrimEnd('\').TrimEnd('/')
        $targetNorm = ([string]$targetWs).TrimEnd('\').TrimEnd('/')
        if ($metaNorm -ine $targetNorm) {
            throw "Cannot resume session from a different workspace ($($meta.workspace))."
        }
    }
    $State.tree_entries = @()
    $State.usage_input_tokens = 0
    $State.usage_output_tokens = 0
    $State.scoped_instr_cache = @{}
    $loadedMessages = @(Read-AgentSession -SessionFile $SessionFile -State $State)
    $loadedHadSystem = $false
    foreach ($loadedMsg in @($loadedMessages)) {
        if ($loadedMsg.role -eq 'system') {
            $loadedHadSystem = $true
            break
        }
    }
    $State.messages = $loadedMessages
    Ensure-SessionTree -State $State
    if ($State.leaf_id -and $State.tree_entries.Count -gt 0) {
        $State.messages = @(Build-BranchContextMessages -State $State -LeafId $State.leaf_id)
    }
    if ($CurrentWorkspace) {
        $State.workspace = if (Test-Path -LiteralPath $CurrentWorkspace) { (Get-Item -LiteralPath $CurrentWorkspace -Force).FullName } else { $CurrentWorkspace }
    }
    if ($meta -and $meta.model) {
        $State.model = [string]$meta.model
    }
    if ($State.session_id) { $script:ActiveSessionId = [string]$State.session_id }
    if ($State.model) { $script:ActiveModelId = [string]$State.model }
    $script:ActiveSessionFile = $SessionFile
    $State.undo_stack = @()
    $State.last_failed_question = ''
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
    $State.step_limit_reached = $false
    $State.loop_detected = $false
    if ($loadedHadSystem -and $State.messages -and @($State.messages).Count -gt 0 -and $State.messages[0].role -eq 'system') {
        $refreshRoot = if ($State.workspace) { [string]$State.workspace } else { '' }
        $refreshConfig = ''
        if ($script:AgentConfigPath) {
            $refreshConfig = [string](Split-Path -Path ([string]$script:AgentConfigPath) -Parent)
        }
        if (-not $refreshConfig) { $refreshConfig = '.' }
        $State.messages[0].content = Build-SystemPrompt -Root $refreshRoot -ConfigDir $refreshConfig
    }
    Sync-AgentCapabilities -State $State | Out-Null
    return $State
}

function Copy-SessionHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [array]) {
        $arrCopy = @()
        foreach ($el in $InputObject) {
            $arrCopy += (Copy-SessionHashtable -InputObject $el)
        }
        return ,$arrCopy
    }
    $props = if ($InputObject -is [hashtable]) { @($InputObject.Keys) } else { @(Get-Member -InputObject $InputObject -MemberType NoteProperty | ForEach-Object { $_.Name }) }
    $copy = @{}
    foreach ($p in $props) {
        $val = $null
        if ($InputObject -is [hashtable]) { $val = $InputObject[$p] } else { $val = $InputObject.$p }
        if ($null -eq $val -or $val -is [string] -or $val -is [ValueType]) {
            $copy[$p] = $val
        }
        elseif ($val -is [array] -or $p -eq 'tool_calls') {
            $subArr = @()
            foreach ($subEl in @($val)) {
                $subArr += (Copy-SessionHashtable -InputObject $subEl)
            }
            $copy[$p] = $subArr
        }
        else {
            $copy[$p] = (Copy-SessionHashtable -InputObject $val)
        }
    }
    return $copy
}

function Copy-SessionHashtableArray {
    param($Items)
    if ($null -eq $Items) { return @() }
    $copied = @()
    foreach ($it in @($Items)) {
        if ($null -ne $it) {
            $copied += (Copy-SessionHashtable -InputObject $it)
        }
    }
    return $copied
}

function Invoke-SessionFork {
    param($State, [string]$SessionDir, [string]$Workspace = '', [string]$Model = '', [string]$FromId = '', [string]$EntryId = '', [string]$NewName = '', [switch]$NoSession)
    Ensure-SessionTree -State $State
    $effWs = if ($Workspace) { $Workspace } elseif ($State.workspace) { [string]$State.workspace } else { '' }
    $effMdl = if ($Model) { $Model } elseif ($State.model) { [string]$State.model } else { '' }
    $effName = if ($NewName) { $NewName } elseif ($State.session_name) { "$($State.session_name) (fork)" } else { '' }
    $effId = if ($EntryId) { $EntryId } else { $FromId }
    $forkMessages = @()
    foreach ($m in @($State.messages)) {
        if ($null -ne $m) {
            $forkMessages += (Copy-SessionHashtable -InputObject $m)
        }
    }
    $forkTreeEntries = @()
    foreach ($te in @($State.tree_entries)) {
        if ($null -ne $te) {
            $forkTreeEntries += (Copy-SessionHashtable -InputObject $te)
        }
    }
    $forkTodos = @()
    if ($State.todos) {
        foreach ($td in @($State.todos)) {
            if ($null -ne $td) {
                $forkTodos += (Copy-SessionHashtable -InputObject $td)
            }
        }
    }
    $forkState = @{
        session_id = 'sess-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999)
        session_name = $effName
        parent_session = [string]$State.session_id
        workspace = $effWs
        model = $effMdl
        leaf_id = $State.leaf_id
        messages = $forkMessages
        tree_entries = $forkTreeEntries
        todos = $forkTodos
        undo_stack = @()
        last_failed_question = ''
        usage_input_tokens = 0
        usage_output_tokens = 0
        last_prompt_tokens = 0
        last_prompt_chars = 0
        scoped_instr_cache = @{}
    }
    if ($effId) {
        Switch-SessionBranch -State $forkState -TargetId $effId | Out-Null
    }
    elseif (-not (Test-ValidConversationBoundary -Messages $forkState.messages)) {
        throw 'Cannot fork session: incomplete tool_calls sequence (missing tool result).'
    }
    $forkFile = if ($NoSession) { '' } else { Join-Path $SessionDir ($forkState.session_id + '.jsonl') }
    $script:ActiveSessionId = $forkState.session_id
    $script:ActiveSessionFile = $forkFile
    $script:ActiveModelId = $effMdl
    if (-not $NoSession) {
        Save-AgentSession -SessionFile $forkFile -State $forkState -Workspace $effWs -Model $effMdl -SessionId $forkState.session_id
    }
    return @{ state = $forkState; session_file = $forkFile; session_id = $forkState.session_id }
}

function Export-AgentSessionHtml {
    param($State, [string]$OutputPath)
    $title = if ($State.session_name) { [string]$State.session_name } elseif ($State.session_id) { [string]$State.session_id } else { 'shellossus session' }
    $cards = @()
    foreach ($m in @($State.messages)) {
        $role = [string]$m.role
        if ($role -eq 'system') { continue }
        if ($role -eq 'user' -and $m.content -and ([string]$m.content).StartsWith('[Capability State Change]')) { continue }
        $isCompaction = ($m.entry_type -eq 'compaction') -or ($role -eq 'user' -and $m.content -and ([string]$m.content).StartsWith('[Compacted Conversation Summary]'))
        $roleLabel = if ($isCompaction) { 'COMPACTION SUMMARY' } else { $role.ToUpper() }
        $bodyParts = @()
        if ($m.reasoning_content) {
            $bodyParts += '<div class="reasoning"><strong>Thinking:</strong><pre>' + (Escape-XmlText ([string]$m.reasoning_content)) + '</pre></div>'
        }
        if ($m.content) {
            $bodyParts += '<pre class="content">' + (Escape-XmlText ([string]$m.content)) + '</pre>'
        }
        if ($m.tool_calls) {
            foreach ($tc in @($m.tool_calls)) {
                $fnName = if ($tc.function -and $tc.function.name) { [string]$tc.function.name } else { 'tool' }
                $fnArgs = if ($tc.function -and $tc.function.arguments) { [string]$tc.function.arguments } else { '{}' }
                $bodyParts += '<div class="tool-call"><code>' + (Escape-XmlText "$fnName($fnArgs)") + '</code></div>'
            }
        }
        $idBadge = if ($m.id) { ' <span class="badge">#' + (Escape-XmlText ([string]$m.id)) + '</span>' } else { '' }
        $cards += ('<div class="card role-' + (Escape-XmlText $role) + '"><div class="role-header">' + (Escape-XmlText $roleLabel) + $idBadge + '</div>' + ($bodyParts -join "`n") + '</div>')
    }
    $th = if ($script:ActiveThemeSpec) { $script:ActiveThemeSpec } else { (Get-AgentThemesCatalog)[0] }
    $html = @(
        '<!DOCTYPE html>',
        '<html lang="en"><head><meta charset="utf-8">',
        ('<title>' + (Escape-XmlText $title) + '</title>'),
        '<style>',
        ("body { background: $($th.bg_outer); color: $($th.fg); font-family: Consolas, monospace; margin: 2rem auto; max-width: 960px; padding: 0 1rem; }"),
        ("h1 { color: $($th.green); border-bottom: 1px solid $($th.bg1); padding-bottom: 0.5rem; }"),
        (".meta { color: $($th.grey1); margin-bottom: 1.5rem; font-size: 0.9rem; }"),
        (".card { background: $($th.bg0); border: 1px solid $($th.bg1); border-radius: 6px; padding: 1rem; margin-bottom: 1rem; }"),
        (".role-user { border-left: 4px solid $($th.blue); }"),
        (".role-assistant { border-left: 4px solid $($th.green); }"),
        (".role-tool { border-left: 4px solid $($th.yellow); background: $($th.bg_outer); }"),
        (".role-header { font-weight: bold; margin-bottom: 0.5rem; color: $($th.orange); }"),
        (".badge { color: $($th.grey1); font-weight: normal; font-size: 0.85rem; }"),
        (".reasoning { color: $($th.grey1); border-left: 2px solid $($th.grey0); padding-left: 0.75rem; margin-bottom: 0.5rem; }"),
        (".tool-call { color: $($th.yellow); margin-top: 0.5rem; }"),
        'pre { white-space: pre-wrap; word-wrap: break-word; margin: 0; }',
        '</style></head><body>',
        ('<h1>' + (Escape-XmlText $title) + '</h1>'),
        ('<div class="meta">Session: ' + (Escape-XmlText ([string]$State.session_id)) + ' | Model: ' + (Escape-XmlText ([string]$State.model)) + ' | Workspace: ' + (Escape-XmlText ([string]$State.workspace)) + '</div>'),
        ($cards -join "`n"),
        '</body></html>'
    ) -join "`n"
    $parent = Split-Path $OutputPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8 -ErrorAction Stop
    return $OutputPath
}
