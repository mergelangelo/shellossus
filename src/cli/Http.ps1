# Pure-ASCII JSON payload escaping, JSONL event output, spinner wait loop, and async HTTP worker.

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

function Wait-AgentProcessWithSpinner {
    param($Process, [string]$StatusLabel = 'Waiting for model', [int]$TimeoutSec = 180, [int]$PollMs = 200)
    $frames = @('|', '/', '-', '\')
    $frameIdx = 0
    $startWait = Get-Date
    $showSpinner = ($script:OutputMode -ne 'json') -and (-not $script:HideSpinner)
    $lastSpinVisLen = 0
    try {
        while (-not $Process.HasExited) {
            $elapsed = ((Get-Date) - $startWait).TotalSeconds
            if ($showSpinner) {
                $spinChar = $frames[$frameIdx % $frames.Count]
                $frameIdx++
                $maxSpinW = (Get-TerminalWidth) - 1
                if ($maxSpinW -lt 20) { $maxSpinW = 20 }
                $rawSpinLine = $script:Gm.Grey1 + ("  [{0}] {1} ({2:0.0}s)..." -f $spinChar, $StatusLabel, $elapsed) + $script:Gm.Reset
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

function Invoke-AgentHttpRequest {
    param(
        [string]$Uri,
        [string]$ApiKey,
        [string]$Body,
        [string]$OutFile,
        [int]$TimeoutSec = 180,
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
        Invoke-WebRequest @request -UseBasicParsing -OutFile $OutFile
        return
    }
    $shellExe = (Get-AgentEnvironment).shell_exe
    $reqTemp = New-AgentTempFile
    $errTemp = New-AgentTempFile
    $stdoutTemp = New-AgentTempFile
    $stderrTemp = New-AgentTempFile
    try {
        Set-Content -LiteralPath $reqTemp.FullName -Value $asciiBody -Encoding Ascii -NoNewline -ErrorAction Stop
        $workerCmd = @'
$ErrorActionPreference = 'Stop'
try {
    Invoke-WebRequest -Uri $env:SHELLOSSUS_HTTP_URI -Method 'Post' -Headers @{ Authorization = ('Bearer ' + $env:SHELLOSSUS_HTTP_KEY) } -ContentType 'application/json; charset=utf-8' -InFile $env:SHELLOSSUS_HTTP_IN -OutFile $env:SHELLOSSUS_HTTP_OUT -MaximumRedirection 0 -TimeoutSec ([int]$env:SHELLOSSUS_HTTP_TIMEOUT) -UseBasicParsing -ErrorAction Stop
}
catch {
    $msg = $_.Exception.Message
    $details = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        $details = $_.ErrorDetails.Message.Trim()
    }
    if ($details) {
        try {
            $parsed = $details | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error -and $parsed.error.message) { $details = [string]$parsed.error.message }
        }
        catch {}
        if ($details.Length -gt 300) { $details = $details.Substring(0, 300) + '...' }
        $msg = $msg + ' (' + $details + ')'
    }
    Set-Content -LiteralPath $env:SHELLOSSUS_HTTP_ERR -Value $msg -Encoding UTF8 -NoNewline
    exit 1
}
'@
        $argList = Get-AgentCommandArguments -CommandText $workerCmd
        $proc = Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_HTTP_URI = $Uri
            SHELLOSSUS_HTTP_KEY = $ApiKey
            SHELLOSSUS_HTTP_IN = $reqTemp.FullName
            SHELLOSSUS_HTTP_OUT = $OutFile
            SHELLOSSUS_HTTP_ERR = $errTemp.FullName
            SHELLOSSUS_HTTP_TIMEOUT = [string]$TimeoutSec
        } -Action {
            Start-Process -FilePath $shellExe -ArgumentList $argList -RedirectStandardOutput $stdoutTemp.FullName -RedirectStandardError $stderrTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
        }
        Wait-AgentProcessWithSpinner -Process $proc -StatusLabel $StatusLabel -TimeoutSec $TimeoutSec
        $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue
        if ($errItem -and $errItem.Length -gt 0) {
            $errText = Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($errText) { throw $errText.Trim() }
        }
        if ($null -ne $proc.ExitCode -and [int]$proc.ExitCode -ne 0) {
            $stdErrText = Get-Content -LiteralPath $stderrTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($stdErrText -and $stdErrText.Trim()) { throw $stdErrText.Trim() }
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
