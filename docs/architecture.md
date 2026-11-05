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

### 2. [`src/Theme.ps1`](../src/Theme.ps1) & [`src/ui/`](../src/ui/)
- **Palettes & Prompt Frame (`Theme.ps1`):** 9 built-in 24-bit TrueColor RGB themes (`gruvbox-material` default, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `one-dark`, `rose-pine`, `kanagawa`, `catppuccin-latte`), dynamic palette builder (`Set-AgentTheme`), context gauge, permission badges, and status bar (`Write-TuiPromptFrame`).
- **TUI Cards & Diffs (`ui/Cards.ps1`):** Tool execution cards, task board cards, plan review, memory cards, and unified diff rendering (`Format-UnifiedDiff`).
- **Interactive Input (`ui/Input.ps1`):** Multi-line prompt input (`Read-TuiMultilineInput`), interactive TUI selector (`Invoke-TuiSelector`), and confirmation prompts (`Read-TuiConfirmation`).
- **Markdown, Table & Mascot Renderer (`ui/Markdown.ps1`):**
  - Renders headings (`H1`–`H4`), bulleted/numbered lists, blockquotes, fenced code blocks, inline code, bold, italic, and links (`Write-AgentReply`, `Format-MarkdownInline`).
  - Buffers contiguous Markdown table lines, computes visible column widths (`Get-VisibleLength`), and pads cells so ANSI escape codes do not distort table alignment (`Format-MarkdownTable`).
  - Renders model `reasoning_content` in `compact` (last 3 lines), `full`, or `hide` mode (`Write-AgentReasoning`) and the ASCII/Unicode mascot (`Write-TuiMascotCard`).

### 3. [`src/tools/`](../src/tools/)
- **Common State & Truncation (`Common.ps1`):** Runtime state variables, canonical name mapping (`Resolve-ToolCanonicalName`), tool enablement check (`Test-IsToolEnabled`), line/head/tail truncation, and environment inspection (`Get-AgentEnvironment`).
- **Schemas & Capabilities (`Schemas.ps1`):** Capability probing (`Get-AgentCapabilities`) and OpenAI tool schema definitions (`Get-AgentTools`).
- **Argument Normalizers (`Normalizers.ps1`):** Tolerant alias and schema normalizers (`Format-EditArguments`, `Format-RunAgentArguments`, `Format-TodoArguments`, `Format-AskUserArguments`, `Format-MemoryArguments`).
- **Schema Validation (`Validation.ps1`):** Strict tool argument validation before execution (`Test-AgentToolArguments`).
- **Ignore Rules & Directory Walk (`Ignore.ps1`):** `.gitignore` / `.ignore` parsing, ancestor rule resolution, and workspace walking (`Invoke-WorkspaceWalk`).
- **File Writing & Editing (`Files.ps1`):** Fuzzy line matching (`Find-EditMatch`), diff previews (`Format-DiffSnippet`), line-ending preservation, and transactional single/batch file writes (`Invoke-AgentWrite`).
- **File Discovery & Reading (`Search.ps1`):** Directory listing (`Invoke-AgentListFiles`), glob file search (`Invoke-AgentFindFiles`), regex/literal content search (`Invoke-AgentGrepFiles`), and paginated file reading (`Invoke-AgentReadFile`).
- **Undo Engine (`Undo.ps1`):** Transactional disk rollback and turn reversal (`Invoke-AgentUndo`).
- **Process & Shell (`Shell.ps1`):** Process tracking (`Stop-AgentProcessTree`) and sanitized command execution (`Invoke-AgentCommand`).
- **Web & Search (`Web.ps1`):** URL encoding, HTML text extraction, web search (`Invoke-AgentWebSearch`), and page fetch (`Invoke-AgentFetchUrl`).
- **Task Tracking (`Todo.ps1`):** Lightweight task state tracking tool (`Invoke-AgentTodo`).
- **Interactive Questioning (`AskUser.ps1`):** Plan review and user clarification questions tool (`Invoke-AgentAskUser`).
- **Persistent Memory (`Memory.ps1`):** Long-term cross-session knowledge storage in `MEMORY.md` (`Invoke-AgentMemory`).
- **Subagents (`Agents.ps1`):** Delegated task execution across specialized roles (`Invoke-AgentSubagent`).
- **Dispatcher (`Dispatch.ps1`):** Master tool router (`Invoke-AgentTool`).

