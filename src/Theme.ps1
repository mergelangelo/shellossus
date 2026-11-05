# Terminal UI theme (sainnhe/gruvbox-material dark medium), status bar, and prompt frame.

$script:Esc = [string][char]27
$script:Bel = [string][char]7
# sainnhe/gruvbox-material (dark medium) exact RGB palette
$script:Gm = @{
    Reset       = "$script:Esc[0m"
    Bg0         = "$script:Esc[48;2;40;40;40m"       # #282828
    Bg1         = "$script:Esc[48;2;50;48;47m"       # #32302f
    BgDiffRed   = "$script:Esc[48;2;64;33;32m"       # #402120
    BgDiffGreen = "$script:Esc[48;2;52;56;27m"       # #34381b
    Fg          = "$script:Esc[38;2;212;190;152m"    # #d4be98
    Fg1         = "$script:Esc[38;2;221;199;161m"    # #ddc7a1
    Red         = "$script:Esc[38;2;234;105;98m"     # #ea6962
    BoldRed     = "$script:Esc[1;38;2;234;105;98m"   # #ea6962 bold (H1)
    Orange      = "$script:Esc[38;2;231;138;78m"     # #e78a4e
    BoldOrange  = "$script:Esc[1;38;2;231;138;78m"   # #e78a4e bold (H2 / **bold**)
    Yellow      = "$script:Esc[38;2;216;166;87m"     # #d8a657
    BoldYellow  = "$script:Esc[1;38;2;216;166;87m"   # #d8a657 bold (H3)
    Green       = "$script:Esc[38;2;169;182;101m"    # #a9b665
    BoldGreen   = "$script:Esc[1;38;2;169;182;101m"  # #a9b665 bold (Shellossus: / H4)
    Aqua        = "$script:Esc[38;2;137;180;130m"    # #89b482
    Blue        = "$script:Esc[38;2;125;174;163m"    # #7daea3
    BoldBlue    = "$script:Esc[1;38;2;125;174;163m"  # #7daea3 bold (You: / Table header)
    Purple      = "$script:Esc[3;38;2;211;134;155m"  # #d3869b italic (*italic*)
    Grey0       = "$script:Esc[38;2;124;111;100m"    # #7c6f64
    Grey1       = "$script:Esc[38;2;146;131;116m"    # #928374
    Grey2       = "$script:Esc[38;2;168;153;132m"    # #a89984
    OscInit     = "$script:Esc]11;#282828$script:Bel$script:Esc]10;#d4be98$script:Bel"
}

$script:Box = @{
    TL       = [string][char]0x256D
    TR       = [string][char]0x256E
    BL       = [string][char]0x2570
    BR       = [string][char]0x256F
    H        = [string][char]0x2500
    V        = [string][char]0x2502
    LT       = [string][char]0x251C
    RT       = [string][char]0x2524
    BarFull  = [string][char]0x2588
    BarEmpty = [string][char]0x2591
    Dot      = [string][char]0x25CF
    Arrow    = [string][char]0x25B8
    Check    = [string][char]0x2713
    Cross    = [string][char]0x2717
}

function Strip-AnsiCodes {
    param([string]$Text)
    if (-not $Text) { return '' }
    $s = $Text -replace '\x1b\][^\x07]*\x07', ''
    $s = $s -replace '\x1b\[[0-9;?]*[a-zA-Z]', ''
    return $s
}

function Get-TerminalWidth {
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI -and $Host.UI.RawUI.WindowSize) {
            $w = [int]$Host.UI.RawUI.WindowSize.Width
            if ($w -ge 50 -and $w -le 220) { return $w }
        }
    }
    catch {}
    return 90
}

function Format-TokenCount {
    param([int]$Tokens)
    if ($Tokens -lt 1000) { return [string]$Tokens }
    return (("{0:0.0}k" -f ($Tokens / 1000.0)).Replace(',', '.'))
}

