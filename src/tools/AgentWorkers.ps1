# Standalone script resolution, subagent aggregate status, shared subagent error results, and parallel ReadOnly worker process pool.

function Resolve-StandaloneScriptPath {
    if ($script:StandaloneScriptPath -and (Test-Path -LiteralPath $script:StandaloneScriptPath)) {
        return (Get-Item -LiteralPath $script:StandaloneScriptPath -Force).FullName
    }
    $cands = @()
    if ($PSScriptRoot) {
        $cands += (Join-Path $PSScriptRoot 'shellossus.ps1')
        $parentDir = Split-Path $PSScriptRoot -Parent
        if ($parentDir) { $cands += (Join-Path $parentDir 'shellossus.ps1') }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Get-Item -LiteralPath $c -Force).FullName
        }
    }
    return ''
}

function Resolve-SubagentAggregateStatus {
    param([array]$Results)
    if (-not $Results -or $Results.Count -eq 0) { return 'completed' }
    $statuses = @($Results | ForEach-Object { [string]$_.status })
    if ($statuses -contains 'error') { return 'error' }
    if ($statuses -contains 'timed_out') { return 'timed_out' }
    if ($statuses -contains 'loop_detected') { return 'loop_detected' }
    if ($statuses -contains 'step_limit_reached') { return 'step_limit_reached' }
    foreach ($st in $statuses) {
        if ($st -and $st -ne 'completed') { return $st }
    }
    return 'completed'
}

function New-SubagentErrorResult {
    param(
        [string]$Role,
        [string]$Context,
        [string]$Message,
        [string]$Permission = 'ReadOnly',
        [AllowEmptyCollection()][string[]]$ModifiedFiles = @()
    )
    $files = @()
    $seen = @{}
    foreach ($mf in @($ModifiedFiles)) {
        $rel = [string]$mf
        if (-not $rel) { continue }
        if ($seen.ContainsKey($rel)) { continue }
        $seen[$rel] = $true
        $files += $rel
    }
    $result = @{
        role = $Role
        permission = $Permission
        context = $Context
        status = 'error'
        output = ('Subagent error: ' + $Message)
        steps_used = 0
        read_files = @()
        modified_files = $files
        usage_input_tokens = 0
        usage_output_tokens = 0
    }
    return $result
}

function Get-AgentWorkerErrorText {
    param([string]$Raw)
    if (-not $Raw) { return '' }
    $text = $Raw.Trim()
    if (-not $text) { return '' }
    # Windows PowerShell sends progress records, including "Preparing modules for first use.",
    # to a redirected error stream as CLIXML. Drop that host noise and keep any real text.
    if (-not $text.StartsWith('#< CLIXML')) { return $text }
    $text = $text -replace '(?s)<Obj S="progress".*?</Obj>', ''
    $text = $text -replace "(?s)<Obj S='progress'.*?</Obj>", ''
    if ($text -match '<S N="Message">([^<]*)</S>') { return $Matches[1].Trim() }
    $text = $text -replace '(?s)#< CLIXML', ''
    $text = $text -replace '(?s)<Objs\b[^>]*>\s*</Objs>', ''
    return $text.Trim()
}

