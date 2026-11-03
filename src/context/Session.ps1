# Conversation branching tree, JSONL session persistence, and standalone HTML export.

function Convert-TreeEntryToMessage {
    param($Entry)
    $msg = @{
        id = [string]$Entry.id
        parent_id = $Entry.parent_id
        role = [string]$Entry.role
        content = $Entry.content
    }
    if ($Entry.entry_type) { $msg.entry_type = [string]$Entry.entry_type }
    if ($Entry.first_kept_entry_id) { $msg.first_kept_entry_id = [string]$Entry.first_kept_entry_id }
    if ($Entry.reasoning_content) { $msg.reasoning_content = $Entry.reasoning_content }
    if ($Entry.tool_calls) { $msg.tool_calls = @($Entry.tool_calls) }
    if ($Entry.tool_call_id) { $msg.tool_call_id = [string]$Entry.tool_call_id }
    return $msg
}

function Test-ValidConversationBoundary {
    param([array]$Messages)
    if (-not $Messages -or $Messages.Count -eq 0) { return $true }
    $i = 0
    while ($i -lt $Messages.Count) {
        $m = $Messages[$i]
        if ($m.role -eq 'assistant' -and $m.tool_calls -and @($m.tool_calls).Count -gt 0) {
            $requiredIds = @()
            foreach ($tc in @($m.tool_calls)) {
                if ($tc -and $tc.id) { $requiredIds += [string]$tc.id }
            }
            $answeredIds = @{}
            $j = $i + 1
            while ($j -lt $Messages.Count -and $Messages[$j].role -eq 'tool') {
                if ($Messages[$j].tool_call_id) {
                    $answeredIds[[string]$Messages[$j].tool_call_id] = $true
                }
                $j++
            }
            foreach ($reqId in $requiredIds) {
                if (-not $answeredIds.ContainsKey($reqId)) {
                    return $false
                }
            }
            $i = $j
            continue
        }
        if ($m.role -eq 'tool') {
            return $false
        }
        $i++
    }
    return $true
}

function Build-BranchContextMessages {
    param($State, [string]$LeafId)
    $sysMsg = if ($State.messages -and $State.messages.Count -gt 0 -and $State.messages[0].role -eq 'system') {
        $State.messages[0]
    }
    else {
        @{ role = 'system'; content = '' }
    }
    if (-not $LeafId) { return @($sysMsg) }
    $byId = @{}
    foreach ($te in @($State.tree_entries)) {
        if ($te -and $te.id) { $byId[[string]$te.id] = $te }
    }
    if (-not $byId.ContainsKey($LeafId)) {
        throw "Entry ID '$LeafId' not found in session tree."
    }
    $chainRev = @()
    $curr = $byId[$LeafId]
    $guard = 0
    while ($null -ne $curr -and $guard -lt 5000) {
        $guard++
        $chainRev += $curr
        if ($curr.parent_id -and $byId.ContainsKey([string]$curr.parent_id)) {
            $curr = $byId[[string]$curr.parent_id]
        }
        else {
            $curr = $null
        }
    }
    $path = @()
    for ($i = $chainRev.Count - 1; $i -ge 0; $i--) {
        $path += $chainRev[$i]
    }
    $compIdx = -1
    for ($i = 0; $i -lt $path.Count; $i++) {
        if ($path[$i].entry_type -eq 'compaction') {
            $compIdx = $i
        }
    }
    if ($compIdx -lt 0) {
        foreach ($te in @($State.tree_entries)) {
            if ($te -and $te.entry_type -eq 'compaction' -and [string]$te.parent_id -eq $LeafId) {
                $path += $te
                $compIdx = $path.Count - 1
                break
            }
        }
    }
    if ($compIdx -lt 0) {
        $rebuilt = @($sysMsg)
        foreach ($entry in $path) {
            $rebuilt += (Convert-TreeEntryToMessage -Entry $entry)
        }
        return $rebuilt
    }
    $compEntry = $path[$compIdx]
    $rebuilt = @($sysMsg, (Convert-TreeEntryToMessage -Entry $compEntry))
    $firstKeptId = [string]$compEntry.first_kept_entry_id
    if ($firstKeptId) {
        $foundFirstKept = $false
        for ($i = 0; $i -lt $compIdx; $i++) {
            if ([string]$path[$i].id -eq $firstKeptId) {
                $foundFirstKept = $true
            }
            if ($foundFirstKept -and $path[$i].entry_type -ne 'compaction') {
                $rebuilt += (Convert-TreeEntryToMessage -Entry $path[$i])
            }
        }
    }
    for ($i = $compIdx + 1; $i -lt $path.Count; $i++) {
        if ($path[$i].entry_type -ne 'compaction') {
            $rebuilt += (Convert-TreeEntryToMessage -Entry $path[$i])
        }
    }
    return $rebuilt
}

