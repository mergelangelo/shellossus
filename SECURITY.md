# Security Policy

`shellossus` is a local coding assistant designed for enterprise environments and locked-down Windows desktops (Citrix, VDI, restricted bastion hosts). Because `shellossus` executes shell commands and modifies workspace files, security, isolation boundaries, and privilege control are core design invariants.

---

## Reporting a Vulnerability

If you discover a security vulnerability or unintended privilege escalation in `shellossus`, please report it privately:

1. **GitHub Security Advisory (Recommended):** Submit a confidential vulnerability report via [GitHub Security Advisories](https://github.com/mergelangelo/shellossus/security/advisories/new).
2. **Direct Contact:** If GitHub Security Advisories is inaccessible, contact the project maintainers via the email listed in repository metadata.

Please include:
- A detailed description of the potential vulnerability.
- Reproduction steps, proof-of-concept scripts, or configuration examples.
- The operating environment (Windows version, PowerShell edition, LanguageMode).

### Vulnerability Response SLA
- **Acknowledgment:** Within 48 hours.
- **Triage & Assessment:** Within 5 business days.
- **Remediation & Patching:** High-priority patches are released promptly upon validation. We follow coordinated disclosure and provide credit to reporters.

---

## Threat Model & Security Architecture

`shellossus` implements defense-in-depth principles across all components:

### 1. Permission Modes & Confirmation Prompts
By default, `shellossus` operates in **`Ask`** mode:
- **`write_file` / `edit_file`:** Must be explicitly approved by typing `WRITE` in `Ask` mode. The separate `memory` tool currently writes without this prompt in non-`ReadOnly` modes.
- **Command Execution:** Must be explicitly approved by typing `RUN`.
- **`ReadOnly` Mode:** Strips file write tools and shell execution tools entirely from the model's capabilities and rejects unauthorized invocations.
- User-entered `!cmd` / `!!cmd` shortcuts execute directly even in `ReadOnly`; this mode restricts model tools, not the user's explicit commands or session persistence.

### 2. Workspace Boundary & Junction Rejection
- Workspace file tools and `@file` attachments enforce the workspace boundary and reject ancestor reparse points. `read_file` also permits registered global `SKILL.md` files.
- Shell commands retain the user's OS permissions and are not confined to the workspace. Global `memory`, configuration/context loading, sessions, imports/exports, and temporary files have separate paths. `memory` does not provide the file tools' ancestor-path checks. See the [complete scope](docs/security.md#workspace-isolation--path-safety).

### 3. Credential & Environment Protection
- `.env`, `.env.*` (excluding `.env.example`), and user profile configuration files are strictly forbidden from agent tools (`read_file`, `find_files`, `grep_files`, `@file`, `write_file`).
- Before executing commands, `SHELLOSSUS_API_KEY`, `H_AGENT_API_KEY`, and `OPENAI_API_KEY` are stripped from the child environment. This does not prevent commands from reading credentials on disk or in other environment variables allowed by the OS.

### 4. Transactional Edits & Conflict-Aware `/undo`
- `write_file` / `edit_file` modifications are staged to temporary files and verified prior to replacing target files on disk.
- Pre-edit backups are verified before touching disk.
- If a file is modified externally or manually after an agent edit, `/undo` detects the conflict and preserves both disk content and the backup file.
- Shell effects, memory notes, task-board state, settings, exports, and network effects are outside undo coverage. Saved sessions do not restore undo history; an I/O error during restoration can leave a partial rollback.

### 5. Process Lifecycle & Execution Timeout
- Shell commands run under configurable execution timeouts (default 60 seconds).
- Descendant process trees are tracked via parent PID maps to terminate runaway child processes upon timeout.

For in-depth security mechanics, refer to [`docs/security.md`](docs/security.md).
