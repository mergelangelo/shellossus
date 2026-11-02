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

    # Mid-turn proactive auto-compaction when context exceeds 60k chars across steps.
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
        Assert-True ($roToolNames.Count -eq 4 -and ($roToolNames -notcontains 'write_file') -and $roPayload.messages[0].content.Contains('Permission mode: ReadOnly.')) 'ReadOnly turn payload was out of sync with active permission.'

        # 3. Switch to Ask: write_file is restored, transition notice replaces ReadOnly notice, and real write with WRITE confirmation succeeds.
        $script:AgentPermission = 'Ask'
        Sync-AgentCapabilities -State $modeSwitchState -RecordTransition | Out-Null
        $modeSwitchState.messages += @{ role = 'user'; content = 'Now update mode-test.txt in Ask mode' }
        Invoke-AgentTurn -State $modeSwitchState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        $askPayload = $script:capturedPayloads[3]
        $askToolNames = @($askPayload.tools | ForEach-Object { $_.function.name })
        $capNoticesInAsk = @($askPayload.messages | Where-Object { $_.role -eq 'user' -and $_.content -like '[Capability State Change]*' })
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

    # 1. Migrate legacy h-agent block with -Shortcut sss and verify backup & profile preservation.
    & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut 'sss'
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
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut $badName
        }
        catch {
            if ($_.Exception.Message -like '*Invalid shortcut name*') { $badThrew = $true }
        }
        Assert-True $badThrew "Installer accepted invalid shortcut syntax: '$badName'."
    }
    $bothFlagsThrew = $false
    try {
        & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut 's' -NoShortcut
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
                & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut $conflictName
            }
            catch {
                if ($_.Exception.Message -like "*conflicts with existing*") { $confThrew = $true }
            }
            Assert-True $confThrew "Installer did not reject conflicting command '$conflictName'."
        }

        # 4. Own previously installed shortcut function is recognized and NOT treated as a conflict on rerun.
        . $profileFile
        & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut 'sss'
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
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText1 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText1.Contains('function global:shos_custom')) 'Interactive first install with conflict retry and custom shortcut failed.'

            # Reinstall 1: '1' (Keep 'shos_custom').
            $global:readQueue = @('1')
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText2 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText2.Contains('function global:shos_custom') -and ((@($intText2 -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1)) 'Interactive reinstall keep shortcut failed.'

            # Reinstall 2: '2' (Change shortcut) -> '3' ('shos').
            $global:readQueue = @('2', '3')
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText3 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText3.Contains('function global:shos') -and (-not $intText3.Contains('function global:shos_custom'))) 'Interactive reinstall change shortcut failed.'

            # Reinstall 3: '3' (Remove shortcut).
            $global:readQueue = @('3')
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
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
        & "$PSScriptRoot\..\install.ps1" -AgentPath $spacedAgent -ProfilePath $spacedProfile -Shortcut 'shos_spaced'
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
}
finally {
    Remove-TestEnvironment -Env $envData
}
