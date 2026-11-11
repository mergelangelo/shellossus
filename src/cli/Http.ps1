# Pure-ASCII JSON payload escaping, JSONL event output, spinner wait loop, and async HTTP worker.

function ConvertTo-AgentApiMessages {
    param([array]$Messages)
    foreach ($message in $Messages) {
        $apiMessage = @{ role = $message.role; content = $message.content }
        if ($message.role -eq 'assistant') {
            if ($message.reasoning_content) { $apiMessage.reasoning_content = $message.reasoning_content }
            # Tool calls are provider data. Replay the arguments, IDs, and extensions intact.
            if ($message.tool_calls) { $apiMessage.tool_calls = @($message.tool_calls) }
        }
        elseif ($message.role -eq 'tool') {
            $apiMessage.tool_call_id = $message.tool_call_id
        }
        $apiMessage
    }
}

function ConvertTo-AsciiJson {
    param([string]$Json)
    if (-not $Json -or ($Json -notmatch '[^\x00-\x7F]')) { return $Json }
    $parts = @($Json -split '([^\x00-\x7F]+)')
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $escaped = foreach ($ch in [char[]]$parts[$i]) {
            '\u{0:x4}' -f [int][char]$ch
        }
        $parts[$i] = ($escaped -join '')
    }
    return ($parts -join '')
}

function Write-AgentJsonEvent {
    param([string]$EventType, [hashtable]$Payload = @{})
    if ($script:OutputMode -ne 'json') { return }
    $ev = @{
        type = $EventType
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    }
    foreach ($k in $Payload.Keys) { $ev[$k] = $Payload[$k] }
    Write-Host (ConvertTo-AsciiJson -Json ($ev | ConvertTo-Json -Depth 20 -Compress))
}

function Assert-AgentApiResponseSize {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt $script:AgentMaxApiResponseBytes) {
        throw "API response exceeds the $($script:AgentMaxApiResponseBytes)-byte limit."
    }
}

