param([switch]$ConstrainedLanguage)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"
$envData = New-TestEnvironment
$workspacePath = $envData.Workspace
$sessionPath = Join-Path $envData.TestRoot 'sessions'
$savedSessionWrites = $script:CurrentTurnWrites
$savedDoctorFixture = $global:ShellossusDoctorFixture
$global:ShellossusDoctorFixture = @{}
$global:ShellossusDoctorFixture.httpError = New-Object System.Exception 'Private response body: doctor-secret-key'
$global:ShellossusDoctorFixture.httpError | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 401 }
$innerEx = New-Object System.Exception 'Inner HTTP failure'
$innerEx | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 403 }
$global:ShellossusDoctorFixture.innerHttpError = New-Object System.Exception ('Outer wrapper', $innerEx)
if ($ConstrainedLanguage) {
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
    . "$PSScriptRoot\..\shellossus.ps1" -LibraryOnly
}

function Get-DoctorCheck {
    param($Report, [string]$Name)
    return @($Report.checks | Where-Object { $_.name -eq $Name })[0]
}

$global:ShellossusDoctorFixture.httpCode = 200
$global:ShellossusDoctorFixture.body = '{"data":[{"id":"test-model"}]}'
$global:ShellossusDoctorFixture.requests = 0
$global:ShellossusDoctorFixture.throwNetwork = $false
$global:ShellossusDoctorFixture.throwRedirectNoResponse = $false
$global:ShellossusDoctorFixture.throwInnerResponseCode = 0
$global:ShellossusDoctorFixture.responsePath = ''
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $OutFile, $MaximumRedirection, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, [switch]$PassThru)
    $global:ShellossusDoctorFixture.requests++
    $global:ShellossusDoctorFixture.responsePath = $OutFile
    Assert-True ($Uri -ceq 'https://example.invalid/v1/models' -and $Method -eq 'Get') 'Doctor sent a request outside the model catalog.'
    Assert-True ($Headers.Authorization -ceq 'Bearer doctor-secret-key' -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 10) 'Doctor request authentication/redirect/timeout settings changed.'
    Assert-True (-not $PassThru -and $UseBasicParsing) 'Doctor must use file-backed responses without -PassThru on Windows PowerShell 5.1.'
    if ($global:ShellossusDoctorFixture.throwNetwork) { throw 'Network failure includes doctor-secret-key and server-private-body.' }
    if ($global:ShellossusDoctorFixture.throwRedirectNoResponse) { throw 'Maximum redirection count exceeded.' }
    if ($global:ShellossusDoctorFixture.throwInnerResponseCode -gt 0) {
        $global:ShellossusDoctorFixture.innerHttpError.InnerException.Response.StatusCode = $global:ShellossusDoctorFixture.throwInnerResponseCode
        throw $global:ShellossusDoctorFixture.innerHttpError
    }
    if ($global:ShellossusDoctorFixture.httpCode -ne 200) {
        $global:ShellossusDoctorFixture.httpError.Response.StatusCode = $global:ShellossusDoctorFixture.httpCode
        throw $global:ShellossusDoctorFixture.httpError
    }
    Set-Content -LiteralPath $OutFile -Value $global:ShellossusDoctorFixture.body -Encoding UTF8 -NoNewline
}

