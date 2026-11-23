# Pure-ASCII JSON payload escaping, JSONL event output, spinner wait loop, and async HTTP worker.

$script:LastHttpRetryAfterSec = $null
$script:LastHttpStreamedContent = $false
$script:LastHttpStreamedReasoning = $false
$script:PersistentHttpWorker = $null
$script:DisablePersistentHttpWorker = $false

function ConvertFrom-AgentRetryAfterValue {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    if ($Value -is [timespan]) {
        $totalSec = $Value.TotalSeconds
        if ($totalSec -le 1) { return 1 }
        if ($totalSec -ge 86400) { return 86400 }
        $intSec = [int]$totalSec
        if ($totalSec -gt $intSec) { $intSec++ }
        return $intSec
    }
    if ($Value -is [datetime]) {
        $diffSec = ($Value.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds
        if ($diffSec -le 1) { return 1 }
        if ($diffSec -ge 86400) { return 86400 }
        $intSec = [int]$diffSec
        if ($diffSec -gt $intSec) { $intSec++ }
        return $intSec
    }
    if ($Value -is [int] -or $Value -is [long]) {
        if ([long]$Value -lt 0) { return $null }
        if ([long]$Value -lt 1) { return 1 }
        if ([long]$Value -ge 86400) { return 86400 }
        return [int]$Value
    }
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    if ($s -match '^[0-9]+\s*,') {
        $s = ($s -split ',')[0].Trim()
    }
    if ($s -match '^[0-9]+$') {
        if ($s.Length -gt 5) {
            $trimmedZeros = $s.TrimStart('0')
            if (-not $trimmedZeros) { return 1 }
            if ($trimmedZeros.Length -gt 5) { return 86400 }
            $s = $trimmedZeros
        }
        $n = [int]$s
        if ($n -lt 1) { return 1 }
        if ($n -ge 86400) { return 86400 }
        return $n
    }
    if ($s -match '^-') { return $null }
    if ($s -match '[A-Za-z]') {
        try {
            $dtUtc = ([datetime]$s).ToUniversalTime()
            $diffSec = ($dtUtc - [datetime]::UtcNow).TotalSeconds
            if ($diffSec -le 1) { return 1 }
            if ($diffSec -ge 86400) { return 86400 }
            $intSec = [int]$diffSec
            if ($diffSec -gt $intSec) { $intSec++ }
            return $intSec
        }
        catch { return $null }
    }
    return $null
}

function Get-AgentRetryAfterSeconds {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return $null }
    $resp = $null
    try {
        if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
            $resp = $ErrorRecord.Exception.Response
        }
        elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.InnerException -and $ErrorRecord.Exception.InnerException.Response) {
            $resp = $ErrorRecord.Exception.InnerException.Response
        }
    }
    catch { return $null }
    if ($null -eq $resp) { return $null }
    $headers = $null
    try { $headers = $resp.Headers } catch { return $null }
    if ($null -eq $headers) { return $null }
    try {
        if ($headers -is [hashtable]) {
            foreach ($k in $headers.Keys) {
                if ([string]$k -ieq 'Retry-After') {
                    return (ConvertFrom-AgentRetryAfterValue -Value $headers[$k])
                }
            }
            return $null
        }
        try {
            if ($null -ne $headers.RetryAfter) {
                if ($null -ne $headers.RetryAfter.Delta) {
                    return (ConvertFrom-AgentRetryAfterValue -Value $headers.RetryAfter.Delta)
                }
                if ($null -ne $headers.RetryAfter.Date) {
                    return (ConvertFrom-AgentRetryAfterValue -Value $headers.RetryAfter.Date.UtcDateTime)
                }
            }
        }
        catch {}
        try {
            $directVal = $headers['Retry-After']
            if ($null -ne $directVal) {
                if ($directVal -isnot [string] -and $directVal -isnot [timespan] -and $directVal -isnot [datetime] -and $directVal -isnot [int] -and $directVal -isnot [long]) {
                    $directVal = @($directVal) | Select-Object -First 1
                }
                if ($null -ne $directVal) {
                    return (ConvertFrom-AgentRetryAfterValue -Value $directVal)
                }
            }
        }
        catch {}
        foreach ($entry in $headers) {
            if ($null -ne $entry -and $entry.Key -is [string] -and $entry.Key -ieq 'Retry-After') {
                $firstVal = @($entry.Value) | Select-Object -First 1
                if ($null -ne $firstVal) {
                    return (ConvertFrom-AgentRetryAfterValue -Value $firstVal)
                }
            }
        }
    }
    catch {}
    return $null
}

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

function New-AgentLiveStreamState {
    return @{
        byte_offset = [long]0
        processed_char_offset = 0
        total_bytes_read = [long]0
        pending_data = @()
        last_file_length = [long]-1
        active_section = 'none'
        at_line_start = $true
        streamed_reasoning = $false
        streamed_content = $false
        saw_any_output = $false
        content_line_buf = ''
        md_state = (New-AgentMarkdownStreamState)
        pending_reasoning_parts = @()
    }
}

