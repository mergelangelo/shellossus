# Security, Boundaries & Enterprise Guide

`shellossus` is engineered for environments where installing third-party runtimes, external CLI binaries, or unverified PowerShell Gallery modules is prohibited. Its security design relies on **explicit, fail-closed application boundaries** and **complete transparency about OS permissions**.

---

## Permission Modes

Set the permission mode at launch (`-Permission <Mode>`) or switch at any time during a session (`/permission <Mode>`):

| Mode | Read & Search Tools | File & Memory Writes (`write_file`, `edit_file`, `memory`) | Shell Execution (`run_command`) | Outbound Web (`fetch_url`, `web_search`) | Typical Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`ReadOnly`** | Allowed | Hidden & blocked (`memory view` allowed) | Hidden & blocked | Confirm per call (or `[a]ll`) | Code review, SQL/log analysis, architecture Q&A |
| **`Ask`** *(default)* | Allowed | Confirm (`y` / `a` / `WRITE`; `Enter` cancels) | Confirm (`y` / `a` / `RUN`; `Enter` cancels) | Confirm (`y` / `a` / `WEB`; `Enter` cancels) | Safe everyday pair programming |
| **`AutoEdit`** | Allowed | Auto-approved (with verified backup) | Confirm (`y` / `a` / `RUN`; `Enter` cancels) | Confirm (`y` / `a` / `WEB`; `Enter` cancels) | Fast iterative coding while gating shell commands |
| **`Auto`** | Allowed | Auto-approved (with verified backup) | Auto-approved | Auto-approved | Trusted automation or isolated sandboxes |

### Confirmation & State Transition Rules
- **Session Resume Reset:** Resuming or importing a session (`/resume`, `/import`) resets the active mode to `Ask` unless `-Permission` was explicitly passed at startup, and clears temporary `[a]ll` approvals.
- **Approval Revocation:** Switching to a stricter mode via `/permission` — or reselecting `ReadOnly`, `Ask`, or `AutoEdit` — clears session-scoped command and web `[a]ll` approvals. `/undo` preserves explicit `/permission` choices made after the reverted turn.
- **Non-Interactive JSON Mode:** In `-Mode json`, any action requiring interactive confirmation returns `status = "cancelled"` immediately without blocking on `Read-Host`.
- **Plan Review (`ask_user`):** Plan review sets `approved = true` only when the user selects an explicit approval option (`Approve`, `Yes`, `Ok`, `Okay`, or `Accept`, optionally suffixed with ` (Recommended)`). Free-text responses are returned as feedback, and plan approval never escalates `-Permission`.
- **Operator Shortcuts (`!cmd` / `!!cmd`):** User-typed `!` and `!!` commands are direct operator actions, not model tool calls; they execute immediately in all permission modes (including `ReadOnly`).

---

## Workspace Isolation & Path Safety

`shellossus` enforces an **application-level file-tool boundary**, not an OS kernel sandbox:

| Subsystem | Filesystem Boundary | Reparse-Point Check | Secret (`.env` / Config) Block |
| :--- | :--- | :--- | :--- |
| `list_files`, `find_files`, `grep_files`, `write_file`, `edit_file`, `@file` | Active workspace root only | Target + all ancestors (`Attributes -band 1024`) | Enforced |
| `read_file` | Workspace root + registered global `SKILL.md` files | Target + all ancestors | Enforced |
| `memory` (`MEMORY.md`) | Fixed paths: workspace (`MEMORY.md` or `.shellossus/MEMORY.md`) or global (`<ConfigDir>/MEMORY.md`) | Target + ancestors up to scope root | Blocks `$ConfigPath` |
| `run_command`, `!cmd`, `!!cmd` | Starts in workspace; **retains full user OS permissions** | Governed by OS / AppLocker / WDAC | Scrubs `SHELLOSSUS_API_KEY` & `OPENAI_API_KEY` env vars |
| Sessions, imports/exports, config, recovery, temp files | `<ConfigDir>/sessions`, explicit paths, `<ConfigDir>/recovery`, OS temp | Config & subagent prompt paths reject reparse points | Config parsed as plain data |

