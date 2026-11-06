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
    # profile preservation & backup, h-agent block migration, and paths with spaces + argument forwarding.
    $profileFile = Join-Path $testRoot 'profile.ps1'
    $legacyBlock = "# keep my settings`r`n# >>> h-agent >>>`r`nfunction global:h-agent { & 'C:\old\h-agent.ps1' @args }`r`n# <<< h-agent <<<`r`n# footer line"
    Set-Content -LiteralPath $profileFile -Value $legacyBlock -Encoding UTF8 -NoNewline

    # 1. Migrate legacy h-agent block with -Install -Shortcut sss and verify backup & profile preservation.
    & "$PSScriptRoot\..\shellossus.ps1" -Install -ProfilePath $profileFile -Shortcut 'sss'
    $profileText = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8
    Assert-True ($profileText.Contains('# keep my settings') -and $profileText.Contains('# footer line')) 'Profile user contents were lost during migration.'
    Assert-True ((-not $profileText.Contains('# >>> h-agent >>>')) -and (-not $profileText.Contains('function global:h-agent'))) 'Legacy h-agent block was not migrated.'
    Assert-True (((@($profileText -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1) -and $profileText.Contains('function global:shellossus') -and $profileText.Contains('function global:sss')) 'Expected shellossus and sss functions in migrated block.'
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
}
finally {
    Remove-TestEnvironment -Env $envData
}
