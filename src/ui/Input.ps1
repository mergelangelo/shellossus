# Interactive TUI input controls (multiline prompt, selector menu, confirmation dialog).

function Read-TuiMultilineInput {
    $first = Read-Host
    if ($null -eq $first) { return $null }
    if ($first.StartsWith('"""') -or $first.StartsWith('<<<')) {
        $fence = if ($first.StartsWith('"""')) { '"""' } else { '>>>' }
        $altFence = $first.Substring(0, 3)
        $rest = $first.Substring(3)
        $restTrimmed = $rest.TrimEnd(' ', "`t")
        if ($restTrimmed.Length -ge 3 -and ($restTrimmed.EndsWith($fence) -or $restTrimmed.EndsWith($altFence))) {
            return $restTrimmed.Substring(0, $restTrimmed.Length - 3)
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
            $nextTrimmed = $next.TrimEnd(' ', "`t")
            if ($nextTrimmed.EndsWith($fence) -or $nextTrimmed.EndsWith($altFence)) {
                $beforeClose = $nextTrimmed.Substring(0, $nextTrimmed.Length - 3)
                if ($beforeClose.Length -gt 0) { $lines += $beforeClose }
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
        [string]$PromptText = 'Select number (Enter cancels)',
        [switch]$AllowFreeText
    )
    if (-not $Items -or $Items.Count -eq 0) { return $null }
    if ($script:OutputMode -eq 'json') { return $null }
    if ($script:OutputMode -ne 'json') {
        $w = Get-TerminalWidth
        $hdr = ' ' + $script:Gm.BoldOrange + $Title + $script:Gm.Reset + ' '
        $body = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $it = $Items[$i]
            $marker = if ($it.active) { $script:Gm.BoldGreen + $script:Box.Dot + $script:Gm.Reset } else { ' ' }
            $numStr = $script:Gm.Yellow + ("[{0}]" -f ($i + 1)) + $script:Gm.Reset
            $lblStr = $script:Gm.Aqua + [string]$it.label + $script:Gm.Reset
            $descStr = if ($it.description) { $script:Gm.Grey1 + ' - ' + [string]$it.description + $script:Gm.Reset } else { '' }
            $body += "$marker $numStr $lblStr$descStr"
        }
        foreach ($ln in @(Format-TuiCardBox -Header $hdr -BodyLines $body -Width $w)) {
            Write-Host $ln
        }
        Write-Host ('  ' + $script:Gm.BoldYellow + $PromptText + ': ' + $script:Gm.Fg) -NoNewline
    }
    $rawChoice = Read-Host
    if ($script:OutputMode -ne 'json') {
        Write-Host $script:Gm.Reset -NoNewline
    }
    if (-not $rawChoice -or -not $rawChoice.Trim()) { return $null }
    $trimmed = $rawChoice.Trim()
    if ($trimmed -match '^\d{1,6}$') {
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
    if ($AllowFreeText) {
        return $trimmed
    }
    return $null
}

function Read-TuiConfirmation {
    param(
        [string]$PromptText,
        [switch]$AllowDiff,
        [string]$ActionType = 'write'
    )
    if ($script:OutputMode -eq 'json') { return 'n' }
    while ($true) {
        Write-Host $PromptText -NoNewline
        $raw = Read-Host
        Write-Host $script:Gm.Reset -NoNewline
        if ($null -eq $raw) { return 'n' }
        $trimmed = $raw.Trim()
        if (-not $trimmed) { return 'n' }
        $lower = $trimmed.ToLower()
        if ($lower -in @('y', 'yes', '1')) {
            return 'y'
        }
        if ($ActionType -eq 'write' -and ($lower -in @('w', 'write') -or $trimmed -ceq 'WRITE')) {
            return 'y'
        }
        if ($ActionType -eq 'run' -and ($lower -in @('r', 'run') -or $trimmed -ceq 'RUN')) {
            return 'y'
        }
        if ($ActionType -eq 'web' -and ($lower -in @('w', 'web', 'write', 'r', 'run') -or $trimmed -in @('WRITE', 'RUN', 'WEB'))) {
            return 'y'
        }
        if ($lower -in @('a', 'all', 'always')) {
            return 'a'
        }
        if ($lower -in @('d', 'diff') -and $AllowDiff) {
            return 'd'
        }
        if ($lower -in @('n', 'no', 'cancel', 'c', '0')) {
            return 'n'
        }
        return $lower
    }
}
