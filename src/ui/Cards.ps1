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
    $Name = Format-TuiText $Name
    $Target = Format-TuiText $Target
    $Detail = Format-TuiText $Detail
    $Summary = Format-TuiText $Summary
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
    $Todos = @(if ($null -ne $Todos) { $Todos })
    if ($Todos.Count -eq 0) { return @() }
    $w = Get-TerminalWidth
    $total = $Todos.Count
    $done = @($Todos | Where-Object { $_.status -eq 'completed' }).Count
    $hdr = ' ' + $script:Gm.BoldAqua + 'TODO ' + $script:Gm.Fg1 + "($done/$total completed)" + $script:Gm.Reset + ' '
    $body = @()
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
        $body += ($icon + ' ' + $txtColor + (Format-TuiText $item.content) + $script:Gm.Reset)
    }
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
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
    $body = @()
    if ($Question) {
        $qClean = Format-TuiText $Question
        $body += ($script:Gm.BoldYellow + $qClean + $script:Gm.Reset)
        if ($Plan) {
            $body += ''
        }
    }
    if ($Plan) {
        $planLines = @($Plan -split "`r?`n")
        foreach ($pLine in $planLines) {
            $cleanLine = Format-PreviewText $pLine
            $formattedLine = Format-MarkdownInline -Text $cleanLine
            $body += $formattedLine
        }
    }
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
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
    $hdr = ' ' + $script:Gm.BoldPurple + 'MEMORY (' + (Format-TuiText $scopeLabel) + ')' + $script:Gm.Reset + ' '
    $body = @()
    if ($Content) {
        $lines = @($Content -split "`r?`n")
        foreach ($ln in $lines) {
            $cleanLine = Format-PreviewText $ln
            $formattedLine = Format-MarkdownInline -Text $cleanLine
            $body += $formattedLine
        }
    }
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
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
    $clean = (Format-PreviewText -Text $Line).Replace("`r", '').Replace("`t", '    ')
    if ($clean.Length -le $MaxChars) { return $clean }
    return ($clean.Substring(0, $MaxChars) + ' ...')
}

