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
- **File Writes & Edits:** Must be explicitly approved by typing `WRITE`.
- **Command Execution:** Must be explicitly approved by typing `RUN`.
- **`ReadOnly` Mode:** Strips file write tools and shell execution tools entirely from the model's capabilities and rejects unauthorized invocations.

### 2. Workspace Boundary & Junction Rejection
- All file operations are resolved strictly against the workspace root.
- Ancestor directory paths are traversed and checked for symbolic links, NTFS junctions, and reparse points (`Attributes -band 1024`). Traversal outside the project boundary is strictly rejected.

### 3. Credential & Environment Protection
- `.env`, `.env.*` (excluding `.env.example`), and user profile configuration files are strictly forbidden from agent tools (`read_file`, `find_files`, `grep_files`, `@file`, `write_file`).
- Before executing commands via `run_command`, `SHELLOSSUS_API_KEY` and `OPENAI_API_KEY` are stripped from the child process environment to prevent key leakage.

### 4. Transactional Edits & Conflict-Aware `/undo`
- File modifications are staged to temporary files and verified prior to replacing target files on disk.
- Pre-edit backups are verified before touching disk.
- If a file is modified externally or manually after an agent edit, `/undo` detects the conflict and preserves both disk content and the backup file.

### 5. Process Lifecycle & Execution Timeout
- Shell commands run under configurable execution timeouts (default 60 seconds).
- Descendant process trees are tracked via parent PID maps to terminate runaway child processes upon timeout.

For in-depth security mechanics, refer to [`docs/security.md`](docs/security.md).
