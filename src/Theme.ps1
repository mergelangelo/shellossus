# Terminal UI theme (sainnhe/gruvbox-material dark medium) and Markdown/table rendering.

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
    param([int]$Chars, [int]$MaxChars = 60000, [int]$Width = 10)
    if ($MaxChars -le 0) { $MaxChars = 60000 }
    if ($Width -lt 4) { $Width = 4 }
    $estTok = [int](($Chars + 3) / 4)
    $maxTok = [int](($MaxChars + 3) / 4)
    $pct = [int](($Chars * 100) / $MaxChars)
    if ($pct -lt 0) { $pct = 0 }
    $clampedPct = if ($pct -gt 100) { 100 } else { $pct }
    $filled = [int](($clampedPct * $Width + 50) / 100)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0) { $filled = 0 }
    $empty = $Width - $filled
    $barColor = if ($pct -ge 80) { $script:Gm.Red } elseif ($pct -ge 50) { $script:Gm.Yellow } else { $script:Gm.Green }
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

    $chars = 0
    if ($State -and $State.messages) {
        foreach ($m in @($State.messages)) {
            if ($m.content) { $chars += ([string]$m.content).Length }
        }
    }
    $effStr = if ($script:ReasoningEffort) { ':' + $script:ReasoningEffort } elseif ($script:ShowReasoning -eq 'hide') { ':hide' } else { '' }
    $modelSeg = $script:Gm.Fg1 + $Model + $script:Gm.Grey1 + $effStr + $script:Gm.Reset
    $permSeg = Format-PermissionBadge -Permission $script:AgentPermission
    $gaugeSeg = Format-ContextGauge -Chars $chars -MaxChars 60000 -Width 8
    $inTok = if ($State -and $State.usage_input_tokens) { [int]$State.usage_input_tokens } else { 0 }
    $outTok = if ($State -and $State.usage_output_tokens) { [int]$State.usage_output_tokens } else { 0 }
    $tokSeg = if (($inTok + $outTok) -gt 0) {
        ' ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + 'in:' + (Format-TokenCount -Tokens $inTok) + ' out:' + (Format-TokenCount -Tokens $outTok) + $script:Gm.Reset
    }
    else { '' }
    $undoSeg = if ($UndoCount -gt 0) {
        ' ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Yellow + "undo:$UndoCount" + $script:Gm.Reset
    }
    else { '' }
    $sep = ' ' + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset + ' '
    $midContent = $modelSeg + $sep + $permSeg + $sep + $gaugeSeg + $tokSeg + $undoSeg
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

function Format-ToolCallCard {
    param(
        [string]$Name,
        [string]$Target = '',
        [string]$Detail = '',
        [string]$Status = 'ok',
        [string]$Summary = '',
        [int]$ElapsedMs = -1
    )
    $targetPart = if ($Target) { ' ' + $script:Gm.Fg1 + $Target + $script:Gm.Reset } else { '' }
    $detailPart = if ($Detail) { ' ' + $script:Gm.Grey1 + '(' + $Detail + ')' + $script:Gm.Reset } else { '' }
    $top = '  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.Yellow + $script:Box.Arrow + ' ' + $Name + $script:Gm.Reset + $targetPart + $detailPart
    $icon = if ($Status -in @('error', 'cancelled', 'timed_out')) {
        $script:Gm.Red + $script:Box.Cross + $script:Gm.Reset
    }
    else {
        $script:Gm.Green + $script:Box.Check + $script:Gm.Reset
    }
    $sumColor = if ($Status -in @('error', 'cancelled', 'timed_out')) { $script:Gm.Red } else { $script:Gm.Grey2 }
    $sumPart = if ($Summary) { ' ' + $sumColor + $Summary + $script:Gm.Reset } else { ' ' + $sumColor + $Status + $script:Gm.Reset }
    $timePart = if ($ElapsedMs -ge 0) { $script:Gm.Grey0 + ' | ' + $script:Gm.Grey1 + ("{0}ms" -f $ElapsedMs) + $script:Gm.Reset } else { '' }
    $bot = '  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $icon + $sumPart + $timePart
    return @($top, $bot)
}

function Write-ToolCallCard {
    param(
        [string]$Name,
        [string]$Target = '',
        [string]$Detail = '',
        [string]$Status = 'ok',
        [string]$Summary = '',
        [int]$ElapsedMs = -1
    )
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-ToolCallCard -Name $Name -Target $Target -Detail $Detail -Status $Status -Summary $Summary -ElapsedMs $ElapsedMs)) {
        Write-Host $ln
    }
}

