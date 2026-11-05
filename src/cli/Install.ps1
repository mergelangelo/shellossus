# PowerShell profile launcher installer (-Install): registers global:shellossus and optional shortcut in $PROFILE.

function Test-ShortcutSyntax {
    param([string]$Name)
    if (-not $Name) { return $false }
    return [bool]($Name -match '^[A-Za-z][A-Za-z0-9_-]*$')
}

function Test-IsOwnAgentFunction {
    param($CommandInfo, [string]$PreviousShortcut, [string]$ResolvedAgent)
    if ($null -eq $CommandInfo -or [string]$CommandInfo.CommandType -ne 'Function') { return $false }
    $def = [string]$CommandInfo.Definition
    if ($def -match '(?i)(shellossus|h-agent)\.ps1') { return $true }
    if ($ResolvedAgent -and ($def.IndexOf($ResolvedAgent, [StringComparison]::OrdinalIgnoreCase) -ge 0)) { return $true }
    return $false
}

function Get-ShortcutConflict {
    param([string]$Name, [string]$PreviousShortcut, [string]$ResolvedAgent)
    if (-not $Name -or ($Name -ieq 'shellossus')) { return $null }
    $cmds = @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
    foreach ($cmd in $cmds) {
        if (Test-IsOwnAgentFunction -CommandInfo $cmd -PreviousShortcut $PreviousShortcut -ResolvedAgent $ResolvedAgent) {
            continue
        }
        $detail = ''
        if ($cmd.Definition) {
            $flatDef = ([string]$cmd.Definition -replace '\r?\n', ' ').Trim()
            if ($flatDef.Length -gt 80) { $flatDef = $flatDef.Substring(0, 80) + '...' }
            $detail = $flatDef
        }
        elseif ($cmd.Source) {
            $detail = [string]$cmd.Source
        }
        return @{
            Name = [string]$cmd.Name
            CommandType = [string]$cmd.CommandType
            Detail = $detail
        }
    }
    return $null
}

function Get-MarkerBlockRange {
    param([string]$Content, [string]$StartMarker, [string]$EndMarker, [string]$StartRegex, [string]$EndRegex, [string]$Label)
    if (-not $Content) { return $null }
    $starts = @($Content -split $StartRegex).Count - 1
    $ends = @($Content -split $EndRegex).Count - 1
    if ($starts -gt 1 -or $ends -gt 1 -or $starts -ne $ends) {
        throw "Unexpected $Label profile markers; edit the profile manually."
    }
    if ($starts -eq 0) { return $null }
    $startIdx = $Content.IndexOf($StartMarker, [StringComparison]::Ordinal)
    $endIdx = $Content.IndexOf($EndMarker, [StringComparison]::Ordinal)
    if ($startIdx -lt 0 -or $endIdx -lt $startIdx) {
        throw "Invalid $Label profile marker order."
    }
    $blockEnd = $endIdx + $EndMarker.Length
    $blockText = $Content.Substring($startIdx, $blockEnd - $startIdx)
    $detectedShortcut = ''
    foreach ($line in @($blockText -split '\r?\n')) {
        if ($line -match '^\s*function\s+global:([A-Za-z0-9_-]+)\s*\{') {
            $fnName = $Matches[1]
            if (($fnName -ine 'shellossus') -and ($fnName -ine 'h-agent')) {
                $detectedShortcut = $fnName
            }
        }
    }
    return @{
        Start = $startIdx
        End = $blockEnd
        Text = $blockText
        Shortcut = $detectedShortcut
    }
}