### Key Isolation Details
1. **Case-Accurate Path Matching:** `Test-AgentPathWithinRoot` and `Get-WorkspaceRelativePath` compare Windows drive paths (`C:\...`) case-insensitively (`OrdinalIgnoreCase`) and POSIX paths case-sensitively (`Ordinal`).
2. **NTFS Junction & Symlink Rejection:** `Resolve-AgentPath`, `Invoke-WorkspaceWalk`, `Get-SkillsCatalog`, and `Invoke-AgentMemory` reject symlinks, junctions, and reparse points (`Attributes -band 1024`). *(Note: application-level checks cannot prevent concurrent filesystem TOCTOU races by external processes.)*
3. **Explicit User `@file` Scope:** Only `@file` references present in the user's original prompt (or explicit slash-command arguments) attach workspace files. Model outputs, template bodies, and subagent task prompts are never auto-expanded into file attachments.
4. **Credential & Config Protection:**
   - `.env`, `.env.*` (except `.env.example`), and the active `-ConfigPath` are excluded from listings, searches, attachments, reads, and writes.
   - `Read-AgentConfig` parses only supported `SHELLOSSUS_*` key-value lines as inert text (never executing PowerShell expressions).
   - Before saving an API key, `Save-AgentConfig` rejects UNC/reparse paths and verifies private permissions on both the parent directory and staged file (SDDL/process-SID ACL verification on Windows; owner, mode `0600`, hardlink count, and non-writable ancestor checks on Unix).

---

## Safe File Writes & `/undo` Protection

### Transactional Staged Writes & Encoding Integrity
- **Staging & Verification:** `Invoke-AgentWrite` and `Invoke-AgentMemory` write updated content to a temporary file first, verify the staged content, confirm the target file did not change on disk during user confirmation, create a verified backup, and replace the target atomically via `Move-Item -Force`.
- **Encoding & BOM Preservation:** `write_file` and `edit_file` support UTF-8 (with or without BOM) and BOM-marked UTF-16 LE / UTF-16 BE. Existing files must round-trip byte-identically through their detected encoding before modification, preserving encoding, BOM, and `CRLF`/`LF` line endings. New files default to UTF-8 without BOM — except new `.ps1` files containing non-ASCII characters, which receive a UTF-8 BOM so Windows PowerShell 5.1 parses them cleanly.
- **Fail-Closed Memory Reads:** Unreadable existing `MEMORY.md` files abort modification rather than being treated as empty.

### Conflict-Aware `/undo` & Automatic Rollback
- **Turn Journal Scope:** Every turn records `write_file`, `edit_file`, and `memory` tool operations (including in-process subagent writes) alongside conversation and `todo` task-board snapshots. Shell commands, manual `/memory` commands, settings changes, session exports, and network calls are outside the journal.
- **Reverse-Chain Preflight:** Before `/undo` or turn-failure rollback modifies any file, `shellossus` validates the entire reverse sequence of operations and byte-hash backups (including repeated edits to the same file within one turn) and re-verifies workspace/reparse boundaries.
- **Manual-Edit Conflict Detection:** If a file on disk was modified externally after the agent's write, `/undo` aborts before overwriting user changes and preserves all backup files so conflicts can be inspected and retried.
- **Retention & Recovery Manifests:** Undo history is process-local (retaining the 20 newest frames). If an I/O error or conflict interrupts restoration mid-flight, `shellossus` keeps the backups, reports pending operations, and (on failed turn rollbacks) writes a JSON recovery manifest under `recovery/` beside the config/session directory (falling back to OS temporary storage).

---

## Process Execution & Command Timeouts

### Isolated Internal Workers (`http`, `web`, `subagent`)
Child PowerShell workers launch the host binary by absolute path from `$PSHOME` with `-NoProfile` and invoke `shellossus.ps1` via `-File -InternalWorker <mode>`. URLs, headers, API keys, and request bodies are passed via scoped environment variables and temporary UTF-8 data files rather than interpolated command code.