try {
    & {
        function Read-Host {
            [CmdletBinding()]
            param([string]$Prompt, [switch]$AsSecureString)
            Assert-True ($Prompt -eq 'API key' -and $AsSecureString) 'Credential prompt requested visible input.'
            return (ConvertTo-SecureString -String 'secret-fixture' -AsPlainText -Force)
        }
        Assert-True ((Read-AgentApiKey) -ceq 'secret-fixture') 'Hidden key did not round trip in this language mode.'
    }

    $argsDoctor = @{ BaseUrl = 'https://example.invalid/v1/'; ModelId = 'test-model'; ApiKey = 'doctor-secret-key'; Workspace = $workspacePath; SessionDir = $sessionPath }
    $report = Get-AgentDoctorReport @argsDoctor
    Assert-True ($report.failures -eq 0 -and $report.warnings -eq 0 -and $report.exit_code -eq 0) ("Healthy doctor check failed: " + ($report | ConvertTo-Json -Depth 6 -Compress))
    Assert-True ((Get-DoctorCheck $report 'model').message -like '*is listed*') 'Doctor did not verify the configured model.'
    Assert-True ((Get-DoctorCheck $report 'endpoint').message -like '*Direct GET /models*') 'Doctor did not identify the transport actually checked.'
    Assert-True ($global:ShellossusDoctorFixture.requests -eq 1) 'Healthy Doctor did not issue exactly one catalog request.'
    $healthyJson = Write-AgentDoctorReport -Report $report -Mode json | ConvertFrom-Json
    Assert-True (($healthyJson.not_tested.name -join ',') -ceq 'chat_transport,chat_contract,web_tools') 'Doctor marked untested capabilities as verified or omitted them from JSON.'
    Assert-True ($healthyJson.not_tested[0].message -like '*Unicode*error reporting*cancellation*' -and $healthyJson.not_tested[2].message -like '*ConstrainedLanguage*') 'Doctor omitted untested worker or web behavior.'
    Assert-True ((Get-DoctorCheck $report 'language_mode').message -like "* $($ExecutionContext.SessionState.LanguageMode).*" ) 'Doctor reported the wrong language mode.'
    Assert-True ((Get-DoctorCheck $report 'sessions').status -eq 'pass' -and @(Get-ChildItem -LiteralPath $sessionPath -Force).Count -eq 0) 'Storage check failed or left a probe behind.'
    Assert-True (-not (Test-Path -LiteralPath $global:ShellossusDoctorFixture.responsePath)) 'Doctor left an HTTP response on disk.'
    Assert-True ($script:CurrentTurnWrites.Count -eq $savedSessionWrites.Count) 'Doctor changed undo history.'

    foreach ($case in @(
        @{ code = 401; status = 'fail'; text = '*API key*' },
        @{ code = 403; status = 'fail'; text = '*account access*' },
        @{ code = 407; status = 'fail'; text = '*Proxy*' },
        @{ code = 404; status = 'warn'; text = '*optional route*' },
        @{ code = 405; status = 'warn'; text = '*optional route*' },
        @{ code = 429; status = 'warn'; text = '*quota*' },
        @{ code = 503; status = 'fail'; text = '*unavailable*' },
        @{ code = 302; status = 'fail'; text = '*not forwarded*' }
    )) {
        $global:ShellossusDoctorFixture.httpCode = $case.code
        $report = Get-AgentDoctorReport @argsDoctor -NoSession
        $endpointCheck = Get-DoctorCheck $report 'endpoint'
        Assert-True ($endpointCheck.status -eq $case.status -and $endpointCheck.message -like $case.text) "Misleading doctor result for HTTP $($case.code)."
    }
    $global:ShellossusDoctorFixture.httpCode = 200
    $global:ShellossusDoctorFixture.throwRedirectNoResponse = $true
    $redirectReport = Get-AgentDoctorReport @argsDoctor -NoSession
    $redirectCheck = Get-DoctorCheck $redirectReport 'endpoint'
    Assert-True ($redirectCheck.status -eq 'fail' -and $redirectCheck.message -like '*not forwarded*') 'PS 5.1 redirection exception without Response was not reported as redirect.'
    $global:ShellossusDoctorFixture.throwRedirectNoResponse = $false

    $global:ShellossusDoctorFixture.throwInnerResponseCode = 403
    $innerReport = Get-AgentDoctorReport @argsDoctor -NoSession
    $innerCheck = Get-DoctorCheck $innerReport 'endpoint'
    Assert-True ($innerCheck.status -eq 'fail' -and $innerCheck.message -like '*account access*') 'InnerException.Response.StatusCode was not extracted.'
    $global:ShellossusDoctorFixture.throwInnerResponseCode = 0

    $textOut = @(Write-AgentDoctorReport -Report $report -Mode text 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
    Assert-True ($textOut.Contains($script:Gm.BoldGreen) -and $textOut.Contains('[PASS]') -and $textOut.Contains('Shellossus doctor')) 'Write-AgentDoctorReport text mode missing ANSI status colors.'
    foreach ($name in @('chat_transport', 'chat_contract', 'web_tools')) {
        Assert-True ($textOut -match ('\[NOT TESTED\][^\r\n]* ' + $name + ':')) "Doctor text did not mark $name as untested."
    }
    foreach ($body in @('<html>proxy login</html>', '{"unexpected":"shape"}', '{"data":[{}]}')) {
        $global:ShellossusDoctorFixture.body = $body
        $report = Get-AgentDoctorReport @argsDoctor -NoSession
        Assert-True ((Get-DoctorCheck $report 'endpoint').status -eq 'warn') 'Doctor accepted an invalid catalog as verification.'
    }
    $global:ShellossusDoctorFixture.body = '{"data":[{"id":"TEST-MODEL"}]}'
    $report = Get-AgentDoctorReport @argsDoctor -NoSession
    Assert-True ((Get-DoctorCheck $report 'model').status -eq 'warn') 'Doctor silently matched a model ID with different case.'
    $global:ShellossusDoctorFixture.throwNetwork = $true
    $report = Get-AgentDoctorReport @argsDoctor -NoSession
    $json = Write-AgentDoctorReport -Report $report -Mode json
    $parsed = $json | ConvertFrom-Json
    Assert-True ($parsed.type -eq 'doctor' -and $parsed.exit_code -eq 1 -and (Get-DoctorCheck $parsed 'endpoint').message -like '*DNS*') 'Network failures did not yield an actionable JSON report.'
    Assert-True (($parsed.not_tested.name -join ',') -ceq ($healthyJson.not_tested.name -join ',')) 'A catalog failure changed the set of untested capabilities.'
    Assert-True ($json -notlike '*doctor-secret-key*' -and $json -notlike '*server-private-body*') 'Doctor leaked a secret or server body.'
    Assert-True (-not (Test-Path -LiteralPath $global:ShellossusDoctorFixture.responsePath)) 'Failure left an HTTP response file.'
    $global:ShellossusDoctorFixture.throwNetwork = $false
    $global:ShellossusDoctorFixture.body = '{"data":[{"id":"test-model"}]}'

    $requestCount = $global:ShellossusDoctorFixture.requests
    foreach ($badUrl in @('', 'http://example.invalid/v1', 'https://user:password@example.invalid/v1', 'https://example.invalid/v1?key=secret', 'https://example.invalid/v1#secret', 'https://example.invalid/v1/chat/completions')) {
        $argsDoctor.BaseUrl = $badUrl
        $report = Get-AgentDoctorReport @argsDoctor -NoSession
        Assert-True ((Get-DoctorCheck $report 'endpoint').status -eq 'fail') 'Invalid API base URL was accepted.'
    }
    Assert-True ($global:ShellossusDoctorFixture.requests -eq $requestCount) 'Doctor made a request to an invalid URL.'
    $argsDoctor.BaseUrl = 'https://example.invalid/v1'
    $argsDoctor.ApiKey = ' '
    $wsKeyReport = Get-AgentDoctorReport @argsDoctor -NoSession
    Assert-True (((Get-DoctorCheck $wsKeyReport 'api_key').status -eq 'fail') -and (-not (Get-DoctorCheck $wsKeyReport 'api_key').message.Contains('[redacted]'))) 'Whitespace-only ApiKey corrupted doctor check messages.'
    $argsDoctor.ApiKey = ''
    $argsDoctor.ModelId = ''
    $report = Get-AgentDoctorReport @argsDoctor -NoSession -ConfigState missing
    Assert-True ($global:ShellossusDoctorFixture.requests -eq $requestCount -and (Get-DoctorCheck $report 'api_key').status -eq 'fail' -and (Get-DoctorCheck $report 'model').status -eq 'fail') 'Missing first-run settings triggered a network request or were not reported.'
    foreach ($loopbackUrl in @('http://localhost:11434/v1', 'http://127.0.0.1:8000/v1', 'http://[::1]:11434/v1')) {
        $argsDoctor.BaseUrl = $loopbackUrl
        $loopbackReport = Get-AgentDoctorReport @argsDoctor -NoSession -ConfigState missing
        Assert-True ((Get-DoctorCheck $loopbackReport 'endpoint').status -eq 'info') "Doctor rejected valid loopback HTTP base URL: $loopbackUrl"
    }
    $argsDoctor.BaseUrl = 'https://example.invalid/v1'

    # Empty loopback key uses the local placeholder. A remote URL with an empty key still fails.
    $task10Before = $global:ShellossusDoctorFixture.requests
    $task10Real = Get-AgentDoctorReport -BaseUrl 'https://example.invalid/v1' -ModelId 'test-model' -ApiKey 'doctor-secret-key' -Workspace $workspacePath -SessionDir $sessionPath -NoSession
    $task10RealKey = Get-DoctorCheck $task10Real 'api_key'
    Assert-True ($task10RealKey.status -eq 'pass' -and $task10RealKey.message -like '*hidden*' -and $task10RealKey.message -notlike '*doctor-secret-key*') 'A real API key did not pass or was printed.'
    $task10Remote = Get-AgentDoctorReport -BaseUrl 'https://api.example/v1' -ModelId 'test-model' -ApiKey '' -Workspace $workspacePath -SessionDir $sessionPath -NoSession
    Assert-True ((Get-DoctorCheck $task10Remote 'api_key').status -eq 'fail') 'Empty API key on https://api.example/v1 did not fail api_key.'
    Assert-True ($global:ShellossusDoctorFixture.requests -eq ($task10Before + 1)) 'Empty API key on a non-loopback URL triggered a network probe.'
    foreach ($task10Url in @('http://127.0.0.1/v1', 'http://localhost/v1', 'http://[::1]/v1')) {
        $task10Local = Get-AgentDoctorReport -BaseUrl $task10Url -ModelId 'test-model' -ApiKey '' -Workspace $workspacePath -SessionDir $sessionPath -NoSession
        $task10LocalKey = Get-DoctorCheck $task10Local 'api_key'
        $task10LocalMsg = [string]$task10LocalKey.message
        Assert-True ($task10LocalKey.status -eq 'pass' -or $task10LocalKey.status -eq 'info') "Empty API key on $task10Url failed api_key ($($task10LocalKey.status))."
        Assert-True ($task10LocalMsg -like '*no*key*configured*' -and $task10LocalMsg -like '*local server*' -and $task10LocalMsg -like '*local placeholder*') "Loopback placeholder was not explained for ${task10Url}: $task10LocalMsg"
        $task10Endpoint = Get-DoctorCheck $task10Local 'endpoint'
        Assert-True ($task10Endpoint.status -eq 'info' -and [string]$task10Endpoint.message -like '*local placeholder*' -and [string]$task10Endpoint.message -notlike '*until an API key is configured*') "Loopback endpoint text still asks for a key: $($task10Endpoint.message)"
    }
    Assert-True ($global:ShellossusDoctorFixture.requests -eq ($task10Before + 1)) 'Local placeholder triggered an endpoint probe.'
    $task10Blank = Get-AgentDoctorReport -BaseUrl 'http://127.0.0.1/v1' -ModelId 'test-model' -ApiKey ' ' -Workspace $workspacePath -SessionDir $sessionPath -NoSession
    Assert-True ((Get-DoctorCheck $task10Blank 'api_key').status -eq 'fail') 'Whitespace API key on loopback was treated as the local placeholder.'

    $blockedPath = Join-Path $envData.TestRoot 'not-a-directory'
    Set-Content -LiteralPath $blockedPath -Value 'keep' -Encoding Ascii
    $argsDoctor.SessionDir = $blockedPath
    $report = Get-AgentDoctorReport @argsDoctor
    Assert-True ((Get-DoctorCheck $report 'sessions').status -eq 'fail' -and (Get-Content -LiteralPath $blockedPath -Raw).Trim() -eq 'keep') 'Invalid session directory was overwritten or not detected.'
    $argsDoctor.Workspace = $blockedPath
    $report = Get-AgentDoctorReport @argsDoctor -NoSession -ConfigState invalid
    Assert-True ((Get-DoctorCheck $report 'workspace').status -eq 'fail' -and (Get-DoctorCheck $report 'configuration').status -eq 'fail') 'Doctor aborted or missed invalid workspace/configuration.'
    $argsDoctor.Workspace = $workspacePath
    $argsDoctor.SessionDir = Join-Path $envData.TestRoot 'disabled-sessions'
    $null = Get-AgentDoctorReport @argsDoctor -NoSession
    Assert-True (-not (Test-Path -LiteralPath $argsDoctor.SessionDir)) '-NoSession still created session storage.'

    # Simulate a real permission error without relying on OS-specific ACL tools.
    function Move-Item { param($LiteralPath, $Destination, $ErrorAction); throw 'Access denied: doctor-secret-key' }
    try {
        $storage = Test-DoctorSessionDirectory -Path $sessionPath
        Assert-True ($storage.status -eq 'fail' -and @(Get-ChildItem -LiteralPath $sessionPath -Force).Count -eq 0) 'A failed storage probe leaked files or reported success.'
    }
    finally { Remove-Item Function:\Move-Item }

    # Exercise real startup and REPL routing with isolated config and mocked I/O.
    $savedEnvironment = @{}
    $envNames = @('SHELLOSSUS_BASE_URL', 'SHELLOSSUS_MODEL', 'SHELLOSSUS_API_KEY', 'SHELLOSSUS_WORKSPACE', 'SHELLOSSUS_CONTEXT_WINDOW', 'SHELLOSSUS_COMPACT_THRESHOLD', 'SHELLOSSUS_REQUEST_TIMEOUT_SEC', 'SHELLOSSUS_STREAM')
    foreach ($envName in $envNames) {
        $savedEnvironment[$envName] = (Get-Item -LiteralPath ('Env:' + $envName) -ErrorAction SilentlyContinue).Value
        Remove-Item -LiteralPath ('Env:' + $envName) -ErrorAction SilentlyContinue
    }
    $global:ShellossusDoctorFixture.inputs = @()
    $global:ShellossusDoctorFixture.inputIndex = 0
    function Read-Host {
        param($Prompt)
        if ($global:ShellossusDoctorFixture.inputIndex -ge $global:ShellossusDoctorFixture.inputs.Count) { throw 'Unexpected startup or diagnostic prompt.' }
        $value = $global:ShellossusDoctorFixture.inputs[$global:ShellossusDoctorFixture.inputIndex]
        $global:ShellossusDoctorFixture.inputIndex++
        return $value
    }
    try {
        $entryPoint = "$PSScriptRoot\..\shellossus.ps1"
        $cliConfig = Join-Path $envData.TestRoot 'doctor.env'
        Save-AgentConfig -Path $cliConfig -Config @{
            SHELLOSSUS_BASE_URL = 'https://example.invalid/v1'
            SHELLOSSUS_MODEL = 'test-model'
            SHELLOSSUS_API_KEY = 'doctor-secret-key'
        }
        $cliReport = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $workspacePath -NoSession -Mode json | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $cliReport.type -eq 'doctor' -and $cliReport.failures -eq 0) ("Standalone -Doctor failed: " + ($cliReport | ConvertTo-Json -Depth 6 -Compress))
        $cliReport = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $workspacePath -Model override-model -NoSession -Mode json | ConvertFrom-Json
        Assert-True ((Get-DoctorCheck $cliReport 'model').message -like '*override-model*' -and $LASTEXITCODE -eq 0 -and $cliReport.warnings -eq 1) 'Standalone -Doctor ignored explicit model settings or treated a warning as failure.'
        $global:ShellossusDoctorFixture.inputs = @('/model active-model', '/doctor', '/exit')
        $beforeRequestCount = $global:ShellossusDoctorFixture.requests
        $replOutput = (& $entryPoint -ConfigPath $cliConfig -Workspace $workspacePath -NoSession -NoContextFiles -NoSkills -NoPromptTemplates 6>&1 | Out-String)
        Assert-True ($global:ShellossusDoctorFixture.inputIndex -eq 3 -and $global:ShellossusDoctorFixture.requests -eq $beforeRequestCount + 1) '/doctor did not route to a single diagnostic request.'
        Assert-True ($replOutput -like '*Shellossus doctor*' -and $replOutput -like '*Configured model is not in /models: active-model*') '/doctor did not inspect the active model.'
        Assert-True ((Read-AgentConfig -Path $cliConfig).SHELLOSSUS_MODEL -eq 'active-model') '/model in REPL did not persist SHELLOSSUS_MODEL to ConfigPath.'
        $global:ShellossusDoctorFixture.inputs = @()
        if ($env:OS -ne 'Windows_NT') {
            Set-ItemProperty -LiteralPath $cliConfig -Name UnixFileMode -Value 420
            $legacyOutput = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $workspacePath -NoSession -Mode json
            $legacyReport = $legacyOutput | ConvertFrom-Json
            Assert-True ($LASTEXITCODE -eq 0 -and (Get-DoctorCheck $legacyReport 'key_storage').status -eq 'warn') 'Doctor did not warn about a legacy key with broad read permissions.'
            Assert-True ((Get-DoctorCheck $legacyReport 'endpoint').status -eq 'pass' -and $legacyOutput -notlike '*doctor-secret-key*') 'Doctor discarded or exposed the legacy key.'
        }
        Set-Content -LiteralPath $cliConfig -Value 'INVALID_CONFIG=doctor-secret-key' -Encoding Ascii
        $cliOutput = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $blockedPath -NoSession -Mode json
        $cliReport = $cliOutput | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 1 -and (Get-DoctorCheck $cliReport 'configuration').status -eq 'fail' -and (Get-DoctorCheck $cliReport 'workspace').status -eq 'fail') 'Broken first-run settings prevented a complete diagnostic report.'
        Assert-True ($cliOutput -notlike '*doctor-secret-key*') 'A configuration error exposed secret content.'
        $task10CliCfg = Join-Path $envData.TestRoot 'task10-missing.env'
        $task10CliRaw = & $entryPoint -Doctor -BaseUrl 'http://127.0.0.1/v1' -Model 'local-model' -ConfigPath $task10CliCfg -Workspace $workspacePath -NoSession -Mode json
        $task10CliReport = $task10CliRaw | ConvertFrom-Json
        $task10CliKey = Get-DoctorCheck $task10CliReport 'api_key'
        Assert-True (($task10CliKey.status -eq 'pass' -or $task10CliKey.status -eq 'info') -and ([string]$task10CliKey.message -like '*local placeholder*') -and ($task10CliRaw -notlike '*doctor-secret-key*')) ("Standalone -Doctor treated a missing loopback key as a failure: $($task10CliKey.status) $($task10CliKey.message)")

        # Configurable request timeout in Get-AgentDoctorReport and standalone -Doctor (valid 10..1800 passes; invalid fails cleanly without crashing or leaking secret values).
        $validTimeoutCfg = Join-Path $envData.TestRoot 'doctor-timeout-valid.env'
        Save-AgentConfig -Path $validTimeoutCfg -Config @{
            SHELLOSSUS_BASE_URL = 'https://example.invalid/v1'
            SHELLOSSUS_MODEL = 'test-model'
            SHELLOSSUS_API_KEY = 'doctor-secret-key'
        }
        $validTimeoutRaw = & $entryPoint -Doctor -RequestTimeoutSec 300 -ConfigPath $validTimeoutCfg -Workspace $workspacePath -NoSession -Mode json
        $validTimeoutReport = $validTimeoutRaw | ConvertFrom-Json
        $validTimeoutCheck = Get-DoctorCheck $validTimeoutReport 'request_timeout'
        Assert-True ($LASTEXITCODE -eq 0 -and $validTimeoutReport.failures -eq 0 -and $validTimeoutCheck.status -eq 'pass' -and ([string]$validTimeoutCheck.message -like '*300s*')) ("Standalone -Doctor rejected valid -RequestTimeoutSec 300: " + $validTimeoutRaw)

        foreach ($badCliTimeout in @('0', '9', '1801', 'abc')) {
            $badTimeoutRaw = & $entryPoint -Doctor -RequestTimeoutSec $badCliTimeout -ConfigPath $validTimeoutCfg -Workspace $workspacePath -NoSession -Mode json
            $badTimeoutReport = $badTimeoutRaw | ConvertFrom-Json
            $badTimeoutCheck = Get-DoctorCheck $badTimeoutReport 'request_timeout'
            Assert-True ($LASTEXITCODE -eq 1 -and $badTimeoutReport.failures -ge 1 -and $badTimeoutCheck.status -eq 'fail' -and $badTimeoutCheck.message -eq 'RequestTimeoutSec must be an integer between 10 and 1800.') ("Standalone -Doctor did not report request_timeout failure for '$badCliTimeout': " + $badTimeoutRaw)
        }

        $badCfgTimeoutFile = Join-Path $envData.TestRoot 'doctor-timeout-secret.env'
        Set-Content -LiteralPath $badCfgTimeoutFile -Value "SHELLOSSUS_BASE_URL=`"https://example.invalid/v1`"`nSHELLOSSUS_MODEL=`"test-model`"`nSHELLOSSUS_REQUEST_TIMEOUT_SEC=`"doctor-secret-key`"" -Encoding Ascii
        $badCfgTimeoutRaw = & $entryPoint -Doctor -ConfigPath $badCfgTimeoutFile -Workspace $workspacePath -NoSession -Mode json
        $badCfgTimeoutReport = $badCfgTimeoutRaw | ConvertFrom-Json
        $badCfgTimeoutCheck = Get-DoctorCheck $badCfgTimeoutReport 'request_timeout'
        Assert-True ($LASTEXITCODE -eq 1 -and $badCfgTimeoutCheck.status -eq 'fail' -and ($badCfgTimeoutRaw -notlike '*doctor-secret-key*')) 'Doctor did not fail invalid config SHELLOSSUS_REQUEST_TIMEOUT_SEC cleanly or leaked its raw value.'

        # Optional SSE stream setting in Get-AgentDoctorReport and standalone -Doctor (valid passes; invalid env/config fails cleanly without crashing or leaking secret values).
        $validStreamRaw = & $entryPoint -Doctor -Stream -ConfigPath $validTimeoutCfg -Workspace $workspacePath -NoSession -Mode json
        $validStreamReport = $validStreamRaw | ConvertFrom-Json
        $validStreamCheck = Get-DoctorCheck $validStreamReport 'stream'
        Assert-True ($LASTEXITCODE -eq 0 -and $validStreamReport.failures -eq 0 -and $validStreamCheck.status -eq 'pass' -and ([string]$validStreamCheck.message -like '*enabled*')) ("Standalone -Doctor rejected valid -Stream: " + $validStreamRaw)

        $env:SHELLOSSUS_STREAM = 'doctor-secret-key'
        try {
            $badEnvStreamRaw = & $entryPoint -Doctor -ConfigPath $validTimeoutCfg -Workspace $workspacePath -NoSession -Mode json
            $badEnvStreamReport = $badEnvStreamRaw | ConvertFrom-Json
            $badEnvStreamCheck = Get-DoctorCheck $badEnvStreamReport 'stream'
            Assert-True ($LASTEXITCODE -eq 1 -and $badEnvStreamReport.failures -ge 1 -and $badEnvStreamCheck.status -eq 'fail' -and $badEnvStreamCheck.message -eq 'Stream setting must be true, false, 1, or 0.' -and ($badEnvStreamRaw -notlike '*doctor-secret-key*')) ("Standalone -Doctor did not fail invalid env SHELLOSSUS_STREAM cleanly: " + $badEnvStreamRaw)

            $overrideEnvStreamRaw = & $entryPoint -Doctor -Stream:$false -ConfigPath $validTimeoutCfg -Workspace $workspacePath -NoSession -Mode json
            $overrideEnvStreamReport = $overrideEnvStreamRaw | ConvertFrom-Json
            $overrideEnvStreamCheck = Get-DoctorCheck $overrideEnvStreamReport 'stream'
            Assert-True ($LASTEXITCODE -eq 0 -and $overrideEnvStreamCheck.status -eq 'pass' -and ([string]$overrideEnvStreamCheck.message -like '*disabled*')) ("Explicit -Stream:`$false did not override invalid env SHELLOSSUS_STREAM in -Doctor: " + $overrideEnvStreamRaw)
        }
        finally {
            Remove-Item -LiteralPath 'Env:SHELLOSSUS_STREAM' -ErrorAction SilentlyContinue
        }

        $badCfgStreamFile = Join-Path $envData.TestRoot 'doctor-stream-secret.env'
        Set-Content -LiteralPath $badCfgStreamFile -Value "SHELLOSSUS_BASE_URL=`"https://example.invalid/v1`"`nSHELLOSSUS_MODEL=`"test-model`"`nSHELLOSSUS_API_KEY=`"doctor-secret-key`"`nSHELLOSSUS_STREAM=`"doctor-secret-key`"" -Encoding Ascii
        $badCfgStreamRaw = & $entryPoint -Doctor -ConfigPath $badCfgStreamFile -Workspace $workspacePath -NoSession -Mode json
        $badCfgStreamReport = $badCfgStreamRaw | ConvertFrom-Json
        $badCfgStreamCheck = Get-DoctorCheck $badCfgStreamReport 'stream'
        Assert-True ($LASTEXITCODE -eq 1 -and $badCfgStreamCheck.status -eq 'fail' -and $badCfgStreamCheck.message -eq 'Stream setting must be true, false, 1, or 0.' -and ($badCfgStreamRaw -notlike '*doctor-secret-key*')) 'Doctor did not fail invalid config SHELLOSSUS_STREAM cleanly or leaked its raw value.'
    }
    finally {
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
        foreach ($envName in $envNames) {
            if ($null -eq $savedEnvironment[$envName]) { Remove-Item -LiteralPath ('Env:' + $envName) -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath ('Env:' + $envName) -Value $savedEnvironment[$envName] }
        }
    }
}
finally {
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-TestEnvironment -Env $envData
    if ($null -eq $savedDoctorFixture) { Remove-Variable ShellossusDoctorFixture -Scope Global -ErrorAction SilentlyContinue }
    else { $global:ShellossusDoctorFixture = $savedDoctorFixture }
}
