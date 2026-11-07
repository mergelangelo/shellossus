# SSRF validation, outbound web confirmation, HTML-to-text conversion, and HTTP page fetching.

function Test-SafeWebUrl {
    param([string]$Url)
    if (-not $Url -or $Url -notmatch '^https?://[^\s]+$') {
        throw 'url must be a valid http:// or https:// URL.'
    }
    $rawHostOnly = ''
    if ($Url -match '^https?://([^/?#]+)') {
        $rawHostPart = $Matches[1]
        if ($rawHostPart -match '@') {
            throw 'URLs with embedded credentials are not allowed.'
        }
        if ($rawHostPart -match '^\[([^\]]+)\](?::\d+)?$') {
            $rawHostOnly = $Matches[1].Trim().ToLower()
        }
        else {
            $rawHostOnly = (($rawHostPart -replace ':\d+$', '') -replace '^\[|\]$', '').Trim().ToLower().TrimEnd('.')
        }
        if ($rawHostOnly -match '^(?:0x[0-9a-f]+|\d+)$' -or $rawHostOnly -match '^(?:0x[0-9a-f]+|\d+)(?:\.(?:0x[0-9a-f]+|\d+)){1,2}$') {
            throw "Blocked request to local or private network address: $rawHostOnly"
        }
        if ($rawHostOnly -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
            foreach ($octStr in @($Matches[1], $Matches[2], $Matches[3], $Matches[4])) {
                if ($octStr.Length -gt 1 -and $octStr.StartsWith('0')) {
                    throw "Blocked request to local or private network address: $rawHostOnly"
                }
            }
        }
    }
    $uri = $null
    try {
        $uri = [uri]$Url
    }
    catch {
        throw 'url must be a valid http:// or https:// URL.'
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https') -or -not $uri.Host) {
        throw 'url must be a valid http:// or https:// URL.'
    }
    if ($uri.UserInfo) {
        throw 'URLs with embedded credentials are not allowed.'
    }
    $dnsHost = (($uri.DnsSafeHost -replace '^\[|\]$', '')).Trim().ToLower().TrimEnd('.')
    $uriHost = (($uri.Host -replace '^\[|\]$', '')).Trim().ToLower().TrimEnd('.')
    $hostsToCheck = @()
    foreach ($candHost in @($rawHostOnly, $dnsHost, $uriHost)) {
        if ($candHost -and ($candHost -notin $hostsToCheck)) {
            $hostsToCheck += $candHost
        }
    }
    foreach ($hostName in $hostsToCheck) {
        if ($hostName -in @('localhost', 'local', 'internal', 'metadata', 'metadata.google.internal', 'instance-data', '0.0.0.0') -or
            $hostName -like '*.localhost' -or $hostName -like '*.local' -or $hostName -like '*.internal') {
            throw "Blocked request to local or private host: $hostName"
        }
        if ($hostName.Contains(':')) {
            if ($hostName -match '^[0:]+0*1(?:%.*)?$' -or
                $hostName -match '^[0:]+(?:%.*)?$' -or
                $hostName -match '^(?:fe[89ab][0-9a-f]:|f[cd][0-9a-f]{2}:|ff[0-9a-f]{2}:|[0:]*:ffff:)' -or
                $hostName -match '^(?:0+:){0,6}(?:::(?:ffff:(?:0:+)?)?|ffff:)?(?:127\.|10\.|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|(?:22[4-9]|23\d|24\d|25[0-5])\.|0\.)' -or
                $hostName -match '^(?:0+:){0,6}(?:::(?:ffff:(?:0:+)?)?|ffff:)?(?:7f[0-9a-f]{2}|0?a[0-9a-f]{2}|c0a8|a9fe|ac1[0-9a-f]|64[4-7][0-9a-f]|[ef][0-9a-f]{3}|0{1,2}[0-9a-f]{2}):[0-9a-f]{1,4}$' -or
                $hostName -match '^64:ff9b:') {
                throw "Blocked request to local or private IPv6 address: $hostName"
            }
        }
        if ($hostName -match '^(?:0x[0-9a-f]+|\d+)$' -or $hostName -match '^\d+(?:\.\d+){1,2}$') {
            throw "Blocked request to local or private network address: $hostName"
        }
        if ($hostName -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
            $o1 = [int]$Matches[1]
            $o2 = [int]$Matches[2]
            $o3 = [int]$Matches[3]
            $o4 = [int]$Matches[4]
            if ($o1 -gt 255 -or $o2 -gt 255 -or $o3 -gt 255 -or $o4 -gt 255) {
                throw "Invalid IPv4 address in URL: $hostName"
            }
            $isPrivate = ($o1 -eq 0) -or
                ($o1 -eq 10) -or
                ($o1 -eq 127) -or
                ($o1 -eq 169 -and $o2 -eq 254) -or
                ($o1 -eq 172 -and $o2 -ge 16 -and $o2 -le 31) -or
                ($o1 -eq 192 -and $o2 -eq 168) -or
                ($o1 -eq 100 -and $o2 -ge 64 -and $o2 -le 127) -or
                ($o1 -ge 224)
            if ($isPrivate) {
                throw "Blocked request to local or private IPv4 address: $hostName"
            }
        }
    }
    return $true
}

