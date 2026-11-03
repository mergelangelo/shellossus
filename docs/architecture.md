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

### 3. [`src/tools/`](../src/tools/)
- **Common & Schemas (`Common.ps1`):** Canonical name mapping (`Resolve-ToolCanonicalName`), tool enablement check, argument normalizers (`Format-*Arguments`), and strict schema validation (`Test-AgentToolArguments`).
- **File Operations (`Files.ps1`):** Ignore rules, directory walking (`Invoke-WorkspaceWalk`), and transactional fuzzy/batch file edits (`Invoke-AgentWrite`).
- **Undo Engine (`Undo.ps1`):** Transactional disk rollback and turn reversal (`Invoke-AgentUndo`).
- **Process & Shell (`Shell.ps1`):** Process tracking (`Stop-AgentProcessTree`) and sanitized command execution (`Invoke-AgentCommand`).
- **Web & Search (`Web.ps1`):** URL encoding, HTML text extraction, web search (`Invoke-AgentWebSearch`), and page fetch (`Invoke-AgentFetchUrl`).
- **Task Tracking (`Todo.ps1`):** Lightweight task state tracking tool (`Invoke-AgentTodo`).
- **Interactive Questioning (`AskUser.ps1`):** Plan review and user clarification questions tool (`Invoke-AgentAskUser`).
- **Persistent Memory (`Memory.ps1`):** Long-term cross-session knowledge storage in `MEMORY.md` (`Invoke-AgentMemory`).
- **Subagents (`Agents.ps1`):** Delegated task execution across specialized roles (`Invoke-AgentSubagent`).
- **Dispatcher (`Dispatch.ps1`):** Master tool caller (`Invoke-AgentTool`) routing calls and executing file queries (`list_files`, `find_files`, `grep_files`).

### 4. [`src/context/`](../src/context/)
- **Prompt Assembly (`Prompt.ps1`):** System prompt builder (`Build-SystemPrompt`), loading `AGENTS.md`, `CLAUDE.md`, `SOUL.md`, `MEMORY.md`, skills, and subagent roles.
- **Templates & Expansion (`Templates.ps1`):** Reusable slash prompt templates (`.shellossus/prompts/`) and inline `@file` / `!cmd` prompt attachments.
- **Session Trees (`Session.ps1`):** Multi-branch conversation trees, atomic JSONL session storage, and standalone HTML export.
- **Context Compaction (`Compaction.ps1`):** Token budgeting, token estimation, semantic compaction boundaries, and structured handoffs (`Invoke-AgentCompact`).

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
