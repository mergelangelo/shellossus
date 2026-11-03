# Architecture & Build Pipeline

`shellossus` uses a dual-distribution architecture: developers maintain clean, modular source files in [`src/`](../src/), while [`build.ps1`](../build.ps1) bundles them into the standalone [`shellossus.ps1`](../shellossus.ps1) in the repository root. This gives contributors small, focused modules while allowing enterprise / Citrix / VDI users to copy a single zero-dependency `.ps1` file.

---

## Module Breakdown

### 1. [`src/Config.ps1`](../src/Config.ps1)
- **Configuration I/O (`Read-AgentConfig`, `Save-AgentConfig`):** Parses and writes `SHELLOSSUS_*` key-value pairs as pure data without ever evaluating PowerShell expressions.
- **Boundary & Secret Enforcement (`Resolve-AgentPath`, `Test-IsSecretFile`):**
  - Resolves workspace-relative paths against the workspace root.
  - Rejects any path outside the workspace root (with a narrow read-only exception for registered global `SKILL.md` files when `-AllowRegisteredSkill` is passed by `read_file`).
  - Walks all ancestor directories of every resolved item and rejects NTFS junctions, symlinks, or reparse points (`Attributes -band 1024`).
  - Blocks access to `.env`, `.env.*` (except `.env.example`), and the active user configuration file (`$script:AgentConfigPath`).

### 2. [`src/Theme.ps1`](../src/Theme.ps1)
- **Palette (`$script:Gm`):** Exact 24-bit TrueColor RGB sequences from `sainnhe/gruvbox-material` (`dark medium`, `#282828` background, `#d4be98` foreground).
- **Markdown & Table Renderer (`Write-AgentReply`, `Format-MarkdownTable`, `Format-MarkdownInline`):**
  - Renders headings (`H1`–`H4`), bulleted/numbered lists, blockquotes, fenced code blocks, inline code, bold, italic, and links.
  - Buffers contiguous Markdown table lines, computes visible column widths (`Get-VisibleLength`), and pads cells so ANSI escape codes do not distort table alignment.
- **Reasoning Display (`Write-AgentReasoning`):** Renders model `reasoning_content` in `compact` (last 3 lines), `full`, or `hide` mode.

### 3. [`src/Tools.ps1`](../src/Tools.ps1)
- **Search Continuation (`grep_files`):** Truncated results return `next_file_offset` (0-based) and `next_start_line` (1-based). Pass both back as `file_offset` and `start_line` with the same search arguments. The line cursor applies only to the first file on the next page. Candidate paths are sorted; pagination assumes the file set and contents remain unchanged between requests. `files_scanned` counts only files actually visited on the current page.
- **Tool Definitions (`Get-AgentTools`):** Exposes built-in tools (`list_files`, `read_file`, `find_files`, `grep_files`, `fetch_url`, `web_search`, `todo`, `ask_user`, `run_agent`, `write_file`, `edit_file`, `run_command`), dynamically hiding write and command tools when `$script:AgentPermission -eq 'ReadOnly'`.
- **Task Planning & Progress (`Invoke-AgentTodo`):** Log-only task board tool (`todo`) with whole-list atomic replacement, resilient argument formatting (`Format-TodoArguments`), validation, and live TUI checklist cards (`Format-TodoCard`).
- **Interactive Questions & Plan Reviews (`Invoke-AgentAskUser`):** Interactive decision tool (`ask_user`) with `question` and `plan-review` presentation intents, option selection via `Invoke-TuiSelector`, custom free-text feedback, explicit plan approval tracking, and Markdown plan cards (`Format-PlanReviewCard`).
- **Strict Schema Validation (`Test-AgentToolArguments`):**
  - Uses `Get-Member -MemberType NoteProperty` (compatible with `ConstrainedLanguage` mode) to inspect parsed JSON objects.
  - Verifies required parameters, rejects unknown parameters, and enforces actual runtime types (`[string]`, `[bool]`, `[int]`/`[long]`, `[array]`) without PowerShell truthy string coercion (e.g. rejecting `"overwrite": "false"`).
