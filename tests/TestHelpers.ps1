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
$script:RegisteredSkills = @{}
$script:ActiveSessionTodos = @()

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestEnvironment {
    $baseTemp = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
    # macOS /tmp and /var are symlinks. The ancestor walk rejects them, so fixtures use the physical path.
    if ($env:OS -ne 'Windows_NT' -and (Test-PathHasReparsePoint -Path $baseTemp)) {
        $candidate = '/private' + $baseTemp
        if ((Test-Path -LiteralPath $candidate) -and -not (Test-PathHasReparsePoint -Path $candidate)) {
            $baseTemp = $candidate
        }
    }
    $root = Join-Path $baseTemp ('shellossus-' + [guid]::NewGuid().ToString('N'))
    $ws = Join-Path $root 'workspace'
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    $rootFull = (Get-Item -LiteralPath $root -Force).FullName
    $wsFull = (Get-Item -LiteralPath $ws -Force).FullName
    $script:AgentConfigPath = Format-ConfigPath -Path (Join-Path $rootFull '.env')
    $script:ActiveWorkspace = $wsFull
    return @{
        TestRoot = $rootFull
        Workspace = $wsFull
    }
}

function Remove-TestEnvironment {
    param($Env)
    if ($Env -and $Env.TestRoot -and (Test-Path -LiteralPath $Env.TestRoot)) {
        Remove-Item -LiteralPath $Env.TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
