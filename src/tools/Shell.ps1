# Process tree management, child process termination, and shell command execution.

function Get-AgentProcessParents {
    # The wait loop asks for this table many times a second. Reuse one snapshot
    # for one second so stopping a command still sees the latest descendants.
    $now = Get-Date
    if ($null -ne $script:AgentProcessParentsCachedAt) {
        $ageSeconds = ($now - $script:AgentProcessParentsCachedAt).TotalSeconds
        if ($ageSeconds -ge 0 -and $ageSeconds -lt 1) {
            foreach ($cachedRow in @($script:AgentProcessParentsCache)) { $cachedRow }
            return
        }
    }
    $rows = @()
    if (-not $script:AgentProcessParentCollections) { $script:AgentProcessParentCollections = 0 }
    $script:AgentProcessParentCollections = $script:AgentProcessParentCollections + 1
    if ($env:OS -eq 'Windows_NT') {
        # Built-in CIM cmdlets work in Windows PowerShell 5.1/ConstrainedLanguage.
        # Get-Process only exposes Parent in newer PowerShell versions.
        $startTimes = @{}
        foreach ($p in @(Get-Process -ErrorAction Stop)) {
            try {
                if ($p.StartTime) { $startTimes[[string]$p.Id] = $p.StartTime.Ticks }
            }
            catch { }
        }
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -OperationTimeoutSec 2 -ErrorAction Stop)) {
            $key = [string]$p.ProcessId
            if ($startTimes.ContainsKey($key)) {
                $rows += ,@{ id = [int]$p.ProcessId; parent_id = [int]$p.ParentProcessId; start_ticks = $startTimes[$key] }
            }
        }
    }
    else {
        foreach ($p in @(Get-Process -ErrorAction Stop)) {
            try {
                $parent = $p.Parent
                if ($parent) { $rows += ,@{ id = [int]$p.Id; parent_id = [int]$parent.Id; start_ticks = $p.StartTime.Ticks } }
            }
            catch { } # Processes can exit while the snapshot is being collected.
        }
    }
    $script:AgentProcessParentsCache = @($rows)
    $script:AgentProcessParentsCachedAt = $now
    foreach ($cachedRow in @($script:AgentProcessParentsCache)) { $cachedRow }
}

function Update-AgentProcessTree {
    param([hashtable]$Tracked)
    $parents = @(Get-AgentProcessParents)
    $live = @{}
    foreach ($key in @($Tracked.Keys)) {
        $p = Get-Process -Id $Tracked[$key].id -ErrorAction SilentlyContinue
        if ($p) {
            try {
                if ($p.StartTime.Ticks -eq $Tracked[$key].start_ticks) { $live[$key] = $true }
            }
            catch { }
        }
    }
    # Repeat to discover grandchildren even if they precede their parents in
    # the snapshot. Retain discovered identities after a parent exits/reparents.
    do {
        $added = $false
        foreach ($row in $parents) {
            $key = [string]$row.id
            $parentKey = [string]$row.parent_id
            if ($Tracked.ContainsKey($key) -or -not $live.ContainsKey($parentKey)) { continue }
            $p = Get-Process -Id $row.id -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            try { $ticks = $p.StartTime.Ticks } catch { continue }
            if ($ticks -ne $row.start_ticks -or $ticks -lt $Tracked[$parentKey].start_ticks) { continue }
            $Tracked[$key] = @{ id = $row.id; start_ticks = $ticks; depth = $Tracked[$parentKey].depth + 1 }
            $live[$key] = $true
            $added = $true
        }
    } while ($added)
}

