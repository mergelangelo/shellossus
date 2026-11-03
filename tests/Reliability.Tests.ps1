param([switch]$ConstrainedLanguage)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$workspacePath = $envData.Workspace
if ($ConstrainedLanguage) {
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
    . "$PSScriptRoot\..\shellossus.ps1" -LibraryOnly
}
$script:OutputMode = 'json'
$script:AgentPermission = 'AutoEdit'
$testBackups = @()
$testProcesses = @()
try {
    # Both overwrite and edit preserve the existing newline convention.
    foreach ($case in @(
        @{ before = "a`r`nb`r`n"; incoming = "a`nc`n"; expected = "a`r`nc`r`n" },
        @{ before = "a`nb`n"; incoming = "a`r`nc`r`n"; expected = "a`nc`n" },
        @{ before = ''; incoming = "a`r`nc"; expected = "a`r`nc" },
        @{ before = 'a'; incoming = "a`nc"; expected = "a`nc" }
    )) {
        $path = Join-Path $workspacePath 'endings.txt'
        Set-Content -LiteralPath $path -Value $case.before -Encoding UTF8 -NoNewline
        $script:CurrentTurnWrites = @()
        $argsJson = @{ path = 'endings.txt'; content = $case.incoming; overwrite = $true } | ConvertTo-Json -Compress
        $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'write_file'; arguments = $argsJson } } | ConvertFrom-Json
        Assert-True ($res.status -eq 'written') 'Overwrite failed in newline preservation test.'
        $testBackups += $res.backup
        Assert-True ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -ceq $case.expected) 'Overwrite changed the existing newline convention.'
        Invoke-AgentUndo -State @{ messages = @() } -UndoEntry @{ messages = @(); writes = @($script:CurrentTurnWrites) }
        $restored = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($null -eq $restored) { $restored = '' }
        Assert-True ($restored -ceq $case.before) 'Undo did not restore original newlines/content.'
    }
    Set-Content -LiteralPath $path -Value "a`nb`nc" -Encoding UTF8 -NoNewline
    $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'edit_file'; arguments = '{"path":"endings.txt","old_text":"b","new_text":"B\r\nC"}' } } | ConvertFrom-Json
    $testBackups += $res.backup
    Assert-True ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -ceq "a`nB`nC`nc") 'edit_file introduced CRLF into an LF file.'

    # Corruption anywhere in an undo chain must prevent ALL restores/deletes.
    $script:CurrentTurnWrites = @()
    Set-Content -LiteralPath (Join-Path $workspacePath 'original.txt') -Value 'original' -Encoding UTF8 -NoNewline
    foreach ($pair in @(@('original', 'edited-once'), @('edited-once', 'edited-twice'))) {
        $argsJson = @{ path = 'original.txt'; old_text = $pair[0]; new_text = $pair[1] } | ConvertTo-Json -Compress
        $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'edit_file'; arguments = $argsJson } } | ConvertFrom-Json
        $testBackups += $res.backup
    }
    $null = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'write_file'; arguments = '{"path":"created.txt","content":"keep until undo succeeds"}' } }
    $entry = @{ messages = @(@{ role = 'system'; content = 'before' }); writes = @($script:CurrentTurnWrites) }
    $state = @{ messages = @(@{ role = 'user'; content = 'after' }) }
    $corruptBackup = $entry.writes[0].backup
    Set-Content -LiteralPath $corruptBackup -Value 'damaged' -Encoding UTF8 -NoNewline
    $undoFailed = $false
    try { Invoke-AgentUndo -State $state -UndoEntry $entry } catch { $undoFailed = $_.Exception.Message -like '*Backup verification failed*' }
    Assert-True $undoFailed 'Undo accepted a corrupted intermediate backup.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'original.txt') -Raw) -eq 'edited-twice') 'Failed preflight partially restored a file.'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspacePath 'created.txt')) 'Failed preflight deleted a created file.'
    Assert-True ($state.messages[0].content -eq 'after') 'Failed preflight changed conversation state.'
    Assert-True ((Test-Path -LiteralPath $entry.writes[0].backup) -and (Test-Path -LiteralPath $entry.writes[1].backup)) 'Failed preflight removed backups.'
    Set-Content -LiteralPath $corruptBackup -Value 'original' -Encoding UTF8 -NoNewline
    Invoke-AgentUndo -State $state -UndoEntry $entry
    Assert-True ((Get-Content -LiteralPath (Join-Path $workspacePath 'original.txt') -Raw) -eq 'original') 'Undo could not be retried after repairing a backup.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'created.txt'))) 'Successful undo did not remove the created file.'

    # Page all matches, including inside a file and across file boundaries.
    $grepDir = Join-Path $workspacePath 'pages'
    New-Item -ItemType Directory -Path $grepDir | Out-Null
    Set-Content -LiteralPath (Join-Path $grepDir 'a.txt') -Value @('hit a1', 'gap', 'hit a3', 'hit a4') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $grepDir 'b.txt') -Value @('gap', 'hit b2', 'hit b3') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $grepDir 'c.txt') -Value 'hit c1' -Encoding UTF8
    foreach ($pageSize in @(1, 2, 3, 6, 7)) {
        $offset = 0
        $line = 1
        $seen = @()
        $pages = 0
        do {
            $argsJson = @{ path = 'pages'; pattern = 'hit'; literal = $true; limit = $pageSize; file_offset = $offset; start_line = $line; context_lines = 1 } | ConvertTo-Json -Compress
            $page = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'grep_files'; arguments = $argsJson } } | ConvertFrom-Json
            Assert-True (-not $page.error) "Search failed: $($page.error)"
            foreach ($hit in $page.matches) { $seen += "$($hit.file):$($hit.line_number)" }
            $pages++
            Assert-True ($pages -le 10) 'Search pagination did not terminate.'
            if ($page.truncated) {
                Assert-True ($null -ne $page.next_file_offset -and $page.next_start_line -ge 1) 'Truncated search has no continuation cursor.'
                Assert-True ($page.next_file_offset -gt $offset -or ($page.next_file_offset -eq $offset -and $page.next_start_line -gt $line)) 'Search cursor did not advance.'
                $offset = $page.next_file_offset
                $line = $page.next_start_line
            }
        } while ($page.truncated)
        Assert-True (($seen -join ',') -eq 'a.txt:1,a.txt:3,a.txt:4,b.txt:2,b.txt:3,c.txt:1') 'Search pagination lost or duplicated matches.'
        Assert-True ($null -eq $page.next_file_offset -and $null -eq $page.next_start_line) 'Complete search returned a continuation cursor.'
    }
    $single = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'grep_files'; arguments = '{"path":"pages/a.txt","pattern":"hit","limit":2,"start_line":3}' } } | ConvertFrom-Json
    Assert-True ($single.matches.Count -eq 2 -and $single.matches[0].line_number -eq 3 -and -not $single.truncated) 'Single-file start_line or exact-limit completion failed.'
    $badLine = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'grep_files'; arguments = '{"path":"pages","pattern":"hit","start_line":0}' } } | ConvertFrom-Json
    Assert-True ($badLine.error -like '*start_line*') 'Search accepted an invalid line cursor.'

    # Exercise the real agent loop with a transport mock that deliberately
    # requests a forbidden write, not just the displayed list of tools.
    $roleDir = Join-Path $workspacePath '.shellossus/agents'
    New-Item -ItemType Directory -Path $roleDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $roleDir 'writer-only.md') -Encoding UTF8 -Value "---`nname: writer-only`ntools: write_file`n---`nWrite files."
    Set-Content -LiteralPath (Join-Path $roleDir 'reader.md') -Encoding UTF8 -Value "---`nname: reader`ntools: read, grep*`n---`nRead files."
    $script:AgentRolesByName = @{}
    $script:EnabledTools = @('read_file', 'run_agent')
    $script:policyStep = 0
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $req = $Body | ConvertFrom-Json
        Assert-True (@($req.tools).Count -eq 0) 'Empty subagent intersection exposed tools.'
        $script:policyStep++
        if ($script:policyStep -eq 1) {
            $reply = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{ tool_calls = @(@{ id = 'denied'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"forbidden.txt","content":"must not exist"}' } }) } }) }
        }
        else {
            $toolResult = $req.messages[-1].content | ConvertFrom-Json
            Assert-True ($toolResult.error -like '*disabled*') 'A hidden tool could still execute.'
            $reply = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'write denied' } }) }
        }
        $reply | ConvertTo-Json -Depth 15 -Compress | Set-Content -LiteralPath $OutFile -Encoding UTF8
    }
    try {
        $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'run_agent'; arguments = '{"role":"writer-only","prompt":"Try a write"}' } } | ConvertFrom-Json
        Assert-True ($res.status -eq 'completed' -and $res.output -eq 'write denied') 'Subagent restriction regression failed.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'forbidden.txt'))) 'Subagent bypassed the parent tool allowlist.'
        Assert-True (-not $script:NoTools -and ($script:EnabledTools -join ',') -eq 'read_file,run_agent') 'Subagent did not restore parent filters.'
    }
    finally { Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue }

    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        throw 'Injected subagent transport failure.'
    }
    try {
        $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'run_agent'; arguments = '{"role":"writer-only","prompt":"Fail the request"}' } } | ConvertFrom-Json
        Assert-True ($res.error -like '*Injected subagent transport failure*') 'Failed subagent request did not propagate its error.'
        Assert-True (-not $script:NoTools -and $script:AgentPermission -eq 'AutoEdit' -and $script:SubagentDepth -eq 0 -and ($script:EnabledTools -join ',') -eq 'read_file,run_agent') 'Failed subagent leaked restricted state into the parent.'
    }
    finally { Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue }

    # Actual worker processes receive the same role/parent intersection. The
    # worker only reports startup capabilities; no external API is contacted.
    $workerScript = Join-Path $envData.TestRoot 'policy-worker.ps1'
    $libraryPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'shellossus.ps1').Replace("'", "''")
    $workerText = @'
