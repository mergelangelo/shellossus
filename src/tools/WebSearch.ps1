# URL percent-encoding/decoding and web_search HTML result extraction.

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

function ConvertTo-AgentSearchUrl {
    param([AllowEmptyString()][string]$UrlSpec)
    if ($null -eq $UrlSpec) { return '' }
    $trimmed = $UrlSpec.Trim()
    if (-not $trimmed) { return '' }
    if ($trimmed -notmatch '^(https?://)([^/?#\\]+)([/?].*)$') {
        throw 'Search URL must be an http:// or https:// URL with an explicit path or query delimiter.'
    }
    $schemePrefix = $Matches[1]
    $authority = $Matches[2]
    if ($authority.Contains('{') -or $authority.Contains('}')) {
        throw 'Search URL cannot contain placeholders in the host or authority.'
    }
    $baseProbe = $schemePrefix + $authority + '/'
    $null = Test-SafeWebUrl -Url $baseProbe
    $probe = if ($trimmed.Contains('{query}')) {
        $trimmed.Replace('{query}', 'test')
    }
    else {
        $trimmed + 'test'
    }
    $null = Test-SafeWebUrl -Url $probe
    $baseUri = [uri]$baseProbe
    $probeUri = [uri]$probe
    if (($probeUri.Scheme -ine $baseUri.Scheme) -or ($probeUri.IdnHost -ine $baseUri.IdnHost) -or ($probeUri.Port -ne $baseUri.Port)) {
        throw 'Search URL query expansion must not alter scheme, host, or port.'
    }
    return $trimmed
}

function Set-AgentSearchUrl {
    param([AllowEmptyString()][string]$UrlSpec)
    $val = ConvertTo-AgentSearchUrl -UrlSpec $UrlSpec
    $script:SearchUrl = $val
    return $script:SearchUrl
}

function Format-SearchFieldText {
    param($Value)
    if ($null -eq $Value -or $Value -isnot [string]) { return '' }
    $text = $Value
    if ($text.Contains('<')) {
        $text = $text -replace '(?is)</?(?:b|strong|i|em|u|mark|span|a|br|code|pre|p|div|small|sub|sup|wbr|h[1-6]|li|ul|ol|blockquote)\b[^>]*>', ''
    }
    if ($text.Contains('&')) {
        $text = $text.Replace('&nbsp;', ' ').Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&apos;', "'").Replace('&mdash;', '--').Replace('&ndash;', '-').Replace('&amp;', '&')
    }
    return (($text -replace '\s+', ' ').Trim())
}

function ConvertFrom-AgentSearchResponse {
    param([AllowEmptyString()][string]$RawText, [int]$Limit = 8)
    if ($null -eq $RawText) { return @() }
    $text = [string]$RawText
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    $trimmed = $text.TrimStart()
    if (-not $trimmed) { return @() }

    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        $entries = @()
        $jsonOpts = @{ ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.Keys -contains 'DateKind') { $jsonOpts.DateKind = 'String' }
        try {
            if ($trimmed.StartsWith('[')) {
                # Assign before wrapping so Windows PowerShell 5.1 does not double-wrap top-level JSON arrays.
                $parsedArr = $trimmed | ConvertFrom-Json @jsonOpts
                $entries = if ($null -eq $parsedArr) { @() } elseif ($parsedArr -is [array]) { $parsedArr } else { @($parsedArr) }
            }
            else {
                $parsed = $trimmed | ConvertFrom-Json @jsonOpts
                if (-not (Test-IsJsonObject -Value $parsed)) {
                    throw 'Invalid JSON object.'
                }
                if ($null -ne $parsed.results -and $parsed.results -is [array]) {
                    $entries = @($parsed.results)
                }
                elseif ((Test-IsJsonObject -Value $parsed.web) -and $null -ne $parsed.web.results -and $parsed.web.results -is [array]) {
                    $entries = @($parsed.web.results)
                }
                elseif ($null -ne $parsed.items -and $parsed.items -is [array]) {
                    $entries = @($parsed.items)
                }
                elseif ($null -ne $parsed.data -and $parsed.data -is [array]) {
                    $entries = @($parsed.data)
                }
            }
        }
        catch {
            throw 'Search endpoint returned invalid JSON.'
        }
        $jsonResults = @()
        foreach ($entry in $entries) {
            if ($jsonResults.Count -ge $Limit) { break }
            if (-not (Test-IsJsonObject -Value $entry)) { continue }
            $urlVal = ''
            foreach ($uField in @('url', 'link', 'href')) {
                if ($entry.$uField -is [string] -and $entry.$uField.Trim()) {
                    $urlVal = $entry.$uField.Trim()
                    break
                }
            }
            if (-not $urlVal) { continue }
            $titleVal = ''
            foreach ($tField in @('title', 'name')) {
                if ($entry.$tField -is [string] -and $entry.$tField.Trim()) {
                    $titleVal = Format-SearchFieldText -Value $entry.$tField
                    break
                }
            }
            if (-not $titleVal) { $titleVal = $urlVal }
            $snippetVal = ''
            foreach ($sField in @('snippet', 'content', 'description', 'summary')) {
                if ($entry.$sField -is [string] -and $entry.$sField.Trim()) {
                    $snippetVal = Format-SearchFieldText -Value $entry.$sField
                    break
                }
            }
            $jsonResults += @{
                title = $titleVal
                url = $urlVal
                snippet = $snippetVal
            }
        }
        return @($jsonResults)
    }

    $results = @()
    $blocks = @($text -split '(?i)<div[^>]+class="[^"]*\bresult\b[^"]*"[^>]*>')
    if ($blocks.Count -gt 1) {
        for ($b = 1; $b -lt $blocks.Count; $b++) {
            if ($results.Count -ge $Limit) { break }
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
            $hrefClean = $href.Replace('&amp;', '&')
            if ($hrefClean -match '[?&]uddg=([^&"]+)') {
                $href = ConvertFrom-UrlEncodedString -Text $Matches[1]
            }
            elseif ($hrefClean.StartsWith('//')) {
                $href = 'https:' + $hrefClean
            }
            else {
                $href = $hrefClean
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
    return @($results)
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
    $baseSearchUrl = if ($env:SHELLOSSUS_SEARCH_URL -and $env:SHELLOSSUS_SEARCH_URL.Trim()) {
        $env:SHELLOSSUS_SEARCH_URL.Trim()
    }
    elseif ($script:SearchUrl -and $script:SearchUrl.Trim()) {
        $script:SearchUrl.Trim()
    }
    else {
        'https://html.duckduckgo.com/html/?q='
    }
    $baseSearchUrl = ConvertTo-AgentSearchUrl -UrlSpec $baseSearchUrl
    $searchUri = if ($baseSearchUrl.Contains('{query}')) {
        $baseSearchUrl.Replace('{query}', $encodedQ)
    }
    else {
        $baseSearchUrl + $encodedQ
    }
    $null = Test-SafeWebUrl -Url $searchUri
    $conf = Request-AgentWebConfirmation -ToolName 'web_search' -Target $query
    if (-not $conf.approved) { return $conf.response }
    $tempOut = New-AgentTempFile
    try {
        Invoke-AgentWebDownload -Uri $searchUri -OutFile $tempOut.FullName
        $rawBody = Get-Content -LiteralPath $tempOut.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $rawBody) { $rawBody = '' }
        $results = @(ConvertFrom-AgentSearchResponse -RawText $rawBody -Limit $limit)
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
