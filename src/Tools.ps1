# Agent tools, permission modes, fuzzy/batch file edits, shell runner, and disk undo.

$script:CurrentTurnWrites = @()
$script:AgentPermission = 'Ask'
$script:ShowReasoning = 'compact'
$script:ReasoningEffort = ''

function Get-AgentTools {
    foreach ($name in @('list_files', 'read_file')) {
        $description = 'List up to 200 entries in a directory. Names only; no file contents.'
        $properties = @{ path = @{ type = 'string'; description = 'Workspace-relative path; . means the root.' } }
        if ($name -eq 'read_file') {
            $description = 'Read a UTF-8 text file: up to 300 lines and 20000 characters, maximum file size 1 MiB. Returns total_lines and pagination metadata.'
            $properties.start_line = @{ type = 'integer'; description = 'Optional 1-based first line to read (default 1).' }
            $properties.max_lines = @{ type = 'integer'; description = 'Optional maximum number of lines to read (1..300, default 300).' }
        }
        @{
            type = 'function'
            function = @{
                name = $name
                description = $description
                parameters = @{
                    type = 'object'
                    properties = $properties
                    required = @('path')
                }
            }
        }
    }
    @{
        type = 'function'
        function = @{
            name = 'find_files'
            description = 'Find files or directories recursively by wildcard pattern (e.g. *.sql, *report*), up to 200 matches.'
            parameters = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'Workspace-relative directory path; . means the root.' }
                    pattern = @{ type = 'string'; description = 'File name wildcard pattern, e.g. *.sql or *.' }
                }
                required = @('path', 'pattern')
            }
        }
    }
    @{
        type = 'function'
        function = @{
            name = 'grep_files'
            description = 'Search UTF-8 text files for a regex or literal pattern, returning matching paths, line numbers, and lines (up to 100 matches).'
            parameters = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'Workspace-relative file or directory path; . means the root.' }
                    pattern = @{ type = 'string'; description = 'Regex or literal search pattern.' }
                    literal = @{ type = 'boolean'; description = 'Set true for literal substring match instead of regex.' }
                    case_sensitive = @{ type = 'boolean'; description = 'Set true for case-sensitive matching.' }
                    include = @{ type = 'string'; description = 'Optional file name wildcard filter, e.g. *.sql or *.ps1.' }
                    context_lines = @{ type = 'integer'; description = 'Optional surrounding context lines (0..5).' }
                }
                required = @('path', 'pattern')
            }
        }
    }
    if ($script:AgentPermission -eq 'ReadOnly') { return }
    foreach ($name in @('write_file', 'edit_file')) {
        $properties = @{ path = @{ type = 'string'; description = 'Workspace-relative text file path. Parent directory must exist.' } }
        if ($name -eq 'write_file') {
            $description = 'Create a UTF-8 text file (or overwrite when overwrite=true).'
            $properties.content = @{ type = 'string'; description = 'Complete file contents, at most 20000 characters.' }
            $properties.overwrite = @{ type = 'boolean'; description = 'Set true to overwrite an existing file (saves a backup).' }
            $required = @('path', 'content')
        }
        else {
            $description = 'Replace one or more unique blocks in a UTF-8 text file (supports single old_text/new_text or batch edits[] array; saves a backup).'
            $properties.old_text = @{ type = 'string'; description = 'Single edit: nonempty text occurring once in the file.' }
            $properties.new_text = @{ type = 'string'; description = 'Single edit: replacement text.' }
            $properties.edits = @{
                type = 'array'
                description = 'Optional batch of non-overlapping edits: array of {old_text, new_text} objects.'
                items = @{
                    type = 'object'
                    properties = @{
                        old_text = @{ type = 'string' }
                        new_text = @{ type = 'string' }
                    }
                    required = @('old_text', 'new_text')
                }
            }
            $required = @('path')
        }
        @{ type = 'function'; function = @{ name = $name; description = $description; parameters = @{ type = 'object'; properties = $properties; required = $required } } }
    }
    @{
        type = 'function'
        function = @{
            name = 'run_command'
            description = 'Execute a PowerShell command in the workspace directory.'
            parameters = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                }
                required = @('command')
            }
        }
    }
}