param($Workspace, $BaseUrl, $Model, $Permission, $Mode, [switch]$NoSession, $MaxSteps, $Tools, [switch]$NoTools, $ExcludeTools, $Prompt, $ConfigPath)
$allowed = $Tools
$disabled = [bool]$NoTools
$denied = $ExcludeTools
. '__LIBRARY__' -LibraryOnly
$script:EnabledTools = @($allowed -split ',' | Where-Object { $_ })
$script:ExcludedTools = @($denied -split ',' | Where-Object { $_ })
$script:NoTools = $disabled
$script:AgentPermission = 'ReadOnly'
$names = @(Get-AgentTools | ForEach-Object { $_.function.name })
@{ type = 'message_end'; role = 'assistant'; content = (@{ tools = $names; no_tools = $disabled } | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress
@{ type = 'turn_end'; status = 'completed' } | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath $workerScript -Value $workerText.Replace('__LIBRARY__', $libraryPath) -Encoding Ascii
    $script:EnabledTools = @('r*', 'grep*')
    $script:ExcludedTools = @('grep_files')
    $workerResults = @(Invoke-ParallelSubagentProcesses -Root $workspacePath -Tasks @(@{ role = 'reader'; prompt = 'inspect' }, @{ role = 'writer-only'; prompt = 'inspect' }) -ScriptPath $workerScript)
    Assert-True ($workerResults.Count -eq 2) 'Parallel worker filter test did not return two results.'
    $reader = $workerResults[0].output | ConvertFrom-Json
    $writer = $workerResults[1].output | ConvertFrom-Json
    Assert-True (($reader.tools -join ',') -eq 'read_file') 'Worker did not inherit aliases, wildcard filters, or exclusions.'
    Assert-True ($writer.no_tools -and $writer.tools.Count -eq 0) 'Empty worker allowlist enabled tools.'
    $script:EnabledTools = @()
    $script:ExcludedTools = @()

    # A timed-out command must stop child and grandchild processes as well.
    # Keep an unrelated process alive to detect overly broad termination.
    $processDir = Join-Path $envData.TestRoot 'process fixtures'
    New-Item -ItemType Directory -Path $processDir | Out-Null
    $leafText = @'
$self = Get-Process -Id $PID
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'leaf.pid') -Value "$PID|$($self.StartTime.Ticks)" -Encoding Ascii
Start-Sleep -Seconds 30
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'late.txt') -Value 'unexpected write'
'@
    $middleText = @'
