$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    Set-Content -LiteralPath (Join-Path $workspacePath 'hello.txt') -Value 'hello' -Encoding UTF8

    # Agent/tool/API round trip without any network or real key.
    $script:requests = 0
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction)
        $script:requests++
        $payload = $Body | ConvertFrom-Json
        Assert-True ($Method -eq 'Post') 'Expected POST.'
        Assert-True ($payload.model -eq 'test-model') 'Wrong model.'
        if ($script:requests -eq 1) {
            return @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                content = $null
                reasoning_content = 'Inspect directory.'
                tool_calls = @(@{ id = 't1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
            } }) }
        }
        $last = $payload.messages[-1]
        Assert-True ($last.role -eq 'tool' -and $last.tool_call_id -eq 't1') 'Missing tool response.'
        $listing = $last.content | ConvertFrom-Json
        Assert-True ($listing.entries.Name -contains 'hello.txt') 'Tool result missing file.'
        return @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'Files inspected.' } }) }
    }
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $mockReply = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body -TimeoutSec $TimeoutSec -ErrorAction $ErrorAction
        $mockReply | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    }
    $state = @{ messages = @(@{ role = 'user'; content = 'List files' }) }
    Invoke-AgentTurn -State $state -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 3
    Assert-True ($script:requests -eq 2) 'Expected two API calls.'
    Assert-True ($state.messages[-1].content -eq 'Files inspected.') 'Missing final answer.'

    # JSON mode (-Mode json) emits only pure JSONL without plain-text tool logs or Read-Host prompts.
    $capturedHostLines = @()
    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
        $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
        $script:capturedHostLines += $text
    }
    $script:OutputMode = 'json'
    try {
        $script:capturedHostLines = @()
        $jsonListCall = @{ id = 'j-list'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } }
        $jsonListRes = Invoke-AgentTool -Root $workspacePath -Call $jsonListCall | ConvertFrom-Json
        Assert-True ($null -ne $jsonListRes.entries -and $script:capturedHostLines.Count -eq 0) 'Invoke-AgentTool emitted plain-text Write-Host output in JSON mode.'
        $script:AgentPermission = 'Ask'
        $jsonWriteCall = @{ id = 'j-write'; function = @{ name = 'write_file'; arguments = '{"path":"json-blocked.txt","content":"x"}' } }
        $jsonWriteRes = Invoke-AgentTool -Root $workspacePath -Call $jsonWriteCall | ConvertFrom-Json
        Assert-True ($jsonWriteRes.status -eq 'cancelled' -and $script:capturedHostLines.Count -eq 0) 'write_file in Ask+JSON mode did not cancel cleanly or emitted plain text.'
        $script:turnStep = 0
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $script:turnStep++
            if ($script:turnStep -eq 1) {
                $r = @{ choices = @(@{ finish_reason = 'tool_calls'; message = @{
                    content = ''
                    tool_calls = @(@{ id = 'jtc1'; type = 'function'; function = @{ name = 'list_files'; arguments = '{"path":"."}' } })
                } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                $r = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'JSON turn complete.' } }) } | ConvertTo-Json -Depth 10 -Compress
            }
            Set-Content -LiteralPath $OutFile -Value $r -Encoding UTF8 -NoNewline
        }
        $script:capturedHostLines = @()
        $jsonTurnState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'go' }) }
        Invoke-AgentTurn -State $jsonTurnState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 4
        Assert-True ($script:capturedHostLines.Count -ge 4) 'Invoke-AgentTurn emitted no JSON events in JSON mode.'
        foreach ($jLine in $script:capturedHostLines) {
            $parsedEv = $jLine | ConvertFrom-Json -ErrorAction Stop
            Assert-True ([bool]$parsedEv.type) "Non-JSON event line emitted in JSON mode: $jLine"
        }
    }
    finally {
        $script:OutputMode = 'text'
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
    }

    # Truncated model response (finish_reason=length) is rejected before accepting message or running tools.
    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
        $resp = @{ choices = @(@{ finish_reason = 'length'; message = @{
            content = 'Partial reply...'
            tool_calls = @(@{ id = 'bad'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"should-not-exist.txt","content":"x"}' } })
        } }) } | ConvertTo-Json -Depth 10 -Compress
        Set-Content -LiteralPath $OutFile -Value $resp -Encoding UTF8 -NoNewline
    }
    $truncState = @{ messages = @(@{ role = 'user'; content = 'Hi' }) }
    $lengthThrew = $false
    try {
        Invoke-AgentTurn -State $truncState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 2
    }
    catch {
        if ($_.Exception.Message -like '*finish_reason=length*') { $lengthThrew = $true }
    }
    Assert-True $lengthThrew 'Truncated response (finish_reason=length) was not rejected.'
    Assert-True ($truncState.messages.Count -eq 1 -and (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'should-not-exist.txt')))) 'Truncated response modified state or executed tool.'
    $compactTruncState = @{ messages = @(
        @{ role = 'system'; content = 'sys' },
        @{ role = 'user'; content = 'm1' },
        @{ role = 'assistant'; content = 'm2' },
        @{ role = 'user'; content = 'm3' },
        @{ role = 'assistant'; content = 'm4' }
    ) }
    $compactLengthThrew = $false
    try {
        Invoke-AgentCompact -State $compactTruncState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -KeepRecent 2 | Out-Null
    }
    catch {
        if ($_.Exception.Message -like '*finish_reason=length*') { $compactLengthThrew = $true }
    }
    Assert-True ($compactLengthThrew -and $compactTruncState.messages.Count -eq 5) 'Invoke-AgentCompact accepted a truncated summary with finish_reason=length.'

    # Installer: first install, reinstall, shortcuts, conflict detection (alias, function, executable),
    # profile preservation & backup, h-agent block migration, and paths with spaces + argument forwarding.
    $profileFile = Join-Path $testRoot 'profile.ps1'
    $legacyBlock = "# keep my settings`r`n# >>> h-agent >>>`r`nfunction global:h-agent { & 'C:\old\h-agent.ps1' @args }`r`n# <<< h-agent <<<`r`n# footer line"
    Set-Content -LiteralPath $profileFile -Value $legacyBlock -Encoding UTF8 -NoNewline

    # 1. Migrate legacy h-agent block with -Shortcut sss and verify backup & profile preservation.
    & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut 'sss'
    $profileText = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8
    Assert-True ($profileText.Contains('# keep my settings') -and $profileText.Contains('# footer line')) 'Profile user contents were lost during migration.'
    Assert-True ((-not $profileText.Contains('# >>> h-agent >>>')) -and (-not $profileText.Contains('function global:h-agent'))) 'Legacy h-agent block was not migrated.'
    Assert-True (((@($profileText -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1) -and $profileText.Contains('function global:shellossus') -and $profileText.Contains('function global:sss')) 'Expected shellossus and sss functions in migrated block.'
    $backups = @(Get-ChildItem -LiteralPath $testRoot -Filter 'profile.ps1.shellossus-backup-*' -File)
    Assert-True ($backups.Count -ge 1) 'Installer did not create a profile backup before modifying existing profile.'

    # 2. Invalid shortcut syntax rejection (spaces, special chars, leading digit) and mutually exclusive flags.
    foreach ($badName in @('bad space', 'bad$char', '1startdigit', 'a;b', '')) {
        $badThrew = $false
        try {
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut $badName
        }
        catch {
            if ($_.Exception.Message -like '*Invalid shortcut name*') { $badThrew = $true }
        }
        Assert-True $badThrew "Installer accepted invalid shortcut syntax: '$badName'."
    }
    $bothFlagsThrew = $false
    try {
        & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut 's' -NoShortcut
    }
    catch {
        if ($_.Exception.Message -like '*Cannot specify both*') { $bothFlagsThrew = $true }
    }
    Assert-True $bothFlagsThrew 'Installer allowed both -Shortcut and -NoShortcut.'

    # 3. Conflict detection with existing Alias, Function, and Executable (via Get-Command -All).
    Set-Alias -Name 'sc_conflict_alias' -Value Get-ChildItem -Scope Global
    function global:sc_conflict_func { Write-Output 'user custom function' }
    $binDir = Join-Path $testRoot 'bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    $exeScript = Join-Path $binDir 'sc_conflict_exe.cmd'
    Set-Content -LiteralPath $exeScript -Value '@echo off' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $binDir 'sc_conflict_exe.ps1') -Value 'Write-Output "ext"' -Encoding Ascii
    $savedPath = $env:PATH
    $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
    try {
        foreach ($conflictName in @('sc_conflict_alias', 'sc_conflict_func', 'sc_conflict_exe')) {
            $confThrew = $false
            try {
                & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut $conflictName
            }
            catch {
                if ($_.Exception.Message -like "*conflicts with existing*") { $confThrew = $true }
            }
            Assert-True $confThrew "Installer did not reject conflicting command '$conflictName'."
        }

        # 4. Own previously installed shortcut function is recognized and NOT treated as a conflict on rerun.
        . $profileFile
        & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $profileFile -Shortcut 'sss'
        $profileTextAfterRerun = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8
        Assert-True (((@($profileTextAfterRerun -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1) -and $profileTextAfterRerun.Contains('function global:sss')) 'Rerun with own existing shortcut failed or duplicated block.'

        # 5. Interactive flows: first install menu (conflict retry -> custom name) and reinstall menu (keep -> change -> remove).
        $interactiveProfile = Join-Path $testRoot 'interactive-profile.ps1'
        $global:readQueue = @('1', '4', 'bad name!', '4', 'shos_custom')
        Set-Alias -Name 's' -Value Get-Location -Scope Global
        function global:Read-Host {
            param($Prompt)
            if (-not $global:readQueue -or $global:readQueue.Count -eq 0) { return '5' }
            $next = $global:readQueue[0]
            if ($global:readQueue.Count -eq 1) { $global:readQueue = @() }
            else { $global:readQueue = @($global:readQueue[1..($global:readQueue.Count - 1)]) }
            return $next
        }
        try {
            # First install: '1' ('s') conflicts with alias 's', then '4' ('bad name!') fails syntax, then '4' ('shos_custom') succeeds.
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText1 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText1.Contains('function global:shos_custom')) 'Interactive first install with conflict retry and custom shortcut failed.'

            # Reinstall 1: '1' (Keep 'shos_custom').
            $global:readQueue = @('1')
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText2 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText2.Contains('function global:shos_custom') -and ((@($intText2 -split '(?m)^# >>> shellossus >>>\r?$').Count - 1) -eq 1)) 'Interactive reinstall keep shortcut failed.'

            # Reinstall 2: '2' (Change shortcut) -> '3' ('shos').
            $global:readQueue = @('2', '3')
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText3 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText3.Contains('function global:shos') -and (-not $intText3.Contains('function global:shos_custom'))) 'Interactive reinstall change shortcut failed.'

            # Reinstall 3: '3' (Remove shortcut).
            $global:readQueue = @('3')
            & "$PSScriptRoot\..\install.ps1" -AgentPath "$PSScriptRoot\..\shellossus.ps1" -ProfilePath $interactiveProfile
            $intText4 = Get-Content -LiteralPath $interactiveProfile -Raw -Encoding UTF8
            Assert-True ($intText4.Contains('function global:shellossus') -and (-not $intText4.Contains('function global:shos'))) 'Interactive reinstall remove shortcut failed.'
        }
        finally {
            Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
            Remove-Variable -Name readQueue -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Alias:\s -Force -ErrorAction SilentlyContinue
        }

        # 6. Paths with spaces and full @args forwarding through registered functions.
        $spacedDir = Join-Path $testRoot 'Folder With Spaces'
        New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
        $spacedAgent = Join-Path $spacedDir 'shellossus.ps1'
        Set-Content -LiteralPath $spacedAgent -Value 'param([string]$Workspace, [string]$Prompt, [int]$MaxSteps) (@{ ws = $Workspace; prompt = $Prompt; steps = $MaxSteps } | ConvertTo-Json -Compress)' -Encoding Ascii
        $spacedProfile = Join-Path $spacedDir 'spaced profile.ps1'
        & "$PSScriptRoot\..\install.ps1" -AgentPath $spacedAgent -ProfilePath $spacedProfile -Shortcut 'shos_spaced'
        . $spacedProfile
        $forwardedRaw = shos_spaced -Workspace 'C:\Project With Spaces' -Prompt 'hello world' -MaxSteps 7
        $forwardedObj = $forwardedRaw | ConvertFrom-Json
        Assert-True ($forwardedObj.ws -eq 'C:\Project With Spaces' -and $forwardedObj.prompt -eq 'hello world' -and $forwardedObj.steps -eq 7) 'Shortcut function failed to forward arguments or path with spaces.'
    }
    finally {
        $env:PATH = $savedPath
        Remove-Item Alias:\sc_conflict_alias -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:sc_conflict_func -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:sss -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:shellossus -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\global:shos_spaced -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-TestEnvironment -Env $envData
}
