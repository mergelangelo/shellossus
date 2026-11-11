# Security Policy

`shellossus` is built for developer workstations, enterprise desktops, Citrix/VDI sessions, and locked-down Windows servers where installing third-party runtimes or binaries is prohibited. Because coding agents inspect files and can execute shell commands, explicit boundaries and fail-closed defaults are core architectural invariants.

---

## Reporting a Vulnerability

If you discover a security vulnerability, boundary bypass, or unintended privilege escalation in `shellossus`, please report it privately rather than opening a public issue:

1. **GitHub Security Advisories (Preferred):** Submit a private report via [GitHub Security Advisories](https://github.com/mergelangelo/shellossus/security/advisories/new).
2. **Direct Maintainer Contact:** If GitHub Security Advisories is unavailable, contact the maintainers via the address listed in the repository metadata.

Please include:
- A clear description of the issue and affected component (`src/...`).
- Minimal reproduction steps, proof-of-concept input, or configuration settings.
- Runtime details (OS version, Windows PowerShell 5.1 vs `pwsh` 7+, and `LanguageMode`).

### Response Targets
- **Acknowledgment:** Within 48 hours.
- **Triage & Assessment:** Within 5 business days.
- **Remediation:** Validated security fixes are prioritized for immediate patching under coordinated disclosure, with reporter credit upon request.

---

## Security Architecture Summary

`shellossus` enforces defense-in-depth at the application layer while remaining completely transparent about OS boundaries:

1. **Explicit Permission Gating (`Ask` by Default):**
   - Modifying file/memory operations (`write_file`, `edit_file`, `memory`), shell commands (`run_command`), and outbound web requests (`fetch_url`, `web_search`) require explicit user confirmation by default (`Enter` cancels; `-Mode json` cancels unapproved actions immediately).
   - `ReadOnly` mode hides and blocks model file writes, shell execution, and modifying `memory` actions. Operator-entered `!cmd` / `!!cmd` shortcuts remain direct user actions.
2. **Workspace File Boundary vs. OS Shell Scope:**
   - Workspace file tools and user `@file` attachments resolve strictly within the workspace root (with a read-only exception for registered global `SKILL.md` files) and reject symbolic links, NTFS junctions, and reparse points (`Attributes -band 1024`).
   - **Shell execution is not an OS sandbox:** `run_command`, `!cmd`, and `!!cmd` start in the workspace directory but execute with the user's OS permissions and host policies (such as AppLocker or WDAC).
3. **Credential & Configuration Isolation:**
   - `.env`, `.env.*` (except `.env.example`), and the active user configuration file (`-ConfigPath`) are blocked across all listing, search, read, attachment, and write tools.
   - Config files are parsed as inert `SHELLOSSUS_*` key-value pairs (never evaluated as PowerShell), key storage verifies private ACLs/file modes, and `SHELLOSSUS_API_KEY` / `OPENAI_API_KEY` are scrubbed from `run_command` child environments.
4. **Transactional Writes & Conflict-Aware `/undo`:**
   - File and `memory` tool writes stage content first, preserve encodings/BOMs, verify byte hashes, and create verified backups before atomic replacement.
   - `/undo` and automatic turn-failure rollback reverse recorded `write_file`, `edit_file`, and `memory` tool changes (including in-process subagent edits) and restore conversation and `todo` state, refusing to clobber manual user edits made after the agent's write. Shell commands, manual `/memory` commands, settings, exports, and network effects are outside undo coverage.
5. **Isolated Workers & Resource Caps:**
   - HTTP, web download, and parallel subagent workers launch `$PSHOME` PowerShell with `-NoProfile` in fixed `-InternalWorker` modes, enforcing SSRF DNS/IP preflight on web fetches, process-tree command timeouts, and strict payload/step/size budgets.

For the complete boundary table, permission rules, undo recovery mechanics, and enterprise / `ConstrainedLanguage` deployment details, see [`docs/security.md`](docs/security.md).
