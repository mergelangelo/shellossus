$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\shellossus.ps1" -LibraryOnly

$script:CurrentTurnWrites = @()
$script:AgentPermission = 'Ask'
$script:OutputMode = 'text'
$script:ShowReasoning = 'compact'
$script:ReasoningEffort = ''
$script:NoTools = $false
$script:EnabledTools = @()
$script:ExcludedTools = @()
$script:NoSkills = $false
$script:NoPromptTemplates = $false
$script:NoContextFiles = $false
$script:Diagnostics = $false
$script:MaxRepeatToolCalls = 3
$script:ActiveWorkspace = ''
$script:RegisteredSkillPaths = @{}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestEnvironment {
    $root = Join-Path $env:TEMP ('shellossus-' + [guid]::NewGuid().ToString('N'))
    $ws = Join-Path $root 'workspace'
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $root '.env')
    $script:ActiveWorkspace = $ws
    return @{
        TestRoot = $root
        Workspace = $ws
    }
}

function Remove-TestEnvironment {
    param($Env)
    if ($Env -and $Env.TestRoot -and (Test-Path -LiteralPath $Env.TestRoot)) {
        Remove-Item -LiteralPath $Env.TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
