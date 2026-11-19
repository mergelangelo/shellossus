param(
    [string]$BaseUrl = '',
    [string]$Model = '',
    [string]$ApiKey = '',
    [string]$ConfigPath = '',
    [int]$RequestTimeoutSec = 120,
    [switch]$IncludeConstrainedLanguage,
    [switch]$SkipCompaction,
    [switch]$KeepWorkspace,
    [switch]$ListScenarios
)

$ErrorActionPreference = 'Stop'

# Capture CLI parameters before dot-sourcing shellossus.ps1 -LibraryOnly,
# whose own param() block and defaults otherwise overwrite same-named script variables.
$argBaseUrl = $BaseUrl
$argModel = $Model
$argApiKey = $ApiKey
$argConfigPath = $ConfigPath
$argTimeoutSec = $RequestTimeoutSec

$repoRoot = Split-Path $PSScriptRoot -Parent
$agentScript = Join-Path $repoRoot 'shellossus.ps1'

$plannedScenarios = @(
    @{ name = 'doctor-json'; description = 'Run -Doctor -Mode json and verify version, status, and zero API key leaks.' },
    @{ name = 'chat-cyrillic-json'; description = 'Run a Cyrillic UTF-8 chat roundtrip in -Mode json.' },
    @{ name = 'tools-roundtrip-autoedit'; description = 'Exercise write_file -> read_file -> edit_file -> grep_files in -Permission AutoEdit.' },
    @{ name = 'stream-roundtrip'; description = 'Exercise -Stream SSE response assembly with write_file and edit_file.' },
    @{ name = 'compact-check'; description = 'Exercise Invoke-AgentCompact against the live endpoint and verify constraint retention.' },
    @{ name = 'constrained-language'; description = 'Opt-in (-IncludeConstrainedLanguage) cold-start ConstrainedLanguage chat check.' }
)

if ($ListScenarios) {
    Write-Host 'Shellossus live E2E scenarios (opt-in, not executed by smoke.ps1):'
    foreach ($sc in $plannedScenarios) {
        Write-Host ("  - {0}: {1}" -f $sc.name, $sc.description)
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $agentScript)) {
    throw "Standalone script not found: $agentScript. Run .\build.ps1 first."
}

if ($argTimeoutSec -lt 10 -or $argTimeoutSec -gt 1800) {
    throw 'RequestTimeoutSec must be between 10 and 1800.'
}

. $agentScript -LibraryOnly

$loadedCfg = @{}
if ($argConfigPath) {
    if (-not (Test-Path -LiteralPath $argConfigPath)) {
        throw "ConfigPath not found: $argConfigPath"
    }
    $loadedCfg = Read-AgentConfig -Path $argConfigPath
}

$effectiveBaseUrl = if ($argBaseUrl -and $argBaseUrl.Trim()) {
    $argBaseUrl.Trim()
}
elseif ($env:SHELLOSSUS_BASE_URL -and $env:SHELLOSSUS_BASE_URL.Trim()) {
    $env:SHELLOSSUS_BASE_URL.Trim()
}
elseif ($loadedCfg.ContainsKey('SHELLOSSUS_BASE_URL') -and $loadedCfg['SHELLOSSUS_BASE_URL']) {
    [string]$loadedCfg['SHELLOSSUS_BASE_URL']
}
else { '' }

$effectiveModel = if ($argModel -and $argModel.Trim()) {
    $argModel.Trim()
}
elseif ($env:SHELLOSSUS_MODEL -and $env:SHELLOSSUS_MODEL.Trim()) {
    $env:SHELLOSSUS_MODEL.Trim()
}
elseif ($loadedCfg.ContainsKey('SHELLOSSUS_MODEL') -and $loadedCfg['SHELLOSSUS_MODEL']) {
    [string]$loadedCfg['SHELLOSSUS_MODEL']
}
else { '' }

