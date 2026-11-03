# Disk undo and multi-step turn rollback.

function Invoke-AgentUndo {
    param($State, $UndoEntry)
    if (-not $UndoEntry) { return }
    $writes = @($UndoEntry.writes)
    $preflightErrors = @()
    $expectedByPath = @{}
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if (-not $w -or $w.undone) { continue }
        $fullKey = [string]$w.full_path
        $isLatestForPath = (-not $expectedByPath.ContainsKey($fullKey))
        if ($w.action -eq 'modified') {
            if (-not $w.backup -or -not (Test-Path -LiteralPath $w.backup)) {
                $preflightErrors += "Backup file missing for $($w.rel_path)."
                continue
            }
            try {
                $backupContent = Get-Content -LiteralPath $w.backup -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $backupContent) { $backupContent = '' }
                if ($null -eq $w.before_content -or $backupContent -cne $w.before_content) {
                    throw 'Backup does not match the recorded original content.'
                }
            }
            catch {
                $preflightErrors += "Backup verification failed for $($w.rel_path); backup kept at $($w.backup): $($_.Exception.Message)"
                continue
            }
            if ($isLatestForPath) {
                if (Test-Path -LiteralPath $w.full_path) {
                    $targetItem = Get-Item -LiteralPath $w.full_path -Force -ErrorAction SilentlyContinue
                    if ($targetItem -and $targetItem.PSIsContainer) {
                        $preflightErrors += "Target path $($w.rel_path) is now a directory."
                        continue
                    }
                    if ($null -ne $w.after_content) {
                        $diskNow = Get-Content -LiteralPath $w.full_path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($null -eq $diskNow) { $diskNow = '' }
                        if (($diskNow -cne $w.after_content) -and ($null -eq $w.before_content -or $diskNow -cne $w.before_content)) {
                            $preflightErrors += "File $($w.rel_path) was modified after the agent write; refusing to overwrite manual changes (backup kept at $($w.backup))."
                            continue
                        }
                    }
                }
            }
            else {
                $expectedAfter = $expectedByPath[$fullKey]
                if ($null -ne $expectedAfter -and $null -ne $w.after_content -and ($w.after_content -cne $expectedAfter)) {
                    $preflightErrors += "Undo chain mismatch for $($w.rel_path)."
                    continue
                }
            }
            $expectedByPath[$fullKey] = $w.before_content
        }
        elseif ($w.action -eq 'created') {
            if ($isLatestForPath) {
                if (Test-Path -LiteralPath $w.full_path) {
                    $targetItem = Get-Item -LiteralPath $w.full_path -Force -ErrorAction SilentlyContinue
                    if ($targetItem -and $targetItem.PSIsContainer) {
                        $preflightErrors += "Created path $($w.rel_path) is now a directory."
                        continue
                    }
                    if ($null -ne $w.after_content) {
                        $diskNow = Get-Content -LiteralPath $w.full_path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($null -eq $diskNow) { $diskNow = '' }
                        if ($diskNow -cne $w.after_content) {
                            $preflightErrors += "Created file $($w.rel_path) was modified after creation; refusing to delete manual changes."
                            continue
                        }
                    }
                }
            }
            else {
                $expectedAfter = $expectedByPath[$fullKey]
                if ($null -ne $expectedAfter -and $null -ne $w.after_content -and ($w.after_content -cne $expectedAfter)) {
                    $preflightErrors += "Undo chain mismatch for $($w.rel_path)."
                    continue
                }
            }
            $expectedByPath[$fullKey] = $null
        }
    }
    if ($preflightErrors.Count -gt 0) {
        throw ('Undo failed: ' + ($preflightErrors -join '; '))
    }
    $undoErrors = @()
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if (-not $w -or $w.undone) { continue }
        try {
            if ($w.action -eq 'modified') {
                $expectedOrig = [string]$w.before_content
                $backupNow = Get-Content -LiteralPath $w.backup -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $backupNow) { $backupNow = '' }
                if ($backupNow -cne $expectedOrig) { throw "Backup changed after preflight for $($w.rel_path)." }
                Copy-Item -LiteralPath $w.backup -Destination $w.full_path -Force -ErrorAction Stop
                $restoredNow = Get-Content -LiteralPath $w.full_path -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $restoredNow) { $restoredNow = '' }
                if ($restoredNow -cne $expectedOrig) {
                    throw "Restored content verification failed for $($w.rel_path) (backup kept at $($w.backup))."
                }
                Remove-Item -LiteralPath $w.backup -Force -ErrorAction Stop
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
                $w.undone = $true
            }
        }
        catch {
            $undoErrors += $_.Exception.Message
        }
    }
    if ($undoErrors.Count -gt 0) {
        throw ('Undo failed: ' + ($undoErrors -join '; '))
    }
    $State.messages = @($UndoEntry.messages)
    $State.last_prompt_tokens = 0
    $State.last_prompt_chars = 0
}
