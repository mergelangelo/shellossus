param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$modules = @(
    'Config.ps1',
    'Theme.ps1',
    'Tools.ps1',
    'Context.ps1',
    'Cli.ps1'
)

$header = @'
param(
    [string]$BaseUrl = $env:SHELLOSSUS_BASE_URL,
    [string]$Model = $env:SHELLOSSUS_MODEL,
    [string]$Workspace = '.',
    [string]$ConfigPath = "$(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME })\.shellossus\.env",
    [int]$MaxSteps = 50,
    [int]$MaxRepeatCalls = 3,
    [string]$Permission = 'Ask',
    [string]$ReasoningEffort = '',
    [string]$Prompt = '',
    [string]$Mode = 'text',
    [string]$Session = '',
    [string]$SessionDir = '',
    [switch]$NoSession,
    [string]$SessionName = '',
    [string]$Fork = '',
    [string]$Export = '',
    [string]$Tools = '',
    [string]$ExcludeTools = '',
    [switch]$NoTools,
    [switch]$NoSkills,
    [switch]$NoPromptTemplates,
    [switch]$NoContextFiles,
    [switch]$HideReasoning,
    [switch]$Diagnostics,
    [switch]$Continue,
    [switch]$Setup,
    [switch]$LibraryOnly
)

# Windows PowerShell 5.1 compatible. No downloaded executables or modules.
# Auto-generated from src/*.ps1 by build.ps1. Edit files in src/ and run .\build.ps1.
'@

$parts = @($header.Replace("`r`n", "`n").TrimEnd())
foreach ($mod in $modules) {
    $modPath = Join-Path (Join-Path $PSScriptRoot 'src') $mod
    if (-not (Test-Path -LiteralPath $modPath)) {
        throw "Missing source module: $modPath"
    }
    $raw = Get-Content -LiteralPath $modPath -Raw -Encoding UTF8 -ErrorAction Stop
    $normalized = $raw.Replace("`r`n", "`n").Trim()
    $parts += "# --- src/$mod ---`n" + $normalized
}

$assembled = ($parts -join "`n`n") + "`n"
$targetPath = Join-Path $PSScriptRoot 'shellossus.ps1'

if ($Check) {
    if (-not (Test-Path -LiteralPath $targetPath)) {
        throw "Target file missing: $targetPath"
    }
    $existing = (Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 -ErrorAction Stop).Replace("`r`n", "`n")
    if ($existing -cne $assembled) {
        throw 'shellossus.ps1 is out of sync with src/*.ps1. Run .\build.ps1 to regenerate.'
    }
    Write-Host 'build.ps1 -Check passed: shellossus.ps1 matches src/*.ps1.'
    return
}

Set-Content -LiteralPath $targetPath -Value $assembled -Encoding Ascii -NoNewline -ErrorAction Stop
Write-Host "Built $targetPath from src/*.ps1."