### 4. [`src/context/`](../src/context/)
- **Prompt Assembly (`Prompt.ps1`):** System prompt builder (`Build-SystemPrompt`), loading `AGENTS.md`, `SOUL.md`, `MEMORY.md`, and capability blocks (`Sync-AgentCapabilities`).
- **Skills & Subagent Catalog (`Catalog.ps1`):** Discovery and resolution of `SKILL.md` skills (`Get-SkillsCatalog`, `Resolve-SkillCommand`) and built-in/custom subagent roles (`Get-AgentRolesCatalog`, `Resolve-AgentRoleCommand`).
- **Templates & Expansion (`Templates.ps1`):** Reusable slash prompt templates (`.shellossus/prompts/`) and inline `@file` / `!cmd` prompt attachments.
- **Session Branch Tree (`SessionTree.ps1`):** Multi-branch conversation DAG construction, boundary validation, and branch switching (`Ensure-SessionTree`, `Get-SessionTree`, `Switch-SessionBranch`).
- **Session Persistence & Export (`Session.ps1`):** Atomic JSONL session storage (`Save-AgentSession`, `Invoke-SessionResume`), session forking (`Invoke-SessionFork`), and standalone HTML export (`Export-AgentSessionHtml`).
- **Context Compaction (`Compaction.ps1`):** Token budgeting, token estimation, semantic compaction boundaries, and structured handoffs (`Invoke-AgentCompact`).

### 5. [`src/cli/`](../src/cli/) & [`src/Cli.ps1`](../src/Cli.ps1)
- **Profile Installer (`cli/Install.ps1`):** Built-in `-Install` launcher installer (`Invoke-AgentProfileInstall`) registering `global:shellossus` and optional conflict-checked shortcuts in `$PROFILE`.
- **HTTP Transport & JSON Events (`cli/Http.ps1`):** UTF-8 file-backed HTTP transport (`Invoke-AgentHttpRequest`) with transient retry/backoff, spinner (`Wait-AgentProcessWithSpinner`), and JSON mode event emitter (`Write-AgentJsonEvent`).
- **Turn Loop (`cli/Turn.ps1`):**
  - Loop detection via canonical tool call signatures (`Get-ToolCallSignature`).
  - Automatically triggers `Invoke-AgentCompact` and retries once if the API reports a context-length overflow.
  - Verifies `finish_reason` before accepting the assistant message or executing any `tool_calls` (`Invoke-AgentTurn`, `Invoke-AgentContinue`).
- **REPL Helpers & Pickers (`cli/Repl.ps1`):** Slash command aliases (`Resolve-ReplCommandAlias`), status/tree/help/startup cards, and interactive pickers for `/permission`, `/diagnostics`, `/reasoning`, `/context`, and `/model`.
- **Entrypoint & REPL Loop (`Cli.ps1`):** Handles `-Install`, `-Setup`, `-Doctor`, `-Mascot`, `-Export`, `-Prompt` single-shot execution, and the interactive REPL loop.

