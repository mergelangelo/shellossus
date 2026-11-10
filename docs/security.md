# Security, Permissions & Enterprise Guide

`shellossus` is designed for environments where installing third-party runtimes, binaries, or unverified PowerShell Gallery modules is prohibited or impractical.

---

## Permission Modes

You can set the permission mode at launch (`-Permission <Mode>`) or switch it at any time during a session (`/permission <Mode>`):

| Mode | Read & Search Tools | File Write & Edit Tools | Shell Execution (`run_command`) | Typical Use Case |
| --- | --- | --- | --- | --- |
| `ReadOnly` | Allowed | Hidden & blocked | Hidden & blocked | Code review, SQL/log analysis, architecture Q&A |
| `Ask` *(default)* | Allowed | Requires confirmation (`y` / `a` / `WRITE`; `Enter` cancels) | Requires confirmation (`y` / `a` / `RUN`; `Enter` cancels) | Safe everyday pair programming |
| `AutoEdit` | Allowed | Auto-approved (saves backup) | Requires confirmation (`y` / `a` / `RUN`; `Enter` cancels) | Fast iterative coding while keeping shell commands gated |
| `Auto` | Allowed | Auto-approved (saves backup) | Auto-approved | Trusted automation or sandboxed environments |

When resuming a saved session via `/resume`, `shellossus` resets the active permission mode to `Ask` unless `-Permission` was explicitly passed at launch.

The table describes the model's `write_file`, `edit_file`, and `run_command` tools. It does not make the entire process read-only. `todo`, `ask_user`, and `memory` remain available subject to tool filters. Memory modifications (`append`, `set`, `clear`) are rejected in `ReadOnly` and require confirmation in `Ask` mode. Sessions can still be saved in `ReadOnly`. `ask_user` plan approval does not change these permission rules.

User-entered `!cmd` and `!!cmd` are direct operator commands in every permission mode, including `ReadOnly`. They run immediately with the user's OS permissions. `!cmd` records the command and its output in the conversation. `!!cmd` displays the result locally.

Outbound web tools (`fetch_url` and `web_search`) require separate confirmation in `ReadOnly`, `Ask`, and `AutoEdit`. Choose `[a]ll` at a web prompt to approve further web requests for the session. `Auto` approves web requests automatically. In JSON mode, a request that requires confirmation returns `cancelled` immediately.

Switching to a stricter mode with `/permission`, or reselecting `ReadOnly`, `Ask`, or `AutoEdit`, clears the temporary `[a]ll` approvals for commands and web requests. Undoing an earlier turn preserves the explicit permission selection.

Plan review sets `approved` only when the user selects an explicit approval option by number, full label, or exact value. Both the label and value must be `Approve`, `Yes`, `Ok`, `Okay`, or `Accept`, optionally followed by ` (Recommended)`. Free-text responses are returned as feedback.

---

## Workspace Isolation & Path Safety

1. **Workspace Boundary Enforcement:**
   - `list_files`, `read_file`, `find_files`, `grep_files`, `write_file`, `edit_file`, and `@file` attachments use workspace path validation. Paths resolving outside the workspace directory are rejected (`Path is outside the workspace.`). Boundary checks (`Test-AgentPathWithinRoot` and `Get-WorkspaceRelativePath`) match Windows drive paths (`C:\...`) case-insensitively on Windows (`OrdinalIgnoreCase`) while keeping POSIX paths case-sensitive (`Ordinal`).
   - The read-only exception for these file tools is `read_file` access to global `SKILL.md` files explicitly registered by `Get-SkillsCatalog` from the global configuration directory (normally `%USERPROFILE%\.shellossus\skills`).
   - The workspace is the starting directory for `run_command`, `!`, and `!!`. These commands can access other paths, invoke native executables, and use the network wherever the user's OS permissions and application-control policies allow. On Windows, controls such as AppLocker or WDAC enforce executable restrictions.
   - `memory` is a separate fixed-path tool: workspace scope uses an existing root `MEMORY.md`, otherwise `.shellossus/MEMORY.md`; global scope uses `MEMORY.md` beside the active configuration file. It does not use `Resolve-AgentPath`, but it checks its target path and ancestor directories up to the scope root for reparse points (`Test-PathHasReparsePoint`).
   - Configuration and global context/skills/agent profiles are intentionally loaded from outside the workspace. Sessions normally live beside the configuration in `sessions/` (`-SessionDir` overrides this); imports/exports and explicit session paths are not constrained by the file-tool boundary. Staging files, backups, and HTTP response files use OS temporary storage. Doctor can create the configured session directory and temporarily probe it.