function Read-AgentLiveStreamDeltaText {
    param(
        [string]$Path,
        [hashtable]$State,
        [switch]$Final
    )
    $fileLen = [long]-1
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $fileLen = [long]$item.Length
    }
    catch {
        return @{ ok = $false; has_lines = $false; delta = '' }
    }
    if ($fileLen -le 0) {
        return @{ ok = $true; has_lines = $false; delta = '' }
    }
    if ($script:AgentMaxApiResponseBytes -gt 0 -and $fileLen -gt $script:AgentMaxApiResponseBytes) {
        return @{ ok = $false; has_lines = $false; delta = '' }
    }
    if ($fileLen -lt [long]$State.byte_offset) {
        $State.byte_offset = [long]0
        $State.processed_char_offset = 0
        $State.pending_data = @()
    }
    if ((-not $Final) -and ($fileLen -eq $State.last_file_length)) {
        return @{ ok = $true; has_lines = $false; delta = '' }
    }
    if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
        $offset = [long]$State.byte_offset
        if ($fileLen -le $offset) {
            $State.last_file_length = $fileLen
            return @{ ok = $true; has_lines = $false; delta = '' }
        }
        $toRead = [int]($fileLen - $offset)
        $fs = $null
        $totalRead = 0
        $buf = [byte[]]::new($toRead)
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            if ($offset -gt 0) {
                $null = $fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
            }
            while ($totalRead -lt $toRead) {
                $n = $fs.Read($buf, $totalRead, $toRead - $totalRead)
                if ($n -le 0) { break }
                $totalRead += $n
            }
        }
        catch {
            # Graceful fallback when the worker holds an exclusive write lock (e.g. Windows PowerShell 5.1).
            return @{ ok = $false; has_lines = $false; delta = '' }
        }
        finally {
            if ($null -ne $fs) { $fs.Dispose() }
        }
        $State.last_file_length = $fileLen
        $State.total_bytes_read = [long]$State.total_bytes_read + $totalRead
        if ($totalRead -le 0) {
            return @{ ok = $true; has_lines = $false; delta = '' }
        }
        $decodeStart = 0
        if ($offset -eq 0 -and $totalRead -ge 3 -and $buf[0] -eq 239 -and $buf[1] -eq 187 -and $buf[2] -eq 191) {
            $decodeStart = 3
        }
        if ($Final) {
            $decodeLen = $totalRead - $decodeStart
            $State.byte_offset = $offset + $totalRead
            if ($decodeLen -le 0) {
                return @{ ok = $true; has_lines = $false; delta = '' }
            }
            $text = [System.Text.Encoding]::UTF8.GetString($buf, $decodeStart, $decodeLen)
            return @{ ok = $true; has_lines = $true; delta = $text }
        }
        $lastLfIdx = -1
        for ($bi = $totalRead - 1; $bi -ge $decodeStart; $bi--) {
            if ($buf[$bi] -eq 10) {
                $lastLfIdx = $bi
                break
            }
        }
        if ($lastLfIdx -lt 0) {
            return @{ ok = $true; has_lines = $false; delta = '' }
        }
        $decodeLen = $lastLfIdx - $decodeStart
        $State.byte_offset = $offset + $lastLfIdx + 1
        $text = if ($decodeLen -gt 0) { [System.Text.Encoding]::UTF8.GetString($buf, $decodeStart, $decodeLen) } else { '' }
        return @{ ok = $true; has_lines = $true; delta = $text }
    }
    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        return @{ ok = $false; has_lines = $false; delta = '' }
    }
    $State.last_file_length = $fileLen
    if (-not $raw) {
        return @{ ok = $true; has_lines = $false; delta = '' }
    }
    $rawStr = [string]$raw
    $charOff = [int]$State.processed_char_offset
    if ($charOff -gt $rawStr.Length) {
        $charOff = 0
        $State.pending_data = @()
    }
    if ($charOff -eq 0 -and $rawStr.Length -gt 0 -and [int][char]$rawStr[0] -eq 0xFEFF) {
        $charOff = 1
    }
    if ($charOff -ge $rawStr.Length) {
        $State.processed_char_offset = $rawStr.Length
        return @{ ok = $true; has_lines = $false; delta = '' }
    }
    $slice = $rawStr.Substring($charOff)
    if ($Final) {
        $State.processed_char_offset = $rawStr.Length
        return @{ ok = $true; has_lines = $true; delta = $slice }
    }
    $lastNl = $slice.LastIndexOf("`n")
    if ($lastNl -lt 0) {
        return @{ ok = $true; has_lines = $false; delta = '' }
    }
    $State.processed_char_offset = $charOff + $lastNl + 1
    $delta = $slice.Substring(0, $lastNl)
    return @{ ok = $true; has_lines = $true; delta = $delta }
}

