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
        if ($Content.IndexOf($OldText, $idx + 1, [StringComparison]::Ordinal) -ge 0) {
            throw 'old_text occurs more than once. Provide more context.'
        }
        return @{ index = $idx; length = $OldText.Length; matched_text = $OldText }
    }
    if ($Content.Contains("`r`n")) {
        $crlfOld = $OldText.Replace("`r`n", "`n").Replace("`n", "`r`n")
        $idx = $Content.IndexOf($crlfOld, [StringComparison]::Ordinal)
        if ($idx -ge 0) {
            if ($Content.IndexOf($crlfOld, $idx + 1, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text occurs more than once. Provide more context.'
            }
            return @{ index = $idx; length = $crlfOld.Length; matched_text = $crlfOld }
        }
    }
    elseif ($OldText.Contains("`r`n")) {
        $lfOld = $OldText.Replace("`r`n", "`n")
        $idx = $Content.IndexOf($lfOld, [StringComparison]::Ordinal)
        if ($idx -ge 0) {
            if ($Content.IndexOf($lfOld, $idx + 1, [StringComparison]::Ordinal) -ge 0) {
                throw 'old_text occurs more than once. Provide more context.'
            }
            return @{ index = $idx; length = $lfOld.Length; matched_text = $lfOld }
        }
    }
    $contentLines = @($Content -split "`n")
    $oldClean = $OldText.Replace("`r`n", "`n").TrimEnd("`r")
    $includeTrailingNewline = $oldClean.EndsWith("`n")
    if ($includeTrailingNewline) {
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
        # A trailing newline requires a following split element, even if it is empty at EOF.
        if ($includeTrailingNewline) { $maxStart-- }
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
            $charEnd = if ($includeTrailingNewline) {
                $lineStarts[$endLineIdx + 1]
            }
            else {
                $endLineRaw = $contentLines[$endLineIdx]
                $endLineCleanLen = if ($endLineRaw.EndsWith("`r")) { $endLineRaw.Length - 1 } else { $endLineRaw.Length }
                $lineStarts[$endLineIdx] + $endLineCleanLen
            }
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

function Get-AgentEditableEncoding {
    param([string]$Path)
    $header = if ($PSVersionTable.PSVersion.Major -lt 6) {
        Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 4 -ErrorAction Stop
    }
    else {
        Get-Content -LiteralPath $Path -AsByteStream -TotalCount 4 -ErrorAction Stop
    }
    switch -Regex ($header -join ' ') {
        '^(255 254 0 0|0 0 254 255)$' { throw 'Unsupported file encoding. UTF-32 is not supported.' }
        '^239 187 191( |$)' { return 'utf8BOM' }
        '^255 254( |$)' { return 'Unicode' }
        '^254 255( |$)' { return 'BigEndianUnicode' }
        default { return 'utf8NoBOM' }
    }
}

function Set-AgentEditableContent {
    param([string]$Path, [AllowEmptyString()][string]$Text, [string]$Encoding)
    if ($Encoding -eq 'utf8NoBOM') {
        Set-AgentUtf8Content -LiteralPath $Path -Value $Text
        return
    }
    if ($Encoding -eq 'utf8BOM' -and $PSVersionTable.PSVersion.Major -lt 6) {
        $Encoding = 'UTF8'
    }
    Set-Content -LiteralPath $Path -Value $Text -Encoding $Encoding -NoNewline -ErrorAction Stop
}

function Read-AgentEditableFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
    $snapshot = New-AgentTempFile
    try {
        Copy-Item -LiteralPath $Path -Destination $snapshot.FullName -Force -ErrorAction Stop
        $encoding = Get-AgentEditableEncoding -Path $snapshot.FullName
        $hash = Read-AgentUndoContent -Path $snapshot.FullName -Hash
        $text = Read-AgentUndoContent -Path $snapshot.FullName
        if ($text -match '\x00') { throw 'Binary content is not supported.' }
        # Re-encoding a single snapshot detects any lossy decoding, including replacement characters.
        Set-AgentEditableContent -Path $snapshot.FullName -Text $text -Encoding $encoding
        if ((Read-AgentUndoContent -Path $snapshot.FullName -Hash) -cne $hash) {
            throw 'Invalid or unsupported file encoding. Expected UTF-8 or BOM-marked UTF-16.'
        }
        return @{ text = $text; encoding = $encoding; hash = $hash }
    }
    finally {
        Remove-Item -LiteralPath $snapshot.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AgentStagedWrite {
    param(
        [string]$Root,
        [string]$Name,
        $Arguments,
        $originalFile,
        [string]$after,
        [int]$editsApplied,
        [int]$firstChangedLine,
        [string]$parent,
        [string]$leaf,
        [string[]]$dirsToCreate
    )
    $before = $originalFile.text
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
        $encoding = if ($originalFile) { $originalFile.encoding }
        elseif ($Arguments.path -like '*.ps1' -and $after -match '[^\x00-\x7F]') { 'utf8BOM' }
        else { 'utf8NoBOM' }
        Set-AgentEditableContent -Path $stageFile.FullName -Text $after -Encoding $encoding
        $stagedCheck = Read-AgentUndoContent -Path $stageFile.FullName
        if (-not $after.Equals($stagedCheck, [StringComparison]::Ordinal) -or
            (Get-AgentEditableEncoding -Path $stageFile.FullName) -ne $encoding) {
            throw 'Staged file verification failed. No write performed.'
        }
        $afterHash = Read-AgentUndoContent -Path $stageFile.FullName -Hash
        if ($null -ne $before) {
            $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
            if ((Read-AgentUndoContent -Path $path -Hash) -cne $originalFile.hash) {
                throw 'File changed during confirmation. No write performed.'
            }
            $backup = New-AgentUndoBackup -Path $path -Before $before -BeforeHash $originalFile.hash
            $backupPath = $backup.FullName
            $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
            if ((Read-AgentUndoContent -Path $path -Hash) -cne $originalFile.hash) {
                throw 'File changed before replacement. No write performed.'
            }
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
                before_hash = $originalFile.hash
                after_hash = $afterHash
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
                after_hash = $afterHash
                created_dirs = $createdDirs
            }
            Move-Item -LiteralPath $stageFile.FullName -Destination $path -Force -ErrorAction Stop
        }
        if ((Read-AgentUndoContent -Path $path -Hash) -cne $afterHash) {
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
    $originalFile = $null
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
        $originalFile = Read-AgentEditableFile -Path $path
    }
    $after = if ($originalFile) {
        ConvertTo-ExistingLineEndings -Content $Arguments.content -Original $originalFile.text
    }
    else { $Arguments.content }
    return (Invoke-AgentStagedWrite -Root $Root -Name 'write_file' -Arguments $Arguments -OriginalFile $originalFile -after $after -editsApplied $editsApplied -firstChangedLine $firstChangedLine -parent $parent -leaf $leaf -dirsToCreate $dirsToCreate)
}

function Invoke-AgentEditFile {
    param([string]$Root, $Arguments)
    $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
    $originalFile = Read-AgentEditableFile -Path $path
    $before = $originalFile.text
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
    return (Invoke-AgentStagedWrite -Root $Root -Name 'edit_file' -Arguments $Arguments -OriginalFile $originalFile -after $after -editsApplied $editsApplied -firstChangedLine $firstChangedLine)
}

function Invoke-AgentWrite {
    param([string]$Root, [string]$Name, $Arguments)
    if ($Name -eq 'write_file') {
        return (Invoke-AgentCreateOrOverwrite -Root $Root -Arguments $Arguments)
    }
    return (Invoke-AgentEditFile -Root $Root -Arguments $Arguments)
}