$self = Get-Process -Id $PID
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'middle.pid') -Value "$PID|$($self.StartTime.Ticks)" -Encoding Ascii
$argText = '-NoProfile -NonInteractive -File "' + (Join-Path $PSScriptRoot 'leaf.ps1') + '"'
Start-Process -FilePath $self.Path -ArgumentList $argText | Out-Null
Start-Sleep -Seconds 30
'@
    $parentText = $middleText.Replace('middle.pid', 'parent.pid').Replace('leaf.ps1', 'middle.ps1')
    Set-Content -LiteralPath (Join-Path $processDir 'leaf.ps1') -Value $leafText -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $processDir 'middle.ps1') -Value $middleText -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $processDir 'parent.ps1') -Value $parentText -Encoding Ascii
    $shellExe = (Get-AgentEnvironment).shell_exe
    $bystander = Start-Process -FilePath $shellExe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -PassThru
    $testProcesses += $bystander
    $parentPath = (Join-Path $processDir 'parent.ps1').Replace("'", "''")
    $timeout = Invoke-ShellCommand -Root $workspacePath -Command "& '$parentPath'" -TimeoutSec 4
    Assert-True ($timeout.timed_out -and $timeout.termination_errors.Count -eq 0) "Tree timeout failed: $($timeout.termination_errors -join '; ')"
    foreach ($pidName in @('parent.pid', 'middle.pid', 'leaf.pid')) {
        $pidPath = Join-Path $processDir $pidName
        Assert-True (Test-Path -LiteralPath $pidPath) "Process fixture did not start: $pidName"
        $parts = (Get-Content -LiteralPath $pidPath -Raw).Trim() -split '\|'
        $p = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
        $stillRunning = $p -and ($p.StartTime.Ticks -eq [long]$parts[1])
        Assert-True (-not $stillRunning) "Timeout left $pidName running."
    }
    Assert-True (-not $bystander.HasExited) 'Tree cleanup stopped an unrelated process.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $processDir 'late.txt'))) 'A timed-out descendant wrote after cleanup.'

    # A tracked PID with a different birth time belongs to a different process.
    $staleIdentity = @{}
    $staleIdentity[[string]$bystander.Id] = @{ id = $bystander.Id; start_ticks = $bystander.StartTime.Ticks - 1; depth = 0 }
    $identityErrors = @(Stop-AgentProcessTree -Tracked $staleIdentity)
    Assert-True ($identityErrors.Count -eq 0 -and -not $bystander.HasExited) 'Cleanup killed a process with a reused PID.'

    # Errors during monitoring also take the finally cleanup path.
    $script:inspectionPidPath = Join-Path $processDir 'inspection.pid'
    $savedParentsFunction = ${function:Get-AgentProcessParents}
    function Get-AgentProcessParents {
        $deadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path -LiteralPath $script:inspectionPidPath)) {
            if ((Get-Date) -gt $deadline) { throw 'Inspection fixture did not start.' }
            Start-Sleep -Milliseconds 50
        }
        throw 'Injected process inspection failure.'
    }
    $inspectionCommand = @'