### 6. [`src/Doctor.ps1`](../src/Doctor.ps1)
- **Diagnostics (`Get-AgentDoctorReport`):** Reports PowerShell/version support, language mode, configuration parsing, effective model/key settings, workspace access, session storage, and endpoint/model-catalog results. `-Doctor` runs before startup prompts or session creation, even with incomplete settings; `/doctor` checks the current model and session directory without changing conversation or undo state.
- **Storage probe (`Test-DoctorSessionDirectory`):** Creates a missing session directory, tests create/write/rename/read/delete inside a uniquely named probe directory, and cleans up the probe. `-NoSession` skips it. Passing this check does not guarantee that an existing session file has writable ACLs or will remain writable later.
- **Network probe (`Invoke-DoctorModelsRequest`):** One authenticated `GET /models`, no redirects, a 10-second request timeout (DNS can exceed it), and UTF-8 file-backed response decoding. Missing catalog support, rate limiting, an invalid catalog, or an absent model ID is a warning. Authentication errors and connectivity failures are failures. No completion or tool call is sent, and server bodies, headers, and raw errors are omitted from reports.
- **Output:** Human-readable checks or one `type: "doctor"` JSON object with `checks`, `failures`, `warnings`, and `exit_code`. Standalone `-Doctor` exits 1 for any failed check and 0 otherwise; warnings require reading the report. Keys are redacted, but model IDs, validated API base URLs, and local paths are visible.

## Built-in Tool Reference

These are the 13 canonical tools from `Get-AgentTools` in `src/tools/Schemas.ps1`. Availability also depends on permission mode and `-Tools` / `-ExcludeTools` / `-NoTools`.

| Tool | Purpose | Filesystem / undo scope |
| --- | --- | --- |
| `list_files` | List a directory | Workspace; read only |
| `read_file` | Read text with line/character pagination | Workspace plus registered global `SKILL.md`; read only |
| `find_files` | Find paths using globs and ignore rules | Workspace; read only |
| `grep_files` | Search text; continue with `file_offset` and `start_line` | Workspace; read only |
| `write_file` | Create or overwrite a text file | Workspace; records file undo |
| `edit_file` | Exact/fuzzy replacement or batch edits | Workspace; records file undo |
| `run_command` | Run PowerShell with a timeout and output capture | User's OS permissions; no file undo |
| `run_agent` | Single, parallel, or pipeline delegation | Inherits tool restrictions; in-process file edits join parent undo |
| `fetch_url` | Fetch HTTP(S) text | Network access; no undo |
| `web_search` | Search the web | Network access; no undo |
| `todo` | Maintain the session task board | State persisted with sessions; no task-board undo |
| `ask_user` | Ask a question or request plan review | Interactive response, not a general permission grant; no file undo |
| `memory` | View/append/set/clear persistent notes | Workspace or configuration directory; no file undo |

`run_command` is a process with the user's permissions, not an OS sandbox. User-entered `!` / `!!` shortcuts invoke it directly. The `memory` implementation uses its own fixed-path handling rather than `Resolve-AgentPath`; it checks the final file for reparse points but does not provide the file tools' ancestor-path guarantee. See [security boundaries and undo coverage](security.md).

---

## Build & Verification Pipeline

1. Edit source modules in `src/*.ps1`.
2. Run `.\build.ps1` to generate `shellossus.ps1` (pure ASCII, LF-normalized).
3. Run `.\tests\smoke.ps1`, which:
   - Calls `.\build.ps1 -Check` to ensure `shellossus.ps1` matches `src/*.ps1`.
   - Executes modular test suites (`Config.Tests.ps1`, `Theme.Tests.ps1`, `Tools.Tests.ps1`, `Context.Tests.ps1`, `Cli.Tests.ps1`, `Doctor.Tests.ps1`, `Reliability.Tests.ps1`) with isolated temporary workspaces. Doctor tests also run in a fresh process with `ConstrainedLanguage`; endpoint results are mocked, so tests send no real API requests.
   - Runs `ConstrainedLanguage.Tests.ps1` to verify core operations under PowerShell `ConstrainedLanguage` mode.

`Reliability.Tests.ps1 -ConstrainedLanguage` is a separate, optional invocation, currently excluded from `smoke.ps1`. It previously failed on Windows PowerShell 5.1 during overwrite verification; a green smoke run does not establish that the full reliability suite passes in that mode. The Windows CI workflow runs smoke under Windows PowerShell 5.1.