function Get-DiffMatchingBlocks {
    param(
        [array]$OldLines,
        [array]$NewLines,
        [int]$OldLow,
        [int]$OldHigh,
        [int]$NewLow,
        [int]$NewHigh
    )
    if ($OldLow -ge $OldHigh -or $NewLow -ge $NewHigh) {
        return @()
    }
    $newPosByLine = @{}
    for ($j = $NewLow; $j -lt $NewHigh; $j++) {
        $key = 'L:' + $NewLines[$j]
        if (-not $newPosByLine.ContainsKey($key)) {
            $newPosByLine[$key] = @($j)
        }
        elseif ($newPosByLine[$key].Count -lt 64) {
            $newPosByLine[$key] += $j
        }
    }
    $foundBlocks = @()
    $stack = @(@{ o_low = $OldLow; o_high = $OldHigh; n_low = $NewLow; n_high = $NewHigh })
    while ($stack.Count -gt 0) {
        $lastIdx = $stack.Count - 1
        $range = $stack[$lastIdx]
        $stack = @(if ($lastIdx -gt 0) { $stack[0..($lastIdx - 1)] } else { @() })
        $oLow = [int]$range.o_low
        $oHigh = [int]$range.o_high
        $nLow = [int]$range.n_low
        $nHigh = [int]$range.n_high
        if ($oLow -ge $oHigh -or $nLow -ge $nHigh) { continue }

        $bestO = -1
        $bestN = -1
        $bestLen = 0
        $bestScore = 0
        for ($o = $oLow; $o -lt $oHigh; $o++) {
            $key = 'L:' + $OldLines[$o]
            if (-not $newPosByLine.ContainsKey($key)) { continue }
            $candidates = $newPosByLine[$key]
            foreach ($n in $candidates) {
                if ($n -lt $nLow) { continue }
                if ($n -ge $nHigh) { break }
                if (($o -gt $oLow) -and ($n -gt $nLow) -and ($OldLines[$o - 1] -ceq $NewLines[$n - 1])) {
                    continue
                }
                if ($OldLines[$o] -cne $NewLines[$n]) { continue }
                $maxK = if (($oHigh - $o) -lt ($nHigh - $n)) { $oHigh - $o } else { $nHigh - $n }
                $k = 1
                while ($k -lt $maxK -and ($OldLines[$o + $k] -ceq $NewLines[$n + $k])) {
                    $k++
                }
                $score = if ($k -eq 1 -and ([string]$OldLines[$o]).Trim().Length -eq 0) { 1 } else { ($k * 2) + 1 }
                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $bestO = $o
                    $bestN = $n
                    $bestLen = $k
                }
            }
        }
        if ($bestLen -gt 0) {
            $foundBlocks += @{ o = $bestO; n = $bestN; len = $bestLen }
            if ($bestO -gt $oLow -and $bestN -gt $nLow) {
                $stack += @{ o_low = $oLow; o_high = $bestO; n_low = $nLow; n_high = $bestN }
            }
            if (($bestO + $bestLen) -lt $oHigh -and ($bestN + $bestLen) -lt $nHigh) {
                $stack += @{ o_low = ($bestO + $bestLen); o_high = $oHigh; n_low = ($bestN + $bestLen); n_high = $nHigh }
            }
        }
    }
    return @($foundBlocks | Sort-Object { $_.o })
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
    $maxDiffChars = if (($w - 18) -ge 20) { $w - 18 } else { 20 }
    $afterNorm = if ($After) { $After.Replace("`r`n", "`n") } else { '' }
    $newLines = @(if ($afterNorm.Length -gt 0) { $afterNorm -split "`n" } else { @() })
    if ($null -eq $Before) {
        $addedCount = $newLines.Count
        $hdr = ' ' + $script:Gm.BoldGreen + 'DIFF ' + (Format-TuiText $ToolName) + ': ' + $script:Gm.Fg1 + (Format-TuiText $Path) + ' ' + $script:Gm.Green + ("(+{0} new)" -f $addedCount) + $script:Gm.Reset + ' '
        $body = @()
        $showCount = if ($newLines.Count -gt $MaxLines) { $MaxLines } else { $newLines.Count }
        for ($i = 0; $i -lt $showCount; $i++) {
            $lnNum = ('{0,4}' -f ($i + 1))
            $txt = Format-DiffLinePreview -Line $newLines[$i] -MaxChars $maxDiffChars
            $body += ($script:Gm.Grey1 + $lnNum + ' ' + $script:Gm.BgDiffGreen + $script:Gm.Green + '+ ' + $txt + $script:Gm.Reset)
        }
        if ($newLines.Count -gt $MaxLines) {
            $body += ('     ... (' + ($newLines.Count - $MaxLines) + ' more lines)' + $script:Gm.Reset)
        }
        return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
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

    $allBlocks = @()
    if ($pref -gt 0) {
        $allBlocks += @{ o = 0; n = 0; len = $pref }
    }
    if ($oldEnd -ge $pref -and $newEnd -ge $pref) {
        foreach ($mb in @(Get-DiffMatchingBlocks -OldLines $oldLines -NewLines $newLines -OldLow $pref -OldHigh ($oldEnd + 1) -NewLow $pref -NewHigh ($newEnd + 1))) {
            $allBlocks += $mb
        }
    }
    $sufLen = $oldLines.Count - ($oldEnd + 1)
    if ($sufLen -gt 0) {
        $allBlocks += @{ o = ($oldEnd + 1); n = ($newEnd + 1); len = $sufLen }
    }
    $mergedBlocks = @()
    foreach ($blk in $allBlocks) {
        if ($blk.len -le 0) { continue }
        if ($mergedBlocks.Count -gt 0) {
            $prev = $mergedBlocks[$mergedBlocks.Count - 1]
            if (($prev.o + $prev.len) -eq $blk.o -and ($prev.n + $prev.len) -eq $blk.n) {
                $prev.len += $blk.len
                continue
            }
        }
        $mergedBlocks += @{ o = $blk.o; n = $blk.n; len = $blk.len }
    }
    $mergedBlocks += @{ o = $oldLines.Count; n = $newLines.Count; len = 0 }

    $opcodes = @()
    $addedCount = 0
    $removedCount = 0
    $currO = 0
    $currN = 0
    foreach ($blk in $mergedBlocks) {
        if ($currO -lt $blk.o -or $currN -lt $blk.n) {
            $delLen = $blk.o - $currO
            $insLen = $blk.n - $currN
            $removedCount += $delLen
            $addedCount += $insLen
            $tag = if ($delLen -gt 0 -and $insLen -gt 0) { 'replace' } elseif ($delLen -gt 0) { 'delete' } else { 'insert' }
            $opcodes += @{ tag = $tag; o1 = $currO; o2 = $blk.o; n1 = $currN; n2 = $blk.n }
        }
        if ($blk.len -gt 0) {
            $opcodes += @{ tag = 'equal'; o1 = $blk.o; o2 = ($blk.o + $blk.len); n1 = $blk.n; n2 = ($blk.n + $blk.len) }
        }
        $currO = $blk.o + $blk.len
        $currN = $blk.n + $blk.len
    }

    $effCtx = if ($ContextLines -ge 0) { $ContextLines } else { 0 }
    $hunks = @()
    if (($addedCount + $removedCount) -gt 0) {
        $group = @()
        for ($opIdx = 0; $opIdx -lt $opcodes.Count; $opIdx++) {
            $op = $opcodes[$opIdx]
            $isFirst = ($opIdx -eq 0)
            $isLast = ($opIdx -eq ($opcodes.Count - 1))
            if ($op.tag -eq 'equal') {
                if ($isFirst -and $isLast) {
                    continue
                }
                elseif ($isFirst) {
                    if ($effCtx -gt 0) {
                        $oStart = if (($op.o2 - $effCtx) -gt $op.o1) { $op.o2 - $effCtx } else { $op.o1 }
                        $nStart = if (($op.n2 - $effCtx) -gt $op.n1) { $op.n2 - $effCtx } else { $op.n1 }
                        if ($oStart -lt $op.o2) {
                            $group += @{ tag = 'equal'; o1 = $oStart; o2 = $op.o2; n1 = $nStart; n2 = $op.n2 }
                        }
                    }
                }
                elseif ($isLast) {
                    if ($effCtx -gt 0 -and $group.Count -gt 0) {
                        $oStop = if (($op.o1 + $effCtx) -lt $op.o2) { $op.o1 + $effCtx } else { $op.o2 }
                        $nStop = if (($op.n1 + $effCtx) -lt $op.n2) { $op.n1 + $effCtx } else { $op.n2 }
                        if ($op.o1 -lt $oStop) {
                            $group += @{ tag = 'equal'; o1 = $op.o1; o2 = $oStop; n1 = $op.n1; n2 = $nStop }
                        }
                    }
                }
                else {
                    $eqLen = $op.o2 - $op.o1
                    if ($eqLen -gt (2 * $effCtx)) {
                        if ($effCtx -gt 0 -and $group.Count -gt 0) {
                            $group += @{ tag = 'equal'; o1 = $op.o1; o2 = ($op.o1 + $effCtx); n1 = $op.n1; n2 = ($op.n1 + $effCtx) }
                        }
                        if ($group.Count -gt 0) {
                            $hunks += @{ ops = $group }
                            $group = @()
                        }
                        if ($effCtx -gt 0) {
                            $group += @{ tag = 'equal'; o1 = ($op.o2 - $effCtx); o2 = $op.o2; n1 = ($op.n2 - $effCtx); n2 = $op.n2 }
                        }
                    }
                    else {
                        $group += $op
                    }
                }
            }
            else {
                $group += $op
            }
        }
        if ($group.Count -gt 0) {
            $hunks += @{ ops = $group }
        }
    }

    $hdr = ' ' + $script:Gm.BoldYellow + 'DIFF ' + (Format-TuiText $ToolName) + ': ' + $script:Gm.Fg1 + (Format-TuiText $Path) + ' ' + $script:Gm.Green + ("+{0}" -f $addedCount) + ' ' + $script:Gm.Red + ("-{0}" -f $removedCount) + $script:Gm.Reset + ' '
    $body = @()
    $emitted = 0
    for ($hIdx = 0; $hIdx -lt $hunks.Count; $hIdx++) {
        if ($emitted -ge $MaxLines) { break }
        $hOps = @($hunks[$hIdx].ops)
        if ($hOps.Count -eq 0) { continue }
        $hOldStart = [int]$hOps[0].o1
        $hOldEnd = [int]$hOps[$hOps.Count - 1].o2
        $hNewStart = [int]$hOps[0].n1
        $hNewEnd = [int]$hOps[$hOps.Count - 1].n2
        $firstChangeOp = $hOps | Where-Object { $_.tag -ne 'equal' } | Select-Object -First 1
        $firstChangeLine = if ($firstChangeOp) { [int]$firstChangeOp.o1 + 1 } else { $hOldStart + 1 }
        if ($hunks.Count -gt 1 -or $hOldStart -gt 0) {
            $oldSpan = $hOldEnd - $hOldStart
            $newSpan = $hNewEnd - $hNewStart
            $body += ($script:Gm.Aqua + ("@@ -{0},{1} +{2},{3} (line {4}) @@" -f ($hOldStart + 1), $oldSpan, ($hNewStart + 1), $newSpan, $firstChangeLine) + $script:Gm.Reset)
        }
        foreach ($op in $hOps) {
            if ($op.tag -eq 'equal') {
                if ($emitted -ge $MaxLines) { break }
                for ($i = $op.o1; $i -lt $op.o2; $i++) {
                    $newLnIdx = $op.n1 + ($i - $op.o1)
                    $lnNum = ('{0,4}' -f ($newLnIdx + 1))
                    $txt = Format-DiffLinePreview -Line $oldLines[$i] -MaxChars $maxDiffChars
                    $body += ($script:Gm.Grey0 + $lnNum + '   ' + $txt + $script:Gm.Reset)
                }
            }
            else {
                for ($i = $op.o1; $i -lt $op.o2; $i++) {
                    if ($emitted -ge $MaxLines) { break }
                    $lnNum = ('{0,4}' -f ($i + 1))
                    $txt = Format-DiffLinePreview -Line $oldLines[$i] -MaxChars $maxDiffChars
                    $body += ($script:Gm.Red + $lnNum + ' ' + $script:Gm.BgDiffRed + $script:Gm.Red + '- ' + $txt + $script:Gm.Reset)
                    $emitted++
                }
                for ($i = $op.n1; $i -lt $op.n2; $i++) {
                    if ($emitted -ge $MaxLines) { break }
                    $lnNum = ('{0,4}' -f ($i + 1))
                    $txt = Format-DiffLinePreview -Line $newLines[$i] -MaxChars $maxDiffChars
                    $body += ($script:Gm.Green + $lnNum + ' ' + $script:Gm.BgDiffGreen + $script:Gm.Green + '+ ' + $txt + $script:Gm.Reset)
                    $emitted++
                }
            }
        }
    }
    if (($removedCount + $addedCount) -gt $MaxLines) {
        $more = ($removedCount + $addedCount) - $MaxLines
        $body += ("     ... ($more more changed lines)" + $script:Gm.Reset)
    }
    return @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)
}

function Write-UnifiedDiffCard {
    param([string]$Path, [string]$ToolName = 'edit_file', $Before = $null, [string]$After = '', [int]$ContextLines = 3, [int]$MaxLines = 80)
    if ($script:OutputMode -eq 'json') { return }
    foreach ($ln in @(Format-UnifiedDiff -Path $Path -ToolName $ToolName -Before $Before -After $After -ContextLines $ContextLines -MaxLines $MaxLines)) {
        Write-Host $ln
    }
}
