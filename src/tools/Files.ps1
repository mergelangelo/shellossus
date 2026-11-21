# Fuzzy text matching, diff preview helpers, and transactional file writes (write_file, edit_file, delete_file, move_file).

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
        if ((Get-Item -LiteralPath $snapshot.FullName -ErrorAction Stop).Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
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
                Write-Host ($script:Gm.Grey1 + 'Backup: ' + (Format-TuiText $backupPath) + $script:Gm.Reset)
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
        Clear-WorkspaceWalkCache
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
    if ($rawEdits.Count -gt $script:AgentMaxBatchEdits) {
        throw "edits[] may contain at most $($script:AgentMaxBatchEdits) operations."
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

function Request-AgentFileOpConfirmation {
    param([string]$ToolName, [string]$SummaryLine)
    if ($script:OutputMode -ne 'json') {
        Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.BoldYellow + $script:Box.Arrow + " $(Format-TuiText $ToolName) " + $script:Gm.Fg1 + (Format-TuiText $SummaryLine) + $script:Gm.Reset)
    }
    if ($script:AgentPermission -in @('AutoEdit', 'Auto')) {
        if ($script:OutputMode -ne 'json') {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [auto-approved by ' + $script:AgentPermission + ' mode]' + $script:Gm.Reset)
        }
        return @{ approved = $true; response = $null }
    }
    if ($script:OutputMode -eq 'json') {
        return @{
            approved = $false
            response = (@{
                status = 'cancelled'
                message = 'Interactive confirmation is disabled in JSON mode. Use -Permission AutoEdit or Auto to allow file modifications.'
            } | ConvertTo-Json -Compress)
        }
    }
    $promptStr = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.BoldYellow + 'Confirm [y]es, [n]o, [a]ll edits: ' + $script:Gm.Fg
    $choice = Read-TuiConfirmation -PromptText $promptStr -ActionType 'write'
    if ($choice -eq 'a') {
        $script:AgentPermission = 'AutoEdit'
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [switched permission to AutoEdit for this session]' + $script:Gm.Reset)
        return @{ approved = $true; response = $null }
    }
    if ($choice -eq 'y') {
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Green + $script:Box.Check + ' confirmed' + $script:Gm.Reset)
        return @{ approved = $true; response = $null }
    }
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
    return @{
        approved = $false
        response = (@{
            status = 'cancelled'
            message = 'User declined. Do not retry without a new user request.'
        } | ConvertTo-Json -Compress)
    }
}

function Get-SameFilesystemEntryInfo {
    param([string]$PathA, [string]$PathB)
    if ($PathA -ceq $PathB) {
        return @{ is_same = $true; differs_from_disk_case = $false }
    }
    if ($PathA -ine $PathB) {
        return @{ is_same = $false; differs_from_disk_case = $false }
    }
    $itemB = Get-Item -LiteralPath $PathB -Force -ErrorAction SilentlyContinue
    if ($null -eq $itemB) {
        return @{ is_same = $false; differs_from_disk_case = $false }
    }
    $normA = $PathA.Replace('\', '/').TrimEnd('/')
    $normB = $PathB.Replace('\', '/').TrimEnd('/')
    $partsA = @($normA -split '/')
    $partsB = @($normB -split '/')
    if ($partsA.Count -ne $partsB.Count) {
        $isCiOs = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS)
        return @{ is_same = $isCiOs; differs_from_disk_case = $isCiOs }
    }
    $differsFromDisk = $false
    $anyChecked = $false
    for ($i = 0; $i -lt $partsA.Count; $i++) {
        if ($partsA[$i] -ceq $partsB[$i]) { continue }
        if ($i -eq 0 -and $partsA[$i] -match '^[a-zA-Z]:$') { continue }
        $parentParts = if ($i -gt 0) { @($partsA[0..($i - 1)]) } else { @() }
        $parentPath = ($parentParts -join '/')
        if (-not $parentPath) { $parentPath = '/' }
        elseif ($parentPath -match '^[a-zA-Z]:$') { $parentPath += '/' }
        $dirMatches = @(Get-ChildItem -LiteralPath $parentPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $partsA[$i] })
        if ($dirMatches.Count -gt 1) {
            return @{ is_same = $false; differs_from_disk_case = $false }
        }
        if ($dirMatches.Count -eq 1) {
            $anyChecked = $true
            if ($dirMatches[0].Name -cne $partsB[$i]) {
                $differsFromDisk = $true
            }
        }
    }
    if ($anyChecked) {
        return @{ is_same = $true; differs_from_disk_case = $differsFromDisk }
    }
    $isCiFallback = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS)
    return @{ is_same = $isCiFallback; differs_from_disk_case = $isCiFallback }
}

