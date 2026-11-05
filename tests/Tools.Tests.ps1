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
    $lineTrunc = Invoke-TruncateLine -Line ('x' * 600) -MaxChars 500
    Assert-True ($lineTrunc.was_truncated -and $lineTrunc.text.EndsWith('... [truncated]')) 'Invoke-TruncateLine failed.'

    $normArgs = Format-EditArguments -ArgsObj ([pscustomobject]@{ path = 'hello.txt'; oldText = 'a'; newText = 'b'; edits = '[{"oldText":"x","newText":"y"}]' })
    Assert-True ($normArgs.old_text -eq 'a' -and $normArgs.new_text -eq 'b' -and $normArgs.edits[0].old_text -eq 'x' -and $normArgs.edits[0].new_text -eq 'y') 'Format-EditArguments camelCase / JSON edits normalization failed.'
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
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
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

    # memory tool tests
    Assert-True ((Resolve-ToolCanonicalName 'memory') -eq 'memory') 'Canonical memory name resolution failed.'
    Assert-True ((Resolve-ToolCanonicalName 'remember') -eq 'memory') 'Canonical remember alias resolution failed.'
    Assert-True ((Resolve-ToolCanonicalName 'manage_memory') -eq 'memory') 'Canonical manage_memory alias resolution failed.'
    Assert-True ((Resolve-ToolCanonicalName 'recall') -eq 'memory') 'Canonical recall alias resolution failed.'

    $memNorm = Format-MemoryArguments -ArgsObj ([pscustomobject]@{ note = 'Use UTF-8'; action = 'APPEND'; scope = 'WORKSPACE' })
    Assert-True ($memNorm.action -eq 'append' -and $memNorm.scope -eq 'workspace' -and $memNorm.content -eq 'Use UTF-8') 'Format-MemoryArguments normalization failed.'

    # append memory
    $memAppendCall = @{
        id = 'mem-1'
        function = @{
            name = 'memory'
            arguments = '{"action":"append","content":"Keep all scripts ASCII"}'
        }
    }
    $memAppendRes = Invoke-AgentTool -Root $workspacePath -Call $memAppendCall | ConvertFrom-Json
    Assert-True ($memAppendRes.success -and $memAppendRes.action -eq 'append' -and ($memAppendRes.memory -like '*Keep all scripts ASCII*')) 'memory append failed.'

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

    # ReadOnly blocks memory append
    $script:AgentPermission = 'ReadOnly'
    $roMemRes = Invoke-AgentTool -Root $workspacePath -Call $memAppendCall | ConvertFrom-Json
    Assert-True ($roMemRes.error -like '*ReadOnly*') 'ReadOnly mode did not block memory modification.'
    $script:AgentPermission = 'Ask'
}
finally {
    Remove-TestEnvironment -Env $envData
}
