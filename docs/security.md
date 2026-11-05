# Security, Permissions & Enterprise Guide

`shellossus` is designed for environments where installing third-party runtimes, binaries, or unverified PowerShell Gallery modules is prohibited or impractical.

---

## Permission Modes

You can set the permission mode at launch (`-Permission <Mode>`) or switch it at any time during a session (`/permission <Mode>`):

| Mode | Read & Search Tools | File Write & Edit Tools | Shell Execution (`run_command`) | Typical Use Case |
| --- | --- | --- | --- | --- |
| `ReadOnly` | Allowed | Hidden & blocked | Hidden & blocked | Code review, SQL/log analysis, architecture Q&A |
| `Ask` *(default)* | Allowed | Requires confirmation (`y` / `Enter` / `WRITE`) | Requires confirmation (`y` / `Enter` / `RUN`) | Safe everyday pair programming |
| `AutoEdit` | Allowed | Auto-approved (saves backup) | Requires confirmation (`y` / `Enter` / `RUN`) | Fast iterative coding while keeping shell commands gated |
| `Auto` | Allowed | Auto-approved (saves backup) | Auto-approved | Trusted automation or sandboxed environments |

When resuming a saved session via `/resume`, `shellossus` resets the active permission mode to `Ask` unless `-Permission` was explicitly passed at launch.

The table describes the model's `write_file`, `edit_file`, and `run_command` tools. It does not make the entire process read-only. `todo`, `ask_user`, and `memory` remain available (subject to tool filters); memory modifications (`append`, `set`, `clear`) are rejected in `ReadOnly` and require confirmation in `Ask` mode (using staged atomic writes without `/undo` backup tracking). Outbound web tools (`fetch_url` and `web_search`) require explicit user confirmation in `ReadOnly` and `Ask` modes (with `[a]ll` approving web requests for the active session) and are automatically approved in `AutoEdit` and `Auto` modes. Sessions can still be saved in `ReadOnly`. User-entered `!cmd` / `!!cmd` shortcuts execute directly, without `RUN` confirmation or a `ReadOnly` check. `ask_user` plan approval does not change these permission rules.

---

## Workspace Isolation & Path Safety

1. **Workspace Boundary Enforcement:**
   - `list_files`, `read_file`, `find_files`, `grep_files`, `write_file`, `edit_file`, and `@file` attachments use workspace path validation. Paths resolving outside the workspace directory are rejected (`Path is outside the workspace.`). Boundary checks use case-sensitive path comparison on all platforms; absolute paths with different capitalization from the workspace may therefore be rejected even on case-insensitive filesystems.
   - The read-only exception for these file tools is `read_file` access to global `SKILL.md` files explicitly registered by `Get-SkillsCatalog` from the global configuration directory (normally `%USERPROFILE%\.shellossus\skills`).
   - Shell commands start with the workspace as their working directory, but retain the user's OS permissions. They can change directory, read/write other paths (including configuration files), invoke programs, and use the network. Permission prompts approve execution; they do not sandbox it.
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
- **Conflict-Aware `/undo`:**
  - `write_file` and `edit_file` record created/modified paths and their content. Modified files also have verified pre-edit backups. In-process subagent file edits join the parent's recorded turn.
  - Before changing any file, undo verifies every pending backup against its recorded `before_content`, including intermediate backups from repeated edits to the same file. Missing, unreadable, or corrupted backups stop the entire preflight; files, backups, and conversation state are preserved for a retry.
  - Undo checks each recorded target and its parent path for workspace boundaries and reparse points during preflight and again before each restoration or deletion. As with the file tools, these application-level checks do not eliminate filesystem races.
  - When `/undo` is invoked, `Invoke-AgentUndo` checks whether the file on disk was modified manually after the agent's write. If manual edits are detected, `/undo` refuses to overwrite the file and preserves the backup path.
  - Backup files are only deleted after restoration succeeds and the restored content is verified against the recorded original content.

