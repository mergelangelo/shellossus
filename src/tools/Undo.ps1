# Disk undo and multi-step turn rollback.

function Clear-AgentUndoBackups {
    param($UndoEntries, $Writes)
    foreach ($entry in @($UndoEntries)) {
        if ($null -eq $entry) { continue }
        if ($entry.preserve_backups) { continue }
        foreach ($w in @($entry.writes)) {
            if ($w -and $w.preserve_backup) { continue }
            if ($w -and $w.backup -and (Test-Path -LiteralPath $w.backup)) {
                Remove-Item -LiteralPath $w.backup -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($w in @($Writes)) {
        if ($w -and $w.preserve_backup) { continue }
        if ($w -and $w.backup -and (Test-Path -LiteralPath $w.backup)) {
            Remove-Item -LiteralPath $w.backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-AgentUndoContent {
    param([string]$Path, [switch]$Hash)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -eq 'PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand') { return $null }
        throw
    }
    if ($item.PSIsContainer) {
        throw "Expected a file at $Path."
    }
    if ($Hash) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $content) { return '' }
    return [string]$content
}

function New-AgentUndoBackup {
    param([string]$Path, [AllowEmptyString()][string]$Before, [string]$BeforeHash)
    $backup = New-AgentTempFile
    try {
        Copy-Item -LiteralPath $Path -Destination $backup.FullName -Force -ErrorAction Stop
        $expected = if ($BeforeHash) { $BeforeHash } else { $Before }
        if ((Read-AgentUndoContent -Path $backup.FullName -Hash:([bool]$BeforeHash)) -cne $expected) {
            throw 'Backup verification failed. No write performed.'
        }
        return $backup
    }
    catch {
        Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Assert-AgentUndoPath {
    param($Write)
    if (-not $Write.root -or -not $Write.full_path) { throw 'Undo entry has no workspace path.' }
    if ($Write.memory_scope) {
        $rootMemory = Join-Path $Write.root 'MEMORY.md'
        $dotMemory = Join-Path (Join-Path $Write.root '.shellossus') 'MEMORY.md'
        if ($Write.full_path -eq $script:AgentConfigPath -or
            ($Write.full_path -cne $rootMemory -and ($Write.memory_scope -ne 'workspace' -or $Write.full_path -cne $dotMemory))) {
            throw 'Undo entry is not a fixed memory path.'
        }
        if (Test-PathHasReparsePoint -Path $Write.full_path -StopAt $Write.root) {
            throw 'Reparse points are not allowed.'
        }
        return
    }
    $parent = Split-Path -Path $Write.full_path -Parent
    $anc = $parent
    while ($anc -and -not (Test-Path -LiteralPath $anc)) {
        $nextAnc = Split-Path -Path $anc -Parent
        if ($nextAnc -eq $anc) { break }
        $anc = $nextAnc
    }
    $null = Resolve-AgentPath -Root $Write.root -RelativePath $anc
    $target = Get-Item -LiteralPath $Write.full_path -Force -ErrorAction SilentlyContinue
    if ($null -ne $target) {
        $null = Resolve-AgentPath -Root $Write.root -RelativePath $Write.full_path
    }
}

function Assert-AgentUndoBackup {
    param($Write)
    if (-not $Write.backup -or -not (Test-Path -LiteralPath $Write.backup)) {
        throw "Backup file missing for $($Write.rel_path)."
    }
    try {
        $backupItem = Get-Item -LiteralPath $Write.backup -Force -ErrorAction Stop
        if (($backupItem.Attributes -band 1024) -ne 0) { throw 'Backup is a reparse point.' }
        $expected = if ($Write.before_hash) { $Write.before_hash } else { $Write.before_content }
        if ((Read-AgentUndoContent -Path $Write.backup -Hash:([bool]$Write.before_hash)) -cne $expected) {
            throw 'Backup does not match the recorded original content.'
        }
    }
    catch {
        throw "Backup verification failed for $($Write.rel_path): $($_.Exception.Message)"
    }
}

function Assert-AgentUndoContent {
    param($Write)
    $useHash = [bool]($Write.after_hash -or $Write.before_hash)
    $before = if ($useHash) { $Write.before_hash } else { $Write.before_content }
    $after = if ($useHash) { $Write.after_hash } else { $Write.after_content }
    $current = Read-AgentUndoContent -Path $Write.full_path -Hash:$useHash
    if ($current -cne $after -and $current -cne $before) {
        throw "File $($Write.rel_path) changed after the agent operation. Refusing to overwrite manual changes."
    }
}

function Stop-AgentUndo {
    param($UndoEntry, [string]$Reason)
    $UndoEntry.preserve_backups = $true
    $pending = @()
    $backups = @()
    foreach ($w in @($UndoEntry.writes)) {
        if (-not $w) { continue }
        $w.preserve_backup = $true
        if (-not $w.undone) { $pending += "$($w.full_path) ($($w.action))" }
        if ($w.backup -and (Test-Path -LiteralPath $w.backup -ErrorAction SilentlyContinue)) {
            $backups += "$($w.full_path) ($($w.action)) -> $($w.backup)"
        }
    }
    $message = "Undo failed: $Reason Conversation and task board restoration is pending."
    if ($pending.Count) { $message += ' Pending file operations: ' + ($pending -join ', ') + '.' }
    if ($backups.Count) { $message += ' Backups kept: ' + ($backups -join ', ') + '.' }
    throw $message
}

function Invoke-AgentUndo {
    param($State, $UndoEntry)
    if (-not $UndoEntry) { return }
    $writes = @($UndoEntry.writes)
    $expectedByPath = @{}
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if (-not $w -or $w.undone) { continue }
        try { Assert-AgentUndoPath -Write $w }
        catch { Stop-AgentUndo -UndoEntry $UndoEntry -Reason "Unsafe undo path for $($w.rel_path): $($_.Exception.Message)" }
        try {
            if ($w.action -in @('modified', 'deleted')) {
                Assert-AgentUndoBackup -Write $w
            }
            $fullKey = [string]$w.full_path
            if ($expectedByPath.ContainsKey($fullKey)) {
                $nextWrite = $expectedByPath[$fullKey]
                if ($w.after_content -cne $nextWrite.before_content -or
                    ($w.after_hash -and $nextWrite.before_hash -and $w.after_hash -cne $nextWrite.before_hash)) {
                    throw "Undo chain mismatch for $($w.rel_path)."
                }
            }
            else { Assert-AgentUndoContent -Write $w }
            $expectedByPath[$fullKey] = $w
        }
        catch {
            Stop-AgentUndo -UndoEntry $UndoEntry -Reason $_.Exception.Message
        }
    }
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if (-not $w -or $w.undone) { continue }
        try {
            Assert-AgentUndoPath -Write $w
            Assert-AgentUndoContent -Write $w
            if ($w.action -in @('modified', 'deleted')) {
                Assert-AgentUndoBackup -Write $w
                Copy-Item -LiteralPath $w.backup -Destination $w.full_path -Force -ErrorAction Stop
                $expected = if ($w.before_hash) { $w.before_hash } else { $w.before_content }
                if ((Read-AgentUndoContent -Path $w.full_path -Hash:([bool]$w.before_hash)) -cne $expected) {
                    throw "Restored content verification failed for $($w.rel_path)."
                }
                $w.undone = $true
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + '  [undo] Restored ' + $w.rel_path + $script:Gm.Reset)
                }
            }
            elseif ($w.action -eq 'created') {
                if (Test-Path -LiteralPath $w.full_path) {
                    Remove-Item -LiteralPath $w.full_path -Force -ErrorAction Stop
                    if ($script:OutputMode -ne 'json') {
                        Write-Host ($script:Gm.Aqua + '  [undo] Removed created file ' + $w.rel_path + $script:Gm.Reset)
                    }
                }
                if ($w.created_dirs) {
                    foreach ($dirPath in @($w.created_dirs)) {
                        if ($dirPath -and (Test-Path -LiteralPath $dirPath)) {
                            $resolvedDir = if ($w.memory_scope) { $dirPath } else { Resolve-AgentPath -Root $w.root -RelativePath $dirPath }
                            if (Test-PathHasReparsePoint -Path $resolvedDir -StopAt $w.root) { throw 'Reparse points are not allowed.' }
                            $dirItem = Get-Item -LiteralPath $resolvedDir -Force -ErrorAction SilentlyContinue
                            if ($dirItem -and $dirItem.PSIsContainer) {
                                $remaining = @(Get-ChildItem -LiteralPath $resolvedDir -Force -ErrorAction SilentlyContinue)
                                if ($remaining.Count -eq 0) {
                                    Remove-Item -LiteralPath $resolvedDir -Force -ErrorAction Stop
                                }
                            }
                        }
                    }
                }
                $w.undone = $true
            }
        }
        catch {
            Stop-AgentUndo -UndoEntry $UndoEntry -Reason $_.Exception.Message
        }
    }
    if ($UndoEntry -is [hashtable]) {
        if ($UndoEntry.ContainsKey('todos')) {
            $State.todos = @(Copy-SessionHashtableArray -Items $UndoEntry.todos)
        }
        if ($UndoEntry.ContainsKey('active_session_todos')) {
            $script:ActiveSessionTodos = @(Copy-SessionHashtableArray -Items $UndoEntry.active_session_todos)
        }
    }
    $State.messages = @($UndoEntry.messages)
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
    if ($State -is [hashtable] -and ($State.ContainsKey('tree_entries') -or $State.ContainsKey('leaf_id'))) {
        if ($UndoEntry -is [hashtable] -and $UndoEntry.ContainsKey('tree_entries') -and $null -ne $UndoEntry.tree_entries) {
            $State.tree_entries = @($UndoEntry.tree_entries)
        }
        if ($UndoEntry -is [hashtable] -and $UndoEntry.ContainsKey('leaf_id') -and $UndoEntry.leaf_id) {
            $State.leaf_id = [string]$UndoEntry.leaf_id
        }
        else {
            $restoredLeaf = ''
            $lastMsgId = ''
            foreach ($m in @($State.messages)) {
                if ($m -and $m.role -ne 'system' -and $m.id) {
                    $lastMsgId = [string]$m.id
                }
            }
            if ($lastMsgId) {
                $restoredLeaf = $lastMsgId
                foreach ($m in @($State.messages)) {
                    if ($m -and $m.id -and $m.parent_id -and ([string]$m.parent_id -eq $lastMsgId) -and ($m.entry_type -eq 'compaction' -or ($m.content -is [string] -and $m.content.StartsWith('[Compacted Conversation Summary]')))) {
                        $restoredLeaf = [string]$m.id
                        break
                    }
                }
            }
            $State.leaf_id = $restoredLeaf
        }
        if (Get-Command -Name 'Ensure-SessionTree' -ErrorAction SilentlyContinue) {
            Ensure-SessionTree -State $State
        }
    }
    Sync-AgentMemoryContext -State $State | Out-Null
    $UndoEntry.preserve_backups = $false
    foreach ($w in $writes) {
        if ($w) { $w.preserve_backup = $false }
    }
    Clear-AgentUndoBackups -Writes $writes
}