function Ensure-SessionTree {
    param($State)
    if ($null -eq $State) { return }
    if ($null -eq $State.tree_entries) {
        $State.tree_entries = @()
    }
    $existingById = @{}
    foreach ($te in @($State.tree_entries)) {
        if ($te -and $te.id) { $existingById[[string]$te.id] = $te }
    }
    $msgIdsInState = @{}
    $lastExistingMsgId = $null
    foreach ($m in @($State.messages)) {
        if ($m.role -eq 'system') { continue }
        if ($m.id) {
            $mid = [string]$m.id
            $msgIdsInState[$mid] = $true
            $lastExistingMsgId = $mid
            if (-not $existingById.ContainsKey($mid)) {
                $entryCopy = @{
                    id = $mid
                    parent_id = $m.parent_id
                    role = [string]$m.role
                    content = $m.content
                    timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
                }
                if ($m.entry_type) { $entryCopy.entry_type = [string]$m.entry_type }
                if ($m.first_kept_entry_id) { $entryCopy.first_kept_entry_id = [string]$m.first_kept_entry_id }
                if ($m.reasoning_content) { $entryCopy.reasoning_content = $m.reasoning_content }
                if ($m.tool_calls) { $entryCopy.tool_calls = @($m.tool_calls) }
                if ($m.tool_call_id) { $entryCopy.tool_call_id = [string]$m.tool_call_id }
                $State.tree_entries += $entryCopy
                $existingById[$mid] = $entryCopy
            }
        }
    }
    $currLeaf = if ($State.leaf_id -and $msgIdsInState.ContainsKey([string]$State.leaf_id)) {
        [string]$State.leaf_id
    }
    else {
        $lastExistingMsgId
    }
    $counter = $State.tree_entries.Count
    for ($i = 0; $i -lt $State.messages.Count; $i++) {
        $m = $State.messages[$i]
        if ($m.role -eq 'system') { continue }
        if ($m.role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Capability State Change]')) { continue }
        if ($m.id -and $existingById.ContainsKey([string]$m.id)) {
            continue
        }
        $counter++
        $newId = ('e{0:D4}' -f $counter)
        while ($existingById.ContainsKey($newId)) {
            $counter++
            $newId = ('e{0:D4}' -f $counter)
        }
        $m.id = $newId
        $m.parent_id = $currLeaf
        $currLeaf = $newId
        $msgIdsInState[$currLeaf] = $true
        $entryCopy = @{
            id = $currLeaf
            parent_id = $m.parent_id
            role = [string]$m.role
            content = $m.content
            timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        }
        if ($m.entry_type) { $entryCopy.entry_type = [string]$m.entry_type }
        if ($m.first_kept_entry_id) { $entryCopy.first_kept_entry_id = [string]$m.first_kept_entry_id }
        if ($m.reasoning_content) { $entryCopy.reasoning_content = $m.reasoning_content }
        if ($m.tool_calls) { $entryCopy.tool_calls = @($m.tool_calls) }
        if ($m.tool_call_id) { $entryCopy.tool_call_id = [string]$m.tool_call_id }
        $State.tree_entries += $entryCopy
        $existingById[$currLeaf] = $entryCopy
    }
    $State.leaf_id = $currLeaf
}

function Get-SessionTree {
    param($State)
    Ensure-SessionTree -State $State
    $activeIds = @{}
    foreach ($m in @($State.messages)) {
        if ($m.id) { $activeIds[[string]$m.id] = $true }
    }
    $nodes = @()
    foreach ($te in @($State.tree_entries)) {
        $preview = if ($te.content) { ([string]$te.content -replace '\s+', ' ').Trim() } elseif ($te.tool_calls) { '[tool_calls]' } else { '' }
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '...' }
        $roleLabel = if ($te.entry_type -eq 'compaction') { 'compaction' } else { [string]$te.role }
        $nodes += @{
            id = [string]$te.id
            parent_id = $te.parent_id
            role = $roleLabel
            entry_type = if ($te.entry_type) { [string]$te.entry_type } else { 'message' }
            preview = $preview
            active = [bool]$activeIds.ContainsKey([string]$te.id)
            is_leaf = ([string]$te.id -eq [string]$State.leaf_id)
        }
    }
    return $nodes
}