2. **Reparse Point Rejection:**
   - `Resolve-AgentPath`, `find_files`, `grep_files`, and `Get-SkillsCatalog` inspect file and ancestor directory attributes and reject any NTFS junction, symlink, or reparse point (`Attributes -band 1024`).
   - *Note:* Application-level path validation is not an OS kernel sandbox and does not protect against concurrent TOCTOU race conditions by external processes.
3. **Credential File Protection:**
   - `.env`, `.env.*` (except `.env.example`), and the user configuration file (`-ConfigPath`) are excluded from directory listings (`list_files`, `find_files`), search (`grep_files`), `@file` attachments, `read_file`, `write_file`, and `edit_file`.
   - Configuration files are parsed strictly as key-value data (`Read-AgentConfig`), never executed as PowerShell code.

---

## Safe File Writes & `/undo` Protection

- **Staged Writes:** `Invoke-AgentWrite` writes new content to a temporary file first, verifies the written content, verifies that the target file did not change during user confirmation, creates and verifies a backup copy, and then replaces the target file via `Move-Item -Force`.
- `write_file` and `edit_file` accept UTF-8 with or without a BOM and BOM-marked UTF-16 LE or BE. They verify that the original bytes round-trip through the detected encoding before an edit or overwrite, preserve the existing encoding and BOM, and verify backups and undo by byte hash. New files use UTF-8 without a BOM, except for new `.ps1` files with non-ASCII characters, which use a UTF-8 BOM for Windows PowerShell 5.1.
- Memory changes stop on a read error. Replacing or clearing an existing memory file requires a verified backup, including when the user runs `/memory` directly.
- **Conflict-Aware `/undo`:**
  - `write_file` and `edit_file` record created/modified paths and their content. Modified files also have verified pre-edit backups. In-process subagent file edits join the parent's recorded turn.
  - Before changing any file, undo verifies every pending backup against its recorded `before_content`, including intermediate backups from repeated edits to the same file. Missing, unreadable, or corrupted backups stop the entire preflight; files, backups, and conversation state are preserved for a retry.
  - Undo checks each recorded target against the workspace boundary or its fixed memory path. It checks for reparse points during preflight and again before each restoration or deletion. These application-level checks are subject to filesystem races.
  - When `/undo` is invoked, `Invoke-AgentUndo` checks whether the file on disk was modified manually after the agent's write. If manual edits are detected, `/undo` refuses to overwrite the file and preserves the backup path.
  - Undo removes the backups after restoration and verification succeed. A failed undo reports pending operations and preserves the backups, including across session switches and process exit.

### Turn and Recovery Scope

`/undo` and automatic rollback after a failed turn reverse recorded `write_file`, `edit_file`, and `memory` tool changes in both memory scopes. They restore conversation and task-board state after file restoration succeeds. Shell commands, manual `/memory` commands, configuration, session exports, and network requests are outside the turn journal.

Undo history is process-local and retains the 20 newest frames. Eviction, session resets, session switches, and process exit clean up ordinary backups. An I/O failure during restoration can leave some files restored and others pending. In that case Shellossus reports the pending paths and keeps the backups for recovery.

---

## Process Execution & Command Timeouts

Child PowerShell processes launch the executable by absolute path from the current installation's `$PSHOME` with profiles disabled. The model API POST and web download workers receive application-owned code through `-EncodedCommand`. Request URLs, credentials, and payloads travel separately as environment values or data files.

For `fetch_url` and `web_search`, downloads run in a separate PowerShell process. The parent checks the temporary output file while the download is running, stops it when it exceeds 2 MiB, and checks the completed file again before reading it. The check is periodic, so a fast response can temporarily exceed the limit between polls; this is not a strict disk or worker-memory quota.

