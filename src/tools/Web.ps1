# SSRF validation, outbound web confirmation, HTML-to-text conversion, and HTTP page fetching.

function Test-BlockedWebAddress {
    param([string]$Address)
    # Operators only. This runs in ConstrainedLanguage and is copied into the download worker.
    if (-not $Address) { return $false }
    $addr = $Address -replace '%.*$', ''
    $addr = $addr -replace '^\s+|\s+$', ''
    $addr = $addr -replace '^\[|\]$', ''
    if (-not $addr) { return $false }
    $o1 = -1
    $o2 = -1
    $o3 = -1
    $o4 = -1
    $haveV4 = $false
    if ($addr -match '^(?i)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
        $g1 = $Matches[1]
        $g2 = $Matches[2]
        $g3 = $Matches[3]
        $g4 = $Matches[4]
        $o1 = [int]($g1 -replace '^0+(?=\d)', '')
        $o2 = [int]($g2 -replace '^0+(?=\d)', '')
        $o3 = [int]($g3 -replace '^0+(?=\d)', '')
        $o4 = [int]($g4 -replace '^0+(?=\d)', '')
        $haveV4 = $true
    }
    elseif ($addr -match ':') {
        if ($addr -match '(?i):(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
            $e1 = [int]($Matches[1] -replace '^0+(?=\d)', '')
            $e2 = [int]($Matches[2] -replace '^0+(?=\d)', '')
            $e3 = [int]($Matches[3] -replace '^0+(?=\d)', '')
            $e4 = [int]($Matches[4] -replace '^0+(?=\d)', '')
            if ($e1 -gt 255 -or $e2 -gt 255 -or $e3 -gt 255 -or $e4 -gt 255) { return $false }
            $hiHex = '{0:x}' -f (($e1 * 256) + $e2)
            $loHex = '{0:x}' -f (($e3 * 256) + $e4)
            $addr = $addr -replace '(?i):\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', (':' + $hiHex + ':' + $loHex)
        }
        $chunks = @($addr -split '::', 3)
        if ($chunks.Count -gt 2) { return $false }
        $left = @()
        $right = @()
        $compressed = $false
        if ($chunks.Count -eq 2) {
            $compressed = $true
            if ($chunks[0] -ne '') { $left = @($chunks[0] -split ':') }
            if ($chunks[1] -ne '') { $right = @($chunks[1] -split ':') }
        }
        else {
            if ($chunks[0] -eq '') { return $false }
            $left = @($chunks[0] -split ':')
        }
        foreach ($part in $left) {
            if ($part -notmatch '^(?i)[0-9a-f]{1,4}$') { return $false }
        }
        foreach ($part in $right) {
            if ($part -notmatch '^(?i)[0-9a-f]{1,4}$') { return $false }
        }
        $have = @($left).Count + @($right).Count
        $zeros = 0
        if ($compressed) {
            if ($have -gt 7) { return $false }
            $zeros = 8 - $have
        }
        else {
            if ($have -ne 8) { return $false }
        }
        $hextets = @()
        foreach ($part in $left) { $hextets += [int]('0x' + $part) }
        for ($zi = 0; $zi -lt $zeros; $zi++) { $hextets += 0 }
        foreach ($part in $right) { $hextets += [int]('0x' + $part) }
        if (@($hextets).Count -ne 8) { return $false }
        $h0 = $hextets[0]
        $h1 = $hextets[1]
        $h2 = $hextets[2]
        $h3 = $hextets[3]
        $h4 = $hextets[4]
        $h5 = $hextets[5]
        $h6 = $hextets[6]
        $h7 = $hextets[7]
        if ($h0 -eq 0 -and $h1 -eq 0 -and $h2 -eq 0 -and $h3 -eq 0 -and $h4 -eq 0 -and $h5 -eq 0 -and $h6 -eq 0 -and $h7 -eq 0) { return $true }
        if ($h0 -eq 0 -and $h1 -eq 0 -and $h2 -eq 0 -and $h3 -eq 0 -and $h4 -eq 0 -and $h5 -eq 0 -and $h6 -eq 0 -and $h7 -eq 1) { return $true }
        if ($h0 -ge 0xFE80 -and $h0 -le 0xFEBF) { return $true }
        if ($h0 -ge 0xFC00 -and $h0 -le 0xFDFF) { return $true }
        if ($h0 -ge 0xFF00) { return $true }
        if ($h0 -eq 0x64 -and $h1 -eq 0xFF9B) { return $true }
        $tail1 = [int](($h6 - ($h6 % 256)) / 256)
        $tail2 = [int]($h6 % 256)
        $tailPrivate = ($tail1 -eq 0) -or ($tail1 -eq 10) -or ($tail1 -eq 127) -or ($tail1 -eq 169 -and $tail2 -eq 254) -or ($tail1 -eq 172 -and $tail2 -ge 16 -and $tail2 -le 31) -or ($tail1 -eq 192 -and $tail2 -eq 168) -or ($tail1 -eq 100 -and $tail2 -ge 64 -and $tail2 -le 127) -or ($tail1 -ge 224)
        if ($tailPrivate) {
            $prefixPlain = $true
            for ($hx = 0; $hx -le 5; $hx++) {
                if ($hextets[$hx] -ne 0 -and $hextets[$hx] -ne 0xFFFF) { $prefixPlain = $false }
            }
            if ($prefixPlain) { return $true }
        }
        $embedded = ($h0 -eq 0 -and $h1 -eq 0 -and $h2 -eq 0 -and $h3 -eq 0 -and $h4 -eq 0 -and ($h5 -eq 0 -or $h5 -eq 0xFFFF))
        if (-not $embedded) { return $false }
        $o1 = [int](($h6 - ($h6 % 256)) / 256)
        $o2 = [int]($h6 % 256)
        $o3 = [int](($h7 - ($h7 % 256)) / 256)
        $o4 = [int]($h7 % 256)
        $haveV4 = $true
    }
    else {
        return $false
    }
    if (-not $haveV4) { return $false }
    if ($o1 -lt 0 -or $o1 -gt 255 -or $o2 -lt 0 -or $o2 -gt 255 -or $o3 -lt 0 -or $o3 -gt 255 -or $o4 -lt 0 -or $o4 -gt 255) { return $false }
    if ($o1 -eq 0 -or $o1 -eq 10 -or $o1 -eq 127 -or ($o1 -eq 169 -and $o2 -eq 254) -or ($o1 -eq 172 -and $o2 -ge 16 -and $o2 -le 31) -or ($o1 -eq 192 -and $o2 -eq 168) -or ($o1 -eq 100 -and $o2 -ge 64 -and $o2 -le 127) -or ($o1 -ge 224)) { return $true }
    return $false
}

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
            if (Test-BlockedWebAddress -Address $hostName) {
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
            if (Test-BlockedWebAddress -Address $hostName) {
                throw "Blocked request to local or private IPv4 address: $hostName"
            }
        }
    }
    return $true
}

