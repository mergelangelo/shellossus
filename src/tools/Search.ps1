# Built-in read-only workspace inspection tools (list_files, find_files, grep_files, read_file).

function Invoke-AgentListFiles {
    param([string]$Path, $Item, $Arguments, [datetime]$ToolStart)
    if (-not $Item.PSIsContainer) { throw 'Expected a directory.' }
    $maxEntries = 200
    if ($null -ne $Arguments.limit) {
        $maxEntries = [int]$Arguments.limit
        if ($maxEntries -lt 1 -or $maxEntries -gt 500) { throw 'limit must be between 1 and 500.' }
    }
    $walkLimit = $script:AgentMaxWalkEntries
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First ($walkLimit + 1))
    $walkTruncated = ($items.Count -gt $walkLimit)
    $entries = @($items | Select-Object -First $walkLimit | Where-Object {
        -not (Test-IsSecretFile $_)
    } | Sort-Object { $_.Name.ToLower() } | Select-Object -First ($maxEntries + 1))
    $isTrunc = ($entries.Count -gt $maxEntries -or $walkTruncated)
    $shownEntries = @($entries | Select-Object -First $maxEntries -Property Name, PSIsContainer, Length)
    $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
    $sumText = "$($shownEntries.Count) entries" + $(if ($isTrunc) { ' (truncated)' } else { '' })
    Write-ToolCallCard -Name 'list_files' -Target $Arguments.path -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
    $notice = if ($walkTruncated) { "[Directory entry scan limit reached ($walkLimit)]" }
    elseif ($isTrunc) { "[${maxEntries} entries limit reached]" }
    else { $null }
    return (@{
        entries = $shownEntries
        truncated = $isTrunc
        notice = $notice
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Get-GlobCandidatePatterns {
    param([string]$Pattern)
    if (-not $Pattern) { return @() }
    if ($Pattern.Length -gt 4096) { throw 'Glob pattern exceeds 4096 characters.' }
    $normPat = $Pattern.Replace('\', '/').TrimStart('/')
    if (-not $normPat) { return @($Pattern) }
    $candPats = @($normPat)
    while ($true) {
        $addedPat = $false
        foreach ($cp in @($candPats)) {
            if ($cp.StartsWith('**/')) {
                $trimmedLead = $cp.Substring(3)
                if ($trimmedLead -and ($candPats -notcontains $trimmedLead)) {
                    $candPats += $trimmedLead
                    if ($candPats.Count -gt 16) { throw 'Glob expands to more than 16 patterns.' }
                    $addedPat = $true
                }
            }
            $scanPos = 0
            while ($scanPos -lt $cp.Length) {
                $rem = $cp.Substring($scanPos)
                $relIdx = $rem.IndexOf('/**/')
                if ($relIdx -lt 0) { break }
                $absIdx = $scanPos + $relIdx
                $collapsedMid = $cp.Substring(0, $absIdx) + '/' + $cp.Substring($absIdx + 4)
                if ($collapsedMid -and ($candPats -notcontains $collapsedMid)) {
                    $candPats += $collapsedMid
                    if ($candPats.Count -gt 16) { throw 'Glob expands to more than 16 patterns.' }
                    $addedPat = $true
                }
                $scanPos = $absIdx + 3
            }
            if ($cp.EndsWith('/**')) {
                $trimmedTrail = $cp.Substring(0, $cp.Length - 3)
                if ($trimmedTrail -and ($candPats -notcontains $trimmedTrail)) {
                    $candPats += $trimmedTrail
                    if ($candPats.Count -gt 16) { throw 'Glob expands to more than 16 patterns.' }
                    $addedPat = $true
                }
            }
        }
        if (-not $addedPat) { break }
    }
    return @($candPats)
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
    $candPats = @(Get-GlobCandidatePatterns -Pattern $rawPat)
    $walk = @{ limit = $script:AgentMaxWalkEntries; visited = 0; truncated = $false }
    $found = @(Get-WorkspaceWalkEntries -Root $Root -SearchPath $Path -Budget $walk | ForEach-Object {
        $walkEntry = $_
        $child = $walkEntry.item
        $relPath = $walkEntry.rel_path
        $relToSearch = Get-WorkspaceRelativePath -Root $Path -FullPath $child.FullName
        $isMatch = if ($isPathPat) {
            $matchedPat = $false
            foreach ($cp in $candPats) {
                if (($relPath -like $cp) -or ($relToSearch -like $cp)) {
                    $matchedPat = $true
                    break
                }
            }
            $matchedPat
        }
        else {
            ($child.Name -like $rawPat)
        }
        if ($isMatch) {
            @{
                path = $relPath
                relative_path = $relToSearch
                is_dir = [bool]$walkEntry.is_dir
                length = if ($walkEntry.is_dir) { $null } else { $child.Length }
            }
        }
    } | Select-Object -First ($maxFind + 1))
    $truncated = ($found.Count -gt $maxFind -or $walk.truncated)
    $found = @($found | Select-Object -First $maxFind)
    $elapsedMs = [int](((Get-Date) - $ToolStart).TotalMilliseconds)
    $sumText = "$($found.Count) matches" + $(if ($truncated) { ' (truncated)' } else { '' })
    Write-ToolCallCard -Name 'find_files' -Target $Arguments.path -Detail "pattern=$rawPat" -Status 'ok' -Summary $sumText -ElapsedMs $elapsedMs
    $notice = if ($walk.truncated) { '[Workspace traversal limit reached. Narrow the search path]' }
    elseif ($truncated) { "[${maxFind} results limit reached. Refine pattern or increase limit]" }
    else { $null }
    return (@{ matches = @($found); files = @($found); count = $found.Count; truncated = $truncated; entries_visited = $walk.visited; notice = $notice } | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-AgentGrepFiles {
    param([string]$Root, [string]$Path, $Item, $Arguments, [datetime]$ToolStart)
    if (-not $Arguments.pattern) { throw 'pattern must be a nonempty string.' }
    $isLiteral = ($Arguments.literal -eq $true)
    $isCaseSensitive = ($Arguments.case_sensitive -eq $true)
    $includeFilter = if ($Arguments.include -is [string] -and $Arguments.include.Trim()) {
        $Arguments.include.Trim().Replace('\', '/')
    }
    elseif ($Arguments.glob -is [string] -and $Arguments.glob.Trim()) {
        $Arguments.glob.Trim().Replace('\', '/')
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
    if ($Arguments.pattern.Length -gt 4096) { throw 'Search pattern exceeds 4096 characters.' }
    $comparison = if ($isCaseSensitive) { [StringComparison]::CurrentCulture } else { [StringComparison]::CurrentCultureIgnoreCase }
    if (-not $isLiteral) {
        $regexOptions = if ($isCaseSensitive) { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
        $pattern = [regex]::new($Arguments.pattern, $regexOptions, (New-TimeSpan -Milliseconds 100))
    }
    $walk = @{ limit = $script:AgentMaxWalkEntries; visited = 0; truncated = $false }
    $includePatterns = @(if ($includeFilter) { Get-GlobCandidatePatterns -Pattern $includeFilter } else { @() })
    $allCandidateFiles = @(if ($Item.PSIsContainer) {
        foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $Root -SearchPath $Path -FilesOnly -Budget $walk)) {
            $child = $walkEntry.item
            $relCandidate = $walkEntry.rel_path
            if ($includePatterns.Count -gt 0) {
                $incMatched = $false
                foreach ($incPat in $includePatterns) {
                    if (($child.Name -like $incPat) -or ($relCandidate -like $incPat)) {
                        $incMatched = $true
                        break
                    }
                }
                if (-not $incMatched) { continue }
            }
            if ($child.Length -le 1MB) { $child.FullName }
        }
    }
    else {
        if ($Item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
        $relSingle = Get-WorkspaceRelativePath -Root $Root -FullPath $Item.FullName
        $incOk = ($includePatterns.Count -eq 0)
        foreach ($incPat in $includePatterns) {
            if (($Item.Name -like $incPat) -or ($relSingle -like $incPat)) {
                $incOk = $true
                break
            }
        }
        if ($incOk) {
            $singleRules = @(Get-WorkspaceIgnoreRules -Root $Root -SearchPath $Item.FullName)
            if (-not (Test-PathIgnored -RelativePath $relSingle -IsDir $false -Rules $singleRules)) {
                $Item.FullName
            }
        }
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
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    $timedOut = $false
    :scan for ($fileIndex = $fileOffset; $fileIndex -lt $totalFiles -and $filesScanned -lt 500; $fileIndex++) {
        $firstLine = if ($fileIndex -eq $fileOffset) { $startLine } else { 1 }
        if ([datetime]::UtcNow -ge $deadline) {
            $timedOut = $true
            $nextFileOffset = $fileIndex
            $nextStartLine = $firstLine
            break
        }
        $file = Get-Item -LiteralPath $allCandidateFiles[$fileIndex] -Force -ErrorAction Stop
        $filesScanned++
        if ($file.Length -le 1MB -and -not $file.PSIsContainer -and ($file.Attributes -band 1024) -eq 0) {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $lines = @($raw -split '\r\n|[\r\n]')
            $lineCount = $lines.Count
            if ($lineCount -gt 0 -and $lines[-1] -eq '') { $lineCount-- }
            for ($i = $firstLine - 1; $i -lt $lineCount; $i++) {
                if ([datetime]::UtcNow -ge $deadline) {
                    $timedOut = $true
                    $nextFileOffset = $fileIndex
                    $nextStartLine = $i + 1
                    break scan
                }
                try {
                    $matched = if ($isLiteral) { $lines[$i].IndexOf($Arguments.pattern, $comparison) -ge 0 }
                    else { $pattern.IsMatch($lines[$i]) }
                }
                catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                    throw 'Regular expression exceeded the 100 ms match limit. Simplify the pattern or use literal matching.'
                }
                if (-not $matched) { continue }
                # Keep one lookahead match so continuation starts at the first omitted hit.
                if ($hitCount -ge $maxMatches) {
                    $matchLimitReached = $true
                    $nextFileOffset = $fileIndex
                    $nextStartLine = $i + 1
                    break scan
                }
                $hitCount++
                $firstContext = $i - $ctxLines
                if ($firstContext -lt 0) { $firstContext = 0 }
                $lastContext = $i + $ctxLines
                if ($lastContext -ge $lineCount) { $lastContext = $lineCount - 1 }
                $excerpt = @(for ($j = $firstContext; $j -le $lastContext; $j++) {
                    $line = $lines[$j]
                    if ($line.Length -gt 300) {
                        $line = $line.Substring(0, 300) + '...'
                        $linesTruncated = $true
                    }
                    $line
                })
                $hit = @{
                    path = (Get-WorkspaceRelativePath -Root $Root -FullPath $file.FullName)
                    file = (Get-WorkspaceRelativePath -Root $Path -FullPath $file.FullName)
                    line_number = $i + 1
                    line = $excerpt[$i - $firstContext]
                }
                if ($ctxLines -gt 0) { $hit.context = $excerpt }
                $hits += $hit
            }
        }
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
    $truncated = ($fileLimitReached -or $matchLimitReached -or $timedOut -or $walk.truncated)
    $truncReason = if ($timedOut) {
        'search_timeout'
    }
    elseif ($matchLimitReached -and $fileLimitReached) {
        'max_matches_and_max_files'
    }
    elseif ($matchLimitReached) {
        'max_matches'
    }
    elseif ($fileLimitReached) {
        'max_files'
    }
    elseif ($walk.truncated) {
        'max_entries'
    }
    else {
        $null
    }
    $notices = @()
    if ($matchLimitReached) { $notices += "${maxMatches} matches limit reached" }
    if ($fileLimitReached) { $notices += "Scanned ${filesScanned} of ${totalFiles} files" }
    if ($timedOut) { $notices += 'Search time limit reached' }
    if ($walk.truncated) { $notices += 'Workspace traversal limit reached. Narrow the search path to scan remaining files' }
    if ($null -ne $nextFileOffset) { $notices += "Continue with file_offset=${nextFileOffset} and start_line=${nextStartLine} using the same search arguments" }
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
        total_files_exact = (-not $walk.truncated)
        entries_visited = $walk.visited
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
    $reqStartIdx = $startLine - 1
    $reqEndIdx = $reqStartIdx + $maxLines - 1
    $windowLines = @()
    $totalLines = 0
    Get-Content -LiteralPath $Path -ReadCount 500 -Encoding UTF8 -ErrorAction Stop | ForEach-Object {
        $batch = @($_)
        $batchCount = $batch.Count
        if ($batchCount -gt 0) {
            $batchStart = $totalLines
            $batchEnd = $totalLines + $batchCount - 1
            if ($batchEnd -ge $reqStartIdx -and $batchStart -le $reqEndIdx) {
                $sliceFrom = if ($reqStartIdx -gt $batchStart) { $reqStartIdx - $batchStart } else { 0 }
                $sliceTo = if ($reqEndIdx -lt $batchEnd) { $reqEndIdx - $batchStart } else { $batchCount - 1 }
                for ($k = $sliceFrom; $k -le $sliceTo; $k++) {
                    $windowLines += [string]$batch[$k]
                }
            }
            $totalLines += $batchCount
        }
    }
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
    $pageLines = @()
    $currentLen = 0
    $endLine = $startLine - 1
    $truncated = $false
    $nextStartLine = $null
    $nextStartChar = $null
    for ($idx = 0; $idx -lt $windowLines.Count; $idx++) {
        $i = $reqStartIdx + $idx
        $lineStr = [string]$windowLines[$idx]
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
