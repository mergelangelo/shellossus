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

    # Backward compatibility with legacy H_AGENT_* keys and .h-agent/.env fallback.
    $legacyFile = Join-Path $testRoot 'legacy.env'
    Set-Content -LiteralPath $legacyFile -Value @(
        'H_AGENT_BASE_URL="https://legacy.invalid/v1"',
        'H_AGENT_MODEL="legacy-model"',
        'H_AGENT_API_KEY="legacy-secret"',
        'H_AGENT_WORKSPACE="C:\legacy workspace"'
    ) -Encoding UTF8
    $parsedLegacy = Read-AgentConfig -Path $legacyFile
    Assert-True ($parsedLegacy.SHELLOSSUS_BASE_URL -eq 'https://legacy.invalid/v1') 'Legacy H_AGENT_BASE_URL was not mapped.'
    Assert-True ($parsedLegacy.SHELLOSSUS_MODEL -eq 'legacy-model') 'Legacy H_AGENT_MODEL was not mapped.'
    Assert-True ($parsedLegacy.SHELLOSSUS_API_KEY -eq 'legacy-secret') 'Legacy H_AGENT_API_KEY was not mapped.'
    Assert-True ($parsedLegacy.SHELLOSSUS_WORKSPACE -eq 'C:\legacy workspace') 'Legacy H_AGENT_WORKSPACE was not mapped.'

    $mixedFile = Join-Path $testRoot 'mixed.env'
    Set-Content -LiteralPath $mixedFile -Value @(
        'H_AGENT_MODEL="old-model"',
        'SHELLOSSUS_MODEL="new-model"',
        'H_AGENT_MODEL="old-model-later"'
    ) -Encoding UTF8
    $parsedMixed = Read-AgentConfig -Path $mixedFile
    Assert-True ($parsedMixed.SHELLOSSUS_MODEL -eq 'new-model') 'SHELLOSSUS_* key must take precedence over H_AGENT_*.'

    $fakeUserHome = Join-Path $testRoot 'user-home'
    $dotHAgentDir = Join-Path $fakeUserHome '.h-agent'
    New-Item -ItemType Directory -Path $dotHAgentDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dotHAgentDir '.env') -Value 'H_AGENT_MODEL="from-dot-h-agent"' -Encoding UTF8
    $defaultShellossusCfg = Join-Path (Join-Path $fakeUserHome '.shellossus') '.env'
    $fallbackCfg = Read-AgentConfig -Path $defaultShellossusCfg
    Assert-True ($fallbackCfg.SHELLOSSUS_MODEL -eq 'from-dot-h-agent') 'Fallback from .shellossus/.env to existing .h-agent/.env failed.'

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

    # Regression: Test-AgentPathWithinRoot normalizes trailing slashes, matches Windows drive paths case-insensitively, and keeps POSIX paths case-sensitive.
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

        $env:OS = ''
        Assert-True (Test-AgentPathWithinRoot -RootPath '/workspace/Project/' -TargetPath '/workspace/Project') 'Test-AgentPathWithinRoot failed for trailing-slash root path on Unix.'
        Assert-True (Test-AgentPathWithinRoot -RootPath '/workspace/Project' -TargetPath '/workspace/Project/sub/file.txt') 'Test-AgentPathWithinRoot failed for exact-case child path on Unix.'
        Assert-True (-not (Test-AgentPathWithinRoot -RootPath '/workspace/Project' -TargetPath '/workspace/project/sub/file.txt')) 'Test-AgentPathWithinRoot accepted wrong-case path on Unix.'
    }
    finally {
        $env:OS = $savedOs
    }
}
finally {
    Remove-TestEnvironment -Env $envData
}
