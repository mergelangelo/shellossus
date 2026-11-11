# Project Constitution

## Preamble

`shellossus` exists to deliver a full-featured, autonomous coding agent that runs out of the box on every Windows machine without external runtimes, package managers, or third-party binaries. Where other coding agents depend on Python, Node.js, or native CLI toolchains that are blocked on corporate desktops, Citrix/VDI sessions, and locked-down servers, `shellossus` provides complete agentic power in a single, zero-dependency PowerShell script connected to any OpenAI-compatible API — and runs equally natively on Linux and macOS via `pwsh`.

This document defines the non-negotiable architectural principles, safety boundaries, and engineering invariants of the project.

---

## Article I — Zero-Dependency Sovereign Runtime

### Section 1. Native PowerShell Execution
`shellossus` must run natively on **Windows PowerShell 5.1** and PowerShell 7+. It must never require Python, Node.js, Go, Rust, WSL, Docker, or any external runtime to install or operate.

### Section 2. No External Binaries or Modules
No built-in feature or tool may depend on external command-line utilities (`rg`, `fd`, `git`, `jq`, `curl`) or external PowerShell modules (`Install-Module`). File discovery, regex search, ignore-rule matching, diff rendering, HTTP communication, SSE response assembly, and Markdown formatting must be implemented directly in PowerShell.

### Section 3. ConstrainedLanguage Compatibility
All code paths must remain compatible with PowerShell **`ConstrainedLanguage`** mode, AppLocker, and Windows Defender Application Control (WDAC). Direct `.NET` static method calls, `Add-Type` compilation, or object methods blocked in `ConstrainedLanguage` mode must not be used when native PowerShell operators and built-in cmdlets can achieve the same result; where an OS capability is unavailable under `ConstrainedLanguage`, the feature must fail closed with a clear diagnostic rather than bypassing policy.

---

## Article II — Modular Source, Single-Script Artifact, and Transport

### Section 1. Modular Source, Single-File Distribution
1. All development takes place in modular source files under [`src/`](src/) (`Config.ps1`, `Theme.ps1`, `ui/*.ps1`, `tools/*.ps1`, `context/*.ps1`, `Doctor.ps1`, `cli/*.ps1`, `Cli.ps1`).
2. The root [`shellossus.ps1`](shellossus.ps1) file is the standalone distribution artifact assembled by [`build.ps1`](build.ps1). It must never be edited by hand and must always stay in exact sync with `src/*.ps1` (`.\build.ps1 -Check`).

### Section 2. Pure ASCII Source Files
All `.ps1` files (`src/*.ps1`, `shellossus.ps1`, `build.ps1`, `tests/*.ps1`) must contain only **7-bit ASCII** characters with normalized LF line endings. This guarantees identical parsing in Windows PowerShell 5.1 regardless of file BOM or system ANSI codepage.

### Section 3. OpenAI-Compatible Transport and Isolated Workers
1. `shellossus` communicates with models via standard OpenAI-compatible `/v1/chat/completions` endpoints (cloud providers, local `Ollama`/`vLLM` servers, or internal corporate gateways) using UTF-8 file-backed HTTP requests so non-ASCII prompts and responses are never corrupted by default codepages.
2. Remote endpoints require `https://`; `http://` is permitted only for local loopback addresses (`localhost`, `127.0.0.1`, `[::1]`).
3. Internal worker processes (`http`, `web`, `subagent`) launch the PowerShell executable from the active `$PSHOME` by absolute path with `-NoProfile` and invoke `shellossus.ps1` via `-File` in fixed `-InternalWorker` modes, passing request payloads and credentials separately as data rather than interpolated command strings.

---

## Article III — Workspace Isolation and Credential Protection

### Section 1. Explicit Boundary Separation
1. Workspace file tools (`list_files`, `read_file`, `find_files`, `grep_files`, `write_file`, `edit_file`) and `@file` attachments must enforce the active workspace root, with a narrow read-only exception for registered global `SKILL.md` files via `read_file`.
2. Only explicit `@file` references in the user's original input may attach workspace files; model-generated subagent prompts, template bodies, and pipeline outputs are treated as literal text.
3. This file-tool boundary is an application-level invariant, not an OS kernel sandbox. Shell execution (`run_command`, `!cmd`, `!!cmd`) retains the user's OS permissions; configuration/context loading, sessions, imports/exports, temporary files, recovery manifests, and the explicit global `memory` scope use separate documented paths.

### Section 2. Reparse Point and Symlink Rejection
Before any workspace file tool or `memory` operation accesses a path, `shellossus` must inspect the target and ancestor directories and reject any symbolic link, NTFS junction, or reparse point (`Attributes -band 1024`).