function ConvertFrom-AgentSseResponse {
    param([AllowEmptyString()][string]$RawText)
    $incompleteErr = 'Incomplete SSE stream from API (missing terminal [DONE] or finish_reason).'
    if ($null -eq $RawText) { throw $incompleteErr }
    $text = $RawText
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    if (-not $text.Trim()) { throw $incompleteErr }
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalized -split "`n"

    $curEvent = ''
    $firstData = ''
    $dataCount = 0
    $eventStartIdx = 0
    $events = @(for ($li = 0; $li -le $lines.Count; $li++) {
        $line = if ($li -lt $lines.Count) { [string]$lines[$li] } else { '' }
        if ($line.Length -eq 0) {
            if ($dataCount -gt 0 -or $curEvent.Length -gt 0) {
                $joinedData = ''
                if ($dataCount -eq 1) {
                    $joinedData = $firstData
                }
                elseif ($dataCount -gt 1) {
                    $multiParts = @(for ($di = $eventStartIdx; $di -lt $li; $di++) {
                        $dl = [string]$lines[$di]
                        if ($dl.Length -gt 0 -and $dl[0] -cne ':') {
                            $dc = $dl.IndexOf(':')
                            if ($dc -gt 0 -and $dl.Substring(0, $dc) -ceq 'data') {
                                $dv = $dl.Substring($dc + 1)
                                if ($dv.Length -gt 0 -and $dv[0] -ceq ' ') { $dv = $dv.Substring(1) }
                                $dv
                            }
                        }
                    })
                    $joinedData = $multiParts -join "`n"
                }
                @{
                    event = $curEvent
                    has_data = ($dataCount -gt 0)
                    data = $joinedData
                }
                $curEvent = ''
                $firstData = ''
                $dataCount = 0
            }
            $eventStartIdx = $li + 1
            continue
        }
        if ($line[0] -ceq ':') { continue }
        $colonIdx = $line.IndexOf(':')
        if ($colonIdx -le 0) {
            throw 'Invalid SSE frame in API stream.'
        }
        $field = $line.Substring(0, $colonIdx)
        $val = $line.Substring($colonIdx + 1)
        if ($val.Length -gt 0 -and $val[0] -ceq ' ') {
            $val = $val.Substring(1)
        }
        if ($field -ceq 'data') {
            if ($dataCount -eq 0) { $firstData = $val }
            $dataCount++
        }
        elseif ($field -ceq 'event') {
            $curEvent = $val.Trim()
        }
        elseif ($field -ceq 'id' -or $field -ceq 'retry') {
            continue
        }
        else {
            throw 'Invalid SSE frame in API stream.'
        }
    })

    $sawDone = $false
    $chunks = @(foreach ($ev in $events) {
        if ($ev.event -ieq 'error') {
            $errMsg = 'Stream error event received from API.'
            if ($ev.has_data -and $ev.data.Trim()) {
                $rawErr = $ev.data.Trim()
                try {
                    $parsedErr = $rawErr | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $parsedErr.error) {
                        if ($parsedErr.error -is [string] -and $parsedErr.error.Trim()) {
                            $errMsg = $parsedErr.error.Trim()
                        }
                        elseif ((Test-IsJsonObject -Value $parsedErr.error) -and $parsedErr.error.message) {
                            $errMsg = [string]$parsedErr.error.message
                        }
                    }
                    elseif ($parsedErr.message) {
                        $errMsg = [string]$parsedErr.message
                    }
                }
                catch {
                    if ($rawErr.Length -gt 300) { $rawErr = $rawErr.Substring(0, 300) + '...' }
                    $errMsg = $rawErr
                }
            }
            throw "SSE stream error: $errMsg"
        }
        if (-not $ev.has_data) { continue }
        $payload = $ev.data.Trim()
        if ($payload -ceq '[DONE]') {
            $sawDone = $true
            continue
        }
        if ($sawDone) {
            throw 'Unexpected SSE data after terminal [DONE].'
        }
        if (-not $payload) {
            throw 'Invalid JSON in SSE stream data payload.'
        }
        $chunk = $null
        try {
            $chunk = $payload | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw 'Invalid JSON in SSE stream data payload.'
        }
        if (-not (Test-IsJsonObject -Value $chunk)) {
            throw 'Invalid JSON in SSE stream data payload.'
        }
        if ($null -ne $chunk.error) {
            $chunkErr = 'API error in SSE stream.'
            if ($chunk.error -is [string] -and $chunk.error.Trim()) {
                $chunkErr = $chunk.error.Trim()
            }
            elseif ((Test-IsJsonObject -Value $chunk.error) -and $chunk.error.message) {
                $chunkErr = [string]$chunk.error.message
            }
            throw "SSE stream error: $chunkErr"
        }
        $chunk
    })

    $hasContent = $false
    $contentParts = @(foreach ($chunk in $chunks) {
        if ($chunk.choices -is [array] -and $chunk.choices.Count -gt 0) {
            $c0 = $chunk.choices[0]
            if ((Test-IsJsonObject -Value $c0) -and (Test-IsJsonObject -Value $c0.delta) -and $null -ne $c0.delta.content) {
                if ($c0.delta.content -isnot [string]) {
                    throw 'API returned non-string assistant content in SSE delta.'
                }
                $hasContent = $true
                $c0.delta.content
            }
        }
    })

    $hasReasoning = $false
    $reasoningParts = @(foreach ($chunk in $chunks) {
        if ($chunk.choices -is [array] -and $chunk.choices.Count -gt 0) {
            $c0 = $chunk.choices[0]
            if ((Test-IsJsonObject -Value $c0) -and (Test-IsJsonObject -Value $c0.delta) -and $null -ne $c0.delta.reasoning_content) {
                if ($c0.delta.reasoning_content -isnot [string]) {
                    throw 'API returned non-string reasoning_content in SSE delta.'
                }
                $hasReasoning = $true
                $c0.delta.reasoning_content
            }
        }
    })

    $finishReason = ''
    $usage = $null
    $toolMetaByIndex = @{}
    $tcDeltas = @(foreach ($chunk in $chunks) {
        if (Test-IsJsonObject -Value $chunk.usage) {
            $usage = $chunk.usage
        }
        if ($chunk.choices -isnot [array] -or $chunk.choices.Count -eq 0) { continue }
        $c0 = $chunk.choices[0]
        if (-not (Test-IsJsonObject -Value $c0)) {
            throw 'API returned an invalid choice entry in SSE stream.'
        }
        if ($null -ne $c0.finish_reason) {
            if ($c0.finish_reason -isnot [string]) {
                throw 'API returned an invalid finish_reason.'
            }
            if ($c0.finish_reason.Length -gt 0) {
                $finishReason = $c0.finish_reason
            }
        }
        $delta = $c0.delta
        if ($null -eq $delta) { continue }
        if (-not (Test-IsJsonObject -Value $delta)) {
            throw 'API returned an invalid delta object in SSE stream.'
        }
        if ($null -ne $delta.role) {
            if ($delta.role -isnot [string] -or ($delta.role.Length -gt 0 -and $delta.role -cne 'assistant')) {
                throw 'API returned an invalid assistant role in SSE stream.'
            }
        }
        if ($null -eq $delta.tool_calls) { continue }
        if ($delta.tool_calls -isnot [array]) {
            throw 'Invalid tool_calls delta in SSE stream.'
        }
        foreach ($tc in $delta.tool_calls) {
            if (-not (Test-IsJsonObject -Value $tc)) {
                throw 'Invalid tool_call entry in SSE stream.'
            }
            $idx = 0
            if ($null -ne $tc.index) {
                if ($tc.index -is [bool] -or ($tc.index -isnot [int] -and $tc.index -isnot [long]) -or $tc.index -lt 0 -or $tc.index -gt 1024) {
                    throw 'Invalid tool_call index in SSE stream.'
                }
                $idx = [int]$tc.index
            }
            if (-not $toolMetaByIndex.ContainsKey($idx)) {
                $toolMetaByIndex[$idx] = @{
                    id = ''
                    type = ''
                    extra = @{}
                    fn_extra = @{}
                }
            }
            $meta = $toolMetaByIndex[$idx]
            if ($null -ne $tc.id) {
                if ($tc.id -isnot [string]) {
                    throw 'Invalid tool_call id in SSE stream.'
                }
                if ($tc.id.Length -gt 0) {
                    if (-not $meta.id) { $meta.id = $tc.id }
                    elseif ($meta.id -cne $tc.id) { throw 'Conflicting tool_call IDs at the same SSE index.' }
                }
            }
            if ($null -ne $tc.type) {
                if ($tc.type -isnot [string]) {
                    throw 'Invalid tool_call type in SSE stream.'
                }
                if ($tc.type.Length -gt 0) { $meta.type = $tc.type }
            }
            foreach ($propName in @(Get-ObjectPropertyNames -InputObject $tc)) {
                if ($propName -notin @('index', 'id', 'type', 'function')) {
                    $propVal = $tc.$propName
                    if ($null -ne $propVal) {
                        if ($meta.extra.ContainsKey($propName) -and (Test-IsJsonObject -Value $propVal) -and @(Get-ObjectPropertyNames -InputObject $propVal).Count -eq 0) {
                            continue
                        }
                        $meta.extra[$propName] = $propVal
                    }
                }
            }
            $hasFnName = $false
            $fnNameFrag = ''
            $hasFnArgs = $false
            $fnArgsFrag = ''
            if ($null -ne $tc.function) {
                if (-not (Test-IsJsonObject -Value $tc.function)) {
                    throw 'Invalid tool_call function object in SSE stream.'
                }
                if ($null -ne $tc.function.name) {
                    if ($tc.function.name -isnot [string]) {
                        throw 'Invalid tool_call function name in SSE stream.'
                    }
                    $hasFnName = $true
                    $fnNameFrag = $tc.function.name
                }
                if ($null -ne $tc.function.arguments) {
                    if ($tc.function.arguments -isnot [string]) {
                        throw 'Invalid tool_call function arguments in SSE stream.'
                    }
                    $hasFnArgs = $true
                    $fnArgsFrag = $tc.function.arguments
                }
                foreach ($fnProp in @(Get-ObjectPropertyNames -InputObject $tc.function)) {
                    if ($fnProp -notin @('name', 'arguments')) {
                        $fnPropVal = $tc.function.$fnProp
                        if ($null -ne $fnPropVal) {
                            if ($meta.fn_extra.ContainsKey($fnProp) -and (Test-IsJsonObject -Value $fnPropVal) -and @(Get-ObjectPropertyNames -InputObject $fnPropVal).Count -eq 0) {
                                continue
                            }
                            $meta.fn_extra[$fnProp] = $fnPropVal
                        }
                    }
                }
            }
            if ($hasFnName -or $hasFnArgs) {
                @{
                    index = $idx
                    has_name = $hasFnName
                    name = $fnNameFrag
                    has_args = $hasFnArgs
                    arguments = $fnArgsFrag
                }
            }
        }
    })

    if (-not $sawDone -or -not $finishReason) {
        throw $incompleteErr
    }

    $assembledToolCalls = @(foreach ($idx in @($toolMetaByIndex.Keys | Sort-Object)) {
        $meta = $toolMetaByIndex[$idx]
        $joinedName = (@(foreach ($d in $tcDeltas) {
            if ($d.index -eq $idx -and $d.has_name) { $d.name }
        }) -join '')
        $joinedArgs = (@(foreach ($d in $tcDeltas) {
            if ($d.index -eq $idx -and $d.has_args) { $d.arguments }
        }) -join '')
        $fnObj = @{
            name = $joinedName
            arguments = $joinedArgs
        }
        foreach ($fk in $meta.fn_extra.Keys) {
            $fnObj[$fk] = $meta.fn_extra[$fk]
        }
        $tcObj = @{
            id = $meta.id
            type = $(if ($meta.type) { $meta.type } else { 'function' })
            function = $fnObj
        }
        foreach ($ek in $meta.extra.Keys) {
            $tcObj[$ek] = $meta.extra[$ek]
        }
        $tcObj
    })

    $msg = @{
        role = 'assistant'
        content = $(if ($hasContent) { $contentParts -join '' } else { $null })
    }
    if ($hasReasoning) {
        $msg['reasoning_content'] = ($reasoningParts -join '')
    }
    if ($assembledToolCalls.Count -gt 0) {
        $msg['tool_calls'] = [object[]]$assembledToolCalls
    }
    $result = @{
        choices = [object[]]@(
            @{
                index = 0
                finish_reason = $finishReason
                message = $msg
            }
        )
    }
    if ($null -ne $usage) {
        $result['usage'] = $usage
    }
    return $result
}