$self = Get-Process -Id $PID
Set-Content -LiteralPath '__PIDPATH__' -Value "$PID|$($self.StartTime.Ticks)" -Encoding Ascii
Start-Sleep -Seconds 30
'@
    $inspectionCommand = $inspectionCommand.Replace('__PIDPATH__', $script:inspectionPidPath.Replace("'", "''"))
    $inspectionScript = Join-Path $processDir 'inspection.ps1'
    Set-Content -LiteralPath $inspectionScript -Value $inspectionCommand -Encoding Ascii
    $inspectionFailed = $false
    $inspectionError = ''
    try { $null = Invoke-ShellCommand -Root $workspacePath -Command ("& '" + $inspectionScript.Replace("'", "''") + "'") -TimeoutSec 15 }
    catch { $inspectionError = $_.Exception.Message; $inspectionFailed = $inspectionError -like '*Injected process inspection failure*' }
    finally { Set-Item Function:\Get-AgentProcessParents -Value $savedParentsFunction }
    Assert-True $inspectionFailed "Expected process inspection failure was not reported: $inspectionError"
    $parts = (Get-Content -LiteralPath $script:inspectionPidPath -Raw).Trim() -split '\|'
    $p = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
    Assert-True (-not ($p -and $p.StartTime.Ticks -eq [long]$parts[1])) 'A monitoring exception leaked the command process.'
}
finally {
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    foreach ($p in $testProcesses) { if (-not $p.HasExited) { Stop-Process -InputObject $p -Force -ErrorAction SilentlyContinue } }
    if ($processDir -and (Test-Path -LiteralPath $processDir)) {
        foreach ($pidFile in @(Get-ChildItem -LiteralPath $processDir -Filter '*.pid' -File)) {
            $parts = (Get-Content -LiteralPath $pidFile.FullName -Raw).Trim() -split '\|'
            $p = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
            if ($p -and $p.StartTime.Ticks -eq [long]$parts[1]) { Stop-Process -InputObject $p -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($backup in $testBackups) { if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force } }
    Remove-TestEnvironment -Env $envData
}
