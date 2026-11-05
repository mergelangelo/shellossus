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
}
finally {
    Remove-TestEnvironment -Env $envData
}