function Read-AgentApiResponse {
    param([string]$Path)
    Assert-AgentApiResponseSize -Path $Path
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $raw) { $raw = '' }
    $probe = [string]$raw
    if ($probe.Length -gt 0 -and [int][char]$probe[0] -eq 0xFEFF) {
        $probe = $probe.Substring(1)
    }
    $trimmed = $probe.TrimStart()
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        return ($probe | ConvertFrom-Json -ErrorAction Stop)
    }
    if ($script:StreamRequests -or ($trimmed -match '^(?:data:|event:|id:|retry:|:)')) {
        return (ConvertFrom-AgentSseResponse -RawText $probe)
    }
    return ($probe | ConvertFrom-Json -ErrorAction Stop)
}

function Wait-AgentProcessWithSpinner {
    param($Process, [string]$StatusLabel = 'Waiting for model', [int]$TimeoutSec = $script:RequestTimeoutSec, [int]$PollMs = 200, [string]$ResponsePath)
    $frames = @('|', '/', '-', '\')
    $frameIdx = 0
    $startWait = Get-Date
    $showSpinner = ($script:OutputMode -ne 'json') -and (-not $script:HideSpinner)
    $lastSpinVisLen = 0
    try {
        while (-not $Process.HasExited) {
            if ($ResponsePath) { Assert-AgentApiResponseSize -Path $ResponsePath }
            $elapsed = ((Get-Date) - $startWait).TotalSeconds
            if ($showSpinner) {
                $spinChar = $frames[$frameIdx % $frames.Count]
                $frameIdx++
                $maxSpinW = (Get-TerminalWidth) - 1
                if ($maxSpinW -lt 20) { $maxSpinW = 20 }
                $rawSpinLine = $script:Gm.Grey1 + ("  [{0}] {1} ({2:0.0}s)..." -f $spinChar, (Format-TuiText $StatusLabel), $elapsed) + $script:Gm.Reset
                $clampedSpinLine = Limit-AnsiLineToWidth -Text $rawSpinLine -MaxWidth $maxSpinW
                $lastSpinVisLen = (Strip-AnsiCodes -Text $clampedSpinLine).Length
                $statusLine = "`r" + $clampedSpinLine
                Write-Host $statusLine -NoNewline
            }
            if ($elapsed -ge ($TimeoutSec + 5)) {
                if (-not $Process.HasExited) {
                    Stop-Process -InputObject $Process -Force -ErrorAction SilentlyContinue
                    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                }
                throw "Request timed out after ${TimeoutSec}s."
            }
            Start-Sleep -Milliseconds $PollMs
        }
    }
    finally {
        if ($showSpinner -and $frameIdx -gt 0) {
            $clearWidth = if ($lastSpinVisLen -gt 0) { $lastSpinVisLen } else { $StatusLabel.Length + 28 }
            $clearLine = "`r" + (' ' * $clearWidth) + "`r"
            Write-Host $clearLine -NoNewline
        }
        if (-not $Process.HasExited) {
            Stop-Process -InputObject $Process -Force -ErrorAction SilentlyContinue
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -InputObject $Process -Timeout 2 -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-InternalHttpWorker {
    $script:InternalWorkerFailed = $false
    try {
        if (-not $env:SHELLOSSUS_HTTP_URI) { throw 'HTTP worker URI is required.' }
        if (-not $env:SHELLOSSUS_HTTP_IN) { throw 'HTTP worker input file is required.' }
        if (-not $env:SHELLOSSUS_HTTP_OUT) { throw 'HTTP worker output file is required.' }
        $timeoutVal = if ($env:SHELLOSSUS_HTTP_TIMEOUT) { [int]$env:SHELLOSSUS_HTTP_TIMEOUT } else { 180 }
        $workerHeaders = @{ Authorization = ('Bearer ' + $env:SHELLOSSUS_API_KEY) }
        if ($env:SHELLOSSUS_HTTP_STREAM -eq '1') {
            $workerHeaders['Accept'] = 'text/event-stream, application/json'
        }
        $null = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $env:SHELLOSSUS_HTTP_URI -Method 'Post' -Headers $workerHeaders -ContentType 'application/json; charset=utf-8' -InFile $env:SHELLOSSUS_HTTP_IN -OutFile $env:SHELLOSSUS_HTTP_OUT -MaximumRedirection 0 -TimeoutSec $timeoutVal -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $msg = [string]$_.Exception.Message
        $details = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $details = ([string]$_.ErrorDetails.Message).Trim()
        }
        if ($details) {
            # Four bytes per code unit is a safe UTF-8 upper bound.
            if ($details.Length -le 4096) {
                try {
                    $parsed = $details | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed.error -and $parsed.error.message) { $details = [string]$parsed.error.message }
                }
                catch {}
            }
            if ($details.Length -gt 300) { $details = $details.Substring(0, 300) + '...' }
            $msg = $msg + ' (' + $details + ')'
        }
        if ($env:SHELLOSSUS_HTTP_ERR) {
            Set-AgentUtf8Content -LiteralPath $env:SHELLOSSUS_HTTP_ERR -Value $msg
        }
        $script:InternalWorkerFailed = $true
    }
}

function Invoke-AgentHttpRequest {
    param(
        [string]$Uri,
        [string]$ApiKey,
        [string]$Body,
        [string]$OutFile,
        [int]$TimeoutSec = $script:RequestTimeoutSec,
        [string]$StatusLabel = 'Waiting for model',
        [switch]$ForceBackgroundWorker
    )
    $asciiBody = ConvertTo-AsciiJson -Json $Body
    $iwrCmd = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ((-not $ForceBackgroundWorker) -and (($iwrCmd -and $iwrCmd.CommandType -eq 'Function') -or $script:DisableAsyncHttp)) {
        $reqHeaders = @{ Authorization = "Bearer $ApiKey" }
        if ($script:StreamRequests) {
            $reqHeaders['Accept'] = 'text/event-stream, application/json'
        }
        $request = @{
            Uri = $Uri
            Method = 'Post'
            Headers = $reqHeaders
            ContentType = 'application/json; charset=utf-8'
            Body = $asciiBody
            TimeoutSec = $TimeoutSec
            ErrorAction = 'Stop'
        }
        if ($iwrCmd -and $iwrCmd.CommandType -ne 'Function') {
            $request['MaximumRedirection'] = 0
        }
        try { Invoke-WebRequest @request -UseBasicParsing -OutFile $OutFile }
        catch {
            $message = Format-AgentError -ErrorRecord $_
            if ($ApiKey) { $message = $message.Replace($ApiKey, '[redacted]') }
            throw (Format-TuiText $message)
        }
        Assert-AgentApiResponseSize -Path $OutFile
        return
    }
    $shellExe = Get-AgentPowerShellExecutable
    $workerScript = Resolve-StandaloneScriptPath -Required
    $reqTemp = New-AgentTempFile
    $errTemp = New-AgentTempFile
    $stdoutTemp = New-AgentTempFile
    $stderrTemp = New-AgentTempFile
    try {
        Set-Content -LiteralPath $reqTemp.FullName -Value $asciiBody -Encoding Ascii -NoNewline -ErrorAction Stop
        $argList = Get-AgentWorkerArguments -ScriptPath $workerScript -WorkerMode 'http'
        $proc = Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_HTTP_URI = $Uri
            SHELLOSSUS_API_KEY = $ApiKey
            OPENAI_API_KEY = $null
            SHELLOSSUS_HTTP_IN = $reqTemp.FullName
            SHELLOSSUS_HTTP_OUT = $OutFile
            SHELLOSSUS_HTTP_ERR = $errTemp.FullName
            SHELLOSSUS_HTTP_TIMEOUT = [string]$TimeoutSec
            SHELLOSSUS_HTTP_STREAM = $(if ($script:StreamRequests) { '1' } else { '0' })
        } -Action {
            Start-Process -FilePath $shellExe -ArgumentList $argList -RedirectStandardOutput $stdoutTemp.FullName -RedirectStandardError $stderrTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
        }
        Wait-AgentProcessWithSpinner -Process $proc -StatusLabel $StatusLabel -TimeoutSec $TimeoutSec -ResponsePath $OutFile
        Assert-AgentApiResponseSize -Path $OutFile
        $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        if ($errItem -and $errItem.Length -gt 0) {
            $errText = Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($errText) {
                if ($ApiKey) { $errText = $errText.Replace($ApiKey, '[redacted]') }
                throw (Format-TuiText $errText.Trim())
            }
        }
        if ($null -ne $proc.ExitCode -and [int]$proc.ExitCode -ne 0) {
            $stdErrText = Get-Content -LiteralPath $stderrTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($stdErrText -and $stdErrText.Trim()) {
                if ($ApiKey) { $stdErrText = $stdErrText.Replace($ApiKey, '[redacted]') }
                throw (Format-TuiText $stdErrText.Trim())
            }
            throw "HTTP worker exited with code $($proc.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $reqTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrTemp.FullName -Force -ErrorAction SilentlyContinue
    }
}
