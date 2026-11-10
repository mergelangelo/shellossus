# Markdown inline/table rendering, assistant reply/reasoning display, and pixel mascot.

function Get-VisibleLength {
    param([string]$Text)
    $cleanText = Strip-AnsiCodes -Text $Text
    $plain = ''
    foreach ($part in @($cleanText -split '(`[^`]+`)')) {
        if (-not $part) { continue }
        if ($part.StartsWith('`') -and $part.EndsWith('`') -and $part.Length -ge 2) {
            $plain += $part.Substring(1, $part.Length - 2)
        }
        else {
            $s = $part -replace '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)'
            $s = $s -replace '\*\*([^*]+)\*\*', '$1'
            $s = $s -replace '(?<![\*\w/\\])\*([^*\s](?:[^*]*?[^*\s])?)\*(?![\*\w])', '$1'
            $plain += $s
        }
    }
    return $plain.Length
}

function Format-MarkdownInline {
    param([string]$Text, [string]$BaseColor = $script:Gm.Fg)
    $Text = Format-TuiText -Text $Text -Multiline
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
            $s = $s -replace '(?<![\*\w/\\])\*([^*\s](?:[^*]*?[^*\s])?)\*(?![\*\w])', ($script:Gm.Purple + '$1' + $script:Gm.Reset + $BaseColor)
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
        if ($trimmed.EndsWith('|') -and (-not $trimmed.EndsWith('\|'))) { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1) }
        $cells = @()
        $cellBuf = ''
        $inTick = $false
        for ($cIdx = 0; $cIdx -lt $trimmed.Length; $cIdx++) {
            $ch = $trimmed[$cIdx]
            if ($ch -eq '\' -and ($cIdx + 1) -lt $trimmed.Length -and $trimmed[$cIdx + 1] -eq '|') {
                $cellBuf += '|'
                $cIdx++
                continue
            }
            if ($ch -eq '`') {
                if ($inTick) {
                    $inTick = $false
                }
                elseif ($trimmed.IndexOf('`', $cIdx + 1) -ge 0) {
                    $inTick = $true
                }
                $cellBuf += $ch
                continue
            }
            if ($ch -eq '|' -and (-not $inTick)) {
                $cells += $cellBuf.Trim()
                $cellBuf = ''
                continue
            }
            $cellBuf += $ch
        }
        $cells += $cellBuf.Trim()
        $isSep = ($cells.Count -gt 0)
        foreach ($c in $cells) {
            if ($c -notmatch '^:?-+:?$') { $isSep = $false; break }
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
    $maxTableW = (Get-TerminalWidth) - $Indent.Length - 4
    $borderOverhead = 4 + (($colCount - 1) * 3)
    $minTableW = $borderOverhead + ($colCount * 4)
    if ($maxTableW -ge $minTableW) {
        $totalW = $borderOverhead
        foreach ($cw in $widths) { $totalW += $cw }
        while ($totalW -gt $maxTableW) {
            $maxIdx = -1
            $maxVal = 4
            for ($i = 0; $i -lt $colCount; $i++) {
                if ($widths[$i] -gt $maxVal) {
                    $maxVal = $widths[$i]
                    $maxIdx = $i
                }
            }
            if ($maxIdx -lt 0) { break }
            $widths[$maxIdx]--
            $totalW--
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
            $formattedVal = Format-MarkdownInline -Text $val -BaseColor $baseColor
            $visLen = (Strip-AnsiCodes -Text $formattedVal).Length
            if ($visLen -gt $widths[$i]) {
                $formattedVal = Limit-AnsiLineToWidth -Text $formattedVal -MaxWidth $widths[$i]
                $visLen = (Strip-AnsiCodes -Text $formattedVal).Length
            }
            $padLen = $widths[$i] - $visLen
            $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }
            $sep = if ($i -lt ($colCount - 1)) { ' | ' } else { ' |' }
            $lineOut += $formattedVal + $pad + $script:Gm.Grey0 + $sep + $script:Gm.Reset
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
    $codeFenceChar = ''
    $codeFenceLen = 0
    $tableBuf = @()
    $lines = @($Content -split "`r?`n")
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $rawLine = $lines[$idx]
        $line = Format-TuiText -Text $rawLine -Multiline
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
        if (-not $inCode -and $trimmedStart -match '^(`{3,}|~{3,})(.*)$') {
            $fenceSeq = $Matches[1]
            $codeFenceChar = [string]$fenceSeq[0]
            $codeFenceLen = $fenceSeq.Length
            $lang = $Matches[2].Trim()
            $label = if ($lang) { " $lang " } else { ' code ' }
            $topHCount = if ((29 - $label.Length) -ge 4) { 29 - $label.Length } else { 4 }
            Write-Host ($barV + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Aqua + $label + $script:Gm.Grey0 + ($script:Box.H * $topHCount) + $script:Gm.Reset)
            $inCode = $true
        }
        elseif ($inCode -and $trimmedStart -match ('^' + ($codeFenceChar * $codeFenceLen) + $codeFenceChar + '*\s*$')) {
            Write-Host ($barV + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 30) + $script:Gm.Reset)
            $inCode = $false
            $codeFenceChar = ''
            $codeFenceLen = 0
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
    if ($inCode) {
        Write-Host ($barV + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 30) + $script:Gm.Reset)
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
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + (Format-TuiText -Text $l -Multiline) + $script:Gm.Reset)
        }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 12) + $script:Gm.Reset)
    }
    else {
        Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + " [reasoning: last 3 of $($lines.Count) lines | /reasoning full to expand]" + $script:Gm.Reset)
        foreach ($l in @($lines | Select-Object -Last 3)) {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Grey1 + (Format-TuiText -Text $l -Multiline) + $script:Gm.Reset)
        }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * 12) + $script:Gm.Reset)
    }
}