function Format-DiffLinePreview {
    param([string]$Line, [int]$MaxChars = 180)
    $clean = Format-PreviewText $Line
    if ($clean.Length -le $MaxChars) { return $clean }
    return ($clean.Substring(0, $MaxChars) + ' ...')
}

function Format-UnifiedDiff {
    param(
        [string]$Path,
        [string]$ToolName = 'edit_file',
        $Before = $null,
        [string]$After = '',
        [int]$ContextLines = 3,
        [int]$MaxLines = 80
    )
    $w = Get-TerminalWidth
    $afterNorm = if ($After) { $After.Replace("`r`n", "`n") } else { '' }
    $newLines = @(if ($afterNorm.Length -gt 0) { $afterNorm -split "`n" } else { @() })
    if ($null -eq $Before) {
        $addedCount = $newLines.Count
        $hdr = ' ' + $script:Gm.BoldGreen + 'DIFF ' + $ToolName + ': ' + $script:Gm.Fg1 + $Path + ' ' + $script:Gm.Green + ("(+{0} new)" -f $addedCount) + $script:Gm.Reset + ' '
        $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
        $dashes = $w - 5 - $hdrVis
        if ($dashes -lt 2) { $dashes = 2 }
        $out = @('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
        $showCount = if ($newLines.Count -gt $MaxLines) { $MaxLines } else { $newLines.Count }
        for ($i = 0; $i -lt $showCount; $i++) {
            $lnNum = ('{0,4}' -f ($i + 1))
            $txt = Format-DiffLinePreview -Line $newLines[$i]
            $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + $lnNum + ' ' + $script:Gm.BgDiffGreen + $script:Gm.Green + '+ ' + $txt + $script:Gm.Reset)
        }
        if ($newLines.Count -gt $MaxLines) {
            $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + '      ... (' + ($newLines.Count - $MaxLines) + ' more lines)' + $script:Gm.Reset)
        }
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
        return $out
    }
    $beforeNorm = $Before.Replace("`r`n", "`n")
    $oldLines = @(if ($beforeNorm.Length -gt 0) { $beforeNorm -split "`n" } else { @() })
    $pref = 0
    $minLen = if ($oldLines.Count -lt $newLines.Count) { $oldLines.Count } else { $newLines.Count }
    while ($pref -lt $minLen -and ($oldLines[$pref] -ceq $newLines[$pref])) {
        $pref++
    }
    $oldEnd = $oldLines.Count - 1
    $newEnd = $newLines.Count - 1
    while ($oldEnd -ge $pref -and $newEnd -ge $pref -and ($oldLines[$oldEnd] -ceq $newLines[$newEnd])) {
        $oldEnd--
        $newEnd--
    }
    $removedCount = if ($oldEnd -ge $pref) { $oldEnd - $pref + 1 } else { 0 }
    $addedCount = if ($newEnd -ge $pref) { $newEnd - $pref + 1 } else { 0 }
    $hdr = ' ' + $script:Gm.BoldYellow + 'DIFF ' + $ToolName + ': ' + $script:Gm.Fg1 + $Path + ' ' + $script:Gm.Green + ("+{0}" -f $addedCount) + ' ' + $script:Gm.Red + ("-{0}" -f $removedCount) + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $out = @('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    $ctxStart = $pref - $ContextLines
    if ($ctxStart -lt 0) { $ctxStart = 0 }
    if ($ctxStart -gt 0) {
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + ("@@ line {0} @@" -f ($pref + 1)) + $script:Gm.Reset)
    }
    for ($i = $ctxStart; $i -lt $pref; $i++) {
        $lnNum = ('{0,4}' -f ($i + 1))
        $txt = Format-DiffLinePreview -Line $oldLines[$i]
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey0 + $lnNum + '   ' + $txt + $script:Gm.Reset)
    }
    $emitted = 0
    for ($i = $pref; $i -le $oldEnd; $i++) {
        if ($emitted -ge $MaxLines) { break }
        $lnNum = ('{0,4}' -f ($i + 1))
        $txt = Format-DiffLinePreview -Line $oldLines[$i]
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Red + $lnNum + ' ' + $script:Gm.BgDiffRed + $script:Gm.Red + '- ' + $txt + $script:Gm.Reset)
        $emitted++
    }
    for ($i = $pref; $i -le $newEnd; $i++) {
        if ($emitted -ge $MaxLines) { break }
        $lnNum = ('{0,4}' -f ($i + 1))
        $txt = Format-DiffLinePreview -Line $newLines[$i]
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Green + $lnNum + ' ' + $script:Gm.BgDiffGreen + $script:Gm.Green + '+ ' + $txt + $script:Gm.Reset)
        $emitted++
    }
    if (($removedCount + $addedCount) -gt $MaxLines) {
        $more = ($removedCount + $addedCount) - $MaxLines
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + "      ... ($more more changed lines)" + $script:Gm.Reset)
    }
    $ctxAfterEnd = $oldEnd + $ContextLines
    if ($ctxAfterEnd -ge $oldLines.Count) { $ctxAfterEnd = $oldLines.Count - 1 }
    for ($i = $oldEnd + 1; $i -le $ctxAfterEnd; $i++) {
        $newLnIdx = $newEnd + 1 + ($i - ($oldEnd + 1))
        $lnNum = ('{0,4}' -f ($newLnIdx + 1))
        $txt = Format-DiffLinePreview -Line $oldLines[$i]
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey0 + $lnNum + '   ' + $txt + $script:Gm.Reset)
    }
    $out += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
    return $out
}

