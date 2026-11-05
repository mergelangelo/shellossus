# URL encoding, lightweight HTML stripping, web search, and HTTP page fetching.

function ConvertTo-UrlEncodedString {
    param([string]$Text)
    if (-not $Text) { return '' }
    $chars = [char[]]$Text
    $out = for ($i = 0; $i -lt $chars.Count; $i++) {
        $ch = $chars[$i]
        $cp = [int][char]$ch
        if ($cp -ge 0xD800 -and $cp -le 0xDBFF -and ($i + 1) -lt $chars.Count) {
            $low = [int][char]$chars[$i + 1]
            if ($low -ge 0xDC00 -and $low -le 0xDFFF) {
                $point = 0x10000 + (($cp - 0xD800) * 1024) + ($low - 0xDC00)
                $b4 = 0x80 + ($point % 64)
                $point = [int](($point - ($point % 64)) / 64)
                $b3 = 0x80 + ($point % 64)
                $point = [int](($point - ($point % 64)) / 64)
                $b2 = 0x80 + ($point % 64)
                $point = [int](($point - ($point % 64)) / 64)
                $b1 = 0xF0 + $point
                '%{0:X2}%{1:X2}%{2:X2}%{3:X2}' -f $b1, $b2, $b3, $b4
                $i++
                continue
            }
        }
        if ($cp -ge 0xD800 -and $cp -le 0xDFFF) { throw 'Search query contains an invalid Unicode surrogate.' }
        if (($cp -ge 0x30 -and $cp -le 0x39) -or ($cp -ge 0x41 -and $cp -le 0x5A) -or ($cp -ge 0x61 -and $cp -le 0x7A) -or $cp -in @(0x2D, 0x5F, 0x2E, 0x7E)) {
            [string]$ch
        }
        elseif ($cp -eq 0x20) {
            '+'
        }
        elseif ($cp -le 0x7F) {
            '%{0:X2}' -f $cp
        }
        elseif ($cp -le 0x7FF) {
            $b2 = 0x80 + ($cp % 64)
            $b1 = 0xC0 + [int](($cp - ($cp % 64)) / 64)
            '%{0:X2}%{1:X2}' -f $b1, $b2
        }
        else {
            $low6 = $cp % 64
            $mid = [int](($cp - $low6) / 64)
            $mid6 = $mid % 64
            $hi4 = [int](($mid - $mid6) / 64)
            '%{0:X2}%{1:X2}%{2:X2}' -f (0xE0 + $hi4), (0x80 + $mid6), (0x80 + $low6)
        }
    }
    return ($out -join '')
}

function ConvertFrom-UrlEncodedString {
    param([string]$Text)
    if (-not $Text) { return '' }
    $work = $Text.Replace('+', ' ')
    $len = $work.Length
    $out = @()
    $i = 0
    while ($i -lt $len) {
        if (($i + 2) -lt $len -and $work[$i] -eq '%' -and ($work.Substring($i + 1, 2) -match '^[0-9A-Fa-f]{2}$')) {
            $b1 = [int]('0x' + $work.Substring($i + 1, 2))
            if ($b1 -le 0x7F) {
                if ($b1 -ge 0x20 -and $b1 -le 0x7E) {
                    $out += [string][char]$b1
                }
                else {
                    $out += $work.Substring($i, 3)
                }
                $i += 3
                continue
            }
            if ($b1 -ge 0xC2 -and $b1 -le 0xDF -and ($i + 5) -lt $len -and $work[$i + 3] -eq '%' -and ($work.Substring($i + 4, 2) -match '^[0-9A-Fa-f]{2}$')) {
                $b2 = [int]('0x' + $work.Substring($i + 4, 2))
                if ($b2 -ge 0x80 -and $b2 -le 0xBF) {
                    $cp = (($b1 - 0xC0) * 64) + ($b2 - 0x80)
                    $out += [string][char]$cp
                    $i += 6
                    continue
                }
            }
            if ($b1 -ge 0xE0 -and $b1 -le 0xEF -and ($i + 8) -lt $len -and $work[$i + 3] -eq '%' -and ($work.Substring($i + 4, 2) -match '^[0-9A-Fa-f]{2}$') -and $work[$i + 6] -eq '%' -and ($work.Substring($i + 7, 2) -match '^[0-9A-Fa-f]{2}$')) {
                $b2 = [int]('0x' + $work.Substring($i + 4, 2))
                $b3 = [int]('0x' + $work.Substring($i + 7, 2))
                if ($b2 -ge 0x80 -and $b2 -le 0xBF -and $b3 -ge 0x80 -and $b3 -le 0xBF) {
                    $cp = (($b1 - 0xE0) * 4096) + (($b2 - 0x80) * 64) + ($b3 - 0x80)
                    if ($cp -ge 0x800 -and ($cp -lt 0xD800 -or $cp -gt 0xDFFF)) {
                        $out += [string][char]$cp
                        $i += 9
                        continue
                    }
                }
            }
            if ($b1 -ge 0xF0 -and $b1 -le 0xF4 -and ($i + 11) -lt $len -and $work[$i + 3] -eq '%' -and ($work.Substring($i + 4, 2) -match '^[0-9A-Fa-f]{2}$') -and $work[$i + 6] -eq '%' -and ($work.Substring($i + 7, 2) -match '^[0-9A-Fa-f]{2}$') -and $work[$i + 9] -eq '%' -and ($work.Substring($i + 10, 2) -match '^[0-9A-Fa-f]{2}$')) {
                $b2 = [int]('0x' + $work.Substring($i + 4, 2))
                $b3 = [int]('0x' + $work.Substring($i + 7, 2))
                $b4 = [int]('0x' + $work.Substring($i + 10, 2))
                if ($b2 -ge 0x80 -and $b2 -le 0xBF -and $b3 -ge 0x80 -and $b3 -le 0xBF -and $b4 -ge 0x80 -and $b4 -le 0xBF) {
                    $point = (($b1 - 0xF0) * 262144) + (($b2 - 0x80) * 4096) + (($b3 - 0x80) * 64) + ($b4 - 0x80)
                    if ($point -ge 0x10000 -and $point -le 0x10FFFF) {
                        $offset = $point - 0x10000
                        $lowTen = $offset % 1024
                        $highTen = [int](($offset - $lowTen) / 1024)
                        $out += ([string][char](0xD800 + $highTen) + [string][char](0xDC00 + $lowTen))
                        $i += 12
                        continue
                    }
                }
            }
            $out += $work.Substring($i, 3)
            $i += 3
            continue
        }
        $out += [string]$work[$i]
        $i++
    }
    return ($out -join '')
}

