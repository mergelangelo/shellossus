# Terminal UI cards (tool calls, todo checklists, plan reviews, memory cards, and unified diffs).

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

function Format-TodoCard {
    param($Todos)
    if ($null -eq $Todos -or $Todos.Count -eq 0) { return @() }
    $w = Get-TerminalWidth
    $total = $Todos.Count
    $done = @($Todos | Where-Object { $_.status -eq 'completed' }).Count
    $hdr = ' ' + $script:Gm.BoldAqua + 'TODO ' + $script:Gm.Fg1 + "($done/$total completed)" + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $out = @('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    foreach ($item in $Todos) {
        $st = [string]$item.status
        $icon = switch ($st) {
            'completed'   { $script:Gm.Green + '[x]' + $script:Gm.Reset }
            'in_progress' { $script:Gm.Yellow + '[>]' + $script:Gm.Reset }
            default       { $script:Gm.Grey1 + '[ ]' + $script:Gm.Reset }
        }
        $txtColor = switch ($st) {
            'completed'   { $script:Gm.Grey1 }
            'in_progress' { $script:Gm.BoldYellow }
            default       { $script:Gm.Fg1 }
        }
        $lineText = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $icon + ' ' + $txtColor + (Format-PreviewText $item.content) + $script:Gm.Reset
        $out += $lineText
    }
    $out += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
    return $out
}

function Write-TodoCard {
    param($Todos)
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-TodoCard -Todos $Todos)) {
        Write-Host $ln
    }
}

function Format-PlanReviewCard {
    param([string]$Question, [string]$Plan)
    $w = Get-TerminalWidth
    $hdr = ' ' + $script:Gm.BoldOrange + 'PLAN REVIEW' + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $out = @('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    if ($Question) {
        $qClean = Format-PreviewText $Question
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.BoldYellow + $qClean + $script:Gm.Reset)
        $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + (' ' * ($w - 4)) + $script:Box.V + $script:Gm.Reset)
    }
    if ($Plan) {
        $planLines = @($Plan -split "`r?`n")
        foreach ($pLine in $planLines) {
            $cleanLine = Format-PreviewText $pLine
            $formattedLine = Format-MarkdownInline -Text $cleanLine
            $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $formattedLine + $script:Gm.Reset)
        }
    }
    $out += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
    return $out
}

function Write-PlanReviewCard {
    param([string]$Question, [string]$Plan)
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-PlanReviewCard -Question $Question -Plan $Plan)) {
        Write-Host $ln
    }
}

function Format-MemoryCard {
    param([string]$Scope, [string]$Action, [string]$Content)
    $w = Get-TerminalWidth
    $scopeLabel = if ($Scope) { [string]$Scope.ToUpper() } else { 'WORKSPACE' }
    $hdr = ' ' + $script:Gm.BoldPurple + 'MEMORY (' + $scopeLabel + ')' + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $out = @('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    if ($Content) {
        $lines = @($Content -split "`r?`n")
        foreach ($ln in $lines) {
            $cleanLine = Format-PreviewText $ln
            $formattedLine = Format-MarkdownInline -Text $cleanLine
            $out += ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $formattedLine + $script:Gm.Reset)
        }
    }
    $out += ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
    return $out
}

function Write-MemoryCard {
    param([string]$Scope, [string]$Action, [string]$Content)
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-MemoryCard -Scope $Scope -Action $Action -Content $Content)) {
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