function Write-UnifiedDiffCard {
    param([string]$Path, [string]$ToolName = 'edit_file', $Before = $null, [string]$After = '')
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-UnifiedDiff -Path $Path -ToolName $ToolName -Before $Before -After $After)) {
        Write-Host $ln
    }
}

function Read-TuiMultilineInput {
    $first = Read-Host
    if ($null -eq $first) { return '' }
    if ($first.StartsWith('"""') -or $first.StartsWith('<<<')) {
        $fence = if ($first.StartsWith('"""')) { '"""' } else { '>>>' }
        $altFence = $first.Substring(0, 3)
        $rest = $first.Substring(3)
        if ($rest.Length -ge 3 -and ($rest.EndsWith($fence) -or $rest.EndsWith($altFence))) {
            return $rest.Substring(0, $rest.Length - 3)
        }
        $lines = @()
        if ($rest) { $lines += $rest }
        while ($true) {
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Grey0 + '  ' + $script:Box.V + ' ... ' + $script:Gm.Fg) -NoNewline
            }
            $next = Read-Host
            if ($script:OutputMode -ne 'json') {
                Write-Host $script:Gm.Reset -NoNewline
            }
            if ($null -eq $next) { break }
            if ($next.EndsWith($fence) -or $next.EndsWith($altFence)) {
                $beforeClose = $next.Substring(0, $next.Length - 3)
                if ($beforeClose -or $lines.Count -gt 0) { $lines += $beforeClose }
                break
            }
            $lines += $next
        }
        return ($lines -join "`n")
    }
    if ($first.EndsWith('\') -and (-not ($first -match '^[a-zA-Z]:\\$'))) {
        $lines = @($first.Substring(0, $first.Length - 1))
        while ($true) {
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Grey0 + '  ' + $script:Box.V + ' ... ' + $script:Gm.Fg) -NoNewline
            }
            $next = Read-Host
            if ($script:OutputMode -ne 'json') {
                Write-Host $script:Gm.Reset -NoNewline
            }
            if ($null -eq $next) { break }
            if ($next.EndsWith('\')) {
                $lines += $next.Substring(0, $next.Length - 1)
                continue
            }
            $lines += $next
            break
        }
        return ($lines -join "`n")
    }
    return $first
}

function Invoke-TuiSelector {
    param(
        [string]$Title,
        [array]$Items,
        [string]$PromptText = 'Select number (Enter cancels)'
    )
    if (-not $Items -or $Items.Count -eq 0) { return $null }
    if ($script:OutputMode -ne 'json') {
        $w = Get-TerminalWidth
        $hdr = ' ' + $script:Gm.BoldOrange + $Title + $script:Gm.Reset + ' '
        $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
        $dashes = $w - 5 - $hdrVis
        if ($dashes -lt 2) { $dashes = 2 }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $it = $Items[$i]
            $marker = if ($it.active) { $script:Gm.BoldGreen + $script:Box.Dot + $script:Gm.Reset } else { ' ' }
            $numStr = $script:Gm.Yellow + ("[{0}]" -f ($i + 1)) + $script:Gm.Reset
            $lblStr = $script:Gm.Aqua + [string]$it.label + $script:Gm.Reset
            $descStr = if ($it.description) { $script:Gm.Grey1 + ' - ' + [string]$it.description + $script:Gm.Reset } else { '' }
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Reset + " $marker $numStr $lblStr$descStr")
        }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
        Write-Host ('  ' + $script:Gm.BoldYellow + $PromptText + ': ' + $script:Gm.Fg) -NoNewline
    }
    $rawChoice = Read-Host
    if ($script:OutputMode -ne 'json') {
        Write-Host $script:Gm.Reset -NoNewline
    }
    if (-not $rawChoice -or -not $rawChoice.Trim()) { return $null }
    $trimmed = $rawChoice.Trim()
    if ($trimmed -match '^\d+$') {
        $idx = [int]$trimmed - 1
        if ($idx -ge 0 -and $idx -lt $Items.Count) {
            $picked = $Items[$idx]
            return $(if ($null -ne $picked.value) { $picked.value } else { $picked.label })
        }
    }
    foreach ($it in $Items) {
        $val = if ($null -ne $it.value) { [string]$it.value } else { [string]$it.label }
        if ($val -ieq $trimmed -or ([string]$it.label -ieq $trimmed)) {
            return $val
        }
    }
    return $null
}

