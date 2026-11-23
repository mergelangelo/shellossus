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
    if ($Check -and ([string]$rawText).Contains("`r")) {
        throw "CRLF line endings found in $Path. All .ps1 files must use LF line endings."
    }
}

$modules = @(
    'Config.ps1',
    'Theme.ps1',
    'ui/Ansi.ps1',
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
    'tools/WebSearch.ps1',
    'tools/Todo.ps1',
    'tools/AskUser.ps1',
    'tools/Memory.ps1',
    'tools/AgentWorkers.ps1',
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
    'cli/Commands.ps1',
    'Cli.ps1'
)

$header = @'
<#
.SYNOPSIS
Zero-dependency pure PowerShell coding agent for Windows PowerShell 5.1, PowerShell 7+, and ConstrainedLanguage.

.DESCRIPTION
shellossus is a standalone, single-file coding agent written entirely in native PowerShell without external runtimes, third-party binaries, or PowerShell Gallery modules. It connects to any OpenAI-compatible /v1/chat/completions API (cloud providers, corporate gateways, or local Ollama/vLLM servers) and provides 15 built-in tools, transactional staged edits with conflict-aware /undo, subagents, DAG session branching, structured /compact, layered Markdown customization, TrueColor TUI output, and headless JSONL automation.

Run .\shellossus.ps1 -Help (or -h / --help) for a compact categorized CLI reference, or Get-Help .\shellossus.ps1 -Detailed / -Examples for full parameter documentation.

.PARAMETER BaseUrl
OpenAI-compatible API base URL (normally ending in /v1). Must use https://, or http://localhost / 127.0.0.1 / [::1] for local servers. Defaults to $env:SHELLOSSUS_BASE_URL or the saved config file.

.PARAMETER Model
Provider model or deployment ID. Defaults to $env:SHELLOSSUS_MODEL or the saved config file.

.PARAMETER Workspace
Active workspace root directory for file tools and command execution. Defaults to the current directory ('.').

.PARAMETER ConfigPath
Path to the plain-data SHELLOSSUS_* key-value configuration file. Defaults to ~/.shellossus/.env (%USERPROFILE%\.shellossus\.env on Windows).

.PARAMETER MaxSteps
Maximum model-tool loop iterations per turn (1..500, default 50).

.PARAMETER MaxRepeatCalls
Loop-guard threshold (1..50, default 3) for identical tool calls without an intervening state change.

.PARAMETER ContextWindow
Model context window budget in tokens (accepts integers or 'k' suffix, e.g. 128k; default 128k).

.PARAMETER CompactThreshold
Auto-compaction threshold in tokens or percentage (e.g. 80k or 75%; default 96k).

.PARAMETER RequestTimeoutSec
Per-request model HTTP timeout in seconds (10..1800, default 180).

.PARAMETER Stream
Stream model responses over SSE (stream = true) with live incremental TUI rendering and fail-closed [DONE] / finish_reason verification. Pass -Stream:$false to override env/config.

.PARAMETER AuthHeader
Authentication header name (default Authorization, sending 'Bearer <key>'; custom headers such as api-key send the raw key without a Bearer prefix).

.PARAMETER MaxTokens
Optional max_tokens generation cap (1..1000000) sent on chat and subagent requests.

.PARAMETER Temperature
Optional sampling temperature (0..2, dot decimal) sent on chat and subagent requests.

.PARAMETER Permission
Tool permission mode: ReadOnly (inspection only), Ask (default: confirm writes, shell, and web), AutoEdit (auto-approve writes; confirm shell and web), or Auto (auto-approve all).

.PARAMETER Theme
Active 24-bit TrueColor theme ID: gruvbox-material (default), catppuccin-mocha, tokyo-night, dracula, nord, one-dark, rose-pine, kanagawa, or catppuccin-latte.

.PARAMETER ReasoningEffort
Optional reasoning_effort hint (low, medium, high) sent to reasoning-capable models.

.PARAMETER Prompt
Run a single prompt non-interactively and exit. Required when -Mode json is used without -Doctor, -Version, or -Help.

.PARAMETER Mode
Output mode: 'text' (default 24-bit TrueColor TUI) or 'json' (strictly valid JSONL event stream on stdout).

.PARAMETER Session
Resume an existing workspace .jsonl session file or create a named session file.

.PARAMETER SessionDir
Directory where workspace .jsonl session files are stored (defaults to <ConfigDir>/sessions).

.PARAMETER NoSession
Ephemeral mode: do not create or write session .jsonl files on disk.

.PARAMETER SessionName
Human-readable display name assigned to a new or forked session.

