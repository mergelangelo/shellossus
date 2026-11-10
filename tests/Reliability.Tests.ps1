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
    # Fixed worker code survives multiline launch in CLM and request data stays separate.
    $shellName = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } elseif ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $installedShell = Join-Path $PSHOME $shellName
    $workerArgs = @(Get-AgentWorkerArguments -CommandText "Write-Output 'first line'`nWrite-Output 'second line'")
    $workerOutput = @(& $installedShell @workerArgs)
    Assert-True (($workerOutput -join '|') -ceq 'first line|second line') 'Encoded worker launch lost multiline code.'
    & {
        $launches = @{ items = @(); kind = '' }
        function Start-Process {
            [CmdletBinding()]
            param($FilePath, [string[]]$ArgumentList, $RedirectStandardOutput, $RedirectStandardError, [switch]$NoNewWindow, [switch]$PassThru)
            if ($launches.kind -eq 'post') {
                $uri = $env:SHELLOSSUS_HTTP_URI
                $body = Get-Content -LiteralPath $env:SHELLOSSUS_HTTP_IN -Raw -Encoding Ascii
                $destination = $env:SHELLOSSUS_HTTP_OUT
            }
            else {
                $uri = $env:SHELLOSSUS_WEB_DOWNLOAD_URI
                $body = ''
                $destination = $env:SHELLOSSUS_WEB_DOWNLOAD_FILE
            }
            $launches.items += @{ executable = $FilePath; arguments = $ArgumentList; uri = $uri; body = $body }
            Set-AgentUtf8Content -LiteralPath $destination -Value 'response'
            return @{ HasExited = $true; ExitCode = 0; Id = 0 }
        }

        $outPath = Join-Path $envData.TestRoot 'fixed-worker-response.txt'
        foreach ($kind in @('post', 'get')) {
            $launches.kind = $kind
            $launches.items = @()
            foreach ($uri in @('https://example.invalid/first', 'https://example.invalid/second')) {
                if ($kind -eq 'post') {
                    Invoke-AgentHttpRequest -Uri $uri -ApiKey 'test-key' -Body $uri -OutFile $outPath -ForceBackgroundWorker
                }
                else { Invoke-AgentWebDownload -Uri $uri -OutFile $outPath }
            }
            Assert-True ($launches.items.Count -eq 2 -and $launches.items[0].uri -ne $launches.items[1].uri) "The $kind worker lost request data."
            if ($kind -eq 'post') {
                Assert-True ($launches.items[0].body -ceq $launches.items[0].uri -and $launches.items[1].body -ceq $launches.items[1].uri) 'The API worker lost its file-backed request body.'
            }
            foreach ($launch in $launches.items) {
                Assert-True ($launch.executable -ceq $installedShell -and $launch.arguments -contains '-NoProfile' -and $launch.arguments -contains '-EncodedCommand') "The $kind worker did not launch fixed code using the installed PowerShell."
            }
            Assert-True (($launches.items[0].arguments -join ' ') -ceq ($launches.items[1].arguments -join ' ')) "Request data changed the $kind worker program."
            if (-not $ConstrainedLanguage) {
                $workerCode = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($launches.items[0].arguments[-1]))
                Assert-True ($workerCode -like '*Invoke-WebRequest*' -and $workerCode -notlike '*Invoke-Expression*') "The $kind worker evaluates external code."
            }
        }
    }

    # Operator shortcuts retain OS access while the model's shell tool is gated.
    $script:AgentPermission = 'ReadOnly'
    $script:OutputMode = 'text'
    try {
        $operatorState = @{ messages = @(@{ role = 'system'; content = 'sys' }); workspace = $workspacePath }
        $outsidePath = Join-Path $envData.TestRoot 'operator-output.txt'
        $quotedPath = $outsidePath.Replace("'", "''")
        $command = "Set-Content -LiteralPath '$quotedPath' -Value 'operator output' -Encoding Ascii"
        $arguments = @{ command = $command } | ConvertTo-Json -Compress
        $blocked = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'run_command'; arguments = $arguments } } | ConvertFrom-Json
        Assert-True ($blocked.error -like '*ReadOnly*' -and -not (Test-Path -LiteralPath $outsidePath)) 'ReadOnly allowed a model command.'
        Invoke-ReplBangCommand -State $operatorState -RootPath $workspacePath -InputText "!!$command"
        Assert-True ((Test-Path -LiteralPath $outsidePath) -and $operatorState.messages.Count -eq 1) 'The local operator shortcut did not run or changed the conversation.'
        Invoke-ReplBangCommand -State $operatorState -RootPath $workspacePath -InputText "!Get-Content -LiteralPath '$quotedPath'"
        Assert-True ($operatorState.messages.Count -eq 2 -and $operatorState.messages[-1].content -like '*operator output*') 'The operator shortcut did not include its output in the conversation.'
    }
    finally {
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'json'
    }

    # Both overwrite and edit preserve the existing newline convention.
    foreach ($case in @(
        @{ before = "a`r`nb`r`n"; incoming = "a`nc`n"; expected = "a`r`nc`r`n" },
        @{ before = "a`nb`n"; incoming = "a`r`nc`r`n"; expected = "a`nc`n" },
        @{ before = ''; incoming = "a`r`nc"; expected = "a`r`nc" },
        @{ before = 'a'; incoming = "a`nc"; expected = "a`nc" }
    )) {
        $path = Join-Path $workspacePath 'endings.txt'
        Set-AgentUtf8Content -LiteralPath $path -Value $case.before
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

    # A unique replacement must include exactly the separators specified by old_text.
    $matchPath = Join-Path $workspacePath 'edit-match.txt'
    foreach ($case in @(
        @{ name = 'exact overlap'; before = 'aaa'; old = 'aa'; error = '*occurs more than once*' }
        @{ name = 'CRLF overlap'; before = "a`r`na`r`na"; old = "a`na"; error = '*occurs more than once*' }
        @{ name = 'LF overlap'; before = "a`na`na"; old = "a`r`na"; error = '*occurs more than once*' }
        @{ name = 'CRLF fuzzy'; before = "foo  `r`nbar`r`n"; old = "foo`n"; new = "baz`n"; after = "baz`r`nbar`r`n" }
        @{ name = 'LF fuzzy'; before = "foo  `nbar`n"; old = "foo`r`n"; new = "baz`r`n"; after = "baz`nbar`n" }
        @{ name = 'fuzzy deletion'; before = "foo  `r`nbar`r`n"; old = "foo`n"; new = ''; after = "bar`r`n" }
        @{ name = 'unterminated duplicate'; before = "foo  `nfoo  "; old = "foo`n"; new = "baz`n"; after = "baz`nfoo  " }
        @{ name = 'missing final newline'; before = 'foo  '; old = "foo`n"; error = '*old_text was not found*' }
    )) {
        Set-AgentUtf8Content -LiteralPath $matchPath -Value $case.before
        $script:CurrentTurnWrites = @()
        $replacement = if ($case.error) { 'replacement' } else { $case.new }
        $argsJson = @{ path = 'edit-match.txt'; old_text = $case.old; new_text = $replacement } | ConvertTo-Json -Compress
        $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'edit_file'; arguments = $argsJson } } | ConvertFrom-Json
        if ($res.backup) { $testBackups += $res.backup }
        $actual = Get-Content -LiteralPath $matchPath -Raw -Encoding UTF8
        if ($case.error) {
            Assert-True ($res.error -like $case.error -and $actual -ceq $case.before -and $script:CurrentTurnWrites.Count -eq 0) "Unsafe edit was not rejected for $($case.name)."
        }
        else {
            Assert-True ($res.status -eq 'written' -and $actual -ceq $case.after) "Incorrect replacement for $($case.name)."
        }
    }

    # File tools preserve encoding and verify backups even when only the BOM differs.
    $encodedPath = Join-Path $workspacePath 'encoded.txt'
    $expectedPath = Join-Path $envData.TestRoot 'expected-encoding.txt'
    $utf8Bom = if ($PSVersionTable.PSVersion.Major -lt 6) { 'UTF8' } else { 'utf8BOM' }
    $nonAscii = ([string][char]0x044F) + ([string][char]0xFFFD)
    $encodedBefore = "original $nonAscii`r`n"
    foreach ($encoding in @($utf8Bom, 'Unicode', 'BigEndianUnicode')) {
        $script:CurrentTurnWrites = @()
        Set-Content -LiteralPath $encodedPath -Value $encodedBefore -Encoding $encoding -NoNewline
        $originalHash = (Get-FileHash -LiteralPath $encodedPath).Hash
        $edit = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{
            name = 'edit_file'; arguments = '{"path":"encoded.txt","old_text":"original","new_text":"edited"}'
        } } | ConvertFrom-Json
        Assert-True ($edit.status -eq 'written') "Editing $encoding failed: $($edit.error)"
        $testBackups += $edit.backup
        Set-Content -LiteralPath $expectedPath -Value "edited $nonAscii`r`n" -Encoding $encoding -NoNewline
        Assert-True ((Get-FileHash -LiteralPath $encodedPath).Hash -ceq (Get-FileHash -LiteralPath $expectedPath).Hash) "edit_file changed $encoding encoding."
        Assert-True ((Get-FileHash -LiteralPath $edit.backup).Hash -ceq $originalHash) "Backup did not preserve $encoding bytes."

        $overwrite = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{
            name = 'write_file'; arguments = '{"path":"encoded.txt","content":"","overwrite":true}'
        } } | ConvertFrom-Json
        Assert-True ($overwrite.status -eq 'written') "Overwriting $encoding failed: $($overwrite.error)"
        $testBackups += $overwrite.backup
        Set-Content -LiteralPath $expectedPath -Value '' -Encoding $encoding -NoNewline
        Assert-True ((Get-FileHash -LiteralPath $encodedPath).Hash -ceq (Get-FileHash -LiteralPath $expectedPath).Hash) "Overwriting with empty content lost the $encoding BOM."
        $encodingFrame = @{ messages = @(); writes = @($script:CurrentTurnWrites) }
        if ($encoding -eq $utf8Bom) {
            Set-AgentUtf8Content -LiteralPath $encodedPath -Value ''
            $bomConflict = ''
            try { Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $encodingFrame }
            catch { $bomConflict = $_.Exception.Message }
            Assert-True ($bomConflict -like '*manual changes*') 'Undo missed a BOM-only change to the target.'
            Copy-Item -LiteralPath $expectedPath -Destination $encodedPath -Force

            Set-AgentUtf8Content -LiteralPath $edit.backup -Value $encodedBefore
            $backupConflict = ''
            try { Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $encodingFrame }
            catch { $backupConflict = $_.Exception.Message }
            Assert-True ($backupConflict -like '*Backup verification failed*') 'Undo accepted a backup with a missing BOM.'
            Set-Content -LiteralPath $edit.backup -Value $encodedBefore -Encoding $encoding -NoNewline
        }
        Invoke-AgentUndo -State @{ messages = @() } -UndoEntry $encodingFrame
        Assert-True ((Get-FileHash -LiteralPath $encodedPath).Hash -ceq $originalHash) "Undo did not restore the original $encoding bytes."
    }

    foreach ($name in @('unicode.ps1', 'unicode.txt', 'ascii.ps1')) {
        $script:CurrentTurnWrites = @()
        $value = if ($name -eq 'ascii.ps1') { 'Write-Output 1' } else { "Write-Output '$nonAscii'" }
        $argsJson = @{ path = $name; content = $value } | ConvertTo-Json -Compress
        $created = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'write_file'; arguments = $argsJson } } | ConvertFrom-Json
        Assert-True ($created.status -eq 'written') "Writing $name failed: $($created.error)"
        if ($name -eq 'unicode.ps1') {
            Set-Content -LiteralPath $expectedPath -Value $value -Encoding $utf8Bom -NoNewline
        }
        else { Set-AgentUtf8Content -LiteralPath $expectedPath -Value $value }
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $workspacePath $name)).Hash -ceq (Get-FileHash -LiteralPath $expectedPath).Hash) "Unexpected encoding for new $name."
    }

    foreach ($badEncoding in @(
        @{ name = 'legacy'; bytes = [byte[]]@(0xCF, 0xF0) }
        @{ name = 'malformed UTF-8'; bytes = [byte[]]@(0xEF, 0xBB, 0xBF, 0xC3, 0x28) }
        @{ name = 'malformed UTF-16'; bytes = [byte[]]@(0xFF, 0xFE, 0x41) }
        @{ name = 'UTF-32'; bytes = [byte[]]@(0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0) }
    )) {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Set-Content -LiteralPath $encodedPath -Value $badEncoding.bytes -Encoding Byte
        }
        else { Set-Content -LiteralPath $encodedPath -Value $badEncoding.bytes -AsByteStream }
        $originalHash = (Get-FileHash -LiteralPath $encodedPath).Hash
        $script:CurrentTurnWrites = @()
        $rejected = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{
            name = 'write_file'; arguments = '{"path":"encoded.txt","content":"replacement","overwrite":true}'
        } } | ConvertFrom-Json
        Assert-True ($rejected.error -like '*encoding*' -and $script:CurrentTurnWrites.Count -eq 0) "write_file accepted $($badEncoding.name)."
        Assert-True ((Get-FileHash -LiteralPath $encodedPath).Hash -ceq $originalHash) "write_file changed $($badEncoding.name) bytes."
    }

    Set-AgentUtf8Content -LiteralPath $encodedPath -Value 'original'
    Set-Content -LiteralPath $expectedPath -Value 'original' -Encoding $utf8Bom -NoNewline
    $script:AgentPermission = 'Ask'
    $script:OutputMode = 'text'
    try {
        $conflict = & {
            function Read-TuiConfirmation {
                param($PromptText, [switch]$AllowDiff, $ActionType)
                Copy-Item -LiteralPath $expectedPath -Destination $encodedPath -Force
                return 'y'
            }
            Invoke-AgentTool -Root $workspacePath -Call @{ function = @{
                name = 'edit_file'; arguments = '{"path":"encoded.txt","old_text":"original","new_text":"edited"}'
            } } | ConvertFrom-Json
        }
        Assert-True ($conflict.error -like '*changed during confirmation*' -and $script:CurrentTurnWrites.Count -eq 0) 'A BOM-only change during confirmation did not stop the edit.'
        Assert-True ((Get-FileHash -LiteralPath $encodedPath).Hash -ceq (Get-FileHash -LiteralPath $expectedPath).Hash) 'The edit overwrote a BOM-only manual change.'
    }
    finally {
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'json'
    }

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

    # A failed preflight inside Restore-AgentTurnSnapshot must not touch history, the session tree, file bytes, or backups.
    $script:CurrentTurnWrites = @()
    $script:AgentPermission = 'AutoEdit'
    $script:OutputMode = 'json'
    $atomicPath = Join-Path $workspacePath 'rollback-atomic.txt'
    Set-Content -LiteralPath $atomicPath -Value 'original-bytes' -Encoding UTF8 -NoNewline
    $atomicArgs = @{ path = 'rollback-atomic.txt'; old_text = 'original-bytes'; new_text = 'edited-bytes' } | ConvertTo-Json -Compress
    $atomicEdit = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'edit_file'; arguments = $atomicArgs } } | ConvertFrom-Json
    Assert-True ($atomicEdit.status -eq 'written' -and @($script:CurrentTurnWrites).Count -eq 1) 'Rollback fixture edit did not record a backup.'
    $atomicBackup = [string]$script:CurrentTurnWrites[0].backup
    $atomicBackupBefore = Get-Content -LiteralPath $atomicBackup -Raw -Encoding UTF8
    Set-Content -LiteralPath $atomicBackup -Value 'damaged' -Encoding UTF8 -NoNewline
    $atomicState = @{
        messages = @(
            @{ role = 'system'; content = 'sys-live' },
            @{ role = 'user'; content = 'user-live' },
            @{ role = 'assistant'; content = 'assistant-live' }
        )
        leaf_id = 'leaf-live'
        tree_entries = @(@{ id = 'leaf-live'; parent_id = $null; role = 'assistant'; content = 'assistant-live' })
    }
    $atomicSnapshot = @{
        messages = @(
            @{ role = 'system'; content = 'sys-snap' },
            @{ role = 'user'; content = 'user-snap' }
        )
        leaf_id = 'leaf-snap'
        tree_entries = @(@{ id = 'leaf-snap'; parent_id = $null; role = 'user'; content = 'user-snap' })
    }
    $atomicThrew = $false
    $atomicError = ''
    try {
        Restore-AgentTurnSnapshot -State $atomicState -Snapshot $atomicSnapshot -Writes @($script:CurrentTurnWrites)
    }
    catch {
        $atomicThrew = $true
        $atomicError = [string]$_.Exception.Message
    }
    Assert-True ($atomicThrew -and $atomicError -like '*Backup verification failed*') "Restore-AgentTurnSnapshot did not fail preflight: $atomicError"
    Assert-True (@($atomicState.messages).Count -eq 3 -and [string]$atomicState.messages[0].content -eq 'sys-live' -and [string]$atomicState.messages[2].content -eq 'assistant-live') 'Failed preflight changed messages.'
    Assert-True ([string]$atomicState.leaf_id -eq 'leaf-live') 'Failed preflight changed leaf_id.'
    Assert-True (@($atomicState.tree_entries).Count -eq 1 -and [string]$atomicState.tree_entries[0].id -eq 'leaf-live' -and [string]$atomicState.tree_entries[0].content -eq 'assistant-live') 'Failed preflight changed tree_entries.'
    $atomicFileAfter = Get-Content -LiteralPath $atomicPath -Raw -Encoding UTF8
    Assert-True ($atomicFileAfter -ceq 'edited-bytes') "Failed preflight changed file bytes: $atomicFileAfter"
    $atomicBackupAfter = ''
    if (Test-Path -LiteralPath $atomicBackup) { $atomicBackupAfter = Get-Content -LiteralPath $atomicBackup -Raw -Encoding UTF8 }
    Assert-True ((Test-Path -LiteralPath $atomicBackup) -and $atomicBackupAfter -ceq 'damaged' -and $atomicBackupBefore -ceq 'original-bytes') 'Failed preflight removed or rewrote the backup.'

    # Inject nonterminating read errors so the memory tool must request ErrorAction Stop.
    $readErrorRoot = Join-Path $workspacePath 'unreadable-memory'
    New-Item -ItemType Directory -Path $readErrorRoot -Force | Out-Null
    $readErrorMemory = Join-Path $readErrorRoot 'MEMORY.md'
    Set-AgentUtf8Content -LiteralPath $readErrorMemory -Value 'original memory'
    $script:CurrentTurnWrites = @()
    & {
        $probe = @{ reads = 0; fail_at = 0; backup = ''; corrupt_backup = $false }
        function Get-Content {
            [CmdletBinding()]
            param($LiteralPath, [switch]$Raw, $Encoding)
            if ($LiteralPath -eq $readErrorMemory) {
                $probe.reads++
                if ($probe.reads -eq $probe.fail_at) {
                    $readAction = $PSBoundParameters['ErrorAction']
                    if ($null -eq $readAction) { $readAction = 'Continue' }
                    Write-Error 'Injected memory read error.' -Category ReadError -ErrorAction $readAction
                    return
                }
            }
            Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
        }
        function Copy-Item {
            [CmdletBinding()]
            param($LiteralPath, $Destination, [switch]$Force)
            Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
            if ($LiteralPath -eq $readErrorMemory) {
                $probe.backup = $Destination
                if ($probe.corrupt_backup) {
                    Set-AgentUtf8Content -LiteralPath $Destination -Value 'damaged copy'
                }
            }
        }

        try {
            foreach ($case in @(
                @{ action = 'view'; fail_at = 1 }
                @{ action = 'append'; fail_at = 1 }
                @{ action = 'set'; fail_at = 2 }
                @{ action = 'clear'; fail_at = 3 }
            )) {
                $probe.reads = 0
                $probe.fail_at = $case.fail_at
                $arguments = @{ action = $case.action }
                if ($case.action -in @('append', 'set')) { $arguments.content = 'replacement' }
                $result = Invoke-AgentTool -Root $readErrorRoot -Call @{ function = @{
                    name = 'memory'; arguments = ($arguments | ConvertTo-Json -Compress)
                } } | ConvertFrom-Json
                Assert-True ($result.error -like '*Injected memory read error*') "Unexpected memory $($case.action) result: $($result | ConvertTo-Json -Compress)"
                Assert-True ((Microsoft.PowerShell.Management\Get-Content -LiteralPath $readErrorMemory -Raw) -ceq 'original memory') 'A read failure changed the memory file.'
                Assert-True (@($script:CurrentTurnWrites).Count -eq 0) 'A failed read recorded an undo operation.'
            }
            Assert-True ($probe.backup -and -not (Test-Path -LiteralPath $probe.backup)) 'A failed pre-write read left a temporary backup.'

            $manualArgs = @{ action = 'set'; content = 'replacement'; user_initiated = $true }
            $probe.corrupt_backup = $true
            $probe.fail_at = 0
            $backupError = ''
            try { $null = Invoke-AgentMemory -Root $readErrorRoot -Arguments $manualArgs }
            catch { $backupError = $_.Exception.Message }
            Assert-True ($backupError -like '*Backup verification failed*') 'A manual memory replacement proceeded without a verified backup.'
            Assert-True ((Microsoft.PowerShell.Management\Get-Content -LiteralPath $readErrorMemory -Raw) -ceq 'original memory') 'A bad backup allowed a manual replacement.'

            $probe.corrupt_backup = $false
            $probe.reads = 0
            $probe.fail_at = 4
            $verifyError = ''
            try { $null = Invoke-AgentMemory -Root $readErrorRoot -Arguments $manualArgs }
            catch { $verifyError = $_.Exception.Message }
            Assert-True ($verifyError -like '*Injected memory read error*' -and $verifyError.Contains($probe.backup)) 'A failed manual write verification did not report its backup.'
            Assert-True ((Microsoft.PowerShell.Management\Get-Content -LiteralPath $probe.backup -Raw) -ceq 'original memory') 'A failed manual write verification lost the original data.'
            Assert-True (@($script:CurrentTurnWrites).Count -eq 0) 'Manual memory changes joined the undo journal.'
        }
        finally {
            if ($probe.backup) { Remove-Item -LiteralPath $probe.backup -Force -ErrorAction SilentlyContinue }
        }
    }

    # Exercise real turn entry points with a mixed file/memory journal and distinct todo snapshots.
    $memoryRoot = Join-Path $workspacePath 'memory-undo'
    $memoryConfig = Join-Path $envData.TestRoot 'memory-config'
    New-Item -ItemType Directory -Path $memoryRoot, $memoryConfig -Force | Out-Null
    $workspaceMemory = Join-Path $memoryRoot '.shellossus/MEMORY.md'
    $globalMemory = Join-Path $memoryConfig 'MEMORY.md'
    $memorySession = Join-Path $envData.TestRoot 'memory-undo.jsonl'
    $savedMemoryConfig = $script:AgentConfigPath
    $script:AgentConfigPath = Join-Path $memoryConfig '.env'
    try {
        & {
            function Invoke-WebRequest {
                param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
                $request = $Body | ConvertFrom-Json
                if ($request.messages[-1].role -eq 'tool') {
                    $finish = if ($failTurn) { 'content_filter' } else { 'stop' }
                    $choice = @{ finish_reason = $finish; message = @{ content = 'Done.' } }
                }
                else {
                    $calls = @(
                        @{ name = 'memory'; arguments = '{"action":"append","content":"workspace note"}' }
                        @{ name = 'edit_file'; arguments = '{"path":".shellossus/MEMORY.md","old_text":"workspace note","new_text":"edited note"}' }
                        @{ name = 'memory'; arguments = '{"action":"clear"}' }
                        @{ name = 'memory'; arguments = '{"scope":"global","action":"append","content":"global note"}' }
                        @{ name = 'memory'; arguments = '{"scope":"global","action":"clear"}' }
                        @{ name = 'memory'; arguments = '{"action":"set","content":"recreated note"}' }
                        @{ name = 'todo'; arguments = '{"todos":[{"content":"new task","status":"completed"}]}' }
                    )
                    $toolCalls = @(for ($i = 0; $i -lt $calls.Count; $i++) {
                        @{ id = "memory-undo-$i"; type = 'function'; function = $calls[$i] }
                    })
                    $choice = @{ finish_reason = 'tool_calls'; message = @{ content = ''; tool_calls = $toolCalls } }
                }
                $reply = @{ choices = @($choice) } | ConvertTo-Json -Depth 10 -Compress
                Set-Content -LiteralPath $OutFile -Value $reply -Encoding UTF8 -NoNewline
            }

            foreach ($failTurn in @($true, $false)) {
                Set-AgentUtf8Content -LiteralPath $globalMemory -Value ''
                $memoryState = @{
                    workspace = $memoryRoot
                    todos = @(@{ content = 'state task'; status = 'pending' })
                    messages = @(@{ role = 'system'; content = 'system before' }, @{ role = 'user'; content = 'update memory' })
                }
                $script:ActiveSessionTodos = @(@{ content = 'active task'; status = 'in_progress' })
                $turn = Invoke-ReplContinueCommand -State $memoryState -Endpoint 'https://example.invalid/v1/chat/completions' -Model 'test-model' -ApiKey 'fake' -RootPath $memoryRoot -SessionFile $memorySession -MaxSteps 4
                $writes = @($script:CurrentTurnWrites)
                Assert-True (($writes.action -join ',') -eq 'created,modified,deleted,modified,deleted,created') 'Memory and regular file writes did not share the journal.'
                if ($failTurn) {
                    Assert-True (@($turn.undo_stack).Count -eq 0 -and @($memoryState.messages).Count -eq 2) 'A failed turn did not restore history and its undo stack.'
                }
                else {
                    $frame = $turn.undo_stack[0]
                    Assert-True ($memoryState.todos[0].content -eq 'new task' -and $script:ActiveSessionTodos[0].content -eq 'new task') 'The todo tool did not update both task boards.'
                    Assert-True ((Get-Content -LiteralPath $workspaceMemory -Raw) -like '*recreated note*' -and -not (Test-Path -LiteralPath $globalMemory)) 'The memory mutations did not reach disk.'

                    Set-AgentUtf8Content -LiteralPath $globalMemory -Value 'manual replacement'
                    $manualConflict = ''
                    try { Invoke-AgentUndo -State $memoryState -UndoEntry $frame }
                    catch { $manualConflict = $_.Exception.Message }
                    Assert-True ($manualConflict -like '*manual changes*' -and (Test-Path -LiteralPath $workspaceMemory)) 'A manually recreated memory file did not stop undo preflight.'
                    Remove-Item -LiteralPath $globalMemory -Force

                    $partialError = & {
                        function Copy-Item {
                            [CmdletBinding()]
                            param($LiteralPath, $Destination, [switch]$Force)
                            if ($Destination -eq $globalMemory) { throw 'Injected memory restore failure.' }
                            Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
                        }
                        try { Invoke-AgentUndo -State $memoryState -UndoEntry $frame }
                        catch { $_.Exception.Message }
                    }
                    Assert-True ($partialError -like '*Injected memory restore failure*' -and $partialError.Contains($globalMemory) -and $partialError.Contains($writes[4].backup)) 'Partial undo did not report pending memory operations and backup paths.'
                    Assert-True ($writes[-1].undone -and -not $writes[2].undone -and -not (Test-Path -LiteralPath $workspaceMemory)) 'Partial undo did not stop before earlier writes.'
                    Assert-True ($memoryState.todos[0].content -eq 'new task' -and $script:ActiveSessionTodos[0].content -eq 'new task') 'Partial undo restored todo before restoring files.'
                    Clear-AgentUndoBackups -UndoEntries @($frame) -Writes $writes
                    Assert-True (Test-Path -LiteralPath $writes[4].backup) 'Partial undo lost a recovery backup.'
                    $undo = Invoke-ReplUndoCommand -State $memoryState -RootPath $memoryRoot -Model 'test-model' -SessionFile $memorySession -UndoStack @($frame)
                    Assert-True (@($undo.undo_stack).Count -eq 0) 'The partial undo could not be retried.'
                    $meta = Get-Content -LiteralPath $memorySession -TotalCount 1 | ConvertFrom-Json
                    Assert-True ($meta.todos[0].content -eq 'active task') 'Undo did not persist the restored task board.'
                }
                Assert-True (-not (Test-Path -LiteralPath $workspaceMemory) -and (Test-Path -LiteralPath $globalMemory -PathType Leaf) -and (Get-Item -LiteralPath $globalMemory).Length -eq 0) 'Rollback did not distinguish missing from empty memory.'
                Assert-True ($memoryState.todos[0].content -eq 'state task' -and $script:ActiveSessionTodos[0].content -eq 'active task') 'Rollback did not restore the two task snapshots independently.'
                Assert-True ($memoryState.messages[0].content -notlike '*recreated note*') 'Restored system prompt still includes undone memory.'
                foreach ($w in $writes) {
                    Assert-True (-not $w.backup -or -not (Test-Path -LiteralPath $w.backup)) 'Successful rollback left a recovery backup.'
                }
            }
        }
    }
    finally {
        foreach ($w in @($script:CurrentTurnWrites)) {
            if ($w.backup) { Remove-Item -LiteralPath $w.backup -Force -ErrorAction SilentlyContinue }
        }
        $script:AgentConfigPath = $savedMemoryConfig
        $script:ActiveSessionTodos = @()
    }

    # Failed rollback keeps one pre-turn frame and its backups; success still reports rollback and adds no second frame.
    $script:AgentPermission = 'AutoEdit'
    $script:OutputMode = 'text'
    $global:rbHost = @()
    $global:rbStep = 0
    $global:rbBackup = ''
    $global:rbCorrupt = $true
    $global:rbFileName = ''
    $global:rbOldText = ''
    $global:rbNewText = ''
    $global:rbQueue = @()
    $global:rbRepairOnUndo = $false
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $Separator, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        if ($text) { $global:rbHost = @($global:rbHost) + @($text) }
    }
    function Start-Sleep {
        param($Seconds, $Milliseconds)
    }
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $global:rbStep++
        if ($global:rbStep -eq 1) {
            $editArgs = @{ path = [string]$global:rbFileName; old_text = [string]$global:rbOldText; new_text = [string]$global:rbNewText } | ConvertTo-Json -Compress
            $reply = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = ''
                tool_calls = @(@{ id = 'rb-w1'; type = 'function'; function = @{ name = 'edit_file'; arguments = $editArgs } })
            } }) } | ConvertTo-Json -Depth 10 -Compress
            Set-Content -LiteralPath $OutFile -Value $reply -Encoding UTF8 -NoNewline
            return
        }
        $payload = $Body | ConvertFrom-Json
        $toolRes = $payload.messages[-1].content | ConvertFrom-Json
        if ($toolRes.backup -and -not $global:rbBackup) {
            $global:rbBackup = [string]$toolRes.backup
            if ($global:rbCorrupt) {
                Set-Content -LiteralPath $global:rbBackup -Value 'damaged' -Encoding UTF8 -NoNewline
            }
        }
        throw 'HTTP 500 Internal Server Error'
    }
    function global:Read-Host {
        param($Prompt)
        if (-not $global:rbQueue -or @($global:rbQueue).Count -eq 0) { return '/exit' }
        $next = [string]@($global:rbQueue)[0]
        if (@($global:rbQueue).Count -eq 1) { $global:rbQueue = @() }
        else { $global:rbQueue = @(@($global:rbQueue)[1..(@($global:rbQueue).Count - 1)]) }
        if ($global:rbRepairOnUndo -and $next -eq '/undo' -and $global:rbBackup) {
            Set-Content -LiteralPath $global:rbBackup -Value ([string]$global:rbOldText) -Encoding UTF8 -NoNewline
        }
        return $next
    }
    $rbCfg = Join-Path $envData.TestRoot 'rollback-policy.env'
    Save-AgentConfig -Path $rbCfg -Config @{
        SHELLOSSUS_BASE_URL = 'https://example.invalid/v1'
        SHELLOSSUS_MODEL = 'test-model'
        SHELLOSSUS_API_KEY = 'test-key'
    }
    $rbSessDir = Join-Path $envData.TestRoot 'rollback-sessions'
    New-Item -ItemType Directory -Path $rbSessDir -Force | Out-Null
    try {
        $global:rbFileName = 'continue-fail-rollback.txt'
        $global:rbOldText = 'before-continue'
        $global:rbNewText = 'after-continue'
        $global:rbCorrupt = $true
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $continueFailPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $continueFailPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        $failState = @{
            messages = @(
                @{ role = 'system'; content = 'sys-keep' },
                @{ role = 'user'; content = 'user-keep' }
            )
            leaf_id = ''
            tree_entries = @()
        }
        Ensure-SessionTree -State $failState
        $preLeaf = [string]$failState.leaf_id
        $preTreeCount = @($failState.tree_entries).Count
        $preMsgCount = @($failState.messages).Count
        Assert-True ($preLeaf -and $preTreeCount -ge 1 -and $preMsgCount -eq 2) 'Continue fixture did not establish a pre-turn tree.'
        $failResult = Invoke-ReplContinueCommand -State $failState -Endpoint 'https://example.invalid/v1/chat/completions' -Model 'test-model' -ApiKey 'fake' -RootPath $workspacePath -SessionFile '' -MaxSteps 4 -UndoStack @()
        $failText = $global:rbHost -join "`n"
        Assert-True ([string]$global:rbBackup) 'Continue fixture did not record a backup path.'
        Assert-True ((Get-Content -LiteralPath $continueFailPath -Raw -Encoding UTF8) -ceq 'after-continue') 'Failed continue restored or skipped the edit.'
        Assert-True ($failText -like '*rollback did not succeed*' -and $failText -like '*Backup verification failed*' -and $failText -notlike '*turn rolled back*') "Failed continue claimed success or hid the rollback error: $failText"
        $keptStack = @($failResult.undo_stack)
        Assert-True ($keptStack.Count -eq 1) "Failed continue kept $($keptStack.Count) undo frames."
        Assert-True (@($failState.messages).Count -gt $preMsgCount -and [string]$failState.leaf_id -ne $preLeaf -and @($failState.tree_entries).Count -gt $preTreeCount) 'Failed continue applied history or the session tree.'
        $keptFrame = $keptStack[0]
        $frameBackup = ''
        foreach ($w in @($keptFrame.writes)) { if ($w -and $w.backup) { $frameBackup = [string]$w.backup } }
        Assert-True (@($keptFrame.messages).Count -eq $preMsgCount -and [string]$keptFrame.messages[0].content -eq 'sys-keep' -and [string]$keptFrame.leaf_id -eq $preLeaf -and @($keptFrame.tree_entries).Count -eq $preTreeCount -and $frameBackup -eq [string]$global:rbBackup) 'Kept frame is not the pre-turn snapshot plus the turn writes.'
        $ordinaryBak = New-AgentTempFile
        $ordinaryEntry = @{ messages = @(); leaf_id = ''; tree_entries = @(); writes = @(@{ action = 'modified'; backup = $ordinaryBak.FullName }) }
        Clear-AgentUndoBackups -UndoEntries (@($ordinaryEntry) + $keptStack) -Writes @($script:CurrentTurnWrites)
        Assert-True (-not (Test-Path -LiteralPath $ordinaryBak.FullName)) 'Ordinary undo backup survived cleanup.'
        Assert-True (Test-Path -LiteralPath $global:rbBackup) 'Clear-AgentUndoBackups deleted a failed-rollback backup.'
        $newState = @{ messages = @(@{ role = 'system'; content = 'sys' }); workspace = $workspacePath; model = 'test-model' }
        $newRes = Invoke-ReplNewSessionCommand -State $newState -RootPath $workspacePath -ConfigDir '' -Model 'test-model' -SessionDir $rbSessDir -UndoStack $keptStack
        Assert-True (@($newRes.undo_stack).Count -eq 0 -and (Test-Path -LiteralPath $global:rbBackup)) '/new deleted a failed-rollback backup.'
        $forkState = @{
            session_id = 'sess-fork-src'
            workspace = $workspacePath
            model = 'test-model'
            messages = @(
                @{ role = 'system'; content = 'sys' },
                @{ role = 'user'; content = 'fork-user' },
                @{ role = 'assistant'; content = 'fork-assistant' }
            )
        }
        $forkRes = Invoke-ReplForkCommand -State $forkState -SessionDir $rbSessDir -UndoStack $keptStack
        Assert-True (@($forkRes.undo_stack).Count -eq 0 -and (Test-Path -LiteralPath $global:rbBackup)) '/fork deleted a failed-rollback backup.'
        $importFile = Join-Path $rbSessDir 'import-source.jsonl'
        $importSource = @{
            session_id = 'sess-import-src'
            workspace = $workspacePath
            model = 'test-model'
            messages = @(
                @{ role = 'system'; content = 'sys' },
                @{ role = 'user'; content = 'imported-user' },
                @{ role = 'assistant'; content = 'imported-assistant' }
            )
        }
        Save-AgentSession -SessionFile $importFile -State $importSource -Workspace $workspacePath -Model 'test-model' -SessionId 'sess-import-src'
        $importLive = @{ messages = @(@{ role = 'system'; content = 'live' }); workspace = $workspacePath; model = 'test-model' }
        $importRes = Invoke-ReplImportCommand -State $importLive -RootPath $workspacePath -SessionFile '' -Model 'test-model' -UndoStack $keptStack -ImportArg $importFile
        Assert-True (@($importRes.undo_stack).Count -eq 0 -and (Test-Path -LiteralPath $global:rbBackup)) '/import deleted a failed-rollback backup.'
        $resumeLive = @{ messages = @(@{ role = 'system'; content = 'live' }); workspace = $workspacePath; model = 'test-model' }
        $resumeRes = Invoke-ReplSessionsCommand -State $resumeLive -SessionDir $rbSessDir -SessionFile '' -RootPath $workspacePath -Model 'test-model' -UndoStack $keptStack -ResumeArg 'import-source.jsonl'
        Assert-True (@($resumeRes.undo_stack).Count -eq 0 -and (Test-Path -LiteralPath $global:rbBackup)) '/resume deleted a failed-rollback backup.'
        Set-Content -LiteralPath $global:rbBackup -Value 'before-continue' -Encoding UTF8 -NoNewline
        $undoRes = Invoke-ReplUndoCommand -State $failState -SessionFile '' -RootPath $workspacePath -Model 'test-model' -UndoStack $keptStack
        Assert-True ((Get-Content -LiteralPath $continueFailPath -Raw -Encoding UTF8) -ceq 'before-continue') 'A later /undo of the kept frame did not restore the file.'
        Assert-True (-not (Test-Path -LiteralPath $global:rbBackup)) 'A later successful undo left the backup file in place.'
        Assert-True (@($undoRes.undo_stack).Count -eq 0) 'Successful /undo kept the frame.'

        $script:AgentPermission = 'AutoEdit'
        $global:rbFileName = 'continue-ok-rollback.txt'
        $global:rbOldText = 'before-ok'
        $global:rbNewText = 'after-ok'
        $global:rbCorrupt = $false
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $continueOkPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $continueOkPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        $okState = @{
            messages = @(
                @{ role = 'system'; content = 'sys-ok' },
                @{ role = 'user'; content = 'user-ok' }
            )
            leaf_id = ''
            tree_entries = @()
        }
        Ensure-SessionTree -State $okState
        $okPreLeaf = [string]$okState.leaf_id
        $priorFrame = @{ messages = @(@{ role = 'system'; content = 'prior-frame' }); leaf_id = 'prior'; tree_entries = @(); writes = @() }
        $okResult = Invoke-ReplContinueCommand -State $okState -Endpoint 'https://example.invalid/v1/chat/completions' -Model 'test-model' -ApiKey 'fake' -RootPath $workspacePath -SessionFile '' -MaxSteps 4 -UndoStack @($priorFrame)
        $okText = $global:rbHost -join "`n"
        Assert-True ($okText -like '*Continue failed; turn rolled back:*' -and $okText -notlike '*did not succeed*') "Successful continue did not report rollback: $okText"
        Assert-True (@($okResult.undo_stack).Count -eq 1 -and [string]$okResult.undo_stack[0].messages[0].content -eq 'prior-frame') 'Successful continue kept a second undo frame.'
        Assert-True ((Get-Content -LiteralPath $continueOkPath -Raw -Encoding UTF8) -ceq 'before-ok') 'Successful continue did not restore the file.'
        Assert-True (@($okState.messages).Count -eq 2 -and [string]$okState.messages[1].content -eq 'user-ok' -and [string]$okState.leaf_id -eq $okPreLeaf) 'Successful continue did not restore history.'
        Assert-True ([string]$global:rbBackup -and -not (Test-Path -LiteralPath $global:rbBackup)) 'Successful continue left the backup file in place.'

        $global:rbFileName = 'repl-fail-rollback.txt'
        $global:rbOldText = 'before-repl'
        $global:rbNewText = 'after-repl'
        $global:rbCorrupt = $true
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $global:rbRepairOnUndo = $false
        $global:rbQueue = @('please edit', '/exit')
        $replFailPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $replFailPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Permission AutoEdit -Mode text -NoSession -ConfigPath $rbCfg
        $replFailText = $global:rbHost -join "`n"
        Assert-True ([string]$global:rbBackup) 'REPL fixture did not record a backup path.'
        Assert-True ($replFailText -like '*rollback did not succeed*' -and $replFailText -like '*Backup verification failed*' -and $replFailText -notlike '*turn rolled back*') "REPL claimed the turn rolled back: $replFailText"
        Assert-True ((Get-Content -LiteralPath $replFailPath -Raw -Encoding UTF8) -ceq 'after-repl') 'REPL failed rollback restored the file.'
        Assert-True (Test-Path -LiteralPath $global:rbBackup) 'REPL exit deleted the failed-rollback backup.'
        $replFailBackup = [string]$global:rbBackup

        $global:rbFileName = 'repl-undo-rollback.txt'
        $global:rbOldText = 'before-undo'
        $global:rbNewText = 'after-undo'
        $global:rbCorrupt = $true
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $global:rbRepairOnUndo = $true
        $global:rbQueue = @('please edit', '/undo', '/exit')
        $replUndoPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $replUndoPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Permission AutoEdit -Mode text -NoSession -ConfigPath $rbCfg
        $replUndoText = $global:rbHost -join "`n"
        Assert-True ((Get-Content -LiteralPath $replUndoPath -Raw -Encoding UTF8) -ceq 'before-undo') "REPL /undo could not retry the kept frame: $replUndoText"
        Assert-True ([string]$global:rbBackup -and -not (Test-Path -LiteralPath $global:rbBackup)) 'Successful REPL /undo left the backup file in place.'
        Assert-True ($replUndoText -like '*Reverted last turn*') "REPL /undo did not restore the kept frame: $replUndoText"

        $global:rbFileName = 'repl-ok-rollback.txt'
        $global:rbOldText = 'before-repl-ok'
        $global:rbNewText = 'after-repl-ok'
        $global:rbCorrupt = $false
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $global:rbRepairOnUndo = $false
        $global:rbQueue = @('please edit', '/undo', '/exit')
        $replOkPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $replOkPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Permission AutoEdit -Mode text -NoSession -ConfigPath $rbCfg
        $replOkText = $global:rbHost -join "`n"
        Assert-True ($replOkText -like '*Request failed; turn rolled back (use /retry to resend):*' -and $replOkText -like '*Nothing to undo*' -and $replOkText -notlike '*did not succeed*') "Successful REPL rollback kept a frame or changed the success text: $replOkText"
        Assert-True ((Get-Content -LiteralPath $replOkPath -Raw -Encoding UTF8) -ceq 'before-repl-ok') 'Successful REPL rollback did not restore the file.'
        Assert-True ([string]$global:rbBackup -and -not (Test-Path -LiteralPath $global:rbBackup)) 'Successful REPL rollback left the backup file in place.'

        $global:rbFileName = 'prompt-fail-rollback.txt'
        $global:rbOldText = 'before-prompt'
        $global:rbNewText = 'after-prompt'
        $global:rbCorrupt = $true
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $global:rbQueue = @()
        $promptFailPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $promptFailPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        $promptThrew = $false
        $promptErr = ''
        try {
            & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Prompt 'edit the file' -Permission AutoEdit -Mode text -NoSession -ConfigPath $rbCfg
        }
        catch {
            $promptThrew = $true
            $promptErr = [string]$_.Exception.Message
        }
        $promptText = $global:rbHost -join "`n"
        Assert-True ($promptThrew -and $promptErr -like '*500*') "Single-shot -Prompt did not surface the request error: $promptErr"
        Assert-True ([string]$global:rbBackup) 'Single-shot fixture did not record a backup path.'
        Assert-True ($promptText -like '*rollback did not succeed*' -and $promptText -like '*Backup verification failed*' -and $promptText -notlike '*rolled back*') "Single-shot -Prompt claimed the turn rolled back: $promptText"
        Assert-True ((Get-Content -LiteralPath $promptFailPath -Raw -Encoding UTF8) -ceq 'after-prompt') 'Single-shot failed rollback restored the file.'
        Assert-True (Test-Path -LiteralPath $global:rbBackup) 'Single-shot exit deleted the failed-rollback backup.'
        $promptFailBackup = [string]$global:rbBackup

        $global:rbFileName = 'prompt-json-rollback.txt'
        $global:rbOldText = 'before-json'
        $global:rbNewText = 'after-json'
        $global:rbCorrupt = $true
        $global:rbStep = 0
        $global:rbBackup = ''
        $global:rbHost = @()
        $promptJsonPath = Join-Path $workspacePath $global:rbFileName
        Set-Content -LiteralPath $promptJsonPath -Value $global:rbOldText -Encoding UTF8 -NoNewline
        $jsonThrew = $false
        $jsonErr = ''
        try {
            & "$PSScriptRoot\..\shellossus.ps1" -Workspace $workspacePath -BaseUrl 'https://example.invalid/v1' -Model 'test-model' -Prompt 'edit the file' -Permission AutoEdit -Mode json -NoSession -ConfigPath $rbCfg
        }
        catch {
            $jsonThrew = $true
            $jsonErr = [string]$_.Exception.Message
        }
        Assert-True ($jsonThrew -and $jsonErr -like '*500*' -and $jsonErr -notlike '*rolled back*') "JSON -Prompt did not surface the original request error: $jsonErr"
        Assert-True ([string]$global:rbBackup -and (Test-Path -LiteralPath $global:rbBackup)) 'JSON -Prompt exit deleted the failed-rollback backup.'
        Assert-True ((Get-Content -LiteralPath $promptJsonPath -Raw -Encoding UTF8) -ceq 'after-json') 'JSON -Prompt failed rollback restored the file.'
        $sawJsonEnd = $false
        foreach ($jsonLine in @($global:rbHost)) {
            $trim = [string]$jsonLine
            if (-not $trim.Trim()) { continue }
            Assert-True ($trim.Trim().StartsWith('{')) "JSON mode wrote plain text: $trim"
            Assert-True ($trim -notlike '*rolled back*' -and $trim -notlike '*did not succeed*') "JSON mode claimed a rollback result: $trim"
            $jsonEv = $trim | ConvertFrom-Json
            if ([string]$jsonEv.type -eq 'turn_end') {
                $sawJsonEnd = $true
                Assert-True ([string]$jsonEv.status -eq 'error' -and [string]$jsonEv.error -like '*500*' -and [string]$jsonEv.error -notlike '*rolled back*') "JSON turn_end claimed rollback: $trim"
                Assert-True ($jsonEv.rollback_error -like '*Backup verification failed*' -and $jsonEv.rollback_error.Contains($global:rbBackup)) 'JSON turn_end omitted the rollback failure and backup path.'
            }
        }
        Assert-True $sawJsonEnd 'JSON -Prompt did not emit turn_end.'
        if ($replFailBackup -and (Test-Path -LiteralPath $replFailBackup)) { Remove-Item -LiteralPath $replFailBackup -Force -ErrorAction SilentlyContinue }
        if ($promptFailBackup -and (Test-Path -LiteralPath $promptFailBackup)) { Remove-Item -LiteralPath $promptFailBackup -Force -ErrorAction SilentlyContinue }
        if ($global:rbBackup -and (Test-Path -LiteralPath $global:rbBackup)) { Remove-Item -LiteralPath $global:rbBackup -Force -ErrorAction SilentlyContinue }
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        $script:OutputMode = 'json'
        $script:AgentPermission = 'AutoEdit'
        $script:CurrentTurnWrites = @()
        Remove-Variable -Name rbHost, rbStep, rbBackup, rbCorrupt, rbFileName, rbOldText, rbNewText, rbQueue, rbRepairOnUndo -Scope Global -ErrorAction SilentlyContinue
    }

    # A copy failure after preflight must not apply history or the session tree, and must keep the backup.
    if (Get-Command chflags -ErrorAction SilentlyContinue) {
        $script:CurrentTurnWrites = @()
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'json'
        $diskPath = Join-Path $workspacePath 'rollback-disk.txt'
        Set-Content -LiteralPath $diskPath -Value 'disk-before' -Encoding UTF8 -NoNewline
        $diskArgs = @{ path = 'rollback-disk.txt'; old_text = 'disk-before'; new_text = 'disk-after' } | ConvertTo-Json -Compress
        $diskEdit = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'edit_file'; arguments = $diskArgs } } | ConvertFrom-Json
        Assert-True ($diskEdit.status -eq 'written' -and @($script:CurrentTurnWrites).Count -eq 1) 'Disk-failure fixture edit did not record a backup.'
        $diskBackup = [string]$script:CurrentTurnWrites[0].backup
        $diskState = @{
            messages = @(
                @{ role = 'system'; content = 'sys-live' },
                @{ role = 'assistant'; content = 'live-after-edit' }
            )
            leaf_id = 'leaf-live'
            tree_entries = @(@{ id = 'leaf-live'; parent_id = $null; role = 'assistant'; content = 'live-after-edit' })
        }
        $diskSnap = @{
            messages = @(@{ role = 'system'; content = 'sys-snap' })
            leaf_id = 'leaf-snap'
            tree_entries = @(@{ id = 'leaf-snap'; parent_id = $null; role = 'system'; content = 'sys-snap' })
        }
        $diskLocked = $false
        try {
            & chflags uchg $diskPath
            if ($LASTEXITCODE -ne 0) { throw 'chflags uchg failed.' }
            $diskLocked = $true
            $diskThrew = $false
            $diskError = ''
            try {
                Restore-AgentTurnSnapshot -State $diskState -Snapshot $diskSnap -Writes @($script:CurrentTurnWrites)
            }
            catch {
                $diskThrew = $true
                $diskError = [string]$_.Exception.Message
            }
            Assert-True ($diskThrew -and $diskError -like '*Undo failed*') "Disk restore did not fail: $diskError"
            Assert-True (@($diskState.messages).Count -eq 2 -and [string]$diskState.messages[1].content -eq 'live-after-edit' -and [string]$diskState.leaf_id -eq 'leaf-live' -and [string]$diskState.tree_entries[0].id -eq 'leaf-live') 'Disk restore failure applied history or the session tree.'
            $diskBytes = Get-Content -LiteralPath $diskPath -Raw -Encoding UTF8
            Assert-True ($diskBytes -ceq 'disk-after' -and (Test-Path -LiteralPath $diskBackup)) "Disk restore failure removed the backup or rewrote the file: $diskBytes"
        }
        finally {
            if ($diskLocked) { & chflags nouchg $diskPath }
        }
    }

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

    # Model-authored task text stays literal even when it names an existing file.
    Set-AgentUtf8Content -LiteralPath (Join-Path $workspacePath 'model-only.txt') -Value 'private attachment marker'
    & {
        $receivedTasks = @{ prompts = @() }
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $request = $Body | ConvertFrom-Json
            $task = [string]$request.messages[-1].content
            $receivedTasks.prompts += $task
            Assert-True (@($request.tools).Count -eq 0) 'Attachment fixture unexpectedly exposed a file tool.'
            $replyText = if ($task -eq 'Generate a reference') { 'generated @model-only.txt' } else { 'done' }
            @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = $replyText } }) } |
                ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $OutFile -Encoding UTF8 -NoNewline
        }
        foreach ($arguments in @(
            '{"role":"writer-only","prompt":"Inspect @model-only.txt"}'
            '{"parallel":[{"role":"writer-only","prompt":"Parallel @model-only.txt"}]}'
            '{"pipeline":[{"role":"writer-only","prompt":"Generate a reference"},{"role":"writer-only","prompt":"Use {previous} and $PREVIOUS"}]}'
        )) {
            $res = Invoke-AgentTool -Root $workspacePath -Call @{ function = @{ name = 'run_agent'; arguments = $arguments } } | ConvertFrom-Json
            Assert-True ($res.status -eq 'completed') "Subagent attachment fixture failed: $($res.error)"
        }
        $expected = @('Inspect @model-only.txt', 'Parallel @model-only.txt', 'Generate a reference', 'Use generated @model-only.txt and generated @model-only.txt')
        Assert-True (($receivedTasks.prompts -join '|') -ceq ($expected -join '|')) 'A model task or pipeline result was expanded as a file attachment.'
    }

    # CLI input can attach a file through a template argument. Template text and literal worker input stay inert.
    $templateDir = Join-Path $workspacePath '.shellossus/prompts'
    New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
    Set-AgentUtf8Content -LiteralPath (Join-Path $templateDir 'check-files.md') -Value 'Review $1 and @model-only.txt'
    Set-AgentUtf8Content -LiteralPath (Join-Path $workspacePath 'explicit.txt') -Value 'user attachment marker'
    $promptConfig = Join-Path $envData.TestRoot 'attachment-policy.env'
    Save-AgentConfig -Path $promptConfig -Config @{ SHELLOSSUS_API_KEY = 'test-key' }
    & {
        $received = @{ prompts = @(); fail_next = $false; queue = @() }
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $request = $Body | ConvertFrom-Json
            $received.prompts += [string]$request.messages[-1].content
            $finish = if ($received.fail_next) { 'content_filter' } else { 'stop' }
            $received.fail_next = $false
            @{ choices = @(@{ finish_reason = $finish; message = @{ content = 'done' } }) } |
                ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $OutFile -Encoding UTF8 -NoNewline
        }
        function Read-Host {
            param($Prompt)
            if ($received.queue.Count -eq 0) { return '/exit' }
            $next = $received.queue[0]
            $received.queue = @($received.queue | Select-Object -Skip 1)
            return $next
        }
        $cliArgs = @{ Workspace = $workspacePath; BaseUrl = 'https://example.invalid/v1'; Model = 'test-model'; ConfigPath = $promptConfig; NoSession = $true }
        $userInput = '/check-files "@explicit.txt"'
        & "$PSScriptRoot\..\shellossus.ps1" @cliArgs -Mode json -Prompt $userInput
        & "$PSScriptRoot\..\shellossus.ps1" @cliArgs -Mode json -Prompt $userInput -LiteralPrompt
        $received.fail_next = $true
        $received.queue = @($userInput, '/retry', '/exit')
        & "$PSScriptRoot\..\shellossus.ps1" @cliArgs -Mode text
        Assert-True ($received.prompts.Count -eq 4 -and $received.prompts[1] -ceq $userInput) 'The worker prompt expanded user shortcuts or the REPL did not retry.'
        foreach ($promptIndex in @(0, 2, 3)) {
            $sent = $received.prompts[$promptIndex]
            Assert-True ($sent -like 'Review @explicit.txt and @model-only.txt*<file path="explicit.txt">*user attachment marker*') 'An explicit template argument lost its file attachment.'
            Assert-True ($sent -notlike '*private attachment marker*' -and $sent -notlike '*<file path="model-only.txt">*') 'Template text or retry requested an implicit attachment.'
        }
    }

    # Actual worker processes receive the same role/parent intersection, CLI flags
    # (-NoSkills, -NoPromptTemplates, -NoContextFiles, -ReasoningEffort), role in system prompt
    # rather than user -Prompt, and aggregate token usage into parent $State.
    $workerScript = Join-Path $envData.TestRoot 'policy-worker.ps1'
    $libraryPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'shellossus.ps1').Replace("'", "''")
    $workerText = @'
