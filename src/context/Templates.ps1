# Reusable slash prompt templates and inline @file / !cmd prompt expansion.

function Split-CommandArgs {
    param([string]$ArgsString)
    $argsList = @()
    if (-not $ArgsString) { return $argsList }
    $current = ''
    $hasToken = $false
    $inQuote = ''
    for ($i = 0; $i -lt $ArgsString.Length; $i++) {
        $ch = $ArgsString[$i]
        if ($inQuote) {
            if ([string]$ch -eq $inQuote) {
                $inQuote = ''
            }
            else {
                $current += $ch
            }
        }
        elseif ($ch -eq [char]'"' -or $ch -eq [char]"'") {
            $inQuote = [string]$ch
            $hasToken = $true
        }
        elseif ([string]$ch -match '^\s$') {
            if ($hasToken) {
                $argsList += $current
                $current = ''
                $hasToken = $false
            }
        }
        else {
            $current += $ch
            $hasToken = $true
        }
    }
    if ($hasToken) {
        $argsList += $current
    }
    return $argsList
}

function Expand-TemplateArgs {
    param([string]$Content, [string]$ArgsString = '')
    if (-not $Content) { return '' }
    $argsList = @(Split-CommandArgs -ArgsString $ArgsString)
    $allArgs = $argsList -join ' '
    $pattern = '\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)'
    $hasPlaceholders = ($Content -match $pattern)
    if (-not $hasPlaceholders) {
        if ($ArgsString -and $ArgsString.Trim()) {
            return ($Content.Trim() + "`n`n" + $ArgsString.Trim())
        }
        return $Content.Trim()
    }
    $out = ''
    $pos = 0
    $work = $Content
    while ($pos -lt $work.Length) {
        $rem = $work.Substring($pos)
        if ($rem -match $pattern) {
            $fullMatch = [string]$Matches[0]
            $matchIdx = $rem.IndexOf($fullMatch, [StringComparison]::Ordinal)
            if ($matchIdx -gt 0) {
                $out += $rem.Substring(0, $matchIdx)
            }
            $replacement = ''
            if ($Matches[1]) {
                $defTarget = [string]$Matches[1]
                $defVal = [string]$Matches[2]
                $actual = if ($defTarget -eq '@' -or $defTarget -eq 'ARGUMENTS') {
                    $allArgs
                }
                else {
                    $idx = [int]$defTarget - 1
                    if ($idx -ge 0 -and $idx -lt $argsList.Count) { [string]$argsList[$idx] } else { '' }
                }
                $replacement = if ($actual) { $actual } else { $defVal }
            }
            elseif ($Matches[3]) {
                $sliceStart = [int]$Matches[3] - 1
                if ($sliceStart -lt 0) { $sliceStart = 0 }
                if ($sliceStart -ge $argsList.Count) {
                    $replacement = ''
                }
                elseif ($Matches[4]) {
                    $sliceLen = [int]$Matches[4]
                    $endIdx = $sliceStart + $sliceLen - 1
                    if ($endIdx -ge $argsList.Count) { $endIdx = $argsList.Count - 1 }
                    if ($endIdx -ge $sliceStart) {
                        $replacement = (@($argsList[$sliceStart..$endIdx]) -join ' ')
                    }
                }
                else {
                    $replacement = (@($argsList[$sliceStart..($argsList.Count - 1)]) -join ' ')
                }
            }
            elseif ($Matches[5]) {
                $simple = [string]$Matches[5]
                if ($simple -eq 'ARGUMENTS' -or $simple -eq '@') {
                    $replacement = $allArgs
                }
                else {
                    $idx = [int]$simple - 1
                    $replacement = if ($idx -ge 0 -and $idx -lt $argsList.Count) { [string]$argsList[$idx] } else { '' }
                }
            }
            $out += $replacement
            $pos += $matchIdx + $fullMatch.Length
        }
        else {
            $out += $rem
            break
        }
    }
    return $out.Trim()
}

function Resolve-PromptTemplate {
    param([string]$Root, [string]$ConfigDir, [string]$InputText)
    if ($script:NoPromptTemplates) { return $null }
    if ($InputText -match '^/skill:') {
        return (Resolve-SkillCommand -Root $Root -ConfigDir $ConfigDir -InputText $InputText)
    }
    if ($InputText -match '^/agent:') {
        return (Resolve-AgentRoleCommand -Root $Root -ConfigDir $ConfigDir -InputText $InputText)
    }
    if ($InputText -notmatch '^/([a-zA-Z0-9_-]+)(?:\s+(.*))?$') { return $null }
    $name = $Matches[1]
    $argsText = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
    $dirs = @()
    if ($Root) {
        $dirs += (Join-Path $Root '.shellossus/prompts')
        $dirs += (Join-Path $Root '.h-agent/prompts')
    }
    if ($ConfigDir) { $dirs += (Join-Path $ConfigDir 'prompts') }
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $cand = Join-Path $d ($name + '.md')
        if (Test-Path -LiteralPath $cand) {
            $tpl = Get-Content -LiteralPath $cand -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($tpl) {
                $body = $tpl -replace '(?s)^---\r?\n.*?\r?\n---\r?\n?', ''
                return (Expand-TemplateArgs -Content $body -ArgsString $argsText)
            }
        }
    }
    return $null
}

function Expand-UserPrompt {
    param([string]$Root, [string]$Prompt)
    $attachments = @()
    foreach ($token in @($Prompt -split '\s+')) {
        if ($token.StartsWith('@') -and $token.Length -gt 1) {
            $rel = $token.Substring(1).TrimEnd(',', '.', ';', ':', ')', ']', '?', '!')
            if (-not $rel) { continue }
            try {
                $resolved = Resolve-AgentPath -Root $Root -RelativePath $rel
                $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
                if ($item.PSIsContainer) { throw 'Target is a directory.' }
                if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB limit.' }
                $lines = @(Get-Content -LiteralPath $resolved -Encoding UTF8 -TotalCount 301 -ErrorAction Stop)
                $truncatedByLines = ($lines.Count -gt 300)
                $content = ($lines | Select-Object -First 300) -join "`n"
                $truncatedByChars = ($content.Length -gt 20000)
                if ($truncatedByChars) { $content = $content.Substring(0, 20000) }
                if ($content -match '\x00') { throw 'Binary content is not supported.' }
                if ($truncatedByLines -or $truncatedByChars) {
                    $content = $content + "`n[... truncated at 300 lines / 20000 chars; use read_file with start_line to read more ...]"
                }
                $escapedRel = Escape-XmlText -Text $rel
                $attachments += "<file path=`"$escapedRel`">`n$content`n</file>"
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + '  [@file] ' + $script:Gm.Grey1 + $rel + $script:Gm.Reset)
                }
            }
            catch {
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Yellow + '  [@file] Skipped ' + $rel + ': ' + $_.Exception.Message + $script:Gm.Reset)
                }
            }
        }
    }
    if ($attachments.Count -gt 0) {
        return ($Prompt + "`n`n" + ($attachments -join "`n`n"))
    }
    return $Prompt
}
