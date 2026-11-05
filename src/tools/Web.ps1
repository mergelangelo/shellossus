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
    $parts = @($work -split '(%[0-9A-Fa-f]{2})')
    for ($i = 1; $i -lt $parts.Count; $i += 2) {
        $hex = $parts[$i].Substring(1)
        $byteVal = [int]('0x' + $hex)
        if ($byteVal -ge 0x20 -and $byteVal -le 0x7E) {
            $parts[$i] = [string][char]$byteVal
        }
    }
    return ($parts -join '')
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
        Invoke-WebRequest @request
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
} catch { exit 1 }
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
            if ($null -ne $proc.ExitCode -and $proc.ExitCode -ne 0) { throw 'Web request failed.' }
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
    if ($url -notmatch '^https?://[^\s]+$') {
        throw 'url must be a valid http:// or https:// URL.'
    }
    $maxChars = 20000
    if ($null -ne $Arguments.max_chars) {
        $maxChars = [int]$Arguments.max_chars
        if ($maxChars -lt 500 -or $maxChars -gt 50000) { throw 'max_chars must be between 500 and 50000.' }
    }
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