function Request-AgentWebConfirmation {
    param([string]$ToolName, [string]$Target)
    if ($script:AgentPermission -in @('AutoEdit', 'Auto') -or $script:AutoApproveWeb) {
        return @{ approved = $true; response = $null }
    }
    if ($script:OutputMode -eq 'json') {
        return @{
            approved = $false
            response = (@{
                status = 'cancelled'
                message = 'Interactive confirmation is disabled in JSON mode. Use -Permission AutoEdit or Auto to allow outbound web requests.'
            } | ConvertTo-Json -Compress)
        }
    }
    Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.BoldYellow + $script:Box.Arrow + " $ToolName " + $script:Gm.Fg1 + (Format-PreviewText $Target) + $script:Gm.Reset)
    $promptStr = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.BoldYellow + 'Confirm outbound web request [y]es, [n]o, [a]ll: ' + $script:Gm.Fg
    $choice = Read-TuiConfirmation -PromptText $promptStr -ActionType 'web'
    if ($choice -eq 'a') {
        $script:AutoApproveWeb = $true
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [auto-approving web requests for this session]' + $script:Gm.Reset)
        return @{ approved = $true; response = $null }
    }
    if ($choice -eq 'y') {
        return @{ approved = $true; response = $null }
    }
    Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
    return @{
        approved = $false
        response = (@{
            status = 'cancelled'
            message = 'User declined web request. Do not retry without a new user request.'
        } | ConvertTo-Json -Compress)
    }
}

function Format-WebRequestError {
    param($ErrorRecord)
    $code = 0
    try {
        if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
            $code = [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}
    $rawMsg = if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        [string]$ErrorRecord.Exception.Message
    }
    else {
        [string]$ErrorRecord
    }
    $cleanMsg = (($rawMsg -replace '[\r\n]+', ' ').Trim())
    if ($cleanMsg.Length -gt 240) {
        $cleanMsg = $cleanMsg.Substring(0, 240) + '...'
    }
    if ($code -gt 0 -and ($cleanMsg -notmatch "\b$code\b")) {
        return "Web request failed (HTTP $code): $cleanMsg"
    }
    if ($cleanMsg -match '^Web request ') {
        return $cleanMsg
    }
    if ($cleanMsg) {
        return "Web request failed: $cleanMsg"
    }
    return 'Web request failed.'
}

function ConvertFrom-HtmlToText {
    param([string]$Html)
    if (-not $Html) { return '' }
    $s = $Html
    $s = $s -replace '(?is)<!--.*?-->', ''
    $s = $s -replace '(?is)<(script|style|noscript|svg|head)\b[^>]*>.*?</\1>', ''
    $s = $s -replace '(?is)<br\s*/?>', "`n"
    $s = $s -replace '(?is)</(p|div|section|article|header|footer|tr|table|ul|ol|blockquote|pre|h[1-6])>', "`n"
    $s = $s -replace '(?is)<li\b[^>]*>', "`n- "
    $s = $s -replace '(?is)<h([1-6])\b[^>]*>', "`n# "
    $s = $s -replace '(?is)<[^>]+>', ' '
    $s = $s.Replace('&nbsp;', ' ').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&apos;', "'").Replace('&mdash;', '--').Replace('&ndash;', '-').Replace('&amp;', '&')
    $lines = @()
    foreach ($ln in @($s -split '\r?\n')) {
        $cleanLn = ($ln -replace '[ \t]+', ' ').Trim()
        $lines += $cleanLn
    }
    $joined = ($lines -join "`n") -replace '\n{3,}', "`n`n"
    return $joined.Trim()
}