.PARAMETER Fork
Fork an existing workspace session into a new session file at startup.

.PARAMETER Export
Export the loaded session (or a .jsonl file path) to standalone themed .html or .jsonl and exit.

.PARAMETER Tools
Comma-separated allowlist of built-in tool names or wildcards (e.g. 'read_file,grep_files').

.PARAMETER ExcludeTools
Comma-separated denylist of built-in tool names to disable for the session.

.PARAMETER NoTools
Disable all model tools (pure chat completion mode).

.PARAMETER NoSkills
Disable discovery and /skill:<name> invocation of SKILL.md domain skills.

.PARAMETER NoPromptTemplates
Disable discovery and /<template> expansion of .shellossus/prompts/*.md templates.

.PARAMETER NoContextFiles
Skip automatic loading of SYSTEM.md, APPEND_SYSTEM.md, AGENTS.md, SOUL.md, and MEMORY.md context files.

.PARAMETER HideReasoning
Start with model reasoning blocks hidden (default view is compact).

.PARAMETER Diagnostics
Enable pre-request capability and tool-sync diagnostics.

.PARAMETER Doctor
Run non-mutating runtime, configuration, workspace, session-storage, and GET /models health checks and exit (0 on pass/warn, 1 on failure).

.PARAMETER Version
Print the shellossus version (text or -Mode json) and exit immediately without reading config or workspace state.

.PARAMETER Help
Print a concise categorized CLI usage reference (text or -Mode json) and exit immediately without reading config or workspace state. Supports -h and --help.

.PARAMETER Mascot
Render the pixel mascot card and exit.

.PARAMETER Continue
Resume the most recent session belonging to the current workspace.

.PARAMETER Setup
Run the interactive setup wizard to save endpoint, model ID, masked API key, and default workspace into -ConfigPath.

.PARAMETER Install
Register the shellossus launcher (and an optional conflict-checked shortcut) in your PowerShell $PROFILE.

.PARAMETER ProfilePath
Target PowerShell profile file path used by -Install (defaults to $PROFILE).

.PARAMETER Shortcut
Non-interactive shortcut name to register during -Install (e.g. s, sss, shos).

.PARAMETER NoShortcut
Skip registering a short alias during -Install.

.PARAMETER LiteralPrompt
Treat -Prompt as literal text without expanding /template commands or @file attachments.

.PARAMETER LibraryOnly
Internal switch reserved for test harnesses. Loads functions without running the CLI entrypoint.

.PARAMETER InternalWorker
Internal worker dispatch mode (http, web, subagent) reserved for isolated child worker subprocesses.

.EXAMPLE
.\shellossus.ps1 -Install
.\shellossus.ps1 -Setup
.\shellossus.ps1 -Doctor

Register the shellossus launcher in $PROFILE, configure API settings interactively, and verify runtime and endpoint health.

.EXAMPLE
.\shellossus.ps1 -Workspace C:\src\app -Permission AutoEdit -Stream

Start an interactive coding session in C:\src\app with auto-approved file edits (shell commands still require confirmation) and live SSE streaming.

.EXAMPLE
.\shellossus.ps1 -Prompt "Explain @README.md" -Permission ReadOnly

Run a single read-only prompt non-interactively and exit.

.EXAMPLE
.\shellossus.ps1 -Mode json -NoSession -Permission ReadOnly -Prompt "Audit @."

Emit strictly valid JSONL turn and tool events on stdout for scripts and CI pipelines.

.EXAMPLE
.\shellossus.ps1 -BaseUrl http://localhost:11434/v1 -Model qwen2.5-coder:14b -Continue

Resume the latest workspace session against a local Ollama server.

.NOTES
Runtime: Windows PowerShell 5.1, PowerShell 7+, and ConstrainedLanguage mode (zero external dependencies).
Configuration precedence: CLI arguments > SHELLOSSUS_* environment variables > -ConfigPath (.env).
API keys are supplied via $env:SHELLOSSUS_API_KEY or saved via -Setup (never passed as CLI arguments).

.LINK
https://github.com/mergelangelo/shellossus
#>
param(
    [string]$BaseUrl = $env:SHELLOSSUS_BASE_URL,
    [string]$Model = $env:SHELLOSSUS_MODEL,
    [string]$Workspace = '.',
    [string]$ConfigPath = (Join-Path (Join-Path $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }) '.shellossus') '.env'),
    [int]$MaxSteps = 50,
    [int]$MaxRepeatCalls = 3,
    [string]$ContextWindow = $env:SHELLOSSUS_CONTEXT_WINDOW,
    [string]$CompactThreshold = $env:SHELLOSSUS_COMPACT_THRESHOLD,
    [string]$RequestTimeoutSec = $env:SHELLOSSUS_REQUEST_TIMEOUT_SEC,
    [switch]$Stream,
    [string]$AuthHeader = $env:SHELLOSSUS_AUTH_HEADER,
    [string]$MaxTokens = $env:SHELLOSSUS_MAX_TOKENS,
    [string]$Temperature = $env:SHELLOSSUS_TEMPERATURE,
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
    [switch]$Version,
    [Alias('h')][switch]$Help,
    [switch]$Mascot,
    [switch]$Continue,
    [switch]$Setup,
    [switch]$Install,
    [string]$ProfilePath = $PROFILE,
    [string]$Shortcut = '',
    [switch]$NoShortcut,
    [switch]$LibraryOnly,
    [switch]$LiteralPrompt,
    [string]$InternalWorker = ''
)

$script:BundledScriptPath = $PSCommandPath
$script:StartupRequestTimeoutSpec = $RequestTimeoutSec
$script:StartupRequestTimeoutBound = ($PSBoundParameters.Keys -contains 'RequestTimeoutSec')
Remove-Variable -Name RequestTimeoutSec -Scope Script -ErrorAction SilentlyContinue
$script:StartupStreamBound = ($PSBoundParameters.Keys -contains 'Stream')
$script:StartupStreamValue = [bool]$Stream
Remove-Variable -Name Stream -Scope Script -ErrorAction SilentlyContinue
$script:StartupAuthHeaderSpec = $AuthHeader
$script:StartupAuthHeaderBound = ($PSBoundParameters.Keys -contains 'AuthHeader')
Remove-Variable -Name AuthHeader -Scope Script -ErrorAction SilentlyContinue
$script:StartupMaxTokensSpec = $MaxTokens
$script:StartupMaxTokensBound = ($PSBoundParameters.Keys -contains 'MaxTokens')
Remove-Variable -Name MaxTokens -Scope Script -ErrorAction SilentlyContinue
$script:StartupTemperatureSpec = $Temperature
$script:StartupTemperatureBound = ($PSBoundParameters.Keys -contains 'Temperature')
Remove-Variable -Name Temperature -Scope Script -ErrorAction SilentlyContinue

# Windows PowerShell 5.1 compatible. No downloaded executables or modules.
# Auto-generated from src/*.ps1 by build.ps1. Edit files in src/ and run .\build.ps1.
'@

Assert-AsciiFile -Path $PSCommandPath

$parts = @($header.Replace("`r`n", "`n").TrimEnd())
$includedFiles = @{}
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
    $modFull = (Get-Item -LiteralPath $modPath -Force -ErrorAction Stop).FullName
    $includedFiles[$modFull] = $true
    $raw = Get-Content -LiteralPath $modFull -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $raw) { $raw = '' }
    Assert-AsciiContent -Path $modFull -Content ([string]$raw)
    $normalized = ([string]$raw).Replace("`r`n", "`n").Trim()
    $parts += "# --- src/$normRel ---`n" + $normalized
}

$srcRoot = Join-Path $PSScriptRoot 'src'
if (Test-Path -LiteralPath $srcRoot) {
    foreach ($srcFile in @(Get-ChildItem -LiteralPath $srcRoot -Filter '*.ps1' -Recurse -File)) {
        if (-not $includedFiles.ContainsKey($srcFile.FullName)) {
            throw "Unlisted source module under src/: $($srcFile.FullName). Add it to `$modules in build.ps1."
        }
    }
}

$extraDirs = @($srcRoot, (Join-Path $PSScriptRoot 'tests'))
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
    $existingRaw = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $existingRaw) { $existingRaw = '' }
    Assert-AsciiContent -Path $targetPath -Content ([string]$existingRaw)
    if (([string]$existingRaw).Contains("`r")) {
        throw "CRLF line endings found in $targetPath. Run .\build.ps1 to regenerate with LF."
    }
    if ([string]$existingRaw -cne $assembled) {
        throw 'shellossus.ps1 is out of sync with src/*.ps1. Run .\build.ps1 to regenerate.'
    }
    Write-Host 'build.ps1 -Check passed: shellossus.ps1 matches src/*.ps1 (strict 7-bit ASCII verified).'
    return
}

Set-Content -LiteralPath $targetPath -Value $assembled -Encoding Ascii -NoNewline -ErrorAction Stop
Write-Host "Built $targetPath from src/*.ps1."