param(
    $Workspace,
    $BaseUrl,
    $Model,
    $Permission,
    $Mode,
    [switch]$NoSession,
    $MaxSteps,
    $Tools,
    [switch]$NoTools,
    $ExcludeTools,
    $Prompt,
    [switch]$LiteralPrompt,
    $ConfigPath,
    [switch]$NoSkills,
    [switch]$NoPromptTemplates,
    [switch]$NoContextFiles,
    $ReasoningEffort
)
$allowed = $Tools
$disabled = [bool]$NoTools
$denied = $ExcludeTools
$passedNoSkills = [bool]$NoSkills
$passedNoTemplates = [bool]$NoPromptTemplates
$passedNoContext = [bool]$NoContextFiles
$passedReasoning = [string]$ReasoningEffort
$passedPrompt = [string]$Prompt
$passedLiteralPrompt = [bool]$LiteralPrompt
. '__LIBRARY__' -LibraryOnly
$script:EnabledTools = @($allowed -split ',' | Where-Object { $_ })
$script:ExcludedTools = @($denied -split ',' | Where-Object { $_ })
$script:NoTools = $disabled
$script:NoSkills = $passedNoSkills
$script:NoPromptTemplates = $passedNoTemplates
$script:NoContextFiles = $passedNoContext
$script:ReasoningEffort = $passedReasoning
$script:AgentPermission = 'ReadOnly'
$sysPrompt = Build-SystemPrompt -Root $Workspace -ConfigDir ''
$names = @(Get-AgentTools | ForEach-Object { $_.function.name })
$payload = @{
    tools = $names
    no_tools = $disabled
    no_skills = $passedNoSkills
    no_templates = $passedNoTemplates
    no_context = $passedNoContext
    reasoning_effort = $passedReasoning
    user_prompt = $passedPrompt
    literal_prompt = $passedLiteralPrompt
    sys_has_role = $sysPrompt.Contains("[Subagent Role: $($env:SHELLOSSUS_SUB_ROLE)]")
}
@{ type = 'message_end'; role = 'assistant'; content = ($payload | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress
@{ type = 'turn_end'; status = 'completed'; usage_input_tokens = 125; usage_output_tokens = 35 } | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath $workerScript -Value $workerText.Replace('__LIBRARY__', $libraryPath) -Encoding Ascii
    $script:EnabledTools = @('r*', 'grep*')
    $script:ExcludedTools = @('grep_files')
    $script:NoSkills = $true
    $script:NoPromptTemplates = $true
    $script:NoContextFiles = $true
    $script:ReasoningEffort = 'high'
    $script:AutoApproveWeb = $true
    $parentStateForParallel = @{ usage_input_tokens = 10; usage_output_tokens = 5 }
    $script:ActiveState = $parentStateForParallel
    try {
        $workerResults = @(Invoke-ParallelSubagentProcesses -Root $workspacePath -Tasks @(@{ role = 'reader'; prompt = '/check-files @model-only.txt' }, @{ role = 'writer-only'; prompt = 'inspect' }) -ScriptPath $workerScript)
        Assert-True ($workerResults.Count -eq 2) 'Parallel worker filter test did not return two results.'
        $reader = $workerResults[0].output | ConvertFrom-Json
        $writer = $workerResults[1].output | ConvertFrom-Json
        Assert-True (($reader.tools -join ',') -eq 'read_file') 'Worker did not inherit aliases, wildcard filters, or exclusions.'
        Assert-True ($writer.no_tools -and $writer.tools.Count -eq 0) 'Empty worker allowlist enabled tools.'
        Assert-True ($reader.no_skills -and $reader.no_templates -and $reader.no_context -and $reader.reasoning_effort -eq 'high') 'Worker did not receive -NoSkills, -NoPromptTemplates, -NoContextFiles, or -ReasoningEffort.'
        Assert-True ($reader.user_prompt -ceq '/check-files @model-only.txt' -and $reader.literal_prompt -and $reader.sys_has_role) ("Parallel worker did not receive a literal user prompt and separate role: " + ($reader | ConvertTo-Json -Compress))
        Assert-True ($parentStateForParallel.usage_input_tokens -eq 260 -and $parentStateForParallel.usage_output_tokens -eq 75) "Parallel worker token usage was not aggregated into parent state (got in=$($parentStateForParallel.usage_input_tokens), out=$($parentStateForParallel.usage_output_tokens))."

        # Regression (Task 11): Aborted/crashed parallel worker that emitted message_end with read_file tool_call
        # but never emitted tool_execution_end or completed turn_end must not report pending read_file as completed.
        $abortWorkerScript = Join-Path $envData.TestRoot 'abort-worker.ps1'
        $abortWorkerText = @'
param($Workspace, $BaseUrl, $Model, $Permission, $Mode, [switch]$NoSession, $MaxSteps, $Tools, [switch]$NoTools, $ExcludeTools, $Prompt, $ConfigPath, [switch]$NoSkills, [switch]$NoPromptTemplates, [switch]$NoContextFiles, $ReasoningEffort)
@{
    type = 'message_end'
    role = 'assistant'
    content = "auto_web=$($env:SHELLOSSUS_SUB_AUTO_WEB)"
    tool_calls = @(@{ id = 'tc-unexecuted'; type = 'function'; function = @{ name = 'read_file'; arguments = '{"path":"never-read.txt"}' } })
} | ConvertTo-Json -Depth 10 -Compress
[Console]::Error.WriteLine('#< CLIXML')
[Console]::Error.WriteLine('<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><AV>Preparing modules for first use.</AV></Obj></Objs>')
exit 1
'@
        Set-Content -LiteralPath $abortWorkerScript -Value $abortWorkerText -Encoding Ascii
        $abortResults = @(Invoke-ParallelSubagentProcesses -Root $workspacePath -Tasks @(@{ role = 'recon'; prompt = 'abort test' }) -ScriptPath $abortWorkerScript)
        Assert-True ($abortResults.Count -eq 1 -and $abortResults[0].status -eq 'error') 'Expected aborted worker status to be error.'
        Assert-True ($abortResults[0].output -eq 'auto_web=1') "Expected SHELLOSSUS_SUB_AUTO_WEB=1 in worker, got '$($abortResults[0].output)'."
        Assert-True (@($abortResults[0].read_files).Count -eq 0) 'Aborted worker before tool_execution_end must not report pending read_file as completed.'

        $stderrWorkerScript = Join-Path $envData.TestRoot 'stderr-worker.ps1'
        $stderrWorkerText = @'
param($Workspace, $BaseUrl, $Model, $Permission, $Mode, [switch]$NoSession, $MaxSteps, $Tools, [switch]$NoTools, $ExcludeTools, $Prompt, $ConfigPath, [switch]$NoSkills, [switch]$NoPromptTemplates, [switch]$NoContextFiles, $ReasoningEffort)
[Console]::Error.WriteLine('#< CLIXML')
[Console]::Error.WriteLine('<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><AV>Preparing modules for first use.</AV></Obj></Objs>')
[Console]::Error.WriteLine('boom')
exit 1
'@
        Set-Content -LiteralPath $stderrWorkerScript -Value $stderrWorkerText -Encoding Ascii
        $stderrResults = @(Invoke-ParallelSubagentProcesses -Root $workspacePath -Tasks @(@{ role = 'recon'; prompt = 'stderr test' }) -ScriptPath $stderrWorkerScript)
        Assert-True ($stderrResults.Count -eq 1 -and $stderrResults[0].status -eq 'error' -and $stderrResults[0].output -eq 'Subagent error: boom') "Plain worker stderr was not kept: $($stderrResults[0].output)"
    }
    finally {
        $script:EnabledTools = @()
        $script:ExcludedTools = @()
        $script:NoSkills = $false
        $script:NoPromptTemplates = $false
        $script:NoContextFiles = $false
        $script:ReasoningEffort = ''
        $script:AutoApproveWeb = $false
        $script:ActiveState = $null
    }

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
        $stillRunning = $false
        if ($p -and ($p.StartTime.Ticks -eq [long]$parts[1])) {
            if (-not $p.HasExited) {
                Wait-Process -InputObject $p -Timeout 3 -ErrorAction SilentlyContinue
            }
            $stillRunning = -not $p.HasExited
        }
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
        $waitStart = Get-Date
        while (-not (Test-Path -LiteralPath $script:inspectionPidPath)) {
            if (((Get-Date) - $waitStart).TotalSeconds -gt 10) { throw 'Inspection fixture did not start.' }
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
    $stillRunning = $false
    if ($p -and ($p.StartTime.Ticks -eq [long]$parts[1])) {
        if (-not $p.HasExited) {
            Wait-Process -InputObject $p -Timeout 3 -ErrorAction SilentlyContinue
        }
        $stillRunning = -not $p.HasExited
    }
    Assert-True (-not $stillRunning) 'A monitoring exception leaked the command process.'

    # Task 13: a process snapshot is collected at most once per second. A later
    # call in that second reuses it, including when a command is stopped.
    $script:AgentProcessParentsCachedAt = $null
    $script:AgentProcessParentsCache = $null
    $script:AgentProcessParentCollections = 0
    $task13First = @(Get-AgentProcessParents)
    $task13Second = @(Get-AgentProcessParents)
    $task13FirstIds = (@($task13First | ForEach-Object { [string]$_.id }) -join ',')
    $task13SecondIds = (@($task13Second | ForEach-Object { [string]$_.id }) -join ',')
    Assert-True ($script:AgentProcessParentCollections -eq 1) "Two process snapshots inside one second collected the full process table $($script:AgentProcessParentCollections) times."
    Assert-True (($task13FirstIds -eq $task13SecondIds) -and ($task13FirstIds.Length -gt 0)) "Second snapshot did not reuse the first process table."
    $script:AgentProcessParentsCachedAt = (Get-Date).AddSeconds(-2)
    $null = @(Get-AgentProcessParents)
    Assert-True ($script:AgentProcessParentCollections -eq 2) "A snapshot older than one second did not collect a new process table (collections=$($script:AgentProcessParentCollections))."
    $task13Tracked = @{}
    $task13Tracked['420000010'] = @{ id = 420000010; start_ticks = 1; depth = 0 }
    $task13StopErrors = @(Stop-AgentProcessTree -Tracked $task13Tracked)
    Assert-True ($task13StopErrors.Count -eq 0) "Stop failed while reusing the process snapshot: $($task13StopErrors -join '; ')"
    Assert-True ($script:AgentProcessParentCollections -eq 2) "Stopping a command collected a new full process table inside the same second (collections=$($script:AgentProcessParentCollections))."
    $script:AgentProcessParentsCachedAt = $null
    $script:AgentProcessParentsCache = $null
    $script:AgentProcessParentCollections = 0
}
finally {
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    foreach ($p in $testProcesses) { if (-not $p.HasExited) { Stop-Process -InputObject $p -Force -ErrorAction SilentlyContinue } }
    if ($processDir -and (Test-Path -LiteralPath $processDir)) {
        foreach ($pidFile in @(Get-ChildItem -LiteralPath $processDir -Filter '*.pid' -File)) {
            $parts = (Get-Content -LiteralPath $pidFile.FullName -Raw).Trim() -split '\|'
            $p = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited -and $p.StartTime.Ticks -eq [long]$parts[1]) { Stop-Process -InputObject $p -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($backup in $testBackups) { if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force } }
    Remove-TestEnvironment -Env $envData
}