function Step-AgentLiveStreamFile {
    param(
        [string]$Path,
        [hashtable]$State,
        [string]$ShowReasoning = $script:ShowReasoning,
        [switch]$Final,
        [scriptblock]$OnBeforeFirstOutput = $null
    )
    if (-not $Path -or -not $State -or $script:OutputMode -eq 'json') { return $false }
    $readRes = Read-AgentLiveStreamDeltaText -Path $Path -State $State -Final:$Final
    if (-not $readRes.ok) { return $false }
    if ((-not $readRes.has_lines) -and (-not ($Final -and $State.pending_data.Count -gt 0))) {
        return $false
    }
    $lines = @()
    if ($readRes.has_lines) {
        $normDelta = ([string]$readRes.delta).Replace("`r`n", "`n")
        $lines = @($normDelta -split "`n")
    }
    $emitted = $false
    $flushEvent = {
        param([string]$Payload)
        $trimmed = $Payload.Trim()
        if (-not $trimmed -or $trimmed -ceq '[DONE]') { return }
        if (-not $trimmed.StartsWith('{')) { return }
        $ev = $null
        try { $ev = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { return }
        if (-not (Test-IsJsonObject -Value $ev)) { return }
        if ($null -eq $ev.choices -or $ev.choices -isnot [array] -or $ev.choices.Count -eq 0) { return }
        $ch = $ev.choices[0]
        if (-not (Test-IsJsonObject -Value $ch) -or (-not (Test-IsJsonObject -Value $ch.delta))) { return }
        $delta = $ch.delta
        $dProps = @(Get-ObjectPropertyNames -InputObject $delta)
        if (($dProps -contains 'reasoning_content') -and $delta.reasoning_content -is [string] -and $delta.reasoning_content.Length -gt 0) {
            if ($ShowReasoning -eq 'full') {
                if ((-not $State.saw_any_output) -and ($null -ne $OnBeforeFirstOutput)) {
                    & $OnBeforeFirstOutput
                }
                Write-AgentLiveStreamDelta -State $State -Kind 'reasoning' -Delta $delta.reasoning_content
                $emitted = $true
            }
            elseif ($ShowReasoning -eq 'compact') {
                if ($null -eq $State.pending_reasoning_parts) { $State.pending_reasoning_parts = @() }
                $State.pending_reasoning_parts += $delta.reasoning_content
            }
        }
        if (($dProps -contains 'content') -and $delta.content -is [string] -and $delta.content.Length -gt 0) {
            if ($ShowReasoning -eq 'compact' -and $State.pending_reasoning_parts -and $State.pending_reasoning_parts.Count -gt 0) {
                $compactReas = ($State.pending_reasoning_parts -join '')
                $State.pending_reasoning_parts = @()
                if ($compactReas.Trim()) {
                    if ((-not $State.saw_any_output) -and ($null -ne $OnBeforeFirstOutput)) {
                        & $OnBeforeFirstOutput
                    }
                    if ($State.active_section -eq 'content') {
                        Flush-AgentLiveContentSection -State $State
                    }
                    Write-AgentReasoning -Text $compactReas -ViewMode 'compact'
                    $State.streamed_reasoning = $true
                    $State.saw_any_output = $true
                    $emitted = $true
                }
            }
            if ((-not $State.saw_any_output) -and ($null -ne $OnBeforeFirstOutput)) {
                & $OnBeforeFirstOutput
            }
            Write-AgentLiveStreamDelta -State $State -Kind 'content' -Delta $delta.content
            $emitted = $true
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        if ($line.Length -eq 0) {
            if ($State.pending_data.Count -gt 0) {
                $payload = ($State.pending_data -join "`n")
                $State.pending_data = @()
                . $flushEvent -Payload $payload
            }
            continue
        }
        if ($line.StartsWith(':')) { continue }
        if ($line.StartsWith('data:')) {
            $dVal = $line.Substring(5)
            if ($dVal.StartsWith(' ')) { $dVal = $dVal.Substring(1) }
            $State.pending_data += $dVal
        }
    }
    if ($Final -and $State.pending_data.Count -gt 0) {
        $payload = ($State.pending_data -join "`n")
        $State.pending_data = @()
        . $flushEvent -Payload $payload
    }
    return $emitted
}

function Wait-AgentProcessWithSpinner {
    param(
        $Process,
        [string]$StatusLabel = 'Waiting for model',
        [int]$TimeoutSec = $script:RequestTimeoutSec,
        [int]$PollMs = 200,
        [string]$ResponsePath,
        [switch]$LiveStream,
        [string]$DoneMarkerPath = ''
    )
    $frames = @('|', '/', '-', '\')
    $startWait = Get-Date
    $spinState = @{
        show = (($script:OutputMode -ne 'json') -and (-not $script:HideSpinner))
        frame_idx = 0
        last_vis_len = 0
    }
    $liveStreamActive = ($LiveStream -and $script:StreamRequests -and ($script:OutputMode -ne 'json') -and [bool]$ResponsePath)
    $liveState = if ($liveStreamActive) { New-AgentLiveStreamState } else { $null }
    $jobCompleted = $false
    $pollIter = 0
    $clearSpinnerLine = {
        if ($spinState.show -and $spinState.frame_idx -gt 0) {
            $clearWidth = if ($spinState.last_vis_len -gt 0) { $spinState.last_vis_len } else { $StatusLabel.Length + 28 }
            $clearLine = "`r" + (' ' * $clearWidth) + "`r"
            Write-Host $clearLine -NoNewline
            $spinState.frame_idx = 0
        }
        $spinState.show = $false
    }
    try {
        while ((-not $Process.HasExited) -and (-not ($DoneMarkerPath -and (Test-Path -LiteralPath $DoneMarkerPath -PathType Leaf)))) {
            if ($ResponsePath) { Assert-AgentApiResponseSize -Path $ResponsePath }
            if ($liveStreamActive) {
                $null = Step-AgentLiveStreamFile -Path $ResponsePath -State $liveState -ShowReasoning $script:ShowReasoning -OnBeforeFirstOutput $clearSpinnerLine
            }
            $elapsed = ((Get-Date) - $startWait).TotalSeconds
            if ($spinState.show) {
                $spinChar = $frames[$spinState.frame_idx % $frames.Count]
                $spinState.frame_idx++
                $maxSpinW = (Get-TerminalWidth) - 1
                if ($maxSpinW -lt 20) { $maxSpinW = 20 }
                $rawSpinLine = $script:Gm.Grey1 + ("  [{0}] {1} ({2})..." -f $spinChar, (Format-TuiText $StatusLabel), (Format-AgentSeconds -Seconds $elapsed)) + $script:Gm.Reset
                $clampedSpinLine = Limit-AnsiLineToWidth -Text $rawSpinLine -MaxWidth $maxSpinW
                $spinState.last_vis_len = (Strip-AnsiCodes -Text $clampedSpinLine).Length
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
            $sleepMs = $PollMs
            if ($DoneMarkerPath -and $pollIter -lt 4 -and $sleepMs -gt 25) {
                $sleepMs = 25
            }
            $pollIter++
            Start-Sleep -Milliseconds $sleepMs
        }
        $completedOk = $false
        if ($DoneMarkerPath) {
            if (Test-Path -LiteralPath $DoneMarkerPath -PathType Leaf) {
                $jobCompleted = $true
                try {
                    $doneRaw = Get-Content -LiteralPath $DoneMarkerPath -Raw -Encoding UTF8 -ErrorAction Stop
                    $doneObj = $doneRaw | ConvertFrom-Json -ErrorAction Stop
                    if ((Test-IsJsonObject -Value $doneObj) -and $doneObj.ok -eq $true) {
                        $completedOk = $true
                    }
                }
                catch {
                    $completedOk = $false
                }
            }
        }
        else {
            $completedOk = ($null -eq $Process.ExitCode -or [int]$Process.ExitCode -eq 0)
        }
        if ($liveStreamActive -and $liveState.saw_any_output -and $completedOk) {
            $null = Step-AgentLiveStreamFile -Path $ResponsePath -State $liveState -ShowReasoning $script:ShowReasoning -Final -OnBeforeFirstOutput $clearSpinnerLine
        }
    }
    finally {
        if ($spinState.show -and $spinState.frame_idx -gt 0) {
            $clearWidth = if ($spinState.last_vis_len -gt 0) { $spinState.last_vis_len } else { $StatusLabel.Length + 28 }
            $clearLine = "`r" + (' ' * $clearWidth) + "`r"
            Write-Host $clearLine -NoNewline
        }
        if ($liveStreamActive -and $liveState) {
            Close-AgentLiveStream -State $liveState -ShowReasoning $script:ShowReasoning
            $script:LastHttpStreamedContent = [bool]$liveState.streamed_content
            $script:LastHttpStreamedReasoning = [bool]$liveState.streamed_reasoning
        }
        if ((-not ($DoneMarkerPath -and $jobCompleted)) -and (-not $Process.HasExited)) {
            Stop-Process -InputObject $Process -Force -ErrorAction SilentlyContinue
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -InputObject $Process -Timeout 2 -ErrorAction SilentlyContinue
        }
    }
}

function New-AgentPrivateWorkerDir {
    $baseTmp = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TMP) { $env:TMP } else { '/tmp' }
    if ($env:OS -ne 'Windows_NT' -and (Test-PathHasReparsePoint -Path $baseTmp)) {
        $physicalCand = '/private' + $baseTmp
        if ((Test-Path -LiteralPath $physicalCand) -and (-not (Test-PathHasReparsePoint -Path $physicalCand))) {
            $baseTmp = $physicalCand
        }
    }
    if (-not (Test-Path -LiteralPath $baseTmp)) {
        try { New-Item -ItemType Directory -Path $baseTmp -Force -ErrorAction Stop | Out-Null }
        catch { return '' }
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $r1 = Get-Random -Minimum 100000 -Maximum 999999
        $r2 = Get-Random -Minimum 100000 -Maximum 999999
        $cand = Join-Path $baseTmp ("shellossus-httpw-$PID-$r1-$r2")
        if (-not (Test-Path -LiteralPath $cand)) {
            $dir = $null
            try {
                $dir = New-Item -ItemType Directory -Path $cand -ErrorAction Stop
                if ($env:OS -ne 'Windows_NT') {
                    Set-ItemProperty -LiteralPath $dir.FullName -Name UnixFileMode -Value 448 -ErrorAction Stop
                    $dirCheck = Get-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                    if ($null -eq $dirCheck.UnixFileMode -or (([int]$dirCheck.UnixFileMode -band 63) -ne 0)) {
                        throw 'Private worker directory mode check failed.'
                    }
                }
                if (-not (Test-AgentConfigPrivacy -Path (Join-Path $dir.FullName 'probe') -ParentOnly)) {
                    throw 'Private worker directory privacy check failed.'
                }
                return [string]$dir.FullName
            }
            catch {
                if ($dir -and $dir.FullName) {
                    Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                return ''
            }
        }
    }
    return ''
}

function Stop-AgentPersistentHttpWorker {
    $w = $script:PersistentHttpWorker
    $script:PersistentHttpWorker = $null
    if ($null -eq $w) { return }
    try {
        if ($w.queue_dir -and (Test-Path -LiteralPath $w.queue_dir -PathType Container)) {
            $stopTmp = Join-Path $w.queue_dir 'stop.tmp'
            $stopFlag = Join-Path $w.queue_dir 'stop.flag'
            try {
                Set-AgentUtf8Content -LiteralPath $stopTmp -Value 'stop'
                Move-Item -LiteralPath $stopTmp -Destination $stopFlag -Force -ErrorAction SilentlyContinue
            }
            catch {}
        }
        if ($w.proc) {
            for ($wi = 0; $wi -lt 8; $wi++) {
                if ($w.proc.HasExited) { break }
                Start-Sleep -Milliseconds 50
            }
            if (-not $w.proc.HasExited) {
                Stop-Process -InputObject $w.proc -Force -ErrorAction SilentlyContinue
                if ($w.proc_id -gt 0) {
                    Stop-Process -Id $w.proc_id -Force -ErrorAction SilentlyContinue
                }
                Wait-Process -InputObject $w.proc -Timeout 2 -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
    finally {
        if ($w.queue_dir -and (Test-Path -LiteralPath $w.queue_dir)) {
            Remove-Item -LiteralPath $w.queue_dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($w.stdout_file) { Remove-Item -LiteralPath $w.stdout_file -Force -ErrorAction SilentlyContinue }
        if ($w.stderr_file) { Remove-Item -LiteralPath $w.stderr_file -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AgentPersistentHttpWorker {
    param(
        [string]$ShellExe,
        [string]$WorkerScript,
        [string]$ApiKey,
        [string]$AuthHeaderName,
        [AllowEmptyString()][string]$ExtraHeadersJson = ''
    )
    $effAuth = if ($AuthHeaderName) { $AuthHeaderName } else { 'Authorization' }
    $fingerprint = "$WorkerScript|$effAuth|$ApiKey|$ExtraHeadersJson"
    $existing = $script:PersistentHttpWorker
    if ($null -ne $existing) {
        $alive = $false
        try { $alive = ($null -ne $existing.proc) -and (-not $existing.proc.HasExited) } catch { $alive = $false }
        if ($alive -and ($existing.auth_fingerprint -ceq $fingerprint) -and $existing.queue_dir -and (Test-Path -LiteralPath $existing.queue_dir -PathType Container) -and (-not (Test-PathHasReparsePoint -Path $existing.queue_dir))) {
            return $existing
        }
        Stop-AgentPersistentHttpWorker
    }
    $queueDir = New-AgentPrivateWorkerDir
    if (-not $queueDir) { return $null }
    $stdoutTemp = New-AgentTempFile
    $stderrTemp = New-AgentTempFile
    try {
        $argList = Get-AgentWorkerArguments -ScriptPath $WorkerScript -WorkerMode 'http'
        $parentTicks = Get-AgentProcessStartTicks -ProcessId $PID
        $proc = Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_HTTP_QUEUE_DIR = $queueDir
            SHELLOSSUS_HTTP_PARENT_PID = [string]$PID
            SHELLOSSUS_HTTP_PARENT_TICKS = [string]$parentTicks
            SHELLOSSUS_HTTP_IDLE_SEC = '900'
            SHELLOSSUS_API_KEY = $ApiKey
            OPENAI_API_KEY = $null
            SHELLOSSUS_HTTP_AUTH_HEADER = $effAuth
            SHELLOSSUS_HTTP_EXTRA_HEADERS = $(if ($ExtraHeadersJson) { $ExtraHeadersJson } else { $null })
        } -Action {
            Start-Process -FilePath $ShellExe -ArgumentList $argList -RedirectStandardOutput $stdoutTemp.FullName -RedirectStandardError $stderrTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
        }
        $procId = 0
        try { $procId = [int]$proc.Id } catch { $procId = 0 }
        $worker = @{
            proc = $proc
            proc_id = $procId
            queue_dir = $queueDir
            stdout_file = $stdoutTemp.FullName
            stderr_file = $stderrTemp.FullName
            auth_fingerprint = $fingerprint
            worker_script = $WorkerScript
            seq = 0
        }
        $script:PersistentHttpWorker = $worker
        return $worker
    }
    catch {
        Remove-Item -LiteralPath $queueDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutTemp.FullName, $stderrTemp.FullName -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Invoke-InternalHttpSingleRequest {
    param(
        [string]$Uri,
        [string]$InFile,
        [string]$OutFile,
        [string]$ErrFile,
        [string]$MetaFile,
        [int]$TimeoutSec = 180,
        [bool]$AcceptSse = $false,
        [string]$ApiKey = '',
        [string]$AuthHeaderName = 'Authorization',
        [hashtable]$ExtraHeaders = @{}
    )
    try {
        if (-not $Uri) { throw 'HTTP worker URI is required.' }
        if (-not $InFile) { throw 'HTTP worker input file is required.' }
        if (-not $OutFile) { throw 'HTTP worker output file is required.' }
        $workerHeaders = New-AgentApiHeaders -ApiKey $ApiKey -AuthHeaderName $AuthHeaderName -ExtraHeaders $ExtraHeaders -AcceptSse:$AcceptSse
        $null = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $Uri -Method 'Post' -Headers $workerHeaders -ContentType 'application/json; charset=utf-8' -InFile $InFile -OutFile $OutFile -MaximumRedirection 0 -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return $true
    }
    catch {
        $errRec = $_
        $msg = [string]$errRec.Exception.Message
        $details = $null
        if ($errRec.ErrorDetails -and $errRec.ErrorDetails.Message) {
            $details = ([string]$errRec.ErrorDetails.Message).Trim()
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
        if ($MetaFile) {
            try {
                $retryAfterSec = Get-AgentRetryAfterSeconds -ErrorRecord $errRec
                if ($null -ne $retryAfterSec) {
                    Set-AgentUtf8Content -LiteralPath $MetaFile -Value (@{ retry_after_sec = [int]$retryAfterSec } | ConvertTo-Json -Compress)
                }
            }
            catch {}
        }
        if ($ErrFile) {
            $msg = Protect-AgentHeaderSecrets -Text $msg -ApiKey $ApiKey -ExtraHeaders $ExtraHeaders
            Set-AgentUtf8Content -LiteralPath $ErrFile -Value $msg
        }
        return $false
    }
}

function Invoke-InternalHttpWorkerLoop {
    param(
        [string]$QueueDir,
        [string]$ApiKey,
        [string]$AuthHeaderName,
        [hashtable]$ExtraHeaders
    )
    if (-not $QueueDir -or (-not (Test-Path -LiteralPath $QueueDir -PathType Container)) -or (Test-PathHasReparsePoint -Path $QueueDir)) {
        throw 'Invalid HTTP worker queue directory.'
    }
    $parentPid = 0
    if ($env:SHELLOSSUS_HTTP_PARENT_PID -and $env:SHELLOSSUS_HTTP_PARENT_PID -match '^\d+$') {
        $parentPid = [int]$env:SHELLOSSUS_HTTP_PARENT_PID
    }
    $parentTicks = [long]0
    if ($env:SHELLOSSUS_HTTP_PARENT_TICKS -and $env:SHELLOSSUS_HTTP_PARENT_TICKS -match '^\d+$') {
        $parentTicks = [long]$env:SHELLOSSUS_HTTP_PARENT_TICKS
    }
    $idleSec = 900
    if ($env:SHELLOSSUS_HTTP_IDLE_SEC -and $env:SHELLOSSUS_HTTP_IDLE_SEC -match '^\d+$') {
        $idleSec = [int]$env:SHELLOSSUS_HTTP_IDLE_SEC
        if ($idleSec -lt 1) { $idleSec = 1 }
    }
    $nextSeq = 1
    $lastActivity = Get-Date
    $lastParentCheck = Get-Date
    $stopFlagPath = Join-Path $QueueDir 'stop.flag'
    while ($true) {
        $jobPath = Join-Path $QueueDir ("job-$nextSeq.json")
        if (Test-Path -LiteralPath $jobPath -PathType Leaf) {
            $jobItem = Get-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue
            if ($null -eq $jobItem -or $jobItem.PSIsContainer -or (($jobItem.Attributes -band 1024) -ne 0)) {
                throw 'Unsafe HTTP worker job file.'
            }
            $jobRaw = Get-Content -LiteralPath $jobPath -Raw -Encoding UTF8 -ErrorAction Stop
            Remove-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue
            $job = $jobRaw | ConvertFrom-Json -ErrorAction Stop
            $jobTimeout = if ($null -ne $job.timeout_sec) { [int]$job.timeout_sec } else { 180 }
            $jobStream = [bool]($job.stream -eq $true)
            $jobOk = Invoke-InternalHttpSingleRequest `
                -Uri ([string]$job.uri) `
                -InFile ([string]$job.in_file) `
                -OutFile ([string]$job.out_file) `
                -ErrFile ([string]$job.err_file) `
                -MetaFile ([string]$job.meta_file) `
                -TimeoutSec $jobTimeout `
                -AcceptSse $jobStream `
                -ApiKey $ApiKey `
                -AuthHeaderName $AuthHeaderName `
                -ExtraHeaders $ExtraHeaders
            $doneTmp = Join-Path $QueueDir ("done-$nextSeq.tmp")
            $donePath = Join-Path $QueueDir ("done-$nextSeq.json")
            Set-AgentUtf8Content -LiteralPath $doneTmp -Value (@{ seq = $nextSeq; ok = [bool]$jobOk } | ConvertTo-Json -Compress)
            Move-Item -LiteralPath $doneTmp -Destination $donePath -Force -ErrorAction Stop
            $nextSeq++
            $lastActivity = Get-Date
            continue
        }
        if (Test-Path -LiteralPath $stopFlagPath) { break }
        $now = Get-Date
        if ($parentPid -gt 0 -and ($now - $lastParentCheck).TotalSeconds -ge 1) {
            $pLive = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
            if ($null -eq $pLive) { break }
            if ($parentTicks -gt 0) {
                $liveTicks = Get-AgentProcessStartTicks -ProcessId $parentPid
                if ($liveTicks -gt 0 -and $liveTicks -ne $parentTicks) { break }
            }
            $lastParentCheck = $now
        }
        if (($now - $lastActivity).TotalSeconds -ge $idleSec) { break }
        Start-Sleep -Milliseconds 15
    }
}

function Invoke-InternalHttpWorker {
    $script:InternalWorkerFailed = $false
    $workerAuthHdr = 'Authorization'
    $workerExtraHdrs = @{}
    try {
        if ($env:SHELLOSSUS_HTTP_AUTH_HEADER) {
            $workerAuthHdr = ConvertTo-AgentAuthHeaderName -HeaderSpec $env:SHELLOSSUS_HTTP_AUTH_HEADER
        }
        if ($env:SHELLOSSUS_HTTP_EXTRA_HEADERS) {
            $workerExtraHdrs = ConvertFrom-AgentExtraHeaders -HeadersSpec $env:SHELLOSSUS_HTTP_EXTRA_HEADERS -AuthHeaderName $workerAuthHdr
        }
        if ($env:SHELLOSSUS_HTTP_QUEUE_DIR) {
            Invoke-InternalHttpWorkerLoop -QueueDir $env:SHELLOSSUS_HTTP_QUEUE_DIR -ApiKey ([string]$env:SHELLOSSUS_API_KEY) -AuthHeaderName $workerAuthHdr -ExtraHeaders $workerExtraHdrs
            return
        }
        $timeoutVal = if ($env:SHELLOSSUS_HTTP_TIMEOUT) { [int]$env:SHELLOSSUS_HTTP_TIMEOUT } else { 180 }
        $ok = Invoke-InternalHttpSingleRequest `
            -Uri ([string]$env:SHELLOSSUS_HTTP_URI) `
            -InFile ([string]$env:SHELLOSSUS_HTTP_IN) `
            -OutFile ([string]$env:SHELLOSSUS_HTTP_OUT) `
            -ErrFile ([string]$env:SHELLOSSUS_HTTP_ERR) `
            -MetaFile ([string]$env:SHELLOSSUS_HTTP_META) `
            -TimeoutSec $timeoutVal `
            -AcceptSse ($env:SHELLOSSUS_HTTP_STREAM -eq '1') `
            -ApiKey ([string]$env:SHELLOSSUS_API_KEY) `
            -AuthHeaderName $workerAuthHdr `
            -ExtraHeaders $workerExtraHdrs
        if (-not $ok) { $script:InternalWorkerFailed = $true }
    }
    catch {
        $msg = Protect-AgentHeaderSecrets -Text ([string]$_.Exception.Message) -ApiKey ([string]$env:SHELLOSSUS_API_KEY) -ExtraHeaders $workerExtraHdrs
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
        [switch]$ForceBackgroundWorker,
        [switch]$LiveStream
    )
    $script:LastHttpRetryAfterSec = $null
    $script:LastHttpStreamedContent = $false
    $script:LastHttpStreamedReasoning = $false
    if ($LiveStream -and $OutFile -and (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        Set-AgentUtf8Content -LiteralPath $OutFile -Value ''
    }
    $asciiBody = ConvertTo-AsciiJson -Json $Body
    $iwrCmd = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ((-not $ForceBackgroundWorker) -and (($iwrCmd -and $iwrCmd.CommandType -eq 'Function') -or $script:DisableAsyncHttp)) {
        $reqHeaders = New-AgentApiHeaders -ApiKey $ApiKey -AuthHeaderName $script:AuthHeaderName -ExtraHeaders $script:ExtraHttpHeaders -AcceptSse:([bool]$script:StreamRequests)
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
            $script:LastHttpRetryAfterSec = Get-AgentRetryAfterSeconds -ErrorRecord $_
            $message = Format-AgentError -ErrorRecord $_
            $message = Protect-AgentHeaderSecrets -Text $message -ApiKey $ApiKey -ExtraHeaders $script:ExtraHttpHeaders
            throw (Format-TuiText $message)
        }
        Assert-AgentApiResponseSize -Path $OutFile
        return
    }
    $shellExe = Get-AgentPowerShellExecutable
    $workerScript = Resolve-StandaloneScriptPath -Required
    $reqTemp = New-AgentTempFile
    $errTemp = New-AgentTempFile
    $metaTemp = New-AgentTempFile
    $stdoutTemp = $null
    $stderrTemp = $null
    try {
        Set-Content -LiteralPath $reqTemp.FullName -Value $asciiBody -Encoding Ascii -NoNewline -ErrorAction Stop
        $authHdrVal = if ($script:AuthHeaderName) { [string]$script:AuthHeaderName } else { 'Authorization' }
        $extraHdrJson = if ($script:ExtraHttpHeaders -and $script:ExtraHttpHeaders.Count -gt 0) {
            ConvertTo-AsciiJson -Json ($script:ExtraHttpHeaders | ConvertTo-Json -Compress)
        }
        else { $null }
        $spCmd = Get-Command -Name 'Start-Process' -ErrorAction SilentlyContinue
        $canUsePersistent = (-not $script:DisablePersistentHttpWorker) -and (-not ($spCmd -and $spCmd.CommandType -eq 'Function'))
        $persistentWorker = $null
        if ($canUsePersistent) {
            $persistentWorker = Get-AgentPersistentHttpWorker -ShellExe $shellExe -WorkerScript $workerScript -ApiKey $ApiKey -AuthHeaderName $authHdrVal -ExtraHeadersJson $(if ($extraHdrJson) { $extraHdrJson } else { '' })
        }
        if ($null -ne $persistentWorker) {
            $persistentWorker.seq = [int]$persistentWorker.seq + 1
            $seq = [int]$persistentWorker.seq
            $jobTmp = Join-Path $persistentWorker.queue_dir ("job-$seq.tmp")
            $jobPath = Join-Path $persistentWorker.queue_dir ("job-$seq.json")
            $donePath = Join-Path $persistentWorker.queue_dir ("done-$seq.json")
            $jobObj = @{
                seq = $seq
                uri = $Uri
                in_file = $reqTemp.FullName
                out_file = $OutFile
                err_file = $errTemp.FullName
                meta_file = $metaTemp.FullName
                timeout_sec = [int]$TimeoutSec
                stream = [bool]$script:StreamRequests
            }
            $jobOk = $false
            try {
                Set-AgentUtf8Content -LiteralPath $jobTmp -Value (ConvertTo-AsciiJson -Json ($jobObj | ConvertTo-Json -Compress))
                Move-Item -LiteralPath $jobTmp -Destination $jobPath -Force -ErrorAction Stop
                Wait-AgentProcessWithSpinner -Process $persistentWorker.proc -StatusLabel $StatusLabel -TimeoutSec $TimeoutSec -ResponsePath $OutFile -LiveStream:$LiveStream -DoneMarkerPath $donePath
                if (Test-Path -LiteralPath $donePath -PathType Leaf) {
                    $doneRaw = Get-Content -LiteralPath $donePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $donePath -Force -ErrorAction SilentlyContinue
                    try {
                        $doneObj = $doneRaw | ConvertFrom-Json -ErrorAction Stop
                        $jobOk = [bool]($doneObj.ok -eq $true)
                    }
                    catch { $jobOk = $false }
                }
                else {
                    $wStderr = ''
                    if ($persistentWorker.stderr_file -and (Test-Path -LiteralPath $persistentWorker.stderr_file)) {
                        $wStderr = Get-Content -LiteralPath $persistentWorker.stderr_file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    }
                    $wExitCode = $persistentWorker.proc.ExitCode
                    Stop-AgentPersistentHttpWorker
                    if ($wStderr -and $wStderr.Trim()) {
                        $wStderr = Protect-AgentHeaderSecrets -Text $wStderr -ApiKey $ApiKey -ExtraHeaders $script:ExtraHttpHeaders
                        throw (Format-TuiText $wStderr.Trim())
                    }
                    throw "HTTP worker exited unexpectedly (code $wExitCode)."
                }
            }
            catch {
                Remove-Item -LiteralPath $jobTmp, $jobPath, $donePath -Force -ErrorAction SilentlyContinue
                if ($null -ne $script:PersistentHttpWorker) {
                    Stop-AgentPersistentHttpWorker
                }
                throw
            }
            $metaItem = Get-Item -LiteralPath $metaTemp.FullName -Force -ErrorAction SilentlyContinue
            if ($metaItem -and $metaItem.Length -gt 0 -and $metaItem.Length -le 1024) {
                try {
                    $metaRaw = Get-Content -LiteralPath $metaTemp.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    $metaObj = $metaRaw | ConvertFrom-Json -ErrorAction Stop
                    if ((Test-IsJsonObject -Value $metaObj) -and $null -ne $metaObj.retry_after_sec) {
                        $script:LastHttpRetryAfterSec = ConvertFrom-AgentRetryAfterValue -Value $metaObj.retry_after_sec
                    }
                }
                catch {}
            }
            Assert-AgentApiResponseSize -Path $OutFile
            $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
            if ($errItem -and $errItem.Length -gt 0) {
                $errText = Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($errText) {
                    $errText = Protect-AgentHeaderSecrets -Text $errText -ApiKey $ApiKey -ExtraHeaders $script:ExtraHttpHeaders
                    throw (Format-TuiText $errText.Trim())
                }
            }
            if (-not $jobOk) {
                throw 'HTTP worker request failed.'
            }
            return
        }
        $stdoutTemp = New-AgentTempFile
        $stderrTemp = New-AgentTempFile
        $argList = Get-AgentWorkerArguments -ScriptPath $workerScript -WorkerMode 'http'
        $proc = Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_HTTP_URI = $Uri
            SHELLOSSUS_API_KEY = $ApiKey
            OPENAI_API_KEY = $null
            SHELLOSSUS_HTTP_IN = $reqTemp.FullName
            SHELLOSSUS_HTTP_OUT = $OutFile
            SHELLOSSUS_HTTP_ERR = $errTemp.FullName
            SHELLOSSUS_HTTP_META = $metaTemp.FullName
            SHELLOSSUS_HTTP_TIMEOUT = [string]$TimeoutSec
            SHELLOSSUS_HTTP_STREAM = $(if ($script:StreamRequests) { '1' } else { '0' })
            SHELLOSSUS_HTTP_AUTH_HEADER = $authHdrVal
            SHELLOSSUS_HTTP_EXTRA_HEADERS = $extraHdrJson
        } -Action {
            Start-Process -FilePath $shellExe -ArgumentList $argList -RedirectStandardOutput $stdoutTemp.FullName -RedirectStandardError $stderrTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
        }
        Wait-AgentProcessWithSpinner -Process $proc -StatusLabel $StatusLabel -TimeoutSec $TimeoutSec -ResponsePath $OutFile -LiveStream:$LiveStream
        $metaItem = Get-Item -LiteralPath $metaTemp.FullName -Force -ErrorAction SilentlyContinue
        if ($metaItem -and $metaItem.Length -gt 0 -and $metaItem.Length -le 1024) {
            try {
                $metaRaw = Get-Content -LiteralPath $metaTemp.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $metaObj = $metaRaw | ConvertFrom-Json -ErrorAction Stop
                if ((Test-IsJsonObject -Value $metaObj) -and $null -ne $metaObj.retry_after_sec) {
                    $script:LastHttpRetryAfterSec = ConvertFrom-AgentRetryAfterValue -Value $metaObj.retry_after_sec
                }
            }
            catch {}
        }
        Assert-AgentApiResponseSize -Path $OutFile
        $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        if ($errItem -and $errItem.Length -gt 0) {
            $errText = Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($errText) {
                $errText = Protect-AgentHeaderSecrets -Text $errText -ApiKey $ApiKey -ExtraHeaders $script:ExtraHttpHeaders
                throw (Format-TuiText $errText.Trim())
            }
        }
        if ($null -ne $proc.ExitCode -and [int]$proc.ExitCode -ne 0) {
            $stdErrText = Get-Content -LiteralPath $stderrTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($stdErrText -and $stdErrText.Trim()) {
                $stdErrText = Protect-AgentHeaderSecrets -Text $stdErrText -ApiKey $ApiKey -ExtraHeaders $script:ExtraHttpHeaders
                throw (Format-TuiText $stdErrText.Trim())
            }
            throw "HTTP worker exited with code $($proc.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $reqTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $metaTemp.FullName -Force -ErrorAction SilentlyContinue
        if ($stdoutTemp) { Remove-Item -LiteralPath $stdoutTemp.FullName -Force -ErrorAction SilentlyContinue }
        if ($stderrTemp) { Remove-Item -LiteralPath $stderrTemp.FullName -Force -ErrorAction SilentlyContinue }
    }
}