### What `/undo` Does Not Cover

`/undo` restores the tracked turn's conversation messages and recorded file changes. It does not reverse effects of `run_command`, `!cmd`, `!!cmd`, `memory` (either scope), task-board state, configuration/setup, session exports, network requests, or changes by external processes. The same limit applies to automatic rollback after a failed turn. For example, `write_file` creating `a.txt` is tracked, while a shell command creating `b.txt` or `memory` appending a note is not.

Undo history is kept in memory and is reset when a session is resumed or its active branch changes; loading JSONL history does not reconstruct file backups. Preflight failure prevents that undo operation from changing files, but I/O failure during restoration can leave some files restored and others pending. Backups are temporary local files, not a durable transaction journal. Keep version control or other backups for long-lived recovery.

---

## Process Execution & Command Timeouts

For `fetch_url` and `web_search`, downloads run in a separate PowerShell process. The parent checks the temporary output file while the download is running, stops it when it exceeds 2 MiB, and checks the completed file again before reading it. The check is periodic, so a fast response can temporarily exceed the limit between polls; this is not a strict disk or worker-memory quota.

- **API Key Scrubbing:** `Invoke-ShellCommand` clears `SHELLOSSUS_API_KEY`, legacy `H_AGENT_API_KEY`, and `OPENAI_API_KEY` before spawning a child PowerShell process and restores them afterward. Other environment variables remain available, and commands can still read files allowed by the OS, including a saved `.env` key.
- **Disk-Backed Output Streaming:** Standard output and standard error are redirected directly to temporary files on disk (`Start-Process -RedirectStandardOutput -RedirectStandardError`). Only the first 300 lines (up to 20,000 characters) are read into memory for the model response; if truncated, the full log is preserved under `.shellossus/output/cmd-*.log`.
- **Timeout & Termination:** Commands default to a 60-second timeout (`timeout_sec`, configurable from 1 to 600 seconds). While waiting, `shellossus` tracks child and descendant processes. On timeout or interrupted execution it stops the command and tracked descendants using built-in cmdlets. Windows PowerShell 5.1 uses `Get-CimInstance Win32_Process` for parent relationships; PowerShell on Linux/macOS uses `Get-Process`. Start times are checked before termination to avoid stopping an unrelated process that reused a PID. Timeout results include `termination_errors` if cleanup could not be completed.
- **Process Tracking Limits:** Tracking is based on periodic snapshots, not an OS process sandbox. A detached descendant whose parent exits between snapshots can escape discovery; command execution retains the user's OS permissions. Normal successful commands may intentionally leave background processes running.

## Subagent Tool Restrictions

In-process and separate-process subagents receive the intersection of the parent's effective tool permissions and the role's tool filter. Parent exclusions, aliases, and wildcard filters are respected. An empty intersection disables all tools; it never means unrestricted access. Parallel workers remain `ReadOnly`, and recursive `run_agent` calls are disabled.

---

## Enterprise / Citrix / VDI Notes

- `shellossus` does **not** modify `ExecutionPolicy`, language mode, or system security settings.
- Windows PowerShell 5.1 and `ConstrainedLanguage` are supported targets. CI runs the smoke suite on Windows PowerShell 5.1, including dedicated constrained-language runs for `Doctor.Tests.ps1`, `Reliability.Tests.ps1`, and `ConstrainedLanguage.Tests.ps1` (see [verification coverage](architecture.md#build--verification-pipeline)).
- Use `shellossus -Doctor` before starting a chat, or `/doctor` in a session, for runtime, settings, storage, and endpoint checks. The authenticated `/models` probe does not generate a completion or verify model tool support. Reports hide the key but include local paths, validated API base URLs, and model IDs; review those before sharing.
- The user API key is stored in plain text in `%USERPROFILE%\.shellossus\.env` (outside the project directory). Do not commit `.env` files or share terminal recordings taken during `shellossus -Setup`.