function Invoke-AgentDeleteFile {
    param([string]$Root, $Arguments)
    $toolStart = Get-Date
    $relPath = [string]$Arguments.path
    $path = Resolve-AgentPath -Root $Root -RelativePath $relPath
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'delete_file only supports files, not directories.' }
    if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB limit for safe undoable deletion.' }
    $beforeHash = Read-AgentUndoContent -Path $path -Hash
    $conf = Request-AgentFileOpConfirmation -ToolName 'delete_file' -SummaryLine ("$relPath ($($item.Length) bytes)")
    if (-not $conf.approved) { return $conf.response }
    $backup = $null
    $backupRecorded = $false
    try {
        $path = Resolve-AgentPath -Root $Root -RelativePath $relPath
        $itemNow = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($itemNow.PSIsContainer) { throw 'delete_file only supports files, not directories.' }
        if ((Read-AgentUndoContent -Path $path -Hash) -cne $beforeHash) {
            throw 'File changed during confirmation. No deletion performed.'
        }
        $backup = New-AgentUndoBackup -Path $path -Before '' -BeforeHash $beforeHash
        $path = Resolve-AgentPath -Root $Root -RelativePath $relPath
        if ((Read-AgentUndoContent -Path $path -Hash) -cne $beforeHash) {
            throw 'File changed before deletion. No deletion performed.'
        }
        if ($script:OutputMode -ne 'json') {
            Write-Host ($script:Gm.Grey1 + 'Backup: ' + (Format-TuiText $backup.FullName) + $script:Gm.Reset)
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        $script:CurrentTurnWrites += @{
            action = 'deleted'
            root = $Root
            full_path = $path
            rel_path = $relPath
            backup = $backup.FullName
            before_content = ''
            after_content = $null
            before_hash = $beforeHash
            after_hash = $null
        }
        $backupRecorded = $true
        if ($null -ne (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
            throw ('File deletion verification failed (backup kept at ' + $backup.FullName + ').')
        }
    }
    finally {
        Clear-WorkspaceWalkCache
        if ($backup -and (-not $backupRecorded) -and (Test-Path -LiteralPath $backup.FullName)) {
            Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
    Write-ToolCallCard -Name 'delete_file' -Target $relPath -Status 'ok' -Summary 'deleted' -ElapsedMs $elapsedMs
    return (@{ status = 'deleted'; path = $relPath; backup = $backup.FullName } | ConvertTo-Json -Compress)
}

function Invoke-AgentMoveFile {
    param([string]$Root, $Arguments)
    $toolStart = Get-Date
    $srcRel = [string]$Arguments.source
    $dstRel = [string]$Arguments.destination
    $allowOverwrite = ($Arguments.overwrite -eq $true)
    $srcPath = Resolve-AgentPath -Root $Root -RelativePath $srcRel
    $srcItem = Get-Item -LiteralPath $srcPath -Force -ErrorAction Stop
    if ($srcItem.PSIsContainer) { throw 'move_file only supports files, not directories.' }
    if ($srcItem.Length -gt 1MB) { throw 'Source file exceeds 1 MiB limit for safe undoable move.' }

    $dstTarget = Resolve-AgentWriteTarget -Root $Root -RelativePath $dstRel
    $dstPath = [string]$dstTarget.full_path
    $dstLeaf = [string]$dstTarget.leaf
    $dstParent = [string]$dstTarget.parent
    $dstDirsToCreate = @($dstTarget.dirs_to_create)

    $sameInfo = Get-SameFilesystemEntryInfo -PathA $srcPath -PathB $dstPath
    if ($sameInfo.is_same) {
        if ($sameInfo.differs_from_disk_case) {
            throw 'Case-only rename on a case-insensitive filesystem requires a two-step move via a temporary name.'
        }
        return (@{ status = 'unchanged'; source = $srcRel; destination = $dstRel } | ConvertTo-Json -Compress)
    }

    $dstExisted = $false
    $dstBeforeHash = $null
    if ($null -ne (Get-Item -LiteralPath $dstPath -Force -ErrorAction SilentlyContinue)) {
        if (-not $allowOverwrite) {
            throw 'Destination file already exists. Set overwrite=true to replace it.'
        }
        $dstPath = Resolve-AgentPath -Root $Root -RelativePath $dstRel
        $dstItem = Get-Item -LiteralPath $dstPath -Force -ErrorAction Stop
        if ($dstItem.PSIsContainer) { throw 'Destination must be a file, not a directory.' }
        if ($dstItem.Length -gt 1MB) { throw 'Destination file exceeds 1 MiB limit for safe undoable overwrite.' }
        $dstExisted = $true
        $dstBeforeHash = Read-AgentUndoContent -Path $dstPath -Hash
    }
    $srcBeforeHash = Read-AgentUndoContent -Path $srcPath -Hash

    $summaryLine = "$srcRel -> $dstRel" + $(if ($dstExisted) { ' [overwrite]' } else { '' })
    $conf = Request-AgentFileOpConfirmation -ToolName 'move_file' -SummaryLine $summaryLine
    if (-not $conf.approved) { return $conf.response }

    $stageFile = New-AgentTempFile
    $srcBackup = $null
    $dstBackup = $null
    $srcBackupRecorded = $false
    $dstBackupRecorded = $false
    $createdDirs = @()
    $dstCommitted = $false
    try {
        $srcPath = Resolve-AgentPath -Root $Root -RelativePath $srcRel
        $srcItemNow = Get-Item -LiteralPath $srcPath -Force -ErrorAction Stop
        if ($srcItemNow.PSIsContainer) { throw 'move_file only supports files, not directories.' }
        if ((Read-AgentUndoContent -Path $srcPath -Hash) -cne $srcBeforeHash) {
            throw 'Source file changed during confirmation. No move performed.'
        }
        if ($dstExisted) {
            $dstPath = Resolve-AgentPath -Root $Root -RelativePath $dstRel
            $dstItemNow = Get-Item -LiteralPath $dstPath -Force -ErrorAction Stop
            if ($dstItemNow.PSIsContainer) { throw 'Destination must be a file, not a directory.' }
            if ((Read-AgentUndoContent -Path $dstPath -Hash) -cne $dstBeforeHash) {
                throw 'Destination file changed during confirmation. No move performed.'
            }
            $dstBackup = New-AgentUndoBackup -Path $dstPath -Before '' -BeforeHash $dstBeforeHash
        }
        $srcBackup = New-AgentUndoBackup -Path $srcPath -Before '' -BeforeHash $srcBeforeHash
        Copy-Item -LiteralPath $srcPath -Destination $stageFile.FullName -Force -ErrorAction Stop
        if ((Read-AgentUndoContent -Path $stageFile.FullName -Hash) -cne $srcBeforeHash) {
            throw 'Staged move verification failed. No move performed.'
        }
        if ((Read-AgentUndoContent -Path $srcPath -Hash) -cne $srcBeforeHash) {
            throw 'Source file changed before move. No move performed.'
        }

        if ($dstExisted) {
            $dstPath = Resolve-AgentPath -Root $Root -RelativePath $dstRel
            if ((Read-AgentUndoContent -Path $dstPath -Hash) -cne $dstBeforeHash) {
                throw 'Destination file changed before move. No move performed.'
            }
            Move-Item -LiteralPath $stageFile.FullName -Destination $dstPath -Force -ErrorAction Stop
            $dstCommitted = $true
            $script:CurrentTurnWrites += @{
                action = 'modified'
                root = $Root
                full_path = $dstPath
                rel_path = $dstRel
                backup = $dstBackup.FullName
                before_content = ''
                after_content = ''
                before_hash = $dstBeforeHash
                after_hash = $srcBeforeHash
            }
            $dstBackupRecorded = $true
        }
        else {
            $existingAncestor = if ($dstDirsToCreate.Count -gt 0) { Split-Path -Path ([string]$dstDirsToCreate[0]) -Parent } else { $dstParent }
            if (-not $existingAncestor) { $existingAncestor = '.' }
            $existingBase = Resolve-AgentPath -Root $Root -RelativePath $existingAncestor
            if (-not (Get-Item -LiteralPath $existingBase -Force).PSIsContainer) { throw 'Parent must be a directory.' }
            foreach ($dirPath in $dstDirsToCreate) {
                if (-not (Test-Path -LiteralPath $dirPath)) {
                    New-Item -ItemType Directory -Path $dirPath -ErrorAction Stop | Out-Null
                    $createdDirs = @($dirPath) + $createdDirs
                }
            }
            $rawDstParent = Split-Path -Path $dstRel -Parent
            $dstParentRel = if ($rawDstParent) { $rawDstParent } else { '.' }
            $dstParentResolved = Resolve-AgentPath -Root $Root -RelativePath $dstParentRel
            $dstPath = Join-Path $dstParentResolved $dstLeaf
            if ($null -ne (Get-Item -LiteralPath $dstPath -Force -ErrorAction SilentlyContinue)) {
                throw 'Destination file was created during confirmation. No move performed.'
            }
            Move-Item -LiteralPath $stageFile.FullName -Destination $dstPath -Force -ErrorAction Stop
            $dstCommitted = $true
            $script:CurrentTurnWrites += @{
                action = 'created'
                root = $Root
                full_path = $dstPath
                rel_path = $dstRel
                after_content = ''
                after_hash = $srcBeforeHash
                created_dirs = $createdDirs
            }
        }
        if ((Read-AgentUndoContent -Path $dstPath -Hash) -cne $srcBeforeHash) {
            $srcBackupRecorded = $true
            throw ('Moved file verification failed (backup kept at ' + $srcBackup.FullName + ').')
        }

        Remove-Item -LiteralPath $srcPath -Force -ErrorAction Stop
        $script:CurrentTurnWrites += @{
            action = 'deleted'
            root = $Root
            full_path = $srcPath
            rel_path = $srcRel
            backup = $srcBackup.FullName
            before_content = ''
            after_content = $null
            before_hash = $srcBeforeHash
            after_hash = $null
        }
        $srcBackupRecorded = $true
        if ($null -ne (Get-Item -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue)) {
            throw ('Source cleanup failed after move (backup kept at ' + $srcBackup.FullName + ').')
        }
    }
    finally {
        Clear-WorkspaceWalkCache
        if ((-not $dstCommitted) -and $createdDirs.Count -gt 0) {
            foreach ($cd in $createdDirs) {
                if ($cd -and (Test-Path -LiteralPath $cd)) {
                    try {
                        $remaining = @(Get-ChildItem -LiteralPath $cd -Force -ErrorAction SilentlyContinue)
                        if ($remaining.Count -eq 0) {
                            Remove-Item -LiteralPath $cd -Force -ErrorAction SilentlyContinue
                        }
                    } catch {}
                }
            }
        }
        if (Test-Path -LiteralPath $stageFile.FullName) {
            Remove-Item -LiteralPath $stageFile.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($srcBackup -and (-not $srcBackupRecorded) -and (Test-Path -LiteralPath $srcBackup.FullName)) {
            Remove-Item -LiteralPath $srcBackup.FullName -Force -ErrorAction SilentlyContinue
        }
        if ($dstBackup -and (-not $dstBackupRecorded) -and (Test-Path -LiteralPath $dstBackup.FullName)) {
            Remove-Item -LiteralPath $dstBackup.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
    Write-ToolCallCard -Name 'move_file' -Target "$srcRel -> $dstRel" -Status 'ok' -Summary 'moved' -ElapsedMs $elapsedMs
    return (@{
        status = 'moved'
        source = $srcRel
        destination = $dstRel
        overwritten = $dstExisted
        backup = $srcBackup.FullName
        destination_backup = $(if ($dstBackup) { $dstBackup.FullName } else { $null })
    } | ConvertTo-Json -Compress)
}