function Stop-AgentProcessTree {
    param($Process, [hashtable]$Tracked)
    if ($null -eq $Tracked) {
        $Tracked = @{}
        if ($Process -and -not $Process.HasExited) {
            try {
                $Tracked[[string]$Process.Id] = @{ id = [int]$Process.Id; start_ticks = $Process.StartTime.Ticks; depth = 0 }
            }
            catch { }
        }
    }
    $cleanupErrors = @()
    try { Update-AgentProcessTree -Tracked $Tracked }
    catch { $cleanupErrors += "Cannot inspect process descendants: $($_.Exception.Message)" }
    # Stop parents first to prevent them starting more work while cleaning up
    # the descendants already discovered. Check identity to avoid PID reuse.
    foreach ($entry in @($Tracked.Values | Sort-Object { $_.depth })) {
        $p = Get-Process -Id $entry.id -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        try {
            if ($p.StartTime.Ticks -ne $entry.start_ticks) { continue }
            Stop-Process -InputObject $p -Force -ErrorAction Stop
            Wait-Process -InputObject $p -Timeout 2 -ErrorAction SilentlyContinue
            if (-not $p.HasExited) { throw 'Process is still running.' }
        }
        catch { $cleanupErrors += "Cannot terminate process $($entry.id): $($_.Exception.Message)" }
    }
    # Covers cancellation immediately after Start-Process, before registration.
    if ($Process -and -not $Process.HasExited) {
        try {
            Stop-Process -InputObject $Process -Force -ErrorAction Stop
            Wait-Process -InputObject $Process -Timeout 2 -ErrorAction SilentlyContinue
        }
        catch { $cleanupErrors += "Cannot terminate command process: $($_.Exception.Message)" }
    }
    return $cleanupErrors
}

