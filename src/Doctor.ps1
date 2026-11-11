# Startup diagnostics. No model generation, settings changes, or policy changes.

function Test-DoctorSessionDirectory {
    param([string]$Path)
    $probe = $null
    try {
        if (-not $Path) { throw 'Missing session directory.' }
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $dir = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($dir.PSProvider.Name -ne 'FileSystem' -or -not $dir.PSIsContainer) { throw 'Expected a filesystem directory.' }
        # Reserve a private probe directory without overwriting any existing file.
        $probePath = Join-Path $dir.FullName ('.doctor-' + $PID + '-' + (Get-Random -Minimum 100000 -Maximum 999999))
        $probe = New-Item -ItemType Directory -Path $probePath -ErrorAction Stop
        $source = Join-Path $probe.FullName 'write.tmp'
        $target = Join-Path $probe.FullName 'session.tmp'
        Set-Content -LiteralPath $source -Value 'shellossus-doctor' -Encoding Ascii -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
        if ((Get-Content -LiteralPath $target -Raw -ErrorAction Stop) -cne 'shellossus-doctor') { throw 'Read-back failed.' }
        Remove-Item -LiteralPath $target -ErrorAction Stop
        Remove-Item -LiteralPath $probe.FullName -Force -ErrorAction Stop
        $probe = $null
        return @{ status = 'pass'; message = "Session directory supports create, write, rename, read, and delete: $($dir.FullName)" }
    }
    catch {
        # Do not echo exception messages: paths and provider errors can contain secrets.
        return @{ status = 'fail'; message = 'Session storage is unavailable. Check the directory path, free space, and create/write/rename/delete permissions; choose -SessionDir or use -NoSession.' }
    }
    finally {
        if ($probe) { Remove-Item -LiteralPath $probe.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-DoctorModelsRequest {
    param([string]$Uri, [string]$ApiKey)
    $responseFile = $null
    try {
        $responseFile = New-AgentTempFile
        # The catalog probe runs in this process and stores the response in a file.
        # Do not follow redirects with the user's credentials.
        # Avoid -PassThru: older PowerShell versions leave -OutFile empty with it.
        # A successful response has no pipeline value; HTTP failures enter catch.
        $null = Invoke-WebRequest -Uri $Uri -Method Get -Headers @{ Authorization = ('Bearer ' + $ApiKey) } -UseBasicParsing -OutFile $responseFile.FullName -MaximumRedirection 0 -TimeoutSec 10 -ErrorAction Stop
        if ((Get-Item -LiteralPath $responseFile.FullName).Length -gt 1MB) {
            return @{ code = 200; valid_catalog = $false; ids = @() }
        }
        try {
            $catalog = Get-Content -LiteralPath $responseFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $valid = ($null -ne $catalog.data -and $catalog.data -is [array])
            $ids = @()
            foreach ($entry in @($catalog.data)) {
                if ($entry.id -isnot [string] -or -not $entry.id.Trim()) { $valid = $false; break }
                $ids += $entry.id
            }
            return @{ code = 200; valid_catalog = $valid; ids = $ids }
        }
        catch { return @{ code = 200; valid_catalog = $false; ids = @() } }
    }
    catch {
        $code = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $code = [int]$_.Exception.Response.StatusCode
        }
        elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Response -and $_.Exception.InnerException.Response.StatusCode) {
            $code = [int]$_.Exception.InnerException.Response.StatusCode
        }
        if ($code -eq 0 -and ($_.Exception.Message -match 'redirection' -or $_.FullyQualifiedErrorId -match 'WebCmdletWebResponseException|MaximumRedirect')) {
            $code = 302
        }
        return @{ code = $code; valid_catalog = $false; ids = @() }
    }
    finally {
        if ($responseFile) { Remove-Item -LiteralPath $responseFile.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AgentDoctorReport {
    param(
        [string]$BaseUrl,
        [string]$ModelId,
        [string]$ApiKey,
        [string]$Workspace = '.',
        [string]$SessionDir,
        [switch]$NoSession,
        [string]$ConfigState = 'loaded',
        [string]$KeyStorageWarning,
        [string]$RequestTimeoutSpec = '',
        [string]$StreamSpec = ''
    )
    $checks = @()
    $version = $PSVersionTable.PSVersion
    $supported = ($version.Major -ge 7 -or ($version.Major -eq 5 -and $version.Minor -ge 1))
    $checks += @{ name = 'powershell'; status = $(if ($supported) { 'pass' } else { 'fail' }); message = "PowerShell $version ($($PSVersionTable.PSEdition)). Requires Windows PowerShell 5.1 or PowerShell 7+." }
    $language = [string]$ExecutionContext.SessionState.LanguageMode
    $checks += @{ name = 'language_mode'; status = $(if ($language -in @('FullLanguage', 'ConstrainedLanguage')) { 'pass' } else { 'fail' }); message = "Language mode: $language. FullLanguage and ConstrainedLanguage are supported; no security policy was changed." }
    if ($ConfigState -eq 'invalid') {
        $checks += @{ name = 'configuration'; status = 'fail'; message = 'Configuration could not be read or parsed. Check -ConfigPath, file permissions, and supported SHELLOSSUS_* key=value entries.' }
    }
    elseif ($ConfigState -eq 'missing') {
        $checks += @{ name = 'configuration'; status = 'info'; message = 'No saved configuration found. Using launch arguments and environment variables; run shellossus -Setup to save settings.' }
    }
    else { $checks += @{ name = 'configuration'; status = 'pass'; message = 'Configuration parsed; effective launch settings are checked below.' } }
    $resolvedTimeout = $script:RequestTimeoutSec
    $timeoutValid = $true
    if ($RequestTimeoutSpec) {
        try {
            $resolvedTimeout = ConvertTo-AgentRequestTimeout -TimeoutSpec $RequestTimeoutSpec
        }
        catch {
            $timeoutValid = $false
        }
    }
    elseif ($resolvedTimeout -lt $script:MinRequestTimeoutSec -or $resolvedTimeout -gt $script:MaxRequestTimeoutSec) {
        $resolvedTimeout = 180
    }
    if ($timeoutValid) {
        $checks += @{ name = 'request_timeout'; status = 'pass'; message = "Model request timeout: ${resolvedTimeout}s." }
    }
    else {
        $checks += @{ name = 'request_timeout'; status = 'fail'; message = 'RequestTimeoutSec must be an integer between 10 and 1800.' }
    }
    $resolvedStream = [bool]$script:StreamRequests
    $streamValid = $true
    if ($null -ne $StreamSpec -and $StreamSpec.Trim().Length -gt 0) {
        try {
            $resolvedStream = ConvertTo-AgentStreamSetting -StreamSpec $StreamSpec
        }
        catch {
            $streamValid = $false
        }
    }
    if ($streamValid) {
        $streamLabel = if ($resolvedStream) { 'enabled' } else { 'disabled' }
        $checks += @{ name = 'stream'; status = 'pass'; message = "SSE response streaming: $streamLabel." }
    }
    else {
        $checks += @{ name = 'stream'; status = 'fail'; message = 'Stream setting must be true, false, 1, or 0.' }
    }
    try {
        $root = Get-Item -LiteralPath $Workspace -Force -ErrorAction Stop
        if (-not $root.PSIsContainer) { throw 'Expected a directory.' }
        $resolved = Resolve-AgentPath -Root $root.FullName -RelativePath '.'
        $checks += @{ name = 'workspace'; status = 'pass'; message = "Workspace is accessible: $resolved" }
    }
    catch { $checks += @{ name = 'workspace'; status = 'fail'; message = 'Workspace is missing, inaccessible, or traverses a reparse point. Choose an existing filesystem directory with -Workspace.' } }
    $storage = if ($NoSession) {
        @{ status = 'info'; message = 'Session persistence is disabled (-NoSession); no storage probe was performed.' }
    }
    else { Test-DoctorSessionDirectory -Path $SessionDir }
    $storage.name = 'sessions'
    $checks += $storage
    $hasKey = [bool]($ApiKey -and $ApiKey.Trim())
    # Same rule as chat startup: an empty key on a loopback server uses the local placeholder.
    $useLocalPlaceholder = (-not $ApiKey) -and (Test-IsLoopbackBaseUrl -Url $BaseUrl)
    $apiKeyStatus = 'fail'
    $apiKeyMessage = 'API key is missing. Run shellossus -Setup or set SHELLOSSUS_API_KEY.'
    if ($hasKey) {
        $apiKeyStatus = 'pass'
        $apiKeyMessage = 'API key is configured (value hidden).'
    }
    elseif ($useLocalPlaceholder) {
        $apiKeyStatus = 'info'
        $apiKeyMessage = 'No API key was configured for the local server; the local placeholder is used.'
    }
    $checks += @{ name = 'api_key'; status = $apiKeyStatus; message = $apiKeyMessage }
    if ($KeyStorageWarning) {
        $checks += @{ name = 'key_storage'; status = 'warn'; message = $KeyStorageWarning }
    }
    $hasModel = [bool]($ModelId -and $ModelId.Trim())
    $modelCheck = @{ name = 'model'; status = $(if ($hasModel) { 'pass' } else { 'fail' }); message = $(if ($hasModel) { "Configured model: $ModelId. Availability has not been verified." } else { 'Model ID is missing. Run shellossus -Setup or pass -Model with the provider model ID.' }) }
    $checks += $modelCheck
    $validUrl = Test-ValidAgentBaseUrl -Url $BaseUrl
    if (-not $validUrl) {
        $checks += @{ name = 'endpoint'; status = 'fail'; message = 'Set an HTTPS API base URL (or http://localhost for local servers, usually ending in /v1), without credentials, query, fragment, or /chat/completions. Configure -BaseUrl or run shellossus -Setup.' }
    }
    elseif (-not $hasKey) {
        $endpointMessage = if ($useLocalPlaceholder) {
            "Network check skipped for the local placeholder. Base URL: $BaseUrl"
        }
        else {
            "Network check skipped until an API key is configured. Base URL: $BaseUrl"
        }
        $checks += @{ name = 'endpoint'; status = 'info'; message = $endpointMessage }
    }
    else {
        $probe = Invoke-DoctorModelsRequest -Uri ($BaseUrl.TrimEnd('/') + '/models') -ApiKey $ApiKey
        $status = 'fail'
        $message = 'Endpoint check failed. Check DNS, proxy/VPN, TLS trust, firewall rules, and the API base URL. The request has a 10-second timeout (DNS resolution may take longer).'
        if ($probe.code -eq 200) {
            $status = 'pass'
            $message = 'Direct GET /models succeeded and returned a usable model catalog.'
            if (-not $probe.valid_catalog) {
                $status = 'warn'
                $message = 'Endpoint responded, but /models did not return a usable model list. Verify the API base URL and provider documentation; model availability is unverified.'
            }
            elseif ($hasModel) {
                if (@($probe.ids) -ccontains $ModelId) {
                    $modelCheck.message = "Configured model is listed by the endpoint: $ModelId."
                }
                else {
                    $modelCheck.status = 'warn'
                    $modelCheck.message = "Configured model is not in /models: $ModelId. Check spelling and access with the provider; some gateways omit valid deployment aliases."
                }
            }
        }
        elseif ($probe.code -in @(401, 403)) { $message = "Endpoint returned HTTP $($probe.code). Check the API key, account access, and gateway authentication requirements." }
        elseif ($probe.code -eq 407) { $message = 'Proxy authentication required (HTTP 407). Check your approved proxy configuration.' }
        elseif ($probe.code -in @(404, 405, 501)) {
            $status = 'warn'
            $message = "Endpoint returned HTTP $($probe.code) for /models. Check the base URL; this optional route may be unsupported. Model availability remains unverified."
        }
        elseif ($probe.code -eq 429) { $status = 'warn'; $message = 'Endpoint rate-limited the check (HTTP 429). Check quota and retry later; model availability is unverified.' }
        elseif ($probe.code -ge 300 -and $probe.code -lt 400) { $message = 'Endpoint redirects the request. Use the final approved HTTPS API base URL; credentials were not forwarded.' }
        elseif ($probe.code -ge 500) { $message = "Endpoint returned HTTP $($probe.code). The service or gateway is unavailable; retry later or contact its administrator." }
        elseif ($probe.code -gt 0) { $message = "Endpoint returned HTTP $($probe.code). Check the base URL and provider authentication requirements." }
        $checks += @{ name = 'endpoint'; status = $status; message = ($message + " Base URL: $BaseUrl") }
    }
    # Never include server bodies, headers, or raw exceptions in a shareable report.
    $trimmedKey = if ($hasKey) { $ApiKey.Trim() } else { '' }
    foreach ($check in $checks) {
        if ($hasKey) {
            $check.message = $check.message.Replace($ApiKey, '[redacted]')
            if ($trimmedKey -and $trimmedKey -ne $ApiKey) {
                $check.message = $check.message.Replace($trimmedKey, '[redacted]')
            }
        }
        $check.message = Format-TuiText $check.message
    }
    $failed = @($checks | Where-Object { $_.status -eq 'fail' }).Count
    $warnings = @($checks | Where-Object { $_.status -eq 'warn' }).Count
    $notTested = @(
        @{ name = 'chat_transport'; message = 'Background POST /chat/completions, Unicode round trip, worker error reporting, and cancellation.' },
        @{ name = 'chat_contract'; message = 'Completion and tool-call compatibility with the configured model.' },
        @{ name = 'web_tools'; message = 'fetch_url and web_search, including their ConstrainedLanguage compatibility.' }
    )
    return @{ checks = $checks; not_tested = $notTested; failures = $failed; warnings = $warnings; exit_code = $(if ($failed) { 1 } else { 0 }) }
}

function Write-AgentDoctorReport {
    param($Report, [string]$Mode = 'text')
    if ($Mode -eq 'json') {
        $event = @{ type = 'doctor'; checks = @($Report.checks); not_tested = @($Report.not_tested); failures = $Report.failures; warnings = $Report.warnings; exit_code = $Report.exit_code }
        Write-Output (ConvertTo-AsciiJson -Json ($event | ConvertTo-Json -Depth 6 -Compress))
        return
    }
    Write-Host ($script:Gm.BoldGreen + 'Shellossus doctor' + $script:Gm.Reset)
    foreach ($check in $Report.checks) {
        $stUpper = $check.status.ToUpper()
        $stColor = switch ($stUpper) {
            'PASS' { $script:Gm.BoldGreen }
            'WARN' { $script:Gm.BoldYellow }
            'FAIL' { $script:Gm.BoldRed }
            default { $script:Gm.BoldAqua }
        }
        Write-Host ('{0}[{1}]{2} {3}: {4}' -f $stColor, $stUpper, $script:Gm.Reset, $check.name, $check.message)
    }
    foreach ($item in $Report.not_tested) {
        Write-Host ('{0}[NOT TESTED]{1} {2}: {3}' -f $script:Gm.BoldAqua, $script:Gm.Reset, $item.name, $item.message)
    }
    Write-Host ("Checks complete: $($Report.failures) failure(s), $($Report.warnings) warning(s). No chat request was sent.")
}
