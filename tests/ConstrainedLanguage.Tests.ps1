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
    & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $clProfilePath -Shortcut 'shoscl'
    $clProfText = Get-Content -LiteralPath $clProfilePath -Raw -Encoding UTF8
    Assert-True ($clProfText.Contains('function global:shellossus') -and $clProfText.Contains('function global:shoscl')) 'ConstrainedLanguage install.ps1 failed.'

    $clEmptyCont = @{ messages = @(@{ role = 'system'; content = 'sys' }) }
    Assert-True (-not (Invoke-AgentContinue -State $clEmptyCont -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2)) 'ConstrainedLanguage Invoke-AgentContinue failed.'

    $clDoneProc = @{ Id = 0; HasExited = $true; ExitCode = 0 }
    Wait-AgentProcessWithSpinner -Process $clDoneProc -StatusLabel 'CL wait check' -TimeoutSec 5 -PollMs 10

    $clCap = Get-AgentCapabilities -Root $workspacePath
    Assert-True ($clCap.permission -eq 'Ask' -and $clCap.tool_names.Count -eq 7 -and $clCap.environment.language_mode -eq 'ConstrainedLanguage') 'ConstrainedLanguage Get-AgentCapabilities or Get-AgentEnvironment failed.'
    $clSyncState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'q' }, @{ role = 'assistant'; content = 'a' }) }
    $clSyncRes = Sync-AgentCapabilities -State $clSyncState -RecordTransition
    Assert-True ($clSyncRes.consistent -and $clSyncState.messages[0].content.Contains('<capabilities>')) 'ConstrainedLanguage Sync-AgentCapabilities failed.'
    $clSig = Get-ToolCallSignature -Call @{ function = @{ name = 'read_file'; arguments = '{"max_lines":10,"path":"a.txt"}' } } -Epoch 1
    Assert-True ($clSig -eq '1|read_file|{max_lines:10,path:"a.txt"}') 'ConstrainedLanguage Get-ToolCallSignature failed.'
    $clWalk = @(Get-WorkspaceWalkEntries -Root $workspacePath -SearchPath $workspacePath -FilesOnly)
    Assert-True ($clWalk.Count -ge 1) 'ConstrainedLanguage Get-WorkspaceWalkEntries failed.'
}
finally {
    Remove-TestEnvironment -Env $envData
}