function Assert-SafeWebResolution {
    param([uri]$Target)
    $targetHost = $Target.IdnHost -replace '^\[|\]$', ''
    if ($Target.IsLoopback) {
        throw "Blocked request to local or private network address: $targetHost"
    }
    if ($Target.HostNameType -in @('IPv4', 'IPv6')) {
        $addresses = @($targetHost)
    }
    else {
        try {
            if (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) {
                $addresses = @(Resolve-DnsName -Name $targetHost -Type A_AAAA -DnsOnly -ErrorAction Stop |
                    Where-Object { $_.Type -in @('A', 'AAAA') -and $_.Section -eq 'Answer' } |
                    ForEach-Object { [string]$_.IPAddress })
            }
            elseif ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
                # Preserve hostname resolution on platforms without the Windows DNS cmdlet.
                $addresses = @([System.Net.Dns]::GetHostAddresses($targetHost))
            }
            else {
                throw 'Resolve-DnsName is unavailable in this PowerShell session.'
            }
        }
        catch {
            throw "DNS resolution failed for ${targetHost}: $($_.Exception.Message)"
        }
        if (-not $addresses.Count -or $addresses -contains '') {
            throw "DNS resolution failed for ${targetHost}: no IPv4 or IPv6 addresses returned."
        }
    }
    foreach ($address in $addresses) {
        if (Test-BlockedWebAddress -Address ([string]$address)) {
            throw "Blocked request to local or private network address: $targetHost"
        }
    }
}