function Invoke-ShellCommand {
    param([string]$Root, [string]$Command)
    if (-not $Command -or -not $Command.Trim()) { throw 'Command must not be empty.' }
    $savedHKey = $env:H_AGENT_API_KEY
    $savedOKey = $env:OPENAI_API_KEY
    Push-Location -LiteralPath $Root -ErrorAction Stop
    try {
        $env:H_AGENT_API_KEY = $null
        $env:OPENAI_API_KEY = $null
        $rawOut = @(& powershell -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    }
    finally {
        $env:H_AGENT_API_KEY = $savedHKey
        $env:OPENAI_API_KEY = $savedOKey
        Pop-Location -ErrorAction SilentlyContinue
    }
    $text = ($rawOut | Select-Object -First 300) -join "`n"
    $truncated = $rawOut.Count -gt 300
    if ($text.Length -gt 20000) { $text = $text.Substring(0, 20000); $truncated = $true }
    $fullLogRel = $null
    if ($truncated) {
        try {
            $outDir = Join-Path (Get-Item -LiteralPath $Root -Force).FullName '.h-agent\output'
            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop | Out-Null }
            $logName = 'cmd-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999) + '.log'
            $logFull = Join-Path $outDir $logName
            Set-Content -LiteralPath $logFull -Value ($rawOut -join "`r`n") -Encoding UTF8 -ErrorAction Stop
            $fullLogRel = Get-WorkspaceRelativePath -Root $Root -FullPath $logFull
        }
        catch {}
    }
    return @{ exit_code = $exitCode; output = $text; truncated = $truncated; full_output_path = $fullLogRel }
}

function Invoke-AgentCommand {
    param([string]$Root, $Arguments)
    if ($Arguments.command -isnot [string] -or -not $Arguments.command.Trim()) { throw 'command must be a nonempty string.' }
    $cmdText = $Arguments.command
    if ($cmdText.Length -gt 8000) { throw 'Command is too long.' }
    Write-Host ("`n" + $script:Gm.BoldYellow + 'PROPOSED run_command (in ' + $Root + '):' + $script:Gm.Reset)
    Write-Host ($script:Gm.Bg1 + $script:Gm.Yellow + '  ' + (Format-PreviewText $cmdText) + '  ' + $script:Gm.Reset)
    if ($script:AgentPermission -eq 'Auto') {
        Write-Host ($script:Gm.Aqua + '  [auto-approved by Auto mode]' + $script:Gm.Reset)
    }
    else {
        Write-Host ($script:Gm.BoldYellow + 'Confirm: ' + $script:Gm.Fg) -NoNewline
        $approval = Read-Host 'Type RUN to execute this command; Enter cancels'
        Write-Host $script:Gm.Reset -NoNewline
        if ($approval -cne 'RUN') {
            return (@{ status = 'cancelled'; message = 'User declined command execution. Do not retry without a new user request.' } | ConvertTo-Json -Compress)
        }
    }
    $res = Invoke-ShellCommand -Root $Root -Command $cmdText
    if ($res.output) {
        $previewLines = @($res.output -split "`r?`n" | Select-Object -First 15)
        foreach ($pLine in $previewLines) {
            Write-Host ($script:Gm.Grey1 + '    ' + (Format-PreviewText $pLine) + $script:Gm.Reset)
        }
        if (($res.output -split "`r?`n").Count -gt 15) {
            Write-Host ($script:Gm.Grey0 + '    ... (output truncated in terminal preview)' + $script:Gm.Reset)
        }
    }
    return (@{
        status = 'executed'
        exit_code = $res.exit_code
        output = $res.output
        truncated = $res.truncated
        full_output_path = $res.full_output_path
    } | ConvertTo-Json -Compress)
}

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
    $contentLines = @($Content -split "`n")
    $oldLines = @($OldText -split "`r?`n")
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

