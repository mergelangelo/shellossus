# Cross-session persistent long-term memory tool (memory / MEMORY.md).

function Format-MemoryAppendText {
    param([string]$Existing, [string]$Content)
    $newBullet = $Content.Trim()
    if (-not $newBullet.StartsWith('-') -and -not $newBullet.StartsWith('*') -and -not $newBullet.StartsWith('#')) {
        $newBullet = "- $newBullet"
    }
    $trimmedExisting = $Existing.TrimEnd()
    $updatedText = if ($trimmedExisting) {
        $trimmedExisting + "`n" + $newBullet + "`n"
    }
    else {
        "# Project Memory`n`n" + $newBullet + "`n"
    }
    return @{ text = $updatedText; bullet = $newBullet }
}

function Invoke-AgentMemory {
    param([string]$Root, $Arguments)
    $toolStart = Get-Date
    $action = if ($Arguments.action) { ([string]$Arguments.action).Trim().ToLower() } else { 'append' }
    $scope = if ($Arguments.scope) { ([string]$Arguments.scope).Trim().ToLower() } else { 'workspace' }
    $content = if ($Arguments.content) { [string]$Arguments.content } else { '' }

    if ($script:AgentPermission -eq 'ReadOnly' -and $action -in @('append', 'set', 'clear')) {
        throw 'Permission mode ReadOnly does not allow memory modifications.'
    }

    $configDir = if ($Arguments.config_dir) {
        [string]$Arguments.config_dir
    }
    elseif ($script:AgentConfigPath) {
        Split-Path $script:AgentConfigPath -Parent
    }
    else {
        Join-Path (Get-AgentUserRoot) '.shellossus'
    }

    $parentDir = $null
    $targetPath = $null
    $displayRel = $null
    $stopRoot = ''
    if ($scope -eq 'global') {
        $parentDir = $configDir
        $targetPath = Join-Path $configDir 'MEMORY.md'
        $displayRel = '~/.shellossus/MEMORY.md'
        $stopRoot = $configDir
    }
    else {
        $stopRoot = $Root
        if ($Root -and (Test-PathHasReparsePoint -Path $Root -StopAt $Root)) {
            throw 'Reparse points are not allowed.'
        }
        $dotDir = Join-Path $Root '.shellossus'
        $wsDotMem = Join-Path $dotDir 'MEMORY.md'
        $wsRootMem = Join-Path $Root 'MEMORY.md'
        if ((Test-PathHasReparsePoint -Path $wsRootMem -StopAt $Root) -or (Test-PathHasReparsePoint -Path $wsDotMem -StopAt $Root)) {
            throw 'Reparse points are not allowed.'
        }
        if (Test-Path -LiteralPath $wsRootMem -ErrorAction Stop) {
            $parentDir = $Root
            $targetPath = $wsRootMem
            $displayRel = 'MEMORY.md'
        }
        else {
            $parentDir = $dotDir
            $targetPath = $wsDotMem
            $displayRel = '.shellossus/MEMORY.md'
        }
    }

    if ($targetPath -eq $script:AgentConfigPath) {
        throw 'Agent tools cannot access credential configuration files.'
    }
    if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
        throw 'Reparse points are not allowed.'
    }
    $before = Read-AgentUndoContent -Path $targetPath -MaxBytes $script:AgentMaxMemoryBytes
    $existing = [string]$before

    $summaryText = ''
    $cardContent = ''
    $updatedText = $existing

    if ($action -eq 'view') {
        $summaryText = if ($existing.Trim()) { "$($existing.Length) chars read" } else { 'empty' }
        $cardContent = if ($existing.Trim()) { $existing.Trim() } else { '(no memories recorded yet)' }
    }
    elseif ($action -eq 'append') {
        $built = Format-MemoryAppendText -Existing $existing -Content $content
        $updatedText = [string]$built.text
        $summaryText = "appended to $displayRel"
        $cardContent = '+ ' + [string]$built.bullet
    }
    elseif ($action -eq 'set') {
        $updatedText = $content.Trim() + "`n"
        $summaryText = "updated $displayRel ($($updatedText.Length) chars)"
        $cardContent = $updatedText.Trim()
    }
    elseif ($action -eq 'clear') {
        $updatedText = ''
        $summaryText = "cleared $displayRel"
        $cardContent = '(memory cleared)'
    }

    $cardPrinted = $false
    if ($action -in @('append', 'set', 'clear')) {
        if ((Get-AgentUtf8ByteCount $updatedText) -gt $script:AgentMaxMemoryBytes) {
            throw "Memory exceeds the $($script:AgentMaxMemoryBytes)-byte limit."
        }
        $needsConfirm = ($script:AgentPermission -eq 'Ask') -and (-not ($Arguments.user_initiated -eq $true))
        if ($needsConfirm) {
            if ($script:OutputMode -eq 'json') {
                return (@{
                    status = 'cancelled'
                    success = $false
                    action = $action
                    scope = $scope
                    path = $displayRel
                    message = 'Interactive confirmation is disabled in JSON mode. Use -Permission AutoEdit or Auto to allow memory modifications.'
                } | ConvertTo-Json -Depth 5 -Compress)
            }
            Write-MemoryCard -Scope $scope -Action $action -Content $cardContent
            $cardPrinted = $true
            $promptStr = '  ' + $script:Gm.BoldYellow + $script:Box.Arrow + " Confirm memory $action ($(Format-TuiText $displayRel)) [y]es, [n]o, [a]ll edits: " + $script:Gm.Fg
            $choice = Read-TuiConfirmation -PromptText $promptStr -ActionType 'write'
            if ($choice -eq 'a') {
                $script:AgentPermission = 'AutoEdit'
                Write-Host ('  ' + $script:Gm.Aqua + $script:Box.Check + ' [switched permission to AutoEdit for this session]' + $script:Gm.Reset)
            }
            elseif ($choice -ne 'y') {
                Write-Host ('  ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
                return (@{
                    status = 'cancelled'
                    success = $false
                    action = $action
                    scope = $scope
                    path = $displayRel
                    message = 'User declined memory modification. Do not retry without a new user request.'
                } | ConvertTo-Json -Depth 5 -Compress)
            }
        }

        if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
            throw 'Reparse points are not allowed.'
        }
        $fresh = Read-AgentUndoContent -Path $targetPath -MaxBytes $script:AgentMaxMemoryBytes
        if ($action -eq 'append') {
            $before = $fresh
            $rebuilt = Format-MemoryAppendText -Existing $before -Content $content
            $updatedText = [string]$rebuilt.text
            if ((Get-AgentUtf8ByteCount $updatedText) -gt $script:AgentMaxMemoryBytes) {
                throw "Memory exceeds the $($script:AgentMaxMemoryBytes)-byte limit."
            }
        }
        elseif ($fresh -cne $before) {
            throw 'Memory file changed during confirmation. No write performed.'
        }

        if ($action -ne 'clear' -or $null -ne $before) {
            $trackWrite = ($Arguments.user_initiated -ne $true)
            $stageFile = $null
            $backup = $null
            $keepBackup = $false
            $createdDirs = @()
            try {
                $after = $null
                $writeAction = 'deleted'
                if ($action -ne 'clear') {
                    $after = $updatedText
                    $writeAction = if ($null -eq $before) { 'created' } else { 'modified' }
                    $stageFile = New-AgentTempFile
                    Set-AgentUtf8Content -LiteralPath $stageFile.FullName -Value $after
                    if ((Read-AgentUndoContent -Path $stageFile.FullName) -cne $after) {
                        throw 'Staged memory verification failed. No write performed.'
                    }
                    if (-not (Test-Path -LiteralPath $parentDir)) {
                        New-Item -ItemType Directory -Path $parentDir -ErrorAction Stop | Out-Null
                        $createdDirs = @($parentDir)
                    }
                }
                if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
                    throw 'Reparse points are not allowed.'
                }
                if ($null -ne $before) {
                    $backup = New-AgentUndoBackup -Path $targetPath -Before $before
                }
                if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
                    throw 'Reparse points are not allowed.'
                }
                if ((Read-AgentUndoContent -Path $targetPath -MaxBytes $script:AgentMaxMemoryBytes) -cne $before) {
                    throw 'Memory file changed before the operation. No write performed.'
                }
                if ($trackWrite) {
                    $script:CurrentTurnWrites += @{
                        action = $writeAction
                        root = $stopRoot
                        full_path = $targetPath
                        rel_path = $displayRel
                        memory_scope = $scope
                        before_content = $before
                        after_content = $after
                        backup = $backup.FullName
                        created_dirs = $createdDirs
                    }
                }
                $keepBackup = ($null -ne $backup)
                if ($action -eq 'clear') {
                    Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                }
                else {
                    Move-Item -LiteralPath $stageFile.FullName -Destination $targetPath -Force -ErrorAction Stop
                }
                if ((Read-AgentUndoContent -Path $targetPath -MaxBytes $script:AgentMaxMemoryBytes) -cne $after) { throw 'Written memory verification failed.' }
                $keepBackup = $trackWrite
            }
            catch {
                if ($keepBackup -and -not $trackWrite) {
                    throw "Memory update failed. Backup kept at $($backup.FullName). $($_.Exception.Message)"
                }
                throw
            }
            finally {
                if ($stageFile) {
                    Remove-Item -LiteralPath $stageFile.FullName -Force -ErrorAction SilentlyContinue
                }
                if ($backup -and -not $keepBackup) {
                    Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $existing = $updatedText

        Sync-AgentMemoryContext -State $script:ActiveState -Root $Root -ConfigDir $configDir | Out-Null
    }

    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
    Write-ToolCallCard -Name 'memory' -Target $displayRel -Detail $action -Status 'ok' -Summary $summaryText -ElapsedMs $elapsedMs
    if (-not $cardPrinted) {
        Write-MemoryCard -Scope $scope -Action $action -Content $cardContent
    }

    $resObj = @{
        status = $(if ($action -eq 'view') { 'ok' } else { 'written' })
        success = $true
        action = $action
        scope = $scope
        path = $displayRel
        memory = $existing
    }
    return ($resObj | ConvertTo-Json -Depth 5 -Compress)
}