The worker checks literal IPs and all IPv4 and IPv6 DNS answers before making the HTTP request, and disables redirects. It uses the Windows inbox `Resolve-DnsName` cmdlet when available. If the cmdlet is missing, the worker can use the system resolver in `FullLanguage` mode, and hostname requests fail closed in `ConstrainedLanguage`. The HTTP client resolves the hostname separately, so DNS preflight does not pin the connection to a checked IP. Deployments that require a guaranteed destination restriction need an outbound network policy or gateway.

- **API Key Scrubbing:** `Invoke-ShellCommand` clears `SHELLOSSUS_API_KEY` and `OPENAI_API_KEY` before spawning a child PowerShell process and restores them afterward. Other environment variables remain available, and commands can still read files allowed by the OS, including a saved `.env` key.
- **Disk-Backed Output Streaming:** Standard output and standard error are redirected directly to temporary files on disk (`Start-Process -RedirectStandardOutput -RedirectStandardError`). The model receives a tail of up to 300 lines and 20,000 UTF-8 bytes. If output is truncated, the full log is preserved under `.shellossus/output/cmd-*.log`.
- **Timeout & Termination:** Commands default to a 60-second timeout (`timeout_sec`, configurable from 1 to 600 seconds). While waiting, `shellossus` tracks child and descendant processes. On timeout or interrupted execution it stops the command and tracked descendants using built-in cmdlets. Windows PowerShell 5.1 uses `Get-CimInstance Win32_Process` for parent relationships; PowerShell on Linux/macOS uses `Get-Process`. Start times are checked before termination to avoid stopping an unrelated process that reused a PID. Timeout results include `termination_errors` if cleanup could not be completed.
- **Process Tracking Limits:** Tracking is based on periodic snapshots, not an OS process sandbox. A detached descendant whose parent exits between snapshots can escape discovery; command execution retains the user's OS permissions. Normal successful commands may intentionally leave background processes running.

## Resource Limits

Each agent turn can accept up to 128 tool calls across model responses, regardless of the step limit. A batch that would exceed the budget is rejected before any call in it runs. Tool arguments are limited to 1 MiB of UTF-8 before parsing, and `edit_file` accepts up to 64 edits per batch. Each model response is limited to 8 MiB before JSON parsing. The HTTP worker is monitored periodically, so the temporary download can briefly exceed the limit. Accepted model responses and tool results share a 32 MiB payload budget per turn.

Each memory file is limited to 256 KiB. A session has a 32 MiB JSONL budget, a 10,000-record limit, and a 5,000-entry tree limit. Start a new session with `/new` when the history fills up. Diagnostics retain the 100 newest steps.

Workspace searches visit up to 10,000 directory entries, including ignored entries. Search results indicate when the traversal is incomplete. `grep_files` additionally allows 100 ms per regular-expression match and 10 seconds for the content scan. Narrow the search path after a traversal limit, or simplify the pattern after a match timeout.

## Subagent Tool Restrictions

In-process and separate-process subagents receive the intersection of the parent's effective tool permissions and the role's tool filter. Parent exclusions, aliases, and wildcard filters are respected. An empty intersection disables all tools; it never means unrestricted access. `ReadOnly` subagents exclude `write_file`, `edit_file`, `run_command`, `memory`, `todo`, and `ask_user` (plus `fetch_url` and `web_search` in non-interactive JSON mode when web tools are not auto-approved), and in-process subagents preserve the parent session's active `todo` state. Parallel workers remain `ReadOnly`, and recursive `run_agent` calls are disabled.

---

## Enterprise / Citrix / VDI Notes

- `shellossus` does **not** modify `ExecutionPolicy`, language mode, or system security settings.
- Windows PowerShell 5.1 and `ConstrainedLanguage` are supported targets. CI runs the smoke suite on Windows PowerShell 5.1, including dedicated constrained-language runs for `Doctor.Tests.ps1`, `Reliability.Tests.ps1`, and `ConstrainedLanguage.Tests.ps1` (see [verification coverage](architecture.md#build--verification-pipeline)).
- Use `shellossus -Doctor` before starting a chat, or `/doctor` in a session, for runtime, settings, storage, and endpoint checks. The authenticated `/models` probe does not generate a completion or verify model tool support. Reports hide the key but include local paths, validated API base URLs, and model IDs; review those before sharing.
- The user API key is stored in plain text in `%USERPROFILE%\.shellossus\.env` (outside the project directory). Do not commit `.env` files or share terminal recordings taken during `shellossus -Setup`.
