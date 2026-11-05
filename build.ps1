param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

function Assert-AsciiContent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    if ($Content -match '[^\x00-\x7F]') {
        $lines = $Content.Replace("`r`n", "`n") -split "`n"
        for ($lineIdx = 0; $lineIdx -lt $lines.Count; $lineIdx++) {
            $lineText = [string]$lines[$lineIdx]
            for ($colIdx = 0; $colIdx -lt $lineText.Length; $colIdx++) {
                $code = [int][char]$lineText[$colIdx]
                if ($code -gt 127) {
                    $hex = $code.ToString('X4')
                    throw "Non-ASCII character U+$hex found in $Path at line $($lineIdx + 1), column $($colIdx + 1). All .ps1 files must be strictly 7-bit ASCII."
                }
            }
        }
        throw "Non-ASCII character found in $Path. All .ps1 files must be strictly 7-bit ASCII."
    }
}

function Assert-AsciiFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $rawText = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $rawText) { $rawText = '' }
    Assert-AsciiContent -Path $Path -Content ([string]$rawText)
}

$modules = @(
    'Config.ps1',
    'Theme.ps1',
    'ui/Cards.ps1',
    'ui/Input.ps1',
    'ui/Markdown.ps1',
    'tools/Common.ps1',
    'tools/Schemas.ps1',
    'tools/Normalizers.ps1',
    'tools/Validation.ps1',
    'tools/Ignore.ps1',
    'tools/Files.ps1',
    'tools/Search.ps1',
    'tools/Shell.ps1',
    'tools/Undo.ps1',
    'tools/Web.ps1',
    'tools/Todo.ps1',
    'tools/AskUser.ps1',
    'tools/Memory.ps1',
    'tools/Agents.ps1',
    'tools/Dispatch.ps1',
    'context/Prompt.ps1',
    'context/Catalog.ps1',
    'context/Templates.ps1',
    'context/SessionTree.ps1',
    'context/Session.ps1',
    'context/Compaction.ps1',
    'Doctor.ps1',
    'cli/Install.ps1',
    'cli/Http.ps1',
    'cli/Turn.ps1',
    'cli/Repl.ps1',
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
    [string]$ContextWindow = $env:SHELLOSSUS_CONTEXT_WINDOW,
    [string]$CompactThreshold = $env:SHELLOSSUS_COMPACT_THRESHOLD,
    [string]$Permission = 'Ask',
    [string]$Theme = $env:SHELLOSSUS_THEME,
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
    [switch]$Doctor,
    [switch]$Mascot,
    [switch]$Continue,
    [switch]$Setup,
    [switch]$Install,
    [string]$ProfilePath = $PROFILE,
    [string]$Shortcut = '',
    [switch]$NoShortcut,
    [switch]$LibraryOnly
)

# Windows PowerShell 5.1 compatible. No downloaded executables or modules.
# Auto-generated from src/*.ps1 by build.ps1. Edit files in src/ and run .\build.ps1.
'@

Assert-AsciiFile -Path $PSCommandPath

$parts = @($header.Replace("`r`n", "`n").TrimEnd())
foreach ($mod in $modules) {
    $normRel = $mod.Replace('\', '/')
    $subParts = $normRel -split '/'
    $modPath = Join-Path $PSScriptRoot 'src'
    foreach ($sp in $subParts) {
        $modPath = Join-Path $modPath $sp
    }
    if (-not (Test-Path -LiteralPath $modPath)) {
        throw "Missing source module: $modPath"
    }
    $raw = Get-Content -LiteralPath $modPath -Raw -Encoding UTF8 -ErrorAction Stop
    Assert-AsciiContent -Path $modPath -Content ([string]$raw)
    $normalized = $raw.Replace("`r`n", "`n").Trim()
    $parts += "# --- src/$normRel ---`n" + $normalized
}

$extraDirs = @((Join-Path $PSScriptRoot 'src'), (Join-Path $PSScriptRoot 'tests'))
foreach ($scanDir in $extraDirs) {
    if (Test-Path -LiteralPath $scanDir) {
        foreach ($psFile in @(Get-ChildItem -LiteralPath $scanDir -Filter '*.ps1' -Recurse -File)) {
            Assert-AsciiFile -Path $psFile.FullName
        }
    }
}

$assembled = ($parts -join "`n`n") + "`n"
$targetPath = Join-Path $PSScriptRoot 'shellossus.ps1'
Assert-AsciiContent -Path $targetPath -Content $assembled

if ($Check) {
    if (-not (Test-Path -LiteralPath $targetPath)) {
        throw "Target file missing: $targetPath"
    }
    $existing = (Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 -ErrorAction Stop).Replace("`r`n", "`n")
    Assert-AsciiContent -Path $targetPath -Content $existing
    if ($existing -cne $assembled) {
        throw 'shellossus.ps1 is out of sync with src/*.ps1. Run .\build.ps1 to regenerate.'
    }
    Write-Host 'build.ps1 -Check passed: shellossus.ps1 matches src/*.ps1 (strict 7-bit ASCII verified).'
    return
}

Set-Content -LiteralPath $targetPath -Value $assembled -Encoding Ascii -NoNewline -ErrorAction Stop
Write-Host "Built $targetPath from src/*.ps1."