### Outbound Web Preflight (`fetch_url` & `web_search`)
- **SSRF & Redirect Blocking:** Before connecting, the `web` worker validates literal IPs and all resolved IPv4/IPv6 DNS records against loopback, link-local, RFC1918/ULA private, CGNAT, and metadata ranges, and disables HTTP redirects (`-MaximumRedirection 0`).
- **DNS Resolution in `ConstrainedLanguage`:** Uses Windows inbox `Resolve-DnsName` when available; falls back to the system `.NET` resolver only in `FullLanguage` mode, and fails closed for hostnames in `ConstrainedLanguage` when `Resolve-DnsName` is absent. *(Because the HTTP client resolves DNS independently after preflight, strict destination enforcement in hostile networks should additionally use an outbound proxy or firewall.)*
- **Download Cap:** The parent process polls the download file and terminates the worker if output exceeds **2 MiB**, re-verifying size after completion.

### Shell Execution (`run_command`)
- **API Key Scrubbing:** `SHELLOSSUS_API_KEY` and `OPENAI_API_KEY` are removed from the child process environment before spawning `run_command` (commands still retain OS-allowed access to disk and other environment variables).
- **Disk-Backed Output:** `stdout` and `stderr` stream directly to temporary files on disk. Up to 300 tail lines / 20,000 UTF-8 bytes are returned to the model; truncated runs preserve the complete log under `.shellossus/output/cmd-*.log`.
- **Timeout & Descendant Cleanup:** Commands default to a 60-second timeout (`1`..`600`s). Periodic PID/start-time snapshots (`Win32_Process` on Windows PowerShell 5.1, `Get-Process` on Unix) track child trees so timed-out or interrupted commands terminate tracked descendants without hitting recycled PIDs.

---

## Subagent Tool Restrictions

In-process and worker-process subagents receive the **strict intersection** of the parent session's active tool permissions and the subagent role's `tools` filter (an empty intersection disables all tools).
- `ReadOnly` subagents (`recon`, `audit`, `parallel[]` workers, or any subagent in a `ReadOnly` session) exclude `write_file`, `edit_file`, `run_command`, `memory`, `todo`, and `ask_user` (plus `fetch_url` and `web_search` in non-interactive JSON mode when web access is not auto-approved).
- Recursive delegation is blocked (`run_agent` depth is capped at `1`).

---

## Resource Limits

| Guardrail | Limit | Behavior When Reached |
| :--- | :--- | :--- |
| Tool calls per turn | `128` calls | Entire response batch is rejected before any call in it runs |
| Tool call arguments | `1 MiB` UTF-8 | Rejected prior to JSON parsing |
| Batch edits (`edit_file`) | `64` edits / call | Rejected during argument validation |
| Model HTTP response size | `8 MiB` | Worker terminated & response rejected before JSON/SSE parsing |
| Turn payload budget | `32 MiB` UTF-8 | Turn aborts cleanly across accepted responses + tool outputs |
| Model request timeout | `180`s default (`10`..`1800`s) | Retries transient failures within a `3600`s per-step wall-clock cap |
| SSE stream verification (`-Stream`) | `[DONE]` + `finish_reason` | Incomplete or error streams are rejected before state/tool changes |
| Web fetch size | `2 MiB` | Download worker stopped and rejected |
| Memory file (`MEMORY.md`) | `256 KiB` | Write rejected before staging |
| Session storage (`.jsonl`) | `32 MiB`, `10,000` records, `5,000` tree nodes | Rejects oversized writes/imports; start a fresh session via `/new` |
| Workspace traversal (`find_files`, `grep_files`) | `10,000` directory entries | Returns results with `truncated = true` metadata |
| Regex content scan (`grep_files`) | `100` ms / match, `10`s total scan | Stops cleanly with explicit timeout truncation metadata |

---

## Enterprise / Citrix / VDI Notes

- **Zero System Mutation:** `shellossus` never alters `ExecutionPolicy`, `LanguageMode`, registry keys, or system security policies.
- **Verified `ConstrainedLanguage` Support:** Tested in CI on Windows PowerShell 5.1 and cross-platform PowerShell 7 (`pwsh`), including dedicated child processes that lock `$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'` on line 1 prior to loading `shellossus.ps1`.
- **Pre-Flight Health Checks:** Run `shellossus -Doctor` (or `/doctor`) to validate runtime compatibility, endpoint connectivity, model visibility, and session directory ACLs without generating completions. Review local paths, base URLs, and model IDs in the output before sharing diagnostic logs externally.
