$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$tableLines = @(Format-MarkdownTable -Lines @('| Col | Val |', '|---|---|', '| a | **bold** |') -Indent '')
$plainTable = @($tableLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' })
Assert-True ($plainTable[0] -eq '| Col | Val  |') 'Table header alignment failed.'
Assert-True ($plainTable[1] -eq '|-----+------|') 'Table separator alignment failed.'
Assert-True ($plainTable[2] -eq '| a   | bold |') 'Table cell markdown stripping or padding failed.'

$inlineOut = Format-MarkdownInline -Text 'Hello **world** and `SELECT *`'
Assert-True ($inlineOut.Contains('38;2;231;138;78') -and (-not $inlineOut.Contains('**')) -and (-not $inlineOut.Contains('`'))) 'Gruvbox Material inline markdown formatting failed.'

Write-AgentReasoning -Text "Step 1`nStep 2`nStep 3`nStep 4"
Write-AgentReply -Content "# Title`n## Subtitle`n> quote`n- **item** with ``code```n| A | B |`n|---|---|`n| 1 | 2 |`n``````sql`nSELECT 1;`n``````"

# TUI primitives: token formatting, context gauge, git branch detection without git binary, status bar, unified diff, tool cards, multiline input, and selector.
Assert-True ((Format-TokenCount -Tokens 850) -eq '850') 'Format-TokenCount <1000 failed.'
Assert-True ((Format-TokenCount -Tokens 14250) -eq '14.3k') 'Format-TokenCount thousands failed.'

$gauge = Format-ContextGauge -Chars 30000 -MaxChars 60000 -Width 10
$plainGauge = Strip-AnsiCodes -Text $gauge
Assert-True ($plainGauge.Contains('50%') -and $plainGauge.Contains('7.5k/15.0k')) "Format-ContextGauge output unexpected: $plainGauge"

$envData = New-TestEnvironment
try {
    $ws = $envData.Workspace
    Assert-True ((Get-GitBranchLabel -Root $ws) -eq '') 'Expected empty git branch when .git does not exist.'
    $gitDir = Join-Path $ws '.git'
    New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Value "ref: refs/heads/feat/inline-tui`n" -Encoding UTF8 -NoNewline
    Assert-True ((Get-GitBranchLabel -Root $ws) -eq 'feat/inline-tui') 'Get-GitBranchLabel failed to parse ref.'
    Set-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Value "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4`n" -Encoding UTF8 -NoNewline
    Assert-True ((Get-GitBranchLabel -Root $ws) -eq 'a1b2c3d') 'Get-GitBranchLabel failed to format detached HEAD hash.'

    $statusState = @{
        session_id = 'sess-tui-1'
        session_name = 'demo'
        workspace = $ws
        model = 'glm-5'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = ('a' * 4000) }
        )
        todos = @(
            @{ content = 'Task A'; status = 'completed' },
            @{ content = 'Task B'; status = 'in_progress' }
        )
        usage_input_tokens = 1200
        usage_output_tokens = 350
    }
    $script:AgentPermission = 'AutoEdit'
    $script:ReasoningEffort = 'high'
    $barLines = @(Format-TuiStatusBar -State $statusState -Root $ws -Model 'glm-5' -UndoCount 2 -Width 90)
    $plainBar = ($barLines | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($barLines.Count -ge 2 -and $plainBar.Contains('glm-5') -and $plainBar.Contains('AutoEdit') -and $plainBar.Contains('a1b2c3d') -and $plainBar.Contains('undo:2') -and $plainBar.Contains('todo:1/2')) "Format-TuiStatusBar missing expected segments: $plainBar"
    $script:AgentPermission = 'Ask'
    $script:ReasoningEffort = ''

    $todoCard = @(Format-TodoCard -Todos @(@{ content = 'Task 1'; status = 'completed' }, @{ content = 'Task 2'; status = 'in_progress' }, @{ content = 'Task 3'; status = 'pending' }))
    $plainTodo = ($todoCard | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainTodo.Contains('TODO') -and $plainTodo.Contains('1/3 completed') -and $plainTodo.Contains('[x] Task 1') -and $plainTodo.Contains('[>] Task 2') -and $plainTodo.Contains('[ ] Task 3')) "Format-TodoCard output unexpected: $plainTodo"
    Assert-True ($todoCard[0].Contains($script:Gm.BoldAqua)) 'Format-TodoCard header missing BoldAqua color sequence.'

    $diffCard = @(Format-UnifiedDiff -Path 'src/App.ps1' -ToolName 'edit_file' -Before "line1`nold_a`nold_b`nline4" -After "line1`nnew_a`nline4" -ContextLines 1)
    $plainDiff = ($diffCard | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainDiff.Contains('src/App.ps1') -and $plainDiff.Contains('+1 -2') -and $plainDiff.Contains('- old_a') -and $plainDiff.Contains('+ new_a')) "Format-UnifiedDiff output unexpected: $plainDiff"

    $cardLines = @(Format-ToolCallCard -Name 'read_file' -Target 'src/Theme.ps1' -Detail 'lines 1-50' -Status 'ok' -Summary '50 lines (1.8k chars)' -ElapsedMs 12)
    $plainCard = ($cardLines | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainCard.Contains('read_file') -and $plainCard.Contains('src/Theme.ps1') -and $plainCard.Contains('50 lines') -and $plainCard.Contains('12ms')) "Format-ToolCallCard output unexpected: $plainCard"

    # Multiline input helper: single line, backslash continuation, and """ block.
    $script:mlQueue = @('single line prompt')
    function Read-Host {
        param($Prompt)
        $next = $script:mlQueue[0]
        if ($script:mlQueue.Count -eq 1) { $script:mlQueue = @() }
        else { $script:mlQueue = @($script:mlQueue[1..($script:mlQueue.Count - 1)]) }
        return $next
    }
    Assert-True ((Read-TuiMultilineInput) -eq 'single line prompt') 'Single line Read-TuiMultilineInput failed.'
    $script:mlQueue = @('SELECT * \', 'FROM users \', 'WHERE active = 1')
    Assert-True ((Read-TuiMultilineInput) -eq "SELECT * `nFROM users `nWHERE active = 1") 'Backslash continuation Read-TuiMultilineInput failed.'
    $script:mlQueue = @('"""first line', 'second line', 'third line"""')
    Assert-True ((Read-TuiMultilineInput) -eq "first line`nsecond line`nthird line") 'Triple-quote fenced Read-TuiMultilineInput failed.'

    # Interactive selector helper: numbered pick and Enter cancel.
    $items = @(
        @{ label = 'ReadOnly'; description = 'Safe inspection'; value = 'ReadOnly'; active = $false },
        @{ label = 'Ask'; description = 'Confirm writes and commands'; value = 'Ask'; active = $true },
        @{ label = 'AutoEdit'; description = 'Auto-approve file edits'; value = 'AutoEdit'; active = $false }
    )
    $script:mlQueue = @('3')
    $picked = Invoke-TuiSelector -Title 'Select Permission' -Items $items
    Assert-True ($picked -eq 'AutoEdit') "Invoke-TuiSelector expected AutoEdit for input 3, got $picked"
    $script:mlQueue = @('Custom choice')
    $customPicked = Invoke-TuiSelector -Title 'Select Permission' -Items $items -AllowFreeText
    Assert-True ($customPicked -eq 'Custom choice') 'Invoke-TuiSelector -AllowFreeText failed.'
    $script:mlQueue = @('')
    $cancelled = Invoke-TuiSelector -Title 'Select Permission' -Items $items
    Assert-True ($null -eq $cancelled) 'Invoke-TuiSelector should return $null on empty input.'

    $planCard = @(Format-PlanReviewCard -Question 'Review migration plan' -Plan "# Plan`n1. Step A`n2. Step B")
    $plainPlan = ($planCard | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainPlan.Contains('PLAN REVIEW') -and $plainPlan.Contains('Review migration plan') -and $plainPlan.Contains('Step A')) 'Format-PlanReviewCard failed.'

    $memCard = @(Format-MemoryCard -Scope 'workspace' -Action 'append' -Content '+ Invariant note')
    $plainMem = ($memCard | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainMem.Contains('MEMORY (WORKSPACE)') -and $plainMem.Contains('+ Invariant note')) 'Format-MemoryCard failed.'
    Assert-True ($memCard[0].Contains($script:Gm.BoldPurple)) 'Format-MemoryCard header missing BoldPurple color sequence.'

    # Read-TuiConfirmation tests via mock Read-Host
    $script:mlQueue = @('y')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -eq 'y') 'Read-TuiConfirmation y failed.'
    $script:mlQueue = @('yes')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -eq 'y') 'Read-TuiConfirmation yes failed.'
    $script:mlQueue = @('WRITE')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -eq 'y') 'Read-TuiConfirmation WRITE failed.'
    $script:mlQueue = @('WRITE')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'run') -ne 'y') 'Read-TuiConfirmation WRITE must not approve run.'
    $script:mlQueue = @('RUN')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'run') -eq 'y') 'Read-TuiConfirmation RUN failed.'
    $script:mlQueue = @('RUN')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -ne 'y') 'Read-TuiConfirmation RUN must not approve write.'
    $script:mlQueue = @('a')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -eq 'a') 'Read-TuiConfirmation a failed.'
    $script:mlQueue = @('d')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -AllowDiff -ActionType 'write') -eq 'd') 'Read-TuiConfirmation d failed.'
    $script:mlQueue = @('n')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -eq 'n') 'Read-TuiConfirmation n failed.'
    $script:mlQueue = @('')
    Assert-True ((Read-TuiConfirmation -PromptText 'prompt: ' -ActionType 'write') -eq 'n') 'Read-TuiConfirmation empty cancel failed.'

    # Mascot tests: compact (5 lines) and full (9 lines)
    $compactMascot = @(Get-TuiMascotLines -Mode 'compact')
    Assert-True ($compactMascot.Count -eq 5) 'Compact mascot must have 5 lines.'
    Assert-True ((Strip-AnsiCodes -Text $compactMascot[0]).Length -eq 14) 'Compact mascot line width must be 14 chars.'

    $fullMascot = @(Get-TuiMascotLines -Mode 'full')
    Assert-True ($fullMascot.Count -eq 9) 'Full mascot must have 9 lines.'
    Assert-True ((Strip-AnsiCodes -Text $fullMascot[0]).Length -eq 28) 'Full mascot line width must be 28 chars.'

    Write-TuiMascotCard -Mode 'compact'
    Write-TuiMascotCard -Mode 'full'

    # Theme catalog, alias resolution, palette switching, config persistence, and HTML export theme integration.
    $themesCatalog = @(Get-AgentThemesCatalog)
    Assert-True ($themesCatalog.Count -eq 9) 'Expected 9 built-in themes in catalog.'
    foreach ($tSpec in $themesCatalog) {
        $appliedSpec = Set-AgentTheme -Name $tSpec.id
        Assert-True ($appliedSpec.id -eq $tSpec.id -and $script:ActiveTheme -eq $tSpec.id) "Set-AgentTheme failed for $($tSpec.id)."
        Assert-True ($script:Gm.OscInit.Contains($tSpec.bg0) -and $script:Gm.OscInit.Contains($tSpec.fg)) "OscInit mismatch for $($tSpec.id)."
        Assert-True ([bool]$script:Gm.BoldAqua -and [bool]$script:Gm.BoldPurple) "Missing BoldAqua or BoldPurple in $($tSpec.id) palette."
    }
    Assert-True ((Resolve-ThemeCanonicalName -Name 'mocha') -eq 'catppuccin-mocha') 'Alias mocha failed.'
    Assert-True ((Resolve-ThemeCanonicalName -Name 'tokyo') -eq 'tokyo-night') 'Alias tokyo failed.'
    Assert-True ((Resolve-ThemeCanonicalName -Name 'onedark') -eq 'one-dark') 'Alias onedark failed.'
    Assert-True ((Resolve-ThemeCanonicalName -Name 'rosepine') -eq 'rose-pine') 'Alias rosepine failed.'
    Assert-True ((Resolve-ThemeCanonicalName -Name 'light') -eq 'catppuccin-latte') 'Alias light failed.'
    $badThemeThrew = $false
    try { Set-AgentTheme -Name 'nonexistent-theme' | Out-Null } catch { $badThemeThrew = $true }
    Assert-True $badThemeThrew 'Set-AgentTheme should throw on unknown theme.'

    # Interactive /theme command & config persistence
    $themeCfgFile = Join-Path $ws 'theme-test.env'
    Save-AgentConfig -Path $themeCfgFile -Config @{
        SHELLOSSUS_BASE_URL = 'https://example.invalid/v1'
        SHELLOSSUS_MODEL = 'test-model'
        SHELLOSSUS_API_KEY = 'secret-key'
        SHELLOSSUS_WORKSPACE = ''
    }
    $prevCfgPath = $script:AgentConfigPath
    $script:AgentConfigPath = $themeCfgFile
    try {
        Invoke-ReplThemeCommand -ThemeArg 'dracula'
        Assert-True ($script:ActiveTheme -eq 'dracula') 'Invoke-ReplThemeCommand direct switch to dracula failed.'
        $reloadedCfg = Read-AgentConfig -Path $themeCfgFile
        Assert-True ($reloadedCfg.SHELLOSSUS_THEME -eq 'dracula' -and $reloadedCfg.SHELLOSSUS_API_KEY -eq 'secret-key') 'Theme persistence in .env config failed.'

        # Interactive picker via /theme without args (select #2 = catppuccin-mocha)
        $script:mlQueue = @('2')
        Invoke-ReplThemeCommand -ThemeArg ''
        Assert-True ($script:ActiveTheme -eq 'catppuccin-mocha') 'Invoke-ReplThemeCommand interactive selector failed.'
    }
    finally {
        $script:AgentConfigPath = $prevCfgPath
        $null = Set-AgentTheme -Name 'gruvbox-material'
    }
}
finally {
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    Remove-TestEnvironment -Env $envData
}