function Invoke-ParallelSubagentProcesses {
    param([string]$Root, [array]$Tasks, [int]$MaxSteps = 15, [string]$ScriptPath, [int]$TimeoutSec = 180, [string]$ApiKey)
    $configDir = if ($script:AgentConfigPath) { Split-Path $script:AgentConfigPath -Parent } else { '' }
    $shellExe = Get-AgentPowerShellExecutable
    $effEndpoint = if ($script:ActiveEndpoint) { $script:ActiveEndpoint } else { 'https://example.invalid/v1/chat/completions' }
    $baseUrl = $effEndpoint -replace '/chat/completions/?$', ''
    $effKey = if ($ApiKey) { $ApiKey } else { 'subagent-key' }
    $workerCmd = @'
$ErrorActionPreference = 'Stop'
$pText = Get-Content -LiteralPath $env:SHELLOSSUS_SUB_PROMPT -Raw -Encoding UTF8
$workerArgs = @{
    Workspace = $env:SHELLOSSUS_SUB_ROOT
    BaseUrl = $env:SHELLOSSUS_SUB_BASEURL
    Model = $env:SHELLOSSUS_SUB_MODEL
    Permission = 'ReadOnly'
    Mode = 'json'
    NoSession = $true
    MaxSteps = [int]$env:SHELLOSSUS_SUB_STEPS
    Tools = $env:SHELLOSSUS_SUB_TOOLS
    NoTools = ($env:SHELLOSSUS_SUB_NO_TOOLS -eq '1')
    ExcludeTools = 'run_agent'
    Prompt = $pText
    LiteralPrompt = $true
}
if ($env:SHELLOSSUS_SUB_CONFIG) { $workerArgs.ConfigPath = $env:SHELLOSSUS_SUB_CONFIG }
if ($env:SHELLOSSUS_SUB_NO_SKILLS -eq '1') { $workerArgs.NoSkills = $true }
if ($env:SHELLOSSUS_SUB_NO_TEMPLATES -eq '1') { $workerArgs.NoPromptTemplates = $true }
if ($env:SHELLOSSUS_SUB_NO_CONTEXT -eq '1') { $workerArgs.NoContextFiles = $true }
if ($env:SHELLOSSUS_SUB_REASONING_EFFORT) { $workerArgs.ReasoningEffort = $env:SHELLOSSUS_SUB_REASONING_EFFORT }
& $env:SHELLOSSUS_SUB_SCRIPT @workerArgs
'@
    $argList = Get-AgentWorkerArguments -CommandText $workerCmd
    $allResults = @()
    $batchSize = 4
    for ($offset = 0; $offset -lt $Tasks.Count; $offset += $batchSize) {
        $endIdx = $offset + $batchSize - 1
        if ($endIdx -ge $Tasks.Count) { $endIdx = $Tasks.Count - 1 }
        $workers = @()
        try {
            for ($i = $offset; $i -le $endIdx; $i++) {
                $t = $Tasks[$i]
                $rName = if ($t.role) { [string]$t.role } else { 'recon' }
                $roleObj = Resolve-AgentRole -Name $rName -Root $Root -ConfigDir $configDir
                $childTools = @(Get-SubagentToolNames -Role $roleObj -ForceReadOnly -NonInteractive)
                $effModel = if ($roleObj.model) { [string]$roleObj.model } elseif ($script:ActiveModelId) { $script:ActiveModelId } else { 'test-model' }
                $promptTemp = New-AgentTempFile
                $outTemp = New-AgentTempFile
                $errTemp = New-AgentTempFile
                $fullPrompt = [string]$t.prompt
                Set-AgentUtf8Content -LiteralPath $promptTemp.FullName -Value $fullPrompt
                if ($script:OutputMode -ne 'json') {
                    Write-Host ($script:Gm.Aqua + ("  [run_agent:{0}] (parallel ReadOnly) " -f (Format-TuiText $roleObj.name)) + $script:Gm.Grey1 + (Invoke-TruncateLine -Line (Format-TuiText $t.prompt) -MaxChars 90).text + $script:Gm.Reset)
                }
                $proc = Invoke-WithProcessEnvironment -Values @{
                    SHELLOSSUS_API_KEY = $effKey
                    OPENAI_API_KEY = $null
                    SHELLOSSUS_SUB_SCRIPT = $ScriptPath
                    SHELLOSSUS_SUB_ROOT = $Root
                    SHELLOSSUS_SUB_BASEURL = $baseUrl
                    SHELLOSSUS_SUB_MODEL = $effModel
                    SHELLOSSUS_SUB_STEPS = [string]$MaxSteps
                    SHELLOSSUS_SUB_PROMPT = $promptTemp.FullName
                    SHELLOSSUS_SUB_TOOLS = ($childTools -join ',')
                    SHELLOSSUS_SUB_NO_TOOLS = $(if ($childTools.Count -eq 0) { '1' } else { '0' })
                    SHELLOSSUS_SUB_CONFIG = $script:AgentConfigPath
                    SHELLOSSUS_SUB_NO_SKILLS = $(if ($script:NoSkills) { '1' } else { '0' })
                    SHELLOSSUS_SUB_NO_TEMPLATES = $(if ($script:NoPromptTemplates) { '1' } else { '0' })
                    SHELLOSSUS_SUB_NO_CONTEXT = $(if ($script:NoContextFiles) { '1' } else { '0' })
                    SHELLOSSUS_SUB_REASONING_EFFORT = $(if ($script:ReasoningEffort) { [string]$script:ReasoningEffort } else { '' })
                    SHELLOSSUS_SUB_AUTO_WEB = $(if ($script:AutoApproveWeb) { '1' } else { '0' })
                    SHELLOSSUS_SUB_ROLE = [string]$roleObj.name
                    SHELLOSSUS_SUB_ROLE_PROMPT = [string]$roleObj.system_prompt
                } -Action {
                    Start-Process -FilePath $shellExe -ArgumentList $argList -WorkingDirectory $Root -RedirectStandardOutput $outTemp.FullName -RedirectStandardError $errTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
                }
                $workers += @{
                    role = $roleObj.name
                    proc = $proc
                    prompt_file = $promptTemp.FullName
                    out_file = $outTemp.FullName
                    err_file = $errTemp.FullName
                    timed_out = $false
                }
            }
            $startWait = Get-Date
            while ($true) {
                $running = @($workers | Where-Object { -not $_.proc.HasExited })
                if ($running.Count -eq 0) { break }
                if (((Get-Date) - $startWait).TotalSeconds -ge $TimeoutSec) {
                    foreach ($rw in $running) {
                        $rw.timed_out = $true
                        $null = Stop-AgentProcessTree -Process $rw.proc
                        Wait-Process -InputObject $rw.proc -Timeout 2 -ErrorAction SilentlyContinue
                    }
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            foreach ($w in $workers) {
                $replyText = ''
                $stepsUsed = 0
                $wReadSet = @{}
                $pendingReadsById = [hashtable]::new([StringComparer]::Ordinal)
                $untrackedReads = @()
                $sawToolExecEnd = $false
                $sawTurnEnd = $false
                $msgUsageIn = 0
                $msgUsageOut = 0
                $turnUsageIn = -1
                $turnUsageOut = -1
                $wStatus = 'completed'
                if (Test-Path -LiteralPath $w.out_file) {
                    foreach ($line in @(Get-Content -LiteralPath $w.out_file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                        $trimmed = ([string]$line).Trim()
                        if (-not $trimmed.StartsWith('{')) { continue }
                        try {
                            $ev = $trimmed | ConvertFrom-Json -ErrorAction Stop
                            if ($ev.type -eq 'message_end' -and $ev.role -eq 'assistant') {
                                $stepsUsed++
                                if ($ev.content) { $replyText = [string]$ev.content }
                                if ($ev.usage) {
                                    if ($ev.usage.prompt_tokens) { $msgUsageIn += [int]$ev.usage.prompt_tokens }
                                    elseif ($ev.usage.input_tokens) { $msgUsageIn += [int]$ev.usage.input_tokens }
                                    if ($ev.usage.completion_tokens) { $msgUsageOut += [int]$ev.usage.completion_tokens }
                                    elseif ($ev.usage.output_tokens) { $msgUsageOut += [int]$ev.usage.output_tokens }
                                }
                                if ($ev.usage_input_tokens) { $msgUsageIn += [int]$ev.usage_input_tokens }
                                if ($ev.usage_output_tokens) { $msgUsageOut += [int]$ev.usage_output_tokens }
                                if ($ev.tool_calls) {
                                    foreach ($tc in @($ev.tool_calls)) {
                                        $fn = if ($tc.function -and $tc.function.name) { [string]$tc.function.name } else { '' }
                                        if ($fn -in @('read_file', 'read') -and $tc.function.arguments) {
                                            try {
                                                $pa = ([string]$tc.function.arguments) | ConvertFrom-Json -ErrorAction Stop
                                                $pa = Format-AgentToolArguments -Name 'read_file' -Arguments $pa
                                                if ($pa.path) {
                                                    if ($tc.id) { $pendingReadsById[[string]$tc.id] = [string]$pa.path }
                                                    else { $untrackedReads += [string]$pa.path }
                                                }
                                            }
                                            catch {}
                                        }
                                    }
                                }
                            }
                            elseif ($ev.type -eq 'tool_execution_end') {
                                $sawToolExecEnd = $true
                                $evId = if ($ev.id) { [string]$ev.id } else { '' }
                                if ($evId -and $pendingReadsById.ContainsKey($evId)) {
                                    $rPath = $pendingReadsById[$evId]
                                    try {
                                        $parsedToolRes = ([string]$ev.result) | ConvertFrom-Json -ErrorAction Stop
                                        if ($null -ne $parsedToolRes -and (-not $parsedToolRes.error) -and ($parsedToolRes.status -notin @('cancelled', 'instructions_required', 'repeated_call_warning', 'loop_detected', 'error'))) {
                                            $wReadSet[$rPath] = $true
                                        }
                                    }
                                    catch {}
                                }
                            }
                            elseif ($ev.type -eq 'turn_end') {
                                $sawTurnEnd = $true
                                if ($ev.status) { $wStatus = [string]$ev.status }
                                if ($null -ne $ev.usage_input_tokens) { $turnUsageIn = [int]$ev.usage_input_tokens }
                                if ($null -ne $ev.usage_output_tokens) { $turnUsageOut = [int]$ev.usage_output_tokens }
                                if ($ev.usage) {
                                    if ($null -ne $ev.usage.prompt_tokens) { $turnUsageIn = [int]$ev.usage.prompt_tokens }
                                    elseif ($null -ne $ev.usage.input_tokens) { $turnUsageIn = [int]$ev.usage.input_tokens }
                                    if ($null -ne $ev.usage.completion_tokens) { $turnUsageOut = [int]$ev.usage.completion_tokens }
                                    elseif ($null -ne $ev.usage.output_tokens) { $turnUsageOut = [int]$ev.usage.output_tokens }
                                }
                            }
                        }
                        catch {}
                    }
                }
                if (-not $w.timed_out -and (Test-Path -LiteralPath $w.err_file)) {
                    $errRaw = Get-Content -LiteralPath $w.err_file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    $errText = Get-AgentWorkerErrorText -Raw $errRaw
                    if ($errText -and (-not $sawTurnEnd -or -not $replyText)) {
                        $wStatus = 'error'
                        $replyText = if ($replyText) { $replyText + "`nSubagent error: " + $errText } else { 'Subagent error: ' + $errText }
                    }
                }
                if (-not $sawTurnEnd -and $w.timed_out) {
                    $wStatus = 'timed_out'
                    if (-not $replyText) {
                        $replyText = "Subagent timed out after ${TimeoutSec}s."
                    }
                }
                elseif (-not $sawTurnEnd -and $wStatus -eq 'completed' -and $w.proc -and $w.proc.HasExited -and $w.proc.ExitCode -ne 0) {
                    $wStatus = 'error'
                }
                if (-not $sawToolExecEnd -and $sawTurnEnd -and (-not $w.timed_out) -and $wStatus -eq 'completed') {
                    foreach ($ur in $untrackedReads) { $wReadSet[$ur] = $true }
                    foreach ($pr in $pendingReadsById.Values) { $wReadSet[$pr] = $true }
                }
                $wUsageIn = if ($turnUsageIn -ge 0) { $turnUsageIn } else { $msgUsageIn }
                $wUsageOut = if ($turnUsageOut -ge 0) { $turnUsageOut } else { $msgUsageOut }
                if ($null -ne $script:ActiveState) {
                    if ($wUsageIn -gt 0) { $script:ActiveState.usage_input_tokens = [int]$script:ActiveState.usage_input_tokens + $wUsageIn }
                    if ($wUsageOut -gt 0) { $script:ActiveState.usage_output_tokens = [int]$script:ActiveState.usage_output_tokens + $wUsageOut }
                }
                $allResults += @{
                    role = $w.role
                    permission = 'ReadOnly'
                    context = 'clean'
                    status = $wStatus
                    output = $replyText
                    steps_used = $stepsUsed
                    read_files = @($wReadSet.Keys | Sort-Object)
                    modified_files = @()
                    usage_input_tokens = $wUsageIn
                    usage_output_tokens = $wUsageOut
                }
            }
        }
        finally {
            foreach ($w in $workers) {
                if ($w.proc -and (-not $w.proc.HasExited)) {
                    $null = Stop-AgentProcessTree -Process $w.proc
                    Wait-Process -InputObject $w.proc -Timeout 2 -ErrorAction SilentlyContinue
                }
                Remove-Item -LiteralPath $w.prompt_file -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $w.out_file -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $w.err_file -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $allResults
}