function Invoke-AgentProfileInstall {
    param(
        [string]$AgentPath = '',
        [string]$ProfilePath = $PROFILE,
        [string]$Shortcut = '',
        [switch]$ShortcutSpecified,
        [switch]$NoShortcut
    )
    $hasExplicitShortcut = if ($PSBoundParameters.Keys -contains 'ShortcutSpecified') {
        [bool]$ShortcutSpecified
    }
    else {
        ($PSBoundParameters.Keys -contains 'Shortcut')
    }
    if ($NoShortcut -and $hasExplicitShortcut) {
        throw 'Cannot specify both -Shortcut and -NoShortcut.'
    }
    if (-not $AgentPath) {
        throw 'AgentPath is required.'
    }
    $resolvedAgent = (Resolve-Path -LiteralPath $AgentPath -ErrorAction Stop).ProviderPath
    if ((Get-Item -LiteralPath $resolvedAgent).PSIsContainer) { throw 'AgentPath must be a script file.' }
    if (-not $ProfilePath) { throw 'No PowerShell profile path is available.' }

    $existing = ''
    $profileExists = Test-Path -LiteralPath $ProfilePath
    $shBlock = $null
    $haBlock = $null
    $previousShortcut = ''

    if ($profileExists) {
        $existing = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
        if ($null -eq $existing) { $existing = '' }
        $shBlock = Get-MarkerBlockRange `
            -Content $existing `
            -StartMarker '# >>> shellossus >>>' `
            -EndMarker '# <<< shellossus <<<' `
            -StartRegex '(?m)^# >>> shellossus >>>\r?$' `
            -EndRegex '(?m)^# <<< shellossus <<<\r?$' `
            -Label 'shellossus'
        $haBlock = Get-MarkerBlockRange `
            -Content $existing `
            -StartMarker '# >>> h-agent >>>' `
            -EndMarker '# <<< h-agent <<<' `
            -StartRegex '(?m)^# >>> h-agent >>>\r?$' `
            -EndRegex '(?m)^# <<< h-agent <<<\r?$' `
            -Label 'h-agent'
        if ($shBlock -and $shBlock.Shortcut) {
            $previousShortcut = [string]$shBlock.Shortcut
        }
        elseif ($haBlock -and $haBlock.Shortcut) {
            $previousShortcut = [string]$haBlock.Shortcut
        }
    }

    $chosenShortcut = ''
    if ($NoShortcut) {
        $chosenShortcut = ''
    }
    elseif ($hasExplicitShortcut) {
        $cand = $Shortcut.Trim()
        if (-not (Test-ShortcutSyntax -Name $cand)) {
            throw "Invalid shortcut name '$Shortcut'. Use only letters, numbers, hyphens, or underscores (must start with a letter, no spaces or special characters)."
        }
        $conflict = Get-ShortcutConflict -Name $cand -PreviousShortcut $previousShortcut -ResolvedAgent $resolvedAgent
        if ($conflict) {
            $info = if ($conflict.Detail) { " ($($conflict.Detail))" } else { '' }
            throw "Shortcut '$cand' conflicts with existing $($conflict.CommandType) '$($conflict.Name)'$info. Choose another shortcut."
        }
        $chosenShortcut = if ($cand -ieq 'shellossus') { '' } else { $cand }
    }
    else {
        $needShortcutMenu = $true
        if ($previousShortcut) {
            Write-Host ($script:Gm.Fg + "Existing shortcut detected: $previousShortcut" + $script:Gm.Reset)
            Write-Host ''
            Write-Host ($script:Gm.Fg + "[1] Keep '$previousShortcut'" + $script:Gm.Reset)
            Write-Host ($script:Gm.Fg + '[2] Change shortcut' + $script:Gm.Reset)
            Write-Host ($script:Gm.Fg + '[3] Remove shortcut' + $script:Gm.Reset)
            Write-Host ''
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                $reChoice = Read-Host 'Select an option [1-3] (default: 1)'
                if ($null -eq $reChoice) { $reChoice = '1' }
                $reChoice = $reChoice.Trim()
                if ($reChoice -eq '' -or $reChoice -eq '1') {
                    $conflict = Get-ShortcutConflict -Name $previousShortcut -PreviousShortcut $previousShortcut -ResolvedAgent $resolvedAgent
                    if ($conflict) {
                        $info = if ($conflict.Detail) { " ($($conflict.Detail))" } else { '' }
                        Write-Host ($script:Gm.Yellow + "Shortcut '$previousShortcut' conflicts with existing $($conflict.CommandType) '$($conflict.Name)'$info. Choose another name." + $script:Gm.Reset)
                        $needShortcutMenu = $true
                    }
                    else {
                        $chosenShortcut = $previousShortcut
                        $needShortcutMenu = $false
                    }
                    break
                }
                elseif ($reChoice -eq '2') {
                    $needShortcutMenu = $true
                    break
                }
                elseif ($reChoice -eq '3') {
                    $chosenShortcut = ''
                    $needShortcutMenu = $false
                    break
                }
                else {
                    Write-Host ($script:Gm.Yellow + 'Please enter 1, 2, or 3.' + $script:Gm.Reset)
                }
            }
        }
        if ($needShortcutMenu) {
            Write-Host ($script:Gm.Fg + 'Choose a shortcut:' + $script:Gm.Reset)
            Write-Host ''
            Write-Host ($script:Gm.Fg + '[1] s' + $script:Gm.Reset)
            Write-Host ($script:Gm.Fg + '[2] sss' + $script:Gm.Reset)
            Write-Host ($script:Gm.Fg + '[3] shos' + $script:Gm.Reset)
            Write-Host ($script:Gm.Fg + '[4] Custom name' + $script:Gm.Reset)
            Write-Host ($script:Gm.Fg + '[5] No shortcut' + $script:Gm.Reset)
            Write-Host ''
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                $sel = Read-Host 'Select an option [1-5]'
                if ($null -eq $sel) { $chosenShortcut = ''; break }
                $sel = $sel.Trim()
                $candidate = ''
                if ($sel -eq '1') { $candidate = 's' }
                elseif ($sel -eq '2') { $candidate = 'sss' }
                elseif ($sel -eq '3') { $candidate = 'shos' }
                elseif ($sel -eq '4') {
                    $customInput = Read-Host 'Enter custom shortcut name'
                    if ($null -eq $customInput) { continue }
                    $candidate = $customInput.Trim()
                    if (-not (Test-ShortcutSyntax -Name $candidate)) {
                        Write-Host ($script:Gm.Yellow + "Invalid shortcut name '$candidate'. Use only letters, numbers, hyphens, or underscores (no spaces or special characters)." + $script:Gm.Reset)
                        continue
                    }
                }
                elseif ($sel -eq '5') {
                    $chosenShortcut = ''
                    break
                }
                else {
                    Write-Host ($script:Gm.Yellow + 'Please enter 1, 2, 3, 4, or 5.' + $script:Gm.Reset)
                    continue
                }
                $conflict = Get-ShortcutConflict -Name $candidate -PreviousShortcut $previousShortcut -ResolvedAgent $resolvedAgent
                if ($conflict) {
                    $info = if ($conflict.Detail) { " ($($conflict.Detail))" } else { '' }
                    Write-Host ($script:Gm.Yellow + "Shortcut '$candidate' conflicts with existing $($conflict.CommandType) '$($conflict.Name)'$info. Choose another name." + $script:Gm.Reset)
                    continue
                }
                $chosenShortcut = if ($candidate -ieq 'shellossus') { '' } else { $candidate }
                break
            }
        }
    }

    $escaped = $resolvedAgent.Replace("'", "''")
    $blockLines = @(
        '# >>> shellossus >>>',
        "function global:shellossus { & '$escaped' @args }"
    )
    if ($chosenShortcut -and ($chosenShortcut -ine 'shellossus')) {
        $blockLines += "function global:$chosenShortcut { & '$escaped' @args }"
    }
    $blockLines += '# <<< shellossus <<<'
    $block = $blockLines -join "`r`n"

    if ($profileExists) {
        if ($shBlock -and $haBlock) {
            # Remove legacy h-agent block first, then update shellossus block in place.
            $haRemoveEnd = $haBlock.End
            if (($haRemoveEnd + 1 -lt $existing.Length) -and ($existing.Substring($haRemoveEnd, 2) -eq "`r`n")) {
                $haRemoveEnd += 2
            }
            elseif (($haRemoveEnd -lt $existing.Length) -and ($existing.Substring($haRemoveEnd, 1) -eq "`n")) {
                $haRemoveEnd += 1
            }
            $withoutHa = $existing.Substring(0, $haBlock.Start) + $existing.Substring($haRemoveEnd)
            $shBlockUpdated = Get-MarkerBlockRange `
                -Content $withoutHa `
                -StartMarker '# >>> shellossus >>>' `
                -EndMarker '# <<< shellossus <<<' `
                -StartRegex '(?m)^# >>> shellossus >>>\r?$' `
                -EndRegex '(?m)^# <<< shellossus <<<\r?$' `
                -Label 'shellossus'
            $updated = $withoutHa.Substring(0, $shBlockUpdated.Start) + $block + $withoutHa.Substring($shBlockUpdated.End)
        }
        elseif ($shBlock) {
            # Use literal slicing: paths with dollar signs are never regex replacements.
            $updated = $existing.Substring(0, $shBlock.Start) + $block + $existing.Substring($shBlock.End)
        }
        elseif ($haBlock) {
            # Migrate legacy h-agent block in place to shellossus block.
            $updated = $existing.Substring(0, $haBlock.Start) + $block + $existing.Substring($haBlock.End)
        }
        else {
            $updated = $existing + "`r`n" + $block + "`r`n"
        }
        $backup = $ProfilePath + '.shellossus-backup-' + (Get-Date -Format 'yyyyMMddHHmmssfff')
        Copy-Item -LiteralPath $ProfilePath -Destination $backup -ErrorAction Stop
        Write-Host ($script:Gm.Grey1 + "Profile backup: $backup" + $script:Gm.Reset)
    }
    else {
        $updated = $block + "`r`n"
    }

    $parent = Split-Path $ProfilePath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding UTF8 -NoNewline
    Write-Host ($script:Gm.Green + "Command registered in: $ProfilePath" + $script:Gm.Reset)
    if ($chosenShortcut) {
        Write-Host ($script:Gm.Green + "Registered commands: shellossus, $chosenShortcut" + $script:Gm.Reset)
        Write-Host ($script:Gm.Fg + "Open a new PowerShell window, then run: $chosenShortcut -Setup (or shellossus -Setup)" + $script:Gm.Reset)
    }
    else {
        Write-Host ($script:Gm.Green + 'Registered command: shellossus' + $script:Gm.Reset)
        Write-Host ($script:Gm.Fg + 'Open a new PowerShell window, then run: shellossus -Setup' + $script:Gm.Reset)
    }
    Write-Host ($script:Gm.Grey1 + 'If profiles are blocked, use your approved script launch method; no policies were changed.' + $script:Gm.Reset)
}
