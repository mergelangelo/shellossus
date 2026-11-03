$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    Set-Content -LiteralPath (Join-Path $workspacePath 'hello.txt') -Value 'hello' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workspacePath '.env') -Value 'SECRET=hidden' -Encoding UTF8

    # AGENTS.md, APPEND_SYSTEM.md, Skills catalog, Prompt templates, and @file prompt expansion.
    Set-Content -LiteralPath (Join-Path $workspacePath 'AGENTS.md') -Value 'Always use snake_case.' -Encoding UTF8
    $dotH = Join-Path $workspacePath '.shellossus'
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

    # Global skills in ConfigDir/skills can be read via read_file, while writes outside workspace stay blocked.
    $globalCfgDir = Join-Path $testRoot 'global-cfg'
    $globalSkillDir = Join-Path $globalCfgDir 'skills\corp-standard'
    New-Item -ItemType Directory -Path $globalSkillDir -Force | Out-Null
    $globalSkillPath = Join-Path $globalSkillDir 'SKILL.md'
    Set-Content -LiteralPath $globalSkillPath -Value "---`nname: corp-standard`ndescription: Global skill`n---`nGlobal rules body." -Encoding UTF8
    $sysWithGlobal = Build-SystemPrompt -Root $workspacePath -ConfigDir $globalCfgDir
    Assert-True ($sysWithGlobal.Contains('corp-standard')) 'Global skill was not listed in system prompt.'
    $call = @{ id = 'g-read'; function = @{ name = 'read_file'; arguments = (@{ path = $globalSkillPath } | ConvertTo-Json -Compress) } }
    $readGlobalSkill = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($readGlobalSkill.text -like '*Global rules body*') 'Global skill could not be read via read_file.'
    $call = @{ id = 'g-edit'; function = @{ name = 'edit_file'; arguments = (@{ path = $globalSkillPath; old_text = 'Global'; new_text = 'Hacked' } | ConvertTo-Json -Compress) } }
    $editGlobalSkill = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($editGlobalSkill.error -like '*outside*') 'Editing global skill outside workspace must be blocked.'

    # Expand-TemplateArgs ($1, $@, $ARGUMENTS, ${2:-default}, ${@:2}, ${@:1:2}, non-recursive) & /skill:name.
    $tplOut = Expand-TemplateArgs -Content 'A=$1 B=${2:-fallback} ALL=$@ SLICE=${@:2} LEN=${@:1:2}' -ArgsString '"hello $2" world three'
    Assert-True ($tplOut -eq 'A=hello $2 B=world ALL=hello $2 world three SLICE=world three LEN=hello $2 world') 'Expand-TemplateArgs bash-style positional/slice/default substitution failed.'
    $skillCmdOut = Resolve-PromptTemplate -Root $workspacePath -ConfigDir $globalCfgDir -InputText '/skill:sql-tuning orders_table'
    Assert-True ($skillCmdOut.Contains('<skill name="sql-tuning"') -and $skillCmdOut.Contains('User: orders_table')) '/skill:name command expansion failed.'

    # Session JSONL persistence roundtrip and project-scoped session lookup.
    $sessionDirTest = Join-Path $testRoot 'sessions'
    $sessionFile = Join-Path $sessionDirTest 'test-ws1.jsonl'
    $otherWs = Join-Path $testRoot 'other-workspace'
    New-Item -ItemType Directory -Path $otherWs -Force | Out-Null
    $sampleState = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'hi' },
            @{ role = 'assistant'; content = 'hello' }
        )
        todos = @(
            @{ content = 'Task 1'; status = 'completed' },
            @{ content = 'Task 2'; status = 'pending' }
        )
    }
    $script:ActiveSessionTodos = @($sampleState.todos)
    Save-AgentSession -SessionFile $sessionFile -State $sampleState -Workspace $workspacePath -Model 'model-a' -SessionId 'sid-1'
    $meta1 = Get-AgentSessionMeta -SessionFile $sessionFile
    Assert-True ($meta1.version -eq 1 -and $meta1.id -eq 'sid-1' -and $meta1.model -eq 'model-a') 'Session metadata header missing or invalid.'
    $script:ActiveSessionTodos = @()
    $restoredState = @{}
    $restoredMsgs = @(Read-AgentSession -SessionFile $sessionFile -State $restoredState)
    Assert-True ($restoredMsgs.Count -eq 3 -and $restoredMsgs[2].content -eq 'hello' -and $restoredState.session_id -eq 'sid-1' -and $restoredState.todos.Count -eq 2 -and $script:ActiveSessionTodos.Count -eq 2 -and $script:ActiveSessionTodos[0].content -eq 'Task 1') 'Session JSONL roundtrip with todos failed.'
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

    # Session tree branching (/tree), session forking (/fork), and HTML session export (/export).
    $treeSessionDir = Join-Path $testRoot 'tree-sessions'
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

    # Compaction, iterative compaction, and compaction preservation across /tree switches and session resume.
    $script:lastCompactBody = ''
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $payload = $Body | ConvertFrom-Json
        $script:lastCompactBody = [string]$payload.messages[1].content
        $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = "## Goal`nCompacted goal summary" } }) } | ConvertTo-Json -Depth 10 -Compress
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
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

    # /tree and /fork reject switching to an unfinished tool_calls message.
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

    # Dynamic <capabilities> block in Build-SystemPrompt and Sync-AgentCapabilities across mode switches without notice bloat.
    $script:AgentPermission = 'ReadOnly'
    $roSys = Build-SystemPrompt -Root $workspacePath -ConfigDir ''
    Assert-True ($roSys.Contains('Permission mode: ReadOnly.') -and $roSys.Contains('Available tools: list_files, read_file, find_files, grep_files, fetch_url, web_search, todo, run_agent.') -and $roSys.Contains('File modification and shell execution are unavailable.')) 'Build-SystemPrompt in ReadOnly mode did not render expected dynamic <capabilities> block.'
    Assert-True ($roSys.Contains('Environment: OS=') -and $roSys.Contains('Command shell (run_command):') -and $roSys.Contains('Get-Command') -and $roSys.Contains($workspacePath)) 'Build-SystemPrompt missing environment, run_command shell, workspace, or Get-Command guidance.'
    Assert-True (-not $roSys.Contains('Available tools: list_files, read_file, find_files, grep_files, write_file')) 'ReadOnly system prompt listed write_file as available.'

    $script:AgentPermission = 'AutoEdit'
    $syncState = @{
        workspace = $workspacePath
        messages = @(
            @{ role = 'system'; content = (Build-SystemPrompt -Root $workspacePath -ConfigDir '') },
            @{ role = 'user'; content = 'Write file' },
            @{ role = 'assistant'; content = 'Wrote file in AutoEdit.' }
        )
    }
    $script:AgentPermission = 'ReadOnly'
    $sync1 = Sync-AgentCapabilities -State $syncState -RecordTransition
    Assert-True ($sync1.prompt_updated -and $sync1.consistent -and $syncState.messages[0].content.Contains('Permission mode: ReadOnly.')) 'Sync-AgentCapabilities did not update system prompt to ReadOnly.'
    $notices1 = @($syncState.messages | Where-Object { $_.role -eq 'user' -and ([string]$_.content).StartsWith('[Capability State Change]') })
    Assert-True ($notices1.Count -eq 1 -and $notices1[0].content.Contains('Permission mode is now ReadOnly.')) 'Expected exactly one capability transition notice after switching to ReadOnly.'

    $script:AgentPermission = 'Ask'
    $sync2 = Sync-AgentCapabilities -State $syncState -RecordTransition
    $notices2 = @($syncState.messages | Where-Object { $_.role -eq 'user' -and ([string]$_.content).StartsWith('[Capability State Change]') })
    Assert-True ($notices2.Count -eq 1 -and $sync2.prompt_updated -and $sync2.consistent -and $syncState.messages[0].content.Contains('Permission mode: Ask.') -and $notices2[0].content.Contains('Permission mode is now Ask.')) 'Repeated permission changes accumulated multiple capability notices or failed to update to Ask.'
    Assert-True ($compTreeState.messages[0].content.Contains('<capabilities>') -and $compTreeState.messages[0].content.Contains('Get-Command') -and $resumedCompState.messages[0].content.Contains('<capabilities>')) 'Capabilities and environment block was not preserved across compaction and session resume.'

    # Subagent roles catalog (.shellossus/agents/*.md), /agent:<role> command expansion, and compaction tracking of subagent files.
    $agentsDir = Join-Path $dotH 'agents'
    New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $agentsDir 'sql-auditor.md') -Value "---`nname: sql-auditor`ndescription: Audit SQL queries for locks`ntools: read_file, grep_files`n---`nFocus on `$1 lock contention." -Encoding UTF8
    $rolesCat = Get-AgentRolesCatalog -Root $workspacePath -ConfigDir $globalCfgDir
    Assert-True ($rolesCat.Contains('<available_agents>') -and $rolesCat.Contains('sql-auditor')) 'Get-AgentRolesCatalog did not load custom agent role.'
    $resolvedSqlAuditor = Resolve-AgentRole -Name 'sql-auditor' -Root $workspacePath -ConfigDir $globalCfgDir
    Assert-True ($resolvedSqlAuditor.permission -eq 'ReadOnly' -and $resolvedSqlAuditor.tools.Count -eq 2) 'Custom role with read-only tools did not auto-infer ReadOnly permission.'
    Assert-True ((Resolve-AgentRole -Name 'scout' -Root $workspacePath).name -eq 'recon' -and (Resolve-AgentRole -Name 'reviewer' -Root $workspacePath).name -eq 'audit' -and (Resolve-AgentRole -Name 'worker' -Root $workspacePath).name -eq 'craft') 'Built-in role alias resolution failed.'
    $agentCmdOut = Resolve-PromptTemplate -Root $workspacePath -ConfigDir $globalCfgDir -InputText '/agent:sql-auditor orders_table'
    Assert-True ($agentCmdOut.Contains('<agent_role name="sql-auditor" permission="ReadOnly">') -and $agentCmdOut.Contains('Focus on orders_table lock contention.') -and $agentCmdOut.Contains('run_agent with role="sql-auditor"')) '/agent:<role> command expansion failed.'
    $subOps = Get-CompactionFileOperations -Messages @(
        @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'sub1'; type = 'function'; function = @{ name = 'run_agent'; arguments = '{"role":"craft","prompt":"fix"}' } }) },
        @{ role = 'tool'; tool_call_id = 'sub1'; content = '{"status":"completed","read_files":["sub-read.sql","sub-both.sql"],"modified_files":["sub-both.sql","sub-mod.sql"]}' }
    )
    Assert-True (($subOps.read_files -contains 'sub-read.sql') -and ($subOps.read_files -notcontains 'sub-both.sql') -and ($subOps.modified_files -contains 'sub-both.sql') -and ($subOps.modified_files -contains 'sub-mod.sql')) 'Get-CompactionFileOperations did not extract read_files and modified_files from run_agent tool result.'

    # Context window (default 128k) and auto-compact threshold (default 96k = 75%), token spec parsing, and API prompt_tokens tracking.
    Assert-True ((Resolve-TokenBudgetValue -Spec '128k') -eq 128000) 'Resolve-TokenBudgetValue 128k failed.'
    Assert-True ((Resolve-TokenBudgetValue -Spec '75%' -BaseTokens 128000) -eq 96000) 'Resolve-TokenBudgetValue 75% of 128k failed.'
    $defStats = Get-ContextStats -State $sampleState
    Assert-True ($defStats.context_window_tokens -eq 128000 -and $defStats.compact_threshold_tokens -eq 96000) "Expected default 128k/96k limits, got $($defStats.context_window_tokens)/$($defStats.compact_threshold_tokens)"
    $customLim = Set-AgentContextLimits -WindowSpec '64k' -CompactSpec '48k'
    Assert-True ($customLim.context_window_tokens -eq 64000 -and $customLim.compact_threshold_tokens -eq 48000 -and $customLim.compact_pct -eq 75) 'Set-AgentContextLimits 64k/48k failed.'
    $null = Set-AgentContextLimits -WindowSpec '128k' -CompactSpec '75%'
}
finally {
    Remove-TestEnvironment -Env $envData
}