$effectiveApiKey = if ($argApiKey -and $argApiKey.Trim()) {
    $argApiKey.Trim()
}
elseif ($env:SHELLOSSUS_API_KEY -and $env:SHELLOSSUS_API_KEY.Trim()) {
    $env:SHELLOSSUS_API_KEY.Trim()
}
elseif ($loadedCfg.ContainsKey('SHELLOSSUS_API_KEY') -and $loadedCfg['SHELLOSSUS_API_KEY']) {
    [string]$loadedCfg['SHELLOSSUS_API_KEY']
}
else { '' }

if (-not $effectiveBaseUrl) {
    throw 'BaseUrl is required. Pass -BaseUrl, set SHELLOSSUS_BASE_URL, or provide -ConfigPath.'
}
if (-not $effectiveModel) {
    throw 'Model is required. Pass -Model, set SHELLOSSUS_MODEL, or provide -ConfigPath.'
}
$hasRealApiKey = [bool]$effectiveApiKey
if (-not $hasRealApiKey) {
    if (Test-IsLoopbackBaseUrl -Url $effectiveBaseUrl) {
        $effectiveApiKey = 'local'
    }
    else {
        throw 'ApiKey is required for non-loopback endpoints. Set SHELLOSSUS_API_KEY, pass -ApiKey, or provide -ConfigPath.'
    }
}

$shellExe = if ($PSVersionTable.PSEdition -eq 'Core') {
    if ($env:OS -eq 'Windows_NT') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }
}
else {
    Join-Path $PSHOME 'powershell.exe'
}

$baseTemp = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
if ($env:OS -ne 'Windows_NT' -and (Test-PathHasReparsePoint -Path $baseTemp)) {
    $physicalCandidate = '/private' + $baseTemp
    if ((Test-Path -LiteralPath $physicalCandidate) -and -not (Test-PathHasReparsePoint -Path $physicalCandidate)) {
        $baseTemp = $physicalCandidate
    }
}

$e2eRoot = Join-Path $baseTemp ('shellossus-live-e2e-' + [guid]::NewGuid().ToString('N'))
$workspaceDir = Join-Path $e2eRoot 'workspace'
$isolatedCfgDir = Join-Path $e2eRoot 'config'
New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
New-Item -ItemType Directory -Path $isolatedCfgDir -Force | Out-Null
$e2eRoot = (Get-Item -LiteralPath $e2eRoot -Force).FullName
$workspaceDir = (Get-Item -LiteralPath $workspaceDir -Force).FullName
$isolatedCfgPath = Join-Path (Get-Item -LiteralPath $isolatedCfgDir -Force).FullName '.env'

function Format-E2eQuotedArg {
    param([string]$Value)
    $escaped = ($Value -replace '(\\*)"', '$1$1\"') -replace '(\\*)$', '$1$1'
    return ('"' + $escaped + '"')
}