function Test-SafeWebUrl {
    param([string]$Url)
    if (-not $Url -or $Url -notmatch '^https?://[^\s]+$') {
        throw 'url must be a valid http:// or https:// URL.'
    }
    $rawHostPart = ''
    if ($Url -match '^https?://([^/?#]+)') {
        $rawHostPart = $Matches[1]
        if ($rawHostPart -match '@') {
            throw 'URLs with embedded credentials are not allowed.'
        }
        $rawHostOnly = ($rawHostPart -replace ':\d+$', '').Trim('[', ']').ToLower().TrimEnd('.')
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
    $hostName = $uri.DnsSafeHost.Trim().ToLower().TrimEnd('.')
    if (-not $hostName) {
        $hostName = $uri.Host.Trim('[', ']').ToLower().TrimEnd('.')
    }
    if ($hostName -in @('localhost', 'local', 'internal', 'metadata', 'metadata.google.internal', 'instance-data', '0.0.0.0') -or
        $hostName -like '*.localhost' -or $hostName -like '*.local' -or $hostName -like '*.internal') {
        throw "Blocked request to local or private host: $hostName"
    }
    if ($hostName -in @('::1', '::', '0:0:0:0:0:0:0:1', '0:0:0:0:0:0:0:0') -or
        $hostName -match '^(?:fe[89ab][0-9a-f]:|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|::ffff:)') {
        throw "Blocked request to local or private IPv6 address: $hostName"
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
    return $true
}

function Request-AgentWebConfirmation {
    param([string]$ToolName, [string]$Target)
    if ($script:AgentPermission -in @('AutoEdit', 'Auto')) {
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
        if ($script:AgentPermission -eq 'Ask') {
            $script:AgentPermission = 'AutoEdit'
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [switched permission to AutoEdit for this session]' + $script:Gm.Reset)
        }
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
    $s = $s.Replace('&nbsp;', ' ').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&apos;', "'").Replace('&mdash;', '--').Replace('&ndash;', '-')
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
    if ($webCommand -and $webCommand.CommandType -eq 'Function') {
        try {
            Invoke-WebRequest @request
        }
        catch {
            throw (Format-WebRequestError -ErrorRecord $_)
        }
    }
    else {
        $stdout = New-TemporaryFile -ErrorAction Stop
        $stderr = New-TemporaryFile -ErrorAction Stop
        $proc = $null
        $oldUri = $env:SHELLOSSUS_WEB_DOWNLOAD_URI
        $oldFile = $env:SHELLOSSUS_WEB_DOWNLOAD_FILE
        try {
            $worker = @'
$ErrorActionPreference = 'Stop'
try {
    Invoke-WebRequest -Uri $env:SHELLOSSUS_WEB_DOWNLOAD_URI -Method Get -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Shellossus/1.0' } -TimeoutSec 30 -UseBasicParsing -OutFile $env:SHELLOSSUS_WEB_DOWNLOAD_FILE -ErrorAction Stop
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
            $workerArguments = if ($env:OS -eq 'Windows_NT') {
                $escaped = ($worker -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
                "-NoProfile -NonInteractive -Command `"$escaped`""
            }
            else { @('-NoProfile', '-NonInteractive', '-Command', $worker) }
            try {
                $env:SHELLOSSUS_WEB_DOWNLOAD_URI = $Uri
                $env:SHELLOSSUS_WEB_DOWNLOAD_FILE = $OutFile
                $proc = Start-Process -FilePath (Get-AgentEnvironment).shell_exe -ArgumentList $workerArguments -RedirectStandardOutput $stdout.FullName -RedirectStandardError $stderr.FullName -NoNewWindow -PassThru -ErrorAction Stop
            }
            finally {
                $env:SHELLOSSUS_WEB_DOWNLOAD_URI = $oldUri
                $env:SHELLOSSUS_WEB_DOWNLOAD_FILE = $oldFile
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
    $tempOut = New-TemporaryFile -ErrorAction Stop
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

function Invoke-AgentWebSearch {
    param($Arguments)
    $toolStart = Get-Date
    $query = if ($Arguments.query) { $Arguments.query.Trim() } else { '' }
    if (-not $query) { throw 'query must be a nonempty string.' }
    $limit = 8
    if ($null -ne $Arguments.limit) {
        $limit = [int]$Arguments.limit
        if ($limit -lt 1 -or $limit -gt 20) { throw 'limit must be between 1 and 20.' }
    }
    $encodedQ = ConvertTo-UrlEncodedString -Text $query
    $baseSearchUrl = if ($env:SHELLOSSUS_SEARCH_URL) { $env:SHELLOSSUS_SEARCH_URL } else { 'https://html.duckduckgo.com/html/?q=' }
    $searchUri = $baseSearchUrl + $encodedQ
    $null = Test-SafeWebUrl -Url $searchUri
    $conf = Request-AgentWebConfirmation -ToolName 'web_search' -Target $query
    if (-not $conf.approved) { return $conf.response }
    $tempOut = New-TemporaryFile -ErrorAction Stop
    try {
        Invoke-AgentWebDownload -Uri $searchUri -OutFile $tempOut.FullName
        $html = Get-Content -LiteralPath $tempOut.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $html) { $html = '' }
        $results = @()
        $blocks = @($html -split '(?i)<div[^>]+class="[^"]*\bresult\b[^"]*"[^>]*>')
        if ($blocks.Count -gt 1) {
            for ($b = 1; $b -lt $blocks.Count; $b++) {
                if ($results.Count -ge $limit) { break }
                $blk = $blocks[$b]
                $href = ''
                $titleRaw = ''
                if ($blk -match '(?is)<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>(.*?)</a>') {
                    $href = $Matches[1]
                    $titleRaw = $Matches[2]
                }
                elseif ($blk -match '(?is)<a[^>]+href="([^"]+)"[^>]+class="[^"]*result__a[^"]*"[^>]*>(.*?)</a>') {
                    $href = $Matches[1]
                    $titleRaw = $Matches[2]
                }
                if (-not $href) { continue }
                if ($href -match '[?&]uddg=([^&"]+)') {
                    $href = ConvertFrom-UrlEncodedString -Text $Matches[1]
                }
                elseif ($href.StartsWith('//')) {
                    $href = 'https:' + $href
                }
                $title = (ConvertFrom-HtmlToText -Html $titleRaw) -replace '\s+', ' '
                $snippet = ''
                if ($blk -match '(?is)<(?:a|td|div|span)[^>]+class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|td|div|span)>') {
                    $snippet = (ConvertFrom-HtmlToText -Html $Matches[1]) -replace '\s+', ' '
                }
                $results += @{
                    title = $title.Trim()
                    url = $href.Trim()
                    snippet = $snippet.Trim()
                }
            }
        }
        $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
        Write-ToolCallCard -Name 'web_search' -Target $query -Status 'ok' -Summary "$($results.Count) results" -ElapsedMs $elapsedMs
        return (@{
            query = $query
            results = @($results)
            count = $results.Count
        } | ConvertTo-Json -Depth 6 -Compress)
    }
    finally {
        Remove-Item -LiteralPath $tempOut.FullName -Force -ErrorAction SilentlyContinue
    }
}