function Get-TuiMascotLines {
    param([string]$Mode = 'compact')
    $topChar = [string][char]0x2580
    $botChar = [string][char]0x2584
    $rst = $script:Gm.Reset
    # Shellossus #6: 10x8 pixels, 10 columns by 4 rows in compact mode.
    $sprite = @(
        '...ssss...',
        '.shhhhhhs.',
        '.shcaachs.',
        'shc####chs',
        'sc#p##p#cs',
        'scq####qcs',
        's#ghhhhg#s',
        '.dddddddd.'
    )
    $colors = @{
        's' = '159;123;85'
        'h' = '193;154;108'
        'd' = '121;94;69'
        '#' = '18;18;18'
        'p' = '247;211;138'
        'q' = '181;124;114'
        'c' = '92;70;54'
        'a' = '38;37;34'
        'g' = '31;31;31'
    }

    if ($Mode -eq 'full' -or $Mode -eq 'large') {
        $lines = @()
        foreach ($row in $sprite) {
            $line = ''
            foreach ($pixel in [char[]]$row) {
                $key = [string]$pixel
                if ($key -eq '.') { $line += ($rst + '  ') }
                else { $line += ("$script:Esc[48;2;$($colors[$key])m  ") }
            }
            $lines += ($line + $rst)
        }
        return $lines
    }

    $lines = @()
    for ($y = 0; $y -lt $sprite.Count; $y += 2) {
        $line = ''
        for ($x = 0; $x -lt $sprite[0].Length; $x++) {
            $top = [string]$sprite[$y][$x]
            $bottom = [string]$sprite[$y + 1][$x]
            if ($top -eq '.' -and $bottom -eq '.') {
                $line += ($rst + ' ')
            }
            elseif ($top -eq '.') {
                $line += ("$rst$script:Esc[38;2;$($colors[$bottom])m$botChar")
            }
            elseif ($bottom -eq '.') {
                $line += ("$rst$script:Esc[38;2;$($colors[$top])m$topChar")
            }
            else {
                $line += ("$script:Esc[48;2;$($colors[$bottom])m$script:Esc[38;2;$($colors[$top])m$topChar")
            }
        }
        $lines += ($line + $rst)
    }
    return $lines
}

function Write-TuiMascotCard {
    param([string]$Mode = 'full')
    if ($script:OutputMode -eq 'json') { return }
    $w = Get-TerminalWidth
    if ($w -lt 48) { $w = 48 }
    $hdr = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' Shellossus Mascot ' + $script:Gm.Reset + ' '
    $body = @()
    foreach ($line in @(Get-TuiMascotLines -Mode $Mode)) {
        $body += ('  ' + $line)
    }
    $body += ('  ' + $script:Gm.BoldYellow + 'The Armored Colossus' + $script:Gm.Reset)
    foreach ($ln in @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)) {
        Write-Host $ln
    }
}