### Section 3. Secret and Configuration Protection
1. `.env`, `.env.*` (except `.env.example`), and the active user configuration file (`$ConfigPath`) must never be listed, searched, read, attached, or modified by agent tools.
2. Configuration files must be parsed strictly as plain `SHELLOSSUS_*` key-value data without evaluating PowerShell expressions. Saving an API key to disk requires verified private directory and file permissions (Windows ACLs or Unix owner/mode bits).
3. Child processes spawned by `run_command` must have `SHELLOSSUS_API_KEY` and `OPENAI_API_KEY` scrubbed from their environment.

### Section 4. Hierarchical Ignore Rules
`find_files` and `grep_files` must respect `.gitignore`, `.ignore`, and `.fdignore` rules — including wildcards (`*`, `**`, `?`), directory-only patterns, escaped characters, and negation (`!pattern`) — loaded top-down from the workspace root through all intermediate parent directories.

---

## Article IV — Tool Execution, Transactional File Integrity, and Undo

### Section 1. Permission Modes and Approvals
1. Model tool availability and confirmations are governed by four modes:
   - **`ReadOnly`**: Allows inspection tools and `ReadOnly`-clamped `run_agent`; blocks `write_file`, `edit_file`, `run_command`, and modifying `memory` actions (`append`, `set`, `clear`). Auxiliary `todo`, `ask_user`, and memory viewing remain available subject to tool filters.
   - **`Ask`** *(default)*: Previews diffs or commands and requires explicit confirmation for file/memory writes and `run_command`.
   - **`AutoEdit`**: Auto-approves file and memory writes (with verified backups) while still requiring confirmation for `run_command`.
   - **`Auto`**: Auto-approves file/memory writes, `run_command`, and outbound web tools.
2. Outbound web tools (`fetch_url`, `web_search`) require separate confirmation unless `Auto` mode or session web `[a]ll` is active.
3. Selecting a stricter mode or reselecting `ReadOnly`, `Ask`, or `AutoEdit` revokes session-scoped command and web `[a]ll` approvals. User-entered `!cmd` and `!!cmd` are direct operator actions outside model tool gating.

### Section 2. Fail-Closed Validation Before Execution
Tool calls must be validated as a complete batch (unique IDs, supported types, turn tool-call budget, argument byte caps, and strict parameter schema/type validation) before any tool in the batch executes. Strings such as `"false"` must never be coerced into booleans.

### Section 3. Atomic Staged Writes, Encoding Preservation, and Backups
1. Every `write_file`, `edit_file`, and modifying `memory` operation must stage new content to a temporary file, verify the staged content, confirm the target file did not change during confirmation, and create a hash-verified backup before replacing the target via `Move-Item -Force`.
2. Existing file encodings (UTF-8 with/without BOM, BOM-marked UTF-16 LE/BE) and line endings (`CRLF` or `LF`) must round-trip cleanly and be preserved. `edit_file` supports exact matches, CRLF-normalized matches, unambiguous line-by-line fuzzy matches, and non-overlapping bottom-to-top batch `edits[]`.

### Section 4. Conflict-Aware Multi-Step `/undo` and Turn Rollback
1. Every turn journals `write_file`, `edit_file`, and `memory` tool changes (including in-process subagent edits) alongside conversation and `todo` task-board snapshots. Shell effects, manual `/memory` commands, configuration updates, exports, and network requests remain outside this journal.
2. Before `/undo` or automatic turn-failure rollback modifies disk, a preflight check must validate the full reverse chain of operations and backups, including multiple edits to the same file within a single turn.
3. If a file was modified externally after the agent's write, `/undo` must refuse to overwrite manual edits and keep backups intact. Conversation and task-board state are restored only after file restoration succeeds; failed rollbacks preserve backups and emit recovery metadata.

### Section 5. Bounded Shell Execution and Subagent Delegation
1. `run_command` redirects stdout/stderr directly to temporary disk files, enforces a configurable timeout with descendant process-tree termination, and saves untruncated output under `.shellossus/output/` whenever terminal output is truncated.
2. `run_agent` supports single delegation (`prompt`), parallel read-only fan-out (`parallel[]`, 1..8 tasks), and sequential pipelines (`pipeline[]`, 1..8 steps with `{previous}` / `$PREVIOUS` substitution) using `clean` or `fork` context. Subagents cannot invoke `run_agent` recursively (depth capped at 1) and inherit at most the intersection of parent and role permissions (`recon`, `audit`, and `parallel[]` workers are strictly `ReadOnly`).

