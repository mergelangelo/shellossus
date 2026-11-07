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
