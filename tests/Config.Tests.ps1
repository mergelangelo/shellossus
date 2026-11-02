$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$envData = New-TestEnvironment
$testRoot = $envData.TestRoot
$workspacePath = $envData.Workspace

try {
    # Config is parsed as data; embedded PowerShell expressions stay literal.
    $configPath = Join-Path $testRoot '.env'
    Save-AgentConfig -Path $configPath -Config @{
        H_AGENT_BASE_URL = 'https://example.invalid/v1'
        H_AGENT_MODEL = 'test-model'
        H_AGENT_API_KEY = 'fake=key#$(throw injected)'
        H_AGENT_WORKSPACE = 'C:\folder with spaces'
    }
    $loadedConfig = Read-AgentConfig -Path $configPath
    Assert-True ($loadedConfig.H_AGENT_API_KEY -eq 'fake=key#$(throw injected)') 'Config value was corrupted or evaluated.'
    Assert-True ($loadedConfig.H_AGENT_WORKSPACE -eq 'C:\folder with spaces') 'Config path changed.'
    $absentConfig = Read-AgentConfig -Path (Join-Path $testRoot 'missing.env')
    Assert-True ($absentConfig.Count -eq 0) 'Missing config should produce empty settings.'

    # Credential and secret file protection (.env and custom ConfigPath).
    Set-Content -LiteralPath (Join-Path $workspacePath '.env') -Value 'SECRET=hidden' -Encoding UTF8
    $call = @{ id = 'cfg-env'; function = @{ name = 'read_file'; arguments = '{"path":".env"}' } }
    $result = Invoke-AgentTool -Root $workspacePath -Call $call | ConvertFrom-Json
    Assert-True ([bool]$result.error) 'Agent must not read .env.'

    $customCfg = Join-Path $workspacePath 'custom.cfg'
    Set-Content -LiteralPath $customCfg -Value 'H_AGENT_API_KEY="secret"' -Encoding UTF8
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
}
finally {
    Remove-TestEnvironment -Env $envData
}