---

## Article V — Context Integrity, Pagination, and Session Tree

### Section 1. Lossless Pagination and Truncation Metadata
1. `read_file` enforces 300 lines and 20,000 characters per page, computing `end_line`, `next_start_line`, and character-offset continuation (`start_char` / `next_start_char`) from actual returned data so no text is ever skipped.
2. `grep_files` and `find_files` return explicit truncation and continuation metadata (`truncated`, `truncation_reason`, `files_scanned`, `total_files`, `next_file_offset`) whenever scan, match, or timeout limits are hit.

### Section 2. Preflight Budgeting and Complete Model Responses
1. Assembled requests must be checked against context budgets prior to dispatch.
2. Both `Invoke-AgentTurn` and `Invoke-AgentCompact` must inspect response size, `finish_reason`, and (when `-Stream` is active) terminal `[DONE]` framing. Any truncated (`finish_reason=length`), filtered (`content_filter`), or incomplete stream response must be rejected before updating conversation state or executing tools.

### Section 3. Atomic Session Tree and Compaction
1. Sessions are persisted atomically as workspace-scoped JSONL files containing `session_meta` and parent-linked DAG entries (`id`, `parent_id`), stripped of internal storage fields before API dispatch.
2. Branch switching (`/tree`), forking (`/fork`), and context compaction cut points are permitted only at valid conversation boundaries (never splitting an assistant `tool_calls` message from its `role = 'tool'` results).
3. Context compaction (`/compact` and automatic overflow recovery) produces a structured handoff (`Goal`, `Constraints & Preferences`, `Progress`, `Key Decisions`, `Next Steps`, `Critical Context`) with cumulative `<read-files>` and `<modified-files>` tracking stored as a `compaction` tree entry so other branches remain intact.

---

## Article VI — Output Streams and Terminal Interface

### Section 1. Clean JSONL Automation (`-Mode json`)
In `-Mode json`, `stdout` must emit only valid JSONL objects (`turn_start`, `message_end`, `tool_execution_start`, `tool_execution_end`, `turn_end`, and optional `diagnostics`). All TUI chrome and interactive prompts are suppressed; any action requiring confirmation immediately returns `status = 'cancelled'`. Standalone `-Doctor -Mode json` emits a single redacted `doctor` report object and exits without entering chat.

### Section 2. TrueColor Terminal Rendering (`-Mode text`)
Interactive and text modes, as well as standalone HTML exports (`/export`), render with the active 24-bit TrueColor palette across the 9 built-in themes (`gruvbox-material` dark medium by default), aligning Markdown tables by visible character width (`Get-VisibleLength`) and sanitizing untrusted terminal control sequences.

---

## Article VII — Local Customization Stack

`shellossus` assembles customization locally and deterministically from:
1. Default base prompt or `.shellossus/SYSTEM.md` / `~/.shellossus/SYSTEM.md` override;
2. Live `<capabilities>` environment, permission, and active-tool block;
3. Global and workspace `APPEND_SYSTEM.md` additions;
4. Agent ethos/persona (`SOUL.md`, `ETHOS.md`, or `SHELLOSSUS.md`) in `<soul>` blocks;
5. Persistent cross-session memory (`MEMORY.md`) in `<memory>` blocks;
6. Global, root, and path-scoped nested `AGENTS.md` project instructions;
7. Local and global domain skills (`SKILL.md`) cataloged in `<available_skills>`;
8. Built-in (`recon`, `audit`, `craft`) and custom subagent role profiles (`agents/*.md`) cataloged in `<available_agents>`;
9. Slash prompt templates (`.shellossus/prompts/*.md`) with single-pass positional, slice, and default argument expansion (`$1`, `$@`, `$ARGUMENTS`, `${1:-default}`, `${@:2}`).

---

## Article VIII — Verification and Changes

### Section 1. Automated Verification (`smoke.ps1`)
Every code change in `src/*.ps1` must be followed by running [`build.ps1`](build.ps1) to regenerate [`shellossus.ps1`](shellossus.ps1) and running [`tests/smoke.ps1`](tests/smoke.ps1) across all modular suites (`Config`, `Theme`, `Tools`, `Context`, `Cli`, `Doctor`, `Reliability`, and `ConstrainedLanguage`, including dedicated `ConstrainedLanguage` child-process runs).

### Section 2. Maintaining Invariants
Every new feature, refactor, or bugfix must uphold Articles I through VII, keep documentation synchronized with behavior, and include regression coverage in [`tests/`](tests/).
