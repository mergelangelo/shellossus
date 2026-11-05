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
    $rst = $script:Gm.Reset
    # Reference silhouette: solid rounded black hands with soft gray shading.
    # Shellossus mascot: 20x16 logical pixels in 20 columns x 8 terminal rows.
    # Each half-block carries two independently colored vertical pixels.
    $sprite = @(
        '......ssssssss......',
        '....sshhhhhhhhss....',
        '...shhhhhhhhhhhhs...',
        '..shhhsssssssshhhs..',
        '.shhssccccccccsshhs.',
        '.shssccaaaaaaccsshs.',
        'shsscca######accsshs',
        'shscc##########ccshs',
        'sssc##ep####pe##csss',
        'sssc##pp####pp##csss',
        'sssc##ff####ff##csss',
        'ssscqq########qqcsss',
        'sss#k#h######h#k#sss',
        'ss#gg#hhhhhhhh#gg#ss',
        '.ss##ssssssssss##ss.',
        '..dddddddddddddddd..'
    )
    $colors = @{
        's' = '159;123;85'
        'h' = '193;154;108'
        'd' = '121;94;69'
        '#' = '18;18;18'
        'p' = '247;211;138'
        'q' = '181;124;114'
        'c' = '92;70;54'
        'e' = '255;239;188'
        'f' = '215;168;92'
        'a' = '38;37;34'
        'g' = '31;31;31'
        'k' = '48;48;48'
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
