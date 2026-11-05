# Built-in read-only workspace inspection tools (list_files, find_files, grep_files, read_file).

function Invoke-AgentListFiles {
    param([string]$Path, $Item, $Arguments, [datetime]$ToolStart)
    if (-not $Item.PSIsContainer) { throw 'Expected a directory.' }
    $maxEntries = 200
    if ($null -ne $Arguments.limit) {
        $maxEntries = [int]$Arguments.limit
        if ($maxEntries -lt 1 -or $maxEntries -gt 500) { throw 'limit must be between 1 and 500.' }
    }
    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Where-Object {
        -not (Test-IsSecretFile $_)
    } | Sort-Object { $_.Name.ToLower() } | Select-Object -First ($maxEntries + 1))
    $isTrunc = ($entries.Count -gt $maxEntries)
    $shownEntries = @($entries | Select-Object -First $maxEntries -Property Name, PSIsContainer, Length)
    $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
    $sumText = "$($shownEntries.Count) entries" + $(if ($isTrunc) { ' (truncated)' } else { '' })
    Write-ToolCallCard -Name 'list_files' -Target $Arguments.path -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
    $notice = if ($isTrunc) { "[${maxEntries} entries limit reached]" } else { $null }
    return (@{
        entries = $shownEntries
        truncated = $isTrunc
        notice = $notice
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-AgentFindFiles {
    param([string]$Root, [string]$Path, $Item, $Arguments, [datetime]$ToolStart)
    if (-not $Item.PSIsContainer) { throw 'Expected a directory.' }
    if (-not $Arguments.pattern.Trim()) { throw 'pattern must be a nonempty string.' }
    $maxFind = 200
    if ($null -ne $Arguments.limit) {
        $maxFind = [int]$Arguments.limit
        if ($maxFind -lt 1 -or $maxFind -gt 1000) { throw 'limit must be between 1 and 1000.' }
    }
    $rawPat = $Arguments.pattern.Trim()
    $isPathPat = ($rawPat.Contains('/') -or $rawPat.Contains('\'))
    $normPat = $rawPat.Replace('\', '/').TrimStart('/')
    $altPat = if ($normPat.StartsWith('**/')) { $normPat.Substring(3) } else { '' }
    $truncated = $false
    $matchCount = 0
    $found = @(foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $Root -SearchPath $Path)) {
        $child = $walkEntry.item
        $relPath = $walkEntry.rel_path
        $relToSearch = Get-WorkspaceRelativePath -Root $Path -FullPath $child.FullName
        $isMatch = if ($isPathPat) {
            ($relPath -like $normPat) -or ($relToSearch -like $normPat) -or ($altPat -and (($relPath -like $altPat) -or ($relToSearch -like $altPat)))
        }
        else {
            ($child.Name -like $rawPat)
        }
        if ($isMatch) {
            if ($matchCount -ge $maxFind) { $truncated = $true; break }
            $matchCount++
            @{
                path = $relPath
                relative_path = $relToSearch
                is_dir = [bool]$walkEntry.is_dir
                length = if ($walkEntry.is_dir) { $null } else { $child.Length }
            }
        }
    })
    $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
    $sumText = "$($found.Count) matches" + $(if ($truncated) { ' (truncated)' } else { '' })
    Write-ToolCallCard -Name 'find_files' -Target $Arguments.path -Detail "pattern=$rawPat" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
    $notice = if ($truncated) { "[${maxFind} results limit reached. Refine pattern or increase limit]" } else { $null }
    return (@{ matches = @($found); files = @($found); count = $found.Count; truncated = $truncated; notice = $notice } | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-AgentGrepFiles {
    param([string]$Root, [string]$Path, $Item, $Arguments, [datetime]$ToolStart)
    if (-not $Arguments.pattern) { throw 'pattern must be a nonempty string.' }
    $isLiteral = ($Arguments.literal -eq $true)
    $isCaseSensitive = ($Arguments.case_sensitive -eq $true)
    $includeFilter = if ($Arguments.include -is [string] -and $Arguments.include.Trim()) {
        $Arguments.include.Trim()
    }
    elseif ($Arguments.glob -is [string] -and $Arguments.glob.Trim()) {
        $Arguments.glob.Trim()
    }
    else {
        ''
    }
    $ctxLines = 0
    if ($null -ne $Arguments.context_lines) {
        $ctxLines = [int]$Arguments.context_lines
        if ($ctxLines -lt 0 -or $ctxLines -gt 5) { throw 'context_lines must be between 0 and 5.' }
    }
    $maxMatches = 100
    if ($null -ne $Arguments.limit) {
        $maxMatches = [int]$Arguments.limit
        if ($maxMatches -lt 1 -or $maxMatches -gt 500) { throw 'limit must be between 1 and 500.' }
    }
    $fileOffset = 0
    if ($null -ne $Arguments.file_offset) {
        $fileOffset = [int]$Arguments.file_offset
        if ($fileOffset -lt 0) { throw 'file_offset must be at least 0.' }
    }
    $startLine = 1
    if ($null -ne $Arguments.start_line) {
        $startLine = [int]$Arguments.start_line
        if ($startLine -lt 1) { throw 'start_line must be at least 1.' }
    }
    $allCandidateFiles = @(if ($Item.PSIsContainer) {
        foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $Root -SearchPath $Path -FilesOnly)) {
            $child = $walkEntry.item
            $relCandidate = $walkEntry.rel_path
            if ($includeFilter -and ($child.Name -notlike $includeFilter) -and ($relCandidate -notlike $includeFilter)) { continue }
            if ($child.Length -le 1MB) { $child.FullName }
        }
    }
    else {
        if ($Item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
        $Item.FullName
    })
    # Offsets are stable while the candidate file set is unchanged.
    $allCandidateFiles = @($allCandidateFiles | Sort-Object -CaseSensitive)
    $totalFiles = $allCandidateFiles.Count
    $filesScanned = 0
    $fileLimitReached = $false
    $matchLimitReached = $false
    $linesTruncated = $false
    $hitCount = 0
    $hits = @()
    $nextFileOffset = $null
    $nextStartLine = $null
    for ($fileIndex = $fileOffset; $fileIndex -lt $totalFiles -and $filesScanned -lt 500; $fileIndex++) {
        $filesScanned++
        $firstLine = if ($fileIndex -eq $fileOffset) { $startLine } else { 1 }
        $selParams = @{ LiteralPath = $allCandidateFiles[$fileIndex]; Pattern = $Arguments.pattern; Encoding = 'UTF8'; ErrorAction = 'Stop' }
        if ($isLiteral) { $selParams.SimpleMatch = $true }
        if ($isCaseSensitive) { $selParams.CaseSensitive = $true }
        if ($ctxLines -gt 0) { $selParams.Context = @($ctxLines, $ctxLines) }
        # Keep one lookahead match so continuation within a file starts
        # at the first result not returned, without buffering all matches.
        $pageMatches = @(Select-String @selParams | Where-Object { $_.LineNumber -ge $firstLine } | Select-Object -First ($maxMatches - $hitCount + 1))
        foreach ($m in $pageMatches) {
            if ($hitCount -ge $maxMatches) {
                $matchLimitReached = $true
                $nextFileOffset = $fileIndex
                $nextStartLine = [int]$m.LineNumber
                break
            }
            $hitCount++
            $lineText = [string]$m.Line
            if ($lineText.Length -gt 300) {
                $lineText = $lineText.Substring(0, 300) + '...'
                $linesTruncated = $true
            }
            $hitObj = @{
                path = (Get-WorkspaceRelativePath -Root $Root -FullPath $m.Path)
                file = (Get-WorkspaceRelativePath -Root $Path -FullPath $m.Path)
                line_number = [int]$m.LineNumber
                line = $lineText
            }
            if ($ctxLines -gt 0 -and $m.Context) {
                $hitObj.context = @($m.Context.PreContext) + @($lineText) + @($m.Context.PostContext)
            }
            $hits += $hitObj
        }
        if ($matchLimitReached) { break }
        if ($fileIndex + 1 -lt $totalFiles) {
            $matchLimitReached = ($hitCount -ge $maxMatches)
            $fileLimitReached = ($filesScanned -ge 500)
            if ($matchLimitReached -or $fileLimitReached) {
                $nextFileOffset = $fileIndex + 1
                $nextStartLine = 1
                break
            }
        }
    }
    $truncated = ($fileLimitReached -or $matchLimitReached)
    $truncReason = if ($matchLimitReached -and $fileLimitReached) {
        'max_matches_and_max_files'
    }
    elseif ($matchLimitReached) {
        'max_matches'
    }
    elseif ($fileLimitReached) {
        'max_files'
    }
    else {
        $null
    }
    $notices = @()
    if ($matchLimitReached) { $notices += "${maxMatches} matches limit reached" }
    if ($fileLimitReached) { $notices += "Scanned ${filesScanned} of ${totalFiles} files" }
    if ($truncated) { $notices += "Continue with file_offset=${nextFileOffset} and start_line=${nextStartLine} using the same search arguments" }
    if ($linesTruncated) { $notices += 'Some lines truncated to 300 chars; use read_file for full lines' }
    $noticeStr = if ($notices.Count -gt 0) { '[' + ($notices -join '. ') + ']' } else { $null }
    $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
    $sumText = "$($hits.Count) matches in $filesScanned files" + $(if ($truncated) { ' (truncated)' } else { '' })
    Write-ToolCallCard -Name 'grep_files' -Target $Arguments.path -Detail "pattern=$($Arguments.pattern)" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
    return (@{
        matches = @($hits)
        truncated = $truncated
        truncation_reason = $truncReason
        files_scanned = $filesScanned
        total_files = $totalFiles
        next_file_offset = $nextFileOffset
        next_start_line = $nextStartLine
        lines_truncated = $linesTruncated
        notice = $noticeStr
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-AgentReadFile {
    param([string]$Path, $Item, $Arguments, [datetime]$ToolStart)
    if ($Item.PSIsContainer) { throw 'Expected a text file.' }
    if ($Item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
    $startLine = 1
    if ($null -ne $Arguments.start_line) {
        $startLine = [int]$Arguments.start_line
        if ($startLine -lt 1) { throw 'start_line must be at least 1.' }
    }
    elseif ($null -ne $Arguments.offset) {
        $startLine = [int]$Arguments.offset
        if ($startLine -lt 1) { throw 'offset must be at least 1.' }
    }
    $startChar = 1
    if ($null -ne $Arguments.start_char) {
        $startChar = [int]$Arguments.start_char
        if ($startChar -lt 1) { throw 'start_char must be at least 1.' }
    }
    $maxLines = 300
    if ($null -ne $Arguments.max_lines) {
        $maxLines = [int]$Arguments.max_lines
        if ($maxLines -lt 1 -or $maxLines -gt 300) { throw 'max_lines must be between 1 and 300.' }
    }
    elseif ($null -ne $Arguments.limit) {
        $maxLines = [int]$Arguments.limit
        if ($maxLines -lt 1 -or $maxLines -gt 300) { throw 'limit must be between 1 and 300.' }
    }
    $allLines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
    $totalLines = $allLines.Count
    $charBudget = 20000
    if ($totalLines -eq 0 -or $startLine -gt $totalLines) {
        $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
        Write-ToolCallCard -Name 'read_file' -Target $Arguments.path -Detail "lines $startLine..$totalLines" -Status 'ok' -Summary "0 lines ($totalLines total)" -ElapsedMs $elapsedMs
        return (@{
            text = ''
            start_line = $startLine
            start_char = $startChar
            end_line = $totalLines
            total_lines = $totalLines
            truncated = $false
            next_start_line = $null
            next_start_char = $null
            notice = $null
        } | ConvertTo-Json -Compress)
    }
    $limitIdx = $startLine - 1 + $maxLines - 1
    if ($limitIdx -ge $totalLines) { $limitIdx = $totalLines - 1 }
    $pageLines = @()
    $currentLen = 0
    $endLine = $startLine - 1
    $truncated = $false
    $nextStartLine = $null
    $nextStartChar = $null
    for ($i = $startLine - 1; $i -le $limitIdx; $i++) {
        $lineStr = [string]$allLines[$i]
        if ($i -eq ($startLine - 1) -and $startChar -gt 1) {
            if ($startChar -gt ($lineStr.Length + 1)) {
                $lineStr = ''
            }
            else {
                $lineStr = $lineStr.Substring($startChar - 1)
            }
        }
        if ($pageLines.Count -eq 0 -and $lineStr.Length -gt $charBudget) {
            $pageLines += $lineStr.Substring(0, $charBudget)
            $endLine = $i + 1
            $truncated = $true
            $nextStartLine = $i + 1
            $nextStartChar = $startChar + $charBudget
            break
        }
        $addedLen = if ($pageLines.Count -eq 0) { $lineStr.Length } else { 1 + $lineStr.Length }
        if (($currentLen + $addedLen) -gt $charBudget) {
            $truncated = $true
            $nextStartLine = $i + 1
            $nextStartChar = $null
            break
        }
        $pageLines += $lineStr
        $currentLen += $addedLen
        $endLine = $i + 1
    }
    if (-not $truncated -and $endLine -lt $totalLines) {
        $truncated = $true
        $nextStartLine = $endLine + 1
        $nextStartChar = $null
    }
    $readNotice = if ($truncated -and $null -ne $nextStartChar) {
        "[Showing line ${startLine} chars ${startChar}..$($nextStartChar - 1). Use start_line=${nextStartLine}, start_char=${nextStartChar} to continue.]"
    }
    elseif ($truncated) {
        "[Showing lines ${startLine}-${endLine} of ${totalLines}. Use start_line=${nextStartLine} to continue.]"
    }
    else {
        $null
    }
    $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
    $sumText = "$($pageLines.Count) lines ($totalLines total)" + $(if ($truncated) { ' [paginated]' } else { '' })
    Write-ToolCallCard -Name 'read_file' -Target $Arguments.path -Detail "lines $startLine..$endLine" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
    return (@{
        text = ($pageLines -join "`n")
        start_line = $startLine
        start_char = $startChar
        end_line = $endLine
        total_lines = $totalLines
        truncated = $truncated
        next_start_line = $nextStartLine
        next_start_char = $nextStartChar
        notice = $readNotice
    } | ConvertTo-Json -Compress)
}
