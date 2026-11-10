# Reusable slash prompt templates and inline @file / !cmd prompt expansion.

function Split-CommandArgs {
    param([string]$ArgsString, [switch]$WithSource)
    $argsList = @()
    if (-not $ArgsString) { return $argsList }
    $current = ''
    $hasToken = $false
    $inQuote = ''
    $tokenStart = 0
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
                $argsList += $(if ($WithSource) {
                    @{ value = $current; source = $ArgsString.Substring($tokenStart, $i - $tokenStart) }
                } else { $current })
                $current = ''
                $hasToken = $false
            }
            $tokenStart = $i + 1
        }
        else {
            $current += $ch
            $hasToken = $true
        }
    }
    if ($hasToken) {
        $argsList += $(if ($WithSource) {
            @{ value = $current; source = $ArgsString.Substring($tokenStart) }
        } else { $current })
    }
    return $argsList
}

function Expand-TemplateArgs {
    param([string]$Content, [string]$ArgsString = '', [switch]$ForCommand)
    $pattern = '\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)'
    if ($Content -notmatch $pattern) {
        if ($ForCommand) {
            return @{ text = $Content.Trim(); has_placeholders = $false; remaining_args = $ArgsString.Trim() }
        }
        if ($Content -and $ArgsString.Trim()) {
            return ($Content.Trim() + "`n`n" + $ArgsString.Trim())
        }
        return $Content.Trim()
    }
    $tokens = @(Split-CommandArgs -ArgsString $ArgsString -WithSource:$ForCommand)
    $argsList = @(if ($ForCommand) { $tokens | ForEach-Object { $_.value } } else { $tokens })
    $allArgs = $argsList -join ' '
    $used = @{}
    $usedAll = $false
    $out = ''
    $pos = 0
    while ($pos -lt $Content.Length) {
        $rem = $Content.Substring($pos)
        if ($rem -match $pattern) {
            $fullMatch = [string]$Matches[0]
            $matchIdx = $rem.IndexOf($fullMatch, [StringComparison]::Ordinal)
            if ($matchIdx -gt 0) {
                $out += $rem.Substring(0, $matchIdx)
            }
            $replacement = ''
            if ($Matches[3]) {
                $sliceStart = [int]$Matches[3] - 1
                if ($sliceStart -lt 0) { $sliceStart = 0 }
                $sliceEnd = $argsList.Count - 1
                if ($Matches[4]) {
                    $requestedEnd = $sliceStart + [int]$Matches[4] - 1
                    if ($requestedEnd -lt $sliceEnd) { $sliceEnd = $requestedEnd }
                }
                if ($sliceEnd -ge $sliceStart) {
                    $indices = $sliceStart..$sliceEnd
                    $replacement = $argsList[$indices] -join ' '
                    if ($ForCommand) {
                        foreach ($idx in $indices) { $used[$idx] = $true }
                    }
                }
            }
            else {
                $target = if ($Matches[1]) { [string]$Matches[1] } else { [string]$Matches[5] }
                if ($target -eq '@' -or $target -eq 'ARGUMENTS') {
                    $replacement = $allArgs
                    $usedAll = $true
                }
                else {
                    $idx = [int]$target - 1
                    if ($idx -ge 0 -and $idx -lt $argsList.Count) {
                        $replacement = [string]$argsList[$idx]
                        if ($ForCommand) { $used[$idx] = $true }
                    }
                }
                if (-not $replacement -and $Matches[1]) { $replacement = [string]$Matches[2] }
            }
            $out += $replacement
            $pos += $matchIdx + $fullMatch.Length
        }
        else {
            $out += $rem
            break
        }
    }
    if ($ForCommand) {
        # Preserve quoting on arguments that were not rendered into the role.
        $remaining = if ($usedAll) { '' } else {
            @(for ($i = 0; $i -lt $tokens.Count; $i++) {
                if (-not $used.ContainsKey($i)) { $tokens[$i].source }
            }) -join ' '
        }
        return @{ text = $out.Trim(); has_placeholders = $true; remaining_args = $remaining }
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
    }
    if ($ConfigDir) { $dirs += (Join-Path $ConfigDir 'prompts') }
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $cand = Join-Path $d ($name + '.md')
        if (Test-Path -LiteralPath $cand) {
            $candItem = Get-Item -LiteralPath $cand -Force -ErrorAction SilentlyContinue
            if (-not $candItem -or $candItem.PSIsContainer -or $candItem.Length -gt 128KB) { continue }
            if (Test-PathHasReparsePoint -Path $candItem.FullName -StopAt $d) { continue }
            $tpl = Get-Content -LiteralPath $candItem.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($tpl -and ($tpl -notmatch '\x00')) {
                $body = $tpl -replace '(?s)^---\r?\n.*?\r?\n---\r?\n?', ''
                return (Expand-TemplateArgs -Content $body -ArgsString $argsText)
            }
        }
    }
    return $null
}

function Expand-UserPrompt {
    param([string]$Root, [string]$Prompt, [string]$AttachmentSource = $Prompt)
    $attachments = @()
    $seenPaths = @{}
    foreach ($token in @($AttachmentSource -split '\s+')) {
        if (($token.StartsWith('"@') -and $token.EndsWith('"')) -or
            ($token.StartsWith("'@") -and $token.EndsWith("'"))) {
            $token = $token.Substring(1, $token.Length - 2)
        }
        if ($token.StartsWith('@') -and $token.Length -gt 1) {
            $rel = $token.Substring(1).TrimEnd(',', '.', ';', ':', ')', ']', '?', '!')
            if (-not $rel) { continue }
            try {
                $resolved = Resolve-AgentPath -Root $Root -RelativePath $rel
                if ($seenPaths.ContainsKey($resolved)) { continue }
                $seenPaths[$resolved] = $true
                $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
                if ($item.PSIsContainer) { throw 'Target is a directory.' }
                if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB limit.' }
                $lines = @(Get-Content -LiteralPath $resolved -Encoding UTF8 -TotalCount 301 -ErrorAction Stop)
                $truncatedByLines = ($lines.Count -gt 300)
                $content = ($lines | Select-Object -First 300) -join "`n"
                if ($content -match '\x00') { throw 'Binary content is not supported.' }
                $truncatedByChars = ($content.Length -gt 20000)
                if ($truncatedByChars) { $content = $content.Substring(0, 20000) }
                if ($truncatedByLines -or $truncatedByChars) {
                    $content = $content + "`n[... truncated at 300 lines / 20000 chars; use read_file with start_line to read more ...]"
                }
                $escapedRel = Escape-XmlText -Text $rel
                $attachments += "<file path=`"$escapedRel`">`n$content`n</file>"
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + '  [@file] ' + $script:Gm.Grey1 + (Format-TuiText $rel) + $script:Gm.Reset)
                }
            }
            catch {
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Yellow + '  [@file] Skipped ' + (Format-TuiText $rel) + ': ' + (Format-TuiText $_.Exception.Message) + $script:Gm.Reset)
                }
            }
        }
    }
    if ($attachments.Count -gt 0) {
        return ($Prompt + "`n`n" + ($attachments -join "`n`n"))
    }
    return $Prompt
}