function Invoke-AgentWrite {
    param([string]$Root, [string]$Name, $Arguments)
    $before = $null
    $prefixText = ''
    $suffixText = ''
    $editsApplied = 1
    $firstChangedLine = 1
    if ($Name -eq 'write_file') {
        if ($Arguments.path -match '[/\\]$') { throw 'Invalid file name.' }
        $parent = Resolve-AgentPath -Root $Root -RelativePath (Split-Path $Arguments.path -Parent)
        if (-not (Get-Item -LiteralPath $parent -Force).PSIsContainer) { throw 'Parent must be a directory.' }
        $leaf = Split-Path $Arguments.path -Leaf
        if (-not $leaf -or $leaf -match '[<>:"/\\|?*\x00-\x1f]' -or $leaf -match '[. ]$') { throw 'Invalid file name.' }
        if ($leaf -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Reserved file name.' }
        $path = Join-Path $parent $leaf
        if ($leaf -eq '.env' -or ($leaf -like '.env.*' -and $leaf -ne '.env.example') -or $path -eq $script:AgentConfigPath) { throw 'Agent tools cannot write credential configuration files.' }
        if ($Arguments.content -isnot [string]) { throw 'content must be a string.' }
        $allowOverwrite = [bool]$Arguments.overwrite
        if (Test-Path -LiteralPath $path) {
            if (-not $allowOverwrite) { throw 'File already exists. Use edit_file or set overwrite=true.' }
            $existingItem = Get-Item -LiteralPath $path -Force
            if ($existingItem.PSIsContainer -or $existingItem.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
            $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -eq $before) { $before = '' }
            $oldText = $before
            $newText = $Arguments.content
        }
        $after = $Arguments.content
    }
    else {
        $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or $item.Length -gt 1MB) { throw 'Expected a text file up to 1 MiB.' }
        $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $before) { $before = '' }
        $rawEdits = @()
        if ($null -ne $Arguments.edits) {
            $rawEdits = @($Arguments.edits)
            if ($rawEdits.Count -eq 0) { throw 'edits array must not be empty.' }
        }
        else {
            if ($Arguments.old_text -isnot [string] -or -not $Arguments.old_text -or $Arguments.new_text -isnot [string]) { throw 'Expected nonempty old_text and string new_text.' }
            $rawEdits = @(@{ old_text = $Arguments.old_text; new_text = $Arguments.new_text })
        }
        $resolvedEdits = @()
        foreach ($ed in $rawEdits) {
            if ($ed.old_text -isnot [string] -or -not $ed.old_text -or $ed.new_text -isnot [string]) { throw 'Each edit must have nonempty old_text and string new_text.' }
            $m = Find-EditMatch -Content $before -OldText $ed.old_text
            $repText = $ed.new_text
            if ($before.Contains("`r`n")) { $repText = $repText.Replace("`r`n", "`n").Replace("`n", "`r`n") }
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
        if ($resolvedEdits.Count -eq 1) {
            $only = $resolvedEdits[0]
            $prefixText = $before.Substring(0, $only.index)
            $oldText = $only.matched_text
            $newText = $only.new_text
            $suffixText = $before.Substring($only.index + $only.length)
        }
        else {
            $prefixText = ''
            $oldText = $before
            $newText = $after
            $suffixText = ''
        }
    }
    if ($after.Length -gt 20000 -or ($null -ne $before -and $before.Length -gt 20000)) { throw 'Write preview is limited to 20000 characters.' }
    if ($after -match '\x00' -or ($null -ne $before -and $before -match '\x00')) { throw 'Binary content is not supported.' }
    Write-Host ("`n" + $script:Gm.BoldYellow + 'PROPOSED ' + $Name + ': ' + $path + $script:Gm.Reset)
    if ($null -ne $before) {
        Write-Host ($script:Gm.BoldRed + '--- BEFORE ---' + $script:Gm.Reset)
        Write-Host ($script:Gm.Grey0 + (Format-PreviewText $prefixText) + $script:Gm.Reset) -NoNewline
        Write-Host ($script:Gm.BgDiffRed + $script:Gm.Red + (Format-PreviewText $oldText) + $script:Gm.Reset) -NoNewline
        Write-Host ($script:Gm.Grey0 + (Format-PreviewText $suffixText) + $script:Gm.Reset)
        Write-Host ($script:Gm.BoldGreen + '--- AFTER ---' + $script:Gm.Reset)
        Write-Host ($script:Gm.Grey0 + (Format-PreviewText $prefixText) + $script:Gm.Reset) -NoNewline
        Write-Host ($script:Gm.BgDiffGreen + $script:Gm.Green + (Format-PreviewText $newText) + $script:Gm.Reset) -NoNewline
        Write-Host ($script:Gm.Grey0 + (Format-PreviewText $suffixText) + $script:Gm.Reset)
    }
    else {
        Write-Host ($script:Gm.BoldGreen + '--- AFTER ---' + $script:Gm.Reset)
        Write-Host ($script:Gm.BgDiffGreen + $script:Gm.Green + (Format-PreviewText $after) + $script:Gm.Reset)
    }
    Write-Host ($script:Gm.Grey0 + '--- END OF PREVIEW ---' + $script:Gm.Reset)
    if ($script:AgentPermission -in @('AutoEdit', 'Auto')) {
        Write-Host ($script:Gm.Aqua + '  [auto-approved by ' + $script:AgentPermission + ' mode]' + $script:Gm.Reset)
    }
    else {
        Write-Host ($script:Gm.BoldYellow + 'Confirm: ' + $script:Gm.Fg) -NoNewline
        $approval = Read-Host 'Type WRITE to approve this file change; Enter cancels'
        Write-Host $script:Gm.Reset -NoNewline
        if ($approval -cne 'WRITE') { return (@{ status = 'cancelled'; message = 'User declined. Do not retry without a new user request.' } | ConvertTo-Json -Compress) }
    }
    $backupPath = $null
    if ($null -ne $before) {
        $path = Resolve-AgentPath -Root $Root -RelativePath $Arguments.path
        $current = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $current) { $current = '' }
        if ($current -cne $before) { throw 'File changed during confirmation. No write performed.' }
        $backup = New-TemporaryFile -ErrorAction Stop
        Copy-Item -LiteralPath $path -Destination $backup.FullName -Force -ErrorAction Stop
        $backupPath = $backup.FullName
        Write-Host ($script:Gm.Grey1 + 'Backup: ' + $backupPath + $script:Gm.Reset)
    }
    else {
        $parent = Resolve-AgentPath -Root $Root -RelativePath (Split-Path $Arguments.path -Parent)
        $path = Join-Path $parent $leaf
        New-Item -ItemType File -Path $path -ErrorAction Stop | Out-Null
    }
    Set-Content -LiteralPath $path -Value $after -Encoding UTF8 -NoNewline -ErrorAction Stop
    if ($null -ne $before) {
        $script:CurrentTurnWrites += @{ action = 'modified'; full_path = $path; rel_path = $Arguments.path; backup = $backupPath }
    }
    else {
        $script:CurrentTurnWrites += @{ action = 'created'; full_path = $path; rel_path = $Arguments.path }
    }
    return (@{ status = 'written'; path = $Arguments.path; backup = $backupPath; edits_applied = $editsApplied; first_changed_line = $firstChangedLine } | ConvertTo-Json -Compress)
}

