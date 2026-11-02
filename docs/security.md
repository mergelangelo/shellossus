# Security, Permissions & Enterprise Guide

`h-agent` is designed for environments where installing third-party runtimes, binaries, or unverified PowerShell Gallery modules is prohibited or impractical.

---

## Permission Modes

You can set the permission mode at launch (`-Permission <Mode>`) or switch it at any time during a session (`/permission <Mode>`):

| Mode | Read & Search Tools | File Write & Edit Tools | Shell Execution (`run_command`) | Typical Use Case |
| --- | --- | --- | --- | --- |
| `ReadOnly` | Allowed | Hidden & blocked | Hidden & blocked | Code review, SQL/log analysis, architecture Q&A |
| `Ask` *(default)* | Allowed | Requires typing `WRITE` | Requires typing `RUN` | Safe everyday pair programming |
| `AutoEdit` | Allowed | Auto-approved (saves backup) | Requires typing `RUN` | Fast iterative coding while keeping shell commands gated |
| `Auto` | Allowed | Auto-approved (saves backup) | Auto-approved | Trusted automation or sandboxed environments |

When resuming a saved session via `/resume`, `h-agent` resets the active permission mode to `Ask` unless `-Permission` was explicitly passed at launch.

---

## Workspace Isolation & Path Safety

1. **Workspace Boundary Enforcement:**
   - Every tool path is resolved through `Resolve-AgentPath`.
   - Paths resolving outside the workspace directory are rejected (`Path is outside the workspace.`).
   - The only exception is read-only access (`read_file`) to `SKILL.md` files explicitly registered during startup by `Get-SkillsCatalog` from `%USERPROFILE%\.h-agent\skills`.
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
  - Every write records both `before_content` and `after_content`.
  - When `/undo` is invoked, `Invoke-AgentUndo` checks whether the file on disk was modified manually after the agent's write. If manual edits are detected, `/undo` refuses to overwrite the file and preserves the backup path.
  - Backup files are only deleted after restoration succeeds and the restored content is verified against the backup.

---

## Process Isolation & Command Timeouts

- **API Key Scrubbing:** `Invoke-ShellCommand` clears `H_AGENT_API_KEY` and `OPENAI_API_KEY` before spawning a child PowerShell process and restores them afterward.
- **Disk-Backed Output Streaming:** Standard output and standard error are redirected directly to temporary files on disk (`Start-Process -RedirectStandardOutput -RedirectStandardError`). Only the first 300 lines (up to 20,000 characters) are read into memory for the model response; if truncated, the full log is preserved under `.h-agent/output/cmd-*.log`.
- **Timeout & Termination:** Commands default to a 60-second timeout (`timeout_sec`, configurable from 1 to 600 seconds). If a command exceeds the timeout, `h-agent` terminates the process (`Stop-Process -Force`) and reports `status = "timed_out"`.

---

## Enterprise / Citrix / VDI Notes

- `h-agent` does **not** modify `ExecutionPolicy`, language mode, or system security settings.
- All code is tested in Windows PowerShell 5.1 under `ConstrainedLanguage` mode.
- The user API key is stored in plain text in `%USERPROFILE%\.h-agent\.env` (outside the project directory). Do not commit `.env` files or share terminal recordings taken during `h-agent -Setup`.
