$ErrorActionPreference = 'Stop'
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

    # Session JSONL persistence roundtrip.
    $sessionFile = Join-Path $testRoot 'sessions\test.jsonl'
    $sampleState = @{ messages = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'hi' },
        @{ role = 'assistant'; content = 'hello' }
    ) }
    Save-AgentSession -SessionFile $sessionFile -State $sampleState
    $restoredMsgs = @(Read-AgentSession -SessionFile $sessionFile)
    Assert-True ($restoredMsgs.Count -eq 3 -and $restoredMsgs[2].content -eq 'hello') 'Session JSONL roundtrip failed.'

    # Exercise the agent/tool/API round trip without any network or real key.
    $script:requests = 0
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction)
        $script:requests++
        $payload = $Body | ConvertFrom-Json
        Assert-True ($Method -eq 'Post') 'Expected POST.'
        Assert-True ($payload.model -eq 'test-model') 'Wrong model.'
        if ($script:requests -eq 1) {
            return @{ choices = @(@{ message = @{
                content = $null
                reasoning_content = 'Inspect directory.'
                tool_calls = @(@{ id = 't1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
            } }) }
        }
        $last = $payload.messages[-1]
        Assert-True ($last.role -eq 'tool' -and $last.tool_call_id -eq 't1') 'Missing tool response.'
        $listing = $last.content | ConvertFrom-Json
        Assert-True ($listing.entries.Name -contains 'hello.txt') 'Tool result missing file.'
        return @{ choices = @(@{ message = @{ content = 'Files inspected.' } }) }
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
    $clSys = Build-SystemPrompt -Root $workspacePath -ConfigDir ''
    Assert-True ($clSys.Contains('sql-tuning')) 'ConstrainedLanguage Build-SystemPrompt failed.'
    $clMatch = Find-EditMatch -Content "one   `r`ntwo" -OldText "one`ntwo"
    Assert-True ($clMatch.index -eq 0 -and $clMatch.length -eq 11) 'ConstrainedLanguage Find-EditMatch failed.'
    Write-AgentReply -Content "# Title`n## Subtitle`n> quote`n- **item** with ``code```n| A | B |`n|---|---|`n| 1 | 2 |`n``````sql`nSELECT 1;`n``````"
    Save-AgentConfig -Path $configPath -Config $loadedConfig
    $constrainedConfig = Read-AgentConfig -Path $configPath
    Assert-True ($constrainedConfig.H_AGENT_API_KEY -eq $loadedConfig.H_AGENT_API_KEY) 'ConstrainedLanguage config roundtrip failed.'
    Write-Host 'All smoke checks passed.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
