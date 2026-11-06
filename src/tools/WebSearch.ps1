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
    $tempOut = New-AgentTempFile
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
