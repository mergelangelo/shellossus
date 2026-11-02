$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\..\build.ps1" -Check
. "$PSScriptRoot\..\h-agent.ps1" -LibraryOnly

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path $env:TEMP ('h-agent-' + [guid]::NewGuid().ToString('N'))
$workspacePath = Join-Path $testRoot 'workspace'
New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $workspacePath 'hello.txt') -Value 'hello' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $testRoot 'outside.txt') -Value 'private' -Encoding UTF8
    $call = @{ id = 't1'; function = @{ name = 'read_file'; arguments = '{"path":"hello.txt"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.text -eq 'hello') 'Text read failed.'
    $call.function.arguments = '{"path":"../outside.txt"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -like '*outside*') 'Workspace escape was not rejected.'
    $call.function.name = 'execute_command'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -eq 'Unknown tool.') 'Unknown tool was not rejected.'
    $call.function.name = 'read_file'
    $call.function.arguments = '{broken'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Malformed arguments were not rejected.'

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

    # Config is parsed as data; embedded PowerShell expressions stay literal.
    $configPath = Join-Path $testRoot '.env'
    Save-AgentConfig -Path $configPath -Config @{
        H_AGENT_BASE_URL = 'https://example.invalid/v1'
        H_AGENT_MODEL = 'test-model'
        H_AGENT_API_KEY = 'fake=key#$(throw injected)'
        H_AGENT_WORKSPACE = 'C:\folder with spaces'
    }
    $loadedConfig = Read-AgentConfig -Path $configPath
    Assert-True ($loadedConfig.H_AGENT_API_KEY -eq 'fake=key#$(throw injected)') 'Config value was corrupted or evaluated.'
    Assert-True ($loadedConfig.H_AGENT_WORKSPACE -eq 'C:\folder with spaces') 'Config path changed.'
    $absentConfig = Read-AgentConfig -Path (Join-Path $testRoot 'missing.env')
    Assert-True ($absentConfig.Count -eq 0) 'Missing config should produce empty settings.'
    Set-Content -LiteralPath (Join-Path $workspacePath '.env') -Value 'SECRET=hidden' -Encoding UTF8
    $call.function.name = 'read_file'
    $call.function.arguments = '{"path":".env"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Agent must not read .env.'
    $customCfg = Join-Path $workspacePath 'custom.cfg'
    Set-Content -LiteralPath $customCfg -Value 'H_AGENT_API_KEY="secret"' -Encoding UTF8
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $workspacePath '.\custom.cfg')
    $call.function.arguments = '{"path":"custom.cfg"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -like '*credential*') 'Agent must not read custom ConfigPath.'

    Set-Content -LiteralPath (Join-Path $workspacePath '.gitignore') -Value '*.log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workspacePath '.env.example') -Value 'H_AGENT_MODEL=""' -Encoding UTF8
    $call.function.name = 'list_files'
    $call.function.arguments = '{"path":"."}'
    $listing = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($listing.entries.Name -contains '.gitignore') 'list_files missed .gitignore.'
    Assert-True ($listing.entries.Name -contains '.env.example') 'list_files missed .env.example.'
    Assert-True ($listing.entries.Name -notcontains '.env') 'list_files exposed .env.'
    Assert-True ($listing.entries.Name -notcontains 'custom.cfg') 'list_files exposed custom ConfigPath.'

    $script:approval = ''
    $script:prompts = 0
    function Read-Host {
        param($Prompt)
        $script:prompts++
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

    # write_file with overwrite=true backs up and replaces content after WRITE confirmation.
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

    # run_command requires RUN confirmation and executes isolated PowerShell commands.
    $call.function.name = 'run_command'
    $call.function.arguments = '{"command":"Write-Output \"cmd-ok\""}'
    $script:approval = 'WRITE'
    $cmdDeclined = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($cmdDeclined.status -eq 'cancelled') 'run_command must require RUN approval.'
    $script:approval = 'RUN'
    $cmdApproved = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($cmdApproved.status -eq 'executed' -and $cmdApproved.exit_code -eq 0 -and $cmdApproved.output.Trim() -eq 'cmd-ok') 'Approved run_command failed.'
    $script:approval = 'WRITE'

    # AGENTS.md, SYSTEM.md, APPEND_SYSTEM.md, Skills catalog, Prompt templates, and @file prompt expansion.
    Set-Content -LiteralPath (Join-Path $workspacePath 'AGENTS.md') -Value 'Always use snake_case.' -Encoding UTF8
    $dotH = Join-Path $workspacePath '.h-agent'
    $skillFolder = Join-Path $dotH 'skills\sql-tuning'
    $promptFolder = Join-Path $dotH 'prompts'
    New-Item -ItemType Directory -Path $skillFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $promptFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dotH 'APPEND_SYSTEM.md') -Value 'Prefer CTEs over subqueries.' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $skillFolder 'SKILL.md') -Value "---`nname: sql-tuning`ndescription: Optimize heavy SQL queries`n---`nCheck indexes." -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $promptFolder 'review.md') -Value 'Review carefully: $ARGUMENTS' -Encoding UTF8
    $fullSys = Build-SystemPrompt -Root $workspacePath -ConfigDir ''
    Assert-True ($fullSys.Contains('Always use snake_case.') -and $fullSys.Contains('Prefer CTEs over subqueries.') -and $fullSys.Contains('sql-tuning')) 'Build-SystemPrompt missed AGENTS.md, APPEND_SYSTEM.md, or skills.'
    $tpl = Resolve-PromptTemplate -Root $workspacePath -ConfigDir '' -InputText '/review @hello.txt'
    Assert-True ($tpl -eq 'Review carefully: @hello.txt') 'Prompt template expansion failed.'
    $expanded = Expand-UserPrompt -Root $workspacePath -Prompt 'Check @hello.txt and @.env'
    Assert-True ($expanded.Contains('<file path="hello.txt">') -and (-not $expanded.Contains('SECRET=hidden'))) '@file expansion failed or leaked .env.'

    # read_file max_lines and total_lines metadata.
    $call.function.name = 'read_file'
    $call.function.arguments = '{"path":"long.txt","start_line":10,"max_lines":5}'
    $sliceRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($sliceRes.total_lines -eq 350 -and $sliceRes.start_line -eq 10 -and $sliceRes.end_line -eq 14 -and $sliceRes.next_start_line -eq 15) 'read_file max_lines/total_lines metadata failed.'

    # Fuzzy edit_file matching (trailing spaces + smart quotes) and /undo disk rollback.
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

    # Batch edits[] in edit_file (multiple non-overlapping edits + overlap rejection).
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
    Assert-True (@(Get-AgentTools).Count -eq 4) 'ReadOnly mode should only expose 4 read-only tools.'
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

    # Truncated run_command saves full log under .h-agent/output/*.log.
    $call.function.arguments = '{"command":"1..320 | ForEach-Object { $_ }"}'
    $truncCmd = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($truncCmd.truncated -and [bool]$truncCmd.full_output_path -and (Test-Path -LiteralPath (Join-Path $workspacePath $truncCmd.full_output_path))) 'Truncated run_command did not save full output log.'
    $script:AgentPermission = 'Ask'
    $script:approval = 'WRITE'

    # Enhanced grep_files with include filter and context_lines.
    $call.function.name = 'grep_files'
    $call.function.arguments = '{"path":".","pattern":"two","include":"batch.txt","context_lines":1}'
    $ctxGrep = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($ctxGrep.matches.Count -eq 1 -and $ctxGrep.matches[0].context.Count -ge 2) 'grep_files include/context_lines failed.'

    # Session JSONL persistence roundtrip and project-scoped session lookup.
    $sessionDirTest = Join-Path $testRoot 'sessions'
    $sessionFile = Join-Path $sessionDirTest 'test-ws1.jsonl'
    $otherWs = Join-Path $testRoot 'other-workspace'
    New-Item -ItemType Directory -Path $otherWs -Force | Out-Null
    $sampleState = @{ messages = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'hi' },
        @{ role = 'assistant'; content = 'hello' }
    ) }
    Save-AgentSession -SessionFile $sessionFile -State $sampleState -Workspace $workspacePath -Model 'model-a' -SessionId 'sid-1'
    $meta1 = Get-AgentSessionMeta -SessionFile $sessionFile
    Assert-True ($meta1.version -eq 1 -and $meta1.id -eq 'sid-1' -and $meta1.model -eq 'model-a') 'Session metadata header missing or invalid.'
    $restoredState = @{}
    $restoredMsgs = @(Read-AgentSession -SessionFile $sessionFile -State $restoredState)
    Assert-True ($restoredMsgs.Count -eq 3 -and $restoredMsgs[2].content -eq 'hello' -and $restoredState.session_id -eq 'sid-1') 'Session JSONL roundtrip failed.'
    Start-Sleep -Milliseconds 50
    $otherSessionFile = Join-Path $sessionDirTest 'test-ws2.jsonl'
    Save-AgentSession -SessionFile $otherSessionFile -State $sampleState -Workspace $otherWs -Model 'model-b' -SessionId 'sid-2'
    $foundWs1 = Find-ProjectSession -SessionDir $sessionDirTest -Workspace $workspacePath
    Assert-True ($foundWs1 -eq (Get-Item -LiteralPath $sessionFile -Force).FullName) 'Find-ProjectSession did not select the current workspace session.'
    $crossResumeThrew = $false
    try {
        Invoke-SessionResume -SessionFile $otherSessionFile -State @{} -CurrentWorkspace $workspacePath | Out-Null
    }
    catch {
        if ($_.Exception.Message -like '*different workspace*') { $crossResumeThrew = $true }
    }
    Assert-True $crossResumeThrew 'Invoke-SessionResume must reject sessions from a different workspace.'
    $dirtyState = @{
        model = 'stale-model'
        undo_stack = @(@{ dummy = 1 })
        last_failed_question = 'old-failure'
        messages = @()
    }
    Invoke-SessionResume -SessionFile $sessionFile -State $dirtyState -CurrentWorkspace $workspacePath | Out-Null
    Assert-True ($dirtyState.model -eq 'model-a' -and $dirtyState.undo_stack.Count -eq 0 -and $dirtyState.last_failed_question -eq '' -and $dirtyState.messages.Count -eq 3) 'Invoke-SessionResume did not synchronize model or clear undo_stack/last_failed_question.'

    # Failed /undo preserves backup, refuses to overwrite manual edits, and succeeds on retry after conflict resolution.
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
    # Resolve conflict on manual-guard-1.txt and retry /undo on the same UndoEntry (including partial undone state where one backup was already consumed).
    Copy-Item -LiteralPath $mgRes2.backup -Destination (Join-Path $workspacePath 'manual-guard-2.txt') -Force
    Remove-Item -LiteralPath $mgRes2.backup -Force
    $mgUndoEntry.writes[1].undone = $true
    Set-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Value 'v2-a' -Encoding UTF8 -NoNewline
    Invoke-AgentUndo -State $mgState -UndoEntry $mgUndoEntry
    Assert-True ($mgState.messages.Count -eq 1) 'Retry undo after resolving conflict did not restore message state.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-1.txt') -Raw -Encoding UTF8) -eq 'v1-a') 'Retry undo did not restore first file.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'manual-guard-2.txt') -Raw -Encoding UTF8) -eq 'v1-b') 'Retry undo did not preserve second file.'

    # Multi-step /undo on the same file within a single turn:
    # 1) write_file (create) -> edit_file -> /undo removes the created file and intermediate backup.
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
    # 2) edit_file -> edit_file -> /undo restores the original content before the first edit.
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

    # read_file respects 20,000-char limit without skipping lines and supports start_char for >20,000-char single lines.
    $lines350 = 1..350 | ForEach-Object { ('L{0:D3}_' -f $_) + ('x' * 95) }
    Set-Content -LiteralPath (Join-Path $workspacePath 'lines350.txt') -Value ($lines350 -join "`n") -Encoding UTF8 -NoNewline
    $call.function.name = 'read_file'
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

    # grep_files reports truncated=true and next_file_offset when hitting 500-file scan limit.
    $grepDir501 = Join-Path $workspacePath 'grep501'
    New-Item -ItemType Directory -Path $grepDir501 -Force | Out-Null
    1..500 | ForEach-Object {
        $fname = Join-Path $grepDir501 ('f{0:D4}.txt' -f $_)
        Set-Content -LiteralPath $fname -Value 'haystack' -Encoding UTF8 -NoNewline
    }
    Set-Content -LiteralPath (Join-Path $grepDir501 'f0501.txt') -Value 'NEEDLE_501' -Encoding UTF8 -NoNewline
    $call.function.name = 'grep_files'
    $call.function.arguments = '{"path":"grep501","pattern":"NEEDLE_501","literal":true}'
    $g501Page1 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($g501Page1.matches.Count -eq 0 -and $g501Page1.truncated -eq $true -and $g501Page1.truncation_reason -eq 'max_files' -and $g501Page1.files_scanned -eq 500 -and $g501Page1.total_files -eq 501 -and $g501Page1.next_file_offset -eq 500) 'grep_files did not report file-limit truncation on 501 files.'
    $call.function.arguments = '{"path":"grep501","pattern":"NEEDLE_501","literal":true,"file_offset":500}'
    $g501Page2 = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($g501Page2.matches.Count -eq 1 -and $g501Page2.truncated -eq $false -and $g501Page2.files_scanned -eq 1) 'grep_files failed to find match in 501st file using file_offset.'
    Remove-Item -LiteralPath $grepDir501 -Recurse -Force

    # Large file (>20,000 chars) edit_file works without hitting preview limit.
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

    # Strict tool argument validation (reject string "false" for boolean, unknown parameters, missing required).
    $call.function.name = 'write_file'
    $call.function.arguments = '{"path":"created.txt","content":"bad","overwrite":"false"}'
    $badBool = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($badBool.error -like '*must be a boolean*') 'String "false" was coerced to boolean instead of rejected.'
    $call.function.name = 'list_files'
    $call.function.arguments = '{"path":".","extra_field":1}'
    $badUnknown = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($badUnknown.error -like '*Unknown argument*') 'Unknown tool argument was not rejected.'

    # Global skills in ConfigDir/skills can be read via read_file, while writes outside workspace stay blocked.
    $globalCfgDir = Join-Path $testRoot 'global-cfg'
    $globalSkillDir = Join-Path $globalCfgDir 'skills\corp-standard'
    New-Item -ItemType Directory -Path $globalSkillDir -Force | Out-Null
    $globalSkillPath = Join-Path $globalSkillDir 'SKILL.md'
    Set-Content -LiteralPath $globalSkillPath -Value "---`nname: corp-standard`ndescription: Global skill`n---`nGlobal rules body." -Encoding UTF8
    $sysWithGlobal = Build-SystemPrompt -Root $workspacePath -ConfigDir $globalCfgDir
    Assert-True ($sysWithGlobal.Contains('corp-standard')) 'Global skill was not listed in system prompt.'
    $call.function.name = 'read_file'
    $call.function.arguments = (@{ path = $globalSkillPath } | ConvertTo-Json -Compress)
    $readGlobalSkill = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($readGlobalSkill.text -like '*Global rules body*') 'Global skill could not be read via read_file.'
    $call.function.name = 'edit_file'
    $call.function.arguments = (@{ path = $globalSkillPath; old_text = 'Global'; new_text = 'Hacked' } | ConvertTo-Json -Compress)
    $editGlobalSkill = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($editGlobalSkill.error -like '*outside*') 'Editing global skill outside workspace must be blocked.'

    # Command timeout terminates hanging process and returns timed_out status.
    $script:AgentPermission = 'Auto'
    $call.function.name = 'run_command'
    $call.function.arguments = '{"command":"Start-Sleep -Seconds 10","timeout_sec":1}'
    $timeoutRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($timeoutRes.status -eq 'timed_out' -and $timeoutRes.timed_out -eq $true) 'Hanging run_command was not terminated on timeout.'
    $script:AgentPermission = 'Ask'
    $script:approval = 'WRITE'

    # Exercise the agent/tool/API round trip without any network or real key.
    $script:requests = 0
    $script:lastCompactBody = ''
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction)
        $script:requests++
        $payload = $Body | ConvertFrom-Json
        Assert-True ($Method -eq 'Post') 'Expected POST.'
        Assert-True ($payload.model -eq 'test-model') 'Wrong model.'
        if ($payload.messages[0].content -like '*compaction assistant*') {
            $script:lastCompactBody = [string]$payload.messages[1].content
            return @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = "## Goal`nTest summary" } }) }
        }
        if ($script:requests -eq 1) {
            return @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = $null
                reasoning_content = 'Inspect directory.'
                tool_calls = @(@{ id = 't1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
            } }) }
        }
        $last = $payload.messages[-1]
        Assert-True ($last.role -eq 'tool' -and $last.tool_call_id -eq 't1') 'Missing tool response.'
        $listing = $last.content | ConvertFrom-Json
        Assert-True ($listing.entries.Name -contains 'hello.txt') 'Tool result missing file.'
        return @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Files inspected.' } }) }
    }
    # Match the UTF-8 response-file transport, with no real HTTP request.
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $mockReply = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body -TimeoutSec $TimeoutSec -ErrorAction $ErrorAction
        $mockReply | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    }
    $state = @{ messages = @(@{ role = 'user'; content = 'List files' }) }
    Invoke-AgentTurn -State $state -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 3
    Assert-True ($script:requests -eq 2) 'Expected two API calls.'
    Assert-True ($state.messages[-1].content -eq 'Files inspected.') 'Missing final answer.'

    # Invoke-AgentCompact includes tool call names, arguments (e.g. file paths), and tool results in summary prompt.
    $compactState = @{ messages = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'Update query' },
        @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'tc9'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"important-query.sql","old_text":"SELECT 1","new_text":"SELECT 2"}' } }) },
        @{ role = 'tool'; tool_call_id = 'tc9'; content = '{"status":"written","path":"important-query.sql"}' },
        @{ role = 'assistant'; content = 'Updated query.' },
        @{ role = 'user'; content = 'Recent question' },
        @{ role = 'assistant'; content = 'Recent answer' }
    ) }
    $didCompact = Invoke-AgentCompact -State $compactState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -KeepRecent 2
    Assert-True ($didCompact -and $script:lastCompactBody.Contains('edit_file') -and $script:lastCompactBody.Contains('important-query.sql')) 'Compaction dropped tool call name or file path.'
    Assert-True ($compactState.messages[1].content.Contains('<modified-files>') -and $compactState.messages[1].content.Contains('important-query.sql')) 'Compaction summary missing <modified-files> XML.'

    # Iterative compaction passes <previous-summary> and Find-CompactionCutPoint never cuts on a tool result.
    $compactState.messages += @(
        @{ role = 'user'; content = 'Read another file' },
        @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'tc10'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"schema.sql"}' } }) },
        @{ role = 'tool'; tool_call_id = 'tc10'; content = '{"path":"schema.sql","text":"CREATE TABLE t(id INT);"}' },
        @{ role = 'assistant'; content = 'Schema inspected.' },
        @{ role = 'user'; content = 'Final question' },
        @{ role = 'assistant'; content = 'Final answer' }
    )
    $cutInfo = Find-CompactionCutPoint -Messages $compactState.messages -StartIndex 1 -KeepRecentTokens 10
    Assert-True ($compactState.messages[$cutInfo.first_kept_index].role -ne 'tool') 'Find-CompactionCutPoint cut directly on a tool message.'
    $didIterativeCompact = Invoke-AgentCompact -State $compactState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -KeepRecent 2
    Assert-True ($didIterativeCompact -and $script:lastCompactBody.Contains('<previous-summary>')) 'Iterative compaction did not pass <previous-summary>.'
    Assert-True ($compactState.messages[1].content.Contains('<read-files>') -and $compactState.messages[1].content.Contains('schema.sql') -and $compactState.messages[1].content.Contains('important-query.sql')) 'Iterative compaction lost cumulative file operations.'

    # Truncation helpers (Invoke-TruncateHead, Invoke-TruncateTail, Invoke-TruncateLine, Format-ByteSize).
    Assert-True ((Format-ByteSize -Bytes 1536) -eq '1.5KB') 'Format-ByteSize failed.'
    $headRes = Invoke-TruncateHead -Content ("line1`nline2`nline3`nline4") -MaxLines 2 -MaxBytes 1000
    Assert-True ($headRes.truncated -and $headRes.truncated_by -eq 'lines' -and $headRes.output_lines -eq 2 -and $headRes.content -eq "line1`nline2") 'Invoke-TruncateHead lines limit failed.'
    $tailRes = Invoke-TruncateTail -Content ("line1`nline2`nline3`nline4") -MaxLines 2 -MaxBytes 1000
    Assert-True ($tailRes.truncated -and $tailRes.truncated_by -eq 'lines' -and $tailRes.output_lines -eq 2 -and $tailRes.content -eq "line3`nline4") 'Invoke-TruncateTail lines limit failed.'
    $lineTrunc = Invoke-TruncateLine -Line ('x' * 600) -MaxChars 500
    Assert-True ($lineTrunc.was_truncated -and $lineTrunc.text.EndsWith('... [truncated]')) 'Invoke-TruncateLine failed.'

    # .gitignore / .ignore with negation (!) and path globs in find_files and grep_files.
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

    # Format-EditArguments (oldText/newText camelCase and JSON-string edits) + Tool filtering.
    $normArgs = Format-EditArguments -ArgsObj ([pscustomobject]@{ path = 'hello.txt'; oldText = 'a'; newText = 'b'; edits = '[{"oldText":"x","newText":"y"}]' })
    Assert-True ($normArgs.old_text -eq 'a' -and $normArgs.new_text -eq 'b' -and $normArgs.edits[0].old_text -eq 'x' -and $normArgs.edits[0].new_text -eq 'y') 'Format-EditArguments camelCase / JSON edits normalization failed.'
    $script:EnabledTools = @('read', 'grep')
    $filteredTools = @(Get-AgentTools)
    Assert-True ($filteredTools.Count -eq 2) 'Tool filtering via $script:EnabledTools failed.'
    $script:EnabledTools = @()

    # Expand-TemplateArgs ($1, $@, $ARGUMENTS, ${2:-default}, ${@:2}, ${@:1:2}, non-recursive) & /skill:name.
    $tplOut = Expand-TemplateArgs -Content 'A=$1 B=${2:-fallback} ALL=$@ SLICE=${@:2} LEN=${@:1:2}' -ArgsString '"hello $2" world three'
    Assert-True ($tplOut -eq 'A=hello $2 B=world ALL=hello $2 world three SLICE=world three LEN=hello $2 world') 'Expand-TemplateArgs bash-style positional/slice/default substitution failed.'
    $skillCmdOut = Resolve-PromptTemplate -Root $workspacePath -ConfigDir $globalCfgDir -InputText '/skill:sql-tuning orders_table'
    Assert-True ($skillCmdOut.Contains('<skill name="sql-tuning"') -and $skillCmdOut.Contains('User: orders_table')) '/skill:name command expansion failed.'

    # Session Tree, Branch Switching, Session Forking, and HTML Export.
    $treeSessionDir = Join-Path $testRoot 'tree-sessions'
    New-Item -ItemType Directory -Path $treeSessionDir -Force | Out-Null
    $treeSessionFile = Join-Path $treeSessionDir 'tree-test.jsonl'
    $treeState = @{
        session_id = 'sess-tree-1'
        session_name = 'Tree Test'
        workspace = $workspacePath
        model = 'test-model'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Branch A user' },
            @{ role = 'assistant'; content = 'Branch A reply' }
        )
    }
    Ensure-SessionTree -State $treeState
    $firstUserEntryId = $treeState.messages[1].id
    $branchALeafId = $treeState.leaf_id
    Switch-SessionBranch -State $treeState -TargetId $firstUserEntryId | Out-Null
    Assert-True ($treeState.messages.Count -eq 2 -and $treeState.leaf_id -eq $firstUserEntryId) 'Switch-SessionBranch to earlier entry failed.'
    $treeState.messages += @{ role = 'assistant'; content = 'Branch B reply' }
    Ensure-SessionTree -State $treeState
    $branchBLeafId = $treeState.leaf_id
    $allNodes = @(Get-SessionTree -State $treeState)
    Assert-True ($allNodes.Count -eq 3 -and $branchALeafId -ne $branchBLeafId) 'Session tree failed to retain both branches.'
    Save-AgentSession -SessionFile $treeSessionFile -State $treeState -Workspace $workspacePath -Model 'test-model'
    $reloadedTreeState = @{ session_id = ''; workspace = $workspacePath; model = ''; messages = @() }
    Invoke-SessionResume -SessionFile $treeSessionFile -State $reloadedTreeState -CurrentWorkspace $workspacePath | Out-Null
    Switch-SessionBranch -State $reloadedTreeState -TargetId $branchALeafId | Out-Null
    Assert-True ($reloadedTreeState.messages[-1].content -eq 'Branch A reply') 'Saved session lost inactive tree branch on reload.'
    $forkResult = Invoke-SessionFork -State $reloadedTreeState -SessionDir $treeSessionDir -EntryId $firstUserEntryId -NewName 'Forked Session'
    Assert-True ((Test-Path -LiteralPath $forkResult.session_file) -and $forkResult.state.messages.Count -eq 2 -and $forkResult.state.parent_session -eq 'sess-tree-1') 'Invoke-SessionFork failed.'
    $htmlOutPath = Join-Path $testRoot 'exported-session.html'
    $exportedHtml = Export-AgentSessionHtml -State $reloadedTreeState -OutputPath $htmlOutPath
    $htmlContent = Get-Content -LiteralPath $exportedHtml -Raw -Encoding UTF8
    Assert-True ($htmlContent.Contains('<!DOCTYPE html>') -and $htmlContent.Contains('Branch A reply')) 'Export-AgentSessionHtml failed.'

    # Regression 1: Session tree preserves context compaction when switching to current leaf.
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = '## Goal`nCompacted goal summary' } }) } | ConvertTo-Json -Depth 10 -Compress
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    $compTreeState = @{
        session_id = 'sess-comp-tree'
        workspace = $workspacePath
        model = 'test-model'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'old user 1' },
            @{ role = 'assistant'; content = 'old assistant 1' },
            @{ role = 'user'; content = 'recent user 2' },
            @{ role = 'assistant'; content = 'recent assistant 2' }
        )
    }
    Ensure-SessionTree -State $compTreeState
    $compOk = Invoke-AgentCompact -State $compTreeState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -KeepRecent 2
    Assert-True ($compOk -and $compTreeState.messages[1].content.StartsWith('[Compacted Conversation Summary]')) 'Compaction before tree switch failed.'
    $leafAfterCompact = $compTreeState.leaf_id
    $lastMsgIdAfterCompact = $compTreeState.messages[-1].id
    Switch-SessionBranch -State $compTreeState -TargetId $leafAfterCompact | Out-Null
    Assert-True ($compTreeState.messages.Count -eq 4 -and $compTreeState.messages[1].content.StartsWith('[Compacted Conversation Summary]')) 'Switch-SessionBranch to leaf_id lost compaction summary.'
    Switch-SessionBranch -State $compTreeState -TargetId $lastMsgIdAfterCompact | Out-Null
    Assert-True ($compTreeState.messages.Count -eq 4 -and $compTreeState.messages[1].content.StartsWith('[Compacted Conversation Summary]')) 'Switch-SessionBranch to last message id lost compaction summary.'
    $compSessFile = Join-Path $treeSessionDir 'comp-tree.jsonl'
    Save-AgentSession -SessionFile $compSessFile -State $compTreeState -Workspace $workspacePath -Model 'test-model'
    $resumedCompState = @{ session_id = ''; workspace = $workspacePath; model = ''; messages = @() }
    Invoke-SessionResume -SessionFile $compSessFile -State $resumedCompState -CurrentWorkspace $workspacePath | Out-Null
    Switch-SessionBranch -State $resumedCompState -TargetId $resumedCompState.leaf_id | Out-Null
    Assert-True ($resumedCompState.messages.Count -eq 4 -and $resumedCompState.messages[1].content.StartsWith('[Compacted Conversation Summary]')) 'Resumed session lost compaction summary after Switch-SessionBranch.'

    # Regression 2: /tree and /fork reject switching to an unfinished tool_calls message.
    $tcTreeState = @{
        session_id = 'sess-tc-bound'
        workspace = $workspacePath
        model = 'test-model'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'list files please' },
            @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'tc_1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } }) },
            @{ role = 'tool'; tool_call_id = 'tc_1'; content = '{"entries":[]}' },
            @{ role = 'assistant'; content = 'done listing' }
        )
    }
    Ensure-SessionTree -State $tcTreeState
    $unfinishedTcEntryId = $tcTreeState.messages[2].id
    $completedToolEntryId = $tcTreeState.messages[3].id
    $tcSwitchThrew = $false
    try {
        Switch-SessionBranch -State $tcTreeState -TargetId $unfinishedTcEntryId | Out-Null
    }
    catch {
        if ($_.Exception.Message -like '*incomplete tool_calls*') { $tcSwitchThrew = $true }
    }
    Assert-True ($tcSwitchThrew -and $tcTreeState.messages.Count -eq 5) 'Switch-SessionBranch allowed switching to an unfinished tool_calls entry.'
    $tcForkThrew = $false
    try {
        Invoke-SessionFork -State $tcTreeState -SessionDir $treeSessionDir -EntryId $unfinishedTcEntryId | Out-Null
    }
    catch {
        if ($_.Exception.Message -like '*incomplete tool_calls*') { $tcForkThrew = $true }
    }
    Assert-True $tcForkThrew 'Invoke-SessionFork allowed forking at an unfinished tool_calls entry.'
    Switch-SessionBranch -State $tcTreeState -TargetId $completedToolEntryId | Out-Null
    Assert-True ($tcTreeState.messages.Count -eq 4 -and $tcTreeState.messages[-1].role -eq 'tool') 'Switch-SessionBranch failed to allow switching to completed tool result.'

    # Regression 3: JSON mode (-Mode json) emits only pure JSONL without plain-text tool logs or Read-Host prompts.
    $capturedHostLines = @()
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        $script:capturedHostLines += $text
    }
    $script:OutputMode = 'json'
    try {
        $script:capturedHostLines = @()
        $jsonListCall = @{ id = 'j-list'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } }
        $jsonListRes = Invoke-AgentTool -Root $workspacePath -Call $jsonListCall | ConvertFrom-Json
        Assert-True ($null -ne $jsonListRes.entries -and $script:capturedHostLines.Count -eq 0) 'Invoke-AgentTool emitted plain-text Write-Host output in JSON mode.'
        $script:AgentPermission = 'Ask'
        $jsonWriteCall = @{ id = 'j-write'; function = @{ name = 'write_file'; arguments = '{"path":"json-blocked.txt","content":"x"}' } }
        $jsonWriteRes = Invoke-AgentTool -Root $workspacePath -Call $jsonWriteCall | ConvertFrom-Json
        Assert-True ($jsonWriteRes.status -eq 'cancelled' -and $script:capturedHostLines.Count -eq 0) 'write_file in Ask+JSON mode did not cancel cleanly or emitted plain text.'
        $script:turnStep = 0
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:turnStep++
            if ($script:turnStep -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 'jtc1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'JSON turn complete.' } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $script:capturedHostLines = @()
        $jsonTurnState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'go' }) }
        Invoke-AgentTurn -State $jsonTurnState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        Assert-True ($script:capturedHostLines.Count -ge 4) 'Invoke-AgentTurn emitted no JSON events in JSON mode.'
        foreach ($jLine in $script:capturedHostLines) {
            $parsedEv = $jLine | ConvertFrom-Json -ErrorAction Stop
            Assert-True ([bool]$parsedEv.type) "Non-JSON event line emitted in JSON mode: $jLine"
        }
    }
    finally {
        $script:OutputMode = 'text'
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
    }

    # Regression 4: Parent directory .gitignore rules apply when searching from a child directory (path = "a/b").
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

    # Truncated model response (finish_reason=length) is rejected before accepting message or running tools.
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $resp = @{ choices = @(@{ finish_reason = 'length'; message = @{
            content = 'Partial reply...'
            tool_calls = @(@{ id = 'bad'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"should-not-exist.txt","content":"x"}' } })
        } }) } | ConvertTo-Json -Depth 10 -Compress
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    $truncState = @{ messages = @(@{ role = 'user'; content = 'Hi' }) }
    $lengthThrew = $false
    try {
        Invoke-AgentTurn -State $truncState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2
    }
    catch {
        if ($_.Exception.Message -like '*finish_reason=length*') { $lengthThrew = $true }
    }
    Assert-True $lengthThrew 'Truncated response (finish_reason=length) was not rejected.'
    Assert-True ($truncState.messages.Count -eq 1 -and (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'should-not-exist.txt')))) 'Truncated response modified state or executed tool.'
    $compactTruncState = @{ messages = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'm1' },
        @{ role = 'assistant'; content = 'm2' },
        @{ role = 'user'; content = 'm3' },
        @{ role = 'assistant'; content = 'm4' }
    ) }
    $compactLengthThrew = $false
    try {
        Invoke-AgentCompact -State $compactTruncState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -KeepRecent 2 | Out-Null
    }
    catch {
        if ($_.Exception.Message -like '*finish_reason=length*') { $compactLengthThrew = $true }
    }
    Assert-True ($compactLengthThrew -and $compactTruncState.messages.Count -eq 5) 'Invoke-AgentCompact accepted a truncated summary with finish_reason=length.'

    # Installer preserves profile contents and replaces its own block on rerun.
    $profileFile = Join-Path $testRoot 'profile.ps1'
    Set-Content -LiteralPath $profileFile -Value '# keep my settings' -Encoding UTF8
    & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\h-agent.ps1" -ProfilePath $profileFile
    & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\h-agent.ps1" -ProfilePath $profileFile
    $profileText = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8
    Assert-True ($profileText.Contains('# keep my settings')) 'Profile contents were lost.'
    Assert-True ((@($profileText -split '(?m)^# >>> h-agent >>>\r?$').Count - 1) -eq 1) 'Installer duplicated the launcher.'

    # Reload the implementation in ConstrainedLanguage and repeat file reading.
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
    . "$PSScriptRoot\..\h-agent.ps1" -LibraryOnly
    $call = @{ id = 'cl'; function = @{ name = 'read_file'; arguments = '{"path":"long.txt","start_line":301}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.start_line -eq 301 -and (-not $result.truncated)) 'ConstrainedLanguage file read failed.'
    $call = @{ id = 'cl-write'; function = @{ name = 'write_file'; arguments = '{"path":"constrained.txt","content":"ok"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'written') 'ConstrainedLanguage creation failed.'
    $call = @{ id = 'cl-edit'; function = @{ name = 'edit_file'; arguments = '{"path":"crlf.txt","old_text":"row2\nline3","new_text":"row2\nrow3"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'written') 'ConstrainedLanguage CRLF edit failed.'
    Remove-Item -LiteralPath $result.backup -Force
    $call = @{ id = 'cl-grep'; function = @{ name = 'grep_files'; arguments = '{"path":".","pattern":"row3"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.matches.Count -eq 1) 'ConstrainedLanguage grep_files failed.'
    $script:approval = 'RUN'
    $call = @{ id = 'cl-cmd'; function = @{ name = 'run_command'; arguments = '{"command":"Write-Output \"cl-cmd-ok\""}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.status -eq 'executed' -and $result.output.Trim() -eq 'cl-cmd-ok') 'ConstrainedLanguage run_command failed.'
    $script:approval = 'WRITE'
    $errText = Format-AgentError -ErrorRecord @{ Exception = @{ Message = 'HTTP 400' }; ErrorDetails = @{ Message = '{"error":{"message":"Bad model"}}' } }
    Assert-True ($errText -eq 'HTTP 400 (Bad model)') 'ConstrainedLanguage error formatting failed.'
    $tableLines = @(Format-MarkdownTable -Lines @('| Col | Val |', '|---|---|', '| a | **bold** |') -Indent '')
    $plainTable = @($tableLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' })
    Assert-True ($plainTable[0] -eq '| Col | Val  |') 'Table header alignment failed.'
    Assert-True ($plainTable[1] -eq '|-----+------|') 'Table separator alignment failed.'
    Assert-True ($plainTable[2] -eq '| a   | bold |') 'Table cell markdown stripping or padding failed.'
    $inlineOut = Format-MarkdownInline -Text 'Hello **world** and `SELECT *`'
    Assert-True ($inlineOut.Contains('38;2;231;138;78') -and (-not $inlineOut.Contains('**')) -and (-not $inlineOut.Contains('`'))) 'Gruvbox Material inline markdown formatting failed.'
    $clSys = Build-SystemPrompt -Root $workspacePath -ConfigDir $globalCfgDir
    Assert-True ($clSys.Contains('sql-tuning') -and $clSys.Contains('corp-standard')) 'ConstrainedLanguage Build-SystemPrompt failed.'
    $call = @{ id = 'cl-skill'; function = @{ name = 'read_file'; arguments = (@{ path = $globalSkillPath } | ConvertTo-Json -Compress) } }
    $clSkillRes = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($clSkillRes.text -like '*Global rules body*') 'ConstrainedLanguage global skill read failed.'
    $call = @{ id = 'cl-bad-bool'; function = @{ name = 'write_file'; arguments = '{"path":"constrained.txt","content":"no","overwrite":"false"}' } }
    $clBadBool = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($clBadBool.error -like '*must be a boolean*') 'ConstrainedLanguage boolean validation failed.'
    $clFoundSess = Find-ProjectSession -SessionDir $sessionDirTest -Workspace $workspacePath
    Assert-True ($clFoundSess -eq (Get-Item -LiteralPath $sessionFile -Force).FullName) 'ConstrainedLanguage Find-ProjectSession failed.'
    $clMatch = Find-EditMatch -Content "one   `r`ntwo" -OldText "one`ntwo"
    Assert-True ($clMatch.index -eq 0 -and $clMatch.length -eq 11) 'ConstrainedLanguage Find-EditMatch failed.'
    $script:AgentPermission = 'AutoEdit'
    $call = @{ id = 'cl-batch'; function = @{ name = 'edit_file'; arguments = '{"path":"batch.txt","edits":[{"old_text":"two","new_text":"2"},{"old_text":"three","new_text":"3"}]}' } }
    $clBatch = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($clBatch.status -eq 'written' -and $clBatch.edits_applied -eq 2) 'ConstrainedLanguage batch edit_file failed.'
    Remove-Item -LiteralPath $clBatch.backup -Force
    $script:CurrentTurnWrites = @()
    $call = @{ id = 'cl-u1'; function = @{ name = 'write_file'; arguments = '{"path":"cl-undo-chain.txt","content":"a"}' } }
    $null = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $call = @{ id = 'cl-u2'; function = @{ name = 'edit_file'; arguments = '{"path":"cl-undo-chain.txt","old_text":"a","new_text":"b"}' } }
    $null = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $clUndoState = @{ messages = @(@{ role = 'user'; content = 'u' }) }
    Invoke-AgentUndo -State $clUndoState -UndoEntry @{ messages = @(); writes = @($script:CurrentTurnWrites) }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'cl-undo-chain.txt'))) 'ConstrainedLanguage multi-step Invoke-AgentUndo failed.'
    $call = @{ id = 'cl-ll'; function = @{ name = 'read_file'; arguments = '{"path":"longline25k.txt","start_line":1,"start_char":20001}' } }
    $clLl = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($clLl.text.Length -eq 5000 -and (-not $clLl.truncated)) 'ConstrainedLanguage read_file start_char failed.'
    $clTpl = Expand-TemplateArgs -Content 'Hello $1 ${2:-world} ${@:2}' -ArgsString 'there a b'
    Assert-True ($clTpl -eq 'Hello there a a b') 'ConstrainedLanguage Expand-TemplateArgs failed.'
    $clTrunc = Invoke-TruncateHead -Content ("a`nb`nc") -MaxLines 2 -MaxBytes 100
    Assert-True ($clTrunc.truncated -and $clTrunc.content -eq "a`nb") 'ConstrainedLanguage Invoke-TruncateHead failed.'
    $clTreeNodes = @(Get-SessionTree -State $reloadedTreeState)
    Assert-True ($clTreeNodes.Count -eq 3) 'ConstrainedLanguage Get-SessionTree failed.'
    Switch-SessionBranch -State $resumedCompState -TargetId $resumedCompState.leaf_id | Out-Null
    Assert-True ($resumedCompState.messages[1].content.StartsWith('[Compacted Conversation Summary]')) 'ConstrainedLanguage compaction branch switch failed.'
    $clFindSub = Invoke-AgentTool -Root $workspacePath -Call $findSubCall | ConvertFrom-Json
    $clFindPaths = @($clFindSub.matches | ForEach-Object { $_.path })
    Assert-True (($clFindPaths -contains 'a/b/keep.txt') -and (-not ($clFindPaths -contains 'a/b/private.log'))) 'ConstrainedLanguage parent .gitignore in find_files failed.'
    $clHtmlPath = Join-Path $testRoot 'cl-export.html'
    $null = Export-AgentSessionHtml -State $reloadedTreeState -OutputPath $clHtmlPath
    Assert-True (Test-Path -LiteralPath $clHtmlPath) 'ConstrainedLanguage Export-AgentSessionHtml failed.'
    $script:AgentPermission = 'Ask'
    Write-AgentReasoning -Text "Step 1`nStep 2`nStep 3`nStep 4"
    Write-AgentReply -Content "# Title`n## Subtitle`n> quote`n- **item** with ``code```n| A | B |`n|---|---|`n| 1 | 2 |`n``````sql`nSELECT 1;`n``````"
    Save-AgentConfig -Path $configPath -Config $loadedConfig
    $constrainedConfig = Read-AgentConfig -Path $configPath
    Assert-True ($constrainedConfig.H_AGENT_API_KEY -eq $loadedConfig.H_AGENT_API_KEY) 'ConstrainedLanguage config roundtrip failed.'
    Write-Host 'All smoke checks passed.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
