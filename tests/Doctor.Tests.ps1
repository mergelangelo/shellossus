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
    $argsDoctor = @{ BaseUrl = 'https://example.invalid/v1/'; ModelId = 'test-model'; ApiKey = 'doctor-secret-key'; Workspace = $workspacePath; SessionDir = $sessionPath }
    $report = Get-AgentDoctorReport @argsDoctor
    Assert-True ($report.failures -eq 0 -and $report.warnings -eq 0 -and $report.exit_code -eq 0) ("Healthy doctor check failed: " + ($report | ConvertTo-Json -Depth 6 -Compress))
    Assert-True ((Get-DoctorCheck $report 'model').message -like '*is listed*') 'Doctor did not verify the configured model.'
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
    $envNames = @('SHELLOSSUS_BASE_URL', 'SHELLOSSUS_MODEL', 'SHELLOSSUS_API_KEY', 'SHELLOSSUS_WORKSPACE', 'H_AGENT_BASE_URL', 'H_AGENT_MODEL', 'H_AGENT_API_KEY', 'H_AGENT_WORKSPACE', 'SHELLOSSUS_CONTEXT_WINDOW', 'SHELLOSSUS_COMPACT_THRESHOLD')
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
        Set-Content -LiteralPath $cliConfig -Value @('SHELLOSSUS_BASE_URL="https://example.invalid/v1"', 'SHELLOSSUS_MODEL="test-model"', 'SHELLOSSUS_API_KEY="doctor-secret-key"') -Encoding Ascii
        $cliReport = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $workspacePath -NoSession -Mode json | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $cliReport.type -eq 'doctor' -and $cliReport.failures -eq 0) ("Standalone -Doctor failed: " + ($cliReport | ConvertTo-Json -Depth 6 -Compress))
        $cliReport = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $workspacePath -Model override-model -NoSession -Mode json | ConvertFrom-Json
        Assert-True ((Get-DoctorCheck $cliReport 'model').message -like '*override-model*' -and $LASTEXITCODE -eq 0 -and $cliReport.warnings -eq 1) 'Standalone -Doctor ignored explicit model settings or treated a warning as failure.'
        $global:ShellossusDoctorFixture.inputs = @('/model active-model', '/doctor', '/exit')
        $beforeRequestCount = $global:ShellossusDoctorFixture.requests
        $replOutput = (& $entryPoint -ConfigPath $cliConfig -Workspace $workspacePath -NoSession -NoContextFiles -NoSkills -NoPromptTemplates 6>&1 | Out-String)
        Assert-True ($global:ShellossusDoctorFixture.inputIndex -eq 3 -and $global:ShellossusDoctorFixture.requests -eq $beforeRequestCount + 1) '/doctor did not route to a single diagnostic request.'
        Assert-True ($replOutput -like '*Shellossus doctor*' -and $replOutput -like '*Configured model is not in /models: active-model*') '/doctor did not inspect the active model.'
        $global:ShellossusDoctorFixture.inputs = @()
        Set-Content -LiteralPath $cliConfig -Value 'INVALID_CONFIG=doctor-secret-key' -Encoding Ascii
        $cliOutput = & $entryPoint -Doctor -ConfigPath $cliConfig -Workspace $blockedPath -NoSession -Mode json
        $cliReport = $cliOutput | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 1 -and (Get-DoctorCheck $cliReport 'configuration').status -eq 'fail' -and (Get-DoctorCheck $cliReport 'workspace').status -eq 'fail') 'Broken first-run settings prevented a complete diagnostic report.'
        Assert-True ($cliOutput -notlike '*doctor-secret-key*') 'A configuration error exposed secret content.'
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
