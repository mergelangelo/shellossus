$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    Set-Content -LiteralPath (Join-Path $workspacePath 'hello.txt') -Value 'hello' -Encoding UTF8

    # Agent/tool/API round trip without any network or real key.
    $script:requests = 0
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction)
        $script:requests++
        $payload = $Body | ConvertFrom-Json
        Assert-True ($Method -eq 'Post') 'Expected POST.'
        Assert-True ($payload.model -eq 'test-model') 'Wrong model.'
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
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $mockReply = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body -TimeoutSec $TimeoutSec -ErrorAction $ErrorAction
        $mockReply | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    }
    $state = @{ messages = @(@{ role = 'user'; content = 'List files' }) }
    Invoke-AgentTurn -State $state -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 3
    Assert-True ($script:requests -eq 2) 'Expected two API calls.'
    Assert-True ($state.messages[-1].content -eq 'Files inspected.') 'Missing final answer.'

    # Scoped instructions must reach the model before any parallel writes execute.
    $scopedDir = Join-Path $workspacePath 'scoped/nested'
    New-Item -ItemType Directory -Path $scopedDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workspacePath 'scoped/AGENTS.md') -Value 'Scoped parent rule.' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $scopedDir 'AGENTS.md') -Value 'Scoped child rule.' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $scopedDir 'input.txt') -Value 'input' -Encoding UTF8
    $script:scopeStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:scopeStep++
        $payload = $Body | ConvertFrom-Json
        if ($script:scopeStep -eq 2) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scopedDir 'a.txt'))) 'First scoped write happened before instructions were delivered.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scopedDir 'b.txt'))) 'Second scoped write happened before instructions were delivered.'
            $notice1 = $payload.messages[-2].content | ConvertFrom-Json
            $notice2 = $payload.messages[-1].content | ConvertFrom-Json
            $notice3 = $payload.messages[-3].content | ConvertFrom-Json
            Assert-True ($notice1.status -eq 'instructions_required' -and $notice2.status -eq 'instructions_required' -and $notice3.status -eq 'instructions_required' -and $notice1.instructions.Contains('Scoped parent rule.') -and $notice1.instructions.Contains('Scoped child rule.')) 'Scoped instructions were not delivered before file reads and writes.'
        }
        $message = if ($script:scopeStep -lt 3) {
            @{ content = $null; tool_calls = @(
                @{ id = "scope-read-$script:scopeStep"; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"scoped/nested/input.txt"}' } },
                @{ id = "scope-a-$script:scopeStep"; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"scoped/nested/a.txt","content":"a"}' } },
                @{ id = "scope-b-$script:scopeStep"; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"scoped/nested/b.txt","content":"b"}' } }
            ) }
        } else { @{ content = 'Scoped writes complete.' } }
        $reason = if ($script:scopeStep -lt 3) { 'tool_calls' } else { 'stop' }
        @{ choices = @(@{ finish_reason = $reason; message = $message }) } | ConvertTo-Json -Depth 15 -Compress | Set-Content -LiteralPath $OutFile -Encoding UTF8 -NoNewline
    }
    $script:AgentPermission = 'AutoEdit'
    $script:OutputMode = 'json'
    $scopeState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'Write files.' }) }
    Invoke-AgentTurn -State $scopeState -Endpoint 'https://example.invalid' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
    Assert-True ($script:scopeStep -eq 3 -and (Test-Path -LiteralPath (Join-Path $scopedDir 'a.txt')) -and (Test-Path -LiteralPath (Join-Path $scopedDir 'b.txt'))) 'Scoped writes did not complete after instructions.'
    $script:AgentPermission = 'Ask'
    $script:OutputMode = 'text'
    Remove-Item -LiteralPath (Join-Path $workspacePath 'scoped') -Recurse -Force

    # JSON mode (-Mode json) emits only pure JSONL without plain-text tool logs or Read-Host prompts.
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

    # MaxSteps default (50), step limit tracking, /continue (Invoke-AgentContinue), and mid-turn auto-compaction.
    Assert-True ($MaxSteps -eq 50) "Expected default MaxSteps=50, got $MaxSteps."
    $emptyContState = @{ messages = @(@{ role = 'system'; content = 'sys' }) }
    Assert-True (-not (Invoke-AgentContinue -State $emptyContState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2)) 'Invoke-AgentContinue should return false when there is no conversation to continue.'

    $script:contTurnStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:contTurnStep++
        if ($script:contTurnStep -le 2) {
            $limVal = $script:contTurnStep * 10
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = "ct-$($script:contTurnStep)"; type = 'function'; function = @{ name = 'list_files'; arguments = "{`"path`":`".`",`"limit`":$limVal}" } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Continued and finished.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    $contState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'Multi-step task' }) }
    Invoke-AgentTurn -State $contState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2
    Assert-True ([bool]$contState.step_limit_reached) 'Expected step_limit_reached=true after hitting step limit.'
    Assert-True ($contState.messages[-1].role -eq 'tool') 'Expected last message to be tool output when step limit is reached.'
    $contRes = Invoke-AgentContinue -State $contState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2
    Assert-True ($contRes -and (-not $contState.step_limit_reached) -and $contState.messages[-1].content -eq 'Continued and finished.') 'Invoke-AgentContinue failed to resume after step limit.'
    $userMsgCount = @($contState.messages | Where-Object { $_.role -eq 'user' }).Count
    Assert-True ($userMsgCount -eq 1) 'Invoke-AgentContinue after tool_calls should not inject a redundant user message.'

    # Invoke-AgentContinue after an assistant stop message appends 'Continue.' user prompt.
    $contRes2 = Invoke-AgentContinue -State $contState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2
    $userMsgsAfter = @($contState.messages | Where-Object { $_.role -eq 'user' })
    Assert-True ($contRes2 -and $userMsgsAfter.Count -eq 2 -and $userMsgsAfter[-1].content -eq 'Continue.') 'Invoke-AgentContinue after assistant stop should append Continue. user prompt.'

    # Mid-turn proactive auto-compaction when context exceeds compact threshold across steps.
    $null = Set-AgentContextLimits -WindowSpec '20k' -CompactSpec '15k'
    $bigFiller = 'X' * 32000
    $midCompactState = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = $bigFiller },
            @{ role = 'assistant'; content = $bigFiller },
            @{ role = 'user'; content = 'run step' }
        )
    }
    $script:midStepReq = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:midStepReq++
        $parsedBody = $Body | ConvertFrom-Json
        if ($parsedBody.messages[0].content -like '*context compaction assistant*') {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = "## Goal`nMid-turn compacted." } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:midStepReq -eq 1) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'mc-1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Done after mid-turn compact.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    Invoke-AgentTurn -State $midCompactState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 3
    $null = Set-AgentContextLimits -WindowSpec '128k' -CompactSpec '75%'
    Assert-True ($midCompactState.messages[1].content.StartsWith('[Compacted Conversation Summary]') -and $midCompactState.messages[-1].content -eq 'Done after mid-turn compact.') 'Mid-turn proactive auto-compaction did not trigger inside Invoke-AgentTurn.'

    # Live waiting spinner/timer (Wait-AgentProcessWithSpinner) in text mode vs silent in JSON mode.
    $script:spinnerLines = @()
    $script:fakeProc = @{ Id = 0; HasExited = $false; ExitCode = 0 }
    $script:sleepCount = 0
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        $script:spinnerLines += $text
    }
    function Start-Sleep {
        param($Seconds, $Milliseconds)
        $script:sleepCount++
        if ($script:sleepCount -ge 2) { $script:fakeProc.HasExited = $true }
    }
    try {
        $script:OutputMode = 'text'
        Wait-AgentProcessWithSpinner -Process $script:fakeProc -StatusLabel '[step 1/50] Waiting for test-model' -TimeoutSec 30 -PollMs 10
        Assert-True ($script:spinnerLines.Count -ge 3) 'Expected spinner frames and clear line in text mode.'
        Assert-True ([bool]($script:spinnerLines | Where-Object { $_ -like '*Waiting for test-model*' })) 'Spinner did not render status label.'
        Assert-True ($script:spinnerLines[-1] -match '^\r +\r$') 'Spinner did not clear status line upon completion.'

        $script:spinnerLines = @()
        $script:sleepCount = 0
        $script:fakeProc.HasExited = $false
        $script:OutputMode = 'json'
        Wait-AgentProcessWithSpinner -Process $script:fakeProc -StatusLabel '[step 1/50] Waiting for test-model' -TimeoutSec 30 -PollMs 10
        Assert-True ($script:spinnerLines.Count -eq 0) 'Wait-AgentProcessWithSpinner emitted output in JSON mode.'
    }
    finally {
        $script:OutputMode = 'text'
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    }

    # Scenario: AutoEdit -> ReadOnly -> Ask synchronization, diagnostics, and real write preview/confirmation in Ask.
    $script:Diagnostics = $true
    $script:AgentPermission = 'AutoEdit'
    $modeSwitchState = @{
        messages = @(
            @{ role = 'system'; content = (Build-SystemPrompt -Root $workspacePath -ConfigDir '') }
        )
    }
    $script:modeStep = 0
    $script:capturedPayloads = @()
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:modeStep++
        $parsed = $Body | ConvertFrom-Json
        $script:capturedPayloads += $parsed
        if ($script:modeStep -eq 1) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'ae-w1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"mode-test.txt","content":"v1-autoedit","overwrite":true}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:modeStep -eq 2) {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Wrote mode-test.txt in AutoEdit.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:modeStep -eq 3) {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Cannot modify files in ReadOnly mode.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:modeStep -eq 4) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'ask-w1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"mode-test.txt","content":"v2-ask-confirmed","overwrite":true}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Updated mode-test.txt after WRITE confirmation.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    function Read-Host {
        param($Prompt)
        return 'WRITE'
    }
    try {
        # 1. AutoEdit turn writes file without confirmation.
        $modeSwitchState.messages += @{ role = 'user'; content = 'Create mode-test.txt' }
        Invoke-AgentTurn -State $modeSwitchState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'mode-test.txt') -Raw -Encoding UTF8) -eq 'v1-autoedit') 'AutoEdit write failed.'
        Assert-True ($modeSwitchState.last_diagnostics.permission -eq 'AutoEdit' -and ($modeSwitchState.last_diagnostics.tools -contains 'write_file')) 'Diagnostics did not record AutoEdit capabilities.'

        # 2. Switch to ReadOnly: tools and system prompt must exclude write_file/edit_file/run_command.
        $script:AgentPermission = 'ReadOnly'
        Sync-AgentCapabilities -State $modeSwitchState -RecordTransition | Out-Null
        $modeSwitchState.messages += @{ role = 'user'; content = 'Update mode-test.txt in ReadOnly' }
        Invoke-AgentTurn -State $modeSwitchState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        $roPayload = $script:capturedPayloads[2]
        $roToolNames = @($roPayload.tools | ForEach-Object { $_.function.name })
        Assert-True ($roToolNames.Count -eq 10 -and ($roToolNames -contains 'memory') -and ($roToolNames -contains 'ask_user') -and ($roToolNames -contains 'todo') -and ($roToolNames -notcontains 'write_file') -and ($roToolNames -contains 'fetch_url') -and ($roToolNames -contains 'web_search') -and ($roToolNames -contains 'run_agent') -and $roPayload.messages[0].content.Contains('Permission mode: ReadOnly.')) 'ReadOnly turn payload was out of sync with active permission.'

        # 3. Switch to Ask: write_file is restored, transition notice replaces ReadOnly notice, and real write with WRITE confirmation succeeds.
        $script:AgentPermission = 'Ask'
        Sync-AgentCapabilities -State $modeSwitchState -RecordTransition | Out-Null
        $modeSwitchState.messages += @{ role = 'user'; content = 'Now update mode-test.txt in Ask mode' }
        Invoke-AgentTurn -State $modeSwitchState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        $askPayload = $script:capturedPayloads[3]
        $askToolNames = @($askPayload.tools | ForEach-Object { $_.function.name })
        $capNoticesInAsk = @($askPayload.messages | Where-Object { $_.role -eq 'user' -and ([string]$_.content).StartsWith('[Capability State Change]') })
        Assert-True (($askToolNames -contains 'write_file') -and $askPayload.messages[0].content.Contains('Permission mode: Ask.') -and $capNoticesInAsk.Count -eq 1 -and $capNoticesInAsk[0].content.Contains('Permission mode is now Ask.')) 'Ask turn payload did not synchronize tools, system prompt, or single transition notice.'
        Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'mode-test.txt') -Raw -Encoding UTF8) -eq 'v2-ask-confirmed') 'Ask mode turn did not perform real confirmed write.'
    }
    finally {
        $script:Diagnostics = $false
        $script:AgentPermission = 'Ask'
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    }

    # Repetition / loop detector:
    # (a) Read -> Edit -> Read is allowed because edit mutates workspace state.
    $script:AgentPermission = 'AutoEdit'
    Set-Content -LiteralPath (Join-Path $workspacePath 'loop-check.txt') -Value 'before' -Encoding UTF8 -NoNewline
    $script:rerStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:rerStep++
        if ($script:rerStep -eq 1) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'r1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"loop-check.txt"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:rerStep -eq 2) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'e1'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"loop-check.txt","old_text":"before","new_text":"after"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:rerStep -eq 3) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'r2'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"loop-check.txt"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $resp = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Read-Edit-Read completed.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    $rerState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'edit and verify' }) }
    Invoke-AgentTurn -State $rerState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 6 -MaxRepeatCalls 2
    Assert-True ((-not $rerState.loop_detected) -and $rerState.messages[-1].content -eq 'Read-Edit-Read completed.') 'Read after edit was falsely flagged as a loop.'

    # (b) Repeated identical calls without state change warn first, then stop turn cleanly while preserving earlier edits.
    $script:loopStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:loopStep++
        if ($script:loopStep -eq 1) {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'lw-1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"preserved-edit.txt","content":"keep-me","overwrite":true}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $resp = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = "lr-$($script:loopStep)"; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"loop-check.txt"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    $loopState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'loop test' }) }
    Invoke-AgentTurn -State $loopState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 10
    Assert-True ([bool]$loopState.loop_detected -and $loopState.repeated_tool -eq 'read_file') 'Repetition detector did not stop identical tool loop.'
    Assert-True ($script:loopStep -eq 5) "Expected loop to stop on 4th identical read_file call (step 5 total with default MaxRepeatCalls=3), got $($script:loopStep)."
    $toolOutputs = @($loopState.messages | Where-Object { $_.role -eq 'tool' } | ForEach-Object { $_.content | ConvertFrom-Json })
    Assert-True ($toolOutputs[3].status -eq 'repeated_call_warning' -and $toolOutputs[4].status -eq 'loop_detected') 'Expected repeated_call_warning on 3rd identical call followed by loop_detected on 4th.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $workspacePath 'preserved-edit.txt')) -and ((Get-Content -LiteralPath (Join-Path $workspacePath 'preserved-edit.txt') -Raw -Encoding UTF8) -eq 'keep-me')) 'Earlier completed write in turn was lost when loop stopped.'
    Assert-True (Test-ValidConversationBoundary -Messages $loopState.messages) 'Conversation boundary invalid after loop stop.'
    $script:AgentPermission = 'Ask'

    # Installer: first install, reinstall, shortcuts, conflict detection (alias, function, executable),
    # profile preservation & backup, and paths with spaces + argument forwarding.
    $profileFile = Join-Path $testRoot 'profile.ps1'
    $existingProfile = "# keep my settings`r`n# footer line"
    Set-Content -LiteralPath $profileFile -Value $existingProfile -Encoding UTF8 -NoNewline

    # 1. Install into an existing profile with -Shortcut sss and verify backup & profile preservation.
    & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $profileFile -Shortcut 'sss'
    $profileText = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8
    Assert-True ($profileText.Contains('# keep my settings') -and $profileText.Contains('# footer line')) 'Profile user contents were lost during install.'
    Assert-True (((@($profileText -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1) -and $profileText.Contains('function global:shellossus') -and $profileText.Contains('function global:sss')) 'Expected shellossus and sss functions in installed block.'
    $backups = @(Get-ChildItem -LiteralPath $testRoot -Filter 'profile.ps1.shellossus-backup-*' -File)
    Assert-True ($backups.Count -ge 1) 'Installer did not create a profile backup before modifying existing profile.'

    # 2. Invalid shortcut syntax rejection (spaces, special chars, leading digit) and mutually exclusive flags.
    foreach ($badName in @('bad space', 'bad$char', '1startdigit', 'a;b', '')) {
        $badThrew = $false
        try {
            & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $profileFile -Shortcut $badName
        }
        catch {
            if ($_.Exception.Message -like '*Invalid shortcut name*') { $badThrew = $true }
        }
        Assert-True $badThrew "Installer accepted invalid shortcut syntax: '$badName'."
    }
    $bothFlagsThrew = $false
    try {
        & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $profileFile -Shortcut 's' -NoShortcut
    }
    catch {
        if ($_.Exception.Message -like '*Cannot specify both*') { $bothFlagsThrew = $true }
    }
    Assert-True $bothFlagsThrew 'Installer allowed both -Shortcut and -NoShortcut.'

    # 3. Conflict detection with existing Alias, Function, and Executable (via Get-Command -All).
    Set-Alias -Name 'sc_conflict_alias' -Value Get-ChildItem -Scope Global
    function global:sc_conflict_func { Write-Output 'user custom function' }
    $binDir = Join-Path $testRoot 'bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    $exeScript = Join-Path $binDir 'sc_conflict_exe.cmd'
    Set-Content -LiteralPath $exeScript -Value '@echo off' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $binDir 'sc_conflict_exe.ps1') -Value 'Write-Output "ext"' -Encoding Ascii
    $savedPath = $env:PATH
    $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
    try {
        foreach ($conflictName in @('sc_conflict_alias', 'sc_conflict_func', 'sc_conflict_exe')) {
            $confThrew = $false
            try {
                & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $profileFile -Shortcut $conflictName
            }
            catch {
                if ($_.Exception.Message -like "*conflicts with existing*") { $confThrew = $true }
            }
            Assert-True $confThrew "Installer did not reject conflicting command '$conflictName'."
        }

        # 4. Own previously installed shortcut function is recognized and NOT treated as a conflict on rerun.
        . $profileFile
        & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $profileFile -Shortcut 'sss'
        $profileTextAfterRerun = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8
        Assert-True (((@($profileTextAfterRerun -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1) -and $profileTextAfterRerun.Contains('function global:sss')) 'Rerun with own existing shortcut failed or duplicated block.'

        # 5. Interactive flows: first install menu (conflict retry -> custom name) and reinstall menu (keep -> change -> remove).
        $interactiveProfile = Join-Path $testRoot 'interactive-profile.ps1'
        $global:readQueue = @('1', '4', 'bad name!', '4', 'shos_custom')
        Set-Alias -Name 's' -Value Get-Location -Scope Global
        function global:Read-Host {
            param($Prompt)
            if (-not $global:readQueue -or $global:readQueue.Count -eq 0) { return '5' }
            $next = $global:readQueue[0]
            if ($global:readQueue.Count -eq 1) { $global:readQueue = @() }
            else { $global:readQueue = @($global:readQueue[1..($global:readQueue.Count - 1)]) }
            return $next
        }
        try {
            # First install: '1' ('s') conflicts with alias 's', then '4' ('bad name!') fails syntax, then '4' ('shos_custom') succeeds.
            & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $interactiveProfile
            $intText1 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText1.Contains('function global:shos_custom')) 'Interactive first install with conflict retry and custom shortcut failed.'

            # Reinstall 1: '1' (Keep 'shos_custom').
            $global:readQueue = @('1')
            & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $interactiveProfile
            $intText2 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText2.Contains('function global:shos_custom') -and ((@($intText2 -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1)) 'Interactive reinstall keep shortcut failed.'

            # Reinstall 2: '2' (Change shortcut) -> '3' ('shos').
            $global:readQueue = @('2', '3')
            & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $interactiveProfile
            $intText3 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText3.Contains('function global:shos') -and (-not $intText3.Contains('function global:shos_custom'))) 'Interactive reinstall change shortcut failed.'

            # Reinstall 3: '3' (Remove shortcut).
            $global:readQueue = @('3')
            & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $interactiveProfile
            $intText4 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText4.Contains('function global:shellossus') -and (-not $intText4.Contains('function global:shos'))) 'Interactive reinstall remove shortcut failed.'
        }
        finally {
            Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
            Remove-Variable -Name readQueue -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Alias:\s -Force -ErrorAction SilentlyContinue
        }

        # 6. Paths with spaces and full @args forwarding through registered functions.
        $spacedDir = Join-Path $testRoot 'Folder With Spaces'
        New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
        $spacedAgent = Join-Path $spacedDir 'shellossus.ps1'
        Set-Content -LiteralPath $spacedAgent -Value 'param([string]$Workspace, [string]$Prompt, [int]$MaxSteps) (@{ ws = $Workspace; prompt = $Prompt; steps = $MaxSteps } | ConvertTo-Json -Compress)' -Encoding Ascii
        $spacedProfile = Join-Path $spacedDir 'spaced profile.ps1'
        Invoke-AgentProfileInstall -AgentPath $spacedAgent -ProfilePath $spacedProfile -Shortcut 'shos_spaced'
        . $spacedProfile
        $forwardedRaw = shos_spaced -Workspace 'C:\Project With Spaces' -Prompt 'hello world' -MaxSteps 7
        $forwardedObj = $forwardedRaw | ConvertFrom-Json
        Assert-True ($forwardedObj.ws -eq 'C:\Project With Spaces' -and $forwardedObj.prompt -eq 'hello world' -and $forwardedObj.steps -eq 7) 'Shortcut function failed to forward arguments or path with spaces.'
    }
    finally {
        $env:PATH = $savedPath
        Remove-Item Alias:\sc_conflict_alias -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:sc_conflict_func -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:sss -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:shellossus -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:shos_spaced -Force -ErrorAction SilentlyContinue
    }

    # Subagent context=fork boundary safety and mutationEpoch advancement on subagent file modification.
    $script:AgentPermission = 'AutoEdit'
    Set-Content -LiteralPath (Join-Path $workspacePath 'fork-edit.txt') -Value 'v1' -Encoding UTF8 -NoNewline
    $script:forkTurnStep = 0
    $script:forkedSawPriorHistory = $false
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:forkTurnStep++
        $pObj = $Body | ConvertFrom-Json
        if ($script:forkTurnStep -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'fk-r1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"fork-edit.txt"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:forkTurnStep -eq 2) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'fk-sub'; type = 'function'; function = @{ name = 'run_agent'; arguments = '{"role":"craft","context":"fork","prompt":"Edit fork-edit.txt based on prior history"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:forkTurnStep -eq 3) {
            $allTxt = ($pObj.messages | ForEach-Object { [string]$_.content }) -join "`n"
            if ($allTxt.Contains('PRIOR_SECRET_CONTEXT')) { $script:forkedSawPriorHistory = $true }
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'fk-e1'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"fork-edit.txt","old_text":"v1","new_text":"v2"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:forkTurnStep -eq 4) {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Subagent updated fork-edit.txt to v2.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:forkTurnStep -eq 5) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'fk-r2'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"fork-edit.txt"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Verified v2 after subagent edit.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    $forkParentState = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Remember PRIOR_SECRET_CONTEXT' },
            @{ role = 'assistant'; content = 'Noted.' },
            @{ role = 'user'; content = 'Read, delegate edit, and re-read fork-edit.txt' }
        )
    }
    Invoke-AgentTurn -State $forkParentState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 6 -MaxRepeatCalls 2
    Assert-True ($script:forkedSawPriorHistory -and (-not $forkParentState.loop_detected) -and $forkParentState.messages[-1].content -eq 'Verified v2 after subagent edit.') 'run_agent context=fork or mutationEpoch advancement after subagent edit failed.'
    $script:AgentPermission = 'Ask'

    # TUI REPL command alias resolution, status dashboard card, and tree card rendering.
    Assert-True ((Resolve-ReplCommandAlias -InputText '?') -eq '/help') 'Alias ? -> /help failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/p AutoEdit') -eq '/permission AutoEdit') 'Alias /p AutoEdit -> /permission AutoEdit failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/m glm-5') -eq '/model glm-5') 'Alias /m -> /model failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/u') -eq '/undo') 'Alias /u -> /undo failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/t e0002') -eq '/tree e0002') 'Alias /t -> /tree failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/ctx 128k 80k') -eq '/context 128k 80k') 'Alias /ctx -> /context failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/mem') -eq '/memory') 'Alias /mem -> /memory failed.'
    Assert-True ((Resolve-ReplCommandAlias -InputText '/mem add invariant') -eq '/memory add invariant') 'Alias /mem add -> /memory add failed.'

    Ensure-SessionTree -State $forkParentState
    $statusCard = @(Format-TuiStatusCard -State $forkParentState -Model 'test-model' -MaxSteps 50 -SessionFile 'test.jsonl' -UndoCount 1)
    $plainStatus = ($statusCard | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainStatus.Contains('test-model') -and $plainStatus.Contains('Ask') -and $plainStatus.Contains('128.0k') -and $plainStatus.Contains('96.0k') -and $plainStatus.Contains('test.jsonl')) "Format-TuiStatusCard output unexpected: $plainStatus"

    $treeCard = @(Format-TuiTreeCard -State $forkParentState)
    $plainTree = ($treeCard | ForEach-Object { Strip-AnsiCodes -Text $_ }) -join "`n"
    Assert-True ($plainTree.Contains('e0001') -and $plainTree.Contains('(root)')) "Format-TuiTreeCard output unexpected: $plainTree"

    # Non-ASCII JSON payload escaping (prevents Windows PowerShell 5.1 UTF-8 BOM / codepage 400 Bad Request).
    $cyrText = ([string][char]0x0447) + ([string][char]0x0442) + ([string][char]0x043E) + '?'
    $rawPayload = (@{ model = 'test-model'; messages = @(@{ role = 'user'; content = $cyrText }) } | ConvertTo-Json -Depth 10 -Compress)
    $asciiPayload = ConvertTo-AsciiJson -Json $rawPayload
    Assert-True ($asciiPayload -notmatch '[^\x00-\x7F]') "ConvertTo-AsciiJson left non-ASCII chars: $asciiPayload"
    Assert-True ($asciiPayload.Contains('\u0447\u0442\u043e?')) "ConvertTo-AsciiJson did not escape Cyrillic as expected: $asciiPayload"
    $parsedPayload = $asciiPayload | ConvertFrom-Json -ErrorAction Stop
    Assert-True ([string]$parsedPayload.messages[0].content -eq $cyrText) 'ConvertTo-AsciiJson round-trip failed.'

    # Regression: -Setup preserves saved SHELLOSSUS_WORKSPACE, SHELLOSSUS_CONTEXT_WINDOW, SHELLOSSUS_COMPACT_THRESHOLD, and SHELLOSSUS_THEME when Enter is pressed.
    $setupCfgFile = Join-Path $testRoot 'setup-preserve.env'
    Save-AgentConfig -Path $setupCfgFile -Config @{
        SHELLOSSUS_BASE_URL = 'https://saved.invalid/v1'
        SHELLOSSUS_MODEL = 'saved-model'
        SHELLOSSUS_API_KEY = 'saved-key'
        SHELLOSSUS_WORKSPACE = 'C:\SavedWorkspace'
        SHELLOSSUS_CONTEXT_WINDOW = '64k'
        SHELLOSSUS_COMPACT_THRESHOLD = '48k'
        SHELLOSSUS_THEME = 'dracula'
    }
    $global:setupReadQueue = @('', 'updated-model', '', '')
    function global:Read-Host {
        param($Prompt)
        if (-not $global:setupReadQueue -or $global:setupReadQueue.Count -eq 0) { return '' }
        $next = $global:setupReadQueue[0]
        if ($global:setupReadQueue.Count -eq 1) { $global:setupReadQueue = @() }
        else { $global:setupReadQueue = @($global:setupReadQueue[1..($global:setupReadQueue.Count - 1)]) }
        return $next
    }
    try {
        & "$PSScriptRoot\..\shellossus.ps1" -Setup -ConfigPath $setupCfgFile
        $afterSetupCfg = Read-AgentConfig -Path $setupCfgFile
        Assert-True ($afterSetupCfg.SHELLOSSUS_BASE_URL -eq 'https://saved.invalid/v1' -and $afterSetupCfg.SHELLOSSUS_MODEL -eq 'updated-model' -and $afterSetupCfg.SHELLOSSUS_API_KEY -eq 'saved-key' -and $afterSetupCfg.SHELLOSSUS_WORKSPACE -eq 'C:\SavedWorkspace' -and $afterSetupCfg.SHELLOSSUS_CONTEXT_WINDOW -eq '64k' -and $afterSetupCfg.SHELLOSSUS_COMPACT_THRESHOLD -eq '48k' -and $afterSetupCfg.SHELLOSSUS_THEME -eq 'dracula') '-Setup failed to preserve existing workspace or optional settings on Enter.'
    }
    finally {
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Variable -Name setupReadQueue -Scope Global -ErrorAction SilentlyContinue
        $null = Set-AgentTheme -Name 'gruvbox-material'
    }

    # Regression: memory tool mutations advance $mutationEpoch and update $State.messages[0].content during Invoke-AgentTurn.
    $script:memTurnStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:memTurnStep++
        if ($script:memTurnStep -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'mv-1'; type = 'function'; function = @{ name = 'memory'; arguments = '{"action":"view"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:memTurnStep -eq 2) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'ma-1'; type = 'function'; function = @{ name = 'memory'; arguments = '{"action":"append","content":"Turn memory rule"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:memTurnStep -eq 3) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'mv-2'; type = 'function'; function = @{ name = 'memory'; arguments = '{"action":"view"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Memory turn ok.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    $memTurnState = @{
        workspace = $workspacePath
        messages = @(
            @{ role = 'system'; content = (Build-SystemPrompt -Root $workspacePath -ConfigDir '') },
            @{ role = 'user'; content = 'View, append, and view memory' }
        )
    }
    $prevPermMemTurn = $script:AgentPermission
    $script:AgentPermission = 'AutoEdit'
    try {
        Invoke-AgentTurn -State $memTurnState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 6 -MaxRepeatCalls 2
    }
    finally {
        $script:AgentPermission = $prevPermMemTurn
    }
    Assert-True ((-not $memTurnState.loop_detected) -and $memTurnState.messages[-1].content -eq 'Memory turn ok.' -and $memTurnState.messages[0].content.Contains('Turn memory rule')) 'Invoke-AgentTurn did not advance mutationEpoch or update system prompt after memory append.'

    # Regression (Item 7d): After context compaction removes old role='tool' messages from $State.messages,
    # Invoke-AgentTurn must remember that scoped AGENTS.md instructions were already delivered and not re-block with instructions_required.
    $scopedCompDir = Join-Path $workspacePath 'scoped-compact/sub'
    New-Item -ItemType Directory -Path $scopedCompDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workspacePath 'scoped-compact/AGENTS.md') -Value 'Scoped compact parent rule.' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $scopedCompDir 'data.txt') -Value 'initial-data' -Encoding UTF8
    $script:scTurnStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $payload = $Body | ConvertFrom-Json
        if ($payload.messages[0].content -like '*context compaction assistant*') {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = "## Goal`nCompacted scoped history" } }) } | ConvertTo-Json -Depth 10 -Compress
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
            return
        }
        $script:scTurnStep++
        if ($script:scTurnStep -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'sc-r1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"scoped-compact/sub/data.txt"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:scTurnStep -eq 2) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'sc-r2'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"scoped-compact/sub/data.txt"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:scTurnStep -eq 3) {
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'First scoped read done.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:scTurnStep -eq 4) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'sc-w1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"scoped-compact/sub/after-compact.txt","content":"ok-after-compact"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $lastToolRes = $payload.messages[-1].content | ConvertFrom-Json
            Assert-True ($lastToolRes.status -eq 'written') "Expected status=written after compaction without re-triggering instructions_required, got: $($payload.messages[-1].content)"
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Post-compact write succeeded immediately.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    $script:AgentPermission = 'AutoEdit'
    $scState = @{
        workspace = $workspacePath
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Read scoped file' }
        )
    }
    Invoke-AgentTurn -State $scState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 5
    $scState.messages += @(
        @{ role = 'user'; content = 'Filler turn' },
        @{ role = 'assistant'; content = 'Filler reply' }
    )
    $didScCompact = Invoke-AgentCompact -State $scState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -KeepRecent 2
    Assert-True ($didScCompact -and (@($scState.messages | Where-Object { $_.role -eq 'tool' }).Count -eq 0)) 'Compaction did not remove old tool messages from $State.messages.'
    $scState.messages += @{ role = 'user'; content = 'Now write in same scoped dir after compaction' }
    Invoke-AgentTurn -State $scState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
    Assert-True ((Test-Path -LiteralPath (Join-Path $scopedCompDir 'after-compact.txt')) -and $scState.messages[-1].content -eq 'Post-compact write succeeded immediately.') 'Scoped AGENTS.md check re-blocked file tool call after compaction.'
    $script:AgentPermission = 'Ask'
    Remove-Item -LiteralPath (Join-Path $workspacePath 'scoped-compact') -Recurse -Force

    # Regression: Scoped AGENTS.md interception (status='instructions_required') does not consume the loop-guard repetition budget.
    $scopedRepDir = Join-Path $workspacePath 'scoped-repeat/nested'
    New-Item -ItemType Directory -Path $scopedRepDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $workspacePath 'scoped-repeat/AGENTS.md') -Value 'Scoped repeat rule.' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $scopedRepDir 'input.txt') -Value 'scoped-input-content' -Encoding UTF8
    $script:srStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:srStep++
        $payload = $Body | ConvertFrom-Json
        if ($script:srStep -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'sr-r1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"scoped-repeat/nested/input.txt"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:srStep -eq 2) {
            $firstToolRes = $payload.messages[-1].content | ConvertFrom-Json
            Assert-True ($firstToolRes.status -eq 'instructions_required') "Expected first scoped read_file to return instructions_required, got: $($payload.messages[-1].content)"
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = @(@{ id = 'sr-r2'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"scoped-repeat/nested/input.txt"}' } }) } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $secondToolRes = $payload.messages[-1].content | ConvertFrom-Json
            Assert-True ($secondToolRes.status -ne 'repeated_call_warning' -and ([string]$secondToolRes.text).Contains('scoped-input-content')) "Expected immediate retry after instructions_required to succeed with MaxRepeatCalls=2, got: $($payload.messages[-1].content)"
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Scoped retry read succeeded.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    $srState = @{
        workspace = $workspacePath
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Read scoped file with MaxRepeatCalls=2' }
        )
    }
    Invoke-AgentTurn -State $srState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4 -MaxRepeatCalls 2
    Assert-True ($script:srStep -eq 3 -and (-not $srState.loop_detected) -and $srState.messages[-1].content -eq 'Scoped retry read succeeded.') 'Scoped instructions_required interception falsely triggered loop-guard penalty on immediate retry.'
    Remove-Item -LiteralPath (Join-Path $workspacePath 'scoped-repeat') -Recurse -Force

    # Regression (Item 11): REPL /memory command (Invoke-ReplMemoryCommand) supports workspace & global scopes and view/add/set/clear/all actions.
    $replMemCfgDir = Join-Path $testRoot 'repl-mem-global'
    New-Item -ItemType Directory -Path $replMemCfgDir -Force | Out-Null
    $replMemState = @{
        workspace = $workspacePath
        messages = @(
            @{ role = 'system'; content = (Build-SystemPrompt -Root $workspacePath -ConfigDir $replMemCfgDir) },
            @{ role = 'user'; content = 'hello' }
        )
    }
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'global add Global pref 1'
    $globalMemFile = Join-Path $replMemCfgDir 'MEMORY.md'
    Assert-True ((Test-Path -LiteralPath $globalMemFile) -and (Get-Content -LiteralPath $globalMemFile -Raw).Contains('Global pref 1') -and $replMemState.messages[0].content.Contains('Global pref 1')) 'Invoke-ReplMemoryCommand global add failed.'
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'global set # Global Replaced'
    Assert-True ((Get-Content -LiteralPath $globalMemFile -Raw).Contains('# Global Replaced') -and (-not (Get-Content -LiteralPath $globalMemFile -Raw).Contains('Global pref 1')) -and $replMemState.messages[0].content.Contains('# Global Replaced')) 'Invoke-ReplMemoryCommand global set failed.'
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'set # Workspace Replaced'
    $wsMemFile = Join-Path $workspacePath '.shellossus/MEMORY.md'
    Assert-True ((Test-Path -LiteralPath $wsMemFile) -and (Get-Content -LiteralPath $wsMemFile -Raw).Contains('# Workspace Replaced') -and $replMemState.messages[0].content.Contains('# Workspace Replaced')) 'Invoke-ReplMemoryCommand workspace set failed.'
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'global view'
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'all'
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'global clear'
    Assert-True ((-not (Test-Path -LiteralPath $globalMemFile)) -and (-not $replMemState.messages[0].content.Contains('# Global Replaced')) -and $replMemState.messages[0].content.Contains('# Workspace Replaced')) 'Invoke-ReplMemoryCommand global clear failed.'
    Invoke-ReplMemoryCommand -State $replMemState -RootPath $workspacePath -ConfigDir $replMemCfgDir -MemArg 'clear'
    Assert-True (-not (Test-Path -LiteralPath $wsMemFile)) 'Invoke-ReplMemoryCommand workspace clear failed.'

    # Regression (Task 6): Copy-SessionHashtableArray produces independent hashtable copies, and single-shot -Prompt rolls back writes and emits turn_end status='error' on failure.
    $copyTestState = @{
        messages = @(
            @{ role = 'system'; content = 'original-sys' },
            @{ role = 'user'; content = 'original-user' }
        )
        tree_entries = @(
            @{ id = 'e0001'; parent_id = $null; role = 'user'; content = 'original-user' }
        )
    }
    $beforeTurnSnap = @(Copy-SessionHashtableArray -Items $copyTestState.messages)
    $beforeTreeSnap = @(Copy-SessionHashtableArray -Items $copyTestState.tree_entries)
    $copyTestState.messages[0].content = 'mutated-sys'
    $copyTestState.tree_entries[0].content = 'mutated-user'
    Assert-True ($beforeTurnSnap.Count -eq 2 -and ($beforeTurnSnap[0] -is [hashtable]) -and $beforeTurnSnap[0].content -eq 'original-sys' -and $beforeTreeSnap.Count -eq 1 -and ($beforeTreeSnap[0] -is [hashtable]) -and $beforeTreeSnap[0].content -eq 'original-user') 'Copy-SessionHashtableArray did not deep-copy session hashtables.'

    $singleShotRollbackFile = Join-Path $workspacePath 'single-shot-rollback.txt'
    $global:ssStep = 0
    $global:ssSawFile = $false
    $global:ssJsonLines = @()
    $global:ssTargetFile = $singleShotRollbackFile
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $global:ssStep++
        if ($global:ssStep -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'ss-w1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"single-shot-rollback.txt","content":"temp-data"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
            return
        }
        if (Test-Path -LiteralPath $global:ssTargetFile) { $global:ssSawFile = $true }
        throw 'HTTP 500 Internal Server Error'
    }
    function Start-Sleep {
        param($Seconds, $Milliseconds)
    }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        if ($text.Trim()) { $global:ssJsonLines += $text }
    }
    $ssThrew = $false
    try {
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Prompt 'Write file then fail' -Permission AutoEdit -Mode json -NoSession -ConfigPath $setupCfgFile
    }
    catch {
        if ($_.Exception.Message -like '*500*') { $ssThrew = $true }
    }
    finally {
        Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
    }
    try {
        Assert-True ($ssThrew -and $global:ssSawFile) "Single-shot -Prompt test did not execute step 1 write followed by step 2 HTTP 500 failure (step=$($global:ssStep), sawFile=$($global:ssSawFile), threw=$ssThrew)."
        Assert-True (-not (Test-Path -LiteralPath $singleShotRollbackFile)) 'Single-shot -Prompt failure did not roll back file created during turn.'
        Assert-True ($global:ssJsonLines.Count -ge 2) 'Single-shot -Prompt in JSON mode did not emit JSON events.'
        $lastSsEv = $global:ssJsonLines[-1] | ConvertFrom-Json -ErrorAction Stop
        Assert-True ($lastSsEv.type -eq 'turn_end' -and $lastSsEv.status -eq 'error' -and $lastSsEv.error -like '*500*') "Single-shot -Prompt failure did not emit turn_end status='error' event: $($global:ssJsonLines[-1])"
    }
    finally {
        Remove-Variable -Name ssStep, ssSawFile, ssJsonLines, ssTargetFile -Scope Global -ErrorAction SilentlyContinue
    }

    # Regression: REPL !cmd shortcut interpolates the actual command string into conversation context (not literal $cmdStr).
    $bangSessDir = Join-Path $testRoot 'bang-sessions'
    New-Item -ItemType Directory -Path $bangSessDir -Force | Out-Null
    $bangSessFile = Join-Path $bangSessDir 'bang-test.jsonl'
    $global:bangReadQueue = @('!Write-Output "bang-check-42"', '/exit')
    function global:Read-Host {
        param($Prompt)
        if (-not $global:bangReadQueue -or $global:bangReadQueue.Count -eq 0) { return '/exit' }
        $next = $global:bangReadQueue[0]
        if ($global:bangReadQueue.Count -eq 1) { $global:bangReadQueue = @() }
        else { $global:bangReadQueue = @($global:bangReadQueue[1..($global:bangReadQueue.Count - 1)]) }
        return $next
    }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
    }
    try {
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Session $bangSessFile -SessionDir $bangSessDir -ConfigPath $setupCfgFile
    }
    finally {
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Variable -Name bangReadQueue -Scope Global -ErrorAction SilentlyContinue
    }
    Assert-True (Test-Path -LiteralPath $bangSessFile) 'REPL !cmd session file was not saved.'
    $bangLoadedState = @{ session_id = ''; workspace = $workspacePath; model = 'test-model'; messages = @() }
    Invoke-SessionResume -SessionFile $bangSessFile -State $bangLoadedState -CurrentWorkspace $workspacePath | Out-Null
    $bangUserMsgs = @($bangLoadedState.messages | Where-Object { $_.role -eq 'user' })
    Assert-True ($bangUserMsgs.Count -eq 1) "Expected 1 user message from !cmd in session history, got $($bangUserMsgs.Count)."
    $bangContent = [string]$bangUserMsgs[0].content
    Assert-True ($bangContent.Contains('[Shell command Write-Output "bang-check-42" exit=0]') -and (-not $bangContent.Contains('$cmdStr')) -and $bangContent.Contains('bang-check-42')) "REPL !cmd message did not interpolate command string properly: $bangContent"

    # Regression (Task 2): CLI -Export works offline without BaseUrl/Model/ApiKey for -Session, -Continue, and shorthand .jsonl -> .html,
    # supports both .html and .jsonl targets, does not hijack existing output .jsonl when -Session/-Continue is passed, and enforces -CurrentWorkspace.
    $expSessDir = Join-Path $testRoot 'export-sessions'
    New-Item -ItemType Directory -Path $expSessDir -Force | Out-Null
    $expSavedJsonl = Join-Path $expSessDir 'sess-export-source.jsonl'
    $expSourceState = @{
        session_id = 'sess-export-source'
        session_name = 'Offline Export Test'
        workspace = $workspacePath
        model = 'offline-saved-model'
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Export question 101' },
            @{ role = 'assistant'; content = 'Export answer 202' }
        )
    }
    Save-AgentSession -SessionFile $expSavedJsonl -State $expSourceState -Workspace $workspacePath -Model 'offline-saved-model' -SessionId 'sess-export-source'
    $emptyCfgFile = Join-Path $testRoot 'empty-export.env'
    Set-Content -LiteralPath $emptyCfgFile -Value '' -Encoding Ascii -NoNewline

    $savedExpEnv = @{
        SHELLOSSUS_BASE_URL = $env:SHELLOSSUS_BASE_URL
        SHELLOSSUS_MODEL = $env:SHELLOSSUS_MODEL
        SHELLOSSUS_API_KEY = $env:SHELLOSSUS_API_KEY
    }
    $env:SHELLOSSUS_BASE_URL = $null
    $env:SHELLOSSUS_MODEL = $null
    $env:SHELLOSSUS_API_KEY = $null
    function global:Read-Host {
        param($Prompt)
        throw "Unexpected Read-Host prompt during offline -Export: $Prompt"
    }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
    }
    try {
        # 1. -Session <saved.jsonl> -Export <out.html> without BaseUrl/Model/ApiKey produces valid HTML.
        $outSessHtml = Join-Path $testRoot 'exported-from-session.html'
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -Session $expSavedJsonl -Export $outSessHtml -ConfigPath $emptyCfgFile
        Assert-True (Test-Path -LiteralPath $outSessHtml) '-Session -Export <out.html> did not create HTML file.'
        $outSessHtmlText = Get-Content -LiteralPath $outSessHtml -Raw -Encoding UTF8
        Assert-True ($outSessHtmlText.Contains('<!DOCTYPE html>') -and $outSessHtmlText.Contains('Export question 101') -and $outSessHtmlText.Contains('Export answer 202') -and $outSessHtmlText.Contains('offline-saved-model')) "-Session -Export <out.html> content invalid: $outSessHtmlText"

        # 2. -Continue -Export <out.jsonl> without BaseUrl/Model/ApiKey produces valid JSONL (not HTML), even if <out.jsonl> already exists.
        $outContJsonl = Join-Path $testRoot 'exported-from-continue.jsonl'
        Set-Content -LiteralPath $outContJsonl -Value 'stale-placeholder' -Encoding Ascii
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -Continue -SessionDir $expSessDir -Export $outContJsonl -ConfigPath $emptyCfgFile
        Assert-True (Test-Path -LiteralPath $outContJsonl) '-Continue -Export <out.jsonl> did not write JSONL file.'
        $outContLines = @(Get-Content -LiteralPath $outContJsonl -Encoding UTF8 | Where-Object { $_.Trim() })
        Assert-True ($outContLines.Count -ge 3) "Expected at least 3 JSONL lines in exported session, got $($outContLines.Count)."
        $firstMeta = $outContLines[0] | ConvertFrom-Json -ErrorAction Stop
        $outContRaw = Get-Content -LiteralPath $outContJsonl -Raw -Encoding UTF8
        Assert-True ($firstMeta.type -eq 'session_meta' -and $firstMeta.model -eq 'offline-saved-model' -and (-not $outContRaw.Contains('<!DOCTYPE html>')) -and $outContRaw.Contains('Export answer 202')) "-Continue -Export <out.jsonl> did not produce valid JSONL export: $outContRaw"

        # 3. Shorthand -Export <existing.jsonl> converts to <existing.html> and enforces -CurrentWorkspace.
        $shorthandHtml = $expSavedJsonl -replace '\.jsonl$', '.html'
        if (Test-Path -LiteralPath $shorthandHtml) { Remove-Item -LiteralPath $shorthandHtml -Force }
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -Export $expSavedJsonl -ConfigPath $emptyCfgFile
        Assert-True (Test-Path -LiteralPath $shorthandHtml) 'Shorthand -Export <existing.jsonl> did not create <existing.html>.'
        $shorthandHtmlText = Get-Content -LiteralPath $shorthandHtml -Raw -Encoding UTF8
        Assert-True ($shorthandHtmlText.Contains('<!DOCTYPE html>') -and $shorthandHtmlText.Contains('Export answer 202')) 'Shorthand -Export <existing.jsonl> HTML content invalid.'

        $otherExportWs = Join-Path $testRoot 'other-export-ws'
        New-Item -ItemType Directory -Path $otherExportWs -Force | Out-Null
        $wrongWsThrew = $false
        try {
            & "$PSScriptRoot\..\shellossus.ps1" -Workspace $otherExportWs -Export $expSavedJsonl -ConfigPath $emptyCfgFile
        }
        catch {
            if ($_.Exception.Message -like '*different workspace*') { $wrongWsThrew = $true }
        }
        Assert-True $wrongWsThrew 'Shorthand -Export <existing.jsonl> did not enforce -CurrentWorkspace.'
    }
    finally {
        $env:SHELLOSSUS_BASE_URL = $savedExpEnv.SHELLOSSUS_BASE_URL
        $env:SHELLOSSUS_MODEL = $savedExpEnv.SHELLOSSUS_MODEL
        $env:SHELLOSSUS_API_KEY = $savedExpEnv.SHELLOSSUS_API_KEY
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
    }

    # Regression (Task 4): Single-shot -Prompt and REPL (/new and /exit) clean up .tmp undo backup files when /undo is not called.
    $bakTargetFile = Join-Path $workspacePath 'backup-cleanup-target.txt'
    Set-Content -LiteralPath $bakTargetFile -Value 'line-v0' -Encoding UTF8 -NoNewline
    $global:bakStep = 0
    $global:ssBackupPath = ''
    $global:ssBackupExistedDuringTurn = $false
    $global:replBackup1Path = ''
    $global:replBackup1ExistedDuringTurn1 = $false
    $global:replBackup1ExistedAfterNew = $true
    $global:replBackup2Path = ''
    $global:replBackup2ExistedDuringTurn2 = $false
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $global:bakStep++
        $payload = $Body | ConvertFrom-Json
        if ($global:bakStep -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'bk-ss-1'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"backup-cleanup-target.txt","old_text":"line-v0","new_text":"line-v1"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($global:bakStep -eq 2) {
            $toolRes = $payload.messages[-1].content | ConvertFrom-Json
            $global:ssBackupPath = [string]$toolRes.backup
            if ($global:ssBackupPath -and (Test-Path -LiteralPath $global:ssBackupPath)) {
                $global:ssBackupExistedDuringTurn = $true
            }
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Single-shot edit complete.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($global:bakStep -eq 3) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'bk-rp-1'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"backup-cleanup-target.txt","old_text":"line-v1","new_text":"line-v2"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($global:bakStep -eq 4) {
            $toolRes = $payload.messages[-1].content | ConvertFrom-Json
            $global:replBackup1Path = [string]$toolRes.backup
            if ($global:replBackup1Path -and (Test-Path -LiteralPath $global:replBackup1Path)) {
                $global:replBackup1ExistedDuringTurn1 = $true
            }
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'REPL turn 1 edit complete.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($global:bakStep -eq 5) {
            $global:replBackup1ExistedAfterNew = [bool]($global:replBackup1Path -and (Test-Path -LiteralPath $global:replBackup1Path))
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'bk-rp-2'; type = 'function'; function = @{ name = 'edit_file'; arguments = '{"path":"backup-cleanup-target.txt","old_text":"line-v2","new_text":"line-v3"}' } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $toolRes = $payload.messages[-1].content | ConvertFrom-Json
            $global:replBackup2Path = [string]$toolRes.backup
            if ($global:replBackup2Path -and (Test-Path -LiteralPath $global:replBackup2Path)) {
                $global:replBackup2ExistedDuringTurn2 = $true
            }
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'REPL turn 2 edit complete.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
    }
    try {
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Prompt 'Edit file in single-shot mode' -Permission AutoEdit -NoSession -ConfigPath $setupCfgFile
        Assert-True ([bool]$global:ssBackupPath -and $global:ssBackupExistedDuringTurn) 'Single-shot edit_file did not create a backup temp file during the turn.'
        Assert-True (-not (Test-Path -LiteralPath $global:ssBackupPath)) "Single-shot -Prompt leaked undo backup file after exit: $($global:ssBackupPath)"

        $global:replBakQueue = @('Edit in turn 1', '/new', 'Edit in turn 2 after /new', '/exit')
        function global:Read-Host {
            param($Prompt)
            if (-not $global:replBakQueue -or $global:replBakQueue.Count -eq 0) { return '/exit' }
            $next = $global:replBakQueue[0]
            if ($global:replBakQueue.Count -eq 1) { $global:replBakQueue = @() }
            else { $global:replBakQueue = @($global:replBakQueue[1..($global:replBakQueue.Count - 1)]) }
            return $next
        }
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Permission AutoEdit -NoSession -ConfigPath $setupCfgFile
        Assert-True ([bool]$global:replBackup1Path -and $global:replBackup1ExistedDuringTurn1) 'REPL turn 1 edit_file did not create a backup temp file.'
        Assert-True (-not $global:replBackup1ExistedAfterNew) "REPL /new did not clean up turn 1 undo backup file: $($global:replBackup1Path)"
        Assert-True ([bool]$global:replBackup2Path -and $global:replBackup2ExistedDuringTurn2) 'REPL turn 2 edit_file did not create a backup temp file.'
        Assert-True (-not (Test-Path -LiteralPath $global:replBackup2Path)) "REPL /exit leaked turn 2 undo backup file: $($global:replBackup2Path)"
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        if ($global:ssBackupPath -and (Test-Path -LiteralPath $global:ssBackupPath)) { Remove-Item -LiteralPath $global:ssBackupPath -Force -ErrorAction SilentlyContinue }
        if ($global:replBackup1Path -and (Test-Path -LiteralPath $global:replBackup1Path)) { Remove-Item -LiteralPath $global:replBackup1Path -Force -ErrorAction SilentlyContinue }
        if ($global:replBackup2Path -and (Test-Path -LiteralPath $global:replBackup2Path)) { Remove-Item -LiteralPath $global:replBackup2Path -Force -ErrorAction SilentlyContinue }
        Remove-Variable -Name bakStep, ssBackupPath, ssBackupExistedDuringTurn, replBackup1Path, replBackup1ExistedDuringTurn1, replBackup1ExistedAfterNew, replBackup2Path, replBackup2ExistedDuringTurn2, replBakQueue -Scope Global -ErrorAction SilentlyContinue
    }

    # Regression (Task 5): In REPL with -NoSession, !cmd followed by a prompt turn and /undo preserves the !cmd message,
    # keeps tree_entries and leaf_id synchronized without duplicate or orphaned entries, and /tree reflects the active branch.
    $global:bangNoSessQueue = @('!Write-Output "tree-sync"', '/status', 'Prompt after bang', '/undo', '/tree', '/exit')
    $global:bangNoSessAfterBangLeaf = ''
    $global:bangNoSessAfterBangTreeCount = -1
    $global:bangNoSessFinalState = $null
    $global:bangNoSessHostLines = @()
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Assistant reply after bang.' } }) } | ConvertTo-Json -Depth 10 -Compress
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    function global:Read-Host {
        param($Prompt)
        if (-not $global:bangNoSessQueue -or $global:bangNoSessQueue.Count -eq 0) { return '/exit' }
        $next = $global:bangNoSessQueue[0]
        if ($global:bangNoSessQueue.Count -eq 1) { $global:bangNoSessQueue = @() }
        else { $global:bangNoSessQueue = @($global:bangNoSessQueue[1..($global:bangNoSessQueue.Count - 1)]) }
        if ($next -eq 'Prompt after bang' -and $state) {
            $global:bangNoSessAfterBangLeaf = [string]$state.leaf_id
            $global:bangNoSessAfterBangTreeCount = @($state.tree_entries).Count
        }
        elseif ($next -eq '/exit' -and $state) {
            $global:bangNoSessFinalState = $state
        }
        return $next
    }
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        if ($text) { $global:bangNoSessHostLines += (Strip-AnsiCodes -Text $text) }
    }
    try {
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -NoSession -ConfigPath $setupCfgFile
        Assert-True ($global:bangNoSessAfterBangLeaf -eq 'e0001' -and $global:bangNoSessAfterBangTreeCount -eq 1) "Expected !cmd under -NoSession to immediately sync tree_entries (1) and leaf_id (e0001), got count=$($global:bangNoSessAfterBangTreeCount), leaf='$($global:bangNoSessAfterBangLeaf)'."
        Assert-True ($null -ne $global:bangNoSessFinalState) 'Failed to capture final REPL state after /undo.'
        $finalNonSys = @($global:bangNoSessFinalState.messages | Where-Object { $_.role -ne 'system' })
        Assert-True ($finalNonSys.Count -eq 1 -and $finalNonSys[0].id -eq 'e0001' -and ([string]$finalNonSys[0].content).Contains('tree-sync')) 'After prompt turn and /undo, !cmd message was not preserved with id e0001 in $state.messages.'
        Assert-True ([string]$global:bangNoSessFinalState.leaf_id -eq 'e0001' -and @($global:bangNoSessFinalState.tree_entries).Count -eq 1 -and [string]$global:bangNoSessFinalState.tree_entries[0].id -eq 'e0001') "Expected 1 synchronized tree entry (e0001) and leaf_id='e0001' after /undo, got count=$(@($global:bangNoSessFinalState.tree_entries).Count), leaf_id='$($global:bangNoSessFinalState.leaf_id)'."
        $treeNodesAfterUndo = @(Get-SessionTree -State $global:bangNoSessFinalState)
        Assert-True ($treeNodesAfterUndo.Count -eq 1 -and $treeNodesAfterUndo[0].id -eq 'e0001' -and $treeNodesAfterUndo[0].active -and $treeNodesAfterUndo[0].is_leaf) '/tree state after /undo did not accurately reflect the single active !cmd branch leaf.'
        $joinedTreeHost = $global:bangNoSessHostLines -join "`n"
        Assert-True ($joinedTreeHost.Contains('[e0001] (user (root))') -and $joinedTreeHost.Contains('tree-sync') -and (-not $joinedTreeHost.Contains('Prompt after bang'))) "Rendered /tree output after /undo was not synchronized: $joinedTreeHost"
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Variable -Name bangNoSessQueue, bangNoSessAfterBangLeaf, bangNoSessAfterBangTreeCount, bangNoSessFinalState, bangNoSessHostLines -Scope Global -ErrorAction SilentlyContinue
    }

    # Regression (Task 7): Scoped AGENTS.md pre-check normalizes file_path aliases, delegates invalid/outside-workspace tool calls
    # to Invoke-AgentTool (rendering TUI error cards without wrapping as 'Cannot verify scoped AGENTS.md instructions'),
    # and still reports genuine instruction-file errors with a TUI error card.
    $t7ScopedDir = Join-Path $workspacePath 'scoped-t7/sub'
    New-Item -ItemType Directory -Path $t7ScopedDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $testRoot 'outside.txt') -Value 'outside-secret' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $workspacePath 'scoped-t7/AGENTS.md') -Value 'Scoped T7 rule.' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $t7ScopedDir 'existing.txt') -Value 't7-data' -Encoding UTF8
    $script:t7HostLines = @()
    $script:t7Step = 0
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        if ($text) { $script:t7HostLines += (Strip-AnsiCodes -Text $text) }
    }
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $script:t7Step++
        $payload = $Body | ConvertFrom-Json
        if ($script:t7Step -eq 1) {
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(
                    @{ id = 't7-out-r'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"../outside.txt"}' } },
                    @{ id = 't7-out-w'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"../outside-w.txt","content":"x"}' } },
                    @{ id = 't7-bad-json'; type = 'function'; function = @{ name = 'read_file'; arguments = '{bad' } },
                    @{ id = 't7-missing-arg'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"scoped-t7/sub/no-content.txt"}' } }
                )
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:t7Step -eq 2) {
            $resOutR = $payload.messages[-4].content | ConvertFrom-Json
            $resOutW = $payload.messages[-3].content | ConvertFrom-Json
            $resBadJ = $payload.messages[-2].content | ConvertFrom-Json
            $resMiss = $payload.messages[-1].content | ConvertFrom-Json
            Assert-True ($resOutR.error -eq 'Path is outside the workspace.' -and (-not ([string]$resOutR.error).Contains('Cannot verify scoped AGENTS.md'))) "Expected standard outside-workspace error for read_file, got: $($resOutR.error)"
            Assert-True ($resOutW.error -eq 'Path is outside the workspace.' -and (-not ([string]$resOutW.error).Contains('Cannot verify scoped AGENTS.md'))) "Expected standard outside-workspace error for write_file, got: $($resOutW.error)"
            Assert-True ([bool]$resBadJ.error -and (-not ([string]$resBadJ.error).Contains('Cannot verify scoped AGENTS.md'))) "Expected standard JSON parse error for read_file, got: $($resBadJ.error)"
            Assert-True ($resMiss.error -like "*Missing required argument 'content'*" -and (-not ([string]$resMiss.error).Contains('Cannot verify scoped AGENTS.md'))) "Expected standard missing-parameter error for write_file, got: $($resMiss.error)"
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(
                    @{ id = 't7-fp-r1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"file_path":"scoped-t7/sub/existing.txt"}' } },
                    @{ id = 't7-fp-w1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"file_path":"scoped-t7/sub/created.txt","content":"via-file-path"}' } }
                )
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        elseif ($script:t7Step -eq 3) {
            $resFpR1 = $payload.messages[-2].content | ConvertFrom-Json
            $resFpW1 = $payload.messages[-1].content | ConvertFrom-Json
            Assert-True ($resFpR1.status -eq 'instructions_required' -and $resFpW1.status -eq 'instructions_required' -and $resFpR1.instructions.Contains('Scoped T7 rule.')) 'file_path alias bypassed scoped AGENTS.md interception.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $t7ScopedDir 'created.txt'))) 'write_file with file_path wrote file before scoped instructions were acknowledged.'
            $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(
                    @{ id = 't7-fp-r2'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"file_path":"scoped-t7/sub/existing.txt"}' } },
                    @{ id = 't7-fp-w2'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"file_path":"scoped-t7/sub/created.txt","content":"via-file-path"}' } }
                )
            } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $resFpR2 = $payload.messages[-2].content | ConvertFrom-Json
            $resFpW2 = $payload.messages[-1].content | ConvertFrom-Json
            Assert-True (([string]$resFpR2.text).Contains('t7-data') -and $resFpW2.status -eq 'written') 'Retry with file_path alias failed after scoped instructions were delivered.'
            $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'T7 turn complete.' } }) } | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
    }
    $script:AgentPermission = 'AutoEdit'
    $script:OutputMode = 'text'
    try {
        $t7State = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'Run T7 checks' }) }
        Invoke-AgentTurn -State $t7State -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 6
        Assert-True ($script:t7Step -eq 4 -and (Test-Path -LiteralPath (Join-Path $t7ScopedDir 'created.txt'))) 'T7 turn did not complete all expected steps.'
        $joinedT7Host = $script:t7HostLines -join "`n"
        Assert-True ($joinedT7Host.Contains('read_file ../outside.txt') -and $joinedT7Host.Contains('write_file ../outside-w.txt') -and $joinedT7Host.Contains('Path is outside the workspace.')) "Expected TUI error cards for failed tool calls in text mode, got:`n$joinedT7Host"

        # Genuine oversized scoped AGENTS.md instruction file error still returns 'Cannot verify scoped AGENTS.md instructions' and renders error card.
        Set-Content -LiteralPath (Join-Path $workspacePath 'scoped-t7/AGENTS.md') -Value ('A' * 70000) -Encoding UTF8 -NoNewline
        $script:t7HostLines = @()
        $script:t7OversizedStep = 0
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:t7OversizedStep++
            $payload = $Body | ConvertFrom-Json
            if ($script:t7OversizedStep -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 't7-ov-1'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"scoped-t7/sub/existing.txt"}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $ovRes = $payload.messages[-1].content | ConvertFrom-Json
                Assert-True ($ovRes.error -like 'Cannot verify scoped AGENTS.md instructions:*Invalid or oversized instruction file*') "Expected oversized scoped AGENTS.md error, got: $($ovRes.error)"
                $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Handled oversized instruction error.' } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $t7OvState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'Read with oversized AGENTS.md' }) }
        Invoke-AgentTurn -State $t7OvState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        $joinedOvHost = $script:t7HostLines -join "`n"
        Assert-True ($joinedOvHost.Contains('read_file scoped-t7/sub/existing.txt') -and $joinedOvHost.Contains('Cannot verify scoped AGENTS.md instructions:')) "Expected TUI error card for oversized scoped AGENTS.md error, got:`n$joinedOvHost"
    }
    finally {
        $script:AgentPermission = 'Ask'
        $script:OutputMode = 'text'
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath (Join-Path $testRoot 'outside.txt')) {
            Remove-Item -LiteralPath (Join-Path $testRoot 'outside.txt') -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath (Join-Path $workspacePath 'scoped-t7')) {
            Remove-Item -LiteralPath (Join-Path $workspacePath 'scoped-t7') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Regression (Task 8): a failed HTTP worker restores previous SHELLOSSUS_HTTP_* values
    # and removes names that were absent. Impossible local URI, no live network call.
    $httpEnvNames = @(
        'SHELLOSSUS_HTTP_URI',
        'SHELLOSSUS_HTTP_KEY',
        'SHELLOSSUS_HTTP_IN',
        'SHELLOSSUS_HTTP_OUT',
        'SHELLOSSUS_HTTP_ERR',
        'SHELLOSSUS_HTTP_TIMEOUT'
    )
    $httpEnvPrior = @{}
    foreach ($httpEnvName in $httpEnvNames) {
        $httpEnvItem = Get-Item -Path ('Env:' + $httpEnvName) -ErrorAction SilentlyContinue
        if ($null -ne $httpEnvItem) {
            $httpEnvPrior[$httpEnvName] = [string]$httpEnvItem.Value
        }
    }
    $httpOutFile = Join-Path $testRoot 'http-worker-out.json'
    $prevHideSpinner = $script:HideSpinner
    $script:HideSpinner = $true
    try {
        foreach ($httpEnvName in $httpEnvNames) {
            Remove-Item -Path ('Env:' + $httpEnvName) -ErrorAction SilentlyContinue
        }
        $env:SHELLOSSUS_HTTP_URI = 'before'
        $env:SHELLOSSUS_HTTP_KEY = 'before-key'
        $env:SHELLOSSUS_HTTP_TIMEOUT = '12'
        $httpEnvThrew = $false
        $httpEnvError = ''
        try {
            Invoke-AgentHttpRequest -Uri 'http://127.0.0.1:1/' -ApiKey 'fake-key' -Body '{}' -OutFile $httpOutFile -TimeoutSec 1 -StatusLabel 'http-env' -ForceBackgroundWorker
        }
        catch {
            $httpEnvThrew = $true
            $httpEnvError = [string]$_.Exception.Message
        }
        Assert-True ($httpEnvThrew) "Expected failed Invoke-AgentHttpRequest to throw. Detail: $httpEnvError"
        Assert-True ($env:SHELLOSSUS_HTTP_URI -eq 'before') "Expected SHELLOSSUS_HTTP_URI to survive a failed request, got '$($env:SHELLOSSUS_HTTP_URI)'."
        Assert-True ($env:SHELLOSSUS_HTTP_KEY -eq 'before-key') "Expected SHELLOSSUS_HTTP_KEY to survive a failed request, got '$($env:SHELLOSSUS_HTTP_KEY)'."
        Assert-True ($env:SHELLOSSUS_HTTP_TIMEOUT -eq '12') "Expected SHELLOSSUS_HTTP_TIMEOUT to survive a failed request, got '$($env:SHELLOSSUS_HTTP_TIMEOUT)'."
        $httpInItem = Get-Item -Path 'Env:SHELLOSSUS_HTTP_IN' -ErrorAction SilentlyContinue
        $httpOutItem = Get-Item -Path 'Env:SHELLOSSUS_HTTP_OUT' -ErrorAction SilentlyContinue
        $httpErrItem = Get-Item -Path 'Env:SHELLOSSUS_HTTP_ERR' -ErrorAction SilentlyContinue
        Assert-True ($null -eq $httpInItem) "SHELLOSSUS_HTTP_IN was absent and should stay absent after a failed request, got '$($env:SHELLOSSUS_HTTP_IN)'."
        Assert-True ($null -eq $httpOutItem) "SHELLOSSUS_HTTP_OUT was absent and should stay absent after a failed request, got '$($env:SHELLOSSUS_HTTP_OUT)'."
        Assert-True ($null -eq $httpErrItem) "SHELLOSSUS_HTTP_ERR was absent and should stay absent after a failed request, got '$($env:SHELLOSSUS_HTTP_ERR)'."
    }
    finally {
        $script:HideSpinner = $prevHideSpinner
        foreach ($httpEnvName in $httpEnvNames) {
            if ($httpEnvPrior.ContainsKey($httpEnvName)) {
                Set-Item -Path ('Env:' + $httpEnvName) -Value $httpEnvPrior[$httpEnvName]
            }
            else {
                Remove-Item -Path ('Env:' + $httpEnvName) -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $httpOutFile) {
            Remove-Item -LiteralPath $httpOutFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Regression (Task 11): /resume with -NoSession loads the chosen session messages
    # but returns an empty session_file. Save-AgentSession already no-ops on an empty path.
    $resumeNoSessDir = Join-Path $testRoot 'resume-nosession'
    New-Item -ItemType Directory -Path $resumeNoSessDir -Force | Out-Null
    $resumeNoSessFile = Join-Path $resumeNoSessDir 'kept-session.jsonl'
    $resumeNoSessSource = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Resumed user text for NoSession' }
        )
    }
    Save-AgentSession -SessionFile $resumeNoSessFile -State $resumeNoSessSource -Workspace $workspacePath -Model 'resume-model' -SessionId 'sess-resume-nosession'
    $resumeNoSessState = @{
        messages = @(
            @{ role = 'system'; content = 'live-system' },
            @{ role = 'user'; content = 'live-user-not-resumed' }
        )
        model = 'live-model'
    }
    $resumeNoSessResult = Invoke-ReplSessionsCommand -State $resumeNoSessState -SessionDir $resumeNoSessDir -SessionFile '' -RootPath $workspacePath -Model 'live-model' -UndoStack @() -LastFailedQuestion 'stale' -ResumeArg 'kept-session.jsonl' -NoSession
    Assert-True ([string]$resumeNoSessResult.session_file -eq '') "Expected empty session_file after resume -NoSession, got '$($resumeNoSessResult.session_file)'."
    $resumeNoSessUsers = @($resumeNoSessResult.state.messages | Where-Object { $_.role -eq 'user' -and [string]$_.content -eq 'Resumed user text for NoSession' })
    Assert-True ($resumeNoSessUsers.Count -eq 1) 'Resumed messages did not contain the saved user text.'
    $resumeNoSessBytesBefore = Get-Content -LiteralPath $resumeNoSessFile -Raw
    $resumeNoSessStampBefore = (Get-Item -LiteralPath $resumeNoSessFile).LastWriteTimeUtc
    Save-AgentSession -SessionFile '' -State $resumeNoSessResult.state -Workspace $workspacePath -Model 'resume-model'
    $resumeNoSessBytesAfter = Get-Content -LiteralPath $resumeNoSessFile -Raw
    $resumeNoSessStampAfter = (Get-Item -LiteralPath $resumeNoSessFile).LastWriteTimeUtc
    Assert-True (($resumeNoSessStampBefore -eq $resumeNoSessStampAfter) -and ($resumeNoSessBytesBefore -eq $resumeNoSessBytesAfter)) "Save-AgentSession -SessionFile '' rewrote the resumed JSONL."

    # Regression (Task 12): /model persists the new model into the open session file.
    # An empty session file still returns the new model and writes nothing.
    $modelPersistDir = Join-Path $testRoot 'model-persist'
    New-Item -ItemType Directory -Path $modelPersistDir -Force | Out-Null
    $modelPersistFile = Join-Path $modelPersistDir 'open-session.jsonl'
    $modelPersistState = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Model persist user text' }
        )
        model = 'old-model'
        session_id = 'sess-model-persist'
    }
    Save-AgentSession -SessionFile $modelPersistFile -State $modelPersistState -Workspace $workspacePath -Model 'old-model' -SessionId 'sess-model-persist'
    $modelPersistMetaBefore = Get-AgentSessionMeta -SessionFile $modelPersistFile
    Assert-True ($modelPersistMetaBefore.model -eq 'old-model') "Fixture session meta model was not old-model, got '$($modelPersistMetaBefore.model)'."
    $modelPersistLive = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Model persist user text' }
        )
        model = 'old-model'
        session_id = 'sess-model-persist'
    }
    $modelPersistResult = Invoke-ReplModelCommand -State $modelPersistLive -CurrentModel 'old-model' -SessionDir $modelPersistDir -NewModel 'new-model' -SessionFile $modelPersistFile -RootPath $workspacePath
    Assert-True ($modelPersistResult -eq 'new-model') "Expected Invoke-ReplModelCommand to return new-model, got '$modelPersistResult'."
    $modelPersistMetaAfter = Get-AgentSessionMeta -SessionFile $modelPersistFile
    Assert-True ($modelPersistMetaAfter.model -eq 'new-model') "Expected SHELLOSSUS session meta model new-model on disk, got '$($modelPersistMetaAfter.model)'."

    $modelEmptyFile = Join-Path $modelPersistDir 'untouched-session.jsonl'
    $modelEmptyState = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Untouched user text' }
        )
        model = 'old-model'
        session_id = 'sess-model-empty'
    }
    Save-AgentSession -SessionFile $modelEmptyFile -State $modelEmptyState -Workspace $workspacePath -Model 'old-model' -SessionId 'sess-model-empty'
    $modelEmptyBytesBefore = Get-Content -LiteralPath $modelEmptyFile -Raw
    $modelEmptyStampBefore = (Get-Item -LiteralPath $modelEmptyFile).LastWriteTimeUtc
    $modelEmptyNamesBefore = @((Get-ChildItem -LiteralPath $modelPersistDir -File | Sort-Object Name | ForEach-Object { $_.Name }) -join '|')
    $modelEmptyLive = @{
        messages = @(
            @{ role = 'system'; content = 'sys' },
            @{ role = 'user'; content = 'Untouched user text' }
        )
        model = 'old-model'
        session_id = 'sess-model-empty'
    }
    $modelEmptyResult = Invoke-ReplModelCommand -State $modelEmptyLive -CurrentModel 'old-model' -SessionDir $modelPersistDir -NewModel 'new-model' -SessionFile '' -RootPath $workspacePath
    Assert-True ($modelEmptyResult -eq 'new-model') "Expected empty session file to return new-model, got '$modelEmptyResult'."
    $modelEmptyBytesAfter = Get-Content -LiteralPath $modelEmptyFile -Raw
    $modelEmptyStampAfter = (Get-Item -LiteralPath $modelEmptyFile).LastWriteTimeUtc
    $modelEmptyNamesAfter = @((Get-ChildItem -LiteralPath $modelPersistDir -File | Sort-Object Name | ForEach-Object { $_.Name }) -join '|')
    $modelEmptyMeta = Get-AgentSessionMeta -SessionFile $modelEmptyFile
    Assert-True ($modelEmptyMeta.model -eq 'old-model') "Empty session file rewrote meta model to '$($modelEmptyMeta.model)'."
    Assert-True (($modelEmptyStampBefore -eq $modelEmptyStampAfter) -and ($modelEmptyBytesBefore -eq $modelEmptyBytesAfter) -and ($modelEmptyNamesBefore -eq $modelEmptyNamesAfter)) "Invoke-ReplModelCommand -SessionFile '' wrote session data."

    # Regression (Task 16): an exception restores the pre-turn messages and undo writes.
    # A cancelled tool inside a successful turn keeps the new messages; restore is catch-only.
    $script:crStep = 0
    $script:crSawFile = $false
    $script:crTargetFile = Join-Path $workspacePath 'continue-rollback.txt'
    $script:crCancelStep = 0
    $crCancelFile = Join-Path $workspacePath 'continue-cancelled.txt'
    $savedCrPerm = $script:AgentPermission
    $savedCrMode = $script:OutputMode
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
    }
    function Start-Sleep {
        param($Seconds, $Milliseconds)
    }
    try {
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'text'
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:crStep++
            if ($script:crStep -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 'cr-w1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"continue-rollback.txt","content":"temp-data"}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
                Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
                return
            }
            if (Test-Path -LiteralPath $script:crTargetFile) { $script:crSawFile = $true }
            throw 'HTTP 500 Internal Server Error'
        }
        $crState = @{
            messages = @(
                @{ role = 'system'; content = 'sys-keep' },
                @{ role = 'user'; content = 'user-keep' }
            )
        }
        $crResult = Invoke-ReplContinueCommand -State $crState -Endpoint 'https://example.invalid/v1/chat/completions' -Model 'test-model' -ApiKey 'fake' -RootPath $workspacePath -SessionFile '' -MaxSteps 4 -UndoStack @()
        Assert-True ($script:crSawFile) 'Continue failure did not write the file before the exception.'
        Assert-True (-not (Test-Path -LiteralPath $script:crTargetFile)) 'Exception did not undo the file written during the turn.'
        $crRoles = @($crState.messages | ForEach-Object { [string]$_.role })
        Assert-True ($crRoles.Count -eq 2 -and $crRoles[0] -eq 'system' -and $crRoles[1] -eq 'user' -and [string]$crState.messages[0].content -eq 'sys-keep' -and [string]$crState.messages[1].content -eq 'user-keep') 'Exception did not restore pre-turn messages.'
        Assert-True ([string]$crState.leaf_id -eq 'e0001' -and @($crState.tree_entries).Count -eq 1 -and [string]$crState.tree_entries[0].id -eq 'e0001') 'Exception did not restore pre-turn leaf_id and tree_entries.'
        Assert-True ($null -ne $crResult.undo_stack -and @($crResult.undo_stack).Count -eq 0) 'Failed continue pushed an undo-stack entry.'

        $script:AgentPermission = 'Ask'
        $script:OutputMode = 'json'
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:crCancelStep++
            if ($script:crCancelStep -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 'cr-can-1'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"continue-cancelled.txt","content":"nope"}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Kept after cancel.' } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $crCancelState = @{
            messages = @(
                @{ role = 'system'; content = 'sys-keep' },
                @{ role = 'user'; content = 'user-keep' }
            )
        }
        $crCancelResult = Invoke-ReplContinueCommand -State $crCancelState -Endpoint 'https://example.invalid/v1/chat/completions' -Model 'test-model' -ApiKey 'fake' -RootPath $workspacePath -SessionFile '' -MaxSteps 4 -UndoStack @()
        Assert-True (-not (Test-Path -LiteralPath $crCancelFile)) 'Cancelled write_file created a file.'
        Assert-True ([string]$crCancelState.messages[-1].content -eq 'Kept after cancel.') 'Successful turn with a cancelled tool did not keep the final assistant message.'
        $crCancelTool = @($crCancelState.messages | Where-Object { $_.role -eq 'tool' })
        $crCancelParsed = $crCancelTool[0].content | ConvertFrom-Json
        Assert-True ($crCancelTool.Count -eq 1 -and $crCancelParsed.status -eq 'cancelled') 'Successful turn did not keep the cancelled tool result.'
        $crCancelStack = @($crCancelResult.undo_stack)
        Assert-True ($crCancelStack.Count -eq 1 -and @($crCancelStack[0].messages).Count -eq 2 -and [string]$crCancelStack[0].leaf_id -eq 'e0001' -and [string]$crCancelState.leaf_id -ne 'e0001') 'Successful turn restored the pre-turn snapshot or dropped the undo entry.'
    }
    finally {
        $script:AgentPermission = $savedCrPerm
        $script:OutputMode = $savedCrMode
        $script:CurrentTurnWrites = @()
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
        if ($script:crTargetFile -and (Test-Path -LiteralPath $script:crTargetFile)) { Remove-Item -LiteralPath $script:crTargetFile -Force -ErrorAction SilentlyContinue }
        if ($crCancelFile -and (Test-Path -LiteralPath $crCancelFile)) { Remove-Item -LiteralPath $crCancelFile -Force -ErrorAction SilentlyContinue }
    }

    # Regression (Task 5): invoking shellossus.ps1 in -Mode json with missing BaseUrl, missing Model, or missing API key
    # never hangs on Read-Host or emits plain-text Write-Host; it emits only valid JSONL on stdout.
    $emptyCfgPath = Join-Path $testRoot 'empty-json.cfg'
    $shellExe = (Get-AgentEnvironment -Root $workspacePath).shell_exe
    $scriptPath = Join-Path $PSScriptRoot '..\shellossus.ps1'
    $jsonCases = @(
        @{ label = 'missing BaseUrl'; extra = '' },
        @{ label = 'missing Model'; extra = "-BaseUrl 'https://example.invalid/v1'" },
        @{ label = 'missing API key'; extra = "-BaseUrl 'https://example.invalid/v1' -Model 'test-model'" }
    )
    $caseIdx = 0
    foreach ($jc in $jsonCases) {
        $caseIdx++
        $jsonOutFile = Join-Path $testRoot "json-missing-$caseIdx.out"
        $jsonErrFile = Join-Path $testRoot "json-missing-$caseIdx.err"
        $cmdText = "`$env:SHELLOSSUS_BASE_URL = ''; `$env:SHELLOSSUS_MODEL = ''; `$env:SHELLOSSUS_API_KEY = ''; & '$($scriptPath.Replace("'", "''"))' -Mode json -ConfigPath '$($emptyCfgPath.Replace("'", "''"))' -Workspace '$($workspacePath.Replace("'", "''"))' -Prompt 'hi' $($jc.extra)"
        $argList = Get-AgentCommandArguments -CommandText $cmdText
        $p = Start-Process -FilePath $shellExe -ArgumentList $argList -WorkingDirectory $workspacePath -RedirectStandardOutput $jsonOutFile -RedirectStandardError $jsonErrFile -NoNewWindow -PassThru
        $exited = $p.WaitForExit(10000)
        if (-not $exited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        Assert-True $exited "shellossus -Mode json hung on Read-Host when $($jc.label)."
        $outLines = @(if (Test-Path -LiteralPath $jsonOutFile) { Get-Content -LiteralPath $jsonOutFile } else { @() })
        $sawTurnEndError = $false
        foreach ($ol in $outLines) {
            if ($ol.Trim()) {
                $ev = $ol | ConvertFrom-Json -ErrorAction Stop
                Assert-True ([bool]$ev.type) "Unexpected non-JSON stdout in -Mode json ($($jc.label)): $ol"
                if ($ev.type -eq 'turn_end' -and $ev.status -eq 'error' -and [bool]$ev.error) {
                    $sawTurnEndError = $true
                }
            }
        }
        Assert-True $sawTurnEndError "Expected turn_end error JSON event in -Mode json when $($jc.label)."
    }

    $script:jsonBannerLines = @()
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $script:jsonBannerLines += (($Object | ForEach-Object { [string]$_ }) -join ' ')
    }
    try {
        $script:OutputMode = 'json'
        Write-TuiStartupBanner -RootPath $workspacePath -ConfigDir '' -Model 'test-model'
        Assert-True ($script:jsonBannerLines.Count -eq 0) 'Write-TuiStartupBanner emitted output in JSON mode.'
    }
    finally {
        $script:OutputMode = 'text'
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-TestEnvironment -Env $envData
}