function Invoke-AgentWebDownload {
    param([string]$Uri, [string]$OutFile, [int]$MaxBytes = 2097152)
    $request = @{
        Uri = $Uri
        Method = 'Get'
        Headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Shellossus/1.0' }
        TimeoutSec = 30
        UseBasicParsing = $true
        OutFile = $OutFile
        ErrorAction = 'Stop'
    }
    $webCommand = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ($webCommand -and $webCommand.CommandType -ne 'Function') {
        $request['MaximumRedirection'] = 0
    }
    if ($webCommand -and $webCommand.CommandType -eq 'Function') {
        Invoke-WithProcessEnvironment -Values @{
            SHELLOSSUS_API_KEY = $null
            OPENAI_API_KEY = $null
        } -Action {
            try {
                Invoke-WebRequest @request
            }
            catch {
                throw (Format-WebRequestError -ErrorRecord $_)
            }
        }
    }
    else {
        $stdout = New-AgentTempFile
        $stderr = New-AgentTempFile
        $proc = $null
        try {
            $worker = @'
$ErrorActionPreference = 'Stop'
try {
    Invoke-WebRequest -Uri $env:SHELLOSSUS_WEB_DOWNLOAD_URI -Method Get -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Shellossus/1.0' } -MaximumRedirection 0 -TimeoutSec 30 -UseBasicParsing -OutFile $env:SHELLOSSUS_WEB_DOWNLOAD_FILE -ErrorAction Stop
} catch {
    $code = 0
    try {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $code = [int]$_.Exception.Response.StatusCode
        }
    } catch {}
    $msg = if ($_.Exception -and $_.Exception.Message) { [string]$_.Exception.Message } else { [string]$_ }
    $msg = ($msg -replace '[\r\n]+', ' ').Trim()
    if ($code -gt 0 -and ($msg -notmatch "\b$code\b")) {
        Write-Output "HTTP ${code}: $msg"
    } else {
        Write-Output $msg
    }
    exit 1
}
'@
            $workerArguments = Get-AgentCommandArguments -CommandText $worker
            $proc = Invoke-WithProcessEnvironment -Values @{
                SHELLOSSUS_API_KEY = $null
                OPENAI_API_KEY = $null
                SHELLOSSUS_WEB_DOWNLOAD_URI = $Uri
                SHELLOSSUS_WEB_DOWNLOAD_FILE = $OutFile
            } -Action {
                Start-Process -FilePath (Get-AgentEnvironment).shell_exe -ArgumentList $workerArguments -RedirectStandardOutput $stdout.FullName -RedirectStandardError $stderr.FullName -NoNewWindow -PassThru -ErrorAction Stop
            }
            $started = Get-Date
            while (-not $proc.HasExited) {
                $file = Get-Item -LiteralPath $OutFile -Force -ErrorAction Stop
                if ($file.Length -gt $MaxBytes) { throw "Web response exceeds $MaxBytes bytes." }
                if (((Get-Date) - $started).TotalSeconds -gt 35) { throw 'Web request timed out.' }
                Start-Sleep -Milliseconds 100
            }
            if ($null -ne $proc.ExitCode -and $proc.ExitCode -ne 0) {
                $errOut = ''
                if (Test-Path -LiteralPath $stdout.FullName) {
                    $errOut = Get-Content -LiteralPath $stdout.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                }
                if ((-not $errOut -or -not $errOut.Trim()) -and (Test-Path -LiteralPath $stderr.FullName)) {
                    $errOut = Get-Content -LiteralPath $stderr.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                }
                $errDetail = if ($errOut -and $errOut.Trim()) { ($errOut -replace '[\r\n]+', ' ').Trim() } else { '' }
                if ($errDetail.Length -gt 240) { $errDetail = $errDetail.Substring(0, 240) + '...' }
                if ($errDetail) {
                    throw "Web request failed: $errDetail"
                }
                throw 'Web request failed.'
            }
        }
        finally {
            if ($proc -and -not $proc.HasExited) {
                Stop-Process -InputObject $proc -Force -ErrorAction SilentlyContinue
                Wait-Process -InputObject $proc -Timeout 2 -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $stdout.FullName, $stderr.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $resultFile = Get-Item -LiteralPath $OutFile -Force -ErrorAction Stop
    if ($resultFile.Length -gt $MaxBytes) { throw "Web response exceeds $MaxBytes bytes." }
}

function Invoke-AgentFetchUrl {
    param($Arguments)
    $toolStart = Get-Date
    $url = if ($Arguments.url) { $Arguments.url.Trim() } else { '' }
    $null = Test-SafeWebUrl -Url $url
    $maxChars = 20000
    if ($null -ne $Arguments.max_chars) {
        $maxChars = [int]$Arguments.max_chars
        if ($maxChars -lt 500 -or $maxChars -gt 50000) { throw 'max_chars must be between 500 and 50000.' }
    }
    $conf = Request-AgentWebConfirmation -ToolName 'fetch_url' -Target $url
    if (-not $conf.approved) { return $conf.response }
    $rawMode = ($Arguments.raw -eq $true)
    $tempOut = New-AgentTempFile
    try {
        Invoke-AgentWebDownload -Uri $url -OutFile $tempOut.FullName
        $rawText = Get-Content -LiteralPath $tempOut.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $rawText) { $rawText = '' }
        $isHtml = ($rawText -match '(?is)<\s*(!doctype\s+html|html|body|div|p|article|main|section|table|h1)\b')
        $content = if ((-not $rawMode) -and $isHtml) {
            ConvertFrom-HtmlToText -Html $rawText
        }
        else {
            $rawText.Trim()
        }
        $truncated = $false
        $totalLen = $content.Length
        if ($content.Length -gt $maxChars) {
            $content = $content.Substring(0, $maxChars) + "`n...(truncated at $maxChars chars)"
            $truncated = $true
        }
        $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
        $sumStr = "$($content.Length) chars" + $(if ($truncated) { " (of $totalLen)" } else { '' })
        Write-ToolCallCard -Name 'fetch_url' -Target $url -Status 'ok' -Summary $sumStr -ElapsedMs $elapsedMs
        return (@{
            url = $url
            content = $content
            length = $totalLen
            truncated = $truncated
        } | ConvertTo-Json -Depth 5 -Compress)
    }
    finally {
        Remove-Item -LiteralPath $tempOut.FullName -Force -ErrorAction SilentlyContinue
    }
}
