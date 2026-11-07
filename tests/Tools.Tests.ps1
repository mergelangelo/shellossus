$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    # Workspace boundaries must not treat case variants or Unix backslashes as descendants.
    Assert-True (Test-AgentPathWithinRoot -RootPath '/tmp/workspace' -TargetPath '/tmp/workspace/file.txt') 'Workspace child was rejected.'
    Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/tmp/workspace' -TargetPath '/tmp/WORKSPACE/file.txt')) 'Case-variant sibling was accepted.'
    Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/tmp/workspace' -TargetPath '/tmp/workspace-other/file.txt')) 'Prefix sibling was accepted.'
    if ($env:OS -ne 'Windows_NT') {
        Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/tmp/workspace' -TargetPath '/tmp/workspace\outside.txt')) 'Unix backslash sibling was accepted.'
        Assert-True (Test-AgentPathWithinRoot -RootPath '/tmp/workspace\' -TargetPath '/tmp/workspace\/file.txt') 'Unix directory with a trailing backslash was rejected.'
        Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/tmp/workspace\' -TargetPath '/tmp/workspace/file.txt')) 'Unix trailing backslash was removed from the workspace name.'
    }
    $caseSibling = Join-Path $testRoot 'WORKSPACE'
    if (-not (Test-Path -LiteralPath $caseSibling)) {
        New-Item -ItemType Directory -Path $caseSibling -ErrorAction Stop | Out-Null
        $caseOutside = Join-Path $caseSibling 'outside.txt'
        Set-Content -LiteralPath $caseOutside -Value 'outside' -Encoding UTF8 -NoNewline
        $caseRejected = $false
        try { $null = Resolve-AgentPath -Root $workspacePath -RelativePath $caseOutside }
        catch { $caseRejected = $_.Exception.Message -like '*outside the workspace*' }
        Assert-True $caseRejected 'Case-variant sibling passed workspace validation.'
    }

    # A symlink must be rejected before an overwrite preview can read its target.
    $linkTarget = Join-Path $testRoot 'link-target.txt'
    $linkPath = Join-Path $workspacePath 'file-link.txt'
    Set-Content -LiteralPath $linkTarget -Value 'outside-private' -Encoding UTF8 -NoNewline
    $fileLinkAvailable = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null
        $fileLinkAvailable = $true
    }
    catch { Write-Warning 'Symbolic link creation unavailable; file-link security check skipped.' }
    if ($fileLinkAvailable) {
        $savedOutputMode = $script:OutputMode
        $script:OutputMode = 'json'
        $linkRejected = $false
        try {
            $null = Invoke-AgentWrite -Root $workspacePath -Name 'write_file' -Arguments @{ path = 'file-link.txt'; content = 'new'; overwrite = $true }
        }
        catch { $linkRejected = $_.Exception.Message -like '*Reparse points*' }
        finally { $script:OutputMode = $savedOutputMode }
        Assert-True $linkRejected 'Overwrite did not reject the symlink before preview and confirmation.'
        Assert-True ((Get-Content -LiteralPath $linkTarget -Raw -Encoding UTF8) -ceq 'outside-private') 'Overwrite changed the symlink target.'
        Remove-Item -LiteralPath $linkPath -Force
    }

    # Undo must reject substituted parent links before restoring any file in the turn.
    $undoDir = Join-Path $workspacePath 'undo-parent'
    $savedUndoDir = Join-Path $workspacePath 'undo-parent-saved'
    $outsideDir = Join-Path $testRoot 'undo-outside'
    New-Item -ItemType Directory -Path $undoDir, $outsideDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $undoDir 'target.txt') -Value 'before' -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $outsideDir 'target.txt') -Value 'after' -Encoding UTF8 -NoNewline
    $savedPermission = $script:AgentPermission
    $savedOutputMode = $script:OutputMode
    $script:AgentPermission = 'AutoEdit'
    $script:OutputMode = 'json'
    $script:CurrentTurnWrites = @()
    $null = Invoke-AgentWrite -Root $workspacePath -Name 'write_file' -Arguments @{ path = 'undo-safe.txt'; content = 'safe' }
    $null = Invoke-AgentWrite -Root $workspacePath -Name 'edit_file' -Arguments @{ path = 'undo-parent/target.txt'; old_text = 'before'; new_text = 'after' }
    $undoSecurityEntry = @{ messages = @(); writes = @($script:CurrentTurnWrites) }
    Move-Item -LiteralPath $undoDir -Destination $savedUndoDir -ErrorAction Stop
    $dirLinkAvailable = $false
    try {
        New-Item -ItemType SymbolicLink -Path $undoDir -Target $outsideDir -ErrorAction Stop | Out-Null
        $dirLinkAvailable = $true
    }
    catch { Write-Warning 'Symbolic link creation unavailable; undo-link security check skipped.' }
    if ($dirLinkAvailable) {
        try {
            $undoRejected = $false
            try { Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $undoSecurityEntry }
            catch { $undoRejected = $_.Exception.Message -like '*Unsafe undo path*' }
            Assert-True $undoRejected 'Undo accepted a substituted parent symlink.'
            Assert-True ((Get-Content -LiteralPath (Join-Path $outsideDir 'target.txt') -Raw -Encoding UTF8) -ceq 'after') 'Undo modified an external file.'
            Assert-True (Test-Path -LiteralPath (Join-Path $workspacePath 'undo-safe.txt')) 'Undo preflight modified a different file.'
            Assert-True (Test-Path -LiteralPath $undoSecurityEntry.writes[1].backup) 'Undo discarded the backup after rejecting a symlink.'
        }
        finally {
            if (Test-Path -LiteralPath $undoDir) {
                (Get-Item -LiteralPath $undoDir -Force).Delete()
            }
        }
    }
    Move-Item -LiteralPath $savedUndoDir -Destination $undoDir -ErrorAction Stop
    Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $undoSecurityEntry
    Assert-True ((Get-Content -LiteralPath (Join-Path $undoDir 'target.txt') -Raw -Encoding UTF8) -ceq 'before') 'Undo retry failed after removing the symlink.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'undo-safe.txt'))) 'Undo retry did not remove the created file.'
    if ($fileLinkAvailable) {
        $script:CurrentTurnWrites = @()
        $null = Invoke-AgentWrite -Root $workspacePath -Name 'edit_file' -Arguments @{ path = 'undo-parent/target.txt'; old_text = 'before'; new_text = 'after' }
        $leafUndoEntry = @{ messages = @(); writes = @($script:CurrentTurnWrites) }
        $undoLeaf = Join-Path $undoDir 'target.txt'
        Remove-Item -LiteralPath $undoLeaf -Force
        New-Item -ItemType SymbolicLink -Path $undoLeaf -Target (Join-Path $outsideDir 'target.txt') -ErrorAction Stop | Out-Null
        $leafRejected = $false
        try { Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $leafUndoEntry }
        catch { $leafRejected = $_.Exception.Message -like '*Unsafe undo path*' }
        Assert-True $leafRejected 'Undo accepted a substituted target symlink.'
        Assert-True ((Get-Content -LiteralPath (Join-Path $outsideDir 'target.txt') -Raw -Encoding UTF8) -ceq 'after') 'Undo modified the external symlink target.'
        Remove-Item -LiteralPath $undoLeaf -Force
        Set-Content -LiteralPath $undoLeaf -Value 'after' -Encoding UTF8 -NoNewline
        Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $leafUndoEntry
        Assert-True ((Get-Content -LiteralPath $undoLeaf -Raw -Encoding UTF8) -ceq 'before') 'Undo retry failed after removing the target symlink.'
    }
    $script:AgentPermission = $savedPermission
    $script:OutputMode = $savedOutputMode
    $script:CurrentTurnWrites = @()

    Set-Content -LiteralPath (Join-Path $workspacePath 'hello.txt') -Value 'hello' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $testRoot 'outside.txt') -Value 'private' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workspacePath '.env') -Value 'SECRET=hidden' -Encoding UTF8
    $customCfg = Join-Path $workspacePath 'custom.cfg'
    Set-Content -LiteralPath $customCfg -Value 'SHELLOSSUS_API_KEY="secret"' -Encoding UTF8
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $workspacePath '.\custom.cfg')

    # Basic read_file, unknown tool, malformed JSON arguments.
    $call = @{ id = 't1'; function = @{ name = 'read_file'; arguments = '{"path":"hello.txt"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.text -eq 'hello') 'Text read failed.'
    $call.function.name = 'execute_command'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -eq 'Unknown tool.') 'Unknown tool was not rejected.'
    $call.function.name = 'read_file'
    $call.function.arguments = '{broken'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Malformed arguments were not rejected.'

    # read_file 300-line pagination and max_lines/total_lines metadata.
    Set-Content -LiteralPath (Join-Path $workspacePath 'long.txt') -Value (1..350) -Encoding UTF8
    $call.function.arguments = '{"path":"long.txt"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True $result.truncated 'Long file was not marked truncated.'
    Assert-True (($result.text -split "`n").Count -eq 300) 'Line limit failed.'
    $call.function.arguments = '{"path":"long.txt","start_line":301}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True (-not $result.truncated) 'Tail read should not be marked truncated.'
    Assert-True ($result.start_line -eq 301) 'start_line was not returned.'
    $tailLines = @($result.text -split "`n")
    Assert-True ($tailLines.Count -eq 50 -and $tailLines[0] -eq '301' -and $tailLines[-1] -eq '350') 'start_line offset read failed.'
    $call.function.arguments = '{"path":"long.txt","start_line":10,"max_lines":5}'
    $sliceRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($sliceRes.total_lines -eq 350 -and $sliceRes.start_line -eq 10 -and $sliceRes.end_line -eq 14 -and $sliceRes.next_start_line -eq 15) 'read_file max_lines/total_lines metadata failed.'

    # read_file 20,000-char limit without skipping lines and start_char for >20,000-char single lines.
    $lines350 = 1..350 | ForEach-Object { ('L{0:D3}_' -f $_) + ('x' * 95) }
    Set-Content -LiteralPath (Join-Path $workspacePath 'lines350.txt') -Value ($lines350 -join "`n") -Encoding UTF8 -NoNewline
    $call.function.arguments = '{"path":"lines350.txt","start_line":1}'
    $rf1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($rf1.truncated -and $rf1.end_line -lt 300 -and $rf1.next_start_line -eq ($rf1.end_line + 1) -and $null -eq $rf1.next_start_char) 'read_file did not adjust end_line/next_start_line when hitting 20,000-char limit.'
    $call.function.arguments = ('{{"path":"lines350.txt","start_line":{0}}}' -f $rf1.next_start_line)
    $rf2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $combinedLines = @($rf1.text -split "`n") + @($rf2.text -split "`n")
    Assert-True ($combinedLines.Count -eq 350 -and $combinedLines[0].StartsWith('L001_') -and $combinedLines[183].StartsWith('L184_') -and $combinedLines[349].StartsWith('L350_')) 'read_file skipped or truncated lines across 20,000-char pagination.'
    $longLine25k = ('A' * 20000) + ('B' * 5000)
    Set-Content -LiteralPath (Join-Path $workspacePath 'longline25k.txt') -Value $longLine25k -Encoding UTF8 -NoNewline
    $call.function.arguments = '{"path":"longline25k.txt","start_line":1}'
    $ll1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($ll1.truncated -and $ll1.text.Length -eq 20000 -and $ll1.end_line -eq 1 -and $ll1.next_start_line -eq 1 -and $ll1.next_start_char -eq 20001) 'read_file did not return next_start_char for >20,000-char line.'
    $call.function.arguments = '{"path":"longline25k.txt","start_line":1,"start_char":20001}'
    $ll2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ((-not $ll2.truncated) -and $ll2.text.Length -eq 5000 -and ($ll1.text + $ll2.text) -eq $longLine25k) 'read_file failed to resume mid-line with start_char.'

    # list_files hides .env and custom ConfigPath while showing .gitignore and .env.example.
    Set-Content -LiteralPath (Join-Path $workspacePath '.gitignore') -Value '*.log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workspacePath '.env.example') -Value 'SHELLOSSUS_MODEL=""' -Encoding UTF8
    $call.function.name = 'list_files'
    $call.function.arguments = '{"path":"."}'
    $listing = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($listing.entries.Name -contains '.gitignore') 'list_files missed .gitignore.'
    Assert-True ($listing.entries.Name -contains '.env.example') 'list_files missed .env.example.'
    Assert-True ($listing.entries.Name -notcontains '.env') 'list_files exposed .env.'
    Assert-True ($listing.entries.Name -notcontains 'custom.cfg') 'list_files exposed custom ConfigPath.'

    # write_file and edit_file approval, backups, CRLF preservation, overwrite=true.
    $script:approval = ''
    $script:prompts = 0
    function Read-Host {
        param($Prompt)
        $script:prompts++
        if ($script:approval -is [array]) {
            $next = $script:approval[0]
            if ($script:approval.Count -le 1) { $script:approval = '' }
            else { $script:approval = @($script:approval[1..($script:approval.Count - 1)]) }
            return $next
        }
        return $script:approval
    }
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"created.txt","content":"first"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'cancelled') 'Write must require approval.'
    Assert-True (-not (Test-Path (Join-Path $workspacePath 'created.txt'))) 'Declined file was created.'
    $script:approval = 'WRITE'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'written') 'Approved creation failed.'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'write_file must not overwrite.'
    $call.function.arguments = '{"path":"../escape.txt","content":"bad"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Outside write was allowed.'
    Assert-True (-not (Test-Path (Join-Path $testRoot 'escape.txt'))) 'Outside file was created.'
    $call.function.arguments = '{"path":"../outside.txt","content":"bad"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -like '*outside*') 'Existing outside file leaked existence instead of failing boundary check.'
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $workspacePath '.\uncreated.cfg')
    $call.function.arguments = '{"path":"uncreated.cfg","content":"bad"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -like '*credential*') 'Agent must not write custom ConfigPath.'
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"created.txt","old_text":"first","new_text":"second"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'written') 'Approved edit failed.'
    Assert-True ((Get-Content -LiteralPath $result.backup -Raw -Encoding UTF8) -eq 'first') 'Backup does not preserve original.'
    Remove-Item -LiteralPath $result.backup -Force
    Assert-True ((Get-Content (Join-Path $workspacePath 'created.txt') -Raw -Encoding UTF8) -eq 'second') 'Edit content mismatch.'
    $call.function.arguments = '{"path":"created.txt","old_text":"missing","new_text":"bad"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Missing edit match was accepted.'
    Set-Content -LiteralPath (Join-Path $workspacePath 'crlf.txt') -Value "line1`r`nline2`r`nline3" -Encoding UTF8 -NoNewline
    $call.function.arguments = '{"path":"crlf.txt","old_text":"line1\nline2","new_text":"row1\nrow2"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'written') 'Multi-line CRLF edit failed.'
    Remove-Item -LiteralPath $result.backup -Force
    $crlfAfter = Get-Content -LiteralPath (Join-Path $workspacePath 'crlf.txt') -Raw -Encoding UTF8
    Assert-True ($crlfAfter -eq "row1`r`nrow2`r`nline3") 'CRLF line endings were not preserved after edit.'

    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"created.txt","content":"overwritten","overwrite":true}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'written' -and [bool]$result.backup) 'Overwrite with backup failed.'
    Assert-True ((Get-Content -LiteralPath $result.backup -Raw -Encoding UTF8) -eq 'second') 'Overwrite backup content mismatch.'
    Remove-Item -LiteralPath $result.backup -Force
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'created.txt') -Raw -Encoding UTF8) -eq 'overwritten') 'Overwritten file content mismatch.'

    # find_files and grep_files search workspace while hiding credentials.
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $workspacePath '.\custom.cfg')
    $call.function.name = 'find_files'
    $call.function.arguments = '{"path":".","pattern":"*"}'
    $found = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($found.matches.path -contains 'hello.txt') 'find_files missed hello.txt.'
    Assert-True ($found.matches.path -notcontains '.env' -and $found.matches.path -notcontains 'custom.cfg') 'find_files exposed credentials.'

    $call.function.name = 'grep_files'
    $call.function.arguments = '{"path":".","pattern":"row2"}'
    $grepped = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($grepped.matches.Count -eq 1 -and $grepped.matches[0].path -eq 'crlf.txt' -and $grepped.matches[0].line_number -eq 2) 'grep_files failed to locate match.'
    $call.function.arguments = '{"path":".","pattern":"SECRET"}'
    $secretGrep = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($secretGrep.matches.Count -eq 0) 'grep_files leaked .env contents.'

    # run_command approval, execution, truncation log, and timeout.
    $call.function.name = 'run_command'
    $call.function.arguments = '{"command":"Write-Output \"cmd-ok\""}'
    $script:approval = 'WRITE'
    $cmdDeclined = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($cmdDeclined.status -eq 'cancelled') 'run_command must require RUN approval.'
    $script:approval = 'RUN'
    $cmdApproved = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($cmdApproved.status -eq 'executed' -and $cmdApproved.exit_code -eq 0 -and $cmdApproved.output.Trim() -eq 'cmd-ok') 'Approved run_command failed.'
    $script:approval = 'WRITE'

    # Fuzzy edit_file matching, batch edits[], large file edit, and /undo disk rollback.
    $script:CurrentTurnWrites = @()
    Set-Content -LiteralPath (Join-Path $workspacePath 'fuzzy.txt') -Value "alpha   `r`nbeta`t`r`ngamma" -Encoding UTF8 -NoNewline
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"fuzzy.txt","old_text":"alpha\nbeta","new_text":"A\nB"}'
    $fuzzyRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($fuzzyRes.status -eq 'written') 'Fuzzy edit_file with trailing whitespace failed.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'fuzzy.txt') -Raw -Encoding UTF8) -eq "A`r`nB`r`ngamma") 'Fuzzy edit_file output mismatch.'
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"temp-new.txt","content":"temp"}'
    $tempWriteRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($tempWriteRes.status -eq 'written' -and (Test-Path -LiteralPath (Join-Path $workspacePath 'temp-new.txt'))) 'Temp file creation failed.'
    $undoEntry = @{ messages = @(@{ role = 'system'; content = 'sys' }); writes = @($script:CurrentTurnWrites) }
    $undoState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'change' }) }
    Invoke-AgentUndo -State $undoState -UndoEntry $undoEntry
    Assert-True ($undoState.messages.Count -eq 1) 'Undo did not restore message state.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'fuzzy.txt') -Raw -Encoding UTF8) -eq "alpha   `r`nbeta`t`r`ngamma") 'Undo did not restore modified file from backup.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'temp-new.txt'))) 'Undo did not remove newly created file.'

    # Automatic parent directory creation in write_file and /undo cleanup of empty created directories.
    $script:CurrentTurnWrites = @()
    $script:approval = 'n'
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"new_pkg/sub_mod/created.txt","content":"nested-content"}'
    $declinedNested = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($declinedNested.status -eq 'cancelled') 'Declined nested write_file should return cancelled.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'new_pkg'))) 'Declined nested write_file must not create missing parent directories.'
    $script:approval = 'WRITE'
    $approvedNested = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $nestedFilePath = Join-Path (Join-Path (Join-Path $workspacePath 'new_pkg') 'sub_mod') 'created.txt'
    Assert-True ($approvedNested.status -eq 'written' -and (Test-Path -LiteralPath $nestedFilePath)) 'Approved nested write_file did not create file and parent directories.'
    Assert-True ((Get-Content -LiteralPath $nestedFilePath -Raw -Encoding UTF8) -ceq 'nested-content') 'Nested write_file content mismatch.'
    $nestedUndoEntry = @{ messages = @(@{ role = 'system'; content = 'sys' }); writes = @($script:CurrentTurnWrites) }
    $nestedUndoState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'create nested' }) }
    Invoke-AgentUndo -State $nestedUndoState -UndoEntry $nestedUndoEntry
    Assert-True (-not (Test-Path -LiteralPath $nestedFilePath)) 'Undo did not remove created file in nested directory.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $workspacePath 'new_pkg') 'sub_mod'))) 'Undo did not remove empty leaf directory created by write_file.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'new_pkg'))) 'Undo did not remove empty ancestor directory created by write_file.'
    $call.function.arguments = '{"path":"missing_dir/../../outside.txt","content":"bad"}'
    $travNested = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$travNested.error) 'write_file allowed traversal through nonexistent directory outside workspace.'

    Set-Content -LiteralPath (Join-Path $workspacePath 'batch.txt') -Value "one`r`ntwo`r`nthree`r`nfour" -Encoding UTF8 -NoNewline
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"batch.txt","edits":[{"old_text":"one","new_text":"1"},{"old_text":"four","new_text":"4"}]}'
    $batchRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($batchRes.status -eq 'written' -and $batchRes.edits_applied -eq 2 -and $batchRes.first_changed_line -eq 1) 'Batch edits[] failed.'
    Remove-Item -LiteralPath $batchRes.backup -Force
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'batch.txt') -Raw -Encoding UTF8) -eq "1`r`ntwo`r`nthree`r`n4") 'Batch edits[] content mismatch.'
    $call.function.arguments = '{"path":"batch.txt","edits":[{"old_text":"two\nthree","new_text":"X"},{"old_text":"three\n4","new_text":"Y"}]}'
    $overlapRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($overlapRes.error -like '*overlap*') 'Overlapping batch edits[] were not rejected.'

    # 4 Permission modes: ReadOnly, Ask, AutoEdit, Auto.
    $script:approval = ''
    $script:AgentPermission = 'ReadOnly'
    Assert-True (@(Get-AgentTools).Count -eq 10) 'ReadOnly mode should expose 10 tools.'
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"ro.txt","content":"no"}'
    $roRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($roRes.error -like '*ReadOnly*') 'ReadOnly mode did not block write_file.'

    $script:AgentPermission = 'AutoEdit'
    $promptsBefore = $script:prompts
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"autoedit.txt","content":"auto-written"}'
    $aeWrite = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($aeWrite.status -eq 'written' -and $script:prompts -eq $promptsBefore) 'AutoEdit mode should write without prompting Read-Host.'
    $call.function.name = 'run_command'
    $call.function.arguments = '{"command":"Write-Output \"should-prompt\""}'
    $aeCmd = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($aeCmd.status -eq 'cancelled' -and $script:prompts -gt $promptsBefore) 'AutoEdit mode must still prompt for run_command.'

    $script:AgentPermission = 'Auto'
    $promptsBefore = $script:prompts
    $autoCmd = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($autoCmd.status -eq 'executed' -and $script:prompts -eq $promptsBefore) 'Auto mode should execute run_command without prompting.'

    $call.function.arguments = '{"command":"1..320 | ForEach-Object { $_ }"}'
    $truncCmd = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($truncCmd.truncated -and [bool]$truncCmd.full_output_path -and (Test-Path -LiteralPath (Join-Path $workspacePath $truncCmd.full_output_path))) 'Truncated run_command did not save full output log.'

    # Task 18: Windows -Command quoting matches the previous inline escape and never adds -ExecutionPolicy.
    $savedQuoteOs = Get-Item -LiteralPath 'Env:OS' -ErrorAction SilentlyContinue
    try {
        $quoteCmd = 'say "hi"\'
        $env:OS = 'Windows_NT'
        $windowsArgs = Get-AgentCommandArguments -CommandText $quoteCmd
        $expectedWindows = '-NoProfile -NonInteractive -Command "say \"hi\"\\"'
        Assert-True ($windowsArgs -is [string]) 'Windows command arguments were not one string.'
        Assert-True ($windowsArgs -eq $expectedWindows) "Windows escape changed for a command containing say `"hi`": $windowsArgs"
        Assert-True (($windowsArgs -notmatch 'ExecutionPolicy') -and ($windowsArgs -notmatch 'Bypass')) 'Get-AgentCommandArguments added ExecutionPolicy or Bypass.'
        $env:OS = 'Other'
        $unixArgs = @(Get-AgentCommandArguments -CommandText $quoteCmd)
        Assert-True ($unixArgs.Count -eq 4 -and $unixArgs[0] -eq '-NoProfile' -and $unixArgs[1] -eq '-NonInteractive' -and $unixArgs[2] -eq '-Command' -and $unixArgs[3] -eq $quoteCmd) "Non-Windows arguments were not the four-element raw command."
        $unixJoined = $unixArgs -join ' '
        Assert-True (($unixJoined -notmatch 'ExecutionPolicy') -and ($unixJoined -notmatch 'Bypass')) 'Non-Windows arguments added ExecutionPolicy or Bypass.'
    }
    finally {
        if ($null -eq $savedQuoteOs) {
            Remove-Item -LiteralPath 'Env:OS' -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath 'Env:OS' -Value ([string]$savedQuoteOs.Value)
        }
    }

    # Child shell publishes the current session values, including empty, and does not keep a stale parent value.
    $savedChildSessionId = $env:SHELLOSSUS_SESSION_ID
    $savedChildSessionFile = $env:SHELLOSSUS_SESSION_FILE
    $savedChildModel = $env:SHELLOSSUS_MODEL
    $savedChildReason = $env:SHELLOSSUS_REASONING_LEVEL
    $savedChildSKey = $env:SHELLOSSUS_API_KEY
    $savedChildOKey = $env:OPENAI_API_KEY
    $savedScriptSessionId = $script:ActiveSessionId
    $savedScriptSessionFile = $script:ActiveSessionFile
    $savedScriptModelId = $script:ActiveModelId
    $savedScriptReason = $script:ReasoningEffort
    try {
        $env:SHELLOSSUS_SESSION_ID = 'stale'
        $script:ActiveSessionId = ''
        $staleChild = Invoke-ShellCommand -Root $workspacePath -Command 'Write-Output $env:SHELLOSSUS_SESSION_ID'
        Assert-True (([string]$staleChild.output).Trim() -eq '') "Child inherited a stale SHELLOSSUS_SESSION_ID, got '$($staleChild.output)'."
        Assert-True ($env:SHELLOSSUS_SESSION_ID -eq 'stale') 'Parent SHELLOSSUS_SESSION_ID was not restored to stale.'

        $env:SHELLOSSUS_SESSION_FILE = 'stale-file'
        $script:ActiveSessionFile = ''
        $env:SHELLOSSUS_MODEL = 'stale-model'
        $script:ActiveModelId = ''
        $env:SHELLOSSUS_REASONING_LEVEL = 'stale-reason'
        $script:ReasoningEffort = ''
        $staleOthers = Invoke-ShellCommand -Root $workspacePath -Command 'Write-Output $env:SHELLOSSUS_SESSION_FILE; Write-Output $env:SHELLOSSUS_MODEL; Write-Output $env:SHELLOSSUS_REASONING_LEVEL'
        Assert-True (([string]$staleOthers.output).Trim() -eq '') "Child inherited a stale session file, model, or reasoning level, got '$($staleOthers.output)'."
        Assert-True ($env:SHELLOSSUS_SESSION_FILE -eq 'stale-file' -and $env:SHELLOSSUS_MODEL -eq 'stale-model' -and $env:SHELLOSSUS_REASONING_LEVEL -eq 'stale-reason') 'Parent session file, model, or reasoning level was not restored.'

        $script:ActiveSessionId = 'live-session'
        $script:ActiveSessionFile = 'live-file'
        $script:ActiveModelId = 'live-model'
        $script:ReasoningEffort = 'high'
        $liveChild = Invoke-ShellCommand -Root $workspacePath -Command 'Write-Output $env:SHELLOSSUS_SESSION_ID; Write-Output $env:SHELLOSSUS_SESSION_FILE; Write-Output $env:SHELLOSSUS_MODEL; Write-Output $env:SHELLOSSUS_REASONING_LEVEL'
        $liveLines = @(([string]$liveChild.output) -split "`r?`n" | Where-Object { $_ -ne '' })
        Assert-True ($liveLines.Count -eq 4 -and $liveLines[0] -eq 'live-session' -and $liveLines[1] -eq 'live-file' -and $liveLines[2] -eq 'live-model' -and $liveLines[3] -eq 'high') "Child did not see the current session values, got '$($liveChild.output)'."
        Assert-True ($env:SHELLOSSUS_SESSION_ID -eq 'stale' -and $env:SHELLOSSUS_SESSION_FILE -eq 'stale-file' -and $env:SHELLOSSUS_MODEL -eq 'stale-model' -and $env:SHELLOSSUS_REASONING_LEVEL -eq 'stale-reason') 'Parent session environment changed while publishing current session values.'

        $env:SHELLOSSUS_API_KEY = 'sec-s'
        $env:OPENAI_API_KEY = 'sec-o'
        $keyChild = Invoke-ShellCommand -Root $workspacePath -Command 'Write-Output $env:SHELLOSSUS_API_KEY; Write-Output $env:OPENAI_API_KEY'
        Assert-True (([string]$keyChild.output).Trim() -eq '') 'Invoke-ShellCommand did not scrub API keys from the child environment.'
        Assert-True ($env:SHELLOSSUS_API_KEY -eq 'sec-s' -and $env:OPENAI_API_KEY -eq 'sec-o') 'Invoke-ShellCommand did not restore API keys after the command.'
    }
    finally {
        $env:SHELLOSSUS_SESSION_ID = $savedChildSessionId
        $env:SHELLOSSUS_SESSION_FILE = $savedChildSessionFile
        $env:SHELLOSSUS_MODEL = $savedChildModel
        $env:SHELLOSSUS_REASONING_LEVEL = $savedChildReason
        $env:SHELLOSSUS_API_KEY = $savedChildSKey
        $env:OPENAI_API_KEY = $savedChildOKey
        $script:ActiveSessionId = $savedScriptSessionId
        $script:ActiveSessionFile = $savedScriptSessionFile
        $script:ActiveModelId = $savedScriptModelId
        $script:ReasoningEffort = $savedScriptReason
    }

    # A junction at .shellossus must not receive the truncated output log. Skip only when this OS cannot create a junction.
    $junctionRoot = Join-Path $testRoot 'junction-shell-ws'
    $junctionOutside = Join-Path $testRoot 'junction-shell-outside'
    New-Item -ItemType Directory -Path $junctionRoot, $junctionOutside -Force | Out-Null
    $dotJunction = Join-Path $junctionRoot '.shellossus'
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $dotJunction -Target $junctionOutside -ErrorAction Stop | Out-Null
        $junctionItem = Get-Item -LiteralPath $dotJunction -Force -ErrorAction Stop
        if (($junctionItem.Attributes -band 1024) -eq 0) { throw 'Junction was not created.' }
        $junctionCreated = $true
    }
    catch {
        if ($env:OS -eq 'Windows_NT') { throw }
    }
    if ($junctionCreated) {
        try {
            $beforeJunction = @(Get-ChildItem -LiteralPath $junctionOutside -Force -ErrorAction SilentlyContinue)
            $junctionCmd = Invoke-ShellCommand -Root $junctionRoot -Command '1..320 | ForEach-Object { $_ }'
            $afterJunction = @(Get-ChildItem -LiteralPath $junctionOutside -Force -ErrorAction SilentlyContinue)
            Assert-True ($junctionCmd.truncated -and $null -eq $junctionCmd.full_output_path) 'Reparse .shellossus copied the output log.'
            Assert-True ($afterJunction.Count -eq $beforeJunction.Count) 'Junction target gained a new file from the output log.'
            Assert-True (([string]$junctionCmd.output).Trim().Length -gt 0) 'Command output was dropped when the output log was skipped.'
        }
        finally {
            $junctionItem = Get-Item -LiteralPath $dotJunction -Force -ErrorAction SilentlyContinue
            if ($junctionItem -and (($junctionItem.Attributes -band 1024) -ne 0)) {
                $junctionItem.Delete()
            }
        }
    }

    $call.function.arguments = '{"command":"Start-Sleep -Seconds 10","timeout_sec":1}'
    $timeoutRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($timeoutRes.status -eq 'timed_out' -and $timeoutRes.timed_out -eq $true) 'Hanging run_command was not terminated on timeout.'
    $script:AgentPermission = 'Ask'
    $script:approval = 'WRITE'

    # grep_files include filter, context_lines, and 500-file pagination.
    $call.function.name = 'grep_files'
    $call.function.arguments = '{"path":".","pattern":"two","include":"batch.txt","context_lines":1}'
    $ctxGrep = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($ctxGrep.matches.Count -eq 1 -and $ctxGrep.matches[0].context.Count -ge 2) 'grep_files include/context_lines failed.'

    # Context lines use the same 300-character cap as the match line.
    $longPre = 'P' * 2000
    $longPost = 'Q' * 2000
    Set-Content -LiteralPath (Join-Path $workspacePath 'longctx.txt') -Value ($longPre + "`n" + 'NEEDLE_CTX' + "`n" + $longPost) -Encoding UTF8 -NoNewline
    $call.function.arguments = '{"path":"longctx.txt","pattern":"NEEDLE_CTX","literal":true,"context_lines":1}'
    $longCtx = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $longCtxMatch = $longCtx.matches[0]
    $preLen = [int]$longCtxMatch.context[0].Length
    $postLen = [int]$longCtxMatch.context[2].Length
    Assert-True ($longCtx.matches.Count -eq 1 -and $longCtxMatch.context.Count -eq 3 -and $longCtxMatch.context[1] -eq 'NEEDLE_CTX') 'grep_files did not return the long lines around the match.'
    Assert-True ($preLen -eq 303 -and $postLen -eq 303 -and $longCtx.lines_truncated -eq $true) "grep context lines were not capped at 300 chars (pre=$preLen post=$postLen lines_truncated=$($longCtx.lines_truncated))."
    Assert-True ($longCtxMatch.context[0] -eq (('P' * 300) + '...') -and $longCtxMatch.context[2] -eq (('Q' * 300) + '...')) 'grep context lines were not the first 300 characters plus an ellipsis.'
    Remove-Item -LiteralPath (Join-Path $workspacePath 'longctx.txt') -Force

    $grepDir501 = Join-Path $workspacePath 'grep501'
    New-Item -ItemType Directory -Path $grepDir501 -Force | Out-Null
    1..500 | ForEach-Object {
        $fname = Join-Path $grepDir501 ('f{0:D4}.txt' -f $_)
        Set-Content -LiteralPath $fname -Value 'haystack' -Encoding UTF8 -NoNewline
    }
    Set-Content -LiteralPath (Join-Path $grepDir501 'f0501.txt') -Value 'NEEDLE_501' -Encoding UTF8 -NoNewline
    $call.function.arguments = '{"path":"grep501","pattern":"NEEDLE_501","literal":true}'
    $g501Page1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($g501Page1.matches.Count -eq 0 -and $g501Page1.truncated -eq $true -and $g501Page1.truncation_reason -eq 'max_files' -and $g501Page1.files_scanned -eq 500 -and $g501Page1.total_files -eq 501 -and $g501Page1.next_file_offset -eq 500) 'grep_files did not report file-limit truncation on 501 files.'
    $call.function.arguments = '{"path":"grep501","pattern":"NEEDLE_501","literal":true,"file_offset":500}'
    $g501Page2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($g501Page2.matches.Count -eq 1 -and $g501Page2.truncated -eq $false -and $g501Page2.files_scanned -eq 1) 'grep_files failed to find match in 501st file using file_offset.'
    Set-Content -LiteralPath (Join-Path $grepDir501 'f0500.txt') -Value 'NEEDLE_501' -Encoding UTF8 -NoNewline
    $call.function.arguments = '{"path":"grep501","pattern":"NEEDLE_501","literal":true,"limit":1}'
    $combinedLimit = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($combinedLimit.truncation_reason -eq 'max_matches_and_max_files' -and $combinedLimit.files_scanned -eq 500 -and $combinedLimit.next_file_offset -eq 500 -and $combinedLimit.next_start_line -eq 1) 'Combined grep file/match limit lost the continuation cursor.'
    $call.function.arguments = '{"path":"grep501","pattern":"NEEDLE_501","literal":true,"limit":1,"file_offset":500,"start_line":1}'
    $combinedTail = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($combinedTail.matches.Count -eq 1 -and -not $combinedTail.truncated -and $combinedTail.matches[0].file -eq 'f0501.txt') 'Combined-limit continuation skipped the final file.'
    Remove-Item -LiteralPath $grepDir501 -Recurse -Force

    # Large file (>20,000 chars) edit_file and strict argument validation.
    $largePrefix = ('A' * 15000) + "`r`n"
    $largeSuffix = "`r`n" + ('B' * 15000)
    Set-Content -LiteralPath (Join-Path $workspacePath 'large.txt') -Value ($largePrefix + 'TARGET_LINE' + $largeSuffix) -Encoding UTF8 -NoNewline
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"large.txt","old_text":"TARGET_LINE","new_text":"REPLACED_LINE"}'
    $largeEdit = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($largeEdit.status -eq 'written') 'Editing a file larger than 20,000 chars failed.'
    Remove-Item -LiteralPath $largeEdit.backup -Force
    $largeAfter = Get-Content -LiteralPath (Join-Path $workspacePath 'large.txt') -Raw -Encoding UTF8
    Assert-True ($largeAfter.Length -gt 30000 -and $largeAfter.Contains('REPLACED_LINE')) 'Large file content corrupted after edit.'

    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"created.txt","content":"bad","overwrite":"false"}'
    $badBool = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($badBool.error -like '*must be a boolean*') 'String "false" was coerced to boolean instead of rejected.'
    $call.function.name = 'list_files'
    $call.function.arguments = '{"path":".","extra_field":1}'
    $badUnknown = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($badUnknown.error -like '*Unknown argument*') 'Unknown tool argument was not rejected.'

    # Multi-file and multi-step /undo conflict guards and retries.
    $script:AgentPermission = 'AutoEdit'
    $script:CurrentTurnWrites = @()
    Set-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Value 'v1-a' -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-2.txt') -Value 'v1-b' -Encoding UTF8 -NoNewline
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"manual-guard-1.txt","old_text":"v1-a","new_text":"v2-a"}'
    $mgRes1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $call.function.arguments = '{"path":"manual-guard-2.txt","old_text":"v1-b","new_text":"v2-b"}'
    $mgRes2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($mgRes1.status -eq 'written' -and $mgRes2.status -eq 'written') 'Setup for multi-file undo guard test failed.'
    Set-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Value 'v3-manual-user-edit' -Encoding UTF8 -NoNewline
    $mgUndoEntry = @{ messages = @(@{ role = 'system'; content = 'sys' }); writes = @($script:CurrentTurnWrites) }
    $mgState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'edit' }) }
    $undoThrew = $false
    try {
        Invoke-AgentUndo -State $mgState -UndoEntry $mgUndoEntry
    }
    catch {
        $undoThrew = $true
    }
    Assert-True $undoThrew 'Invoke-AgentUndo must throw when manual edits would be overwritten.'
    Assert-True ((Test-Path -LiteralPath $mgRes1.backup) -and (Test-Path -LiteralPath $mgRes2.backup)) 'Failed undo deleted a backup file during preflight.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Raw -Encoding UTF8) -eq 'v3-manual-user-edit') 'Undo overwrote manual user edits.'
    Copy-Item -LiteralPath $mgRes2.backup -Destination (Join-Path $workspacePath 'manual-guard-2.txt') -Force
    Remove-Item -LiteralPath $mgRes2.backup -Force
    $mgUndoEntry.writes[1].undone = $true
    Set-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Value 'v2-a' -Encoding UTF8 -NoNewline
    Invoke-AgentUndo -State $mgState -UndoEntry $mgUndoEntry
    Assert-True ($mgState.messages.Count -eq 1) 'Retry undo after resolving conflict did not restore message state.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Raw -Encoding UTF8) -eq 'v1-a') 'Retry undo did not restore first file.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-2.txt') -Raw -Encoding UTF8) -eq 'v1-b') 'Retry undo did not preserve second file.'

    $script:CurrentTurnWrites = @()
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"chain-create.txt","content":"step1"}'
    $cc1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"chain-create.txt","old_text":"step1","new_text":"step2"}'
    $cc2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($cc1.status -eq 'written' -and $cc2.status -eq 'written') 'Setup for create+edit undo test failed.'
    $ccUndoEntry = @{ messages = @(@{ role = 'system'; content = 'sys' }); writes = @($script:CurrentTurnWrites) }
    $ccState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'create and edit' }) }
    Invoke-AgentUndo -State $ccState -UndoEntry $ccUndoEntry
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'chain-create.txt'))) 'Undo of create+edit did not remove the created file.'
    Assert-True (-not (Test-Path -LiteralPath $cc2.backup)) 'Undo of create+edit left intermediate backup behind.'

    Set-Content -LiteralPath (Join-Path $workspacePath 'chain-edit.txt') -Value 'orig-0' -Encoding UTF8 -NoNewline
    $script:CurrentTurnWrites = @()
    $call.function.name = 'edit_file'
    $call.function.arguments = '{"path":"chain-edit.txt","old_text":"orig-0","new_text":"edit-1"}'
    $ce1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $call.function.arguments = '{"path":"chain-edit.txt","old_text":"edit-1","new_text":"edit-2"}'
    $ce2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($ce1.status -eq 'written' -and $ce2.status -eq 'written') 'Setup for edit+edit undo test failed.'
    $ceUndoEntry = @{ messages = @(@{ role = 'system'; content = 'sys' }); writes = @($script:CurrentTurnWrites) }
    $ceState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'two edits' }) }
    Invoke-AgentUndo -State $ceState -UndoEntry $ceUndoEntry
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'chain-edit.txt') -Raw -Encoding UTF8) -eq 'orig-0') 'Undo of two sequential edits did not restore original content.'
    Assert-True ((-not (Test-Path -LiteralPath $ce1.backup)) -and (-not (Test-Path -LiteralPath $ce2.backup))) 'Undo of two sequential edits left backup files behind.'
    $script:AgentPermission = 'Ask'

    # Truncation helpers, Format-EditArguments, tool filtering, and .gitignore rules (including parent directories).
    Assert-True ((Format-ByteSize -Bytes 1536) -eq '1.5KB') 'Format-ByteSize failed.'
    $headRes = Invoke-TruncateHead -Content ("line1`nline2`nline3`nline4") -MaxLines 2 -MaxBytes 1000
    Assert-True ($headRes.truncated -and $headRes.truncated_by -eq 'lines' -and $headRes.output_lines -eq 2 -and $headRes.content -eq "line1`nline2") 'Invoke-TruncateHead lines limit failed.'
    $tailRes = Invoke-TruncateTail -Content ("line1`nline2`nline3`nline4") -MaxLines 2 -MaxBytes 1000
    Assert-True ($tailRes.truncated -and $tailRes.truncated_by -eq 'lines' -and $tailRes.output_lines -eq 2 -and $tailRes.content -eq "line3`nline4") 'Invoke-TruncateTail lines limit failed.'
    Assert-True ($headRes.truncatedBy -ceq $headRes.truncated_by -and $tailRes.truncatedBy -ceq $tailRes.truncated_by) 'truncated_by did not equal truncatedBy.'
    $headEmpty = Invoke-TruncateHead -Content ''
    $headUnder = Invoke-TruncateHead -Content "a`nb" -MaxLines 10 -MaxBytes 100
    $tailEmpty = Invoke-TruncateTail -Content ''
    $tailUnder = Invoke-TruncateTail -Content "a`nb" -MaxLines 10 -MaxBytes 100
    Assert-True ((-not $headEmpty.truncated) -and ($null -eq $headEmpty.truncatedBy) -and ($null -eq $headEmpty.truncated_by) -and (-not ($headEmpty.truncatedBy -is [string]))) 'Invoke-TruncateHead empty truncatedBy was not null.'
    Assert-True ((-not $headUnder.truncated) -and ($null -eq $headUnder.truncatedBy) -and ($null -eq $headUnder.truncated_by) -and (-not ($headUnder.truncatedBy -is [string]))) 'Invoke-TruncateHead under-limit truncatedBy was not null.'
    Assert-True ((-not $tailEmpty.truncated) -and ($null -eq $tailEmpty.truncatedBy) -and ($null -eq $tailEmpty.truncated_by) -and (-not ($tailEmpty.truncatedBy -is [string]))) 'Invoke-TruncateTail empty truncatedBy was not null.'
    Assert-True ((-not $tailUnder.truncated) -and ($null -eq $tailUnder.truncatedBy) -and ($null -eq $tailUnder.truncated_by) -and (-not ($tailUnder.truncatedBy -is [string]))) 'Invoke-TruncateTail under-limit truncatedBy was not null.'
    $lineTrunc = Invoke-TruncateLine -Line ('x' * 600) -MaxChars 500
    Assert-True ($lineTrunc.was_truncated -and $lineTrunc.text.EndsWith('... [truncated]')) 'Invoke-TruncateLine failed.'

    # ConvertTo-NormalizedObjectArray wraps one hashtable when the detector matches and leaves an int untouched.
    $wrappedOne = ConvertTo-NormalizedObjectArray -Value @{ name = 'solo' } -ItemNormalizer { param($Item) $Item } -SingleItemDetector { param($Item) $true }
    Assert-True (($wrappedOne -is [array]) -and ($wrappedOne.Count -eq 1) -and ($wrappedOne[0] -is [hashtable]) -and ($wrappedOne[0].name -eq 'solo')) 'ConvertTo-NormalizedObjectArray did not wrap a hashtable when the detector matched.'
    $untouchedInt = ConvertTo-NormalizedObjectArray -Value ([int]7) -ItemNormalizer { param($Item) $Item } -SingleItemDetector { param($Item) $true }
    Assert-True (($untouchedInt -is [int]) -and ($untouchedInt -eq 7)) 'ConvertTo-NormalizedObjectArray did not leave an int untouched.'

    $normArgs = Format-EditArguments -ArgsObj ([pscustomobject]@{ path = 'hello.txt'; oldText = 'a'; newText = 'b'; edits = '[{"oldText":"x","newText":"y"}]' })
    Assert-True ($normArgs.old_text -eq 'a' -and $normArgs.new_text -eq 'b' -and $normArgs.edits[0].old_text -eq 'x' -and $normArgs.edits[0].new_text -eq 'y') 'Format-EditArguments camelCase / JSON edits normalization failed.'
    $norm = Format-EditArguments -Arguments ([pscustomobject]@{
        path = 'a.txt'; old_text = 'keep'; oldText = 'drop'; new_text = 'N'; newText = 'D'
    })
    Assert-True ($norm.old_text -eq 'keep' -and $norm.new_text -eq 'N') 'camelCase alias clobbered canonical edit fields.'
    Assert-True ((-not $norm.ContainsKey('oldText')) -and (-not $norm.ContainsKey('newText'))) 'camelCase alias was kept beside canonical edit fields.'
    $normValidated = $true
    try { Test-AgentToolArguments -Name 'edit_file' -Arguments $norm } catch { $normValidated = $false }
    Assert-True $normValidated 'Canonical edit fields with aliases did not validate.'
    $normEdits = Format-EditArguments -Arguments ([pscustomobject]@{
        path = 'b.txt'
        edits = @([pscustomobject]@{ old_text = 'keep'; oldText = 'drop'; new_text = 'N'; newText = 'D' })
    })
    Assert-True ($normEdits.edits[0].old_text -eq 'keep' -and $normEdits.edits[0].new_text -eq 'N') 'camelCase alias clobbered canonical edits[] fields.'
    Assert-True ((-not $normEdits.edits[0].ContainsKey('oldText')) -and (-not $normEdits.edits[0].ContainsKey('newText'))) 'camelCase alias was kept beside canonical edits[] fields.'
    $editsValidated = $true
    try { Test-AgentToolArguments -Name 'edit_file' -Arguments $normEdits } catch { $editsValidated = $false }
    Assert-True $editsValidated 'Canonical edits[] fields with aliases did not validate.'
    # Get-Member lists oldText before old_text, so the canonical assignment used to win by accident.
    # Reversing that list puts each alias after its canonical name, which is the order that clobbered.
    $savedGetObjectPropertyNames = ${function:Get-ObjectPropertyNames}
    try {
        function Get-ObjectPropertyNames {
            param($InputObject)
            $names = @(& $savedGetObjectPropertyNames -InputObject $InputObject)
            $rev = @()
            for ($i = $names.Count - 1; $i -ge 0; $i--) { $rev += $names[$i] }
            return $rev
        }
        $normReversed = Format-EditArguments -Arguments ([pscustomobject]@{
            path = 'a.txt'; old_text = 'keep'; oldText = 'drop'; new_text = 'N'; newText = 'D'
        })
        Assert-True ($normReversed.old_text -eq 'keep' -and $normReversed.new_text -eq 'N') 'camelCase alias clobbered canonical edit fields.'
        $normReversedEdits = Format-EditArguments -Arguments ([pscustomobject]@{
            path = 'b.txt'
            edits = @([pscustomobject]@{ old_text = 'keep'; oldText = 'drop'; new_text = 'N'; newText = 'D' })
        })
        Assert-True ($normReversedEdits.edits[0].old_text -eq 'keep' -and $normReversedEdits.edits[0].new_text -eq 'N') 'camelCase alias clobbered canonical edits[] fields.'
    }
    finally {
        ${function:Get-ObjectPropertyNames} = $savedGetObjectPropertyNames
    }
    $script:EnabledTools = @('read', 'grep')
    $filteredTools = @(Get-AgentTools)
    Assert-True ($filteredTools.Count -eq 2) 'Tool filtering via $script:EnabledTools failed.'
    $capFiltered = Get-AgentCapabilities
    Assert-True ($capFiltered.tool_names.Count -eq 2 -and ($capFiltered.tool_names -join ',') -eq 'read_file,grep_files' -and (-not $capFiltered.can_write) -and (-not $capFiltered.can_exec)) 'Get-AgentCapabilities did not reflect $script:EnabledTools.'
    $script:EnabledTools = @()
    $script:AgentPermission = 'ReadOnly'
    $capRo = Get-AgentCapabilities
    Assert-True ($capRo.permission -eq 'ReadOnly' -and $capRo.tool_names.Count -eq 10 -and ($capRo.tool_names -contains 'memory') -and ($capRo.tool_names -contains 'ask_user') -and ($capRo.tool_names -contains 'todo') -and ($capRo.tool_names -contains 'fetch_url') -and ($capRo.tool_names -contains 'web_search') -and ($capRo.tool_names -contains 'run_agent') -and (-not $capRo.can_write) -and (-not $capRo.can_exec)) 'Get-AgentCapabilities in ReadOnly mode failed.'
    $script:AgentPermission = 'AutoEdit'
    $capAe = Get-AgentCapabilities
    Assert-True ($capAe.permission -eq 'AutoEdit' -and $capAe.can_write -and (-not $capAe.write_requires_confirmation) -and $capAe.exec_requires_confirmation) 'Get-AgentCapabilities in AutoEdit mode failed.'
    $script:NoTools = $true
    $capNoTools = Get-AgentCapabilities
    Assert-True ($capNoTools.no_tools -and $capNoTools.tool_names.Count -eq 0 -and $capNoTools.tools.Count -eq 0) 'Get-AgentCapabilities with $script:NoTools failed.'
    $script:NoTools = $false
    $script:AgentPermission = 'Ask'
    $envInfo = Get-AgentEnvironment -Root $workspacePath
    Assert-True ([bool]$envInfo.os -and [bool]$envInfo.ps_version -and ($envInfo.shell_exe -in @('powershell', 'pwsh')) -and [bool]$envInfo.shell_version -and $envInfo.workspace -eq (Get-Item -LiteralPath $workspacePath -Force).FullName) 'Get-AgentEnvironment did not return expected OS, PowerShell, shell, and workspace metadata.'
    $capWithEnv = Get-AgentCapabilities -Root $workspacePath
    Assert-True ($capWithEnv.environment.shell_exe -eq $envInfo.shell_exe -and $capWithEnv.environment.workspace -eq $envInfo.workspace) 'Get-AgentCapabilities did not include environment metadata.'

    $ignoreTestDir = Join-Path $workspacePath 'igtest'
    New-Item -ItemType Directory -Path (Join-Path $ignoreTestDir 'build') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ignoreTestDir 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ignoreTestDir '.gitignore') -Value @('# comment', 'build/', '*.log', '!keep.log') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $ignoreTestDir 'build\out.txt') -Value 'findme_ignored' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $ignoreTestDir 'debug.log') -Value 'findme_ignored' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $ignoreTestDir 'keep.log') -Value 'findme_kept' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $ignoreTestDir 'sub\q1.sql') -Value 'SELECT 1' -Encoding UTF8
    $call = @{ id = 'ig-find'; function = @{ name = 'find_files'; arguments = '{"path":"igtest","pattern":"*.log"}' } }
    $igFind = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($igFind.count -eq 1 -and $igFind.files[0].relative_path -eq 'keep.log') '.gitignore negation (!) in find_files failed.'
    $call = @{ id = 'ig-pathglob'; function = @{ name = 'find_files'; arguments = '{"path":"igtest","pattern":"sub/*.sql"}' } }
    $igPathGlob = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($igPathGlob.count -eq 1 -and $igPathGlob.files[0].relative_path -eq 'sub/q1.sql') 'Path glob (sub/*.sql) in find_files failed.'
    $call = @{ id = 'ig-grep'; function = @{ name = 'grep_files'; arguments = '{"path":"igtest","pattern":"findme_"}' } }
    $igGrep = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($igGrep.matches.Count -eq 1 -and $igGrep.matches[0].file -eq 'keep.log') '.gitignore filtering in grep_files failed.'
    Remove-Item -LiteralPath $ignoreTestDir -Recurse -Force

    # Parent directory .gitignore rules apply when searching from a child directory (path = "a/b").
    $dirA = Join-Path $workspacePath 'a'
    $dirAB = Join-Path $dirA 'b'
    New-Item -ItemType Directory -Path $dirAB -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dirA '.gitignore') -Value '*.log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dirAB 'private.log') -Value 'secret log token' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dirAB 'keep.txt') -Value 'public log token' -Encoding UTF8
    $findSubCall = @{ id = 'f-sub'; function = @{ name = 'find_files'; arguments = '{"path":"a/b","pattern":"*"}' } }
    $findSubRes = Invoke-AgentTool -Root $workspacePath -Call $findSubCall | ConvertFrom-Json
    $findSubPaths = @($findSubRes.matches | ForEach-Object { $_.path })
    Assert-True (($findSubPaths -contains 'a/b/keep.txt') -and (-not ($findSubPaths -contains 'a/b/private.log'))) 'Parent directory .gitignore was ignored when find_files started in a/b.'
    $grepSubCall = @{ id = 'g-sub'; function = @{ name = 'grep_files'; arguments = '{"path":"a/b","pattern":"token"}' } }
    $grepSubRes = Invoke-AgentTool -Root $workspacePath -Call $grepSubCall | ConvertFrom-Json
    $grepSubPaths = @($grepSubRes.matches | ForEach-Object { $_.path })
    Assert-True (($grepSubPaths -contains 'a/b/keep.txt') -and (-not ($grepSubPaths -contains 'a/b/private.log'))) 'Parent directory .gitignore was ignored when grep_files started in a/b.'

    # Combined regex segments (Compress-IgnoreRules) and directory pruning before entry (.venv / build).
    $pruneDir = Join-Path $workspacePath 'prunetest'
    $venvSub = Join-Path (Join-Path $pruneDir '.venv') 'lib\site-packages\pkg'
    $srcSub = Join-Path $pruneDir 'src'
    New-Item -ItemType Directory -Path $venvSub -Force | Out-Null
    New-Item -ItemType Directory -Path $srcSub -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pruneDir '.gitignore') -Value @('.venv/', '*.tmp', '*.bak') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path (Join-Path $pruneDir '.venv') '.gitignore') -Value '!leaked.py' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $venvSub 'leaked.py') -Value 'PRUNE_TOKEN_123' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $srcSub 'app.py') -Value 'PRUNE_TOKEN_123' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $srcSub 'scratch.tmp') -Value 'PRUNE_TOKEN_123' -Encoding UTF8
    $compressedRules = @(Get-WorkspaceIgnoreRules -Root $pruneDir -SearchPath $pruneDir)
    Assert-True ($compressedRules.Count -eq 1 -and $compressedRules[0].combined -eq $true) 'Positive-only .gitignore rules should be compressed into a single combined regex segment.'
    $pruneFindCall = @{ id = 'p-find'; function = @{ name = 'find_files'; arguments = '{"path":"prunetest","pattern":"*.py"}' } }
    $pruneFindRes = Invoke-AgentTool -Root $workspacePath -Call $pruneFindCall | ConvertFrom-Json
    Assert-True ($pruneFindRes.count -eq 1 -and $pruneFindRes.files[0].relative_path -eq 'src/app.py') 'Pruned directory .venv was entered during find_files.'
    $pruneGrepCall = @{ id = 'p-grep'; function = @{ name = 'grep_files'; arguments = '{"path":"prunetest","pattern":"PRUNE_TOKEN_123"}' } }
    $pruneGrepRes = Invoke-AgentTool -Root $workspacePath -Call $pruneGrepCall | ConvertFrom-Json
    Assert-True ($pruneGrepRes.matches.Count -eq 1 -and $pruneGrepRes.matches[0].file -eq 'src/app.py') 'Pruned directory .venv or ignored .tmp file was scanned during grep_files.'
    Remove-Item -LiteralPath $pruneDir -Recurse -Force

    # Subagent tool (run_agent): argument normalization, validation, depth guard, single, parallel, pipeline, and shared /undo.
    $normSub = Format-RunAgentArguments -ArgsObj ([pscustomobject]@{
        agent = 'scout'
        task = 'Find entrypoints'
        maxSteps = 8
        tasks = '[{"agent":"reviewer","task":"Audit code"}]'
    })
    Assert-True ($normSub.role -eq 'scout' -and $normSub.prompt -eq 'Find entrypoints' -and $normSub.max_steps -eq 8 -and $normSub.parallel[0].role -eq 'reviewer' -and $normSub.parallel[0].prompt -eq 'Audit code') 'Format-RunAgentArguments alias normalization failed.'

    $badSubBoth = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'sub-bad1'; function = @{ name = 'run_agent'; arguments = '{"prompt":"a","parallel":[{"prompt":"b"}]}' } } | ConvertFrom-Json
    Assert-True ($badSubBoth.error -like '*only one execution mode*') 'run_agent did not reject multiple execution modes.'
    $badSubNone = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'sub-bad2'; function = @{ name = 'run_agent'; arguments = '{"role":"recon"}' } } | ConvertFrom-Json
    Assert-True ($badSubNone.error -like '*requires one of*') 'run_agent did not reject missing execution mode.'
    $badSubForkPar = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'sub-bad3'; function = @{ name = 'run_agent'; arguments = '{"context":"fork","parallel":[{"prompt":"x"}]}' } } | ConvertFrom-Json
    Assert-True ($badSubForkPar.error -like '*cannot be ''fork'' when using parallel*') 'run_agent did not reject context=fork with parallel[].'

    # Depth guard hides run_agent inside subagents.
    $script:SubagentDepth = 1
    try {
        Assert-True (-not (Test-IsToolEnabled -Name 'run_agent')) 'run_agent must be disabled when SubagentDepth >= MaxSubagentDepth.'
        $blockedSub = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'sub-depth'; function = @{ name = 'run_agent'; arguments = '{"prompt":"nested"}' } } | ConvertFrom-Json
        Assert-True ($blockedSub.error -like '*disabled*') 'Nested run_agent call at depth 1 was not blocked.'
    }
    finally {
        $script:SubagentDepth = 0
    }

    # Single recon (clamped to ReadOnly), pipeline ({previous} -> craft edit), parallel fan-out, and unified /undo rollback.
    $script:AgentPermission = 'AutoEdit'
    $script:CurrentTurnWrites = @()
    Set-Content -LiteralPath (Join-Path $workspacePath 'sub-target.txt') -Value 'OLD_TOKEN' -Encoding UTF8 -NoNewline
    $script:subMockStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:subMockStep++
        $reqObj = $Body | ConvertFrom-Json
        $toolNamesInReq = @($reqObj.tools | ForEach-Object { $_.function.name })
        Assert-True ($toolNamesInReq -notcontains 'run_agent') 'Subagent request must not expose recursive run_agent tool.'
        if ($script:subMockStep -eq 1) {
            Assert-True ($toolNamesInReq -notcontains 'write_file') 'recon subagent must run in ReadOnly mode even when parent is AutoEdit.'
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'sr-1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"sub-target.txt"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:subMockStep -eq 2) {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Found OLD_TOKEN in sub-target.txt' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:subMockStep -eq 3) {
            Assert-True ($toolNamesInReq -contains 'edit_file') 'craft subagent in AutoEdit should have edit_file.'
            $userMsg = [string]$reqObj.messages[-1].content
            Assert-True ($userMsg.Contains('Found OLD_TOKEN in sub-target.txt')) 'Pipeline did not substitute {previous} output.'
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'sc-1'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"sub-target.txt","old_text":"OLD_TOKEN","new_text":"NEW_FROM_SUBAGENT"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:subMockStep -eq 4) {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Replaced token in sub-target.txt' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = "Parallel worker step $($script:subMockStep)" } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    try {
        $pipeCall = @{
            id = 'sub-pipe'
            function = @{
                name = 'subagent'
                arguments = '{"chain":[{"agent":"scout","task":"Inspect sub-target.txt"},{"agent":"worker","task":"Update based on: {previous}"}]}'
            }
        }
        $pipeRes = Invoke-AgentTool -Root $workspacePath -Call $pipeCall | ConvertFrom-Json
        Assert-True ($pipeRes.status -eq 'completed' -and $pipeRes.mode -eq 'pipeline' -and $pipeRes.steps_count -eq 2) 'Pipeline run_agent execution failed.'
        Assert-True ($pipeRes.output -eq 'Replaced token in sub-target.txt' -and ($pipeRes.modified_files -contains 'sub-target.txt')) 'Pipeline did not report output or modified_files.'
        Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'sub-target.txt') -Raw -Encoding UTF8) -eq 'NEW_FROM_SUBAGENT') 'Subagent edit was not written to disk.'

        # Parent /undo reverts the subagent's file modification.
        $subUndoState = @{ messages = @(@{ role = 'system'; content = 'sys' }) }
        Invoke-AgentUndo -State $subUndoState -UndoEntry @{ messages = @(@{ role = 'system'; content = 'sys' }); writes = @($script:CurrentTurnWrites) }
        Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'sub-target.txt') -Raw -Encoding UTF8) -eq 'OLD_TOKEN') 'Parent /undo did not revert subagent file edit.'

        $parCall = @{
            id = 'sub-par'
            function = @{
                name = 'run_agent'
                arguments = '{"parallel":[{"role":"recon","prompt":"Check A"},{"role":"audit","prompt":"Check B"}]}'
            }
        }
        $parRes = Invoke-AgentTool -Root $workspacePath -Call $parCall | ConvertFrom-Json
        Assert-True ($parRes.status -eq 'completed' -and $parRes.mode -eq 'parallel' -and $parRes.tasks_count -eq 2 -and $parRes.output.Contains('Task 1 (recon)') -and $parRes.output.Contains('Task 2 (audit)')) 'Parallel run_agent execution failed.'

        # Regression (Item 8d): parallel and pipeline propagate non-completed statuses (step_limit_reached, loop_detected, error).
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'sl-1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $parLimitRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-par-lim'
            function = @{ name = 'run_agent'; arguments = '{"max_steps":1,"parallel":[{"role":"recon","prompt":"Hit step limit"}]}' }
        } | ConvertFrom-Json
        Assert-True ($parLimitRes.status -eq 'step_limit_reached') "Expected parallel status=step_limit_reached when child task hit step limit, got $($parLimitRes.status)."

        $pipeLoopRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-pipe-loop'
            function = @{ name = 'run_agent'; arguments = '{"max_steps":10,"pipeline":[{"role":"recon","prompt":"Hit loop"}]}' }
        } | ConvertFrom-Json
        Assert-True ($pipeLoopRes.status -eq 'loop_detected') "Expected pipeline status=loop_detected when child step hit loop, got $($pipeLoopRes.status)."

        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            throw 'Child subagent failure'
        }
        $parErrRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-par-err'
            function = @{ name = 'run_agent'; arguments = '{"parallel":[{"role":"recon","prompt":"Fail task"}]}' }
        } | ConvertFrom-Json
        Assert-True ($parErrRes.status -eq 'error') "Expected parallel status=error when child task threw error, got $($parErrRes.status)."
        $parChild = $parErrRes.results[0]
        Assert-True ($parChild.role -eq 'recon' -and $parChild.permission -eq 'ReadOnly' -and $parChild.context -eq 'clean' -and $parChild.status -eq 'error') 'Parallel in-process error result did not keep role, ReadOnly permission, clean context, and error status.'
        Assert-True ($parChild.output -eq 'Subagent error: Child subagent failure') "Parallel error output prefix changed: $($parChild.output)"
        Assert-True ([int]$parChild.steps_used -eq 0 -and [int]$parChild.usage_input_tokens -eq 0 -and [int]$parChild.usage_output_tokens -eq 0) 'Parallel error result did not zero steps and usage.'
        Assert-True ($parChild.read_files -is [array] -and $parChild.read_files.Count -eq 0 -and $parChild.modified_files -is [array] -and $parChild.modified_files.Count -eq 0) 'Parallel error result file lists were not empty arrays.'

        $pipeErrRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-pipe-err'
            function = @{ name = 'run_agent'; arguments = '{"pipeline":[{"role":"recon","prompt":"Fail step 1"},{"role":"recon","prompt":"Should not run"}]}' }
        } | ConvertFrom-Json
        Assert-True ($pipeErrRes.status -eq 'error' -and $pipeErrRes.steps_count -eq 1) "Expected pipeline status=error and early stop when step 1 failed, got status=$($pipeErrRes.status) steps=$($pipeErrRes.steps_count)."
        $pipeChild = $pipeErrRes.results[0]
        Assert-True ($pipeChild.role -eq 'recon' -and $pipeChild.permission -eq 'AutoEdit' -and $pipeChild.context -eq 'clean' -and $pipeChild.status -eq 'error') 'Pipeline error result did not pass the current AutoEdit permission and clean step context.'
        Assert-True ($pipeChild.output -eq 'Subagent error: Child subagent failure') "Pipeline error output prefix changed: $($pipeChild.output)"
        Assert-True ([int]$pipeChild.steps_used -eq 0 -and [int]$pipeChild.usage_input_tokens -eq 0 -and [int]$pipeChild.usage_output_tokens -eq 0) 'Pipeline error result did not zero steps and usage.'
        Assert-True ($pipeChild.read_files -is [array] -and $pipeChild.read_files.Count -eq 0 -and $pipeChild.modified_files -is [array] -and $pipeChild.modified_files.Count -eq 0) 'Pipeline error result file lists were not empty arrays.'

        $script:AgentPermission = 'Ask'
        $pipeForkRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-pipe-err-fork'
            function = @{ name = 'run_agent'; arguments = '{"pipeline":[{"role":"audit","prompt":"Fail fork step","context":"fork"}]}' }
        } | ConvertFrom-Json
        $pipeForkChild = $pipeForkRes.results[0]
        Assert-True ($pipeForkRes.status -eq 'error' -and $pipeForkRes.steps_count -eq 1) 'Pipeline fork error did not stop at the failing step.'
        Assert-True ($pipeForkChild.role -eq 'audit' -and $pipeForkChild.permission -eq 'Ask' -and $pipeForkChild.context -eq 'fork' -and $pipeForkChild.output -eq 'Subagent error: Child subagent failure') 'Pipeline error result did not pass the current permission and step context.'
        $script:AgentPermission = 'AutoEdit'

        $directErr = @(New-SubagentErrorResult -Role 'recon' -Context 'clean' -Message 'Child subagent failure')
        Assert-True ($directErr.Count -eq 1) 'New-SubagentErrorResult unrolled its result.'
        $directOne = $directErr[0]
        $directKeys = @($directOne.Keys | Sort-Object) -join ','
        Assert-True ($directKeys -eq 'context,modified_files,output,permission,read_files,role,status,steps_used,usage_input_tokens,usage_output_tokens') "New-SubagentErrorResult keys changed: $directKeys"
        Assert-True ($directOne.permission -eq 'ReadOnly' -and $directOne.status -eq 'error' -and $directOne.output -eq 'Subagent error: Child subagent failure' -and $directOne.steps_used -eq 0 -and $directOne.usage_input_tokens -eq 0 -and $directOne.usage_output_tokens -eq 0) 'New-SubagentErrorResult default shape changed.'
        Assert-True ($directOne.read_files -is [array] -and $directOne.read_files.Count -eq 0 -and $directOne.modified_files -is [array] -and $directOne.modified_files.Count -eq 0) 'New-SubagentErrorResult did not return real empty arrays.'
        $explicitErr = New-SubagentErrorResult -Role 'audit' -Context 'fork' -Message 'Child subagent failure' -Permission 'Ask'
        Assert-True ($explicitErr.role -eq 'audit' -and $explicitErr.permission -eq 'Ask' -and $explicitErr.context -eq 'fork' -and $explicitErr.output -eq 'Subagent error: Child subagent failure') 'New-SubagentErrorResult did not keep explicit permission and context.'

        $slowWorkerScript = Join-Path $testRoot 'slow-subagent.ps1'
        Set-Content -LiteralPath $slowWorkerScript -Value 'param([Parameter(ValueFromRemainingArguments = $true)]$Remaining) Start-Sleep -Seconds 30' -Encoding Ascii
        $timedOutResults = @(Invoke-ParallelSubagentProcesses -Root $workspacePath -Tasks @(@{ role = 'recon'; prompt = 'Slow task' }) -ScriptPath $slowWorkerScript -TimeoutSec 1)
        Assert-True ($timedOutResults.Count -eq 1 -and $timedOutResults[0].status -eq 'timed_out' -and $timedOutResults[0].output -eq 'Subagent timed out after 1s.') "Expected timed_out status and timeout message from Invoke-ParallelSubagentProcesses, got status=$($timedOutResults[0].status) output=$($timedOutResults[0].output)."
        Assert-True ((Resolve-SubagentAggregateStatus -Results $timedOutResults) -eq 'timed_out') 'Resolve-SubagentAggregateStatus did not return timed_out.'
        Assert-True ((Resolve-SubagentAggregateStatus -Results @(@{ status = 'completed' }, @{ status = 'step_limit_reached' }, @{ status = 'timed_out' })) -eq 'timed_out') 'Resolve-SubagentAggregateStatus did not prioritize timed_out above step_limit_reached.'
        Assert-True ((Resolve-SubagentAggregateStatus -Results @(@{ status = 'timed_out' }, @{ status = 'error' })) -eq 'error') 'Resolve-SubagentAggregateStatus did not prioritize error above timed_out.'
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        $script:AgentPermission = 'Ask'
    }

    # TUI tool card and unified diff rendering in text mode.
    $script:tuiCaptured = @()
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        $script:tuiCaptured += (Strip-AnsiCodes -Text $text)
    }
    try {
        $script:OutputMode = 'text'
        $script:AgentPermission = 'AutoEdit'
        Set-Content -LiteralPath (Join-Path $workspacePath 'tui-diff.txt') -Value "alpha`nbeta`ngamma" -Encoding UTF8 -NoNewline
        $null = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'tui-r'; function = @{ name = 'read_file'; arguments = '{"path":"tui-diff.txt"}' } }
        $null = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'tui-e'; function = @{ name = 'edit_file'; arguments = '{"path":"tui-diff.txt","old_text":"beta","new_text":"BETA_NEW"}' } }
        $joinedTui = $script:tuiCaptured -join "`n"
        Assert-True ($joinedTui.Contains('read_file') -and $joinedTui.Contains('3 lines')) "Expected TUI tool card for read_file, got: $joinedTui"
        Assert-True ($joinedTui.Contains('DIFF edit_file: tui-diff.txt +1 -1') -and $joinedTui.Contains('- beta') -and $joinedTui.Contains('+ BETA_NEW')) "Expected unified diff card for edit_file, got: $joinedTui"
    }
    finally {
        $script:AgentPermission = 'Ask'
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
    }

    # Web tools: fetch_url (HTML stripping, entity decoding, scheme guard) and web_search.
    Assert-True ((ConvertTo-UrlEncodedString -Text 'a b?') -eq 'a+b%3F') 'ConvertTo-UrlEncodedString failed.'
    $supplementary = ([string][char]0xD83D) + ([string][char]0xDE00)
    Assert-True ((ConvertTo-UrlEncodedString -Text $supplementary) -eq '%F0%9F%98%80') 'Search Unicode surrogate encoding failed.'
    $badSurrogateRejected = $false
    try { $null = ConvertTo-UrlEncodedString -Text ([string][char]0xD83D) } catch { $badSurrogateRejected = $true }
    Assert-True $badSurrogateRejected 'An invalid Unicode surrogate was accepted.'
    $cleanHtml = ConvertFrom-HtmlToText -Html '<html><head><style>body{}</style><script>alert(1)</script></head><body><h1>Title</h1><p>Hello &amp; world</p></body></html>'
    Assert-True ($cleanHtml.Contains('Title') -and $cleanHtml.Contains('Hello & world') -and (-not $cleanHtml.Contains('alert(1)'))) "ConvertFrom-HtmlToText unexpected: $cleanHtml"

    $badSchemeRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-bad'; function = @{ name = 'fetch_url'; arguments = '{"url":"file:///etc/passwd"}' } } | ConvertFrom-Json
    Assert-True ($badSchemeRes.error -like '*http*') 'fetch_url must reject non-http/https URLs.'

    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        if ($Uri -like '*duckduckgo*') {
            $ddgHtml = '<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs">Example Docs</a><a class="result__snippet">Official documentation snippet.</a></div>'
            Set-Content -LiteralPath $OutFile -Value $ddgHtml -Encoding UTF8 -NoNewline
        }
        else {
            $pageHtml = '<html><body><h1>Guide</h1><p>PowerShell 5.1 guide text.</p></body></html>'
            Set-Content -LiteralPath $OutFile -Value $pageHtml -Encoding UTF8 -NoNewline
        }
    }
    try {
        $fetchRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-fetch'; function = @{ name = 'fetch_url'; arguments = '{"url":"https://example.com/docs"}' } } | ConvertFrom-Json
        Assert-True ($fetchRes.url -eq 'https://example.com/docs' -and $fetchRes.content.Contains('PowerShell 5.1 guide text.')) 'fetch_url failed to return cleaned page content.'

        $searchRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-search'; function = @{ name = 'web_search'; arguments = '{"query":"powershell 5.1","limit":5}' } } | ConvertFrom-Json
        Assert-True ($searchRes.count -eq 1 -and $searchRes.results[0].title -eq 'Example Docs' -and $searchRes.results[0].url -eq 'https://example.com/docs') 'web_search failed to parse search results.'

        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            Set-Content -LiteralPath $OutFile -Value ('a' * 2100000) -Encoding UTF8 -NoNewline
        }
        $largeFetch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-large'; function = @{ name = 'fetch_url'; arguments = '{"url":"https://example.com/large"}' } } | ConvertFrom-Json
        Assert-True ($largeFetch.error -like '*exceeds*') 'fetch_url accepted an oversized response.'
        $largeSearch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 's-large'; function = @{ name = 'web_search'; arguments = '{"query":"large"}' } } | ConvertFrom-Json
        Assert-True ($largeSearch.error -like '*exceeds*') 'web_search accepted an oversized response.'

        # Regression (Item 12a): Invoke-AgentWebDownload propagates HTTP/network failure reason instead of blind 'Web request failed.'
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            throw 'Response status code does not indicate success: 404 (Not Found).'
        }
        $errFetch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-404'; function = @{ name = 'fetch_url'; arguments = '{"url":"https://example.com/missing"}' } } | ConvertFrom-Json
        Assert-True ($errFetch.error -like '*404*' -and $errFetch.error -like '*Not Found*') 'fetch_url did not surface HTTP 404 failure details.'

        # Regression (Item 12b): ConvertFrom-UrlEncodedString decodes multi-byte UTF-8 (Cyrillic and 4-byte UTF-8) in URLs and web_search results.
        $expectedCyrillicWord = ([string][char]0x0447) + ([string][char]0x0442) + ([string][char]0x043E) + '?'
        $decodedCyrUrl = ConvertFrom-UrlEncodedString -Text 'https%3A%2F%2Fru.wikipedia.org%2Fwiki%2F%D1%87%D1%82%D0%BE%3F'
        Assert-True ($decodedCyrUrl -eq ('https://ru.wikipedia.org/wiki/' + $expectedCyrillicWord)) 'ConvertFrom-UrlEncodedString failed to decode Cyrillic UTF-8 percent-encoded URL.'
        $expectedEmoji = ([string][char]0xD83D) + ([string][char]0xDE00)
        $decodedEmoji = ConvertFrom-UrlEncodedString -Text 'https://example.com/%F0%9F%98%80'
        Assert-True ($decodedEmoji -eq ('https://example.com/' + $expectedEmoji)) 'ConvertFrom-UrlEncodedString failed to decode 4-byte UTF-8 sequence into surrogate pair.'

        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $ddgUtf8Html = '<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fru.wikipedia.org%2Fwiki%2F%D1%87%D1%82%D0%BE%3F">Wiki Article</a><a class="result__snippet">UTF-8 snippet.</a></div>'
            Set-Content -LiteralPath $OutFile -Value $ddgUtf8Html -Encoding UTF8 -NoNewline
        }
        $utf8SearchRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-search-utf8'; function = @{ name = 'web_search'; arguments = '{"query":"utf8 test","limit":5}' } } | ConvertFrom-Json
        Assert-True ($utf8SearchRes.count -eq 1 -and $utf8SearchRes.results[0].url -eq ('https://ru.wikipedia.org/wiki/' + $expectedCyrillicWord)) 'web_search corrupted multi-byte UTF-8 URL in DuckDuckGo redirect.'
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    }

    # Regression (Item 12c): SSRF protection blocks localhost, loopback, link-local metadata, private IPv4/IPv6, and obfuscated numeric IPs.
    foreach ($unsafeUrl in @(
        'http://localhost/admin',
        'http://localhost:8080/api',
        'http://sub.localhost/test',
        'http://127.0.0.1:9000/health',
        'http://169.254.169.254/latest/meta-data/',
        'http://10.0.0.1/internal',
        'http://172.16.0.1/secret',
        'http://172.31.255.254/secret',
        'http://192.168.1.1/router',
        'http://[::1]:8080/loopback',
        'http://[fe80::1]/linklocal',
        'http://[fd00::1]/ula',
        'http://2130706433/decimal-loopback',
        'http://0x7f000001/hex-loopback',
        'http://0177.0.0.1/octal-loopback',
        'http://metadata.google.internal/computeMetadata/v1/'
    )) {
        $ssrfThrew = $false
        try {
            $null = Test-SafeWebUrl -Url $unsafeUrl
        }
        catch {
            $ssrfThrew = $true
        }
        Assert-True $ssrfThrew "Test-SafeWebUrl failed to block unsafe SSRF URL: $unsafeUrl"
        $ssrfFetch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-ssrf'; function = @{ name = 'fetch_url'; arguments = (@{ url = $unsafeUrl } | ConvertTo-Json -Compress) } } | ConvertFrom-Json
        Assert-True ($null -ne $ssrfFetch.error -and $ssrfFetch.error.Length -gt 0) "fetch_url did not block unsafe SSRF URL: $unsafeUrl"
    }

    # Regression (Item 12d): fetch_url and web_search require confirmation in Ask and ReadOnly modes, and cancel in non-interactive JSON mode.
    $savedApprovalWeb = $script:approval
    $savedPermWeb = $script:AgentPermission
    $savedModeWeb = $script:OutputMode
    try {
        $script:approval = 'n'
        $script:AgentPermission = 'Ask'
        $askCancelFetch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-ask-no'; function = @{ name = 'fetch_url'; arguments = '{"url":"https://example.com/docs"}' } } | ConvertFrom-Json
        Assert-True ($askCancelFetch.status -eq 'cancelled') 'fetch_url in Ask mode did not cancel when declined.'
        $askCancelSearch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 's-ask-no'; function = @{ name = 'web_search'; arguments = '{"query":"powershell"}' } } | ConvertFrom-Json
        Assert-True ($askCancelSearch.status -eq 'cancelled') 'web_search in Ask mode did not cancel when declined.'

        $script:AgentPermission = 'ReadOnly'
        $roCancelFetch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-ro-no'; function = @{ name = 'fetch_url'; arguments = '{"url":"https://example.com/docs"}' } } | ConvertFrom-Json
        Assert-True ($roCancelFetch.status -eq 'cancelled') 'fetch_url in ReadOnly mode did not require confirmation.'

        $script:AgentPermission = 'Ask'
        $script:OutputMode = 'json'
        $script:approval = $null
        $jsonCancelFetch = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'w-json-no'; function = @{ name = 'fetch_url'; arguments = '{"url":"https://example.com/docs"}' } } | ConvertFrom-Json
        Assert-True ($jsonCancelFetch.status -eq 'cancelled') 'fetch_url in JSON mode under Ask permission did not cancel immediately.'
    }
    finally {
        $script:approval = $savedApprovalWeb
        $script:AgentPermission = $savedPermWeb
        $script:OutputMode = $savedModeWeb
    }

    # Todo tool: aliases, argument normalization, validation, and checklist execution.
    Assert-True ((Resolve-ToolCanonicalName -Name 'manage_todo') -eq 'todo') 'Resolve-ToolCanonicalName manage_todo alias failed.'
    Assert-True ((Resolve-ToolCanonicalName -Name 'todos') -eq 'todo') 'Resolve-ToolCanonicalName todos alias failed.'
    Assert-True ((Resolve-ToolCanonicalName -Name 'tasks') -eq 'todo') 'Resolve-ToolCanonicalName tasks alias failed.'
    Assert-True ((Resolve-ToolCanonicalName -Name 'task_board') -eq 'todo') 'Resolve-ToolCanonicalName task_board alias failed.'

    $normTodoArgs = Format-TodoArguments -Arguments ([pscustomobject]@{ tasks = '[{"title":"Step 1","done":true},{"task":"Step 2","status":"in_progress"},{"text":"Step 3","status":"pending"}]' })
    Assert-True ($normTodoArgs.todos.Count -eq 3 -and $normTodoArgs.todos[0].content -eq 'Step 1' -and $normTodoArgs.todos[0].status -eq 'completed' -and $normTodoArgs.todos[1].content -eq 'Step 2' -and $normTodoArgs.todos[2].content -eq 'Step 3') 'Format-TodoArguments normalization failed.'

    $todoCall = @{
        id = 'td-1'
        function = @{
            name = 'todo'
            arguments = '{"todos":[{"content":"Setup environment","status":"completed"},{"content":"Implement feature","status":"in_progress"},{"content":"Add unit tests","status":"pending"}]}'
        }
    }
    $todoRes = Invoke-AgentTool -Root $workspacePath -Call $todoCall | ConvertFrom-Json
    Assert-True ($todoRes.success -and $todoRes.total -eq 3 -and $todoRes.completed -eq 1 -and $todoRes.in_progress -eq 1 -and $todoRes.pending -eq 1) 'Invoke-AgentTool todo execution failed.'
    Assert-True ($script:ActiveSessionTodos.Count -eq 3 -and $script:ActiveSessionTodos[0].content -eq 'Setup environment' -and $script:ActiveSessionTodos[0].status -eq 'completed') 'Invoke-AgentTool did not update $script:ActiveSessionTodos.'

    $badTodoCall = @{ id = 'td-bad'; function = @{ name = 'todo'; arguments = '{"todos":[{"content":"","status":"pending"}]}' } }
    $badTodoRes = Invoke-AgentTool -Root $workspacePath -Call $badTodoCall | ConvertFrom-Json
    Assert-True ($badTodoRes.error -like '*content*') 'todo tool did not reject empty content.'

    $badStatusCall = @{ id = 'td-bad-st'; function = @{ name = 'todo'; arguments = '{"todos":[{"content":"Valid task","status":"invalid_status"}]}' } }
    $badStatusRes = Invoke-AgentTool -Root $workspacePath -Call $badStatusCall | ConvertFrom-Json
    Assert-True ($badStatusRes.error -like '*status*') 'todo tool did not reject invalid status.'

    # Ask_user tool: aliases, argument normalization, plan-review approval, questions, and custom free text.
    Assert-True ((Resolve-ToolCanonicalName -Name 'ask') -eq 'ask_user') 'Resolve-ToolCanonicalName ask alias failed.'
    Assert-True ((Resolve-ToolCanonicalName -Name 'ask_user_question') -eq 'ask_user') 'Resolve-ToolCanonicalName ask_user_question alias failed.'
    Assert-True ((Resolve-ToolCanonicalName -Name 'plan_review') -eq 'ask_user') 'Resolve-ToolCanonicalName plan_review alias failed.'
    Assert-True ((Resolve-ToolCanonicalName -Name 'question') -eq 'ask_user') 'Resolve-ToolCanonicalName question alias failed.'

    $normAskQuestion = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Which framework?'; options = @('Pester 4', 'Pester 5') })
    Assert-True ($normAskQuestion.question -eq 'Which framework?' -and $normAskQuestion.intent -eq 'question' -and $normAskQuestion.options.Count -eq 2 -and $normAskQuestion.options[0].label -eq 'Pester 4' -and $normAskQuestion.allow_custom) 'Format-AskUserArguments question normalization failed.'

    $normPlanArgs = Format-AskUserArguments -Arguments ([pscustomobject]@{ prompt = 'Review refactor'; plan = "# Plan`n1. Do refactor" })
    Assert-True ($normPlanArgs.question -eq 'Review refactor' -and $normPlanArgs.intent -eq 'plan-review' -and $normPlanArgs.options.Count -eq 3 -and $normPlanArgs.options[0].value -eq 'Approve') 'Format-AskUserArguments plan-review default options failed.'

    $norm = Format-AskUserArguments -Arguments ([pscustomobject]@{
        question = 'Ship it?'
        plan_review = 'Do A then B'
    })
    Assert-True ($norm.intent -eq 'plan-review' -and $norm.plan -eq 'Do A then B') 'plan_review text was dropped.'

    $normPlanReview = Format-AskUserArguments -Arguments ([pscustomobject]@{
        question = 'Ship it?'
        planReview = 'Do A then B'
    })
    Assert-True ($normPlanReview.intent -eq 'plan-review' -and $normPlanReview.plan -eq 'Do A then B') 'planReview text was dropped.'

    $normPlanWins = Format-AskUserArguments -Arguments ([pscustomobject]@{
        question = 'Ship it?'
        plan = 'Original plan'
        plan_review = 'Do A then B'
    })
    Assert-True ($normPlanWins.intent -eq 'plan-review' -and $normPlanWins.plan -eq 'Original plan') 'plan lost to plan_review.'

    # A non-array options value must survive so the validator can reject it.
    $norm = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = 123 })
    $threw = $false
    $throwText = ''
    try { Test-AgentToolArguments -Name 'ask_user' -Arguments $norm } catch { $threw = $true; $throwText = [string]$_.Exception.Message }
    Assert-True ($threw) 'options=123 was rewritten into Yes/No and passed validation.'
    Assert-True ($throwText -eq "Argument 'options' must be an array.") "options=123 validation error was: $throwText"

    $normFalseOpt = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = $false })
    $threwFalseOpt = $false
    $throwTextFalse = ''
    try { Test-AgentToolArguments -Name 'ask_user' -Arguments $normFalseOpt } catch { $threwFalseOpt = $true; $throwTextFalse = [string]$_.Exception.Message }
    Assert-True ($threwFalseOpt) 'options=$false was rewritten into Yes/No and passed validation.'
    Assert-True ($throwTextFalse -eq "Argument 'options' must be an array.") "options=`$false validation error was: $throwTextFalse"

    # A JSON string of a scalar parses to a ValueType. It must stay a ValueType so validation rejects it.
    foreach ($badOpt in @('false', '123', 'true', '0')) {
        $normBadStr = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = $badOpt })
        $threwBadStr = $false
        $throwBadStr = ''
        try { Test-AgentToolArguments -Name 'ask_user' -Arguments $normBadStr } catch { $threwBadStr = $true; $throwBadStr = [string]$_.Exception.Message }
        Assert-True ($threwBadStr) "options='$badOpt' was rewritten into Yes/No and passed validation."
        Assert-True ($throwBadStr -eq "Argument 'options' must be an array.") "options='$badOpt' validation error was: $throwBadStr"
    }

    $normJsonOpt = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = '["A","B"]' })
    Assert-True ($normJsonOpt.options.Count -eq 2 -and $normJsonOpt.options[0].label -eq 'A' -and $normJsonOpt.options[1].value -eq 'B') 'JSON options array string was not normalized.'

    $normJsonObj = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = '{"label":"Ship"}' })
    Assert-True ($normJsonObj.options.Count -eq 1 -and $normJsonObj.options[0].label -eq 'Ship' -and $normJsonObj.options[0].value -eq 'Ship') 'JSON options object string was not normalized.'

    $normEmptyArr = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = '[]' })
    Assert-True ($normEmptyArr.options.Count -eq 2 -and $normEmptyArr.options[0].value -eq 'Yes' -and $normEmptyArr.options[1].value -eq 'No') 'Empty JSON options array did not become Yes/No.'

    $normEmptyPlan = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; intent = 'plan-review'; options = '[]' })
    Assert-True ($normEmptyPlan.options.Count -eq 3 -and $normEmptyPlan.options[0].value -eq 'Approve') 'Empty JSON options array did not use plan-review defaults.'

    $normLabelOpt = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; options = ([pscustomobject]@{ label = 'Ship' }) })
    Assert-True ($normLabelOpt.options.Count -eq 1 -and $normLabelOpt.options[0].label -eq 'Ship' -and $normLabelOpt.options[0].value -eq 'Ship') 'Single labeled options object was not normalized.'

    $normOmitOpt = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q' })
    Assert-True ($normOmitOpt.intent -eq 'question' -and $normOmitOpt.options.Count -eq 2 -and $normOmitOpt.options[0].value -eq 'Yes' -and $normOmitOpt.options[1].value -eq 'No') 'Omitted options did not become Yes/No.'

    $normOmitPlanOpt = Format-AskUserArguments -Arguments ([pscustomobject]@{ question = 'Q'; intent = 'plan-review' })
    Assert-True ($normOmitPlanOpt.intent -eq 'plan-review' -and $normOmitPlanOpt.options.Count -eq 3 -and $normOmitPlanOpt.options[0].value -eq 'Approve' -and $normOmitPlanOpt.options[1].value -eq 'Revise' -and $normOmitPlanOpt.options[2].value -eq 'Decline') 'Omitted plan-review options did not use the plan-review defaults.'

    # Test execution: plan approval by index '1'
    $script:approval = '1'
    $planCall = @{
        id = 'ask-plan-1'
        function = @{
            name = 'ask_user'
            arguments = '{"question":"Approve refactoring plan?","intent":"plan-review","plan":"# Refactor Plan\n1. Add tests\n2. Modify src"}'
        }
    }
    $planRes = Invoke-AgentTool -Root $workspacePath -Call $planCall | ConvertFrom-Json
    Assert-True ($planRes.question -eq 'Approve refactoring plan?' -and $planRes.intent -eq 'plan-review' -and $planRes.approved -and $planRes.answer -eq 'Approve' -and (-not $planRes.cancelled)) 'ask_user plan approval failed.'

    # Test execution: choice by label
    $script:approval = 'Pester 5'
    $qCall = @{
        id = 'ask-q-1'
        function = @{
            name = 'ask_user'
            arguments = '{"question":"Select test framework","options":["Pester 4","Pester 5"]}'
        }
    }
    $qRes = Invoke-AgentTool -Root $workspacePath -Call $qCall | ConvertFrom-Json
    Assert-True ($qRes.answer -eq 'Pester 5' -and (-not $qRes.approved) -and (-not $qRes.cancelled)) 'ask_user question choice failed.'

    # Test execution: select 'Other' option by number (3) and provide custom response
    $script:approval = @('3', 'Mocha')
    $qOtherCall = @{
        id = 'ask-q-other'
        function = @{
            name = 'ask_user'
            arguments = '{"question":"Select test framework","options":["Pester 4","Pester 5"]}'
        }
    }
    $qOtherRes = Invoke-AgentTool -Root $workspacePath -Call $qOtherCall | ConvertFrom-Json
    Assert-True ($qOtherRes.answer -eq 'Mocha' -and $qOtherRes.custom -eq 'Mocha' -and (-not $qOtherRes.approved) -and (-not $qOtherRes.cancelled)) 'ask_user Other choice failed.'

    # Test execution: custom free-text feedback
    $script:approval = 'Please add backward compatibility'
    $customCall = @{
        id = 'ask-custom-1'
        function = @{
            name = 'ask_user'
            arguments = '{"question":"Approve changes?","intent":"plan-review"}'
        }
    }
    $customRes = Invoke-AgentTool -Root $workspacePath -Call $customCall | ConvertFrom-Json
    Assert-True ($customRes.custom -eq 'Please add backward compatibility' -and (-not $customRes.approved) -and (-not $customRes.cancelled)) 'ask_user custom feedback failed.'

    # Test execution: cancel on empty input
    $script:approval = ''
    $cancelCall = @{
        id = 'ask-cancel-1'
        function = @{
            name = 'ask_user'
            arguments = '{"question":"Continue?"}'
        }
    }
    $cancelRes = Invoke-AgentTool -Root $workspacePath -Call $cancelCall | ConvertFrom-Json
    Assert-True ($cancelRes.cancelled -and $null -eq $cancelRes.answer) 'ask_user cancellation failed.'

    # Validation: empty question rejected
    $badAskCall = @{ id = 'ask-bad'; function = @{ name = 'ask_user'; arguments = '{"question":""}' } }
    $badAskRes = Invoke-AgentTool -Root $workspacePath -Call $badAskCall | ConvertFrom-Json
    Assert-True ($badAskRes.error -like '*question*') 'ask_user tool did not reject empty question.'

    # Regression: ask_user in -Mode json must return status=cancelled immediately without calling Read-Host.
    $prevModeAsk = $script:OutputMode
    $script:OutputMode = 'json'
    $savedApprovalAsk = $script:approval
    $script:approval = $null
    try {
        $jsonAskRes = Invoke-AgentTool -Root $workspacePath -Call $cancelCall | ConvertFrom-Json
        Assert-True ($jsonAskRes.status -eq 'cancelled' -and $jsonAskRes.cancelled -and (-not $jsonAskRes.approved) -and $null -eq $jsonAskRes.answer) 'ask_user in JSON mode did not cancel immediately.'
    }
    finally {
        $script:OutputMode = $prevModeAsk
        $script:approval = $savedApprovalAsk
    }

    # memory tool tests
    Assert-True ((Resolve-ToolCanonicalName 'memory') -eq 'memory') 'Canonical memory name resolution failed.'
    Assert-True ((Resolve-ToolCanonicalName 'remember') -eq 'memory') 'Canonical remember alias resolution failed.'
    Assert-True ((Resolve-ToolCanonicalName 'manage_memory') -eq 'memory') 'Canonical manage_memory alias resolution failed.'
    Assert-True ((Resolve-ToolCanonicalName 'recall') -eq 'memory') 'Canonical recall alias resolution failed.'

    $memNorm = Format-MemoryArguments -ArgsObj ([pscustomobject]@{ note = 'Use UTF-8'; action = 'APPEND'; scope = 'WORKSPACE' })
    Assert-True ($memNorm.action -eq 'append' -and $memNorm.scope -eq 'workspace' -and $memNorm.content -eq 'Use UTF-8') 'Format-MemoryArguments normalization failed.'

    # view/clear switch the action only for $true or the strings true and 1. [bool]"false" is $true in PowerShell.
    $onlyFalse = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 'false' })
    Assert-True ($onlyFalse.action -eq 'append') 'view="false" became a view action.'
    $onlyTrue = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 'true' })
    Assert-True ($onlyTrue.action -eq 'view') 'view="true" did not select view.'
    $withAction = Format-MemoryArguments -Arguments ([pscustomobject]@{ action = 'save'; view = 'false' })
    Assert-True ($withAction.action -eq 'save') 'an explicit action was overwritten.'
    $saveRejected = $false
    $saveRejectText = ''
    try { Test-AgentToolArguments -Name 'memory' -Arguments $withAction } catch { $saveRejected = $true; $saveRejectText = [string]$_.Exception.Message }
    Assert-True $saveRejected 'action save became legal.'
    Assert-True ($saveRejectText -eq "action must be 'append', 'view', 'set', or 'clear'.") "action save validation error was: $saveRejectText"
    $viewZero = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = '0' })
    Assert-True ($viewZero.action -eq 'append') 'view="0" became a view action.'
    $viewOne = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = '1' })
    Assert-True ($viewOne.action -eq 'view') 'view="1" did not select view.'
    $viewFalseBool = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = $false })
    Assert-True ($viewFalseBool.action -eq 'append') 'view=$false became a view action.'
    $viewTrueBool = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = $true })
    Assert-True ($viewTrueBool.action -eq 'view') 'view=$true did not select view.'
    $viewIntOne = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 1 })
    Assert-True ($viewIntOne.action -eq 'append') 'view=1 (integer) became a view action.'
    $viewIntZero = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 0 })
    Assert-True ($viewIntZero.action -eq 'append') 'view=0 (integer) became a view action.'
    $viewUpper = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 'TRUE' })
    Assert-True ($viewUpper.action -eq 'view') 'view="TRUE" did not select view.'
    $viewMixedFalse = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 'False' })
    Assert-True ($viewMixedFalse.action -eq 'append') 'view="False" became a view action.'
    $clearFalse = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = 'false' })
    Assert-True ($clearFalse.action -eq 'append') 'clear="false" became a clear action.'
    $clearTrue = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = 'true' })
    Assert-True ($clearTrue.action -eq 'clear') 'clear="true" did not select clear.'
    $clearZero = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = '0' })
    Assert-True ($clearZero.action -eq 'append') 'clear="0" became a clear action.'
    $clearOne = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = '1' })
    Assert-True ($clearOne.action -eq 'clear') 'clear="1" did not select clear.'
    $clearFalseBool = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = $false })
    Assert-True ($clearFalseBool.action -eq 'append') 'clear=$false became a clear action.'
    $clearTrueBool = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = $true })
    Assert-True ($clearTrueBool.action -eq 'clear') 'clear=$true did not select clear.'
    $clearUpper = Format-MemoryArguments -Arguments ([pscustomobject]@{ clear = 'TRUE' })
    Assert-True ($clearUpper.action -eq 'clear') 'clear="TRUE" did not select clear.'
    $explicitOverTrue = Format-MemoryArguments -Arguments ([pscustomobject]@{ action = 'set'; view = 'true'; clear = 'true' })
    Assert-True ($explicitOverTrue.action -eq 'set') 'an explicit action lost to a true view flag.'
    $falseViewRealClear = Format-MemoryArguments -Arguments ([pscustomobject]@{ view = 'false'; clear = 'true' })
    Assert-True ($falseViewRealClear.action -eq 'clear') 'view="false" blocked a real clear flag.'

    # Regression (Task 14): a model-supplied user_initiated flag stays on the normalized object and is rejected.
    # Direct Invoke-AgentMemory and /memory keep passing the flag and skip Ask confirmation.
    $norm = Format-MemoryArguments -Arguments ([pscustomobject]@{ action = 'append'; content = 'x'; user_initiated = $true })
    $threw = $false
    try { Test-AgentToolArguments -Name 'memory' -Arguments $norm } catch { $threw = $_.Exception.Message -match 'user_initiated' }
    Assert-True ($threw) 'model-supplied user_initiated was stripped instead of rejected.'
    Assert-True ($norm.ContainsKey('user_initiated') -and ($norm.user_initiated -eq $true)) 'Format-MemoryArguments dropped user_initiated before validation.'

    $savedPermUserInit = $script:AgentPermission
    $savedApprovalUserInit = $script:approval
    $savedOutputUserInit = $script:OutputMode
    $savedActiveUserInit = $script:ActiveState
    $userInitRoot = Join-Path $workspacePath 'user-init-mem'
    New-Item -ItemType Directory -Path $userInitRoot -Force | Out-Null
    try {
        $script:OutputMode = 'text'
        $script:AgentPermission = 'Auto'
        $modelSupplied = Invoke-AgentTool -Root $userInitRoot -Call @{ id = 'mem-ui'; function = @{ name = 'memory'; arguments = '{"action":"append","content":"x","user_initiated":true}' } } | ConvertFrom-Json
        Assert-True ($modelSupplied.error -like '*Unknown argument*user_initiated*') "model tool call did not reject user_initiated: $($modelSupplied.error)"
        Assert-True ((-not (Test-Path -LiteralPath (Join-Path $userInitRoot 'MEMORY.md'))) -and (-not (Test-Path -LiteralPath (Join-Path $userInitRoot '.shellossus/MEMORY.md')))) 'model-supplied user_initiated wrote memory.'

        $script:AgentPermission = 'Ask'
        $script:approval = 'n'
        $promptsBeforeDecline = $script:prompts
        $declinedDirect = Invoke-AgentMemory -Root $userInitRoot -Arguments @{ action = 'append'; content = 'should-not-write' } | ConvertFrom-Json
        Assert-True ($declinedDirect.status -eq 'cancelled' -and (-not $declinedDirect.success) -and ($script:prompts -gt $promptsBeforeDecline)) 'Ask mode memory append without user_initiated did not require confirmation.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $userInitRoot '.shellossus/MEMORY.md'))) 'declined direct memory append wrote a file.'

        $promptsBeforeUserInit = $script:prompts
        $userInitAsk = Invoke-AgentMemory -Root $userInitRoot -Arguments @{ action = 'append'; content = 'x'; user_initiated = $true } | ConvertFrom-Json
        Assert-True ($userInitAsk.success -and $userInitAsk.status -eq 'written' -and ($script:prompts -eq $promptsBeforeUserInit)) 'Ask mode treated a direct user_initiated memory call as unknown or required confirmation.'

        $script:AgentPermission = 'Auto'
        $userInitAuto = Invoke-AgentMemory -Root $userInitRoot -Arguments @{ action = 'append'; content = 'x'; user_initiated = $true } | ConvertFrom-Json
        Assert-True ($userInitAuto.success -and $userInitAuto.status -eq 'written' -and (-not ($userInitAuto.error -like '*Unknown argument*'))) 'Auto mode treated a direct user_initiated memory call as unknown.'

        $script:AgentPermission = 'Ask'
        $script:approval = 'n'
        $promptsBeforeReplMem = $script:prompts
        $replMemState = @{
            workspace = $userInitRoot
            messages = @(
                @{ role = 'system'; content = 'sys' }
            )
        }
        $script:ActiveState = $replMemState
        Invoke-ReplMemoryCommand -State $replMemState -RootPath $userInitRoot -ConfigDir $testRoot -MemArg 'add typed note'
        $replMemFile = Join-Path $userInitRoot '.shellossus/MEMORY.md'
        $replMemText = ''
        if (Test-Path -LiteralPath $replMemFile) { $replMemText = [string](Get-Content -LiteralPath $replMemFile -Raw -Encoding UTF8) }
        Assert-True (($script:prompts -eq $promptsBeforeReplMem) -and $replMemText.Contains('typed note')) 'user-typed /memory change required confirmation or was rejected.'
    }
    finally {
        $script:AgentPermission = $savedPermUserInit
        $script:approval = $savedApprovalUserInit
        $script:OutputMode = $savedOutputUserInit
        $script:ActiveState = $savedActiveUserInit
        if (Test-Path -LiteralPath $userInitRoot) {
            Remove-Item -LiteralPath $userInitRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # append memory (also verify live Sync-AgentMemoryContext updates active system prompt)
    $script:approval = 'WRITE'
    $memSyncState = @{
        workspace = $workspacePath
        messages = @(
            @{ role = 'system'; content = (Build-SystemPrompt -Root $workspacePath -ConfigDir '') }
        )
    }
    $script:ActiveState = $memSyncState
    $memAppendCall = @{
        id = 'mem-1'
        function = @{
            name = 'memory'
            arguments = '{"action":"append","content":"Keep all scripts ASCII"}'
        }
    }
    $memAppendRes = Invoke-AgentTool -Root $workspacePath -Call $memAppendCall | ConvertFrom-Json
    Assert-True ($memAppendRes.success -and $memAppendRes.action -eq 'append' -and ($memAppendRes.memory -like '*Keep all scripts ASCII*')) 'memory append failed.'
    Assert-True ($memSyncState.messages[0].content.Contains('<memory source=') -and $memSyncState.messages[0].content.Contains('Keep all scripts ASCII')) 'memory append did not sync <memory> block in active system prompt.'

    # view memory
    $memViewCall = @{
        id = 'mem-2'
        function = @{
            name = 'memory'
            arguments = '{"action":"view"}'
        }
    }
    $memViewRes = Invoke-AgentTool -Root $workspacePath -Call $memViewCall | ConvertFrom-Json
    Assert-True ($memViewRes.success -and $memViewRes.action -eq 'view' -and ($memViewRes.memory -like '*Keep all scripts ASCII*')) 'memory view failed.'

    # clear memory
    $memClearCall = @{
        id = 'mem-3'
        function = @{
            name = 'memory'
            arguments = '{"action":"clear"}'
        }
    }
    $memClearRes = Invoke-AgentTool -Root $workspacePath -Call $memClearCall | ConvertFrom-Json
    Assert-True ($memClearRes.success -and $memClearRes.action -eq 'clear' -and -not $memClearRes.memory) 'memory clear failed.'
    Assert-True (-not $memSyncState.messages[0].content.Contains('Keep all scripts ASCII')) 'memory clear did not remove <memory> block from active system prompt.'
    $script:ActiveState = $null

    # ReadOnly blocks memory append
    $script:AgentPermission = 'ReadOnly'
    $roMemRes = Invoke-AgentTool -Root $workspacePath -Call $memAppendCall | ConvertFrom-Json
    Assert-True ($roMemRes.error -like '*ReadOnly*') 'ReadOnly mode did not block memory modification.'
    $script:AgentPermission = 'Ask'

    # Regression (Item 13a): memory mutations require confirmation in Ask mode and cancel in JSON mode.
    $script:approval = 'n'
    $declinedMemRes = Invoke-AgentTool -Root $workspacePath -Call $memAppendCall | ConvertFrom-Json
    Assert-True ($declinedMemRes.status -eq 'cancelled' -and (-not $declinedMemRes.success)) 'memory append in Ask mode did not cancel when declined.'
    $prevModeMem = $script:OutputMode
    $script:OutputMode = 'json'
    $script:approval = $null
    try {
        $jsonMemRes = Invoke-AgentTool -Root $workspacePath -Call $memAppendCall | ConvertFrom-Json
        Assert-True ($jsonMemRes.status -eq 'cancelled' -and (-not $jsonMemRes.success)) 'memory append in JSON mode under Ask permission did not cancel immediately.'
    }
    finally {
        $script:OutputMode = $prevModeMem
        $script:approval = 'WRITE'
    }

    # Regression (Item 13b): memory checks parent directory (.shellossus) for symlink/reparse-point traversal via Test-PathHasReparsePoint.
    $memSymlinkWs = Join-Path $testRoot 'mem-symlink-ws'
    $memOutsideDir = Join-Path $testRoot 'mem-outside-dir'
    New-Item -ItemType Directory -Path $memSymlinkWs -Force | Out-Null
    New-Item -ItemType Directory -Path $memOutsideDir -Force | Out-Null
    $dotShellLink = Join-Path $memSymlinkWs '.shellossus'
    $createdDirLink = $false
    try {
        New-Item -ItemType SymbolicLink -Path $dotShellLink -Target $memOutsideDir -ErrorAction Stop | Out-Null
        $createdDirLink = $true
    }
    catch {
        if ($env:OS -eq 'Windows_NT') {
            try {
                New-Item -ItemType Junction -Path $dotShellLink -Target $memOutsideDir -ErrorAction Stop | Out-Null
                $createdDirLink = $true
            }
            catch {
                $createdDirLink = $false
            }
        }
        else {
            $createdDirLink = $false
        }
    }
    if ($createdDirLink) {
        Assert-True (Test-PathHasReparsePoint -Path (Join-Path $dotShellLink 'MEMORY.md') -StopAt $memSymlinkWs) 'Test-PathHasReparsePoint failed to detect symlinked .shellossus parent directory.'
        $symlinkMemRes = Invoke-AgentTool -Root $memSymlinkWs -Call $memAppendCall | ConvertFrom-Json
        Assert-True ($symlinkMemRes.error -like '*Symlink*' -or $symlinkMemRes.error -like '*reparse*') 'memory append did not block symlinked .shellossus directory.'
    }

    # Regression (Item 14): Convert-IgnorePatternToRule supports character classes [...] in .gitignore.
    $ccRules = @(
        (Convert-IgnorePatternToRule -Line '*.[ch]'),
        (Convert-IgnorePatternToRule -Line '[Bb]uild/'),
        (Convert-IgnorePatternToRule -Line 'file[0-9].log'),
        (Convert-IgnorePatternToRule -Line '[!a-z].tmp')
    )
    Assert-True (Test-PathIgnored -RelativePath 'src/main.c' -IsDir $false -Rules $ccRules) 'Character class *.[ch] failed to match src/main.c.'
    Assert-True (Test-PathIgnored -RelativePath 'include/util.h' -IsDir $false -Rules $ccRules) 'Character class *.[ch] failed to match include/util.h.'
    Assert-True (-not (Test-PathIgnored -RelativePath 'src/main.cpp' -IsDir $false -Rules $ccRules)) 'Character class *.[ch] falsely matched src/main.cpp.'
    Assert-True (Test-PathIgnored -RelativePath 'Build' -IsDir $true -Rules $ccRules) 'Character class [Bb]uild/ failed to match Build/ directory.'
    Assert-True (Test-PathIgnored -RelativePath 'build' -IsDir $true -Rules $ccRules) 'Character class [Bb]uild/ failed to match build/ directory.'
    Assert-True (-not (Test-PathIgnored -RelativePath 'rebuild' -IsDir $true -Rules $ccRules)) 'Character class [Bb]uild/ falsely matched rebuild/ directory.'
    Assert-True (Test-PathIgnored -RelativePath 'logs/file7.log' -IsDir $false -Rules $ccRules) 'Character class file[0-9].log failed to match logs/file7.log.'
    Assert-True (Test-PathIgnored -RelativePath '9.tmp' -IsDir $false -Rules $ccRules) 'Negated character class [!a-z].tmp failed to match 9.tmp.'
    Assert-True (-not (Test-PathIgnored -RelativePath 'a.tmp' -IsDir $false -Rules $ccRules)) 'Negated character class [!a-z].tmp falsely matched a.tmp.'

    # Regression (Item 15): build.ps1 rejects non-ASCII characters in source/test .ps1 files instead of silently replacing them with '?'.
    $badBuildDir = Join-Path $testRoot 'bad-ascii-build'
    $badSrcDir = Join-Path $badBuildDir 'src'
    New-Item -ItemType Directory -Path $badSrcDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'build.ps1') -Destination (Join-Path $badBuildDir 'build.ps1') -Force
    $nonAsciiChar = [string][char]0x0410
    Set-Content -LiteralPath (Join-Path $badSrcDir 'Config.ps1') -Value ("# Non-ASCII: " + $nonAsciiChar) -Encoding UTF8
    $buildThrew = $false
    $buildErrText = ''
    try {
        & (Join-Path $badBuildDir 'build.ps1')
    }
    catch {
        $buildThrew = $true
        $buildErrText = [string]$_.Exception.Message
    }
    Assert-True ($buildThrew -and $buildErrText -like '*Non-ASCII character U+0410*' -and $buildErrText -like '*7-bit ASCII*') "build.ps1 did not fail on non-ASCII source file. Error: $buildErrText"

    # Regression (Item 16): read_file streams files in batches (-ReadCount) and accurately slices across batch boundaries.
    $batchedFile = Join-Path $workspacePath 'batched1250.txt'
    $batchedLines = 1..1250 | ForEach-Object { "row-$_" }
    Set-Content -LiteralPath $batchedFile -Value ($batchedLines -join "`n") -Encoding UTF8 -NoNewline
    $call = @{ id = 'rf-batch'; function = @{ name = 'read_file'; arguments = '{"path":"batched1250.txt","start_line":498,"max_lines":6}' } }
    $batchReadRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $batchReturnedLines = @($batchReadRes.text -split "`n")
    Assert-True ($batchReadRes.total_lines -eq 1250 -and $batchReadRes.start_line -eq 498 -and $batchReadRes.end_line -eq 503 -and $batchReadRes.truncated -and $batchReadRes.next_start_line -eq 504) 'read_file across 500-line batch boundary returned wrong pagination metadata.'
    Assert-True ($batchReturnedLines.Count -eq 6 -and $batchReturnedLines[0] -eq 'row-498' -and $batchReturnedLines[2] -eq 'row-500' -and $batchReturnedLines[3] -eq 'row-501' -and $batchReturnedLines[5] -eq 'row-503') 'read_file across 500-line batch boundary returned wrong lines.'
    $fnReadDef = [string](Get-Command -Name 'Invoke-AgentReadFile').Definition
    Assert-True ($fnReadDef -match '-ReadCount\s+500') 'Invoke-AgentReadFile should stream lines using Get-Content -ReadCount 500.'

    # Regression (Item 17): Read-DirectoryIgnoreRules caches compiled rules by file fingerprint and invalidates on modification/deletion.
    $cacheIgDir = Join-Path $workspacePath 'igcache-test'
    New-Item -ItemType Directory -Path $cacheIgDir -Force | Out-Null
    $cacheIgFile = Join-Path $cacheIgDir '.gitignore'
    Set-Content -LiteralPath $cacheIgFile -Value '*.cached1' -Encoding UTF8
    $rulesV1 = @(Read-DirectoryIgnoreRules -RootFull $workspacePath -DirFull $cacheIgDir)
    Assert-True ($rulesV1.Count -eq 1 -and $rulesV1[0].pattern -eq '*.cached1') 'Read-DirectoryIgnoreRules failed initial read.'
    Assert-True ($null -ne $script:IgnoreRulesCache -and $script:IgnoreRulesCache.Count -ge 1) 'Read-DirectoryIgnoreRules did not populate $script:IgnoreRulesCache.'
    $rulesV1Cached = @(Read-DirectoryIgnoreRules -RootFull $workspacePath -DirFull $cacheIgDir)
    Assert-True ($rulesV1Cached.Count -eq 1 -and $rulesV1Cached[0].regex -ceq $rulesV1[0].regex) 'Read-DirectoryIgnoreRules cache hit returned different rules.'
    Set-Content -LiteralPath $cacheIgFile -Value @('*.cached1', '*.cached2') -Encoding UTF8
    $rulesV2 = @(Read-DirectoryIgnoreRules -RootFull $workspacePath -DirFull $cacheIgDir)
    Assert-True ($rulesV2.Count -eq 2 -and $rulesV2[1].pattern -eq '*.cached2') 'Read-DirectoryIgnoreRules did not invalidate cache when .gitignore changed.'
    Remove-Item -LiteralPath $cacheIgFile -Force
    $rulesV3 = @(Read-DirectoryIgnoreRules -RootFull $workspacePath -DirFull $cacheIgDir)
    Assert-True ($rulesV3.Count -eq 0) 'Read-DirectoryIgnoreRules did not invalidate cache when .gitignore was deleted.'
    Remove-Item -LiteralPath $cacheIgDir -Recurse -Force

    # Regression: Format-AskUserArguments and Format-MemoryArguments preserve unknown arguments and non-string types for validation.
    $unknownAskRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'ask-unk'; function = @{ name = 'ask_user'; arguments = '{"question":"Continue?","unexpected_param":123}' } } | ConvertFrom-Json
    Assert-True ($unknownAskRes.error -like '*Unknown argument*unexpected_param*') "ask_user did not reject unknown argument: $($unknownAskRes.error)"
    $unknownMemRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'mem-unk'; function = @{ name = 'memory'; arguments = '{"action":"view","unexpected_param":123}' } } | ConvertFrom-Json
    Assert-True ($unknownMemRes.error -like '*Unknown argument*unexpected_param*') "memory did not reject unknown argument: $($unknownMemRes.error)"
    $badTypeMemRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'mem-type'; function = @{ name = 'memory'; arguments = '{"action":"append","content":12345}' } } | ConvertFrom-Json
    Assert-True ($badTypeMemRes.error -like '*must be a string*') "memory did not reject non-string content: $($badTypeMemRes.error)"

    # Regression: Request-AgentWebConfirmation 'a' ([a]ll) sets $script:AutoApproveWeb = $true without escalating $script:AgentPermission to AutoEdit.
    $savedPermWebAll = $script:AgentPermission
    $savedAutoWebAll = $script:AutoApproveWeb
    $savedApprovalWebAll = $script:approval
    try {
        $script:AgentPermission = 'Ask'
        $script:AutoApproveWeb = $false
        $script:approval = 'a'
        $webConf1 = Request-AgentWebConfirmation -ToolName 'fetch_url' -Target 'https://example.com/1'
        Assert-True ($webConf1.approved -and $script:AutoApproveWeb -eq $true) 'Entering a at web confirmation did not set $script:AutoApproveWeb = $true.'
        Assert-True ($script:AgentPermission -eq 'Ask') "Entering a at web confirmation must not escalate AgentPermission to AutoEdit (got $($script:AgentPermission))."
        $promptsBeforeWeb2 = $script:prompts
        $script:approval = 'n'
        $webConf2 = Request-AgentWebConfirmation -ToolName 'fetch_url' -Target 'https://example.com/2'
        Assert-True ($webConf2.approved -and $script:prompts -eq $promptsBeforeWeb2) 'Subsequent web request was not auto-approved when $script:AutoApproveWeb is true.'
    }
    finally {
        $script:AgentPermission = $savedPermWebAll
        $script:AutoApproveWeb = $savedAutoWebAll
        $script:approval = $savedApprovalWebAll
    }

    # Regression: Test-SafeWebUrl blocks IPv4-compatible/mapped IPv6, hex-encoded private IPv4 in IPv6, and NAT64 prefix.
    foreach ($ipv6SsrfUrl in @(
        'http://[::127.0.0.1]/',
        'http://[::ffff:127.0.0.1]/',
        'http://[::10.0.0.1]/',
        'http://[::192.168.1.1]/',
        'http://[::169.254.169.254]/',
        'http://[::172.16.0.1]/',
        'http://[::7f00:1]/',
        'http://[::ffff:7f00:1]/',
        'http://[0:0:0:0:0:0:7f00:1]/',
        'http://[0:0:0:0:0:ffff:7f00:1]/',
        'http://[64:ff9b::127.0.0.1]/',
        'http://[64:ff9b::7f00:1]/'
    )) {
        $v6Blocked = $false
        try {
            $null = Test-SafeWebUrl -Url $ipv6SsrfUrl
        }
        catch {
            $v6Blocked = $true
        }
        Assert-True $v6Blocked "Test-SafeWebUrl failed to block IPv6 SSRF URL: $ipv6SsrfUrl"
    }

    # Regression: Invoke-AgentWebDownload scrubs SHELLOSSUS_API_KEY and OPENAI_API_KEY during download and restores them in finally.
    $savedEnvS = $env:SHELLOSSUS_API_KEY
    $savedEnvO = $env:OPENAI_API_KEY
    $script:leakedKeysDuringWeb = $true
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:leakedKeysDuringWeb = ([bool]$env:SHELLOSSUS_API_KEY -or [bool]$env:OPENAI_API_KEY)
        Set-Content -LiteralPath $OutFile -Value 'ok' -Encoding UTF8 -NoNewline
    }
    $dlTmp = New-AgentTempFile
    try {
        $env:SHELLOSSUS_API_KEY = 'sec-s'
        $env:OPENAI_API_KEY = 'sec-o'
        Invoke-AgentWebDownload -Uri 'https://example.com/test' -OutFile $dlTmp.FullName
        Assert-True (-not $script:leakedKeysDuringWeb) 'Invoke-AgentWebDownload did not scrub API keys from environment during download.'
        Assert-True ($env:SHELLOSSUS_API_KEY -eq 'sec-s' -and $env:OPENAI_API_KEY -eq 'sec-o') 'Invoke-AgentWebDownload did not restore API keys after download.'
    }
    finally {
        $env:SHELLOSSUS_API_KEY = $savedEnvS
        $env:OPENAI_API_KEY = $savedEnvO
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dlTmp.FullName -Force -ErrorAction SilentlyContinue
    }

    # Regression: Wait-AgentProcessWithSpinner clamps long status labels to terminal width without [Math]::Max.
    $script:clampedSpinOut = @()
    $script:spinFakeProc = @{ Id = 0; HasExited = $false; ExitCode = 0 }
    $script:spinPolls = 0
    $savedGetTerminalWidth = ${function:Get-TerminalWidth}
    function Get-TerminalWidth { return 40 }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $script:clampedSpinOut += (($Object | ForEach-Object { [string]$_ }) -join ' ')
    }
    function Start-Sleep {
        param($Seconds, $Milliseconds)
        $script:spinPolls++
        if ($script:spinPolls -ge 1) { $script:spinFakeProc.HasExited = $true }
    }
    try {
        $script:OutputMode = 'text'
        $veryLongLabel = 'Waiting for subagent with an extremely long status label that exceeds forty columns'
        Wait-AgentProcessWithSpinner -Process $script:spinFakeProc -StatusLabel $veryLongLabel -TimeoutSec 10 -PollMs 10
        $visFrame = (Strip-AnsiCodes -Text $script:clampedSpinOut[0]).TrimStart("`r")
        Assert-True ($visFrame.Length -le 39) "Wait-AgentProcessWithSpinner did not clamp spinner line to (Get-TerminalWidth) - 1 (got length $($visFrame.Length): $visFrame)."
    }
    finally {
        ${function:Get-TerminalWidth} = $savedGetTerminalWidth
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    }

    # Regression: Get-SubagentToolNames excludes write/exec/state/interactive tools for ReadOnly subagents,
    # excludes web tools in non-interactive ReadOnly mode when AutoApproveWeb is false, and Invoke-SubagentInProcess
    # isolates parent $script:ActiveSessionTodos and $parentState.todos from craft subagent todo calls.
    $savedPermSubTodo = $script:AgentPermission
    $savedModeSubTodo = $script:OutputMode
    $savedAutoWebSubTodo = $script:AutoApproveWeb
    $savedStateSubTodo = $script:ActiveState
    $savedTodosSubTodo = @($script:ActiveSessionTodos)
    try {
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'text'
        $script:AutoApproveWeb = $false
        $reconRole = Resolve-AgentRole -Name 'recon' -Root $workspacePath -ConfigDir ''
        $auditRole = Resolve-AgentRole -Name 'audit' -Root $workspacePath -ConfigDir ''
        $reconTools = @(Get-SubagentToolNames -Role $reconRole)
        $auditTools = @(Get-SubagentToolNames -Role $auditRole)
        foreach ($excludedTool in @('write_file', 'edit_file', 'run_command', 'memory', 'todo', 'ask_user', 'run_agent')) {
            Assert-True ($reconTools -notcontains $excludedTool) "recon ReadOnly subagent exposed $excludedTool."
            Assert-True ($auditTools -notcontains $excludedTool) "audit ReadOnly subagent exposed $excludedTool."
        }
        Assert-True (($reconTools -contains 'read_file') -and ($reconTools -contains 'fetch_url') -and ($reconTools -contains 'web_search')) 'Interactive ReadOnly recon subagent should retain read_file, fetch_url, and web_search.'

        $nonInteractiveRoTools = @(Get-SubagentToolNames -Role $reconRole -ForceReadOnly -NonInteractive)
        Assert-True (($nonInteractiveRoTools -notcontains 'fetch_url') -and ($nonInteractiveRoTools -notcontains 'web_search')) 'Get-SubagentToolNames -ForceReadOnly -NonInteractive did not exclude fetch_url and web_search when AutoApproveWeb is false.'
        Assert-True (($nonInteractiveRoTools -contains 'list_files') -and ($nonInteractiveRoTools -contains 'read_file') -and ($nonInteractiveRoTools -contains 'find_files') -and ($nonInteractiveRoTools -contains 'grep_files')) 'Get-SubagentToolNames -ForceReadOnly -NonInteractive dropped core workspace read tools.'

        $script:OutputMode = 'json'
        $parentTodoList = @(@{ content = 'Parent task 1'; status = 'in_progress' }, @{ content = 'Parent task 2'; status = 'pending' })
        $parentStateForSubTodo = @{
            session_id = 'parent-todo-sess'
            workspace = $workspacePath
            model = 'test-model'
            messages = @(@{ role = 'system'; content = 'sys' })
            todos = @($parentTodoList)
        }
        $script:ActiveState = $parentStateForSubTodo
        $script:ActiveSessionTodos = @($parentTodoList)
        $script:subTodoStep = 0
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:subTodoStep++
            if ($script:subTodoStep -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 'sub-td-1'; type = 'function'; function = @{ name = 'todo'; arguments = '{"todos":[{"content":"Subagent local step","status":"completed"}]}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            elseif ($script:subTodoStep -eq 2) {
                $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Craft subagent finished' } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            elseif ($script:subTodoStep -eq 3) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 'sub-td-2'; type = 'function'; function = @{ name = 'todo'; arguments = '{"todos":[{"content":"Subagent failing step","status":"in_progress"}]}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                throw 'Subagent failed after updating todo'
            }
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $craftTodoRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-craft-todo'
            function = @{ name = 'run_agent'; arguments = '{"role":"craft","prompt":"Run subagent with local todo"}' }
        } | ConvertFrom-Json
        Assert-True ($craftTodoRes.status -eq 'completed') 'Craft subagent with todo call did not complete.'
        Assert-True ($script:ActiveSessionTodos.Count -eq 2 -and $script:ActiveSessionTodos[0].content -eq 'Parent task 1' -and $script:ActiveSessionTodos[1].content -eq 'Parent task 2') 'Craft subagent todo call overwrote parent $script:ActiveSessionTodos.'
        Assert-True ($parentStateForSubTodo.todos.Count -eq 2 -and $parentStateForSubTodo.todos[0].content -eq 'Parent task 1' -and $parentStateForSubTodo.todos[1].content -eq 'Parent task 2') 'Craft subagent todo call overwrote $parentState.todos.'
        Assert-True ($script:ActiveState -eq $parentStateForSubTodo) 'Invoke-SubagentInProcess did not restore $script:ActiveState.'

        $craftFailRes = Invoke-AgentTool -Root $workspacePath -Call @{
            id = 'sub-craft-todo-fail'
            function = @{ name = 'run_agent'; arguments = '{"role":"craft","prompt":"Run failing subagent with local todo"}' }
        } | ConvertFrom-Json
        Assert-True ([bool]$craftFailRes.error) 'Expected failing craft subagent to return an error.'
        Assert-True ($script:ActiveSessionTodos.Count -eq 2 -and $script:ActiveSessionTodos[0].content -eq 'Parent task 1' -and $script:ActiveSessionTodos[1].content -eq 'Parent task 2') 'Failing craft subagent todo call corrupted parent $script:ActiveSessionTodos.'
        Assert-True ($parentStateForSubTodo.todos.Count -eq 2 -and $parentStateForSubTodo.todos[0].content -eq 'Parent task 1' -and $parentStateForSubTodo.todos[1].content -eq 'Parent task 2') 'Failing craft subagent todo call corrupted $parentState.todos.'
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        $script:AgentPermission = $savedPermSubTodo
        $script:OutputMode = $savedModeSubTodo
        $script:AutoApproveWeb = $savedAutoWebSubTodo
        $script:ActiveState = $savedStateSubTodo
        $script:ActiveSessionTodos = $savedTodosSubTodo
    }

    # Regression (Task 4): Clear-AgentUndoBackups removes temporary backup files across UndoEntries and Writes.
    $tmpBak1 = New-AgentTempFile
    $tmpBak2 = New-AgentTempFile
    $tmpBak3 = New-AgentTempFile
    Assert-True ((Test-Path -LiteralPath $tmpBak1.FullName) -and (Test-Path -LiteralPath $tmpBak2.FullName) -and (Test-Path -LiteralPath $tmpBak3.FullName)) 'New-AgentTempFile did not create temporary backup files.'
    $mockUndoEntries = @(
        $null,
        @{ writes = @($null, @{ action = 'created'; backup = $null }, @{ action = 'modified'; backup = $tmpBak1.FullName }) },
        @{ writes = @(@{ action = 'modified'; backup = $tmpBak2.FullName }) }
    )
    $mockWrites = @(
        $null,
        @{ action = 'modified'; backup = $tmpBak3.FullName }
    )
    Clear-AgentUndoBackups -UndoEntries $mockUndoEntries -Writes $mockWrites
    Assert-True ((-not (Test-Path -LiteralPath $tmpBak1.FullName)) -and (-not (Test-Path -LiteralPath $tmpBak2.FullName)) -and (-not (Test-Path -LiteralPath $tmpBak3.FullName))) 'Clear-AgentUndoBackups did not remove all backup files in UndoEntries and Writes.'

    # Characterization captured from the tool schema before the single-table refactor.
    # Serializes Get-AgentTools to JSON, then locks tool order plus every property name and description.
    function Compare-OrdinalSchemaPath {
        param([string]$Left, [string]$Right)
        $n = $Left.Length
        if ($Right.Length -lt $n) { $n = $Right.Length }
        for ($i = 0; $i -lt $n; $i++) {
            $lc = [int][char]$Left[$i]
            $rc = [int][char]$Right[$i]
            if ($lc -lt $rc) { return -1 }
            if ($lc -gt $rc) { return 1 }
        }
        if ($Left.Length -lt $Right.Length) { return -1 }
        if ($Left.Length -gt $Right.Length) { return 1 }
        return 0
    }
    function Sort-SchemaPropertyRecords {
        param($Records)
        $items = @($Records)
        for ($i = 0; $i -lt $items.Count; $i++) {
            for ($j = $i + 1; $j -lt $items.Count; $j++) {
                $cmp = Compare-OrdinalSchemaPath -Left ([string]$items[$j].path) -Right ([string]$items[$i].path)
                if ($cmp -lt 0) {
                    $tmp = $items[$i]
                    $items[$i] = $items[$j]
                    $items[$j] = $tmp
                }
            }
        }
        foreach ($item in $items) { Write-Output $item }
    }
    function Get-CapturedSchemaProperties {
        param($Node, [string]$Prefix)
        $found = @()
        if ($null -eq $Node) { return }
        $nodeNames = @($Node.PSObject.Properties.Name)
        if ($nodeNames -notcontains 'properties' -or $null -eq $Node.properties) { return }
        $propNames = @($Node.properties.PSObject.Properties.Name)
        foreach ($propName in $propNames) {
            $child = $Node.properties.$propName
            $path = if ($Prefix) { $Prefix + '.' + $propName } else { [string]$propName }
            $desc = ''
            $childNames = @()
            if ($null -ne $child) { $childNames = @($child.PSObject.Properties.Name) }
            if ($childNames -contains 'description' -and $null -ne $child.description) {
                $desc = [string]$child.description
            }
            $found += @{ path = $path; description = $desc }
            if ($childNames -contains 'items') {
                $nested = @(Get-CapturedSchemaProperties -Node $child.items -Prefix ($path + '.items'))
                foreach ($nestedItem in $nested) { $found += $nestedItem }
            }
        }
        foreach ($foundItem in $found) { Write-Output $foundItem }
    }
    function Get-CapturedToolSchemaText {
        param($Tools)
        $toolsJson = @($Tools) | ConvertTo-Json -Depth 30
        # Windows PowerShell 5.1 returns a JSON array as one object.
        # Wrapping that object in @() nests it, and [string] then joins every tool name.
        $parsed = $toolsJson | ConvertFrom-Json
        $lines = @()
        foreach ($tool in $parsed) {
            if ($lines.Count -gt 0) { $lines += '' }
            $lines += ('tool: ' + [string]$tool.function.name)
            $lines += ('description: ' + [string]$tool.function.description)
            $records = @(Get-CapturedSchemaProperties -Node $tool.function.parameters -Prefix '')
            $records = @(Sort-SchemaPropertyRecords -Records $records)
            foreach ($rec in $records) {
                $lines += ('property: ' + [string]$rec.path)
                if ($rec.description) {
                    $lines += ('description: ' + [string]$rec.description)
                }
                else {
                    $lines += 'description:'
                }
            }
        }
        return ($lines -join "`n")
    }
    $savedSchemaPerm = $script:AgentPermission
    $savedSchemaNoTools = $script:NoTools
    $savedSchemaEnabled = @($script:EnabledTools)
    $savedSchemaExcluded = @($script:ExcludedTools)
    $savedSchemaDepth = $script:SubagentDepth
    try {
        $script:AgentPermission = 'Ask'
        $script:NoTools = $false
        $script:EnabledTools = @()
        $script:ExcludedTools = @()
        $script:SubagentDepth = 0
        $actualSchemaText = [string](Get-CapturedToolSchemaText -Tools @(Get-AgentTools))
        $expectedSchemaText = @'
tool: list_files
description: List up to 200 entries in a directory. Names only; no file contents.
property: limit
description: Optional maximum number of entries to return (1..500, default 200).
property: path
description: Workspace-relative path; . means the root.

tool: read_file
description: Read a UTF-8 text file: up to 300 lines and 20000 characters, maximum file size 1 MiB. Returns total_lines and pagination metadata.
property: limit
description: Optional alias for max_lines (1..300).
property: max_lines
description: Optional maximum number of lines to read (1..300, default 300).
property: offset
description: Optional alias for start_line (1-based line offset).
property: path
description: Workspace-relative path; . means the root.
property: start_char
description: Optional 1-based character offset within start_line for reading long lines (default 1).
property: start_line
description: Optional 1-based first line to read (default 1).

tool: find_files
description: Find files or directories recursively by wildcard pattern (e.g. *.sql, src/*.ps1), respecting .gitignore/.ignore.
property: limit
description: Optional maximum number of results (1..1000, default 200).
property: path
description: Workspace-relative directory path; . means the root.
property: pattern
description: File name or relative path wildcard pattern, e.g. *.sql or src/*.ps1.

tool: grep_files
description: Search UTF-8 text files for a regex or literal pattern (respecting .gitignore/.ignore), returning matching paths, line numbers, and lines.
property: case_sensitive
description: Set true for case-sensitive matching.
property: context_lines
description: Optional surrounding context lines (0..5).
property: file_offset
description: Optional 0-based file offset. To continue, use next_file_offset together with next_start_line from the previous result (default 0).
property: glob
description: Optional alias for include wildcard filter.
property: include
description: Optional file name wildcard filter, e.g. *.sql or *.ps1.
property: limit
description: Optional maximum number of matches to return (1..500, default 100).
property: literal
description: Set true for literal substring match instead of regex.
property: path
description: Workspace-relative file or directory path; . means the root.
property: pattern
description: Regex or literal search pattern.
property: start_line
description: Optional 1-based first matching line to include in the file at file_offset; later files start at line 1 (default 1).

tool: fetch_url
description: Fetch an HTTP/HTTPS URL and return readable text, Markdown, or JSON content (up to 20000 characters by default).
property: max_chars
description: Optional maximum characters to return (500..50000, default 20000).
property: raw
description: Optional: set true to return raw HTML without tag stripping.
property: url
description: HTTP or HTTPS URL to fetch.

tool: web_search
description: Search the web for a query and return matching result titles, URLs, and snippets.
property: limit
description: Optional maximum number of results (1..20, default 8).
property: query
description: Search query text.

tool: todo
description: Track task plan and progress during multi-step work. Call this to initialize or update the active todo list (replaces entire list on each call).
property: todos
description: Complete ordered list of task items: array of {content, status}. Status must be pending, in_progress, or completed.
property: todos.items.content
description: Clear, concise description of the task.
property: todos.items.status
description: Task status: pending, in_progress, or completed.

tool: ask_user
description: Ask the user a concise question, request an architectural decision, or present a Markdown implementation plan for explicit review and approval before making changes.
property: allow_custom
description: Whether the user can provide custom free-text feedback if none of the options fit (default true).
property: intent
description: Presentation intent: 'question' for architectural/decision choices (default), or 'plan-review' for reviewing a Markdown plan before modifying files.
property: options
description: Optional choices to show the user (list of strings or objects with label and description). Put recommended choice first.
property: plan
description: Markdown text of the plan under review (used when intent is 'plan-review').
property: question
description: The question or plan summary to present to the user.

tool: memory
description: Record, view, or manage persistent long-term memories, user preferences, and project invariants that survive across CLI sessions in MEMORY.md.
property: action
description: Action to perform: 'append' to add a new memory note (default), 'view' to read memory, 'set' to replace memory content, or 'clear' to reset.
property: content
description: The fact, preference, or architectural invariant to record (required for 'append' and 'set').
property: scope
description: Storage scope: 'workspace' (default, stored in .shellossus/MEMORY.md) or 'global' (stored in global config MEMORY.md).

tool: write_file
description: Create a UTF-8 text file (or overwrite when overwrite=true).
property: content
description: Complete file contents, up to 1 MiB.
property: overwrite
description: Set true to overwrite an existing file (saves a backup).
property: path
description: Workspace-relative text file path. Parent directory must exist.

tool: edit_file
description: Replace one or more unique blocks in a UTF-8 text file (supports single old_text/new_text or batch edits[] array; saves a backup).
property: edits
description: Optional batch of non-overlapping edits: array of {old_text, new_text} objects.
property: edits.items.new_text
description:
property: edits.items.old_text
description:
property: new_text
description: Single edit: replacement text.
property: old_text
description: Single edit: nonempty text occurring once in the file.
property: path
description: Workspace-relative text file path. Parent directory must exist.

tool: run_command
description: Execute a PowerShell command in the workspace directory.
property: command
description: PowerShell command to execute.
property: timeout_sec
description: Optional timeout in seconds (1..600, default 60).

tool: run_agent
description: Delegate a task, parallel fan-out, or sequential pipeline to isolated subagents (roles: recon [ReadOnly], audit [ReadOnly], craft [inherits permission]). Keeps main context clean.
property: context
description: Optional context mode for single/pipeline tasks: clean (default, fresh context) or fork (clones parent conversation history).
property: max_steps
description: Optional step budget per subagent run (1..50, default 15).
property: parallel
description: Concurrent ReadOnly fan-out tasks (1..8 items of {role, prompt}).
property: parallel.items.prompt
description:
property: parallel.items.role
description:
property: pipeline
description: Sequential pipeline steps (1..8 items of {role, prompt, context}); use {previous} or $PREVIOUS in prompt to reference prior step output.
property: pipeline.items.context
description:
property: pipeline.items.prompt
description:
property: pipeline.items.role
description:
property: prompt
description: Single-task instruction for the subagent (mutually exclusive with parallel and pipeline).
property: role
description: Optional subagent role: recon (ReadOnly search), audit (ReadOnly review), craft (inherits permission), or custom role name.
'@
        $actualSchemaText = $actualSchemaText.TrimEnd("`r", "`n")
        $expectedSchemaText = $expectedSchemaText.TrimEnd("`r", "`n")
        if ($actualSchemaText -cne $expectedSchemaText) {
            $actualLines = @($actualSchemaText -split "`n")
            $expectedLines = @($expectedSchemaText -split "`n")
            $maxLines = $actualLines.Count
            if ($expectedLines.Count -gt $maxLines) { $maxLines = $expectedLines.Count }
            $diffAt = -1
            for ($lineIdx = 0; $lineIdx -lt $maxLines; $lineIdx++) {
                $actualLine = if ($lineIdx -lt $actualLines.Count) { [string]$actualLines[$lineIdx] } else { '<missing>' }
                $expectedLine = if ($lineIdx -lt $expectedLines.Count) { [string]$expectedLines[$lineIdx] } else { '<missing>' }
                if ($actualLine -cne $expectedLine) { $diffAt = $lineIdx; break }
            }
            $shownActual = if ($diffAt -ge 0 -and $diffAt -lt $actualLines.Count) { [string]$actualLines[$diffAt] } else { '<missing>' }
            $shownExpected = if ($diffAt -ge 0 -and $diffAt -lt $expectedLines.Count) { [string]$expectedLines[$diffAt] } else { '<missing>' }
            throw ("Tool schema names or descriptions drifted at line {0}. Actual: [{1}] Expected: [{2}]" -f ($diffAt + 1), $shownActual, $shownExpected)
        }
    }
    finally {
        $script:AgentPermission = $savedSchemaPerm
        $script:NoTools = $savedSchemaNoTools
        $script:EnabledTools = $savedSchemaEnabled
        $script:ExcludedTools = $savedSchemaExcluded
        $script:SubagentDepth = $savedSchemaDepth
    }

    # Regression (Task 3): find_files expands leading **/, middle /**/, and trailing /** including multiple /**/ segments.
    New-Item -ItemType Directory -Path (Join-Path $workspacePath 'sub/deep') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workspacePath 'sub/root.txt') -Value 'r' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $workspacePath 'sub/deep/leaf.txt') -Value 'l' -Encoding Ascii
    $findGlobRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'f-glob1'; function = @{ name = 'find_files'; arguments = '{"path":".","pattern":"sub/**/*.txt"}' } } | ConvertFrom-Json
    $foundGlobPaths = @($findGlobRes.matches | ForEach-Object { $_.path })
    Assert-True ($foundGlobPaths -contains 'sub/root.txt' -and $foundGlobPaths -contains 'sub/deep/leaf.txt') 'find_files with sub/**/*.txt should match both sub/root.txt and sub/deep/leaf.txt.'

    New-Item -ItemType Directory -Path (Join-Path $workspacePath 'mglob/a/b') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspacePath 'mglob/a/x/b') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspacePath 'mglob/a/b/y') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspacePath 'mglob/a/x/b/y') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workspacePath 'mglob/a/b/c.txt') -Value '1' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $workspacePath 'mglob/a/x/b/c.txt') -Value '2' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $workspacePath 'mglob/a/b/y/c.txt') -Value '3' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $workspacePath 'mglob/a/x/b/y/c.txt') -Value '4' -Encoding Ascii
    $findMultiGlob = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'f-glob2'; function = @{ name = 'find_files'; arguments = '{"path":"mglob","pattern":"a/**/b/**/c.txt"}' } } | ConvertFrom-Json
    $multiRelPaths = @($findMultiGlob.matches | ForEach-Object { $_.relative_path })
    Assert-True ($multiRelPaths.Count -eq 4 -and ($multiRelPaths -contains 'a/b/c.txt') -and ($multiRelPaths -contains 'a/x/b/c.txt') -and ($multiRelPaths -contains 'a/b/y/c.txt') -and ($multiRelPaths -contains 'a/x/b/y/c.txt')) 'find_files with a/**/b/**/c.txt failed to match all 0-or-more subdirectory combinations.'
    Remove-Item -LiteralPath (Join-Path $workspacePath 'mglob') -Recurse -Force

    # Regression (Task 4): single-file grep_files respects include filter (with backslash normalization and /**/ expansion) and workspace .gitignore rules.
    Set-Content -LiteralPath (Join-Path $workspacePath 'single-grep.txt') -Value 'needle_here' -Encoding Ascii
    $singleGrepMismatch = Invoke-AgentTool -Root $workspacePath -Call @{
        id = 'g-single-inc1'
        function = @{ name = 'grep_files'; arguments = '{"path":"single-grep.txt","pattern":"needle_here","include":"*.ps1"}' }
    } | ConvertFrom-Json
    Assert-True (@($singleGrepMismatch.matches).Count -eq 0) 'Single-file grep_files should return 0 matches when include filter does not match.'

    Set-Content -LiteralPath (Join-Path $workspacePath 'sub/root.txt') -Value 'needle_sub_root' -Encoding Ascii
    $singleGrepMatch = Invoke-AgentTool -Root $workspacePath -Call @{
        id = 'g-single-inc2'
        function = @{ name = 'grep_files'; arguments = '{"path":"sub/root.txt","pattern":"needle_sub_root","include":"sub\\**\\*.txt"}' }
    } | ConvertFrom-Json
    Assert-True (@($singleGrepMatch.matches).Count -eq 1) 'Single-file grep_files should match when normalized/expanded include filter matches.'

    Set-Content -LiteralPath (Join-Path $workspacePath 'sub/ignored-single.log') -Value 'needle_ignored_single' -Encoding Ascii
    $singleGrepIgnored = Invoke-AgentTool -Root $workspacePath -Call @{
        id = 'g-single-ig'
        function = @{ name = 'grep_files'; arguments = '{"path":"sub/ignored-single.log","pattern":"needle_ignored_single"}' }
    } | ConvertFrom-Json
    Assert-True (@($singleGrepIgnored.matches).Count -eq 0) 'Single-file grep_files should return 0 matches when target file is ignored by .gitignore.'
    Remove-Item -LiteralPath (Join-Path $workspacePath 'sub') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $workspacePath 'single-grep.txt') -Force

    # Regression (Task 6): Convert-IgnorePatternToRule handles escaped wildcard/bracket/backslash sequences (\\, \[, \], \*, \?).
    $escRuleBrack = Convert-IgnorePatternToRule -Line '\[draft\].txt'
    Assert-True (Test-PathIgnored -RelativePath '[draft].txt' -IsDir $false -Rules @($escRuleBrack)) 'Escaped \[draft\].txt in .gitignore should match literal [draft].txt.'
    Assert-True (Test-PathIgnored -RelativePath 'docs/[draft].txt' -IsDir $false -Rules @($escRuleBrack)) 'Escaped \[draft\].txt in .gitignore should match nested docs/[draft].txt.'
    Assert-True (-not (Test-PathIgnored -RelativePath 'd.txt' -IsDir $false -Rules @($escRuleBrack))) 'Escaped \[draft\].txt in .gitignore must not act as character class [draft].'
    $escRuleStar = Convert-IgnorePatternToRule -Line 'note\*.txt'
    Assert-True ((Test-PathIgnored -RelativePath 'note*.txt' -IsDir $false -Rules @($escRuleStar)) -and (-not (Test-PathIgnored -RelativePath 'note1.txt' -IsDir $false -Rules @($escRuleStar)))) 'Escaped \* in .gitignore should match only literal *.'
    $escRuleQmark = Convert-IgnorePatternToRule -Line 'what\?.txt'
    Assert-True ((Test-PathIgnored -RelativePath 'what?.txt' -IsDir $false -Rules @($escRuleQmark)) -and (-not (Test-PathIgnored -RelativePath 'what1.txt' -IsDir $false -Rules @($escRuleQmark)))) 'Escaped \? in .gitignore should match only literal ?.'

    # Regression (Task 7): Find-EditMatch normalizes CRLF old_text (with or without trailing CRLF) against LF file content.
    $lfContent = "line1`nline2`nline3`n"
    $mExactCrlf = Find-EditMatch -Content $lfContent -OldText "line1`r`nline2"
    Assert-True ($mExactCrlf.index -eq 0 -and $mExactCrlf.matched_text -ceq "line1`nline2") 'Find-EditMatch should match CRLF old_text against LF file content.'
    $mExactCrlfTrail = Find-EditMatch -Content $lfContent -OldText "line1`r`nline2`r`n"
    Assert-True ($mExactCrlfTrail.index -eq 0 -and $mExactCrlfTrail.matched_text -ceq "line1`nline2`n") 'Find-EditMatch should match CRLF old_text with trailing CRLF against LF file content.'
    $mFuzzyCrlfTrail = Find-EditMatch -Content $lfContent -OldText "line1   `r`nline2`r`n"
    Assert-True ($mFuzzyCrlfTrail.index -eq 0 -and $mFuzzyCrlfTrail.matched_text -ceq "line1`nline2") 'Find-EditMatch fuzzy line matching should strip single trailing newline on CRLF old_text.'

    # Regression (Task 8): ConvertFrom-HtmlToText decodes &amp; last; Invoke-AgentWebSearch decodes &amp; in uddg redirect links.
    $htmlText = ConvertFrom-HtmlToText -Html '<p>Escaped: &amp;lt;tag&amp;gt; &amp;quot;q&amp;quot;</p>'
    Assert-True ($htmlText -ceq 'Escaped: &lt;tag&gt; &quot;q&quot;') "Expected '&lt;tag&gt; &quot;q&quot;', got '$htmlText'"
    $savedPermSearch8 = $script:AgentPermission
    $savedWebDl8 = ${function:Invoke-AgentWebDownload}
    try {
        $script:AgentPermission = 'AutoEdit'
        function Invoke-AgentWebDownload {
            param([string]$Uri, [string]$OutFile, [int]$MaxBytes = 2097152)
            $ddgHtml = '<div class="result"><a class="result__a" href="//duckduckgo.com/l/?kh=-1&amp;uddg=https%3A%2F%2Fexample.com%2Fpath%3Fa%3D1%26b%3D2">Example &amp;lt;Title&amp;gt;</a><a class="result__snippet">Snippet &amp;amp; text</a></div>'
            Set-Content -LiteralPath $OutFile -Value $ddgHtml -Encoding UTF8 -NoNewline
        }
        $wsRes8 = Invoke-AgentWebSearch -Arguments @{ query = 'test query'; limit = 5 } | ConvertFrom-Json
        Assert-True ($wsRes8.count -eq 1 -and $wsRes8.results[0].url -ceq 'https://example.com/path?a=1&b=2') "Expected decoded uddg URL after &amp;, got '$($wsRes8.results[0].url)'"
        Assert-True ($wsRes8.results[0].title -ceq 'Example &lt;Title&gt;' -and $wsRes8.results[0].snippet -ceq 'Snippet &amp; text') 'Invoke-AgentWebSearch double-decoded HTML entities in title or snippet.'
    }
    finally {
        $script:AgentPermission = $savedPermSearch8
        ${function:Invoke-AgentWebDownload} = $savedWebDl8
    }

    # Regression (Task 9): Normalizers drop redundant alias keys when canonical keys are also present so Test-AgentToolArguments succeeds.
    foreach ($toolName9 in @('list_files', 'read_file', 'find_files', 'grep_files', 'write_file')) {
        $baseArgs9 = @{ path = 'a.txt'; file_path = 'b.txt'; filepath = 'c.txt' }
        if ($toolName9 -eq 'find_files' -or $toolName9 -eq 'grep_files') { $baseArgs9['pattern'] = 'x' }
        if ($toolName9 -eq 'write_file') { $baseArgs9['content'] = 'hello' }
        $norm9 = Format-AgentToolArguments -Name $toolName9 -Arguments $baseArgs9
        Assert-True ($norm9['path'] -eq 'a.txt' -and (-not $norm9.ContainsKey('file_path')) -and (-not $norm9.ContainsKey('filepath'))) "Format-AgentToolArguments did not drop path aliases for $toolName9."
        Test-AgentToolArguments -Name $toolName9 -Arguments $norm9
    }
    $normEdit9 = Format-EditArguments -Arguments @{
        path = 'a.txt'; file_path = 'a.txt'; filePath = 'a.txt'
        old_text = 'o'; oldText = 'o'; new_text = 'n'; newText = 'n'
    }
    Assert-True ((-not $normEdit9.ContainsKey('file_path')) -and (-not $normEdit9.ContainsKey('oldText')) -and (-not $normEdit9.ContainsKey('newText'))) 'Format-EditArguments did not drop redundant aliases.'
    Test-AgentToolArguments -Name 'edit_file' -Arguments $normEdit9

    $normBatchEdit9 = Format-EditArguments -Arguments @{
        path = 'a.txt'; file_path = 'a.txt'
        edits = @(@{ old_text = 'o1'; oldText = 'o1'; new_text = 'n1'; newText = 'n1' })
    }
    Assert-True ((-not $normBatchEdit9.ContainsKey('file_path')) -and (-not $normBatchEdit9.edits[0].ContainsKey('oldText')) -and (-not $normBatchEdit9.edits[0].ContainsKey('newText'))) 'Format-EditArguments did not drop redundant batch aliases.'
    Test-AgentToolArguments -Name 'edit_file' -Arguments $normBatchEdit9

    $normRunSingle9 = Format-RunAgentArguments -Arguments @{
        prompt = 'p'; task = 't'; role = 'recon'; agent = 'recon'; max_steps = 5; maxSteps = 5
    }
    Assert-True ((-not $normRunSingle9.ContainsKey('task')) -and (-not $normRunSingle9.ContainsKey('agent')) -and (-not $normRunSingle9.ContainsKey('maxSteps'))) 'Format-RunAgentArguments did not drop single-task aliases.'
    Test-AgentToolArguments -Name 'run_agent' -Arguments $normRunSingle9

    $normRunPar9 = Format-RunAgentArguments -Arguments @{
        parallel = @(@{ prompt = 'p1'; task = 't1'; role = 'recon'; agent = 'recon' }); tasks = @()
    }
    Assert-True ((-not $normRunPar9.ContainsKey('tasks')) -and (-not $normRunPar9.parallel[0].ContainsKey('task')) -and (-not $normRunPar9.parallel[0].ContainsKey('agent'))) 'Format-RunAgentArguments did not drop parallel aliases.'
    Test-AgentToolArguments -Name 'run_agent' -Arguments $normRunPar9

    $normRunPipe9 = Format-RunAgentArguments -Arguments @{
        pipeline = @(@{ prompt = 'p2'; task = 't2'; role = 'craft'; agent = 'craft' }); chain = @(); steps = @()
    }
    Assert-True ((-not $normRunPipe9.ContainsKey('chain')) -and (-not $normRunPipe9.ContainsKey('steps')) -and (-not $normRunPipe9.pipeline[0].ContainsKey('task')) -and (-not $normRunPipe9.pipeline[0].ContainsKey('agent'))) 'Format-RunAgentArguments did not drop pipeline aliases.'
    Test-AgentToolArguments -Name 'run_agent' -Arguments $normRunPipe9

    $normTodo9 = Format-TodoArguments -Arguments @{
        todos = @(@{ content = 'c'; task = 't'; title = 'ti'; text = 'tx'; description = 'd'; status = 'pending'; state = 'pending'; done = $false })
        tasks = @(); items = @(); checklist = @()
    }
    Assert-True ((-not $normTodo9.ContainsKey('tasks')) -and (-not $normTodo9.ContainsKey('items')) -and (-not $normTodo9.ContainsKey('checklist'))) 'Format-TodoArguments did not drop top-level aliases.'
    Assert-True ((-not $normTodo9.todos[0].ContainsKey('task')) -and (-not $normTodo9.todos[0].ContainsKey('title')) -and (-not $normTodo9.todos[0].ContainsKey('state')) -and (-not $normTodo9.todos[0].ContainsKey('done'))) 'Format-TodoArguments did not drop item-level aliases.'
    Test-AgentToolArguments -Name 'todo' -Arguments $normTodo9

    # Regression (Task 12): Invoke-SubagentInProcess preserves session-wide [a]ll permission upgrades from craft subagents
    # and syncs parent <memory> block when subagent updates MEMORY.md.
    $savedPerm12 = $script:AgentPermission
    $savedMode12 = $script:OutputMode
    $savedState12 = $script:ActiveState
    $savedApproval12 = $script:approval
    try {
        $script:AgentPermission = 'Ask'
        $script:OutputMode = 'text'
        $script:approval = 'a'
        $parentSys12 = Build-SystemPrompt -Root $workspacePath -ConfigDir ''
        $parentState12 = @{
            session_id = 'parent-12'
            workspace = $workspacePath
            model = 'test-model'
            messages = @(@{ role = 'system'; content = $parentSys12 })
        }
        $script:ActiveState = $parentState12
        $script:sub12Step = 0
        function Write-Host {
            param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        }
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:sub12Step++
            if ($script:sub12Step -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 's12-m1'; type = 'function'; function = @{ name = 'memory'; arguments = '{"action":"set","scope":"workspace","content":"Subagent learned invariant 12"}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Updated memory and approved all edits.' } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $sub12Res = Invoke-SubagentInProcess -Root $workspacePath -RoleName 'craft' -TaskPrompt 'Record invariant' -ContextMode 'clean' -MaxSteps 4
        Assert-True ($sub12Res.status -eq 'completed') 'Craft subagent in Task 12 did not complete.'
        Assert-True ($script:AgentPermission -eq 'AutoEdit') "Expected session-wide [a]ll upgrade to AutoEdit to persist after craft subagent, got '$($script:AgentPermission)'."
        Assert-True (([string]$parentState12.messages[0].content).Contains('Subagent learned invariant 12')) 'Parent system prompt did not sync <memory> changes made inside subagent.'
    }
    finally {
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        $memFile12 = Join-Path $workspacePath '.shellossus/MEMORY.md'
        if (Test-Path -LiteralPath $memFile12) { Remove-Item -LiteralPath $memFile12 -Force -ErrorAction SilentlyContinue }
        $script:AgentPermission = $savedPerm12
        $script:OutputMode = $savedMode12
        $script:ActiveState = $savedState12
        $script:approval = $savedApproval12
    }

    # Regression (Task 15): Test-SafeWebUrl blocks uncompressed zero IPv6 prefixes and CGNAT/multicast inside IPv6 without blocking 2001:db8::, 2002::, or 100::.
    foreach ($badIpv6Url15 in @(
        'http://[0:0:0:0:0:0:127.0.0.1]/',
        'http://[0:0:0:0:0:ffff:127.0.0.1]/',
        'http://[::100.64.0.1]/',
        'http://[::ffff:100.64.0.1]/',
        'http://[::224.0.0.1]/',
        'http://[::ffff:224.0.0.1]/',
        'http://[::6440:1]/',
        'http://[::e000:1]/'
    )) {
        $blocked15 = $false
        try { Test-SafeWebUrl -Url $badIpv6Url15 | Out-Null } catch { $blocked15 = $true }
        Assert-True $blocked15 "Expected $badIpv6Url15 to be blocked by Test-SafeWebUrl."
    }
    foreach ($goodIpv6Url15 in @(
        'https://[2001:db8::1]/',
        'https://[2002::1]/',
        'https://[100::1]/'
    )) {
        Assert-True (Test-SafeWebUrl -Url $goodIpv6Url15) "Expected $goodIpv6Url15 to be allowed by Test-SafeWebUrl."
    }

    # Task 2: canonical address classification, independent of host-text denylist.
    foreach ($blockedAddr in @(
        '10.0.0.1',
        '127.0.0.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '192.168.1.1',
        '172.16.0.1',
        '224.0.0.1',
        '::1',
        'fe80::1',
        'fe80::1%lo0',
        'fd00::1',
        '::ffff:10.0.0.1',
        '64:ff9b::8.8.8.8',
        '64:ff9b:1::127.0.0.1',
        '64:ff9b:1::7f00:1',
        '::ffff:0:7f00:1',
        '::ffff:0:10.0.0.1'
    )) {
        Assert-True (Test-BlockedWebAddress -Address $blockedAddr) "Test-BlockedWebAddress did not block $blockedAddr."
    }
    foreach ($publicAddr in @(
        '8.8.8.8',
        '1.1.1.1',
        '2001:db8::1',
        '::ffff:8.8.8.8'
    )) {
        Assert-True (-not (Test-BlockedWebAddress -Address $publicAddr)) "Test-BlockedWebAddress blocked public address $publicAddr."
    }

    # Task 2: the download worker blocks resolved local addresses before Invoke-WebRequest.
    # Do not define function Invoke-WebRequest here; that branch skips the worker.
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    $downloadCmd = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    Assert-True ($downloadCmd -and $downloadCmd.CommandType -ne 'Function') 'Invoke-WebRequest was a function, so the download worker did not run.'
    foreach ($blockedUri in @(
        'http://10.0.0.1/',
        'http://127.0.0.1/',
        'http://169.254.169.254/',
        'http://100.64.0.1/',
        'http://localhost/'
    )) {
        $blockedOut = Join-Path $testRoot ('blocked-web-' + ($blockedUri -replace '[^0-9A-Za-z]', '-') + '.tmp')
        if (Test-Path -LiteralPath $blockedOut) { Remove-Item -LiteralPath $blockedOut -Force }
        $blockedThrew = $false
        $blockedMsg = ''
        try {
            Invoke-AgentWebDownload -Uri $blockedUri -OutFile $blockedOut
        }
        catch {
            $blockedThrew = $true
            $blockedMsg = [string]$_
        }
        Assert-True $blockedThrew "Invoke-AgentWebDownload did not throw for $blockedUri."
        Assert-True ($blockedMsg -like '*Blocked request*') "Invoke-AgentWebDownload for $blockedUri did not report Blocked request: $blockedMsg"
        $blockedExists = Test-Path -LiteralPath $blockedOut
        $blockedEmpty = $false
        if ($blockedExists) {
            $blockedEmpty = ((Get-Item -LiteralPath $blockedOut -Force).Length -eq 0)
        }
        Assert-True ((-not $blockedExists) -or $blockedEmpty) "Invoke-AgentWebDownload wrote a response body for $blockedUri."
        if ($blockedExists) { Remove-Item -LiteralPath $blockedOut -Force -ErrorAction SilentlyContinue }
    }
}
finally {
    Remove-TestEnvironment -Env $envData
}