function Format-ContextGauge {
    param(
        [int]$Chars = -1,
        [int]$MaxChars = 0,
        [int]$Tokens = -1,
        [int]$MaxTokens = 0,
        [int]$CompactTokens = 0,
        [int]$Width = 10
    )
    if ($Width -lt 4) { $Width = 4 }
    $estTok = if ($Tokens -ge 0) {
        $Tokens
    }
    elseif ($Chars -ge 0) {
        [int](($Chars + 3) / 4)
    }
    else {
        0
    }
    $maxTok = if ($MaxTokens -gt 0) {
        $MaxTokens
    }
    elseif ($MaxChars -gt 0) {
        [int](($MaxChars + 3) / 4)
    }
    elseif ($script:ContextWindowTokens -gt 0) {
        [int]$script:ContextWindowTokens
    }
    else {
        128000
    }
    if ($maxTok -le 0) { $maxTok = 128000 }
    $pct = [int](($estTok * 100) / $maxTok)
    if ($pct -lt 0) { $pct = 0 }
    $clampedPct = if ($pct -gt 100) { 100 } else { $pct }
    $filled = [int](($clampedPct * $Width + 50) / 100)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0) { $filled = 0 }
    $empty = $Width - $filled
    $colorRefTok = if ($CompactTokens -gt 0) { $CompactTokens } else { $maxTok }
    $compactPct = if ($colorRefTok -gt 0) { [int](($estTok * 100) / $colorRefTok) } else { $pct }
    $barColor = if ($compactPct -ge 85 -or $pct -ge 80) { $script:Gm.Red } elseif ($compactPct -ge 55 -or $pct -ge 50) { $script:Gm.Yellow } else { $script:Gm.Green }
    $bar = $barColor + ($script:Box.BarFull * $filled) + $script:Gm.Grey0 + ($script:Box.BarEmpty * $empty) + $script:Gm.Reset
    $tokStr = (Format-TokenCount -Tokens $estTok) + '/' + (Format-TokenCount -Tokens $maxTok)
    return ($bar + ' ' + $barColor + ("{0}%" -f $pct) + $script:Gm.Reset + ' ' + $script:Gm.Grey1 + '(' + $tokStr + ')' + $script:Gm.Reset)
}

function Get-GitBranchLabel {
    param([string]$Root)
    if (-not $Root) { return '' }
    $curr = $Root
    for ($depth = 0; $depth -lt 12; $depth++) {
        if (-not $curr) { break }
        $currItem = Get-Item -LiteralPath $curr -Force -ErrorAction SilentlyContinue
        if (-not $currItem -or (($currItem.Attributes -band 1024) -ne 0)) { break }
        $dotGit = Join-Path $curr '.git'
        if (Test-Path -LiteralPath $dotGit) {
            $gitItem = Get-Item -LiteralPath $dotGit -Force -ErrorAction SilentlyContinue
            if ($gitItem -and (($gitItem.Attributes -band 1024) -eq 0) -and $gitItem.PSIsContainer) {
                $headFile = Join-Path $dotGit 'HEAD'
                if (Test-Path -LiteralPath $headFile) {
                    $headItem = Get-Item -LiteralPath $headFile -Force -ErrorAction SilentlyContinue
                    if ($headItem -and (-not $headItem.PSIsContainer) -and (($headItem.Attributes -band 1024) -eq 0) -and $headItem.Length -le 1024) {
                        $rawHead = Get-Content -LiteralPath $headFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($rawHead) {
                            $trimmed = $rawHead.Trim()
                            if ($trimmed -match '^ref:\s*refs/heads/(.+)$') {
                                return $Matches[1].Trim()
                            }
                            if ($trimmed -match '^[0-9a-fA-F]{7,40}$') {
                                return $trimmed.Substring(0, 7)
                            }
                        }
                    }
                }
            }
            break
        }
        $parent = Split-Path $curr -Parent
        if (-not $parent -or ($parent -ieq $curr)) { break }
        $curr = $parent
    }
    return ''
}

function Format-PermissionBadge {
    param([string]$Permission = $script:AgentPermission)
    $p = if ($Permission) { $Permission } else { 'Ask' }
    $color = switch ($p) {
        'ReadOnly' { $script:Gm.Blue }
        'Ask'      { $script:Gm.BoldYellow }
        'AutoEdit' { $script:Gm.Aqua }
        'Auto'     { $script:Gm.BoldRed }
        default    { $script:Gm.Fg }
    }
    return ($script:Gm.Bg1 + $color + '[' + $p + ']' + $script:Gm.Reset)
}

