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
    BoldGreen   = "$script:Esc[1;38;2;169;182;101m"  # #a9b665 bold (H: / H4)
    Aqua        = "$script:Esc[38;2;137;180;130m"    # #89b482
    Blue        = "$script:Esc[38;2;125;174;163m"    # #7daea3
    BoldBlue    = "$script:Esc[1;38;2;125;174;163m"  # #7daea3 bold (You: / Table header)
    Purple      = "$script:Esc[3;38;2;211;134;155m"  # #d3869b italic (*italic*)
    Grey0       = "$script:Esc[38;2;124;111;100m"    # #7c6f64
    Grey1       = "$script:Esc[38;2;146;131;116m"    # #928374
    Grey2       = "$script:Esc[38;2;168;153;132m"    # #a89984
    OscInit     = "$script:Esc]11;#282828$script:Bel$script:Esc]10;#d4be98$script:Bel"
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
    Write-Host ("`n" + $script:Gm.BoldGreen + 'H: ' + $script:Gm.Reset) -NoNewline
    $inCode = $false
    $first = $true
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
                $tIndent = if ($first) { '' } else { '   ' }
                $first = $false
                Write-Host ($tIndent + $tLine)
            }
            $tableBuf = @()
        }
        $indent = if ($first) { '' } else { '   ' }
        $first = $false
        $trimmedStart = $line.TrimStart()
        if ($trimmedStart.StartsWith('```')) {
            $lang = $trimmedStart.Substring(3).Trim()
            $label = if ($lang) { "[$lang]" } else { '---' }
            Write-Host ($indent + $script:Gm.Grey1 + $label + $script:Gm.Reset)
            $inCode = -not $inCode
        }
        elseif ($inCode) {
            Write-Host ($indent + $script:Gm.Bg1 + $script:Gm.Yellow + '  ' + $line + '  ' + $script:Gm.Reset)
        }
        elseif ($line -match '^\s*(#{1,6})\s+(.*)$') {
            $level = $Matches[1].Length
            $hColor = switch ($level) {
                1 { $script:Gm.BoldRed }
                2 { $script:Gm.BoldOrange }
                3 { $script:Gm.BoldYellow }
                default { $script:Gm.BoldGreen }
            }
            Write-Host ($indent + (Format-MarkdownInline -Text $Matches[2] -BaseColor $hColor))
        }
        elseif ($line -match '^\s*([-*_]){3,}\s*$') {
            Write-Host ($indent + $script:Gm.Grey0 + ('-' * 40) + $script:Gm.Reset)
        }
        elseif ($line -match '^(\s*)>\s?(.*)$') {
            Write-Host ($indent + $Matches[1] + $script:Gm.Grey0 + '| ' + (Format-MarkdownInline -Text $Matches[2] -BaseColor $script:Gm.Grey2))
        }
        elseif ($line -match '^(\s*)([-*+]|\d+\.)\s+(.*)$') {
            Write-Host ($indent + $Matches[1] + $script:Gm.Green + $Matches[2] + ' ' + $script:Gm.Reset + (Format-MarkdownInline -Text $Matches[3] -BaseColor $script:Gm.Fg))
        }
        else {
            Write-Host ($indent + (Format-MarkdownInline -Text $line -BaseColor $script:Gm.Fg))
        }
    }
    if ($tableBuf.Count -gt 0) {
        foreach ($tLine in @(Format-MarkdownTable -Lines $tableBuf -Indent '')) {
            $tIndent = if ($first) { '' } else { '   ' }
            $first = $false
            Write-Host ($tIndent + $tLine)
        }
    }
}

function Write-AgentReasoning {
    param([string]$Text)
    if (-not $Text -or $script:ShowReasoning -eq 'hide' -or $script:OutputMode -eq 'json') { return }
    $lines = @($Text.Trim() -split "`r?`n")
    if ($script:ShowReasoning -eq 'full' -or $lines.Count -le 3) {
        Write-Host ("`n" + $script:Gm.Grey0 + '  [reasoning]' + $script:Gm.Reset)
        foreach ($l in $lines) {
            Write-Host ($script:Gm.Grey1 + '  | ' + (Format-PreviewText $l) + $script:Gm.Reset)
        }
    }
    else {
        Write-Host ("`n" + $script:Gm.Grey0 + "  [reasoning: last 3 of $($lines.Count) lines | /reasoning full to expand]" + $script:Gm.Reset)
        foreach ($l in @($lines | Select-Object -Last 3)) {
            Write-Host ($script:Gm.Grey1 + '  | ' + (Format-PreviewText $l) + $script:Gm.Reset)
        }
    }
}
