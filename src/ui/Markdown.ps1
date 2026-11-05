# Markdown inline/table rendering, assistant reply/reasoning display, and pixel mascot.

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

function Get-TuiMascotLines {
    param([string]$Mode = 'compact')
    $topChar = [string][char]0x2580
    $botChar = [string][char]0x2584
    $fullChar = [string][char]0x2588
    $cBodyFg = "$script:Esc[38;2;168;153;132m"
    $cEyeFg  = "$script:Esc[1;38;2;250;189;47m"
    $cBodyBg = "$script:Esc[48;2;168;153;132m"
    $cEyeBg  = "$script:Esc[48;2;250;189;47m"
    $rst     = $script:Gm.Reset

    $sprite = @(
        '    ###       ',
        '  #######     ',
        ' #########    ',
        ' ##E#E####    ',
        '###########   ',
        ' ############ ',
        '  ##########  ',
        '##  ## #   ###',
        '    ##     #  ',
        '              '
    )

    if ($Mode -eq 'full') {
        $lines = @()
        for ($y = 0; $y -lt 9; $y++) {
            $row = $sprite[$y]
            $sb = ''
            for ($x = 0; $x -lt $row.Length; $x++) {
                $ch = $row[$x]
                if ($ch -eq '#') {
                    $sb += ($cBodyFg + $cBodyBg + $fullChar + $fullChar)
                }
                elseif ($ch -eq 'E') {
                    $sb += ($cEyeFg + $cEyeBg + $fullChar + $fullChar)
                }
                else {
                    $sb += ($rst + '  ')
                }
            }
            $lines += ($sb + $rst)
        }
        return $lines
    }

    $lines = @()
    for ($y = 0; $y -lt 10; $y += 2) {
        $rTop = $sprite[$y]
        $rBot = $sprite[$y + 1]
        $sb = ''
        for ($x = 0; $x -lt 14; $x++) {
            $t = $rTop[$x]
            $b = $rBot[$x]
            if ($t -eq ' ' -and $b -eq ' ') {
                $sb += ($rst + ' ')
            }
            elseif ($t -ne ' ' -and $b -eq ' ') {
                $fg = if ($t -eq 'E') { $cEyeFg } else { $cBodyFg }
                $sb += ($rst + $fg + $topChar)
            }
            elseif ($t -eq ' ' -and $b -ne ' ') {
                $fg = if ($b -eq 'E') { $cEyeFg } else { $cBodyFg }
                $sb += ($rst + $fg + $botChar)
            }
            else {
                $fg = if ($t -eq 'E') { $cEyeFg } else { $cBodyFg }
                $bg = if ($b -eq 'E') { $cEyeBg } else { $cBodyBg }
                $sb += ($bg + $fg + $topChar)
            }
        }
        $lines += ($sb + $rst)
    }
    return $lines
}

function Write-TuiMascotCard {
    param([string]$Mode = 'full')
    if ($script:OutputMode -eq 'json') { return }
    $w = Get-TerminalWidth
    $hdr = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' Shellossus Mascot ' + $script:Gm.Reset + ' '
    $hdrVis = (Strip-AnsiCodes -Text $hdr).Length
    $dashes = $w - 5 - $hdrVis
    if ($dashes -lt 2) { $dashes = 2 }
    $barV = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Reset
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + $script:Gm.Reset + $hdr + $script:Gm.Grey0 + ($script:Box.H * $dashes) + $script:Box.TR + $script:Gm.Reset)
    $lines = @(Get-TuiMascotLines -Mode $Mode)
    foreach ($line in $lines) {
        Write-Host ($barV + '  ' + $line)
    }
    Write-Host ($barV + '  ' + $script:Gm.BoldYellow + 'The Armored Colossus' + $script:Gm.Reset)
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + ($script:Box.H * ($w - 4)) + $script:Box.BR + $script:Gm.Reset)
}