function Switch-SessionBranch {
    param($State, [string]$TargetId)
    Ensure-SessionTree -State $State
    if (-not $TargetId) { throw 'Target entry ID is required.' }
    $rebuilt = @(Build-BranchContextMessages -State $State -LeafId $TargetId)
    if (-not (Test-ValidConversationBoundary -Messages $rebuilt)) {
        throw "Cannot switch branch or fork at entry '$TargetId': incomplete tool_calls sequence (missing tool result)."
    }
    $effectiveLeaf = $TargetId
    foreach ($te in @($State.tree_entries)) {
        if ($te -and $te.entry_type -eq 'compaction' -and [string]$te.parent_id -eq $TargetId) {
            $effectiveLeaf = [string]$te.id
            break
        }
    }
    $State.messages = $rebuilt
    $State.leaf_id = $effectiveLeaf
    $State.undo_stack = @()
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
    Sync-AgentCapabilities -State $State | Out-Null
    return $State
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
    foreach ($m in @($State.messages)) {
        if ($m.role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Capability State Change]')) { continue }
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
            if ($te.entry_type) { $bEntry.entry_type = [string]$te.entry_type }
            if ($te.first_kept_entry_id) { $bEntry.first_kept_entry_id = [string]$te.first_kept_entry_id }
            if ($te.reasoning_content) { $bEntry.reasoning_content = $te.reasoning_content }
            if ($te.tool_calls) { $bEntry.tool_calls = @($te.tool_calls) }
            if ($te.tool_call_id) { $bEntry.tool_call_id = [string]$te.tool_call_id }
            $lines += ($bEntry | ConvertTo-Json -Depth 20 -Compress)
        }
    }
    $tempSession = New-TemporaryFile -ErrorAction Stop
    try {
        Set-Content -LiteralPath $tempSession.FullName -Value $lines -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempSession.FullName -Destination $SessionFile -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $tempSession.FullName) {
            Remove-Item -LiteralPath $tempSession.FullName -Force -ErrorAction SilentlyContinue
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
                return @{
                    version = [int]$obj.version
                    id = [string]$obj.id
                    name = if ($obj.name) { [string]$obj.name } else { '' }
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
    foreach ($line in @(Get-Content -LiteralPath $SessionFile -Encoding UTF8 -ErrorAction Stop)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
        if ($obj.type -eq 'session_meta') {
            if ($null -ne $State) {
                $State.session_id = [string]$obj.id
                $State.workspace = [string]$obj.workspace
                $State.model = [string]$obj.model
                if ($obj.name) { $State.session_name = [string]$obj.name }
                if ($obj.parent_session) { $State.parent_session = [string]$obj.parent_session }
                if ($obj.leaf_id) { $State.leaf_id = [string]$obj.leaf_id }
                if ($obj.todos) {
                    $State.todos = @($obj.todos)
                    $script:ActiveSessionTodos = @($obj.todos)
                }
            }
            elseif ($obj.todos) {
                $script:ActiveSessionTodos = @($obj.todos)
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
                if ($obj.entry_type) { $bMsg.entry_type = [string]$obj.entry_type }
                if ($obj.first_kept_entry_id) { $bMsg.first_kept_entry_id = [string]$obj.first_kept_entry_id }
                if ($obj.reasoning_content) { $bMsg.reasoning_content = $obj.reasoning_content }
                if ($obj.tool_calls) { $bMsg.tool_calls = @($obj.tool_calls) }
                if ($obj.tool_call_id) { $bMsg.tool_call_id = [string]$obj.tool_call_id }
                $State.tree_entries += $bMsg
            }
            continue
        }
        $msg = @{ role = [string]$obj.role; content = $obj.content }
        if ($obj.id) { $msg.id = [string]$obj.id }
        if ($obj.parent_id) { $msg.parent_id = [string]$obj.parent_id }
        if ($obj.entry_type) { $msg.entry_type = [string]$obj.entry_type }
        if ($obj.first_kept_entry_id) { $msg.first_kept_entry_id = [string]$obj.first_kept_entry_id }
        if ($obj.reasoning_content) { $msg.reasoning_content = $obj.reasoning_content }
        if ($obj.tool_calls) { $msg.tool_calls = @($obj.tool_calls) }
        if ($obj.tool_call_id) { $msg.tool_call_id = [string]$obj.tool_call_id }
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
    $loadedMessages = @(Read-AgentSession -SessionFile $SessionFile -State $State)
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
    $State.undo_stack = @()
    $State.last_failed_question = ''
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
    Sync-AgentCapabilities -State $State | Out-Null
    return $State
}

function Invoke-SessionFork {
    param($State, [string]$SessionDir, [string]$Workspace = '', [string]$Model = '', [string]$FromId = '', [string]$EntryId = '', [string]$NewName = '')
    Ensure-SessionTree -State $State
    $effWs = if ($Workspace) { $Workspace } elseif ($State.workspace) { [string]$State.workspace } else { '' }
    $effMdl = if ($Model) { $Model } elseif ($State.model) { [string]$State.model } else { '' }
    $effName = if ($NewName) { $NewName } elseif ($State.session_name) { "$($State.session_name) (fork)" } else { '' }
    $effId = if ($EntryId) { $EntryId } else { $FromId }
    $forkState = @{
        session_id = 'sess-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999)
        session_name = $effName
        parent_session = [string]$State.session_id
        workspace = $effWs
        model = $effMdl
        leaf_id = $State.leaf_id
        messages = @($State.messages)
        tree_entries = @($State.tree_entries)
        undo_stack = @()
        last_failed_question = ''
    }
    if ($effId) {
        Switch-SessionBranch -State $forkState -TargetId $effId | Out-Null
    }
    elseif (-not (Test-ValidConversationBoundary -Messages $forkState.messages)) {
        throw 'Cannot fork session: incomplete tool_calls sequence (missing tool result).'
    }
    $forkFile = Join-Path $SessionDir ($forkState.session_id + '.jsonl')
    Save-AgentSession -SessionFile $forkFile -State $forkState -Workspace $effWs -Model $effMdl -SessionId $forkState.session_id
    return @{ state = $forkState; session_file = $forkFile; session_id = $forkState.session_id }
}

function Export-AgentSessionHtml {
    param($State, [string]$OutputPath)
    $title = if ($State.session_name) { [string]$State.session_name } elseif ($State.session_id) { [string]$State.session_id } else { 'shellossus session' }
    $cards = @()
    foreach ($m in @($State.messages)) {
        $role = [string]$m.role
        if ($role -eq 'system') { continue }
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
        $cards += ('<div class="card role-' + (Escape-XmlText $role) + '"><div class="role-header">' + (Escape-XmlText $role.ToUpper()) + $idBadge + '</div>' + ($bodyParts -join "`n") + '</div>')
    }
    $html = @(
        '<!DOCTYPE html>',
        '<html lang="en"><head><meta charset="utf-8">',
        ('<title>' + (Escape-XmlText $title) + '</title>'),
        '<style>',
        'body { background: #1d2021; color: #d4be98; font-family: Consolas, monospace; margin: 2rem auto; max-width: 960px; padding: 0 1rem; }',
        'h1 { color: #a9b665; border-bottom: 1px solid #3c3836; padding-bottom: 0.5rem; }',
        '.meta { color: #928374; margin-bottom: 1.5rem; font-size: 0.9rem; }',
        '.card { background: #282828; border: 1px solid #3c3836; border-radius: 6px; padding: 1rem; margin-bottom: 1rem; }',
        '.role-user { border-left: 4px solid #7daea3; }',
        '.role-assistant { border-left: 4px solid #a9b665; }',
        '.role-tool { border-left: 4px solid #d8a657; background: #242424; }',
        '.role-header { font-weight: bold; margin-bottom: 0.5rem; color: #e78a4e; }',
        '.badge { color: #928374; font-weight: normal; font-size: 0.85rem; }',
        '.reasoning { color: #928374; border-left: 2px solid #504945; padding-left: 0.75rem; margin-bottom: 0.5rem; }',
        '.tool-call { color: #d8a657; margin-top: 0.5rem; }',
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