function Format-TuiStatusBar {
    param($State, [string]$Root, [string]$Model, [int]$UndoCount = 0, [int]$Width = 0)
    $w = if ($Width -ge 50) { $Width } else { Get-TerminalWidth }
    $innerW = $w - 4
    if ($innerW -lt 46) { $innerW = 46 }
    $wsName = if ($Root) { Split-Path $Root -Leaf } else { 'workspace' }
    if (-not $wsName) { $wsName = $Root }
    $branch = Get-GitBranchLabel -Root $Root
    $branchSeg = if ($branch) { ' ' + $script:Gm.Purple + '(' + $branch + ')' + $script:Gm.Reset } else { '' }
    $sessLabel = if ($State -and $State.session_name) { [string]$State.session_name } elseif ($State -and $State.session_id) { [string]$State.session_id } else { '' }
    $sessSeg = if ($sessLabel) { ' ' + $script:Gm.Grey0 + $script:Box.H + ' ' + $script:Gm.Grey1 + $sessLabel + $script:Gm.Reset } else { '' }
    $topTitle = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' ' + $wsName + $script:Gm.Reset + $branchSeg + $sessSeg + ' '
    $topVisLen = (Strip-AnsiCodes -Text $topTitle).Length
    $topDashes = $w - 3 - $topVisLen
    if ($topDashes -lt 2) { $topDashes = 2 }
    $lineTop = $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $topTitle + $script:Gm.Grey0 + ($script:Box.H * $topDashes) + $script:Box.TR + $script:Gm.Reset

    $stBar = if (Get-Command -Name 'Get-ContextStats' -ErrorAction SilentlyContinue) {
        Get-ContextStats -State $State
    }
    else {
        $cTmp = 0
        if ($State -and $State.messages) {
            foreach ($m in @($State.messages)) {
                if ($m.content) { $cTmp += ([string]$m.content).Length }
            }
        }
        @{ est_tokens = [int](($cTmp + 3) / 4); context_window_tokens = 128000; compact_threshold_tokens = 96000 }
    }
    $effStr = if ($script:ReasoningEffort) { ':' + $script:ReasoningEffort } elseif ($script:ShowReasoning -eq 'hide') { ':hide' } else { '' }
    $modelSeg = $script:Gm.Fg1 + $Model + $script:Gm.Grey1 + $effStr + $script:Gm.Reset
    $permSeg = Format-PermissionBadge -Permission $script:AgentPermission
    $gaugeSeg = Format-ContextGauge -Tokens $stBar.est_tokens -MaxTokens $stBar.context_window_tokens -CompactTokens $stBar.compact_threshold_tokens -Width 8
    $inTok = if ($State -and $State.usage_input_tokens) { [int]$State.usage_input_tokens } else { 0 }
    $outTok = if ($State -and $State.usage_output_tokens) { [int]$State.usage_output_tokens } else { 0 }
    $tokSeg = if (($inTok + $outTok) -gt 0) {
        ' ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + 'in:' + (Format-TokenCount -Tokens $inTok) + ' out:' + (Format-TokenCount -Tokens $outTok) + $script:Gm.Reset
    }
    else { '' }
    $todoList = if ($script:ActiveSessionTodos -and $script:ActiveSessionTodos.Count -gt 0) {
        $script:ActiveSessionTodos
    }
    elseif ($State -and $State.todos -and $State.todos.Count -gt 0) {
        $State.todos
    }
    else { @() }
    $todoSeg = if ($todoList.Count -gt 0) {
        $tTotal = $todoList.Count
        $tDone = @($todoList | Where-Object { $_.status -eq 'completed' }).Count
        $tInProg = @($todoList | Where-Object { $_.status -eq 'in_progress' }).Count
        $tColor = if ($tDone -eq $tTotal) { $script:Gm.Green } elseif ($tInProg -gt 0) { $script:Gm.Yellow } else { $script:Gm.Aqua }
        ' ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $tColor + "todo:$tDone/$tTotal" + $script:Gm.Reset
    }
    else { '' }
    $undoSeg = if ($UndoCount -gt 0) {
        ' ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Yellow + "undo:$UndoCount" + $script:Gm.Reset
    }
    else { '' }
    $sep = ' ' + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset + ' '
    $midContent = $modelSeg + $sep + $permSeg + $sep + $gaugeSeg + $tokSeg + $todoSeg + $undoSeg
    $midVisLen = (Strip-AnsiCodes -Text $midContent).Length
    $padRight = $innerW - $midVisLen
    $padStr = if ($padRight -gt 0) { ' ' * $padRight } else { '' }
    $lineMid = $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset + ' ' + $midContent + $padStr + ' ' + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset
    $lineBot = $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 2)) + $script:Box.BR + $script:Gm.Reset
    return @($lineTop, $lineMid, $lineBot)
}

function Write-TuiPromptFrame {
    param($State, [string]$Root, [string]$Model, [int]$UndoCount = 0)
    if ($script:OutputMode -eq 'json') { return }
    $wsName = if ($Root) { Split-Path $Root -Leaf } else { 'workspace' }
    if (-not $wsName) { $wsName = $Root }
    $titleSeq = "$script:Esc]0;shellossus - $wsName [$Model | $($script:AgentPermission)]$script:Bel"
    Write-Host ("`n" + $titleSeq) -NoNewline
    foreach ($ln in @(Format-TuiStatusBar -State $State -Root $Root -Model $Model -UndoCount $UndoCount)) {
        Write-Host $ln
    }
}