function Invoke-E2eRunner {
    param(
        [hashtable]$Spec,
        [int]$TimeoutSec = 180
    )
    $specPath = Join-Path $e2eRoot ('spec-' + [guid]::NewGuid().ToString('N') + '.json')
    $runnerPath = Join-Path $e2eRoot ('run-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $stdoutPath = Join-Path $e2eRoot ('out-' + [guid]::NewGuid().ToString('N') + '.log')
    $stderrPath = Join-Path $e2eRoot ('err-' + [guid]::NewGuid().ToString('N') + '.log')

    $specJson = ConvertTo-AsciiJson -Json ($Spec | ConvertTo-Json -Depth 10 -Compress)
    Set-AgentUtf8Content -LiteralPath $specPath -Value $specJson

    $runnerCode = @'
param([string]$SpecFile)
$ErrorActionPreference = 'Stop'
$spec = Get-Content -LiteralPath $SpecFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($spec.mode -eq 'compact') {
    . $spec.agent_script -LibraryOnly
    $endpoint = ($spec.base_url.TrimEnd('/')) + '/chat/completions'
    $script:RequestTimeoutSec = [int]$spec.timeout_sec
    $script:OutputMode = 'json'
    $state = @{
        session_id = 'live-e2e-compact'
        workspace = $spec.workspace
        model = $spec.model
        messages = @(
            @{ role = 'system'; content = 'You are a concise assistant.' },
            @{ role = 'user'; content = 'Project setup note: Always use port 8443 for the API listener and keep TLS enabled.' },
            @{ role = 'assistant'; content = 'Noted. I will always use port 8443 with TLS enabled.' },
            @{ role = 'user'; content = 'Also log audit events to audit.log in JSON format.' },
            @{ role = 'assistant'; content = 'Understood. Audit events will be written to audit.log as JSON.' },
            @{ role = 'user'; content = 'We finished reviewing the database migration plan.' },
            @{ role = 'assistant'; content = 'Great, ready for the next task.' },
            @{ role = 'user'; content = 'Recent question: what file holds the schema?' },
            @{ role = 'assistant'; content = 'Recent answer: schema.sql.' }
        )
    }
    $didCompact = Invoke-AgentCompact -State $state -Endpoint $endpoint -ModelId $spec.model -ApiKey $env:SHELLOSSUS_API_KEY -KeepRecent 2
    $summaryText = if ($state.messages.Count -ge 2) { [string]$state.messages[1].content } else { '' }
    $lastContent = if ($state.messages.Count -ge 1) { [string]$state.messages[-1].content } else { '' }
    $result = @{
        compacted = [bool]$didCompact
        message_count = $state.messages.Count
        summary = $summaryText
        last_content = $lastContent
    }
    Write-Output (ConvertTo-AsciiJson -Json ($result | ConvertTo-Json -Depth 6 -Compress))
    exit 0
}
$cliArgs = @{
    BaseUrl = [string]$spec.base_url
    Model = [string]$spec.model
    Workspace = [string]$spec.workspace
    ConfigPath = [string]$spec.config_path
    Mode = 'json'
    RequestTimeoutSec = [int]$spec.timeout_sec
}
if ($spec.doctor) {
    $cliArgs['Doctor'] = $true
}
else {
    $cliArgs['NoSession'] = $true
    $cliArgs['Permission'] = [string]$spec.permission
    $cliArgs['Prompt'] = [string]$spec.prompt
    if ($spec.no_tools) { $cliArgs['NoTools'] = $true }
    if ($spec.stream) { $cliArgs['Stream'] = $true }
    if ($spec.max_steps) { $cliArgs['MaxSteps'] = [int]$spec.max_steps }
}
if ($spec.constrained_language) {
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
}
$global:LASTEXITCODE = 0
& $spec.agent_script @cliArgs
if ($null -ne $LASTEXITCODE) { exit [int]$LASTEXITCODE }
exit 0
'@
    Set-Content -LiteralPath $runnerPath -Value $runnerCode -Encoding Ascii

    $proc = $null
    try {
        $startArgList = if ($env:OS -eq 'Windows_NT') {
            '-NoProfile -File ' + (Format-E2eQuotedArg -Value $runnerPath) + ' -SpecFile ' + (Format-E2eQuotedArg -Value $specPath)
        }
        else {
            $runnerArg = if ($runnerPath -match '[\s"]') { Format-E2eQuotedArg -Value $runnerPath } else { $runnerPath }
            $specArg = if ($specPath -match '[\s"]') { Format-E2eQuotedArg -Value $specPath } else { $specPath }
            @('-NoProfile', '-File', $runnerArg, '-SpecFile', $specArg)
        }
        $proc = Start-Process -FilePath $shellExe -ArgumentList $startArgList -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -PassThru -ErrorAction Stop
        # Touch Handle immediately so Windows PowerShell 5.1 populates ExitCode reliably after exit.
        try { $null = $proc.Handle } catch {}
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not $proc.HasExited) {
            if ((Get-Date) -gt $deadline) {
                Stop-Process -InputObject $proc -Force -ErrorAction SilentlyContinue
                throw "Scenario process timed out after ${TimeoutSec}s."
            }
            Start-Sleep -Milliseconds 200
        }
        try { $proc.WaitForExit() } catch {}
        $exitCode = if ($null -ne $proc.ExitCode) { [int]$proc.ExitCode } else { -1 }
        $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { [string](Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrPath) { [string](Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) } else { '' }
        return @{
            exit_code = $exitCode
            stdout = $stdoutText
            stderr = $stderrText
        }
    }
    finally {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -InputObject $proc -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $specPath, $runnerPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-E2eJsonLines {
    param([AllowEmptyString()][string]$RawText)
    $events = @()
    if (-not $RawText) { return @() }
    foreach ($line in @($RawText -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $events += ($trimmed | ConvertFrom-Json -ErrorAction Stop)
    }
    return @($events)
}

function Assert-NoApiKeyLeak {
    param([AllowEmptyString()][string]$Text, [string]$Secret, [bool]$IsRealSecret)
    if ($IsRealSecret -and $Secret -and $Secret.Length -ge 6 -and $Text -and $Text.Contains($Secret)) {
        throw 'API key leaked into scenario output.'
    }
}

$results = @()
function Invoke-E2eScenario {
    param([string]$Name, [scriptblock]$Body, [switch]$Skip, [string]$SkipReason = '')
    if ($Skip) {
        $script:results += @{ name = $Name; status = 'SKIP'; elapsed_sec = 0.0; detail = $SkipReason }
        return
    }
    $sw = Get-Date
    try {
        $detail = & $Body
        $elapsed = [math]::Round(((Get-Date) - $sw).TotalSeconds, 2)
        $script:results += @{ name = $Name; status = 'PASS'; elapsed_sec = $elapsed; detail = ([string]$detail) }
    }
    catch {
        $elapsed = [math]::Round(((Get-Date) - $sw).TotalSeconds, 2)
        $errMsg = ([string]$_.Exception.Message) -replace '[\r\n]+', ' '
        if ($hasRealApiKey -and $effectiveApiKey.Length -ge 6) {
            $errMsg = $errMsg.Replace($effectiveApiKey, '[redacted]')
        }
        if ($errMsg.Length -gt 200) { $errMsg = $errMsg.Substring(0, 200) + '...' }
        $script:results += @{ name = $Name; status = 'FAIL'; elapsed_sec = $elapsed; detail = $errMsg }
    }
}

$isolatedEnvMap = @{
    SHELLOSSUS_API_KEY = $effectiveApiKey
    SHELLOSSUS_BASE_URL = $null
    SHELLOSSUS_MODEL = $null
    SHELLOSSUS_WORKSPACE = $null
    SHELLOSSUS_CONTEXT_WINDOW = $null
    SHELLOSSUS_COMPACT_THRESHOLD = $null
    SHELLOSSUS_REQUEST_TIMEOUT_SEC = $null
    SHELLOSSUS_STREAM = $null
    SHELLOSSUS_THEME = $null
    SHELLOSSUS_SEARCH_URL = $null
    OPENAI_API_KEY = $null
}

$runStart = Get-Date

try {
    Invoke-WithProcessEnvironment -Values $isolatedEnvMap -Action {
        Write-Host ("Shellossus live E2E | endpoint={0} | model={1} | shell={2}" -f $effectiveBaseUrl, $effectiveModel, $PSVersionTable.PSVersion)

        # 1. -Doctor -Mode json
        Invoke-E2eScenario -Name 'doctor-json' -Body {
            $res = Invoke-E2eRunner -Spec @{
                mode = 'cli'
                agent_script = $agentScript
                base_url = $effectiveBaseUrl
                model = $effectiveModel
                workspace = $workspaceDir
                config_path = $isolatedCfgPath
                timeout_sec = $argTimeoutSec
                doctor = $true
            } -TimeoutSec ($argTimeoutSec + 30)
            Assert-NoApiKeyLeak -Text ($res.stdout + "`n" + $res.stderr) -Secret $effectiveApiKey -IsRealSecret $hasRealApiKey
            if ($res.exit_code -ne 0) {
                throw "Doctor exited with code $($res.exit_code): $($res.stderr)"
            }
            $docObj = $res.stdout.Trim() | ConvertFrom-Json -ErrorAction Stop
            if ($docObj.type -cne 'doctor' -or [int]$docObj.failures -ne 0 -or -not $docObj.version) {
                throw "Unexpected doctor JSON payload (type=$($docObj.type), failures=$($docObj.failures), version=$($docObj.version))."
            }
            return "v$($docObj.version), warnings=$($docObj.warnings)"
        }

        # 2. Cyrillic UTF-8 chat (-Mode json)
        Invoke-E2eScenario -Name 'chat-cyrillic-json' -Body {
            $cyrToken = ([string][char]0x041F) + ([string][char]0x0420) + ([string][char]0x041E) + ([string][char]0x0412) + ([string][char]0x0415) + ([string][char]0x0420) + ([string][char]0x041A) + ([string][char]0x0410)
            $cyrPrompt = (([string][char]0x041E) + ([string][char]0x0442) + ([string][char]0x0432) + ([string][char]0x0435) + ([string][char]0x0442) + ([string][char]0x044C) + ' ' + ([string][char]0x043E) + ([string][char]0x0434) + ([string][char]0x043D) + ([string][char]0x0438) + ([string][char]0x043C) + ' ' + ([string][char]0x0441) + ([string][char]0x043B) + ([string][char]0x043E) + ([string][char]0x0432) + ([string][char]0x043E) + ([string][char]0x043C) + ': ' + $cyrToken)
            $res = Invoke-E2eRunner -Spec @{
                mode = 'cli'
                agent_script = $agentScript
                base_url = $effectiveBaseUrl
                model = $effectiveModel
                workspace = $workspaceDir
                config_path = $isolatedCfgPath
                timeout_sec = $argTimeoutSec
                permission = 'ReadOnly'
                no_tools = $true
                prompt = $cyrPrompt
            } -TimeoutSec ($argTimeoutSec + 60)
            Assert-NoApiKeyLeak -Text ($res.stdout + "`n" + $res.stderr) -Secret $effectiveApiKey -IsRealSecret $hasRealApiKey
            if ($res.exit_code -ne 0) { throw "Exit $($res.exit_code): $($res.stderr)" }
            $events = @(ConvertFrom-E2eJsonLines -RawText $res.stdout)
            $turnEnd = @($events | Where-Object { $_.type -eq 'turn_end' }) | Select-Object -Last 1
            $msgEnd = @($events | Where-Object { $_.type -eq 'message_end' -and $_.role -eq 'assistant' }) | Select-Object -Last 1
            if (-not $turnEnd -or $turnEnd.status -ne 'completed') { throw 'Missing completed turn_end event.' }
            if (-not $msgEnd -or -not $msgEnd.content -or -not ([string]$msgEnd.content).Trim()) { throw 'Assistant returned empty content.' }
            if (([string]$msgEnd.content) -notmatch '[\u0400-\u04FF]') { throw "Expected Cyrillic reply, got: $($msgEnd.content)" }
            return "completed (chars=$(([string]$msgEnd.content).Length))"
        }

        # 3. Tool calling roundtrip (write_file -> read_file -> edit_file -> grep_files)
        Invoke-E2eScenario -Name 'tools-roundtrip-autoedit' -Body {
            $toolPrompt = 'Perform these exact steps using tools in order: 1) Call write_file to create e2e-note.txt with two lines: "alpha line" and "beta line". 2) Call read_file on e2e-note.txt. 3) Call edit_file on e2e-note.txt replacing "beta line" with "gamma line". 4) Call grep_files with path "." and pattern "gamma". 5) Reply with TOOLS_OK.'
            $res = Invoke-E2eRunner -Spec @{
                mode = 'cli'
                agent_script = $agentScript
                base_url = $effectiveBaseUrl
                model = $effectiveModel
                workspace = $workspaceDir
                config_path = $isolatedCfgPath
                timeout_sec = $argTimeoutSec
                permission = 'AutoEdit'
                max_steps = 12
                prompt = $toolPrompt
            } -TimeoutSec (($argTimeoutSec * 2) + 60)
            Assert-NoApiKeyLeak -Text ($res.stdout + "`n" + $res.stderr) -Secret $effectiveApiKey -IsRealSecret $hasRealApiKey
            if ($res.exit_code -ne 0) { throw "Exit $($res.exit_code): $($res.stderr)" }
            $events = @(ConvertFrom-E2eJsonLines -RawText $res.stdout)
            $turnEnd = @($events | Where-Object { $_.type -eq 'turn_end' }) | Select-Object -Last 1
            if (-not $turnEnd -or $turnEnd.status -ne 'completed') { throw 'Missing completed turn_end event.' }
            $calledTools = @($events | Where-Object { $_.type -eq 'tool_execution_end' } | ForEach-Object { [string]$_.name } | Select-Object -Unique)
            foreach ($reqTool in @('write_file', 'read_file', 'edit_file', 'grep_files')) {
                if ($calledTools -notcontains $reqTool) {
                    throw "Expected tool '$reqTool' was not called (saw: $($calledTools -join ','))."
                }
            }
            $notePath = Join-Path $workspaceDir 'e2e-note.txt'
            if (-not (Test-Path -LiteralPath $notePath)) { throw 'e2e-note.txt was not created on disk.' }
            $noteContent = Get-Content -LiteralPath $notePath -Raw -Encoding UTF8
            if (-not $noteContent.Contains('alpha line') -or -not $noteContent.Contains('gamma line') -or $noteContent.Contains('beta line')) {
                throw "Unexpected e2e-note.txt content: $noteContent"
            }
            return "tools=$($calledTools -join ',')"
        }

        # 4. Streaming SSE roundtrip (-Stream)
        Invoke-E2eScenario -Name 'stream-roundtrip' -Body {
            $streamPrompt = 'Use write_file to create stream-check.txt containing "stream-v1", then use edit_file to replace "stream-v1" with "stream-v2", then reply STREAM_OK.'
            $res = Invoke-E2eRunner -Spec @{
                mode = 'cli'
                agent_script = $agentScript
                base_url = $effectiveBaseUrl
                model = $effectiveModel
                workspace = $workspaceDir
                config_path = $isolatedCfgPath
                timeout_sec = $argTimeoutSec
                permission = 'AutoEdit'
                stream = $true
                max_steps = 10
                prompt = $streamPrompt
            } -TimeoutSec (($argTimeoutSec * 2) + 60)
            Assert-NoApiKeyLeak -Text ($res.stdout + "`n" + $res.stderr) -Secret $effectiveApiKey -IsRealSecret $hasRealApiKey
            if ($res.exit_code -ne 0) { throw "Exit $($res.exit_code): $($res.stderr)" }
            $events = @(ConvertFrom-E2eJsonLines -RawText $res.stdout)
            $turnEnd = @($events | Where-Object { $_.type -eq 'turn_end' }) | Select-Object -Last 1
            if (-not $turnEnd -or $turnEnd.status -ne 'completed') { throw 'Missing completed turn_end event in -Stream mode.' }
            $streamFile = Join-Path $workspaceDir 'stream-check.txt'
            if (-not (Test-Path -LiteralPath $streamFile)) { throw 'stream-check.txt was not created.' }
            $streamBody = Get-Content -LiteralPath $streamFile -Raw -Encoding UTF8
            if (-not $streamBody.Contains('stream-v2')) { throw "Unexpected stream-check.txt content: $streamBody" }
            return 'SSE verified + file updated'
        }

        # 5. Compaction check (Invoke-AgentCompact)
        Invoke-E2eScenario -Name 'compact-check' -Skip:$SkipCompaction -SkipReason 'Skipped via -SkipCompaction' -Body {
            $res = Invoke-E2eRunner -Spec @{
                mode = 'compact'
                agent_script = $agentScript
                base_url = $effectiveBaseUrl
                model = $effectiveModel
                workspace = $workspaceDir
                config_path = $isolatedCfgPath
                timeout_sec = $argTimeoutSec
            } -TimeoutSec ($argTimeoutSec + 60)
            Assert-NoApiKeyLeak -Text ($res.stdout + "`n" + $res.stderr) -Secret $effectiveApiKey -IsRealSecret $hasRealApiKey
            if ($res.exit_code -ne 0) { throw "Exit $($res.exit_code): $($res.stderr)" }
            $compObj = $res.stdout.Trim() | ConvertFrom-Json -ErrorAction Stop
            if (-not $compObj.compacted) { throw 'Invoke-AgentCompact returned false.' }
            if (-not $compObj.summary -or -not ([string]$compObj.summary).Contains('8443')) {
                throw 'Compacted summary did not preserve key constraint (port 8443).'
            }
            if ([string]$compObj.last_content -notlike '*schema.sql*') {
                throw 'Compaction did not retain the most recent message.'
            }
            return "messages=$($compObj.message_count), preserved port 8443"
        }

        # 6. Optional ConstrainedLanguage cold-start check
        Invoke-E2eScenario -Name 'constrained-language' -Skip:(-not $IncludeConstrainedLanguage) -SkipReason 'Opt-in via -IncludeConstrainedLanguage' -Body {
            $res = Invoke-E2eRunner -Spec @{
                mode = 'cli'
                agent_script = $agentScript
                base_url = $effectiveBaseUrl
                model = $effectiveModel
                workspace = $workspaceDir
                config_path = $isolatedCfgPath
                timeout_sec = $argTimeoutSec
                permission = 'ReadOnly'
                no_tools = $true
                constrained_language = $true
                prompt = 'Reply with exactly: CLM_LIVE_OK'
            } -TimeoutSec ($argTimeoutSec + 60)
            Assert-NoApiKeyLeak -Text ($res.stdout + "`n" + $res.stderr) -Secret $effectiveApiKey -IsRealSecret $hasRealApiKey
            if ($res.exit_code -ne 0) { throw "Exit $($res.exit_code): $($res.stderr)" }
            $events = @(ConvertFrom-E2eJsonLines -RawText $res.stdout)
            $turnEnd = @($events | Where-Object { $_.type -eq 'turn_end' }) | Select-Object -Last 1
            $msgEnd = @($events | Where-Object { $_.type -eq 'message_end' -and $_.role -eq 'assistant' }) | Select-Object -Last 1
            if (-not $turnEnd -or $turnEnd.status -ne 'completed') { throw 'Missing completed turn_end event in ConstrainedLanguage.' }
            if (-not $msgEnd -or -not ([string]$msgEnd.content).Trim()) { throw 'Empty reply in ConstrainedLanguage.' }
            return 'cold-start CLM completed'
        }
    }
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $e2eRoot)) {
        Remove-Item -LiteralPath $e2eRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$totalElapsed = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 2)
Write-Host ''
Write-Host ('{0,-26} {1,-6} {2,8}  {3}' -f 'Scenario', 'Status', 'Time(s)', 'Details')
Write-Host ('{0,-26} {1,-6} {2,8}  {3}' -f ('-' * 26), ('-' * 6), ('-' * 8), ('-' * 40))
foreach ($row in $results) {
    Write-Host ('{0,-26} {1,-6} {2,8:N2}  {3}' -f $row.name, $row.status, $row.elapsed_sec, $row.detail)
}

$passedCount = @($results | Where-Object { $_.status -eq 'PASS' }).Count
$failedCount = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
$skippedCount = @($results | Where-Object { $_.status -eq 'SKIP' }).Count
Write-Host ''
Write-Host ("Summary: {0} passed, {1} failed, {2} skipped ({3:N2}s total)" -f $passedCount, $failedCount, $skippedCount, $totalElapsed)
if ($KeepWorkspace) {
    Write-Host ("Workspace kept at: {0}" -f $e2eRoot)
}

if ($failedCount -gt 0) { exit 1 }
exit 0
