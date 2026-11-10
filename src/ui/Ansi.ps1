# ANSI string helpers, terminal width, box framing, context gauge, and status bar.

function Strip-AnsiCodes {
    param([string]$Text)
    if (-not $Text) { return '' }
    $s = $Text -replace '\x1b\][^\x07]*\x07', ''
    $s = $s -replace '\x1b\[[0-9;?]*[a-zA-Z]', ''
    return $s
}

function Get-TerminalWidth {
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI) {
            $w = 0
            if ($Host.UI.RawUI.WindowSize -and $Host.UI.RawUI.WindowSize.Width) {
                $w = [int]$Host.UI.RawUI.WindowSize.Width
            }
            if ($w -le 0 -and $Host.UI.RawUI.BufferSize -and $Host.UI.RawUI.BufferSize.Width) {
                $w = [int]$Host.UI.RawUI.BufferSize.Width
            }
            if ($w -ge 35 -and $w -le 500) {
                return ($w - 1)
            }
        }
    }
    catch {}
    return 90
}

function Limit-AnsiLineToWidth {
    param(
        [string]$Text,
        [int]$MaxWidth
    )
    if (-not $Text -or $MaxWidth -le 0) { return '' }
    $plain = Strip-AnsiCodes -Text $Text
    if ($plain.Length -le $MaxWidth) { return $Text }
    $ellipsis = if ($MaxWidth -ge 4) { '...' } else { '' }
    $targetVis = $MaxWidth - $ellipsis.Length
    if ($targetVis -le 0) {
        return ($plain.Substring(0, $MaxWidth))
    }
    $tokens = @($Text -split '(\x1b\][^\x07]*\x07|\x1b\[[0-9;?]*[a-zA-Z])')
    $out = ''
    $visCount = 0
    $hasAnsi = $false
    foreach ($tok in $tokens) {
        if (-not $tok) { continue }
        if ($tok -match '^\x1b') {
            $hasAnsi = $true
            if ($visCount -lt $targetVis) {
                $out += $tok
            }
            continue
        }
        $rem = $targetVis - $visCount
        if ($rem -le 0) { break }
        if ($tok.Length -le $rem) {
            $out += $tok
            $visCount += $tok.Length
        }
        else {
            $out += $tok.Substring(0, $rem)
            $visCount += $rem
            break
        }
    }
    $out += $ellipsis
    if ($hasAnsi) { $out += $script:Gm.Reset }
    return $out
}

function Split-AnsiLineToWidth {
    param(
        [string]$Text,
        [int]$MaxWidth
    )
    if ($null -eq $Text) { return @('') }
    if ($MaxWidth -le 0) { return @($Text) }
    $plain = Strip-AnsiCodes -Text $Text
    if ($plain.Length -le $MaxWidth) { return @($Text) }
    $tokens = @($Text -split '(\x1b\][^\x07]*\x07|\x1b\[[0-9;?]*[a-zA-Z])')
    $lines = @()
    $currLine = ''
    $currVis = 0
    $activeFg = ''
    $activeBg = ''
    foreach ($tok in $tokens) {
        if (-not $tok) { continue }
        if ($tok -match '^\x1b') {
            $currLine += $tok
            if ($tok -eq "$script:Esc[0m") {
                $activeFg = ''
                $activeBg = ''
            }
            elseif ($tok -match '^\x1b\[(?:0;)?48;') {
                $activeBg = $tok
            }
            elseif ($tok -match '^\x1b\[') {
                $activeFg = $tok
            }
            continue
        }
        $pos = 0
        while ($pos -lt $tok.Length) {
            $remCols = $MaxWidth - $currVis
            $remChars = $tok.Length - $pos
            if ($remChars -le $remCols) {
                $currLine += $tok.Substring($pos)
                $currVis += $remChars
                break
            }
            $slice = $tok.Substring($pos, $remCols)
            $breakLen = $remCols
            $advanceLen = $remCols
            $lastSpace = $slice.LastIndexOf(' ')
            if ($lastSpace -ge 0 -and ($currVis + $lastSpace) -ge [int]($MaxWidth / 2)) {
                $breakLen = $lastSpace
                $advanceLen = $lastSpace + 1
            }
            $currLine += $tok.Substring($pos, $breakLen)
            if ($activeFg -or $activeBg) {
                $currLine += $script:Gm.Reset
            }
            $lines += $currLine
            $currLine = $activeBg + $activeFg
            $currVis = 0
            $pos += $advanceLen
        }
    }
    if ($currVis -gt 0 -or $lines.Count -eq 0) {
        if ($activeFg -or $activeBg) {
            $currLine += $script:Gm.Reset
        }
        $lines += $currLine
    }
    return $lines
}

