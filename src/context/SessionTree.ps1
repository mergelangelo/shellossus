# Multi-branch conversation DAG tree and branch context reconstruction.

function Copy-MessageOptionalFields {
    param($Source, $Target)
    # Copies entry_type, first_kept_entry_id, reasoning_content,
    # tool_calls (as an array), and tool_call_id when present.
    # Does not copy role, content, id, or parent_id.
    if ($Source.entry_type) { $Target.entry_type = [string]$Source.entry_type }
    if ($Source.first_kept_entry_id) { $Target.first_kept_entry_id = [string]$Source.first_kept_entry_id }
    if ($Source.reasoning_content) { $Target.reasoning_content = $Source.reasoning_content }
    if ($Source.tool_calls) { $Target.tool_calls = @($Source.tool_calls) }
    if ($Source.tool_call_id) { $Target.tool_call_id = [string]$Source.tool_call_id }
}

function New-SessionTreeEntryId {
    param($ExistingById, $Counter)
    # Returns the next free 'e0001'-style id and advances $Counter.Value
    # to that id. Callers pass @{ Value = <entry count> }.
    # PowerShell 7 ConstrainedLanguage cannot construct [ref].
    $Counter.Value = $Counter.Value + 1
    $newId = ('e{0:D4}' -f $Counter.Value)
    while ($ExistingById.ContainsKey($newId)) {
        $Counter.Value = $Counter.Value + 1
        $newId = ('e{0:D4}' -f $Counter.Value)
    }
    return $newId
}

function Convert-TreeEntryToMessage {
    param($Entry)
    $msg = @{
        id = [string]$Entry.id
        parent_id = $Entry.parent_id
        role = [string]$Entry.role
        content = $Entry.content
    }
    Copy-MessageOptionalFields -Source $Entry -Target $msg
    return $msg
}

function Test-ValidConversationBoundary {
    param([array]$Messages)
    if (-not $Messages -or $Messages.Count -eq 0) { return $true }
    $i = 0
    while ($i -lt $Messages.Count) {
        $m = $Messages[$i]
        if ($m.role -eq 'assistant' -and $null -ne $m.tool_calls) {
            if ($m.tool_calls -isnot [array]) { return $false }
            $pendingIds = Get-AgentToolCallIdSet -Calls $m.tool_calls
            if ($null -eq $pendingIds) { return $false }
            $j = $i + 1
            while ($j -lt $Messages.Count -and $Messages[$j].role -eq 'tool') {
                $id = $Messages[$j].tool_call_id
                if ($id -isnot [string] -or -not $pendingIds.ContainsKey($id)) { return $false }
                $pendingIds.Remove($id)
                $j++
            }
            if ($pendingIds.Count -gt 0) { return $false }
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

function Assert-AgentSessionTree {
    param([array]$Entries, [string]$LeafId)
    $byId = @{}
    $parents = @{}
    foreach ($entry in $Entries) {
        $byId[$entry.id] = $entry
        if ($entry.parent_id) { $parents[$entry.parent_id] = $true }
    }
    $pendingById = @{}
    $path = [object[]]::new($Entries.Count)
    foreach ($entry in $Entries) {
        $node = $entry
        $depth = 0
        while ($node -and -not $pendingById.ContainsKey($node.id)) {
            $pendingById[$node.id] = $false # Visiting, before the parent's state is known.
            $path[$depth] = $node
            $depth++
            $parentId = $node.parent_id
            if ($parentId -and -not $byId.ContainsKey($parentId)) {
                throw "Session entry '$($node.id)' has a missing parent."
            }
            $node = if ($parentId) { $byId[$parentId] }
        }
        $pending = if ($node) { $pendingById[$node.id] }
        if ($pending -is [bool]) { throw "Parent cycle in session tree at entry '$($node.id)'." }
        for ($i = $depth - 1; $i -ge 0; $i--) {
            $node = $path[$i]
            if ($node.role -eq 'tool') {
                if (-not $pending -or -not $pending.ContainsKey($node.tool_call_id)) {
                    throw "Session entry '$($node.id)' has a mismatched tool result."
                }
                # Siblings may answer the same pending call on separate branches.
                $pending = $pending.Clone()
                $pending.Remove($node.tool_call_id)
            }
            else {
                if ($pending.Count -gt 0) { throw "Incomplete tool calls before session entry '$($node.id)'." }
                $pending = if ($node.tool_calls) { Get-AgentToolCallIdSet -Calls $node.tool_calls }
            }
            if ($pending.Count -gt 0 -and ($node.id -eq $LeafId -or -not $parents.ContainsKey($node.id))) {
                throw "Incomplete tool calls at session leaf '$($node.id)'."
            }
            $pendingById[$node.id] = $pending
        }
    }
    foreach ($entry in $Entries) {
        $firstKept = $entry.first_kept_entry_id
        if (-not $firstKept) { continue }
        $ancestor = $byId[$entry.parent_id]
        while ($ancestor -and $ancestor.id -ine $firstKept) {
            $ancestor = if ($ancestor.parent_id) { $byId[$ancestor.parent_id] }
        }
        if (-not $ancestor -or $ancestor.role -eq 'tool' -or $ancestor.entry_type -eq 'compaction') {
            throw "Invalid first kept entry for session compaction '$($entry.id)'."
        }
    }
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
        if ($te -and $te.id) {
            if ($byId.ContainsKey([string]$te.id)) { throw "Duplicate session entry ID '$($te.id)'." }
            $byId[[string]$te.id] = $te
        }
    }
    if (-not $byId.ContainsKey($LeafId)) {
        throw "Entry ID '$LeafId' not found in session tree."
    }
    $path = [object[]]::new($byId.Count)
    $start = $path.Count
    $visited = @{}
    $curr = $byId[$LeafId]
    while ($curr) {
        if ($visited.ContainsKey($curr.id)) { throw "Parent cycle in session tree at entry '$($curr.id)'." }
        $visited[$curr.id] = $true
        $start--
        $path[$start] = $curr
        if ($curr.parent_id -and -not $byId.ContainsKey([string]$curr.parent_id)) {
            throw "Session entry '$($curr.id)' has a missing parent."
        }
        $curr = if ($curr.parent_id) { $byId[[string]$curr.parent_id] }
    }
    $path = @($path[$start..($path.Count - 1)])
    $compIdx = -1
    for ($i = 0; $i -lt $path.Count; $i++) {
        if ($path[$i].entry_type -eq 'compaction') {
            $compIdx = $i
        }
    }
    if ($path.Count -gt 0 -and $path[$path.Count - 1].entry_type -ne 'compaction') {
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
                Copy-MessageOptionalFields -Source $m -Target $entryCopy
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
    $counter = @{ Value = $State.tree_entries.Count }
    for ($i = 0; $i -lt $State.messages.Count; $i++) {
        $m = $State.messages[$i]
        if ($m.role -eq 'system') { continue }
        if ($m.role -eq 'user' -and $m.content -is [string] -and $m.content.StartsWith('[Capability State Change]')) { continue }
        if ($m.id -and $existingById.ContainsKey([string]$m.id)) {
            continue
        }
        $newId = New-SessionTreeEntryId -ExistingById $existingById -Counter $counter
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
        Copy-MessageOptionalFields -Source $m -Target $entryCopy
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
        throw "Cannot switch branch or fork at entry '$TargetId': incomplete tool_calls sequence (missing or mismatched tool results)."
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
