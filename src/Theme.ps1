# Terminal UI themes, palette switching, status bar, and prompt frame.

$script:Esc = [string][char]27
$script:Bel = [string][char]7
$script:ActiveTheme = 'gruvbox-material'
$script:ActiveThemeSpec = $null

function Get-AgentThemesCatalog {
    return @(
        @{
            id          = 'gruvbox-material'
            label       = 'Gruvbox Material'
            description = 'Warm retro dark medium palette (#282828 / #d4be98)'
            bg_outer    = '#1d2021'
            bg0         = '#282828'
            bg1         = '#32302f'
            bg_diff_red = '#402120'
            bg_diff_grn = '#34381b'
            fg          = '#d4be98'
            fg1         = '#ddc7a1'
            red         = '#ea6962'
            orange      = '#e78a4e'
            yellow      = '#d8a657'
            green       = '#a9b665'
            aqua        = '#89b482'
            blue        = '#7daea3'
            purple      = '#d3869b'
            grey0       = '#7c6f64'
            grey1       = '#928374'
            grey2       = '#a89984'
        },
        @{
            id          = 'catppuccin-mocha'
            label       = 'Catppuccin Mocha'
            description = 'Soothing pastel dark palette (#1e1e2e / #cdd6f4)'
            bg_outer    = '#181825'
            bg0         = '#1e1e2e'
            bg1         = '#313244'
            bg_diff_red = '#3c2330'
            bg_diff_grn = '#23392e'
            fg          = '#cdd6f4'
            fg1         = '#f5e0dc'
            red         = '#f38ba8'
            orange      = '#fab387'
            yellow      = '#f9e2af'
            green       = '#a6e3a1'
            aqua        = '#94e2d5'
            blue        = '#89b4fa'
            purple      = '#cba6f7'
            grey0       = '#6c7086'
            grey1       = '#9399b2'
            grey2       = '#a6adc8'
        },
        @{
            id          = 'tokyo-night'
            label       = 'Tokyo Night'
            description = 'Deep indigo neon dark palette (#1a1b26 / #c0caf5)'
            bg_outer    = '#16161e'
            bg0         = '#1a1b26'
            bg1         = '#24283b'
            bg_diff_red = '#3f222c'
            bg_diff_grn = '#203532'
            fg          = '#c0caf5'
            fg1         = '#dce0f7'
            red         = '#f7768e'
            orange      = '#ff9e64'
            yellow      = '#e0af68'
            green       = '#9ece6a'
            aqua        = '#73daca'
            blue        = '#7aa2f7'
            purple      = '#bb9af7'
            grey0       = '#565f89'
            grey1       = '#787c99'
            grey2       = '#9aa5ce'
        },
        @{
            id          = 'dracula'
            label       = 'Dracula'
            description = 'High-contrast gothic dark palette (#282a36 / #f8f8f2)'
            bg_outer    = '#21222c'
            bg0         = '#282a36'
            bg1         = '#343746'
            bg_diff_red = '#4a2633'
            bg_diff_grn = '#234232'
            fg          = '#f8f8f2'
            fg1         = '#ffffff'
            red         = '#ff5555'
            orange      = '#ffb86c'
            yellow      = '#f1fa8c'
            green       = '#50fa7b'
            aqua        = '#8be9fd'
            blue        = '#6272a4'
            purple      = '#bd93f9'
            grey0       = '#6272a4'
            grey1       = '#7b88b8'
            grey2       = '#9ea8cc'
        },
        @{
            id          = 'nord'
            label       = 'Nord'
            description = 'Arctic bluish-grey dark palette (#2e3440 / #d8dee9)'
            bg_outer    = '#242933'
            bg0         = '#2e3440'
            bg1         = '#3b4252'
            bg_diff_red = '#48323c'
            bg_diff_grn = '#32443c'
            fg          = '#d8dee9'
            fg1         = '#eceff4'
            red         = '#bf616a'
            orange      = '#d08770'
            yellow      = '#ebcb8b'
            green       = '#a3be8c'
            aqua        = '#88c0d0'
            blue        = '#81a1c1'
            purple      = '#b48ead'
            grey0       = '#616e88'
            grey1       = '#7b88a1'
            grey2       = '#96a3bc'
        },
        @{
            id          = 'one-dark'
            label       = 'One Dark Pro'
            description = 'Classic Atom and VS Code dark palette (#282c34 / #abb2bf)'
            bg_outer    = '#21252b'
            bg0         = '#282c34'
            bg1         = '#333842'
            bg_diff_red = '#45272d'
            bg_diff_grn = '#283b2e'
            fg          = '#abb2bf'
            fg1         = '#c8ccd4'
            red         = '#e06c75'
            orange      = '#d19a66'
            yellow      = '#e5c07b'
            green       = '#98c379'
            aqua        = '#56b6c2'
            blue        = '#61afef'
            purple      = '#c678dd'
            grey0       = '#5c6370'
            grey1       = '#7f848e'
            grey2       = '#9da5b4'
        },
        @{
            id          = 'rose-pine'
            label       = 'Rose Pine'
            description = 'Muted pine and rose dark palette (#191724 / #e0def4)'
            bg_outer    = '#13111c'
            bg0         = '#191724'
            bg1         = '#26233a'
            bg_diff_red = '#3d2131'
            bg_diff_grn = '#1f333a'
            fg          = '#e0def4'
            fg1         = '#f0effa'
            red         = '#eb6f92'
            orange      = '#ea9a97'
            yellow      = '#f6c177'
            green       = '#9ccfd8'
            aqua        = '#31748f'
            blue        = '#7aa2f7'
            purple      = '#c4a7e7'
            grey0       = '#6e6a86'
            grey1       = '#908caa'
            grey2       = '#b4b1cc'
        },
        @{
            id          = 'kanagawa'
            label       = 'Kanagawa Wave'
            description = 'Japanese ink and wave dark palette (#1f1f28 / #dcd7ba)'
            bg_outer    = '#16161d'
            bg0         = '#1f1f28'
            bg1         = '#2a2a37'
            bg_diff_red = '#43242b'
            bg_diff_grn = '#2b3328'
            fg          = '#dcd7ba'
            fg1         = '#eae6cf'
            red         = '#c34043'
            orange      = '#ffa066'
            yellow      = '#dca561'
            green       = '#76946a'
            aqua        = '#6a9589'
            blue        = '#7e9cd8'
            purple      = '#957fb8'
            grey0       = '#727169'
            grey1       = '#938aa9'
            grey2       = '#a6a69c'
        },
        @{
            id          = 'catppuccin-latte'
            label       = 'Catppuccin Latte'
            description = 'Warm daylight high-contrast light palette (#eff1f5 / #4c4f69)'
            bg_outer    = '#e6e9ef'
            bg0         = '#eff1f5'
            bg1         = '#ccd0da'
            bg_diff_red = '#f2d5cf'
            bg_diff_grn = '#d5e8d4'
            fg          = '#4c4f69'
            fg1         = '#2c2f44'
            red         = '#d20f39'
            orange      = '#fe640b'
            yellow      = '#df8e1d'
            green       = '#40a02b'
            aqua        = '#179299'
            blue        = '#1e66f5'
            purple      = '#8839ef'
            grey0       = '#8c8fa1'
            grey1       = '#6c6f85'
            grey2       = '#5c5f77'
        }
    )
}