function Format-TuiCardBox {
    param(
        [string]$Header,
        $BodyLines = @(),
        [string]$Indent = '  ',
        [int]$Width = 0
    )
    $w = if ($Width -ge 30) { $Width } else { Get-TerminalWidth }
    $indLen = $Indent.Length
    $boxW = $w
    if ($boxW -lt ($indLen + 14)) {
        $boxW = $indLen + 14
    }
    $innerW = $boxW - $indLen - 4
    $maxHdrVis = $boxW - $indLen - 5
    $effHeader = $Header
    $hdrVis = (Strip-AnsiCodes -Text $effHeader).Length
    if ($hdrVis -gt $maxHdrVis) {
        $effHeader = Limit-AnsiLineToWidth -Text $effHeader -MaxWidth $maxHdrVis
        $hdrVis = (Strip-AnsiCodes -Text $effHeader).Length
    }
    $rowMeta = @()
    if ($null -ne $BodyLines) {
        foreach ($rawItem in @($BodyLines)) {
            $itemStr = if ($null -ne $rawItem) { [string]$rawItem } else { '' }
            $subLines = @($itemStr -split "`r?`n")
            foreach ($rawLn in $subLines) {
                $cleanLn = $rawLn.Replace("`r", '').Replace("`t", '    ')
                foreach ($wrappedLn in @(Split-AnsiLineToWidth -Text $cleanLn -MaxWidth $innerW)) {
                    $vLen = (Strip-AnsiCodes -Text $wrappedLn).Length
                    $rowMeta += @{ text = $wrappedLn; vis = $vLen }
                }
            }
        }
    }
    $dashes = $boxW - $indLen - 3 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $out = @(
        ($Indent + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $effHeader + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    )
    foreach ($rm in $rowMeta) {
        $padLen = $innerW - $rm.vis
        $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }
        $out += ($Indent + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset + ' ' + $rm.text + $pad + ' ' + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset)
    }
    $out += ($Indent + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($boxW - $indLen - 2)) + $script:Box.BR + $script:Gm.Reset)
    return $out
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
            if ($gitItem -and (($gitItem.Attributes -band 1024) -eq 0)) {
                $gitDirFull = ''
                if ($gitItem.PSIsContainer) {
                    $gitDirFull = $gitItem.FullName
                }
                else {
                    $gitPtrRaw = Get-Content -LiteralPath $dotGit -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($gitPtrRaw -and ([string]$gitPtrRaw).Trim() -match '^gitdir:\s*(.+)$') {
                        $ptrTarget = $Matches[1].Trim()
                        $candDir = if ($ptrTarget -match '^([a-zA-Z]:[/\\]|[/\\])') { $ptrTarget } else { Join-Path $curr $ptrTarget }
                        if (Test-Path -LiteralPath $candDir) {
                            $candItem = Get-Item -LiteralPath $candDir -Force -ErrorAction SilentlyContinue
                            if ($candItem -and $candItem.PSIsContainer -and (($candItem.Attributes -band 1024) -eq 0)) {
                                $gitDirFull = $candItem.FullName
                            }
                        }
                    }
                }
                if ($gitDirFull) {
                    $headFile = Join-Path $gitDirFull 'HEAD'
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
    $w = if ($Width -ge 30) { $Width } else { Get-TerminalWidth }
    if ($w -lt 30) { $w = 30 }
    $innerW = $w - 4
    $wsName = if ($Root) { Split-Path $Root -Leaf } else { 'workspace' }
    if (-not $wsName) { $wsName = $Root }
    $branch = Get-GitBranchLabel -Root $Root
    $branchSeg = if ($branch) { ' ' + $script:Gm.Purple + '(' + (Format-TuiText $branch) + ')' + $script:Gm.Reset } else { '' }
    $sessLabel = if ($State -and $State.session_name) { [string]$State.session_name } elseif ($State -and $State.session_id) { [string]$State.session_id } else { '' }
    $sessSeg = if ($sessLabel) { ' ' + $script:Gm.Grey0 + $script:Box.H + ' ' + $script:Gm.Grey1 + (Format-TuiText $sessLabel) + $script:Gm.Reset } else { '' }
    $topTitle = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' ' + (Format-TuiText $wsName) + $script:Gm.Reset + $branchSeg + $sessSeg + ' '
    $maxTopVis = $w - 5
    $topVisLen = (Strip-AnsiCodes -Text $topTitle).Length
    if ($topVisLen -gt $maxTopVis) {
        $topTitle = Limit-AnsiLineToWidth -Text $topTitle -MaxWidth $maxTopVis
        $topVisLen = (Strip-AnsiCodes -Text $topTitle).Length
    }
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
    $modelSeg = $script:Gm.Fg1 + (Format-TuiText $Model) + $script:Gm.Grey1 + $effStr + $script:Gm.Reset
    $permSeg = Format-PermissionBadge -Permission $script:AgentPermission
    $gaugeW = if ($innerW -lt 90) { 4 } else { 8 }
    $gaugeSeg = Format-ContextGauge -Tokens $stBar.est_tokens -MaxTokens $stBar.context_window_tokens -CompactTokens $stBar.compact_threshold_tokens -Width $gaugeW
    $inTok = if ($State -and $State.usage_input_tokens) { [int]$State.usage_input_tokens } else { 0 }
    $outTok = if ($State -and $State.usage_output_tokens) { [int]$State.usage_output_tokens } else { 0 }
    $tokSeg = if (($inTok + $outTok) -gt 0) {
        ' ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + 'in:' + (Format-TokenCount -Tokens $inTok) + ' out:' + (Format-TokenCount -Tokens $outTok) + $script:Gm.Reset
    }
    else { '' }
    $todoList = @(if ($script:ActiveSessionTodos -and @($script:ActiveSessionTodos).Count -gt 0) {
        @($script:ActiveSessionTodos)
    }
    elseif ($State -and $State.todos -and @($State.todos).Count -gt 0) {
        @($State.todos)
    }
    else {
        @()
    })
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
    $outLines = @($lineTop)
    foreach ($midChunk in @(Split-AnsiLineToWidth -Text $midContent -MaxWidth $innerW)) {
        $chunkVis = (Strip-AnsiCodes -Text $midChunk).Length
        $padRight = $innerW - $chunkVis
        $padStr = if ($padRight -gt 0) { ' ' * $padRight } else { '' }
        $outLines += ($script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset + ' ' + $midChunk + $padStr + ' ' + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset)
    }
    $outLines += ($script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 2)) + $script:Box.BR + $script:Gm.Reset)
    return $outLines
}

function Write-TuiPromptFrame {
    param($State, [string]$Root, [string]$Model, [int]$UndoCount = 0)
    if ($script:OutputMode -eq 'json') { return }
    $wsName = if ($Root) { Split-Path $Root -Leaf } else { 'workspace' }
    if (-not $wsName) { $wsName = $Root }
    $titleSeq = "$script:Esc]0;shellossus - $(Format-TuiText $wsName) [$(Format-TuiText $Model) | $($script:AgentPermission)]$script:Bel"
    Write-Host ("`n" + $titleSeq) -NoNewline
    foreach ($ln in @(Format-TuiStatusBar -State $State -Root $Root -Model $Model -UndoCount $UndoCount)) {
        Write-Host $ln
    }
}
