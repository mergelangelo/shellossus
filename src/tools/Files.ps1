# Fuzzy text matching, diff preview helpers, and transactional file writes (write_file, edit_file).

function Format-FuzzyLine {
    param([string]$Line)
    $s = $Line.TrimEnd()
    $s = $s -replace '^\uFEFF', ''
    $s = $s -replace '[\u2018\u2019\u201A\u201B]', "'"
    $s = $s -replace '[\u201C\u201D\u201E\u201F]', '"'
    $s = $s -replace '[\u2010-\u2015\u2212]', '-'
    $s = $s -replace '[\u00A0\u2002-\u200A\u202F\u205F\u3000]', ' '
    return $s
}

function Find-EditMatch {
    param([string]$Content, [string]$OldText)
    $idx = $Content.IndexOf($OldText, [StringComparison]::Ordinal)
    if ($idx -ge 0) {
        if ($Content.IndexOf($OldText, $idx + $OldText.Length, [StringComparison]::Ordinal) -ge 0) {
            throw 'old_text occurs more than once. Provide more context.'
        }
        return @{ index = $idx; length = $OldText.Length; matched_text = $OldText }
    }
    if ($Content.Contains("`r`n")) {
        $crlfOld = $OldText.Replace("`r`n", "`n").Replace("`n", "`r`n")
        $idx = $Content.IndexOf($crlfOld, [StringComparison]::Ordinal)
        if ($idx -ge 0) {
            if ($Content.IndexOf($crlfOld, $idx + $crlfOld.Length, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text occurs more than once. Provide more context.'
            }
            return @{ index = $idx; length = $crlfOld.Length; matched_text = $crlfOld }
        }
    }
    elseif ($OldText.Contains("`r`n")) {
        $lfOld = $OldText.Replace("`r`n", "`n")
        $idx = $Content.IndexOf($lfOld, [StringComparison]::Ordinal)
        if ($idx -ge 0) {
            if ($Content.IndexOf($lfOld, $idx + $lfOld.Length, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text occurs more than once. Provide more context.'
            }
            return @{ index = $idx; length = $lfOld.Length; matched_text = $lfOld }
        }
    }
    $contentLines = @($Content -split "`n")
    $oldClean = $OldText.Replace("`r`n", "`n").TrimEnd("`r")
    if ($oldClean.Length -gt 0 -and $oldClean.EndsWith("`n")) {
        $oldClean = $oldClean.Substring(0, $oldClean.Length - 1)
    }
    $oldLines = @($oldClean -split "`n")
    if ($oldLines.Count -gt 0 -and $oldLines.Count -le $contentLines.Count) {
        $lineStarts = @()
        $pos = 0
        for ($i = 0; $i -lt $contentLines.Count; $i++) {
            $lineStarts += $pos
            $pos += $contentLines[$i].Length + 1
        }
        $normContent = @($contentLines | ForEach-Object { Format-FuzzyLine -Line $_ })
        $normOld = @($oldLines | ForEach-Object { Format-FuzzyLine -Line $_ })
        $matchesFound = @()
        $maxStart = $contentLines.Count - $oldLines.Count
        for ($i = 0; $i -le $maxStart; $i++) {
            $ok = $true
            for ($j = 0; $j -lt $oldLines.Count; $j++) {
                if ($normContent[$i + $j] -cne $normOld[$j]) { $ok = $false; break }
            }
            if ($ok) { $matchesFound += $i }
        }
        if ($matchesFound.Count -gt 1) {
            throw 'old_text occurs more than once. Provide more context.'
        }
        if ($matchesFound.Count -eq 1) {
            $startLineIdx = $matchesFound[0]
            $endLineIdx = $startLineIdx + $oldLines.Count - 1
            $charStart = $lineStarts[$startLineIdx]
            $endLineRaw = $contentLines[$endLineIdx]
            $endLineCleanLen = if ($endLineRaw.EndsWith("`r")) { $endLineRaw.Length - 1 } else { $endLineRaw.Length }
            $charEnd = $lineStarts[$endLineIdx] + $endLineCleanLen
            $matchedLen = $charEnd - $charStart
            return @{
                index = $charStart
                length = $matchedLen
                matched_text = $Content.Substring($charStart, $matchedLen)
            }
        }
    }
    throw 'old_text was not found. Read the file again.'
}

function ConvertTo-ExistingLineEndings {
    param([string]$Content, [string]$Original)
    if ($Original.Contains("`r`n")) {
        return $Content.Replace("`r`n", "`n").Replace("`n", "`r`n")
    }
    if ($Original.Contains("`n")) { return $Content.Replace("`r`n", "`n") }
    # Empty and single-line files do not establish a newline convention.
    return $Content
}

function Invoke-AgentStagedWrite {
    param(
        [string]$Root,
        [string]$Name,
        $Arguments,
        $before,
        [string]$after,
        [int]$editsApplied,
        [int]$firstChangedLine,
        [string]$parent,
        [string]$leaf,
        [string[]]$dirsToCreate
    )
    if ($after.Length -gt 1MB -or ($null -ne $before -and $before.Length -gt 1MB)) { throw 'File content exceeds 1 MiB limit.' }
    if ($after -match '\x00' -or ($null -ne $before -and $before -match '\x00')) { throw 'Binary content is not supported.' }
    if ($script:OutputMode -ne 'json') {
        Write-Host ''
        Write-UnifiedDiffCard -Path $Arguments.path -ToolName $Name -Before $before -After $after
    }
    if ($script:AgentPermission -in @('AutoEdit', 'Auto')) {
        if ($script:OutputMode -ne 'json') {
            Write-Host ('  ' + $script:Gm.Aqua + $script:Box.Check + ' [auto-approved by ' + $script:AgentPermission + ' mode]' + $script:Gm.Reset)
        }
    }
    else {
        if ($script:OutputMode -eq 'json') {
            return (@{ status = 'cancelled'; message = 'Interactive confirmation is disabled in JSON mode. Use -Permission AutoEdit or Auto to allow file modifications.' } | ConvertTo-Json -Compress)
        }
        $confirmed = $false
        while (-not $confirmed) {
            $promptStr = '  ' + $script:Gm.BoldYellow + $script:Box.Arrow + ' Confirm [y]es, [n]o, [a]ll edits, [d]iff: ' + $script:Gm.Fg
            $choice = Read-TuiConfirmation -PromptText $promptStr -AllowDiff -ActionType 'write'
            if ($choice -eq 'd') {
                Write-Host ''
                Write-UnifiedDiffCard -Path $Arguments.path -ToolName $Name -Before $before -After $after -MaxLines 500
                continue
            }
            if ($choice -eq 'a') {
                $script:AgentPermission = 'AutoEdit'
                Write-Host ('  ' + $script:Gm.Aqua + $script:Box.Check + ' [switched permission to AutoEdit for this session]' + $script:Gm.Reset)
                $confirmed = $true
                break
            }
            if ($choice -eq 'y') {
                $confirmed = $true
                break
            }
            Write-Host ('  ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
            return (@{ status = 'cancelled'; message = 'User declined. Do not retry without a new user request.' } | ConvertTo-Json -Compress)
        }
    }
    $stageFile = New-AgentTempFile
    $backup = $null
    $backupPath = $null
    $backupRecorded = $false
    try {
        Set-AgentUtf8Content -LiteralPath $stageFile.FullName -Value $after
        $stagedCheck = Get-Content -LiteralPath $stageFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $stagedCheck) { $stagedCheck = '' }
        if ($stagedCheck -cne $after) { throw 'Staged file verification failed. No write performed.' }
        if ($null -ne $before) {
            $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
            $current = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -eq $current) { $current = '' }
            if ($current -cne $before) { throw 'File changed during confirmation. No write performed.' }
            $backup = New-AgentUndoBackup -Path $path -Before $before
            $backupPath = $backup.FullName
            if ($script:OutputMode -ne 'json') {
                Write-Host ($script:Gm.Grey1 + 'Backup: ' + $backupPath + $script:Gm.Reset)
            }
            $script:CurrentTurnWrites += @{
                action = 'modified'
                root = $Root
                full_path = $path
                rel_path = $Arguments.path
                backup = $backupPath
                before_content = $before
                after_content = $after
            }
            $backupRecorded = $true
            Move-Item -LiteralPath $stageFile.FullName -Destination $path -Force -ErrorAction Stop
        }
        else {
            $existingAncestor = if ($dirsToCreate.Count -gt 0) { Split-Path -Path ([string]$dirsToCreate[0]) -Parent } else { $parent }
            if (-not $existingAncestor) { $existingAncestor = '.' }
            $existingBase = Resolve-AgentPath -Root $Root -RelativePath $existingAncestor
            if (-not (Get-Item -LiteralPath $existingBase -Force).PSIsContainer) { throw 'Parent must be a directory.' }
            $createdDirs = @()
            foreach ($dirPath in $dirsToCreate) {
                if (-not (Test-Path -LiteralPath $dirPath)) {
                    New-Item -ItemType Directory -Path $dirPath -ErrorAction Stop | Out-Null
                    $createdDirs = @($dirPath) + $createdDirs
                }
            }
            $parent = Resolve-AgentPath -Root $Root -RelativePath (Split-Path $Arguments.path -Parent)
            $path = Join-Path $parent $leaf
            if (Test-Path -LiteralPath $path) { throw 'File was created during confirmation. No write performed.' }
            $script:CurrentTurnWrites += @{
                action = 'created'
                root = $Root
                full_path = $path
                rel_path = $Arguments.path
                after_content = $after
                created_dirs = $createdDirs
            }
            Move-Item -LiteralPath $stageFile.FullName -Destination $path -Force -ErrorAction Stop
        }
        $writtenCheck = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $writtenCheck) { $writtenCheck = '' }
        if ($writtenCheck -cne $after) {
            if ($backupPath) {
                throw ('Written file verification failed (backup kept at ' + $backupPath + ').')
            }
            throw 'Written file verification failed.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageFile.FullName) {
            Remove-Item -LiteralPath $stageFile.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($backup -and (-not $backupRecorded) -and (Test-Path -LiteralPath $backup.FullName)) {
            Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return (@{ status = 'written'; path = $Arguments.path; backup = $backupPath; edits_applied = $editsApplied; first_changed_line = $firstChangedLine } | ConvertTo-Json -Compress)
}

function Invoke-AgentCreateOrOverwrite {
    param([string]$Root, $Arguments)
    $before = $null
    $editsApplied = 1
    $firstChangedLine = 1
    $writeTarget = Resolve-AgentWriteTarget -Root $Root -RelativePath $Arguments.path
    $path = [string]$writeTarget.full_path
    $leaf = [string]$writeTarget.leaf
    $parent = [string]$writeTarget.parent
    $dirsToCreate = @($writeTarget.dirs_to_create)
    if ($Arguments.content -isnot [string]) { throw 'content must be a string.' }
    $allowOverwrite = ($Arguments.overwrite -eq $true)
    if (Test-Path -LiteralPath $path) {
        if (-not $allowOverwrite) { throw 'File already exists. Use edit_file or set overwrite=true.' }
        $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
        $existingItem = Get-Item -LiteralPath $path -Force
        if ($existingItem.PSIsContainer -or $existingItem.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
        $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $before) { $before = '' }
    }
    $after = if ($null -ne $before) {
        ConvertTo-ExistingLineEndings -Content $Arguments.content -Original $before
    }
    else { $Arguments.content }
    return (Invoke-AgentStagedWrite -Root $Root -Name 'write_file' -Arguments $Arguments -before $before -after $after -editsApplied $editsApplied -firstChangedLine $firstChangedLine -parent $parent -leaf $leaf -dirsToCreate $dirsToCreate)
}

function Invoke-AgentEditFile {
    param([string]$Root, $Arguments)
    $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or $item.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
    $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $before) { $before = '' }
    $rawEdits = if ($null -ne $Arguments.edits) {
        @($Arguments.edits)
    }
    else {
        @(@{ old_text = $Arguments.old_text; new_text = $Arguments.new_text })
    }
    $resolvedEdits = @()
    foreach ($ed in $rawEdits) {
        if ($ed.old_text -isnot [string] -or -not $ed.old_text -or $ed.new_text -isnot [string]) { throw 'Each edit must have nonempty old_text and string new_text.' }
        $m = Find-EditMatch -Content $before -OldText $ed.old_text
        $repText = ConvertTo-ExistingLineEndings -Content $ed.new_text -Original $before
        $resolvedEdits += @{ index = $m.index; length = $m.length; matched_text = $m.matched_text; new_text = $repText }
    }
    for ($i = 0; $i -lt $resolvedEdits.Count; $i++) {
        for ($j = $i + 1; $j -lt $resolvedEdits.Count; $j++) {
            $a = $resolvedEdits[$i]
            $b = $resolvedEdits[$j]
            if ($a.index -lt ($b.index + $b.length) -and $b.index -lt ($a.index + $a.length)) {
                throw 'Batch edits overlap. Provide non-overlapping edit blocks.'
            }
        }
    }
    $sortedAsc = @($resolvedEdits | Sort-Object { $_.index })
    $minIdx = $sortedAsc[0].index
    $firstChangedLine = (@($before.Substring(0, $minIdx) -split "`n")).Count
    $editsApplied = $resolvedEdits.Count
    $after = $before
    foreach ($ed in @($resolvedEdits | Sort-Object { $_.index } -Descending)) {
        $after = $after.Substring(0, $ed.index) + $ed.new_text + $after.Substring($ed.index + $ed.length)
    }
    if ($after -ceq $before) { return (@{ status = 'unchanged' } | ConvertTo-Json -Compress) }
    return (Invoke-AgentStagedWrite -Root $Root -Name 'edit_file' -Arguments $Arguments -before $before -after $after -editsApplied $editsApplied -firstChangedLine $firstChangedLine)
}

function Invoke-AgentWrite {
    param([string]$Root, [string]$Name, $Arguments)
    if ($Name -eq 'write_file') {
        return (Invoke-AgentCreateOrOverwrite -Root $Root -Arguments $Arguments)
    }
    return (Invoke-AgentEditFile -Root $Root -Arguments $Arguments)
}
