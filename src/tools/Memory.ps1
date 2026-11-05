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

    $targetPath = $null
    $displayRel = $null
    if ($scope -eq 'global') {
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force -ErrorAction Stop | Out-Null
        }
        $targetPath = Join-Path $configDir 'MEMORY.md'
        $displayRel = '~/.shellossus/MEMORY.md'
    }
    else {
        $dotDir = Join-Path $Root '.shellossus'
        $wsDotMem = Join-Path $dotDir 'MEMORY.md'
        $wsRootMem = Join-Path $Root 'MEMORY.md'
        if (Test-Path -LiteralPath $wsRootMem) {
            $targetPath = $wsRootMem
            $displayRel = 'MEMORY.md'
        }
        else {
            if (-not (Test-Path -LiteralPath $dotDir)) {
                New-Item -ItemType Directory -Path $dotDir -Force -ErrorAction Stop | Out-Null
            }
            $targetPath = $wsDotMem
            $displayRel = '.shellossus/MEMORY.md'
        }
    }

    if (Test-Path -LiteralPath $targetPath) {
        $candItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        if (($candItem.Attributes -band 1024) -ne 0) { throw 'Reparse points are not allowed.' }
    }

    $existing = ''
    if (Test-Path -LiteralPath $targetPath) {
        $existing = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $existing) { $existing = '' }
    }

    $summaryText = ''
    $cardContent = ''

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
        Set-Content -LiteralPath $targetPath -Value $updatedText -Encoding UTF8 -ErrorAction Stop
        $existing = $updatedText
        $summaryText = "appended to $displayRel"
        $cardContent = "+ $newBullet"
    }
    elseif ($action -eq 'set') {
        $updatedText = $content.Trim() + "`n"
        Set-Content -LiteralPath $targetPath -Value $updatedText -Encoding UTF8 -ErrorAction Stop
        $existing = $updatedText
        $summaryText = "updated $displayRel ($($updatedText.Length) chars)"
        $cardContent = $updatedText.Trim()
    }
    elseif ($action -eq 'clear') {
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
        }
        $existing = ''
        $summaryText = "cleared $displayRel"
        $cardContent = '(memory cleared)'
    }

    if ($action -in @('append', 'set', 'clear')) {
        Sync-AgentMemoryContext -State $script:ActiveState -Root $Root -ConfigDir $configDir | Out-Null
    }

    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
    Write-ToolCallCard -Name 'memory' -Target $displayRel -Detail $action -Status 'ok' -Summary $summaryText -ElapsedMs $elapsedMs
    Write-MemoryCard -Scope $scope -Action $action -Content $cardContent

    $resObj = @{
        success = $true
        action = $action
        scope = $scope
        path = $displayRel
        memory = $existing
    }
    return ($resObj | ConvertTo-Json -Depth 5 -Compress)
}