function Invoke-AgentUndo {
    param($State, $UndoEntry)
    if (-not $UndoEntry) { return }
    $State.messages = @($UndoEntry.messages)
    $writes = @($UndoEntry.writes)
    for ($i = $writes.Count - 1; $i -ge 0; $i--) {
        $w = $writes[$i]
        if ($w.action -eq 'modified' -and $w.backup -and (Test-Path -LiteralPath $w.backup)) {
            Copy-Item -LiteralPath $w.backup -Destination $w.full_path -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $w.backup -Force -ErrorAction SilentlyContinue
            Write-Host ($script:Gm.Aqua + '  [undo] Restored ' + $w.rel_path + $script:Gm.Reset)
        }
        elseif ($w.action -eq 'created' -and $w.full_path -and (Test-Path -LiteralPath $w.full_path)) {
            Remove-Item -LiteralPath $w.full_path -Force -ErrorAction SilentlyContinue
            Write-Host ($script:Gm.Aqua + '  [undo] Removed created file ' + $w.rel_path + $script:Gm.Reset)
        }
    }
}

function Invoke-AgentTool {
    param([string]$Root, $Call)
    try {
        $name = $Call.function.name
        if ($name -notin @('list_files', 'read_file', 'find_files', 'grep_files', 'write_file', 'edit_file', 'run_command')) { throw 'Unknown tool.' }
        if ($script:AgentPermission -eq 'ReadOnly' -and $name -in @('write_file', 'edit_file', 'run_command')) {
            throw 'Permission mode ReadOnly does not allow file modifications or commands.'
        }
        $arguments = $Call.function.arguments | ConvertFrom-Json -ErrorAction Stop
        if ($name -eq 'run_command') { return (Invoke-AgentCommand -Root $Root -Arguments $arguments) }
        if ($arguments.path -isnot [string]) { throw 'path must be a string.' }
        if ($name -in @('write_file', 'edit_file')) { return (Invoke-AgentWrite -Root $Root -Name $name -Arguments $arguments) }
        $path = Resolve-AgentPath -Root $Root -RelativePath $arguments.path
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        Write-Host ($script:Gm.Yellow + ('  [{0}] ' -f $name) + $script:Gm.Grey1 + $arguments.path + $script:Gm.Reset)
        if ($name -eq 'list_files') {
            if (-not $item.PSIsContainer) { throw 'Expected a directory.' }
            $entries = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Where-Object {
                -not (Test-IsSecretFile $_)
            } | Select-Object -First 201)
            return (@{
                entries = @($entries | Select-Object -First 200 -Property Name, PSIsContainer, Length)
                truncated = ($entries.Count -gt 200)
            } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($name -eq 'find_files') {
            if (-not $item.PSIsContainer) { throw 'Expected a directory.' }
            if ($arguments.pattern -isnot [string] -or -not $arguments.pattern.Trim()) { throw 'pattern must be a nonempty string.' }
            $found = @()
            $truncated = $false
            foreach ($child in @(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue)) {
                if (($child.Attributes -band 1024) -ne 0) { continue }
                if ($child.FullName -match '[/\\](\.git|node_modules)([/\\]|$)') { continue }
                if (Test-IsSecretFile $child) { continue }
                if ($child.Name -like $arguments.pattern) {
                    if ($found.Count -ge 200) { $truncated = $true; break }
                    $found += @{
                        path = (Get-WorkspaceRelativePath -Root $Root -FullPath $child.FullName)
                        is_dir = [bool]$child.PSIsContainer
                        length = if ($child.PSIsContainer) { $null } else { $child.Length }
                    }
                }
            }
            return (@{ matches = $found; truncated = $truncated } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($name -eq 'grep_files') {
            if ($arguments.pattern -isnot [string] -or -not $arguments.pattern) { throw 'pattern must be a nonempty string.' }
            $isLiteral = [bool]$arguments.literal
            $isCaseSensitive = [bool]$arguments.case_sensitive
            $includeFilter = if ($arguments.include -is [string] -and $arguments.include.Trim()) { $arguments.include.Trim() } else { '' }
            $ctxLines = 0
            if ($null -ne $arguments.context_lines) {
                $ctxLines = [int]$arguments.context_lines
                if ($ctxLines -lt 0) { $ctxLines = 0 }
                if ($ctxLines -gt 5) { $ctxLines = 5 }
            }
            $targetFiles = @()
            if ($item.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
                    if (($child.Attributes -band 1024) -ne 0) { continue }
                    if ($child.FullName -match '[/\\](\.git|node_modules)([/\\]|$)') { continue }
                    if (Test-IsSecretFile $child) { continue }
                    if ($includeFilter -and ($child.Name -notlike $includeFilter)) { continue }
                    if ($child.Length -le 1MB) { $targetFiles += $child.FullName }
                    if ($targetFiles.Count -ge 500) { break }
                }
            }
            else {
                if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
                $targetFiles = @($item.FullName)
            }
            $hits = @()
            $truncated = $false
            if ($targetFiles.Count -gt 0) {
                $selParams = @{ LiteralPath = $targetFiles; Pattern = $arguments.pattern; Encoding = 'UTF8'; ErrorAction = 'Stop' }
                if ($isLiteral) { $selParams.SimpleMatch = $true }
                if ($isCaseSensitive) { $selParams.CaseSensitive = $true }
                if ($ctxLines -gt 0) { $selParams.Context = @($ctxLines, $ctxLines) }
                foreach ($m in @(Select-String @selParams)) {
                    if ($hits.Count -ge 100) { $truncated = $true; break }
                    $lineText = [string]$m.Line
                    if ($lineText.Length -gt 300) { $lineText = $lineText.Substring(0, 300) + '...' }
                    $hitObj = @{
                        path = (Get-WorkspaceRelativePath -Root $Root -FullPath $m.Path)
                        line_number = [int]$m.LineNumber
                        line = $lineText
                    }
                    if ($ctxLines -gt 0 -and $m.Context) {
                        $hitObj.context = @($m.Context.PreContext) + @($lineText) + @($m.Context.PostContext)
                    }
                    $hits += $hitObj
                }
            }
            return (@{ matches = $hits; truncated = $truncated } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($item.PSIsContainer) { throw 'Expected a text file.' }
        if ($item.Length -gt 1MB) { throw 'File exceeds 1 MiB.' }
        $startLine = 1
        if ($null -ne $arguments.start_line) {
            if ($arguments.start_line -isnot [int] -and $arguments.start_line -isnot [long]) { throw 'start_line must be an integer.' }
            $startLine = [int]$arguments.start_line
            if ($startLine -lt 1) { throw 'start_line must be at least 1.' }
        }
        $maxLines = 300
        if ($null -ne $arguments.max_lines) {
            if ($arguments.max_lines -isnot [int] -and $arguments.max_lines -isnot [long]) { throw 'max_lines must be an integer.' }
            $maxLines = [int]$arguments.max_lines
            if ($maxLines -lt 1 -or $maxLines -gt 300) { throw 'max_lines must be between 1 and 300.' }
        }
        $allLines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)
        $totalLines = $allLines.Count
        $skip = $startLine - 1
        $selected = @($allLines | Select-Object -Skip $skip -First $maxLines)
        $text = $selected -join "`n"
        $endLine = if ($selected.Count -gt 0) { $startLine + $selected.Count - 1 } else { $startLine }
        $truncated = ($endLine -lt $totalLines)
        if ($text.Length -gt 20000) { $text = $text.Substring(0, 20000); $truncated = $true }
        $nextStart = if ($truncated -and $endLine -lt $totalLines) { $endLine + 1 } else { $null }
        return (@{
            text = $text
            start_line = $startLine
            end_line = $endLine
            total_lines = $totalLines
            truncated = $truncated
            next_start_line = $nextStart
        } | ConvertTo-Json -Compress)
    }
    catch { return (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
}