function Invoke-ShellCommand {
    param([string]$Root, [string]$Command, [int]$TimeoutSec = 60)
    if (-not $Command -or -not $Command.Trim()) { throw 'Command must not be empty.' }
    if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 600) { throw 'timeout_sec must be between 1 and 600.' }
    $rootFull = (Get-Item -LiteralPath $Root -Force -ErrorAction Stop).FullName
    $envInfo = Get-AgentEnvironment -Root $rootFull
    $shellExe = $envInfo.shell_exe
    $outTemp = New-AgentTempFile
    $errTemp = New-AgentTempFile
    $savedSSess = $env:SHELLOSSUS_SESSION_ID
    $savedSFile = $env:SHELLOSSUS_SESSION_FILE
    $savedSMod = $env:SHELLOSSUS_MODEL
    $savedSReas = $env:SHELLOSSUS_REASONING_LEVEL
    $timedOut = $false
    $proc = $null
    $trackedProcesses = @{}
    $commandFinished = $false
    $terminationErrors = @()
    $exitCode = 0
    $startTime = Get-Date
    try {
        try {
            $env:SHELLOSSUS_SESSION_ID = if ($script:ActiveSessionId) { [string]$script:ActiveSessionId } else { '' }
            $env:SHELLOSSUS_SESSION_FILE = if ($script:ActiveSessionFile) { [string]$script:ActiveSessionFile } else { '' }
            $env:SHELLOSSUS_MODEL = if ($script:ActiveModelId) { [string]$script:ActiveModelId } else { '' }
            $env:SHELLOSSUS_REASONING_LEVEL = if ($script:ReasoningEffort) { [string]$script:ReasoningEffort } else { '' }
            $wrappedCmd = "try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}`n" + $Command
            $argList = Get-AgentCommandArguments -CommandText $wrappedCmd
            $proc = Invoke-WithProcessEnvironment -Values @{
                SHELLOSSUS_API_KEY = $null
                OPENAI_API_KEY = $null
            } -Action {
                Start-Process -FilePath $shellExe -ArgumentList $argList -WorkingDirectory $rootFull -RedirectStandardOutput $outTemp.FullName -RedirectStandardError $errTemp.FullName -NoNewWindow -PassThru -ErrorAction Stop
            }
            if (-not $proc.HasExited) {
                try {
                    $trackedProcesses[[string]$proc.Id] = @{ id = $proc.Id; start_ticks = $proc.StartTime.Ticks; depth = 0 }
                }
                catch { if (-not $proc.HasExited) { throw } }
            }
            $waitStart = Get-Date
            while (-not $proc.HasExited) {
                Update-AgentProcessTree -Tracked $trackedProcesses
                if ($proc.HasExited) { break }
                $remainingSeconds = $TimeoutSec - ((Get-Date) - $waitStart).TotalSeconds
                if ($remainingSeconds -le 0) {
                    $timedOut = $true
                    $terminationErrors = @(Stop-AgentProcessTree -Process $proc -Tracked $trackedProcesses)
                    break
                }
                if ($remainingSeconds -ge 1) { Wait-Process -InputObject $proc -Timeout 1 -ErrorAction SilentlyContinue }
                else { Start-Sleep -Milliseconds 50 }
            }
            $commandFinished = $true
            if (-not $timedOut) {
                if ($null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode }
            }
            else {
                $exitCode = -1
            }
        }
        finally {
            $env:SHELLOSSUS_SESSION_ID = $savedSSess
            $env:SHELLOSSUS_SESSION_FILE = $savedSFile
            $env:SHELLOSSUS_MODEL = $savedSMod
            $env:SHELLOSSUS_REASONING_LEVEL = $savedSReas
        }
        $elapsedSec = [int](((Get-Date) - $startTime).TotalSeconds * 10) / 10.0
        $outItem = Get-Item -LiteralPath $outTemp.FullName -Force -ErrorAction Stop
        $errItem = Get-Item -LiteralPath $errTemp.FullName -Force -ErrorAction Stop
        $outRaw = if ($outItem.Length -gt 0 -and $outItem.Length -le 2MB) { Get-Content -LiteralPath $outTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } elseif ($outItem.Length -gt 2MB) { (Get-Content -LiteralPath $outTemp.FullName -Tail 400 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        $errRaw = if ($errItem.Length -gt 0 -and $errItem.Length -le 2MB) { Get-Content -LiteralPath $errTemp.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } elseif ($errItem.Length -gt 2MB) { (Get-Content -LiteralPath $errTemp.FullName -Tail 400 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
        $combinedRaw = if ($outRaw -and $errRaw) { $outRaw.TrimEnd("`r", "`n") + "`n" + $errRaw } elseif ($outRaw) { [string]$outRaw } elseif ($errRaw) { [string]$errRaw } else { '' }
        $tailRes = Invoke-TruncateTail -Content $combinedRaw -MaxLines 300 -MaxBytes 20000
        $truncated = $tailRes.truncated -or ($outItem.Length -gt 2MB) -or ($errItem.Length -gt 2MB)
        $text = $tailRes.content
        $fullLogRel = $null
        if ($truncated) {
            try {
                $outDir = Join-Path (Join-Path $rootFull '.shellossus') 'output'
                if (-not (Test-PathHasReparsePoint -Path $outDir -StopAt $rootFull)) {
                    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop | Out-Null }
                    $logName = 'cmd-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 100000 -Maximum 999999) + '.log'
                    $logFull = Join-Path $outDir $logName
                    Copy-Item -LiteralPath $outTemp.FullName -Destination $logFull -Force -ErrorAction Stop
                    if ($errItem.Length -gt 0) {
                        Get-Content -LiteralPath $errTemp.FullName -ReadCount 500 -Encoding UTF8 -ErrorAction SilentlyContinue | Add-Content -LiteralPath $logFull -Encoding UTF8 -ErrorAction SilentlyContinue
                    }
                    $fullLogRel = Get-WorkspaceRelativePath -Root $Root -FullPath $logFull
                }
            }
            catch {}
        }
        if ($timedOut) {
            $timeoutNote = if ($terminationErrors.Count -eq 0) {
                "[Command timed out after ${TimeoutSec}s; command and tracked descendants were terminated]"
            }
            else {
                "[Command timed out after ${TimeoutSec}s; process cleanup incomplete: " + ($terminationErrors -join '; ') + ']'
            }
            $text = if ($text) { $text + "`n" + $timeoutNote } else { $timeoutNote }
        }
        return @{
            exit_code = $exitCode
            output = $text
            truncated = $truncated
            full_output_path = $fullLogRel
            timed_out = $timedOut
            termination_errors = @($terminationErrors)
            wall_time_seconds = $elapsedSec
        }
    }
    finally {
        if ($proc -and -not $commandFinished) {
            $null = Stop-AgentProcessTree -Process $proc -Tracked $trackedProcesses
        }
        if (Test-Path -LiteralPath $outTemp.FullName) { Remove-Item -LiteralPath $outTemp.FullName -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $errTemp.FullName) { Remove-Item -LiteralPath $errTemp.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-AgentCommand {
    param([string]$Root, $Arguments)
    if ($Arguments.command -isnot [string] -or -not $Arguments.command.Trim()) { throw 'command must be a nonempty string.' }
    $cmdText = $Arguments.command
    if ($cmdText.Length -gt 8000) { throw 'Command is too long.' }
    $timeoutSec = 60
    if ($null -ne $Arguments.timeout_sec) {
        $timeoutSec = [int]$Arguments.timeout_sec
        if ($timeoutSec -lt 1 -or $timeoutSec -gt 600) { throw 'timeout_sec must be between 1 and 600.' }
    }
    if ($script:OutputMode -ne 'json') {
        Write-Host ("`n  " + $script:Gm.Grey0 + $script:Box.TL + $script:Box.H + ' ' + $script:Gm.BoldYellow + $script:Box.Arrow + ' run_command ' + $script:Gm.Grey1 + '(' + $Root + ')' + $script:Gm.Reset)
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Bg1 + $script:Gm.Yellow + '  ' + (Format-PreviewText $cmdText) + '  ' + $script:Gm.Reset)
    }
    if ($script:AgentPermission -eq 'Auto') {
        if ($script:OutputMode -ne 'json') {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [auto-approved by Auto mode]' + $script:Gm.Reset)
        }
    }
    elseif (($script:OutputMode -ne 'json') -and $script:AutoApproveCommands) {
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [commands are auto-approved for this session]' + $script:Gm.Reset)
    }
    else {
        if ($script:OutputMode -eq 'json') {
            return (@{ status = 'cancelled'; message = 'Interactive confirmation is disabled in JSON mode. Use -Permission Auto to allow command execution.' } | ConvertTo-Json -Compress)
        }
        $promptStr = '  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.BoldYellow + 'Confirm [y]es, [n]o, [a]ll commands: ' + $script:Gm.Fg
        $choice = Read-TuiConfirmation -PromptText $promptStr -ActionType 'run'
        if ($choice -eq 'a') {
            $script:AutoApproveCommands = $true
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + ' ' + $script:Gm.Aqua + $script:Box.Check + ' [commands are auto-approved for this session]' + $script:Gm.Reset)
        }
        elseif ($choice -ne 'y') {
            Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $script:Gm.Red + $script:Box.Cross + ' cancelled' + $script:Gm.Reset)
            return (@{ status = 'cancelled'; message = 'User declined command execution. Do not retry without a new user request.' } | ConvertTo-Json -Compress)
        }
    }
    $res = Invoke-ShellCommand -Root $Root -Command $cmdText -TimeoutSec $timeoutSec
    if ($script:OutputMode -ne 'json') {
        if ($res.output) {
            $previewLines = @($res.output -split "`r?`n" | Select-Object -First 15)
            foreach ($pLine in $previewLines) {
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + '   ' + $script:Gm.Grey1 + (Format-PreviewText $pLine) + $script:Gm.Reset)
            }
            if (($res.output -split "`r?`n").Count -gt 15) {
                Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.V + '   ... (output truncated in terminal preview)' + $script:Gm.Reset)
            }
        }
        $cmdIcon = if ($res.timed_out -or $res.exit_code -ne 0) { $script:Gm.Red + $script:Box.Cross + $script:Gm.Reset } else { $script:Gm.Green + $script:Box.Check + $script:Gm.Reset }
        $cmdColor = if ($res.timed_out -or $res.exit_code -ne 0) { $script:Gm.Red } else { $script:Gm.Grey2 }
        Write-Host ('  ' + $script:Gm.Grey0 + $script:Box.BL + $script:Box.H + ' ' + $cmdIcon + ' ' + $cmdColor + ("exit {0}" -f $res.exit_code) + $script:Gm.Grey0 + ' | ' + $script:Gm.Grey1 + ("{0}s" -f $res.wall_time_seconds) + $script:Gm.Reset)
    }
    $status = if ($res.timed_out) { 'timed_out' } else { 'executed' }
    return (@{
        status = $status
        exit_code = $res.exit_code
        output = $res.output
        truncated = $res.truncated
        full_output_path = $res.full_output_path
        timed_out = $res.timed_out
        termination_errors = @($res.termination_errors)
        wall_time_seconds = $res.wall_time_seconds
    } | ConvertTo-Json -Compress)
}
