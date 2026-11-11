$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    # Set up fixtures before entering ConstrainedLanguage mode.
    Set-Content -LiteralPath (Join-Path $workspacePath 'long.txt') -Value (1..350) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workspacePath 'crlf.txt') -Value "row1`r`nrow2`r`nline3" -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $workspacePath 'batch.txt') -Value "1`r`ntwo`r`nthree`r`n4" -Encoding UTF8 -NoNewline
    $longLine25k = ('A' * 20000) + ('B' * 5000)
    Set-Content -LiteralPath (Join-Path $workspacePath 'longline25k.txt') -Value $longLine25k -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $workspacePath 'AGENTS.md') -Value 'Always use snake_case.' -Encoding UTF8
    $dotH = Join-Path $workspacePath '.shellossus'
    $skillFolder = Join-Path $dotH 'skills\sql-tuning'
    New-Item -ItemType Directory -Path $skillFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $skillFolder 'SKILL.md') -Value "---`nname: sql-tuning`ndescription: Optimize heavy SQL queries`n---`nCheck indexes." -Encoding UTF8
    $globalCfgDir = Join-Path $testRoot 'global-cfg'
    $globalSkillDir = Join-Path $globalCfgDir 'skills\corp-standard'
    New-Item -ItemType Directory -Path $globalSkillDir -Force | Out-Null
    $globalSkillPath = Join-Path $globalSkillDir 'SKILL.md'
    Set-Content -LiteralPath $globalSkillPath -Value "---`nname: corp-standard`ndescription: Global skill`n---`nGlobal rules body." -Encoding UTF8
    $dirA = Join-Path $workspacePath 'a'
    $dirAB = Join-Path $dirA 'b'
    New-Item -ItemType Directory -Path $dirAB -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dirA '.gitignore') -Value '*.log' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dirAB 'private.log') -Value 'secret log token' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dirAB 'keep.txt') -Value 'public log token' -Encoding UTF8
    $clGitDir = Join-Path $workspacePath '.git'
    New-Item -ItemType Directory -Path $clGitDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clGitDir 'HEAD') -Value "ref: refs/heads/cl-tui`n" -Encoding UTF8 -NoNewline

    $sessionDirTest = Join-Path $testRoot 'sessions'
    $sessionFile = Join-Path $sessionDirTest 'test-ws1.jsonl'
    $sampleState = @{ messages = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'hi' },
        @{ role = 'assistant'; content = 'hello' }
    ) }
    Save-AgentSession -SessionFile $sessionFile -State $sampleState -Workspace $workspacePath -Model 'model-a' -SessionId 'sid-1'

    $reloadedTreeState = @{
        session_id = 'sess-tree-cl'
        workspace = $workspacePath
        model = 'test-model'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'u1' },
            @{ role = 'assistant'; content = 'a1' },
            @{ role = 'user'; content = 'u2' }
        )
    }
    Ensure-SessionTree -State $reloadedTreeState

    $resumedCompState = @{
        session_id = 'sess-comp-cl'
        workspace = $workspacePath
        model = 'test-model'
        leaf_id = 'e0003'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ id = 'e0003'; parent_id = 'e0002'; entry_type = 'compaction'; first_kept_entry_id = 'e0002'; role = 'user'; content = "[Compacted Conversation Summary]`nSummary text" },
            @{ id = 'e0002'; parent_id = 'e0001'; role = 'assistant'; content = 'recent reply' }
        )
        tree_entries = @(
            @{ id = 'e0001'; parent_id = $null; role = 'user'; content = 'old q' },
            @{ id = 'e0002'; parent_id = 'e0001'; role = 'assistant'; content = 'recent reply' },
            @{ id = 'e0003'; parent_id = 'e0002'; entry_type = 'compaction'; first_kept_entry_id = 'e0002'; role = 'user'; content = "[Compacted Conversation Summary]`nSummary text" }
        )
    }

    $clConfigPath = Join-Path $testRoot '.env'
    $loadedConfig = @{
        SHELLOSSUS_BASE_URL = 'https://example.invalid/v1'
        SHELLOSSUS_MODEL = 'test-model'
        SHELLOSSUS_API_KEY = 'fake=key#$(throw injected)'
        SHELLOSSUS_WORKSPACE = 'C:\folder with spaces'
    }

    $script:approval = 'WRITE'
    function Read-Host {
        param($Prompt)
        return $script:approval
    }

    # Switch to ConstrainedLanguage and re-source shellossus.ps1.
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
    . "$PSScriptRoot\..\shellossus.ps1" -LibraryOnly

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
    $call = @{ id = 'cl-u1'; function = @{ name = 'write_file'; arguments = '{"path":"cl_new_dir/cl_sub/cl-undo-chain.txt","content":"a"}' } }
    $null = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $call = @{ id = 'cl-u2'; function = @{ name = 'edit_file'; arguments = '{"path":"cl_new_dir/cl_sub/cl-undo-chain.txt","old_text":"a","new_text":"b"}' } }
    $null = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    $clUndoState = @{ messages = @(@{ role = 'user'; content = 'u' }) }
    Invoke-AgentUndo -State $clUndoState -UndoEntry @{ messages = @(); writes = @($script:CurrentTurnWrites) }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'cl_new_dir'))) 'ConstrainedLanguage multi-step Invoke-AgentUndo with nested directory cleanup failed.'

    $call = @{ id = 'cl-ll'; function = @{ name = 'read_file'; arguments = '{"path":"longline25k.txt","start_line":1,"start_char":20001}' } }
    $clLl = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($clLl.text.Length -eq 5000 -and (-not $clLl.truncated)) 'ConstrainedLanguage read_file start_char failed.'

    $clTpl = Expand-TemplateArgs -Content 'Hello $1 ${2:-world} ${@:2}' -ArgsString 'there a b'
    Assert-True ($clTpl -eq 'Hello there a a b') 'ConstrainedLanguage Expand-TemplateArgs failed.'

    $clTrunc = Invoke-TruncateHead -Content ("a`nb`nc") -MaxLines 2 -MaxBytes 100
    Assert-True ($clTrunc.truncated -and $clTrunc.content -eq "a`nb") 'ConstrainedLanguage Invoke-TruncateHead failed.'

    $clTreeNodes = @(Get-SessionTree -State $reloadedTreeState)
    Assert-True ($clTreeNodes.Count -eq 3) 'ConstrainedLanguage Get-SessionTree failed.'
    $clArrCopy = @(Copy-SessionHashtableArray -Items $reloadedTreeState.messages)
    Assert-True ($clArrCopy.Count -eq $reloadedTreeState.messages.Count -and $clArrCopy[0].content -eq 'sys') 'ConstrainedLanguage Copy-SessionHashtableArray failed.'

    Switch-SessionBranch -State $resumedCompState -TargetId $resumedCompState.leaf_id | Out-Null
    Assert-True ($resumedCompState.messages[1].content.StartsWith('[Compacted Conversation Summary]')) 'ConstrainedLanguage compaction branch switch failed.'

    & {
        $savedWindow = $script:ContextWindowTokens
        $savedThreshold = $script:CompactThresholdTokens
        $null = Set-AgentContextLimits -WindowSpec '4k' -CompactSpec '75%'
        $mock = @{ calls = 0; failAt = 2; prior = ''; transcript = '' }
        $glyph = ([string][char]0xd83d) + ([string][char]0xde00)
        $nonAscii = [string][char]0x044f
        $rule = 'Never run external programs.'
        $correction = 'Correction: use staging.json.'
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $mock.calls++
            $payload = $Body | ConvertFrom-Json
            $userBody = $payload.messages[1].content
            $promptBytes = Get-AgentUtf8TextSize ($payload.messages[0].content + $userBody)
            Assert-True ($promptBytes + 1000 + 128 -le 4000) 'A compaction request exceeded the 4k window budget.'
            Assert-True ($userBody -cnotmatch '\ufffd|(?<![\ud800-\udbff])[\udc00-\udfff]|[\ud800-\udbff](?![\udc00-\udfff])') 'A compaction batch split a surrogate pair.'
            Assert-True ($userBody -match '(?s)\A<previous-summary>\n(.*?)\n</previous-summary>\n\n<conversation>\n(.*?)\n</conversation>') 'Compaction request is missing its handoff or transcript.'
            $previous = $Matches[1]
            $transcript = $Matches[2]
            Assert-True ($previous -ceq $mock.prior) 'Compaction did not carry the previous batch summary forward.'
            $mock.transcript += $transcript
            $summary = if ($previous) { $previous } else { "## Constraints & Preferences`nUse draft.json." }
            if ($transcript.Contains($rule)) { $summary += "`n$rule" }
            if ($transcript.Contains($correction)) { $summary = $summary.Replace('Use draft.json.', 'Use staging.json.') }
            $mock.prior = $summary
            if ($mock.calls -eq $mock.failAt) { $summary = $nonAscii * 501 }
            $response = @{
                choices = @(@{ finish_reason = 'stop'; message = @{ content = $summary } })
                usage = @{ prompt_tokens = 11; completion_tokens = 7 }
            } | ConvertTo-Json -Depth 5 -Compress
            Set-Content -LiteralPath $OutFile -Value $response -Encoding UTF8 -NoNewline
        }

        try {
            $longUser = "[Compacted Conversation Summary]`nMessage start.`n" + ($glyph * 900) + "`n$rule`n" + ('x' * 900) + "`nMessage tail."
            $toolResult = '{"text":"tool result start ' + ('x' * 3000) + ' tool result tail"}'
            $compactState = @{ messages = @(
                @{ role = 'system'; content = 'sys' },
                @{ role = 'user'; content = $longUser },
                @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'cl-read'; function = @{ name = 'read_file'; arguments = '{"path":"example.json"}' } }) },
                @{ role = 'tool'; tool_call_id = 'cl-read'; content = $toolResult },
                @{ role = 'user'; content = $correction },
                @{ role = 'assistant'; content = 'Correction acknowledged.' },
                @{ role = 'user'; content = 'Recent user message.' },
                @{ role = 'assistant'; content = 'Recent assistant message.' }
            ) }
            $compactArgs = @{ State = $compactState; Endpoint = 'https://example.invalid'; ModelId = 'test-model'; ApiKey = 'fake'; KeepRecent = 2; Focus = 'file paths' }
            $failed = $false
            try { $null = Invoke-AgentCompact @compactArgs }
            catch {
                if ($_.Exception.Message -notlike '*summary exceeded its size limit*') { throw }
                $failed = $true
            }
            Assert-True ($failed -and $mock.calls -eq 2 -and $compactState.messages.Count -eq 8 -and $compactState.messages[1].content -ceq $longUser) 'Oversized intermediate summary changed the active history.'
            Assert-True (-not $compactState.ContainsKey('tree_entries') -and -not $compactState.ContainsKey('leaf_id')) 'A failed compaction changed the session tree.'
            $mock.calls = 0
            $mock.failAt = 0
            $mock.prior = ''
            $mock.transcript = ''
            $didCompact = Invoke-AgentCompact @compactArgs
            $summary = $compactState.messages[1].content
            Assert-True ($didCompact -and $mock.calls -gt 2 -and $summary.Contains($rule) -and $summary.Contains('Use staging.json.') -and -not $summary.Contains('Use draft.json.')) 'Compaction lost a long user message constraint or its later correction.'
            Assert-True ($mock.transcript.Contains('Message start.') -and $mock.transcript.Contains('Message tail.') -and -not $mock.transcript.Contains('Recent user message.')) 'Compaction dropped part of the long user message or summarized retained history.'
            Assert-True ($mock.transcript.Contains('tool result start') -and -not $mock.transcript.Contains('tool result tail') -and $summary.Contains('example.json')) 'Compaction failed to shorten tool output separately while retaining file operations.'
            Assert-True ($compactState.usage_input_tokens -eq (11 * ($mock.calls + 2)) -and $compactState.usage_output_tokens -eq (7 * ($mock.calls + 2))) 'Compaction did not count usage for each batch.'
        }
        finally {
            $script:ContextWindowTokens = $savedWindow
            $script:CompactThresholdTokens = $savedThreshold
        }
    }

    $findSubCall = @{ id = 'f-sub'; function = @{ name = 'find_files'; arguments = '{"path":"a/b","pattern":"*"}' } }
    $clFindSub = Invoke-AgentTool -Root $workspacePath -Call $findSubCall | ConvertFrom-Json
    $clFindPaths = @($clFindSub.matches | ForEach-Object { $_.path })
    Assert-True (($clFindPaths -contains 'a/b/keep.txt') -and (-not ($clFindPaths -contains 'a/b/private.log'))) 'ConstrainedLanguage parent .gitignore in find_files failed.'

    $clHtmlPath = Join-Path $testRoot 'cl-export.html'
    $null = Export-AgentSessionHtml -State $reloadedTreeState -OutputPath $clHtmlPath
    Assert-True (Test-Path -LiteralPath $clHtmlPath) 'ConstrainedLanguage Export-AgentSessionHtml failed.'

    $script:AgentPermission = 'Ask'
    Write-AgentReasoning -Text "Step 1`nStep 2`nStep 3`nStep 4"
    Write-AgentReply -Content "# Title`n## Subtitle`n> quote`n- **item** with ``code```n| A | B |`n|---|---|`n| 1 | 2 |`n``````sql`nSELECT 1;`n``````"
    Save-AgentConfig -Path $clConfigPath -Config $loadedConfig
    $constrainedConfig = Read-AgentConfig -Path $clConfigPath
    Assert-True ($constrainedConfig.SHELLOSSUS_API_KEY -eq $loadedConfig.SHELLOSSUS_API_KEY) 'ConstrainedLanguage config roundtrip failed.'

    $clProfilePath = Join-Path $testRoot 'cl-profile.ps1'
    Invoke-AgentProfileInstall -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $clProfilePath -Shortcut 'shoscl'
    $clProfText = Get-Content -LiteralPath $clProfilePath -Raw -Encoding UTF8
    Assert-True ($clProfText.Contains('function global:shellossus') -and $clProfText.Contains('function global:shoscl')) 'ConstrainedLanguage Invoke-AgentProfileInstall failed.'

    $clEmptyCont = @{ messages = @(@{ role = 'system'; content = 'sys' }) }
    Assert-True (-not (Invoke-AgentContinue -State $clEmptyCont -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2)) 'ConstrainedLanguage Invoke-AgentContinue failed.'

    $clDoneProc = @{ Id = 0; HasExited = $true; ExitCode = 0 }
    Wait-AgentProcessWithSpinner -Process $clDoneProc -StatusLabel 'CL wait check' -TimeoutSec 5 -PollMs 10

    $clCap = Get-AgentCapabilities -Root $workspacePath
    Assert-True ($clCap.permission -eq 'Ask' -and $clCap.tool_names.Count -eq 13 -and ($clCap.tool_names -contains 'memory') -and ($clCap.tool_names -contains 'ask_user') -and ($clCap.tool_names -contains 'todo') -and ($clCap.tool_names -contains 'fetch_url') -and ($clCap.tool_names -contains 'web_search') -and ($clCap.tool_names -contains 'run_agent') -and $clCap.environment.language_mode -eq 'ConstrainedLanguage') 'ConstrainedLanguage Get-AgentCapabilities or Get-AgentEnvironment failed.'
    $clSyncState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'q' }, @{ role = 'assistant'; content = 'a' }) }
    $clSyncRes = Sync-AgentCapabilities -State $clSyncState -RecordTransition
    Assert-True ($clSyncRes.consistent -and $clSyncState.messages[0].content.Contains('<capabilities>')) 'ConstrainedLanguage Sync-AgentCapabilities failed.'
    $clSig = Get-ToolCallSignature -Call @{ function = @{ name = 'read_file'; arguments = '{"max_lines":10,"path":"a.txt"}' } } -Epoch 1
    Assert-True ($clSig -eq '1|read_file|{max_lines:10,path:"a.txt"}') 'ConstrainedLanguage Get-ToolCallSignature failed.'
    $clTodoCall = @{ id = 'cl-td'; function = @{ name = 'todo'; arguments = '{"todos":[{"content":"cl task","status":"completed"}]}' } }
    $clTodoRes = Invoke-AgentTool -Root $workspacePath -Call $clTodoCall | ConvertFrom-Json
    Assert-True ($clTodoRes.success -and $clTodoRes.total -eq 1 -and $clTodoRes.completed -eq 1) 'ConstrainedLanguage todo execution failed.'
    $savedAppr = $script:approval
    $script:approval = '1'
    $clAskCall = @{ id = 'cl-ask'; function = @{ name = 'ask_user'; arguments = '{"question":"Confirm?","intent":"plan-review","plan":"# CL Plan"}' } }
    $clAskRes = Invoke-AgentTool -Root $workspacePath -Call $clAskCall | ConvertFrom-Json
    Assert-True ($clAskRes.question -eq 'Confirm?' -and $clAskRes.intent -eq 'plan-review' -and $clAskRes.approved) 'ConstrainedLanguage ask_user execution failed.'
    $script:approval = 'Okay, but wait for my review'
    $clAskRes = Invoke-AgentTool -Root $workspacePath -Call $clAskCall | ConvertFrom-Json
    Assert-True (-not $clAskRes.approved -and $clAskRes.custom -ceq $script:approval) 'ConstrainedLanguage plan review approved conditional feedback.'
    $script:approval = $savedAppr
    $clMemCall = @{ id = 'cl-mem'; function = @{ name = 'memory'; arguments = '{"action":"append","content":"CL invariant"}' } }
    $clMemRes = Invoke-AgentTool -Root $workspacePath -Call $clMemCall | ConvertFrom-Json
    Assert-True ($clMemRes.success -and $clMemRes.action -eq 'append' -and ($clMemRes.memory -like '*CL invariant*')) 'ConstrainedLanguage memory execution failed.'
    $clWalk = @(Get-WorkspaceWalkEntries -Root $workspacePath -SearchPath $workspacePath -FilesOnly)
    Assert-True ($clWalk.Count -ge 1) 'ConstrainedLanguage Get-WorkspaceWalkEntries failed.'
    Clear-WorkspaceWalkCache
    $clBudget1 = @{ visited = 0; limit = 500; truncated = $false }
    $clCached1 = @(Get-CachedWorkspaceFileEntries -Root $workspacePath -SearchPath $workspacePath -Budget $clBudget1)
    $clBudget2 = @{ visited = 0; limit = 500; truncated = $false }
    $clCached2 = @(Get-CachedWorkspaceFileEntries -Root $workspacePath -SearchPath $workspacePath -Budget $clBudget2)
    Assert-True ($clCached1.Count -ge 1 -and $clCached2.Count -eq $clCached1.Count -and $clBudget2.visited -eq $clBudget1.visited) 'ConstrainedLanguage Get-CachedWorkspaceFileEntries failed.'
    $clLitGrep1 = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'cl-lg1'; function = @{ name = 'grep_files'; arguments = '{"path":".","pattern":"row3","literal":true,"limit":1}' } } | ConvertFrom-Json
    $clLitGrep2 = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'cl-lg2'; function = @{ name = 'grep_files'; arguments = '{"path":".","pattern":"ROW3","literal":true,"case_sensitive":true}' } } | ConvertFrom-Json
    Assert-True ($clLitGrep1.matches.Count -eq 1 -and $clLitGrep2.matches.Count -eq 0 -and $script:WorkspaceWalkCache.Count -gt 0) 'ConstrainedLanguage cached literal grep_files failed.'
    Clear-WorkspaceWalkCache
    Assert-True ($script:WorkspaceWalkCache.Count -eq 0) 'ConstrainedLanguage Clear-WorkspaceWalkCache failed.'
    $clNormSub = Format-RunAgentArguments -ArgsObj ('{"agent":"scout","task":"check"}' | ConvertFrom-Json)
    Assert-True ($clNormSub.role -eq 'scout' -and $clNormSub.prompt -eq 'check') 'ConstrainedLanguage Format-RunAgentArguments failed.'
    $clRole = Resolve-AgentRole -Name 'scout' -Root $workspacePath
    Assert-True ($clRole.name -eq 'recon' -and $clRole.permission -eq 'ReadOnly') 'ConstrainedLanguage Resolve-AgentRole failed.'
    $clAgentCmd = Resolve-PromptTemplate -Root $workspacePath -ConfigDir $globalCfgDir -InputText '/agent:recon find queries'
    Assert-True ($clAgentCmd.Contains('<agent_role name="recon"') -and $clAgentCmd.Contains('find queries')) 'ConstrainedLanguage /agent:<role> failed.'
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'CL subagent ok' } }) } | ConvertTo-Json -Depth 10 -Compress
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    $clSubCall = @{ id = 'cl-sub'; function = @{ name = 'run_agent'; arguments = '{"role":"recon","prompt":"Quick check"}' } }
    $clSubRes = Invoke-AgentTool -Root $workspacePath -Call $clSubCall | ConvertFrom-Json
    Assert-True ($clSubRes.status -eq 'completed' -and $clSubRes.output -eq 'CL subagent ok') 'ConstrainedLanguage run_agent execution failed.'
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue

    # ConstrainedLanguage Inline TUI verification
    Assert-True ((Get-GitBranchLabel -Root $workspacePath) -eq 'cl-tui') 'ConstrainedLanguage Get-GitBranchLabel failed.'
    Assert-True ((Format-TokenCount -Tokens 15400) -eq '15.4k') 'ConstrainedLanguage Format-TokenCount failed.'
    $clGauge = Strip-AnsiCodes -Text (Format-ContextGauge -Chars 15000 -MaxChars 60000 -Width 8)
    Assert-True ($clGauge.Contains('25%')) 'ConstrainedLanguage Format-ContextGauge failed.'
    $clBar = @(Format-TuiStatusBar -State $reloadedTreeState -Root $workspacePath -Model 'test-model' -UndoCount 1 -Width 85)
    $clBarPlain = ($clBar | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($clBarPlain.Contains('cl-tui') -and $clBarPlain.Contains('test-model') -and $clBarPlain.Contains('undo:1')) 'ConstrainedLanguage Format-TuiStatusBar failed.'
    $clMascotFull = @(Get-TuiMascotLines -Mode 'full')
    $clMascotCompact = @(Get-TuiMascotLines -Mode 'compact')
    Assert-True ($clMascotFull.Count -eq 8 -and (Strip-AnsiCodes -Text $clMascotFull[0]).Length -eq 20) 'ConstrainedLanguage full mascot rendering failed.'
    Assert-True ($clMascotCompact.Count -eq 4 -and (Strip-AnsiCodes -Text $clMascotCompact[0]).Length -eq 10) 'ConstrainedLanguage compact mascot rendering failed.'
    Assert-True ($clMascotFull[4].Contains("$script:Esc[48;2;247;211;138m") -and $clMascotCompact[2].Contains("$script:Esc[38;2;247;211;138m")) 'ConstrainedLanguage mascot eye colors are missing.'
    Write-TuiPromptFrame -State $reloadedTreeState -Root $workspacePath -Model 'test-model' -UndoCount 1
    $clDiff = @(Format-UnifiedDiff -Path 'a.txt' -ToolName 'edit_file' -Before "x`ny" -After "x`nz")
    $clDiffPlain = ($clDiff | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($clDiffPlain.Contains('+1 -1') -and $clDiffPlain.Contains('- y') -and $clDiffPlain.Contains('+ z')) 'ConstrainedLanguage Format-UnifiedDiff failed.'
    $clCard = @(Format-ToolCallCard -Name 'read_file' -Target 'a.txt' -Detail 'lines 1..2' -Status 'ok' -Summary '2 lines' -ElapsedMs 5)
    Assert-True ($clCard.Count -eq 2) 'ConstrainedLanguage Format-ToolCallCard failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/p Auto') -eq '/permission Auto') 'ConstrainedLanguage Resolve-ReplCommandAlias failed.'
    $clStatusCard = @(Format-TuiStatusCard -State $reloadedTreeState -Model 'test-model' -MaxSteps 50 -SessionFile $sessionFile -UndoCount 1)
    Assert-True ($clStatusCard.Count -ge 7) 'ConstrainedLanguage Format-TuiStatusCard failed.'
    $clTreeCard = @(Format-TuiTreeCard -State $reloadedTreeState)
    Assert-True ($clTreeCard.Count -ge 4) 'ConstrainedLanguage Format-TuiTreeCard failed.'
    Write-TuiHelpCard
    $script:approval = '2'
    $clPicked = Invoke-TuiSelector -Title 'CL Picker' -Items @(
        @{ label = 'One'; value = 'v1'; description = 'd1'; active = $false },
        @{ label = 'Two'; value = 'v2'; description = 'd2'; active = $true }
    )
    Assert-True ($clPicked -eq 'v2') 'ConstrainedLanguage Invoke-TuiSelector failed.'
    $script:approval = 'on'
    $clPrefixPicked = Invoke-TuiSelector -Title 'CL Picker' -Items @(
        @{ label = 'One'; value = 'v1'; description = 'd1'; active = $false },
        @{ label = 'Two'; value = 'v2'; description = 'd2'; active = $true }
    )
    Assert-True ($clPrefixPicked -eq 'v1') 'ConstrainedLanguage Invoke-TuiSelector prefix match failed.'
    $null = Set-AgentTheme -Name 'tokyo-night'
    Assert-True ($script:ActiveTheme -eq 'tokyo-night' -and $script:Gm.OscInit.Contains('#1a1b26')) 'ConstrainedLanguage Set-AgentTheme failed.'
    $null = Set-AgentTheme -Name 'gruvbox-material'
    $script:approval = 'WRITE'

    $clCyr = ([string][char]0x0447) + ([string][char]0x0442) + ([string][char]0x043E) + '?'
    $clAsciiJson = ConvertTo-AsciiJson -Json (@{ q = $clCyr } | ConvertTo-Json -Compress)
    Assert-True (($clAsciiJson -notmatch '[^\x00-\x7F]') -and (([string]($clAsciiJson | ConvertFrom-Json).q) -eq $clCyr)) 'ConstrainedLanguage ConvertTo-AsciiJson failed.'
    $clLim = Set-AgentContextLimits -WindowSpec '128k' -CompactSpec '80k'
    Assert-True ($clLim.context_window_tokens -eq 128000 -and $clLim.compact_threshold_tokens -eq 80000) 'ConstrainedLanguage Set-AgentContextLimits failed.'
    $null = Set-AgentContextLimits -WindowSpec '128k' -CompactSpec '75%'
    $clTimeout = Set-AgentRequestTimeout -TimeoutSpec '300'
    Assert-True ($clTimeout -eq 300 -and $script:RequestTimeoutSec -eq 300) 'ConstrainedLanguage Set-AgentRequestTimeout failed.'
    $null = Set-AgentRequestTimeout -TimeoutSpec '180'
    Assert-True ((ConvertTo-UrlEncodedString -Text $clCyr) -eq '%D1%87%D1%82%D0%BE%3F') 'ConstrainedLanguage ConvertTo-UrlEncodedString failed.'
    $clEmoji = ([string][char]0xD83D) + ([string][char]0xDE00)
    Assert-True ((ConvertTo-UrlEncodedString -Text $clEmoji) -eq '%F0%9F%98%80') 'ConstrainedLanguage supplementary Unicode encoding failed.'
    $clScopedDir = Join-Path $workspacePath 'cl-scoped'
    New-Item -ItemType Directory -Path $clScopedDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clScopedDir 'AGENTS.md') -Value 'Constrained scoped rule.' -Encoding UTF8
    $clScoped = Get-ScopedAgentInstructions -Root $workspacePath -TargetPath 'cl-scoped/file.txt'
    Assert-True ($clScoped.Contains('Constrained scoped rule.')) 'ConstrainedLanguage scoped AGENTS.md lookup failed.'
    Assert-True ((ConvertFrom-HtmlToText -Html '<p>Hi &amp; bye</p>').Contains('Hi & bye')) 'ConstrainedLanguage ConvertFrom-HtmlToText failed.'

    # Exercise the worker's DNS validation without issuing DNS or HTTP requests.
    if (-not (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue)) {
        $clDnsUnavailable = ''
        try { Assert-SafeWebResolution -Target 'https://public.test/' }
        catch { $clDnsUnavailable = $_.Exception.Message }
        Assert-True ($clDnsUnavailable -like 'DNS resolution failed*Resolve-DnsName is unavailable*') 'Missing DNS cmdlet must fail closed in ConstrainedLanguage.'
    }
    & {
        function Resolve-DnsName {
            [CmdletBinding()]
            param([string]$Name, [string]$Type, [switch]$DnsOnly)
            Assert-True ($Type -eq 'A_AAAA' -and $DnsOnly -and $ErrorActionPreference -eq 'Stop') 'Expected a terminating DNS query for A and AAAA records.'
            if ($Name -eq 'missing.test') { throw 'Mock DNS name does not exist.' }
            @{ Type = 'CNAME'; Section = 'Answer'; NameHost = 'alias.test' }
            @{ Type = 'A'; Section = 'Additional'; IPAddress = '10.0.0.1' }
            if ($Name -ne 'empty.test') {
                @{ Type = 'AAAA'; Section = 'Answer'; IPAddress = '2606:4700:4700::1111' }
            }
            if ($Name -eq 'mixed.test') {
                @{ Type = 'A'; Section = 'Answer'; IPAddress = '8.8.8.8' }
                @{ Type = 'AAAA'; Section = 'Answer'; IPAddress = 'fd00::1' }
            }
            if ($Name -eq 'private-v4.test') {
                @{ Type = 'A'; Section = 'Answer'; IPAddress = '192.168.1.1' }
            }
        }

        Assert-SafeWebResolution -Target 'https://public.test/'
        Assert-SafeWebResolution -Target 'https://[2606:4700:4700::1111]/'
        foreach ($dnsCase in @(
            @{ name = 'mixed.test'; error = 'Blocked request*' }
            @{ name = 'private-v4.test'; error = 'Blocked request*' }
            @{ name = 'empty.test'; error = 'DNS resolution failed*no IPv4 or IPv6 addresses*' }
            @{ name = 'missing.test'; error = 'DNS resolution failed*Mock DNS name does not exist*' }
        )) {
            $dnsError = ''
            try { Assert-SafeWebResolution -Target ('https://' + $dnsCase.name + '/') }
            catch { $dnsError = $_.Exception.Message }
            Assert-True ($dnsError -like $dnsCase.error) "Unexpected DNS validation result for $($dnsCase.name): $dnsError"
        }
    }

    $clTmp = New-AgentTempFile
    try {
        Assert-True ($null -ne $clTmp -and (Test-Path -LiteralPath $clTmp.FullName)) 'ConstrainedLanguage New-AgentTempFile failed.'
        Set-AgentUtf8Content -LiteralPath $clTmp.FullName -Value ''
        $clEmptyRead = Get-Content -LiteralPath $clTmp.FullName -Raw -Encoding UTF8
        if ($null -eq $clEmptyRead) { $clEmptyRead = '' }
        Assert-True ($clEmptyRead -ceq '' -and (Get-Item -LiteralPath $clTmp.FullName -Force).Length -eq 0) 'ConstrainedLanguage Set-AgentUtf8Content with empty string failed.'
        Set-AgentUtf8Content -LiteralPath $clTmp.FullName -Value 'ascii-no-bom'
        Assert-True ((Get-Content -LiteralPath $clTmp.FullName -Raw -Encoding UTF8) -ceq 'ascii-no-bom' -and (Get-Item -LiteralPath $clTmp.FullName -Force).Length -eq 12) 'ConstrainedLanguage Set-AgentUtf8Content with ASCII string failed or wrote BOM.'
        $clUnicodeVal = ([string][char]0x0442) + ([string][char]0x0435) + ([string][char]0x0441) + ([string][char]0x0442)
        Set-AgentUtf8Content -LiteralPath $clTmp.FullName -Value $clUnicodeVal
        Assert-True ((Get-Content -LiteralPath $clTmp.FullName -Raw -Encoding UTF8) -ceq $clUnicodeVal -and (Get-Item -LiteralPath $clTmp.FullName -Force).Length -eq 8) 'ConstrainedLanguage Set-AgentUtf8Content with Unicode string failed or wrote BOM.'
    }
    finally {
        if ($clTmp -and (Test-Path -LiteralPath $clTmp.FullName)) {
            Remove-Item -LiteralPath $clTmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $bundledText = Get-Content -LiteralPath "$PSScriptRoot\..\shellossus.ps1" -Raw -Encoding UTF8
    $forbiddenTempCmd = 'New-' + 'TemporaryFile'
    Assert-True (-not $bundledText.Contains($forbiddenTempCmd)) 'shellossus.ps1 must use New-AgentTempFile instead of the legacy utility temp-file cmdlet.'

    # Regression (Batch 1 in ConstrainedLanguage):
    # Task 1: single-letter relative paths with colons rejected in ConstrainedLanguage
    $clColonWriteBlocked = $false
    try { Resolve-AgentWriteTarget -Root $workspacePath -RelativePath 'c:secret.txt' | Out-Null }
    catch { if ($_.Exception.Message -eq 'Invalid path syntax.') { $clColonWriteBlocked = $true } }
    Assert-True $clColonWriteBlocked 'ConstrainedLanguage Resolve-AgentWriteTarget did not reject c:secret.txt.'

    $clColonReadBlocked = $false
    try { Resolve-AgentPath -Root $workspacePath -RelativePath 'a:.env' | Out-Null }
    catch { if ($_.Exception.Message -eq 'Invalid path syntax.') { $clColonReadBlocked = $true } }
    Assert-True $clColonReadBlocked 'ConstrainedLanguage Resolve-AgentPath did not reject a:.env.'

    # Task 2: Find-CompactionCutPoint never cuts on a tool message in ConstrainedLanguage
    $clToolTailMsgs = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'u1' },
        @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'c1'; function = @{ name = 'read_file'; arguments = '{}' } }) },
        @{ role = 'tool'; tool_call_id = 'c1'; content = 'r1' },
        @{ role = 'tool'; tool_call_id = 'c2'; content = 'r2' }
    )
    $clCutRes = Find-CompactionCutPoint -Messages $clToolTailMsgs -StartIndex 1 -KeepRecent 1
    Assert-True ($clToolTailMsgs[$clCutRes.cut_index].role -ne 'tool' -and $clCutRes.cut_index -eq 2) 'ConstrainedLanguage Find-CompactionCutPoint cut on a tool message.'

    # Task 3 & Task 4: /**/ candidate expansion in find_files and single-file grep_files filtering in ConstrainedLanguage
    $clFindGlob = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'cl-fglob'; function = @{ name = 'find_files'; arguments = '{"path":".","pattern":"a/**/*.txt"}' } } | ConvertFrom-Json
    $clFoundGlobPaths = @($clFindGlob.matches | ForEach-Object { $_.path })
    Assert-True ($clFoundGlobPaths -contains 'a/b/keep.txt') 'ConstrainedLanguage find_files with a/**/*.txt failed.'

    $clSingleGrepIg = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'cl-sg-ig'; function = @{ name = 'grep_files'; arguments = '{"path":"a/b/private.log","pattern":"secret"}' } } | ConvertFrom-Json
    Assert-True (@($clSingleGrepIg.matches).Count -eq 0) 'ConstrainedLanguage single-file grep_files did not enforce .gitignore.'

    $clSingleGrepInc = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'cl-sg-inc'; function = @{ name = 'grep_files'; arguments = '{"path":"a/b/keep.txt","pattern":"public","include":"*.ps1"}' } } | ConvertFrom-Json
    Assert-True (@($clSingleGrepInc.matches).Count -eq 0) 'ConstrainedLanguage single-file grep_files did not enforce include filter.'

    # Regression (Batch 2 in ConstrainedLanguage):
    # Task 6: escaped .gitignore wildcards/brackets in ConstrainedLanguage
    $clEscBrack = Convert-IgnorePatternToRule -Line '\[draft\].txt'
    $clEscStar = Convert-IgnorePatternToRule -Line 'note\*.txt'
    Assert-True ((Test-PathIgnored -RelativePath '[draft].txt' -IsDir $false -Rules @($clEscBrack)) -and (-not (Test-PathIgnored -RelativePath 'd.txt' -IsDir $false -Rules @($clEscBrack)))) 'ConstrainedLanguage escaped bracket ignore rule failed.'
    Assert-True ((Test-PathIgnored -RelativePath 'note*.txt' -IsDir $false -Rules @($clEscStar)) -and (-not (Test-PathIgnored -RelativePath 'note1.txt' -IsDir $false -Rules @($clEscStar)))) 'ConstrainedLanguage escaped star ignore rule failed.'

    # Task 7: Find-EditMatch CRLF old_text against LF content in ConstrainedLanguage
    $clEditMatch = Find-EditMatch -Content "line1`nline2`nline3`n" -OldText "line1`r`nline2`r`n"
    Assert-True ($clEditMatch.index -eq 0 -and $clEditMatch.matched_text -ceq "line1`nline2`n") 'ConstrainedLanguage Find-EditMatch CRLF-to-LF match failed.'

    # Task 8 & Task 15: ConvertFrom-HtmlToText entity order and Test-SafeWebUrl IPv6 checks in ConstrainedLanguage
    Assert-True ((ConvertFrom-HtmlToText -Html '<p>&amp;lt;x&amp;gt;</p>') -ceq '&lt;x&gt;') 'ConstrainedLanguage ConvertFrom-HtmlToText double-unescaped &amp;lt;.'
    foreach ($clBadV6 in @('http://[0:0:0:0:0:0:127.0.0.1]/', 'http://[::100.64.0.1]/', 'http://[::224.0.0.1]/')) {
        $clBlockedV6 = $false
        try { Test-SafeWebUrl -Url $clBadV6 | Out-Null } catch { $clBlockedV6 = $true }
        Assert-True $clBlockedV6 "ConstrainedLanguage Test-SafeWebUrl did not block $clBadV6."
    }
    Assert-True ((Test-SafeWebUrl -Url 'https://[2001:db8::1]/') -and (Test-SafeWebUrl -Url 'https://[2002::1]/') -and (Test-SafeWebUrl -Url 'https://[100::1]/')) 'ConstrainedLanguage Test-SafeWebUrl blocked valid IPv6 URL.'

    # Task 2: address classifier has no .NET calls and must run in ConstrainedLanguage.
    Assert-True (Test-BlockedWebAddress -Address '10.0.0.1') 'ConstrainedLanguage Test-BlockedWebAddress did not block 10.0.0.1.'
    Assert-True (-not (Test-BlockedWebAddress -Address '8.8.8.8')) 'ConstrainedLanguage Test-BlockedWebAddress blocked 8.8.8.8.'

    # Task 9: Normalizer alias dropping in ConstrainedLanguage
    $clNormRead = Format-AgentToolArguments -Name 'read_file' -Arguments @{ path = 'a.txt'; file_path = 'a.txt' }
    Test-AgentToolArguments -Name 'read_file' -Arguments $clNormRead
    $clNormTodo = Format-TodoArguments -Arguments @{ todos = @(@{ content = 'a'; task = 'a'; status = 'pending'; state = 'pending' }); tasks = @() }
    Test-AgentToolArguments -Name 'todo' -Arguments $clNormTodo

    # Task 14: Test-PathHasReparsePoint non-existent StopAt in ConstrainedLanguage
    $clNonExistStop = Join-Path $testRoot 'cl-uncreated-home/.shellossus'
    Assert-True (-not (Test-PathHasReparsePoint -Path (Join-Path $clNonExistStop 'MEMORY.md') -StopAt $clNonExistStop)) 'ConstrainedLanguage Test-PathHasReparsePoint failed on non-existent StopAt.'

    # Task 16: Expand-UserPrompt late NUL byte check before 20,000-char truncation in ConstrainedLanguage
    $clLateNull = Join-Path $workspacePath 'cl-late-null.bin'
    Set-Content -LiteralPath $clLateNull -Value (('A' * 20010) + [char]0 + 'z') -Encoding Ascii -NoNewline
    $clExpandedNull = Expand-UserPrompt -Root $workspacePath -Prompt 'check @cl-late-null.bin'
    Assert-True ($clExpandedNull -notlike '*<file path="cl-late-null.bin">*') 'ConstrainedLanguage Expand-UserPrompt did not reject late NUL byte.'
    Remove-Item -LiteralPath $clLateNull -Force -ErrorAction SilentlyContinue

    # Task 17: Build-BranchContextMessages with two compactions on branch in ConstrainedLanguage
    $clTwoCompState = @{
        messages = @(@{ role = 'system'; content = 'sys' })
        tree_entries = @(
            @{ id = 'e1'; parent_id = $null; entry_type = 'message'; role = 'user'; content = 'u1' },
            @{ id = 'c1'; parent_id = 'e1'; entry_type = 'compaction'; role = 'user'; content = '[Compacted Conversation Summary] First'; first_kept_entry_id = 'e1' },
            @{ id = 'e2'; parent_id = 'c1'; entry_type = 'message'; role = 'assistant'; content = 'a1' },
            @{ id = 'c2'; parent_id = 'e2'; entry_type = 'compaction'; role = 'user'; content = '[Compacted Conversation Summary] Second'; first_kept_entry_id = 'e2' }
        )
        leaf_id = 'c2'
    }
    $clRebuiltComp = @(Build-BranchContextMessages -State $clTwoCompState -LeafId 'e2')
    Assert-True ($clRebuiltComp[1].content -like '*Second*') 'ConstrainedLanguage Build-BranchContextMessages failed to attach second child compaction.'

    $script:AgentPermission = 'AutoEdit'
    $script:AutoApproveCommands = $true
    $script:AutoApproveWeb = $true
    $clPermissionState = @{ messages = @(@{ role = 'system'; content = 'sys' }); workspace = $workspacePath }
    $clPermissionFrame = New-AgentUndoFrame -Snapshot (New-AgentTurnSnapshot -State $clPermissionState)
    Invoke-ReplPermissionCommand -State $clPermissionState -ReqPerm 'Ask'
    Restore-AgentTurnPermission -State $clPermissionState -Frame $clPermissionFrame
    Assert-True ($script:AgentPermission -eq 'Ask' -and -not $script:AutoApproveCommands -and -not $script:AutoApproveWeb) 'ConstrainedLanguage undo restored revoked approvals.'

    # Task 3: Direct execution of Resolve-StandaloneScriptPath, Get-AgentWorkerArguments, Invoke-InternalWebWorker,
    # Invoke-InternalHttpWorker, and Invoke-InternalSubagentWorker validation in ConstrainedLanguage mode.
    $clStandalone = Resolve-StandaloneScriptPath -Required
    Assert-True ([bool]$clStandalone -and (Test-Path -LiteralPath $clStandalone -PathType Leaf)) 'ConstrainedLanguage Resolve-StandaloneScriptPath -Required failed.'
    $savedClOs = Get-Item -LiteralPath 'Env:OS' -ErrorAction SilentlyContinue
    try {
        $env:OS = 'Windows_NT'
        $clWinArgs = Get-AgentWorkerArguments -ScriptPath 'C:\Dir With Spaces\shellossus.ps1' -WorkerMode 'http'
        Assert-True ($clWinArgs -ceq '-NoProfile -NonInteractive -OutputFormat Text -File "C:\Dir With Spaces\shellossus.ps1" -InternalWorker http') "ConstrainedLanguage Windows Get-AgentWorkerArguments failed: $clWinArgs"
        $env:OS = 'Other'
        $clPosixPlain = @(Get-AgentWorkerArguments -ScriptPath '/opt/shellossus/shellossus.ps1' -WorkerMode 'subagent')
        Assert-True ($clPosixPlain.Count -eq 8 -and $clPosixPlain[4] -ceq '-File' -and $clPosixPlain[5] -ceq '/opt/shellossus/shellossus.ps1' -and $clPosixPlain[7] -ceq 'subagent') 'ConstrainedLanguage POSIX plain Get-AgentWorkerArguments failed.'
        $clPosixArgs = @(Get-AgentWorkerArguments -ScriptPath '/opt/dir with spaces/shellossus.ps1' -WorkerMode 'web')
        Assert-True ($clPosixArgs.Count -eq 8 -and $clPosixArgs[4] -ceq '-File' -and $clPosixArgs[5] -ceq '"/opt/dir with spaces/shellossus.ps1"' -and $clPosixArgs[7] -ceq 'web') 'ConstrainedLanguage POSIX spaced Get-AgentWorkerArguments failed.'
    }
    finally {
        if ($null -eq $savedClOs) { Remove-Item -LiteralPath 'Env:OS' -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath 'Env:OS' -Value ([string]$savedClOs.Value) }
    }
    $clBadModeThrew = $false
    try { $null = Get-AgentWorkerArguments -ScriptPath $clStandalone -WorkerMode 'eval' }
    catch { $clBadModeThrew = $true }
    Assert-True $clBadModeThrew 'ConstrainedLanguage Get-AgentWorkerArguments accepted invalid worker mode.'

    $clWebOut = Join-Path $testRoot 'cl-web-blocked.tmp'
    $clWebMessages = @(Invoke-WithProcessEnvironment -Values @{
        SHELLOSSUS_WEB_DOWNLOAD_URI = 'http://127.0.0.1/secret'
        SHELLOSSUS_WEB_DOWNLOAD_FILE = $clWebOut
    } -Action {
        Invoke-InternalWebWorker
    })
    Assert-True ($script:InternalWorkerFailed -and ($clWebMessages -join ' ') -like '*Blocked request*' -and (-not (Test-Path -LiteralPath $clWebOut))) "ConstrainedLanguage Invoke-InternalWebWorker did not block 127.0.0.1: $($clWebMessages -join ' ')"

    $clHttpIn = New-AgentTempFile
    $clHttpOut = Join-Path $testRoot 'cl-http-out.tmp'
    $clHttpErr = New-AgentTempFile
    try {
        Set-AgentUtf8Content -LiteralPath $clHttpIn.FullName -Value '{}'
        Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_HTTP_URI = 'badclscheme://example.invalid/v1'
            SHELLOSSUS_API_KEY = 'cl-key'
            SHELLOSSUS_HTTP_IN = $clHttpIn.FullName
            SHELLOSSUS_HTTP_OUT = $clHttpOut
            SHELLOSSUS_HTTP_ERR = $clHttpErr.FullName
            SHELLOSSUS_HTTP_TIMEOUT = '2'
        } -Action {
            Invoke-InternalHttpWorker
        }
        $clErrWritten = Get-Content -LiteralPath $clHttpErr.FullName -Raw -Encoding UTF8
        Assert-True ($script:InternalWorkerFailed -and [bool]$clErrWritten -and $clErrWritten.Trim().Length -gt 0) 'ConstrainedLanguage Invoke-InternalHttpWorker did not record error output.'
    }
    finally {
        Remove-Item -LiteralPath $clHttpIn.FullName, $clHttpErr.FullName, $clHttpOut -Force -ErrorAction SilentlyContinue
    }

    $clSubMissingThrew = $false
    try {
        Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_SUB_SCRIPT = (Join-Path $testRoot 'missing-sub-worker.ps1')
            SHELLOSSUS_SUB_PROMPT = (Join-Path $testRoot 'missing-prompt.tmp')
        } -Action {
            Invoke-InternalSubagentWorker
        }
    }
    catch {
        $clSubMissingThrew = $true
    }
    Assert-True $clSubMissingThrew 'ConstrainedLanguage Invoke-InternalSubagentWorker accepted missing SHELLOSSUS_SUB_SCRIPT.'

    # Task 4: Get-AgentFileContentDigest native + ConstrainedLanguage pure-PowerShell fallback verification.
    function Set-TestRawBytes {
        param([string]$LiteralPath, [byte[]]$Bytes)
        if ($Bytes.Count -eq 0) {
            $null = New-Item -ItemType File -Path $LiteralPath -Force -ErrorAction Stop
            return
        }
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Set-Content -LiteralPath $LiteralPath -Value $Bytes -Encoding Byte -ErrorAction Stop
        }
        else {
            Set-Content -LiteralPath $LiteralPath -Value $Bytes -AsByteStream -ErrorAction Stop
        }
    }

    $digestDir = Join-Path $testRoot 'digest-checks'
    New-Item -ItemType Directory -Path $digestDir -Force | Out-Null
    $nativeSamplePath = Join-Path $digestDir 'native-sample.bin'
    Set-TestRawBytes -LiteralPath $nativeSamplePath -Bytes ([byte[]]@(1, 2, 3, 4, 250, 255))
    $nativeDigest = Get-AgentFileContentDigest -LiteralPath $nativeSamplePath
    Assert-True ([bool]$nativeDigest -and $nativeDigest -cmatch '^[0-9A-F]{64}$') "Expected 64-char hex SHA-256 digest from native Get-AgentFileContentDigest, got: $nativeDigest"

    $missingDigestThrew = $false
    try { $null = Get-AgentFileContentDigest -LiteralPath (Join-Path $digestDir 'does-not-exist.bin') }
    catch { $missingDigestThrew = $true }
    Assert-True $missingDigestThrew 'Get-AgentFileContentDigest did not throw on missing file.'

    $dirDigestThrew = $false
    try { $null = Get-AgentFileContentDigest -LiteralPath $digestDir }
    catch { $dirDigestThrew = $true }
    Assert-True $dirDigestThrew 'Get-AgentFileContentDigest did not throw on directory path.'

    & {
        # Windows PowerShell 5.1 Get-FileHash silently skips directories.
        function Get-FileHash { return $null }
        $skippedDirDigestThrew = $false
        try { $null = Get-AgentFileContentDigest -LiteralPath $digestDir }
        catch { $skippedDirDigestThrew = $true }
        Assert-True $skippedDirDigestThrew 'Get-AgentFileContentDigest accepted a directory when Get-FileHash silently skipped it.'
    }

    & {
        function Get-FileHash {
            throw 'Simulated non-CLM I/O failure.'
        }
        $nonClmRethrown = $false
        try { $null = Get-AgentFileContentDigest -LiteralPath $nativeSamplePath }
        catch {
            if ($_.Exception.Message -like '*Simulated non-CLM I/O failure*') {
                $nonClmRethrown = $true
            }
        }
        Assert-True $nonClmRethrown 'Get-AgentFileContentDigest swallowed a non-ConstrainedLanguage error.'
    }

    & {
        function Get-FileHash {
            throw 'Cannot invoke method. Method invocation is supported only on core types in this language mode.'
        }

        $fbMissingThrew = $false
        try { $null = Get-AgentFileContentDigest -LiteralPath (Join-Path $digestDir 'fb-missing.bin') }
        catch { $fbMissingThrew = $true }
        Assert-True $fbMissingThrew 'Fallback Get-AgentFileContentDigest did not throw on missing file.'

        $fbDirThrew = $false
        try { $null = Get-AgentFileContentDigest -LiteralPath $digestDir }
        catch { $fbDirThrew = $true }
        Assert-True $fbDirThrew 'Fallback Get-AgentFileContentDigest did not throw on directory.'

        $fbEmptyPath = Join-Path $digestDir 'empty.bin'
        Set-TestRawBytes -LiteralPath $fbEmptyPath -Bytes ([byte[]]@())
        $fbEmptyDigest1 = Get-AgentFileContentDigest -LiteralPath $fbEmptyPath
        $fbEmptyDigest2 = Get-AgentFileContentDigest -LiteralPath $fbEmptyPath
        Assert-True ([bool]$fbEmptyDigest1 -and $fbEmptyDigest1 -ceq $fbEmptyDigest2) 'Fallback Get-AgentFileContentDigest failed or was non-deterministic on empty file.'

        [byte[]]$baseBytes = @(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200)
        $fbBaseA = Join-Path $digestDir 'base-a.bin'
        $fbBaseB = Join-Path $digestDir 'base-b.bin'
        $fbFlipStart = Join-Path $digestDir 'flip-start.bin'
        $fbFlipMid = Join-Path $digestDir 'flip-mid.bin'
        $fbFlipEnd = Join-Path $digestDir 'flip-end.bin'
        $fbLenPlus = Join-Path $digestDir 'len-plus.bin'

        [byte[]]$startBytes = @($baseBytes); $startBytes[0] = 11
        [byte[]]$midBytes = @($baseBytes); $midBytes[10] = 111
        [byte[]]$endBytes = @($baseBytes); $endBytes[19] = 201
        [byte[]]$lenBytes = @($baseBytes) + @([byte]0)

        Set-TestRawBytes -LiteralPath $fbBaseA -Bytes $baseBytes
        Set-TestRawBytes -LiteralPath $fbBaseB -Bytes $baseBytes
        Set-TestRawBytes -LiteralPath $fbFlipStart -Bytes $startBytes
        Set-TestRawBytes -LiteralPath $fbFlipMid -Bytes $midBytes
        Set-TestRawBytes -LiteralPath $fbFlipEnd -Bytes $endBytes
        Set-TestRawBytes -LiteralPath $fbLenPlus -Bytes $lenBytes

        $dBaseA = Get-AgentFileContentDigest -LiteralPath $fbBaseA
        $dBaseB = Get-AgentFileContentDigest -LiteralPath $fbBaseB
        $dStart = Get-AgentFileContentDigest -LiteralPath $fbFlipStart
        $dMid = Get-AgentFileContentDigest -LiteralPath $fbFlipMid
        $dEnd = Get-AgentFileContentDigest -LiteralPath $fbFlipEnd
        $dLen = Get-AgentFileContentDigest -LiteralPath $fbLenPlus

        Assert-True ($dBaseA -ceq $dBaseB) 'Fallback Get-AgentFileContentDigest returned different digests for identical bytes.'
        Assert-True ($dBaseA -cne $fbEmptyDigest1) 'Fallback digest collided with empty file.'
        Assert-True ($dBaseA -cne $dStart) 'Fallback digest did not change on 1-byte flip at start.'
        Assert-True ($dBaseA -cne $dMid) 'Fallback digest did not change on 1-byte flip in middle.'
        Assert-True ($dBaseA -cne $dEnd) 'Fallback digest did not change on 1-byte flip at end.'
        Assert-True ($dBaseA -cne $dLen) 'Fallback digest did not change on length extension.'
        $uniqueSet = @($dBaseA, $dStart, $dMid, $dEnd, $dLen, $fbEmptyDigest1 | Select-Object -Unique)
        Assert-True ($uniqueSet.Count -eq 6) 'Fallback digests were not pairwise distinct across byte mutations.'

        # Verify Save-AgentSession + Assert-AgentSessionRevision + Invoke-SessionResume under fallback.
        $fbSessFile = Join-Path $sessionDirTest 'fb-clm-sess.jsonl'
        $fbSessState = @{
            messages = @(
                @{ role = 'system'; content = 'sys' },
                @{ role = 'user'; content = 'fallback user msg' },
                @{ role = 'assistant'; content = 'fallback assistant reply' }
            )
        }
        Save-AgentSession -SessionFile $fbSessFile -State $fbSessState -Workspace $workspacePath -Model 'fb-model' -SessionId 'sid-fb-1'
        $fbSessState.messages += @{ role = 'user'; content = 'second turn' }
        $fbSessState.messages += @{ role = 'assistant'; content = 'second reply' }
        Save-AgentSession -SessionFile $fbSessFile -State $fbSessState -Workspace $workspacePath -Model 'fb-model' -SessionId 'sid-fb-1'
        $fbResumed = @{ messages = @() }
        Invoke-SessionResume -SessionFile $fbSessFile -State $fbResumed -CurrentWorkspace $workspacePath | Out-Null
        Assert-True ($fbResumed.session_id -eq 'sid-fb-1' -and $fbResumed.messages.Count -ge 5) 'Invoke-SessionResume failed under Get-AgentFileContentDigest fallback.'
        $fbResumed.messages += @{ role = 'user'; content = 'post-resume turn' }
        $fbResumed.messages += @{ role = 'assistant'; content = 'post-resume reply' }
        Save-AgentSession -SessionFile $fbSessFile -State $fbResumed -Workspace $workspacePath -Model 'fb-model' -SessionId 'sid-fb-1'

        # Verify UTF-16 LE BOM edit_file + write_file + Invoke-AgentUndo + invalid binary rejection under fallback.
        $savedPermFb = $script:AgentPermission
        $savedModeFb = $script:OutputMode
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'json'
        try {
            $fbUtf16Rel = 'fb-utf16le.txt'
            $fbUtf16Full = Join-Path $workspacePath $fbUtf16Rel
            [byte[]]$utf16OrigBytes = @(255, 254, 111, 0, 110, 0, 101, 0, 10, 0, 116, 0, 119, 0, 111, 0)
            Set-TestRawBytes -LiteralPath $fbUtf16Full -Bytes $utf16OrigBytes
            $utf16OrigDigest = Get-AgentFileContentDigest -LiteralPath $fbUtf16Full

            $script:CurrentTurnWrites = @()
            $fbEditArgs = @{ path = $fbUtf16Rel; old_text = 'two'; new_text = '2' } | ConvertTo-Json -Compress
            $fbEditRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'fb-ed'; function = @{ name = 'edit_file'; arguments = $fbEditArgs } } | ConvertFrom-Json
            Assert-True ($fbEditRes.status -eq 'written') "Fallback UTF-16 LE edit_file failed: $($fbEditRes.error)"

            $fbWriteArgs = @{ path = $fbUtf16Rel; content = "alpha`nbeta"; overwrite = $true } | ConvertTo-Json -Compress
            $fbWriteRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'fb-wr'; function = @{ name = 'write_file'; arguments = $fbWriteArgs } } | ConvertFrom-Json
            Assert-True ($fbWriteRes.status -eq 'written') "Fallback UTF-16 LE overwrite write_file failed: $($fbWriteRes.error)"
            Assert-True ((Get-AgentFileContentDigest -LiteralPath $fbUtf16Full) -cne $utf16OrigDigest) 'Fallback UTF-16 LE file digest did not change after edits.'

            $fbUndoState = @{ messages = @(@{ role = 'user'; content = 'u' }) }
            Invoke-AgentUndo -State $fbUndoState -UndoEntry @{ messages = @(); writes = @($script:CurrentTurnWrites) }
            Assert-True ((Get-AgentFileContentDigest -LiteralPath $fbUtf16Full) -ceq $utf16OrigDigest) 'Fallback Invoke-AgentUndo did not restore exact original UTF-16 LE bytes.'

            $fbBadBinRel = 'fb-invalid-utf8.txt'
            $fbBadBinFull = Join-Path $workspacePath $fbBadBinRel
            Set-TestRawBytes -LiteralPath $fbBadBinFull -Bytes ([byte[]]@(195, 40))
            $badOrigDigest = Get-AgentFileContentDigest -LiteralPath $fbBadBinFull
            $fbBadEditArgs = @{ path = $fbBadBinRel; old_text = 'a'; new_text = 'b' } | ConvertTo-Json -Compress
            $fbBadEditRes = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'fb-bad'; function = @{ name = 'edit_file'; arguments = $fbBadEditArgs } } | ConvertFrom-Json
            Assert-True ($fbBadEditRes.error -like '*Invalid or unsupported file encoding*') "Fallback edit_file did not reject invalid UTF-8 bytes: $($fbBadEditRes | ConvertTo-Json -Compress)"
            Assert-True ((Get-AgentFileContentDigest -LiteralPath $fbBadBinFull) -ceq $badOrigDigest) 'Fallback edit_file altered invalid UTF-8 file.'

            $script:CurrentTurnWrites = @()
            $fbConflictRel = 'fb-manual-conflict.txt'
            $fbConflictFull = Join-Path $workspacePath $fbConflictRel
            $null = Invoke-AgentTool -Root $workspacePath -Call @{ id = 'fb-cw'; function = @{ name = 'write_file'; arguments = (@{ path = $fbConflictRel; content = 'agent-v1' } | ConvertTo-Json -Compress) } } | ConvertFrom-Json
            Set-AgentUtf8Content -LiteralPath $fbConflictFull -Value 'user-manual-edit'
            $fbConflictThrew = $false
            try { Invoke-AgentUndo -State @{ messages = @() } -UndoEntry @{ messages = @(); writes = @($script:CurrentTurnWrites) } }
            catch {
                if ($_.Exception.Message -like '*Refusing to overwrite manual changes*') { $fbConflictThrew = $true }
            }
            Assert-True $fbConflictThrew 'Fallback Invoke-AgentUndo did not detect manual modification after write_file.'
        }
        finally {
            $script:AgentPermission = $savedPermFb
            $script:OutputMode = $savedModeFb
        }
    }

    # Task 6: Get-AgentExecutionContext, Restore-AgentExecutionContext, Enter-SubagentExecutionScope,
    # Exit-SubagentExecutionScope, and Invoke-SubagentInProcess isolation in ConstrainedLanguage mode.
    & {
        $cl6Perm = $script:AgentPermission
        $cl6Rev = $script:PermissionRevision
        $cl6Cmd = $script:AutoApproveCommands
        $cl6Web = $script:AutoApproveWeb
        $cl6Enabled = @($script:EnabledTools)
        $cl6Excluded = @($script:ExcludedTools)
        $cl6NoTools = $script:NoTools
        $cl6Depth = $script:SubagentDepth
        $cl6Model = $script:ActiveModelId
        $cl6Endpoint = $script:ActiveEndpoint
        $cl6Workspace = $script:ActiveWorkspace
        $cl6State = $script:ActiveState
        $cl6Todos = @(if ($null -ne $script:ActiveSessionTodos) { Copy-SessionHashtableArray -Items $script:ActiveSessionTodos } else { @() })
        $cl6Mode = $script:OutputMode
        $cl6SubWs = Join-Path $testRoot 'cl6-sub-ws'
        New-Item -ItemType Directory -Path $cl6SubWs -Force | Out-Null
        $cl6SubWs = (Get-Item -LiteralPath $cl6SubWs -Force).FullName
        try {
            $cl6TodoRef = @{ content = 'CL parent todo'; status = 'pending' }
            $cl6ParentState = @{ session_id = 'cl6-sess'; workspace = $workspacePath; model = 'cl6-model'; messages = @(@{ role = 'system'; content = 'sys' }) }
            $script:OutputMode = 'json'
            $script:AgentPermission = 'Ask'
            $script:PermissionRevision = 5
            $script:AutoApproveCommands = $false
            $script:AutoApproveWeb = $false
            $script:EnabledTools = @('read_file', 'run_agent')
            $script:ExcludedTools = @('web_search')
            $script:NoTools = $false
            $script:SubagentDepth = 0
            $script:ActiveModelId = 'cl6-model'
            $script:ActiveEndpoint = ''
            $script:ActiveWorkspace = $workspacePath
            $script:ActiveState = $cl6ParentState
            $script:ActiveSessionTodos = @($cl6TodoRef)

            $cl6Ctx = Get-AgentExecutionContext
            Assert-True ($cl6Ctx -is [hashtable] -and $cl6Ctx.permission_revision -eq 5 -and $cl6Ctx.active_session_todos.Count -eq 1) 'ConstrainedLanguage Get-AgentExecutionContext failed.'
            $cl6TodoRef.status = 'completed'
            Assert-True ($cl6Ctx.active_session_todos[0].status -ceq 'pending') 'ConstrainedLanguage Get-AgentExecutionContext did not deep-copy todos.'
            Restore-AgentExecutionContext -Context $cl6Ctx
            Assert-True ($script:ActiveSessionTodos[0].status -ceq 'pending') 'ConstrainedLanguage Restore-AgentExecutionContext did not restore deep-copied todos.'

            function Invoke-WebRequest {
                param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
                $script:ExcludedTools = @('read_file')
                $script:AutoApproveWeb = $true
                $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'cl6 sub ok' } }) } | ConvertTo-Json -Depth 6 -Compress
                Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
            }
            $cl6SubOut = Invoke-SubagentInProcess -Root $cl6SubWs -RoleName 'recon' -TaskPrompt 'CL6 isolation' -MaxSteps 2
            Assert-True ($cl6SubOut.status -eq 'completed' -and $script:ActiveEndpoint -ceq '' -and $script:ActiveWorkspace -ceq $workspacePath -and ($script:ExcludedTools -join ',') -ceq 'web_search' -and (-not $script:AutoApproveWeb)) 'ConstrainedLanguage Invoke-SubagentInProcess leaked execution context.'
        }
        finally {
            Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $cl6SubWs) { Remove-Item -LiteralPath $cl6SubWs -Recurse -Force -ErrorAction SilentlyContinue }
            $script:AgentPermission = $cl6Perm
            $script:PermissionRevision = $cl6Rev
            $script:AutoApproveCommands = $cl6Cmd
            $script:AutoApproveWeb = $cl6Web
            $script:EnabledTools = @($cl6Enabled)
            $script:ExcludedTools = @($cl6Excluded)
            $script:NoTools = $cl6NoTools
            $script:SubagentDepth = $cl6Depth
            $script:ActiveModelId = $cl6Model
            $script:ActiveEndpoint = $cl6Endpoint
            $script:ActiveWorkspace = $cl6Workspace
            $script:ActiveState = $cl6State
            $script:ActiveSessionTodos = @($cl6Todos)
            $script:OutputMode = $cl6Mode
        }
    }

    # Task 4: True cold-start ConstrainedLanguage child-process verification (LanguageMode set on line 1 before loading any module or script).
    $coldRoot = Join-Path $testRoot 'cold-clm-child'
    $coldWs = Join-Path $coldRoot 'workspace'
    $coldCfg = Join-Path $coldRoot 'missing-config.env'
    $coldSessDir = Join-Path $coldRoot 'sessions'
    New-Item -ItemType Directory -Path $coldWs, $coldSessDir -Force | Out-Null
    Set-TestRawBytes -LiteralPath (Join-Path $coldWs 'utf16le.txt') -Bytes ([byte[]]@(255, 254, 97, 0, 10, 0, 98, 0))
    Set-TestRawBytes -LiteralPath (Join-Path $coldWs 'bad-utf8.txt') -Bytes ([byte[]]@(195, 40))

    $coldRunnerPath = Join-Path $coldRoot 'cold-clm-runner.ps1'
    $coldRunnerLines = @(
        '$ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage''',
        '$ErrorActionPreference = ''Stop''',
        'if ($ExecutionContext.SessionState.LanguageMode -ne ''ConstrainedLanguage'') { throw ''Cold child is not in ConstrainedLanguage.'' }',
        '$docLines = @(& $env:SHELLOSSUS_COLD_BUNDLED -Doctor -Mode json -Workspace $env:SHELLOSSUS_COLD_WS -ConfigPath $env:SHELLOSSUS_COLD_CFG -BaseUrl ''https://example.invalid/v1'' -Model ''test-model'' -NoSession)',
        '$global:LASTEXITCODE = 0',
        'if ($docLines.Count -ne 1) { throw "Expected 1 JSON line from -Doctor, got $($docLines.Count)." }',
        '$docObj = $docLines[0] | ConvertFrom-Json',
        '$langCheck = @($docObj.checks | Where-Object { $_.name -eq ''language_mode'' })[0]',
        'if ($docObj.type -ne ''doctor'' -or -not $langCheck -or $langCheck.status -ne ''pass'' -or $langCheck.message -notlike ''*Language mode: ConstrainedLanguage*'') {',
        '    throw "Unexpected cold CLM doctor output: $($docLines[0])"',
        '}',
        '. $env:SHELLOSSUS_COLD_BUNDLED -LibraryOnly',
        'if ($ExecutionContext.SessionState.LanguageMode -ne ''ConstrainedLanguage'') { throw ''LanguageMode changed after sourcing shellossus.ps1.'' }',
        '$script:OutputMode = ''json''',
        '$script:AgentPermission = ''AutoEdit''',
        '$script:AgentConfigPath = $env:SHELLOSSUS_COLD_CFG',
        '$script:ActiveWorkspace = $env:SHELLOSSUS_COLD_WS',
        '$script:CurrentTurnWrites = @()',
        '$utf16Full = Join-Path $env:SHELLOSSUS_COLD_WS ''utf16le.txt''',
        '$origUtf16Digest = Get-AgentFileContentDigest -LiteralPath $utf16Full',
        '$badRes = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-bad''; function = @{ name = ''edit_file''; arguments = ''{"path":"bad-utf8.txt","old_text":"x","new_text":"y"}'' } } | ConvertFrom-Json',
        'if ($badRes.error -notlike ''*Invalid or unsupported file encoding*'') { throw "Cold CLM bad-utf8 check failed: $($badRes | ConvertTo-Json -Compress)" }',
        '$nonAsciiText = ''Write-Output "'' + ([string][char]0x00E9) + ''"''',
        '$wrBomArgs = @{ path = ''bom-script.ps1''; content = $nonAsciiText } | ConvertTo-Json -Compress',
        '$wrBomRes = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-w1''; function = @{ name = ''write_file''; arguments = $wrBomArgs } } | ConvertFrom-Json',
        'if ($wrBomRes.status -ne ''written'') { throw "Cold CLM write_file bom-script.ps1 failed: $($wrBomRes.error)" }',
        '$edBomArgs = @{ path = ''bom-script.ps1''; old_text = ''Write-Output''; new_text = ''Write-Host'' } | ConvertTo-Json -Compress',
        '$edBomRes = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-e1''; function = @{ name = ''edit_file''; arguments = $edBomArgs } } | ConvertFrom-Json',
        'if ($edBomRes.status -ne ''written'') { throw "Cold CLM edit_file bom-script.ps1 failed: $($edBomRes.error)" }',
        '$edUtf16Res = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-e2''; function = @{ name = ''edit_file''; arguments = ''{"path":"utf16le.txt","old_text":"b","new_text":"beta"}'' } } | ConvertFrom-Json',
        'if ($edUtf16Res.status -ne ''written'') { throw "Cold CLM edit_file utf16le.txt failed: $($edUtf16Res.error)" }',
        '$wrUtf16Res = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-w2''; function = @{ name = ''write_file''; arguments = ''{"path":"utf16le.txt","content":"alpha\nbeta","overwrite":true}'' } } | ConvertFrom-Json',
        'if ($wrUtf16Res.status -ne ''written'') { throw "Cold CLM overwrite utf16le.txt failed: $($wrUtf16Res.error)" }',
        '$coldUndoState = @{ messages = @(@{ role = ''user''; content = ''u'' }) }',
        'Invoke-AgentUndo -State $coldUndoState -UndoEntry @{ messages = @(); writes = @($script:CurrentTurnWrites) }',
        'if (Test-Path -LiteralPath (Join-Path $env:SHELLOSSUS_COLD_WS ''bom-script.ps1'')) { throw ''Cold CLM undo did not remove created bom-script.ps1.'' }',
        'if ((Get-AgentFileContentDigest -LiteralPath $utf16Full) -cne $origUtf16Digest) { throw ''Cold CLM undo did not restore original UTF-16 LE bytes.'' }',
        '$coldSessFile = Join-Path $env:SHELLOSSUS_COLD_SESS ''cold-sess.jsonl''',
        '$coldState = @{ messages = @(@{ role = ''system''; content = ''sys'' }, @{ role = ''user''; content = ''hello cold clm'' }, @{ role = ''assistant''; content = ''ok'' }) }',
        'Save-AgentSession -SessionFile $coldSessFile -State $coldState -Workspace $env:SHELLOSSUS_COLD_WS -Model ''test-model'' -SessionId ''sid-cold-1''',
        '$coldState.messages += @{ role = ''user''; content = ''turn 2'' }',
        '$coldState.messages += @{ role = ''assistant''; content = ''reply 2'' }',
        'Save-AgentSession -SessionFile $coldSessFile -State $coldState -Workspace $env:SHELLOSSUS_COLD_WS -Model ''test-model'' -SessionId ''sid-cold-1''',
        '$coldResumed = @{ messages = @() }',
        'Invoke-SessionResume -SessionFile $coldSessFile -State $coldResumed -CurrentWorkspace $env:SHELLOSSUS_COLD_WS | Out-Null',
        'if ($coldResumed.session_id -ne ''sid-cold-1'' -or $coldResumed.messages.Count -lt 5) { throw ''Cold CLM Invoke-SessionResume failed.'' }',
        'Clear-WorkspaceWalkCache',
        '$coldGrep1 = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-g1''; function = @{ name = ''grep_files''; arguments = ''{"path":".","pattern":"a","literal":true}'' } } | ConvertFrom-Json',
        '$coldGrep2 = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-g2''; function = @{ name = ''grep_files''; arguments = ''{"path":".","pattern":"b","literal":true}'' } } | ConvertFrom-Json',
        'if ($coldGrep1.matches.Count -ne 1 -or $coldGrep2.matches.Count -ne 1 -or $script:WorkspaceWalkCache.Count -eq 0) { throw ''Cold CLM cached literal grep_files failed.'' }',
        '$null = Invoke-AgentTool -Root $env:SHELLOSSUS_COLD_WS -Call @{ id = ''c-w3''; function = @{ name = ''write_file''; arguments = ''{"path":"cold-added.txt","content":"gamma","overwrite":true}'' } } | ConvertFrom-Json',
        'if ($script:WorkspaceWalkCache.Count -ne 0) { throw ''Cold CLM write_file did not invalidate walk cache.'' }',
        '$resolvedSelf = Resolve-StandaloneScriptPath -Required',
        '$workerArgs = Get-AgentWorkerArguments -ScriptPath $resolvedSelf -WorkerMode ''http''',
        'if (-not $workerArgs) { throw ''Cold CLM Get-AgentWorkerArguments returned empty result.'' }',
        '$coldTodo = @{ content = ''cold task''; status = ''pending'' }',
        '$script:ActiveSessionTodos = @($coldTodo)',
        '$coldCtx = Get-AgentExecutionContext',
        '$coldTodo.status = ''completed''',
        '$script:ActiveEndpoint = ''https://leaked.example.invalid/v1/chat/completions''',
        'Restore-AgentExecutionContext -Context $coldCtx',
        'if ($script:ActiveSessionTodos[0].status -cne ''pending'' -or $script:ActiveEndpoint -cne $coldCtx.active_endpoint) { throw ''Cold CLM execution context roundtrip failed.'' }',
        '$null = Set-AgentStreamSetting -StreamSpec ''true''',
        'if (-not $script:StreamRequests) { throw ''Cold CLM Set-AgentStreamSetting failed.'' }',
        '$coldSse = ConvertFrom-AgentSseResponse -RawText (": keepalive`ndata: {`"choices`":[{`"index`":0,`"delta`":{`"content`":`"cold-`"}}]}", "", "data: {`"choices`":[{`"index`":0,`"delta`":{`"content`":`"sse`"},`"finish_reason`":`"stop`"}]}", "", "data: [DONE]" -join "`n")',
        'if ($coldSse.choices[0].message.content -cne ''cold-sse'' -or $coldSse.choices[0].finish_reason -cne ''stop'') { throw ''Cold CLM ConvertFrom-AgentSseResponse failed.'' }',
        '$null = Set-AgentStreamSetting -StreamSpec ''false''',
        'Write-Output ''COLD_CLM_CHILD_OK'''
    )
    Set-AgentUtf8Content -LiteralPath $coldRunnerPath -Value ($coldRunnerLines -join "`n")

    $coldPsExe = Get-AgentPowerShellExecutable
    $coldBundledPath = (Get-Item -LiteralPath "$PSScriptRoot\..\shellossus.ps1" -Force).FullName
    $coldOutput = @(Invoke-WithProcessEnvironment -Values @{
        SHELLOSSUS_COLD_BUNDLED = $coldBundledPath
        SHELLOSSUS_COLD_WS = $coldWs
        SHELLOSSUS_COLD_CFG = $coldCfg
        SHELLOSSUS_COLD_SESS = $coldSessDir
        SHELLOSSUS_API_KEY = $null
    } -Action {
        & $coldPsExe -NoProfile -NonInteractive -File $coldRunnerPath 2>&1
    })
    $coldExit = $LASTEXITCODE
    $coldJoined = ($coldOutput | ForEach-Object { [string]$_ }) -join "`n"
    Assert-True ($coldExit -eq 0 -and ($coldOutput -contains 'COLD_CLM_CHILD_OK')) "Cold-start ConstrainedLanguage child check failed (exit=$coldExit): $coldJoined"

    # Task 7: ConstrainedLanguage verification for Set-AgentStreamSetting, ConvertFrom-AgentSseResponse,
    # Invoke-AgentTurn over SSE, Invoke-AgentCompact over SSE, and truncated SSE safety rejection.
    $savedClStream = $script:StreamRequests
    $savedClPerm7 = $script:AgentPermission
    $savedClMode7 = $script:OutputMode
    try {
        Assert-True ($ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') 'Expected ConstrainedLanguage before Task 7 SSE checks.'
        $clStreamTrue = Set-AgentStreamSetting -StreamSpec 'true'
        Assert-True ($clStreamTrue -and $script:StreamRequests) 'ConstrainedLanguage Set-AgentStreamSetting true failed.'

        $clSseRaw = @(
            ': clm keepalive',
            'data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"clm-think-","content":"clm-"}}]}',
            '',
            'data: {"choices":[{"index":0,"delta":{"reasoning_content":"done","content":"reply","tool_calls":[{"index":0,"id":"cl_tc_0","type":"function","extra_content":{"provider":"x"},"function":{"name":"read_file","arguments":"{\"path\":"}},{"index":1,"id":"cl_tc_1","type":"function","function":{"name":"list_files","arguments":"{}"}}]}}]}',
            '',
            'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a/b/keep.txt\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":18,"completion_tokens":9}}',
            '',
            'data: [DONE]'
        ) -join "`r`n"
        $clSseObj = ConvertFrom-AgentSseResponse -RawText $clSseRaw
        Assert-True ($clSseObj.choices[0].finish_reason -ceq 'tool_calls' -and $clSseObj.choices[0].message.reasoning_content -ceq 'clm-think-done' -and $clSseObj.choices[0].message.content -ceq 'clm-reply') 'ConstrainedLanguage ConvertFrom-AgentSseResponse content/reasoning failed.'
        Assert-True (@($clSseObj.choices[0].message.tool_calls).Count -eq 2 -and $clSseObj.choices[0].message.tool_calls[0].function.arguments -ceq '{"path":"a/b/keep.txt"}' -and $clSseObj.choices[0].message.tool_calls[0].extra_content.provider -ceq 'x') 'ConstrainedLanguage ConvertFrom-AgentSseResponse indexed tool_calls or extension failed.'
        Assert-True ([int]$clSseObj.usage.prompt_tokens -eq 18 -and [int]$clSseObj.usage.completion_tokens -eq 9) 'ConstrainedLanguage ConvertFrom-AgentSseResponse usage failed.'

        foreach ($clBadSse in @(
            'data: {"choices":[{"index":0,"delta":{"content":"no-done"},"finish_reason":"stop"}]}',
            ("data: {`"choices`":[{`"index`":0,`"delta`":{`"content`":`"no-finish`"}}]}`n`ndata: [DONE]"),
            ("data: {broken`n`ndata: [DONE]"),
            ("event: error`ndata: {`"error`":{`"message`":`"clm-stream-err`"}}`n`ndata: [DONE]")
        )) {
            $clBadThrew = $false
            try { $null = ConvertFrom-AgentSseResponse -RawText $clBadSse }
            catch { $clBadThrew = $true }
            Assert-True $clBadThrew "ConstrainedLanguage ConvertFrom-AgentSseResponse accepted unsafe stream: $clBadSse"
        }

        $script:OutputMode = 'json'
        $script:AgentPermission = 'AutoEdit'
        $script:clSseTurnStep = 0
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:clSseTurnStep++
            $reqJson = $Body | ConvertFrom-Json
            Assert-True ([bool]$reqJson.stream -and $Headers['Accept'] -eq 'text/event-stream, application/json') 'ConstrainedLanguage SSE request missing stream=true or Accept header.'
            if ($script:clSseTurnStep -eq 1) {
                $out1 = @(
                    'data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"clm_r1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"a/b/keep.txt\"}"}}]},"finish_reason":"tool_calls"}]}',
                    '',
                    'data: [DONE]'
                ) -join "`n"
                Set-Content -LiteralPath $OutFile -Value $out1 -Encoding UTF8 -NoNewline
                return
            }
            $out2 = @(
                'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"CLM SSE complete"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4}}',
                '',
                'data: [DONE]'
            ) -join "`n"
            Set-Content -LiteralPath $OutFile -Value $out2 -Encoding UTF8 -NoNewline
        }
        try {
            $clSseState = @{
                session_id = 'clm-sse-turn'
                workspace = $workspacePath
                model = 'test-model'
                usage_input_tokens = 0
                usage_output_tokens = 0
                messages = @(
                    @{ role = 'system'; content = 'sys' },
                    @{ role = 'user'; content = 'Read keep.txt in CLM over SSE' }
                )
            }
            Invoke-AgentTurn -State $clSseState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'k' -Root $workspacePath -Steps 4
            Assert-True ($clSseState.messages[-1].content -ceq 'CLM SSE complete' -and $clSseState.usage_input_tokens -eq 10 -and $clSseState.usage_output_tokens -eq 4) 'ConstrainedLanguage Invoke-AgentTurn over SSE failed.'

            $clSseState.messages += @{ role = 'user'; content = 'Recent user turn' }
            $clSseState.messages += @{ role = 'assistant'; content = 'Recent assistant turn' }
            $didClSseCompact = Invoke-AgentCompact -State $clSseState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'k' -KeepRecent 2
            Assert-True ([bool]$didClSseCompact -and ([string]$clSseState.messages[1].content).Contains('CLM SSE complete')) 'ConstrainedLanguage Invoke-AgentCompact over SSE failed.'
        }
        finally {
            Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
            Remove-Variable -Name clSseTurnStep -Scope Script -ErrorAction SilentlyContinue
        }
    }
    finally {
        $script:StreamRequests = $savedClStream
        $script:AgentPermission = $savedClPerm7
        $script:OutputMode = $savedClMode7
    }
}
finally {
    Remove-TestEnvironment -Env $envData
}
