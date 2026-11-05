# Cross-session persistent long-term memory tool (memory / MEMORY.md).

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
        Join-Path (if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }) '.shellossus'
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
        if (Test-Path -LiteralPath $wsRootMem) {
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

    if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
        throw 'Reparse points are not allowed.'
    }

    $existing = ''
    if (Test-Path -LiteralPath $targetPath) {
        $candItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        if ($candItem.PSIsContainer) { throw 'MEMORY.md path is a directory.' }
        $existing = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $existing) { $existing = '' }
    }

    $summaryText = ''
    $cardContent = ''
    $updatedText = $existing

    if ($action -eq 'view') {
        $summaryText = if ($existing.Trim()) { "$($existing.Length) chars read" } else { 'empty' }
        $cardContent = if ($existing.Trim()) { $existing.Trim() } else { '(no memories recorded yet)' }
    }
    elseif ($action -eq 'append') {
        $newBullet = $content.Trim()
        if (-not $newBullet.StartsWith('-') -and -not $newBullet.StartsWith('*') -and -not $newBullet.StartsWith('#')) {
            $newBullet = "- $newBullet"
        }
        $trimmedExisting = $existing.TrimEnd()
        $updatedText = if ($trimmedExisting) {
            $trimmedExisting + "`n" + $newBullet + "`n"
        }
        else {
            "# Project Memory`n`n" + $newBullet + "`n"
        }
        $summaryText = "appended to $displayRel"
        $cardContent = "+ $newBullet"
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
            $promptStr = '  ' + $script:Gm.BoldYellow + $script:Box.Arrow + " Confirm memory $action ($displayRel) [y]es, [n]o, [a]ll edits: " + $script:Gm.Fg
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
        if ($action -in @('append', 'set')) {
            if (-not (Test-Path -LiteralPath $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
            }
            if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
                throw 'Reparse points are not allowed.'
            }
            $stageFile = New-TemporaryFile -ErrorAction Stop
            try {
                Set-Content -LiteralPath $stageFile.FullName -Value $updatedText -Encoding UTF8 -NoNewline -ErrorAction Stop
                $stagedCheck = Get-Content -LiteralPath $stageFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $stagedCheck) { $stagedCheck = '' }
                if ($stagedCheck -cne $updatedText) { throw 'Staged memory verification failed. No write performed.' }
                if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
                    throw 'Reparse points are not allowed.'
                }
                Move-Item -LiteralPath $stageFile.FullName -Destination $targetPath -Force -ErrorAction Stop
                $writtenCheck = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 -ErrorAction Stop
                if ($null -eq $writtenCheck) { $writtenCheck = '' }
                if ($writtenCheck -cne $updatedText) { throw 'Written memory verification failed.' }
            }
            finally {
                if ($stageFile -and (Test-Path -LiteralPath $stageFile.FullName)) {
                    Remove-Item -LiteralPath $stageFile.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            $existing = $updatedText
        }
        elseif ($action -eq 'clear') {
            if (Test-Path -LiteralPath $targetPath) {
                if (Test-PathHasReparsePoint -Path $targetPath -StopAt $stopRoot) {
                    throw 'Reparse points are not allowed.'
                }
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
            }
            $existing = ''
        }

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