function Resolve-ThemeCanonicalName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $norm = ($Name.Trim().ToLower() -replace '[_\s]+', '-')
    switch ($norm) {
        'gruvbox'           { return 'gruvbox-material' }
        'gruvbox-material'  { return 'gruvbox-material' }
        'default'           { return 'gruvbox-material' }
        'catppuccin'        { return 'catppuccin-mocha' }
        'mocha'             { return 'catppuccin-mocha' }
        'catppuccin-mocha'  { return 'catppuccin-mocha' }
        'tokyo'             { return 'tokyo-night' }
        'tokyonight'        { return 'tokyo-night' }
        'tokyo-night'       { return 'tokyo-night' }
        'dracula'           { return 'dracula' }
        'nord'              { return 'nord' }
        'onedark'           { return 'one-dark' }
        'one-dark'          { return 'one-dark' }
        'one-dark-pro'      { return 'one-dark' }
        'atom'              { return 'one-dark' }
        'rosepine'          { return 'rose-pine' }
        'rose-pine'         { return 'rose-pine' }
        'kanagawa'          { return 'kanagawa' }
        'kanagawa-wave'     { return 'kanagawa' }
        'latte'             { return 'catppuccin-latte' }
        'light'             { return 'catppuccin-latte' }
        'catppuccin-latte'  { return 'catppuccin-latte' }
        default             { return '' }
    }
}

function ConvertFrom-HexToRgbTriplet {
    param([string]$Hex)
    $clean = $Hex.TrimStart('#')
    $r = [int]('0x' + $clean.Substring(0, 2))
    $g = [int]('0x' + $clean.Substring(2, 2))
    $b = [int]('0x' + $clean.Substring(4, 2))
    return "$r;$g;$b"
}