function Get-VisibleLength {
    param([string]$Text)
    $plain = ''
    foreach ($part in @($Text -split '(`[^`]+`)')) {
        if (-not $part) { continue }
        if ($part.StartsWith('`') -and $part.EndsWith('`') -and $part.Length -ge 2) {
            $plain += $part.Substring(1, $part.Length - 2)
        }
        else {
            $s = $part -replace '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)'
            $s = $s -replace '\*\*([^*]+)\*\*', '$1'
            $s = $s -replace '(?<!\*)\*([^*\s][^*]*?)\*(?!\*)', '$1'
            $plain += $s
        }
    }
    return $plain.Length
}

function Format-MarkdownInline {
    param([string]$Text, [string]$BaseColor = $script:Gm.Fg)
    $out = $BaseColor
    foreach ($part in @($Text -split '(`[^`]+`)')) {
        if (-not $part) { continue }
        if ($part.StartsWith('`') -and $part.EndsWith('`') -and $part.Length -ge 2) {
            $code = $part.Substring(1, $part.Length - 2)
            $out += $script:Gm.Bg1 + $script:Gm.Aqua + $code + $script:Gm.Reset + $BaseColor
        }
        else {
            $s = $part -replace '\[([^\]]+)\]\(([^)]+)\)', ($script:Gm.Blue + '$1' + $script:Gm.Reset + $BaseColor + ' (' + $script:Gm.Aqua + '$2' + $script:Gm.Reset + $BaseColor + ')')
            $s = $s -replace '\*\*([^*]+)\*\*', ($script:Gm.BoldOrange + '$1' + $script:Gm.Reset + $BaseColor)
            $s = $s -replace '(?<!\*)\*([^*\s][^*]*?)\*(?!\*)', ($script:Gm.Purple + '$1' + $script:Gm.Reset + $BaseColor)
            $out += $s
        }
    }
    return ($out + $script:Gm.Reset)
}

function Format-MarkdownTable {
    param($Lines, [string]$Indent = '')
    $rows = @()
    $colCount = 0
    foreach ($raw in @($Lines)) {
        $trimmed = $raw.Trim()
        if ($trimmed.StartsWith('|')) { $trimmed = $trimmed.Substring(1) }
        if ($trimmed.EndsWith('|')) { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1) }
        $cells = @($trimmed -split '\|' | ForEach-Object { $_.Trim() })
        $isSep = $true
        foreach ($c in $cells) {
            if ($c -notmatch '^:?-{2,}:?$') { $isSep = $false; break }
        }
        if ($cells.Count -gt $colCount) { $colCount = $cells.Count }
        $rows += @{ cells = $cells; isSep = $isSep }
    }
    if ($colCount -eq 0) { return @() }
    $widths = @(1..$colCount | ForEach-Object { 3 })
    foreach ($r in $rows) {
        if ($r.isSep) { continue }
        for ($i = 0; $i -lt $r.cells.Count; $i++) {
            $len = Get-VisibleLength -Text $r.cells[$i]
            if ($len -gt $widths[$i]) { $widths[$i] = $len }
        }
    }
    $result = @()
    $headerDone = $false
    foreach ($r in $rows) {
        if ($r.isSep) {
            $sepParts = @()
            for ($i = 0; $i -lt $colCount; $i++) { $sepParts += ('-' * $widths[$i]) }
            $result += ($Indent + $script:Gm.Grey0 + '|-' + ($sepParts -join '-+-') + '-|' + $script:Gm.Reset)
            $headerDone = $true
            continue
        }
        $lineOut = $Indent + $script:Gm.Grey0 + '| ' + $script:Gm.Reset
        $baseColor = if (-not $headerDone) { $script:Gm.BoldBlue } else { $script:Gm.Fg }
        for ($i = 0; $i -lt $colCount; $i++) {
            $val = if ($i -lt $r.cells.Count) { $r.cells[$i] } else { '' }
            $visLen = Get-VisibleLength -Text $val
            $padLen = $widths[$i] - $visLen
            $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }
            $sep = if ($i -lt ($colCount - 1)) { ' | ' } else { ' |' }
            $lineOut += (Format-MarkdownInline -Text $val -BaseColor $baseColor) + $pad + $script:Gm.Grey0 + $sep + $script:Gm.Reset
        }
        $result += $lineOut
    }
    return $result
}