- **Fuzzy & Batch File Edits (`Find-EditMatch`, `Invoke-AgentWrite`):**
  - Both full overwrites and edit replacements preserve an existing CRLF or LF newline convention. Empty and single-line files retain the incoming text's line endings.
  - Supports exact replacement, CRLF-normalized replacement, and line-by-line fuzzy matching (`Format-FuzzyLine`) that normalizes trailing whitespace, UTF-8 BOM, and typographic quotes/dashes.
  - Supports atomic batch `edits[]`: validates all blocks against the original file, rejects overlapping ranges, and applies replacements bottom-to-top.
  - Stages output to a temporary file (`New-TemporaryFile`), verifies the staged write, creates and verifies a backup copy, registers the rollback entry in `$script:CurrentTurnWrites` before touching the target file, and replaces the target via `Move-Item -Force`.
- **Disk Rollback (`Invoke-AgentUndo`):**
  - Restores modified files from verified backups and removes newly created files in reverse order.
  - Checks `after_content` on disk before restoring so manual edits made by the user after an agent turn are never overwritten.
  - Preserves the backup file and throws an explicit error if restoration fails.
- **Isolated Shell Execution (`Invoke-ShellCommand`, `Invoke-AgentCommand`):**
  - Scrubs `SHELLOSSUS_API_KEY` and `OPENAI_API_KEY` from the child environment.
  - Uses `Start-Process` with `-RedirectStandardOutput` and `-RedirectStandardError` to stream output directly to temporary disk files without buffering large outputs in RAM.
  - Enforces a configurable timeout (`Wait-Process -Timeout`, default 60s) and terminates hung processes via `Stop-Process -Force`.

### 4. [`src/Context.ps1`](../src/Context.ps1)
- **System Prompt Assembly (`Build-SystemPrompt`, `Get-AgentsContext`, `Get-SkillsCatalog`):** Combines base instructions, `SYSTEM.md` overrides, `APPEND_SYSTEM.md` additions, `AGENTS.md` project rules, and discovered `SKILL.md` descriptors.
- **Prompt Templates & `@file` Expansion (`Resolve-PromptTemplate`, `Expand-UserPrompt`):** Expands `/<template>` files from `.shellossus/prompts/` and attaches workspace files referenced via `@path/to/file`.
- **Project-Scoped Sessions (`Save-AgentSession`, `Get-AgentSessionMeta`, `Read-AgentSession`, `Find-ProjectSession`):**
  - Writes a `session_meta` JSON header on line 1 (`version`, `id`, `workspace`, `model`, `updated_at`) followed by message records.
  - Saves atomically via a temporary file and `Move-Item -Force`.
- **Structured Context Compaction (`Invoke-AgentCompact`):** Summarizes older conversation turns (preserving `tool_calls` names, arguments, and `tool` results) into a structured Markdown handoff (`Goal`, `Constraints & Preferences`, `Progress`, `Key Decisions`, `Next Steps`, `Critical Context`).

### 5. [`src/Cli.ps1`](../src/Cli.ps1)
- **Turn Loop (`Invoke-AgentTurn`):**
  - Sends UTF-8 JSON requests via `Invoke-WebRequest -OutFile` (avoiding PowerShell 5.1 default ANSI decoding issues).
  - Retries transient HTTP/network failures (`408`, `429`, `500`, `502`, `503`, `504`, timeouts) with backoff.
  - Automatically triggers `Invoke-AgentCompact` and retries once if the API reports a context-length overflow.
  - Verifies `finish_reason` before accepting the assistant message or executing any `tool_calls` (rejecting truncated `finish_reason=length` responses).
- **Interactive REPL:** Handles slash commands, `!cmd` / `!!cmd` shortcuts, turn rollback on failure, and `-Prompt` single-shot execution.

---

## Build & Verification Pipeline

1. Edit source modules in `src/*.ps1`.
2. Run `.\build.ps1` to generate `shellossus.ps1` (pure ASCII, LF-normalized).
3. Run `.\tests\smoke.ps1`, which:
   - Calls `.\build.ps1 -Check` to ensure `shellossus.ps1` matches `src/*.ps1`.
   - Executes modular test suites (`Config.Tests.ps1`, `Theme.Tests.ps1`, `Tools.Tests.ps1`, `Context.Tests.ps1`, `Cli.Tests.ps1`, `Reliability.Tests.ps1`) with isolated temporary workspaces. Reliability regressions also run in a fresh PowerShell process with `ConstrainedLanguage`, including real process-tree termination and separate-process subagent tool filtering.
   - Runs `ConstrainedLanguage.Tests.ps1` to verify core operations under PowerShell `ConstrainedLanguage` mode.