function Build-TuiPalette {
    param($Spec)
    $bg0Rgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.bg0
    $bg1Rgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.bg1
    $bgRedRgb = ConvertFrom-HexToRgbTriplet -Hex $Spec.bg_diff_red
    $bgGrnRgb = ConvertFrom-HexToRgbTriplet -Hex $Spec.bg_diff_grn
    $fgRgb    = ConvertFrom-HexToRgbTriplet -Hex $Spec.fg
    $fg1Rgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.fg1
    $redRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.red
    $orgRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.orange
    $yelRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.yellow
    $grnRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.green
    $aquRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.aqua
    $bluRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.blue
    $purRgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.purple
    $gr0Rgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.grey0
    $gr1Rgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.grey1
    $gr2Rgb   = ConvertFrom-HexToRgbTriplet -Hex $Spec.grey2
    return @{
        Reset       = "$script:Esc[0m"
        Bg0         = "$script:Esc[48;2;$($bg0Rgb)m"
        Bg1         = "$script:Esc[48;2;$($bg1Rgb)m"
        BgDiffRed   = "$script:Esc[48;2;$($bgRedRgb)m"
        BgDiffGreen = "$script:Esc[48;2;$($bgGrnRgb)m"
        Fg          = "$script:Esc[38;2;$($fgRgb)m"
        Fg1         = "$script:Esc[38;2;$($fg1Rgb)m"
        Red         = "$script:Esc[38;2;$($redRgb)m"
        BoldRed     = "$script:Esc[1;38;2;$($redRgb)m"
        Orange      = "$script:Esc[38;2;$($orgRgb)m"
        BoldOrange  = "$script:Esc[1;38;2;$($orgRgb)m"
        Yellow      = "$script:Esc[38;2;$($yelRgb)m"
        BoldYellow  = "$script:Esc[1;38;2;$($yelRgb)m"
        Green       = "$script:Esc[38;2;$($grnRgb)m"
        BoldGreen   = "$script:Esc[1;38;2;$($grnRgb)m"
        Aqua        = "$script:Esc[38;2;$($aquRgb)m"
        BoldAqua    = "$script:Esc[1;38;2;$($aquRgb)m"
        Blue        = "$script:Esc[38;2;$($bluRgb)m"
        BoldBlue    = "$script:Esc[1;38;2;$($bluRgb)m"
        Purple      = "$script:Esc[3;38;2;$($purRgb)m"
        BoldPurple  = "$script:Esc[1;38;2;$($purRgb)m"
        Grey0       = "$script:Esc[38;2;$($gr0Rgb)m"
        Grey1       = "$script:Esc[38;2;$($gr1Rgb)m"
        Grey2       = "$script:Esc[38;2;$($gr2Rgb)m"
        OscInit     = "$script:Esc]11;$($Spec.bg0)$script:Bel$script:Esc]10;$($Spec.fg)$script:Bel"
    }
}

function Set-AgentTheme {
    param([string]$Name)
    $canon = Resolve-ThemeCanonicalName -Name $Name
    $catalog = @(Get-AgentThemesCatalog)
    if (-not $canon) {
        $validList = ($catalog | ForEach-Object { $_.id }) -join ', '
        throw "Unknown theme '$Name'. Available themes: $validList"
    }
    $found = $null
    foreach ($t in $catalog) {
        if ($t.id -eq $canon) {
            $found = $t
            break
        }
    }
    $script:ActiveTheme = $found.id
    $script:ActiveThemeSpec = $found
    $script:Gm = Build-TuiPalette -Spec $found
    return $found
}

$null = Set-AgentTheme -Name 'gruvbox-material'

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
            if ($lastSpace -gt 0 -and ($currVis + $lastSpace) -ge [int]($MaxWidth / 2)) {
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
        foreach ($ln in @($BodyLines)) {
            $s = if ($null -ne $ln) { [string]$ln } else { '' }
            foreach ($wrappedLn in @(Split-AnsiLineToWidth -Text $s -MaxWidth $innerW)) {
                $vLen = (Strip-AnsiCodes -Text $wrappedLn).Length
                $rowMeta += @{ text = $wrappedLn; vis = $vLen }
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
    $w = if ($Width -ge 30) { $Width } else { Get-TerminalWidth }
    if ($w -lt 30) { $w = 30 }
    $innerW = $w - 4
    $wsName = if ($Root) { Split-Path $Root -Leaf } else { 'workspace' }
    if (-not $wsName) { $wsName = $Root }
    $branch = Get-GitBranchLabel -Root $Root
    $branchSeg = if ($branch) { ' ' + $script:Gm.Purple + '(' + $branch + ')' + $script:Gm.Reset } else { '' }
    $sessLabel = if ($State -and $State.session_name) { [string]$State.session_name } elseif ($State -and $State.session_id) { [string]$State.session_id } else { '' }
    $sessSeg = if ($sessLabel) { ' ' + $script:Gm.Grey0 + $script:Box.H + ' ' + $script:Gm.Grey1 + $sessLabel + $script:Gm.Reset } else { '' }
    $topTitle = ' ' + $script:Gm.BoldGreen + $script:Box.Dot + ' ' + $wsName + $script:Gm.Reset + $branchSeg + $sessSeg + ' '
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
    $modelSeg = $script:Gm.Fg1 + $Model + $script:Gm.Grey1 + $effStr + $script:Gm.Reset
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
    $titleSeq = "$script:Esc]0;shellossus - $wsName [$Model | $($script:AgentPermission)]$script:Bel"
    Write-Host ("`n" + $titleSeq) -NoNewline
    foreach ($ln in @(Format-TuiStatusBar -State $State -Root $Root -Model $Model -UndoCount $UndoCount)) {
        Write-Host $ln
    }
}
