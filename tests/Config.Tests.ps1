$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    # Config is parsed as data; embedded PowerShell expressions stay literal.
    $configPath = Join-Path $testRoot '.env'
    Save-AgentConfig -Path $configPath -Config @{
        SHELLOSSUS_BASE_URL = 'https://example.invalid/v1'
        SHELLOSSUS_MODEL = 'test-model'
        SHELLOSSUS_API_KEY = 'fake=key#$(throw injected)'
        SHELLOSSUS_WORKSPACE = 'C:\folder with spaces'
    }
    $loadedConfig = Read-AgentConfig -Path $configPath
    Assert-True ($loadedConfig.SHELLOSSUS_API_KEY -eq 'fake=key#$(throw injected)') 'Config value was corrupted or evaluated.'
    Assert-True ($loadedConfig.SHELLOSSUS_WORKSPACE -eq 'C:\folder with spaces') 'Config path changed.'
    $absentConfig = Read-AgentConfig -Path (Join-Path $testRoot 'missing.env')
    Assert-True ($absentConfig.Count -eq 0) 'Missing config should produce empty settings.'

    # Credential and secret file protection (.env and custom ConfigPath).
    Set-Content -LiteralPath (Join-Path $workspacePath '.env') -Value 'SECRET=hidden' -Encoding UTF8
    $call = @{ id = 'cfg-env'; function = @{ name = 'read_file'; arguments = '{"path":".env"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Agent must not read .env.'

    $customCfg = Join-Path $workspacePath 'custom.cfg'
    Set-Content -LiteralPath $customCfg -Value 'SHELLOSSUS_API_KEY="secret"' -Encoding UTF8
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $workspacePath '.\custom.cfg')
    $call.function.arguments = '{"path":"custom.cfg"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -like '*credential*') 'Agent must not read custom ConfigPath.'

    # Workspace boundary enforcement.
    Set-Content -LiteralPath (Join-Path $testRoot 'outside.txt') -Value 'private' -Encoding UTF8
    $call.function.arguments = '{"path":"../outside.txt"}'
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ($result.error -like '*outside*') 'Workspace escape was not rejected.'

    # Error formatting helper.
    $errText = Format-AgentError -ErrorRecord @{ Exception = @{ Message = 'HTTP 400' }; ErrorDetails = @{ Message = '{"error":{"message":"Bad model"}}' } }
    Assert-True ($errText -eq 'HTTP 400 (Bad model)') 'Format-AgentError failed.'

    # Only SHELLOSSUS_* keys are configuration. An unknown key is rejected, and a missing file stays empty.
    $badKeyFile = Join-Path $testRoot 'bad-key.env'
    Set-Content -LiteralPath $badKeyFile -Value 'OTHER_MODEL="nope"' -Encoding UTF8
    $badKeyThrew = $false
    try {
        $null = Read-AgentConfig -Path $badKeyFile
    }
    catch {
        if ($_.Exception.Message -like '*Invalid config entry*') { $badKeyThrew = $true }
    }
    Assert-True $badKeyThrew 'Unsupported config key was accepted.'

    $fakeUserHome = Join-Path $testRoot 'user-home'
    $otherCfgDir = Join-Path $fakeUserHome 'other-agent'
    New-Item -ItemType Directory -Path $otherCfgDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $otherCfgDir '.env') -Value 'SHELLOSSUS_MODEL="from-other-dir"' -Encoding UTF8
    $defaultShellossusCfg = Join-Path (Join-Path $fakeUserHome '.shellossus') '.env'
    $missingCfg = Read-AgentConfig -Path $defaultShellossusCfg
    Assert-True ($missingCfg.Count -eq 0) 'Missing .shellossus/.env must stay empty.'

    # Regression: Format-ConfigPath resolves existing ancestor and strips .\ segments when intermediate directories do not exist.
    $deepUncreated = Format-ConfigPath -Path (Join-Path $workspacePath '.\uncreated-dir\nested\custom.cfg')
    $expectedDeep = Join-Path (Join-Path (Join-Path (Get-Item -LiteralPath $workspacePath -Force).FullName 'uncreated-dir') 'nested') 'custom.cfg'
    Assert-True ($deepUncreated -eq $expectedDeep -and (-not $deepUncreated.Contains('.\')) -and (-not $deepUncreated.Contains('./'))) "Format-ConfigPath did not normalize uncreated intermediate directories: $deepUncreated"

    # Regression: Test-IsSecretFile catches NTFS Alternate Data Streams (::$DATA) and trailing dots/spaces.
    $adsEnvItem = [pscustomobject]@{ PSIsContainer = $false; Name = '.env::$DATA'; FullName = (Join-Path $workspacePath '.env::$DATA') }
    $dotEnvItem = [pscustomobject]@{ PSIsContainer = $false; Name = '.env. '; FullName = (Join-Path $workspacePath '.env. ') }
    $adsCfgItem = [pscustomobject]@{ PSIsContainer = $false; Name = 'custom.cfg::$DATA'; FullName = ($script:AgentConfigPath + '::$DATA') }
    Assert-True (Test-IsSecretFile $adsEnvItem) 'Test-IsSecretFile missed .env::$DATA.'
    Assert-True (Test-IsSecretFile $dotEnvItem) 'Test-IsSecretFile missed .env with trailing dot/space.'
    Assert-True (Test-IsSecretFile $adsCfgItem) 'Test-IsSecretFile missed custom.cfg::$DATA.'

    # Regression: Resolve-AgentPath rejects paths with colons after optional drive prefix (NTFS ADS syntax).
    $adsPathRejected = $false
    try {
        $null = Resolve-AgentPath -Root $workspacePath -RelativePath '.env::$DATA'
    }
    catch {
        $adsPathRejected = ($_.Exception.Message -like '*Invalid path syntax*')
    }
    Assert-True $adsPathRejected 'Resolve-AgentPath did not reject NTFS Alternate Data Stream path syntax.'

    # Task 5: Test-ValidAgentBaseUrl allows HTTPS and loopback HTTP (localhost, 127.0.0.1, ::1), rejects remote HTTP and malformed URLs.
    foreach ($validUrl in @(
        'https://api.openai.com/v1',
        'https://gateway.corp.internal:8443/v1',
        'http://localhost:11434/v1',
        'http://LOCALHOST:11434/v1',
        'http://127.0.0.1:8000/v1',
        'http://[::1]:11434/v1',
        'http://[0:0:0:0:0:0:0:1]:8080/v1'
    )) {
        Assert-True (Test-ValidAgentBaseUrl -Url $validUrl) "Test-ValidAgentBaseUrl rejected valid base URL: $validUrl"
    }
    foreach ($invalidUrl in @(
        '',
        'ftp://localhost:11434/v1',
        'http://example.invalid/v1',
        'http://192.168.1.10:11434/v1',
        'http://10.0.0.1:8000/v1',
        'http://user:pass@localhost:11434/v1',
        'http://localhost:11434/v1?key=secret',
        'http://localhost:11434/v1#frag',
        'http://localhost:11434/v1/chat/completions',
        'http://localhost:11434/v1/models',
        'https://example.invalid/v1/chat/completions',
        'https://example.invalid/v1/models'
    )) {
        Assert-True (-not (Test-ValidAgentBaseUrl -Url $invalidUrl)) "Test-ValidAgentBaseUrl accepted invalid base URL: $invalidUrl"
    }

    # Task 5: Update-AgentConfigOptionalKey persists SHELLOSSUS_MODEL, SHELLOSSUS_CONTEXT_WINDOW, SHELLOSSUS_COMPACT_THRESHOLD, and SHELLOSSUS_THEME,
    # and Invoke-ReplContextCommand persists context limits to $script:AgentConfigPath.
    Assert-True (-not (Update-AgentConfigOptionalKey -Path (Join-Path $testRoot 'nonexistent-dir\missing.env') -Key 'SHELLOSSUS_MODEL' -Value 'x')) 'Update-AgentConfigOptionalKey should return false when config file does not exist.'
    Assert-True (Update-AgentConfigOptionalKey -Path $configPath -Key 'SHELLOSSUS_MODEL' -Value 'persisted-model') 'Update-AgentConfigOptionalKey failed for SHELLOSSUS_MODEL.'
    Assert-True (Update-AgentConfigOptionalKey -Path $configPath -Key 'SHELLOSSUS_THEME' -Value 'nord') 'Update-AgentConfigOptionalKey failed for SHELLOSSUS_THEME.'
    $script:AgentConfigPath = $configPath
    Invoke-ReplContextCommand -State @{ messages = @() } -CtxArg '64k 48k'
    $null = Set-AgentContextLimits -WindowSpec '128k' -CompactSpec '75%'
    $reloadedAfterUpdates = Read-AgentConfig -Path $configPath
    Assert-True ($reloadedAfterUpdates.SHELLOSSUS_MODEL -eq 'persisted-model') 'SHELLOSSUS_MODEL was not persisted by Update-AgentConfigOptionalKey.'
    Assert-True ($reloadedAfterUpdates.SHELLOSSUS_THEME -eq 'nord') 'SHELLOSSUS_THEME was not persisted by Update-AgentConfigOptionalKey.'
    Assert-True ($reloadedAfterUpdates.SHELLOSSUS_CONTEXT_WINDOW -eq '64000' -and $reloadedAfterUpdates.SHELLOSSUS_COMPACT_THRESHOLD -eq '48000') 'Invoke-ReplContextCommand did not persist SHELLOSSUS_CONTEXT_WINDOW and SHELLOSSUS_COMPACT_THRESHOLD.'

    # Task 7: Test-IsLoopbackBaseUrl detects valid loopback endpoints and rejects remote or invalid endpoints.
    Assert-True (Test-IsLoopbackBaseUrl -Url 'http://localhost:11434/v1') 'Test-IsLoopbackBaseUrl rejected http://localhost:11434/v1.'
    Assert-True (Test-IsLoopbackBaseUrl -Url 'http://127.0.0.1:8000/v1') 'Test-IsLoopbackBaseUrl rejected http://127.0.0.1:8000/v1.'
    Assert-True (Test-IsLoopbackBaseUrl -Url 'http://[::1]:11434/v1') 'Test-IsLoopbackBaseUrl rejected http://[::1]:11434/v1.'
    Assert-True (-not (Test-IsLoopbackBaseUrl -Url 'https://api.openai.com/v1')) 'Test-IsLoopbackBaseUrl accepted non-loopback https://api.openai.com/v1.'
    Assert-True (-not (Test-IsLoopbackBaseUrl -Url 'http://example.invalid/v1')) 'Test-IsLoopbackBaseUrl accepted invalid remote HTTP URL.'

    # Task 22: Get-AgentUserRoot is the shared home directory. Test-IsLoopbackHost is the shared loopback host check.
    Assert-True ([bool](Get-AgentUserRoot)) 'Get-AgentUserRoot returned an empty path.'
    Assert-True (Test-IsLoopbackHost -HostName 'localhost') 'Test-IsLoopbackHost rejected localhost.'
    Assert-True (Test-IsLoopbackHost -HostName '127.0.0.1') 'Test-IsLoopbackHost rejected 127.0.0.1.'
    Assert-True (Test-IsLoopbackHost -HostName '::1') 'Test-IsLoopbackHost rejected ::1.'
    Assert-True (Test-IsLoopbackHost -HostName '[::1]') 'Test-IsLoopbackHost rejected bracketed ::1.'
    Assert-True (Test-IsLoopbackHost -HostName '0:0:0:0:0:0:0:1') 'Test-IsLoopbackHost rejected expanded IPv6 loopback.'
    Assert-True (Test-IsLoopbackHost -HostName 'LOCALHOST') 'Test-IsLoopbackHost rejected LOCALHOST.'
    Assert-True (-not (Test-IsLoopbackHost -HostName 'example.com')) 'Test-IsLoopbackHost accepted example.com.'
    Assert-True (-not (Test-IsLoopbackHost -HostName '0.0.0.0')) 'Test-IsLoopbackHost accepted 0.0.0.0.'
    Assert-True (-not (Test-IsLoopbackHost -HostName 'foo.localhost')) 'Test-IsLoopbackHost accepted foo.localhost.'
    Assert-True (-not (Test-IsLoopbackHost -HostName 'printer.local')) 'Test-IsLoopbackHost accepted printer.local.'
    Assert-True (-not (Test-IsLoopbackHost -HostName 'metadata.google.internal')) 'Test-IsLoopbackHost accepted metadata.google.internal.'
    Assert-True (Test-ValidAgentBaseUrl -Url 'http://127.0.0.1:11434/v1') 'Test-ValidAgentBaseUrl rejected http://127.0.0.1:11434/v1.'
    Assert-True (-not (Test-ValidAgentBaseUrl -Url 'http://example.com')) 'Test-ValidAgentBaseUrl accepted http://example.com.'

    # Set-AgentUtf8Content writes BOM-less UTF-8 for empty, pure ASCII, and non-ASCII Unicode strings.
    $utf8Path = Join-Path $testRoot 'utf8-nobom.txt'
    Set-AgentUtf8Content -LiteralPath $utf8Path -Value ''
    $emptyRead = Get-Content -LiteralPath $utf8Path -Raw -Encoding UTF8
    if ($null -eq $emptyRead) { $emptyRead = '' }
    Assert-True ($emptyRead -ceq '' -and (Get-Item -LiteralPath $utf8Path -Force).Length -eq 0) 'Set-AgentUtf8Content empty string wrote unexpected bytes.'

    Set-AgentUtf8Content -LiteralPath $utf8Path -Value 'ascii-no-bom'
    Assert-True ((Get-Content -LiteralPath $utf8Path -Raw -Encoding UTF8) -ceq 'ascii-no-bom') 'Set-AgentUtf8Content ASCII roundtrip failed.'
    Assert-True ((Get-Item -LiteralPath $utf8Path -Force).Length -eq 12) 'Set-AgentUtf8Content ASCII string included a BOM or wrong byte length.'

    $unicodeVal = ([string][char]0x0442) + ([string][char]0x0435) + ([string][char]0x0441) + ([string][char]0x0442)
    Set-AgentUtf8Content -LiteralPath $utf8Path -Value $unicodeVal
    Assert-True ((Get-Content -LiteralPath $utf8Path -Raw -Encoding UTF8) -ceq $unicodeVal) 'Set-AgentUtf8Content Unicode roundtrip failed.'
    Assert-True ((Get-Item -LiteralPath $utf8Path -Force).Length -eq 8) 'Set-AgentUtf8Content Unicode string included a BOM or wrong byte length.'

    # Regression: Test-AgentPathWithinRoot and Get-WorkspaceRelativePath normalize trailing slashes, match Windows drive paths case-insensitively, and keep POSIX paths case-sensitive.
    Assert-True ((Get-WorkspaceRelativePath -Root $workspacePath -FullPath $workspacePath) -eq '.') 'Get-WorkspaceRelativePath did not return . for exact workspace root.'
    Assert-True ((Get-WorkspaceRelativePath -Root ($workspacePath + '/') -FullPath $workspacePath) -eq '.') 'Get-WorkspaceRelativePath did not return . when Root has trailing slash.'
    Assert-True ((Get-WorkspaceRelativePath -Root $workspacePath -FullPath ($workspacePath + '/')) -eq '.') 'Get-WorkspaceRelativePath did not return . when FullPath has trailing slash.'
    Assert-True ((Get-WorkspaceRelativePath -Root $workspacePath -FullPath (Join-Path (Join-Path $workspacePath 'sub') 'file.txt')) -eq 'sub/file.txt') 'Get-WorkspaceRelativePath did not return forward-slash relative path for nested file.'
    $savedOs = $env:OS
    try {
        $env:OS = 'Windows_NT'
        Assert-True (Test-AgentPathWithinRoot -RootPath 'C:\Workspace\Project\' -TargetPath 'C:\Workspace\Project') 'Test-AgentPathWithinRoot failed for trailing-slash root path on Windows.'
        Assert-True (Test-AgentPathWithinRoot -RootPath 'C:\Workspace\Project' -TargetPath 'c:\workspace\project') 'Test-AgentPathWithinRoot failed for case-variant exact root on Windows.'
        Assert-True (Test-AgentPathWithinRoot -RootPath 'C:\Workspace\Project\' -TargetPath 'C:\Workspace\Project\sub\file.txt') 'Test-AgentPathWithinRoot failed for child path on Windows.'
        Assert-True (Test-AgentPathWithinRoot -RootPath 'C:\Workspace\Project' -TargetPath 'c:\workspace\project\sub\file.txt') 'Test-AgentPathWithinRoot failed for case-variant child path on Windows.'
        Assert-True (Test-AgentPathWithinRoot -RootPath 'C:\Workspace\Project' -TargetPath 'c:\workspace\project/sub/file.txt') 'Test-AgentPathWithinRoot failed for case-variant forward-slash child path on Windows.'
        Assert-True (-not (Test-AgentPathWithinRoot -RootPath 'C:\Workspace\Project' -TargetPath 'c:\workspace\project_other\file.txt')) 'Test-AgentPathWithinRoot accepted sibling prefix path on Windows.'
        Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/tmp/workspace' -TargetPath '/tmp/WORKSPACE/file.txt')) 'Test-AgentPathWithinRoot accepted case-variant POSIX path on Windows.'
        Assert-True ((Get-WorkspaceRelativePath -Root 'C:\repo\work' -FullPath 'c:\Repo\Work') -eq '.') 'Get-WorkspaceRelativePath failed for case-variant Windows drive root.'
        Assert-True ((Get-WorkspaceRelativePath -Root 'C:\repo\work\' -FullPath 'c:\Repo\Work\') -eq '.') 'Get-WorkspaceRelativePath failed for trailing-slash case-variant Windows drive root.'
        Assert-True ((Get-WorkspaceRelativePath -Root 'C:\repo\work' -FullPath 'c:\Repo\Work\src\a.ps1') -eq 'src/a.ps1') 'Get-WorkspaceRelativePath failed for case-variant Windows drive nested path.'
        Assert-True ((Get-WorkspaceRelativePath -Root '/tmp/workspace' -FullPath '/tmp/WORKSPACE/file.txt') -eq '/tmp/WORKSPACE/file.txt') 'Get-WorkspaceRelativePath stripped case-variant POSIX prefix on Windows.'

        $env:OS = ''
        Assert-True (Test-AgentPathWithinRoot -RootPath '/workspace/Project/' -TargetPath '/workspace/Project') 'Test-AgentPathWithinRoot failed for trailing-slash root path on Unix.'
        Assert-True (Test-AgentPathWithinRoot -RootPath '/workspace/Project' -TargetPath '/workspace/Project/sub/file.txt') 'Test-AgentPathWithinRoot failed for exact-case child path on Unix.'
        Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/workspace/Project' -TargetPath '/workspace/project/sub/file.txt')) 'Test-AgentPathWithinRoot accepted wrong-case path on Unix.'
        Assert-True ((Get-WorkspaceRelativePath -Root '/workspace/Project/' -FullPath '/workspace/Project') -eq '.') 'Get-WorkspaceRelativePath failed for trailing-slash root on Unix.'
        Assert-True ((Get-WorkspaceRelativePath -Root '/workspace/Project' -FullPath '/workspace/Project/sub/file.txt') -eq 'sub/file.txt') 'Get-WorkspaceRelativePath failed for exact-case child path on Unix.'
        Assert-True ((Get-WorkspaceRelativePath -Root '/workspace/Project' -FullPath '/workspace/project/sub/file.txt') -eq '/workspace/project/sub/file.txt') 'Get-WorkspaceRelativePath stripped wrong-case prefix on Unix.'
    }
    finally {
        $env:OS = $savedOs
    }

    # Resolve-AgentWriteTarget is the single write-target check for new files.
    $missingTarget = Resolve-AgentWriteTarget -Root $workspacePath -RelativePath 'sub/new.txt'
    $missingAncestor = Resolve-ExistingPathAncestor -Root $workspacePath -RelativePath 'sub'
    $missingNames = @($missingAncestor.missing_names)
    $dirsToCreate = @($missingTarget.dirs_to_create)
    $lastDir = [string]$dirsToCreate[$dirsToCreate.Count - 1]
    Assert-True ($missingTarget.exists -eq $false) 'Resolve-AgentWriteTarget reported an existing file for sub/new.txt.'
    Assert-True ($missingTarget.leaf -eq 'new.txt') 'Resolve-AgentWriteTarget leaf was not new.txt.'
    Assert-True ($missingNames.Count -eq 1 -and [string]$missingNames[0] -eq 'sub') 'Resolve-ExistingPathAncestor missing_names was not sub.'
    Assert-True ($dirsToCreate.Count -eq $missingNames.Count -and (Split-Path -Path $lastDir -Leaf) -eq [string]$missingNames[0]) 'dirs_to_create was not the path equivalent of missing_names.'
    Assert-True (Test-AgentPathWithinRoot -RootPath $workspacePath -TargetPath $lastDir) 'dirs_to_create did not end in a path under the workspace.'
    Assert-True ((Split-Path -Path ([string]$missingTarget.full_path) -Leaf) -eq 'new.txt') 'full_path did not end with new.txt.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'sub'))) 'Resolve-AgentWriteTarget created the missing parent directory.'

    $beforeBadSegments = @((Get-ChildItem -LiteralPath $workspacePath -Force | ForEach-Object { $_.Name }) | Sort-Object)
    foreach ($badSegment in @(
        @{ Path = 'CON'; Message = 'Reserved file name.' },
        @{ Path = 'foo.'; Message = 'Invalid file name.' },
        @{ Path = 'a:b'; Message = 'Invalid file name.' }
    )) {
        $segmentThrew = $false
        $segmentMessage = ''
        try {
            Test-ValidPathSegment -Segment ([string]$badSegment.Path) -Kind File
        }
        catch {
            $segmentThrew = $true
            $segmentMessage = [string]$_.Exception.Message
        }
        Assert-True ($segmentThrew -and $segmentMessage -eq [string]$badSegment.Message) "Test-ValidPathSegment file segment $($badSegment.Path) returned: $segmentMessage"
        $writeThrew = $false
        $writeMessage = ''
        try {
            $null = Resolve-AgentWriteTarget -Root $workspacePath -RelativePath ([string]$badSegment.Path)
        }
        catch {
            $writeThrew = $true
            $writeMessage = [string]$_.Exception.Message
        }
        Assert-True $writeThrew "Resolve-AgentWriteTarget did not throw for segment $($badSegment.Path)."
        if ([string]$badSegment.Path -eq 'a:b') {
            Assert-True ($writeMessage.Length -gt 0) 'Resolve-AgentWriteTarget segment a:b threw an empty error.'
        }
        else {
            Assert-True ($writeMessage -eq [string]$badSegment.Message) "Resolve-AgentWriteTarget segment $($badSegment.Path) returned: $writeMessage"
        }
    }
    $dirConThrew = $false
    $dirConMessage = ''
    try { Test-ValidPathSegment -Segment 'CON' -Kind Directory }
    catch { $dirConThrew = $true; $dirConMessage = [string]$_.Exception.Message }
    Assert-True ($dirConThrew -and $dirConMessage -eq 'Invalid directory name.') "Directory segment CON returned: $dirConMessage"
    $dirDotThrew = $false
    $dirDotMessage = ''
    try { Test-ValidPathSegment -Segment 'foo.' -Kind Directory }
    catch { $dirDotThrew = $true; $dirDotMessage = [string]$_.Exception.Message }
    Assert-True ($dirDotThrew -and $dirDotMessage -eq 'Invalid directory name.') "Directory segment foo. returned: $dirDotMessage"
    $dirColonThrew = $false
    $dirColonMessage = ''
    try { Test-ValidPathSegment -Segment 'a:b' -Kind Directory }
    catch { $dirColonThrew = $true; $dirColonMessage = [string]$_.Exception.Message }
    Assert-True ($dirColonThrew -and $dirColonMessage -eq 'Invalid directory name.') "Directory segment a:b returned: $dirColonMessage"
    $afterBadSegments = @((Get-ChildItem -LiteralPath $workspacePath -Force | ForEach-Object { $_.Name }) | Sort-Object)
    Assert-True (($beforeBadSegments -join '|') -ceq ($afterBadSegments -join '|')) 'A rejected path segment created a file.'

    $savedSecretConfig = $script:AgentConfigPath
    try {
        $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $workspacePath 'secrets.txt')
        $secretThrew = $false
        $secretMessage = ''
        try {
            $null = Resolve-AgentWriteTarget -Root $workspacePath -RelativePath 'secrets.txt'
        }
        catch {
            $secretThrew = $true
            $secretMessage = [string]$_.Exception.Message
        }
        Assert-True ($secretThrew -and $secretMessage -eq 'Agent tools cannot write credential configuration files.') "Custom config leaf secrets.txt returned: $secretMessage"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath 'secrets.txt'))) 'Custom config rejection created secrets.txt.'
    }
    finally {
        $script:AgentConfigPath = $savedSecretConfig
    }

    foreach ($secretName in @('.env', '.env.local')) {
        $envThrew = $false
        $envMessage = ''
        try {
            $null = Resolve-AgentWriteTarget -Root $workspacePath -RelativePath $secretName
        }
        catch {
            $envThrew = $true
            $envMessage = [string]$_.Exception.Message
        }
        Assert-True ($envThrew -and $envMessage -eq 'Agent tools cannot write credential configuration files.') "Secret name $secretName returned: $envMessage"
    }
    $exampleTarget = Resolve-AgentWriteTarget -Root $workspacePath -RelativePath '.env.example'
    Assert-True ($exampleTarget.leaf -eq '.env.example' -and $exampleTarget.exists -eq $false) '.env.example was rejected or treated as an existing file.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspacePath '.env.example'))) '.env.example was created by the resolver.'

    $junctionOutside = Join-Path $testRoot 'junction-outside'
    $junctionLink = Join-Path $workspacePath 'linked-parent'
    New-Item -ItemType Directory -Path $junctionOutside -Force | Out-Null
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionLink -Target $junctionOutside -ErrorAction Stop | Out-Null
        $junctionItem = Get-Item -LiteralPath $junctionLink -Force -ErrorAction Stop
        if ($junctionItem.LinkType -eq 'Junction' -or (($junctionItem.Attributes -band 1024) -ne 0 -and $junctionItem.LinkType -eq 'Junction')) {
            $junctionCreated = $true
        }
    }
    catch {
        $junctionCreated = $false
    }
    if ($junctionCreated) {
        try {
            Set-Content -LiteralPath (Join-Path $junctionOutside 'inside.txt') -Value 'inside' -Encoding UTF8 -NoNewline
            $ancestorThrew = $false
            $ancestorMessage = ''
            try {
                $null = Resolve-AgentPath -Root $workspacePath -RelativePath 'linked-parent/inside.txt'
            }
            catch {
                $ancestorThrew = $true
                $ancestorMessage = [string]$_.Exception.Message
            }
            Assert-True ($ancestorThrew -and $ancestorMessage -eq 'Reparse points are not allowed.') "Resolve-AgentPath reparse ancestor returned: $ancestorMessage"
            Assert-True ((Get-Content -LiteralPath (Join-Path $junctionOutside 'inside.txt') -Raw -Encoding UTF8) -ceq 'inside') 'Resolve-AgentPath changed a file under a reparse ancestor.'
            $junctionThrew = $false
            $junctionMessage = ''
            try {
                $null = Resolve-AgentWriteTarget -Root $workspacePath -RelativePath 'linked-parent/new.txt'
            }
            catch {
                $junctionThrew = $true
                $junctionMessage = [string]$_.Exception.Message
            }
            Assert-True ($junctionThrew -and $junctionMessage -eq 'Reparse points are not allowed.') "Junction ancestor returned: $junctionMessage"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionOutside 'new.txt'))) 'Junction ancestor rejection created a file in the link target.'
        }
        finally {
            if (Test-Path -LiteralPath $junctionLink) {
                (Get-Item -LiteralPath $junctionLink -Force).Delete()
            }
        }
    }
    elseif ($env:OS -eq 'Windows_NT') {
        throw 'Junction creation failed on Windows. This assertion must not be skipped in the Windows CI job.'
    }

    # A custom config filename that write_file rejects must not be offered as instructions_required.
    $savedPreviewPerm = $script:AgentPermission
    $savedPreviewMode = $script:OutputMode
    $savedPreviewCfg = $script:AgentConfigPath
    $previewDir = Join-Path $workspacePath 'preview-scope'
    New-Item -ItemType Directory -Path $previewDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $previewDir 'AGENTS.md') -Value 'Preview scope rule.' -Encoding UTF8
    try {
        $script:AgentPermission = 'AutoEdit'
        $script:OutputMode = 'json'
        $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $previewDir 'secrets.txt')
        $script:previewReplied = $false
        function Invoke-WebRequest {
            param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing, $OutFile)
            $reply = @{ choices = @(@{ finish_reason = 'stop'; message = @{ content = 'done' } }) }
            if (-not $script:previewReplied) {
                $script:previewReplied = $true
                $reply = @{
                    choices = @(@{
                        finish_reason = 'tool_calls'
                        message = @{
                            content = ''
                            tool_calls = @(@{
                                id = 'cfg-write'
                                type = 'function'
                                function = @{ name = 'write_file'; arguments = '{"path":"preview-scope/secrets.txt","content":"nope"}' }
                            })
                        }
                    })
                }
            }
            $json = $reply | ConvertTo-Json -Depth 12 -Compress
            Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8 -NoNewline
        }
        $previewState = @{ messages = @(@{ role = 'system'; content = 'sys' }, @{ role = 'user'; content = 'Write the config.' }) }
        Invoke-AgentTurn -State $previewState -Endpoint 'https://example.invalid/v1/chat/completions' -ModelId 'test-model' -ApiKey 'fake' -Root $workspacePath -Steps 3
        $toolMsgs = @($previewState.messages | Where-Object { $_.role -eq 'tool' })
        Assert-True ($toolMsgs.Count -eq 1) 'Custom config write did not return exactly one tool result.'
        $toolRes = $toolMsgs[0].content | ConvertFrom-Json
        Assert-True ($toolRes.error -eq 'Agent tools cannot write credential configuration files.') "Custom config write preview returned: $($toolMsgs[0].content)"
        Assert-True ([string]$toolMsgs[0].content -notlike '*instructions_required*') 'Custom config path received instructions_required.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $previewDir 'secrets.txt'))) 'Custom config preview created secrets.txt.'
    }
    finally {
        Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
        $script:AgentPermission = $savedPreviewPerm
        $script:OutputMode = $savedPreviewMode
        $script:AgentConfigPath = $savedPreviewCfg
        $script:previewReplied = $false
    }
}
finally {
    Remove-TestEnvironment -Env $envData
}