function Write-AgentReply {
    param([string]$Content)
    if ($script:OutputMode -eq 'json') { return }
    $barV = $script:Gm.Grey0 + '  ' + $script:Box.V + ' ' + $script:Gm.Reset
    Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' Shellossus' + $script:Gm.Reset)
    $inCode = $false
    $tableBuf = @()
    $lines = @($Content -split "`r?`n")
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $line = $lines[$idx]
        $isTableLine = (-not $inCode) -and ($line -match '^\s*\|.*\|\s*$')
        if ($isTableLine) {
            $tableBuf += $line
            continue
        }
        if ($tableBuf.Count -gt 0) {
            foreach ($tLine in @(Format-MarkdownTable -Lines $tableBuf -Indent '')) {
                Write-Host ($barV + $tLine)
            }
            $tableBuf = @()
        }
        $trimmedStart = $line.TrimStart()
        if ($trimmedStart.StartsWith('```')) {
            if (-not $inCode) {
                $lang = $trimmedStart.Substring(3).Trim()
                $label = if ($lang) { " $lang " } else { ' code ' }
                Write-Host ($barV + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Aqua + $label + $script:Gm.Grey0 + ($script:Box.H * 24) + $script:Gm.Reset)
            }
            else {
                Write-Host ($barV + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 30) + $script:Gm.Reset)
            }
            $inCode = -not $inCode
        }
        elseif ($inCode) {
            Write-Host ($barV + $script:Gm.Grey0 + $script:Box.V + $script:Gm.Bg1 + $script:Gm.Yellow + '  ' + $line + '  ' + $script:Gm.Reset)
        }
        elseif ($line -match '^\s*(#{1,6})\s+(.*)$') {
            $level = $Matches[1].Length
            $hColor = switch ($level) {
                1 { $script:Gm.BoldRed }
                2 { $script:Gm.BoldOrange }
                3 { $script:Gm.BoldYellow }
                default { $script:Gm.BoldGreen }
            }
            Write-Host ($barV + (Format-MarkdownInline -Text $Matches[2] -BaseColor $hColor))
        }
        elseif ($line -match '^\s*([-*_]){3,}\s*$') {
            Write-Host ($barV + $script:Gm.Grey0 + ($script:Box.H * 40) + $script:Gm.Reset)
        }
        elseif ($line -match '^(\s*)>\s?(.*)$') {
            Write-Host ($barV + $Matches[1] + $script:Gm.Grey0 + $script:Box.V + ' ' + (Format-MarkdownInline -Text $Matches[2] -BaseColor $script:Gm.Grey2))
        }
        elseif ($line -match '^(\s*)([-*+]|\d+\.)\s+(.*)$') {
            Write-Host ($barV + $Matches[1] + $script:Gm.Green + $Matches[2] + ' ' + $script:Gm.Reset + (Format-MarkdownInline -Text $Matches[3] -BaseColor $script:Gm.Fg))
        }
        else {
            Write-Host ($barV + (Format-MarkdownInline -Text $line -BaseColor $script:Gm.Fg))
        }
    }
    if ($tableBuf.Count -gt 0) {
        foreach ($tLine in @(Format-MarkdownTable -Lines $tableBuf -Indent '')) {
            Write-Host ($barV + $tLine)
        }
    }
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 16) + $script:Gm.Reset)
}

function Write-AgentReasoning {
    param([string]$Text)
    if (-not $Text -or $script:ShowReasoning -eq 'hide' -or $script:OutputMode -eq 'json') { return }
    $lines = @($Text.Trim() -split "`r?`n")
    if ($script:ShowReasoning -eq 'full' -or $lines.Count -le 3) {
        Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' [reasoning]' + $script:Gm.Reset)
        foreach ($l in $lines) {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + (Format-PreviewText $l) + $script:Gm.Reset)
        }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 12) + $script:Gm.Reset)
    }
    else {
        Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + " [reasoning: last 3 of $($lines.Count) lines | /reasoning full to expand]" + $script:Gm.Reset)
        foreach ($l in @($lines | Select-Object -Last 3)) {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + (Format-PreviewText $l) + $script:Gm.Reset)
        }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 12) + $script:Gm.Reset)
    }
}
