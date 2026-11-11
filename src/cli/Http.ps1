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

function Read-AgentApiResponse {
    param([string]$Path)
    Assert-AgentApiResponseSize -Path $Path
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
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
        $null = Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $env:SHELLOSSUS_HTTP_URI -Method 'Post' -Headers @{ Authorization = ('Bearer ' + $env:SHELLOSSUS_API_KEY) } -ContentType 'application/json; charset=utf-8' -InFile $env:SHELLOSSUS_HTTP_IN -OutFile $env:SHELLOSSUS_HTTP_OUT -MaximumRedirection 0 -TimeoutSec $timeoutVal -UseBasicParsing -ErrorAction Stop
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
        $request = @{
            Uri = $Uri
            Method = 'Post'
            Headers = @{ Authorization = "Bearer $ApiKey" }
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