function Test-AgentWebAutoApproval {
    param([string]$Permission = $script:AgentPermission)
    return ($Permission -eq 'Auto' -or $script:AutoApproveWeb)
}

function Request-AgentWebConfirmation {
    param([string]$ToolName, [string]$Target)
    if (Test-AgentWebAutoApproval) {
        return @{ approved = $true; response = $null }
    }
    if ($script:OutputMode -eq 'json') {
        return @{
            approved = $false
            response = (@{
                status = 'cancelled'
                message = 'Interactive confirmation is disabled in JSON mode. Use -Permission Auto to allow outbound web requests.'
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
    if ($script:WebDownloadUseHostCommand -eq $true) {
        $webCommand = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
        if ($webCommand -and $webCommand.Parameters -and $webCommand.Parameters.MaximumRedirection) {
            $request['MaximumRedirection'] = 0
        }
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
        $shellExe = Get-AgentPowerShellExecutable
        $stdout = New-AgentTempFile
        $stderr = New-AgentTempFile
        $proc = $null
        $procId = 0
        try {
            $workerFunctions = foreach ($name in @('Test-BlockedWebAddress', 'Assert-SafeWebResolution', 'Format-WebRequestError')) {
                $body = (Get-Command -Name $name -CommandType Function).Definition
                "function $name {`n$body`n}"
            }
            $workerMain = @'
$ErrorActionPreference = 'Stop'
try {
    Assert-SafeWebResolution -Target $env:SHELLOSSUS_WEB_DOWNLOAD_URI
} catch {
    Write-Output $_.Exception.Message
    exit 1
}
try {
    Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $env:SHELLOSSUS_WEB_DOWNLOAD_URI -Method Get -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Shellossus/1.0' } -MaximumRedirection 0 -TimeoutSec 30 -UseBasicParsing -OutFile $env:SHELLOSSUS_WEB_DOWNLOAD_FILE -ErrorAction Stop
} catch {
    Write-Output (Format-WebRequestError -ErrorRecord $_)
    exit 1
}
'@
            $worker = ($workerFunctions -join "`n") + "`n" + $workerMain
            $workerArguments = Get-AgentWorkerArguments -CommandText $worker
            $proc = Invoke-WithProcessEnvironment -Values @{
                SHELLOSSUS_API_KEY = $null
                OPENAI_API_KEY = $null
                SHELLOSSUS_WEB_DOWNLOAD_URI = $Uri
                SHELLOSSUS_WEB_DOWNLOAD_FILE = $OutFile
            } -Action {
                Start-Process -FilePath $shellExe -ArgumentList $workerArguments -RedirectStandardOutput $stdout.FullName -RedirectStandardError $stderr.FullName -NoNewWindow -PassThru -ErrorAction Stop
            }
            $procId = 0
            try { $procId = [int]$proc.Id } catch { $procId = 0 }
            $started = Get-Date
            while ($procId -gt 0 -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $OutFile) {
                    $file = Get-Item -LiteralPath $OutFile -Force -ErrorAction Stop
                    if ($file.Length -gt $MaxBytes) {
                        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                        throw "Web response exceeds $MaxBytes bytes."
                    }
                }
                if (((Get-Date) - $started).TotalSeconds -gt 35) {
                    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                    throw 'Web request timed out.'
                }
                Start-Sleep -Milliseconds 100
            }
            $errOut = ''
            if (Test-Path -LiteralPath $stdout.FullName) {
                $errOut = Get-Content -LiteralPath $stdout.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            if ((-not $errOut -or -not $errOut.Trim()) -and (Test-Path -LiteralPath $stderr.FullName)) {
                $errOut = Get-Content -LiteralPath $stderr.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            $errDetail = if ($errOut -and $errOut.Trim()) { ($errOut -replace '[\r\n]+', ' ').Trim() } else { '' }
            if ($errDetail.Length -gt 240) { $errDetail = $errDetail.Substring(0, 240) + '...' }
            if ($errDetail) { throw $errDetail }
            if (($null -ne $proc.ExitCode -and $proc.ExitCode -ne 0) -or -not (Test-Path -LiteralPath $OutFile)) {
                throw 'Web request failed.'
            }
        }
        finally {
            if ($procId -gt 0 -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
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
