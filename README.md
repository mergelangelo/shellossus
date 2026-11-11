# Zero Dependencies. One File. Full Agent Power.
### Pure PowerShell 5.1+ Coding Agent for Desktops & Servers

**No Python. No Node.js. No third-party modules.** `shellossus` runs on PowerShell itself — built into every Windows machine by default, and available on Linux and macOS via `pwsh`.

Drop [`shellossus.ps1`](shellossus.ps1) onto any workstation, jump host, or Citrix/VDI session and connect to any OpenAI-compatible API (cloud providers, internal corporate gateways, or local `Ollama` / `vLLM` servers).

---

## Why `shellossus`?

- **Runs Where Nothing Else Can:** Engineered natively for **Windows PowerShell 5.1**, PowerShell 7+, **`ConstrainedLanguage` mode**, AppLocker, and WDAC — with zero external binaries (`rg`, `fd`, `git`, `curl`) or PowerShell Gallery dependencies.
- **Modular Engineering, Single-File Artifact:** Maintained across 36 focused modules in [`src/`](src/) and bundled by [`build.ps1`](build.ps1) into one pure 7-bit ASCII script ([`shellossus.ps1`](shellossus.ps1)) that parses identically regardless of BOM or system codepage and is trivial to audit or copy.
- **Transactional & Fail-Closed by Design:** Starts in `Ask` mode by default, stages every edit, preserves file encodings/BOMs, verifies backups by byte hash, supports conflict-aware multi-step `/undo`, and rejects truncated responses or incomplete SSE streams before modifying state.
- **Full Agent Depth, Zero Vendor Lock-In:** Combines 13 built-in tools, subagents (`single`, `parallel[]`, `pipeline[]`), DAG session branching (`/tree`, `/fork`), structured `/compact`, layered Markdown customization (`SOUL.md`, `AGENTS.md`, `MEMORY.md`, `SKILL.md`), a 24-bit TrueColor TUI, and headless JSONL streaming over standard `/v1/chat/completions`.

---

## Quick Start

### 1. Install Launcher & Configure

Copy [`shellossus.ps1`](shellossus.ps1) (or clone the repository) into a permanent folder and register the launcher in your PowerShell `$PROFILE`:

```powershell
.\shellossus.ps1 -Install
# Optional non-interactive shortcut registration:
.\shellossus.ps1 -Install -Shortcut s
```

Open a new PowerShell window and configure your API base URL (HTTPS, or `http://localhost` for local servers), model ID, and masked API key (stored outside your repository in `%USERPROFILE%\.shellossus\.env`, or supplied at runtime via `$env:SHELLOSSUS_API_KEY`):

```powershell
shellossus -Setup
```

### 2. Verify Setup

Run the non-mutating health check to validate runtime compatibility, configuration privacy, workspace/session storage, and `GET /models` reachability:

```powershell
shellossus -Doctor
```

### 3. Run in Any Project

```powershell
cd C:\path\to\project
shellossus
```

Common launch modes (see the [full CLI & `.env` reference](docs/cli.md)):

```powershell
shellossus -Continue                                # Resume latest session for this workspace
shellossus -Permission AutoEdit                     # Auto-approve file edits; confirm shell commands
shellossus -Stream                                  # Assemble responses over SSE for strict gateways
shellossus -Prompt "Explain @src/tools/Files.ps1"   # Single-shot non-interactive execution
shellossus -Mode json -NoSession -Prompt "Audit @." # Machine-readable JSONL event stream
```

---

## Capabilities at a Glance

| Area | What Is Built In |
| :--- | :--- |
| **13 Native Tools** | `list_files`, `read_file` (line & char pagination), `find_files` (`.gitignore`-aware globs), `grep_files` (regex/literal + continuation), `write_file`, `edit_file` (fuzzy + batch `edits[]`), `run_command`, `run_agent`, `fetch_url`, `web_search`, `todo`, `ask_user`, and `memory` ([tool reference](docs/architecture.md#built-in-tool-reference)) |
| **Subagent Delegation** | Built-in roles (`recon`, `audit`, `craft`) + custom `agents/*.md` profiles, single/parallel/pipeline orchestration, `/agent:<role> <task>`, and unified parent `/undo` |
| **4 Permission Modes** | `ReadOnly` (inspection only), `Ask` *(default: diff & command prompts)*, `AutoEdit` (auto-approves writes; gates shell), and `Auto` ([permission guide](docs/security.md#permission-modes)) |
| **Safe Edits & `/undo`** | Atomic staged writes, UTF-8 / UTF-16 BOM & line-ending preservation, manual-edit conflict detection, automatic turn rollback, and task-board/memory restoration |
| **Session Tree & Compaction** | Workspace-scoped `.jsonl` DAG sessions, branch switching (`/tree`), forking (`/fork`), standalone themed HTML export (`/export`), and constraint-preserving `/compact` |
| **Layered Customization** | Local & global `AGENTS.md` (including path-scoped nested rules), `SOUL.md` persona/ethos, `MEMORY.md` long-term notes, `SYSTEM.md` / `APPEND_SYSTEM.md`, `SKILL.md` skills, and `/<template>` prompts ([customization guide](docs/customization.md)) |
| **24-bit Terminal UI** | 9 built-in TrueColor themes (`gruvbox-material` default), visible-width-aligned Markdown tables, collapsible `reasoning` blocks, interactive pickers, and pixel `/mascot` |

---

## Interactive Workflow

Call picker-enabled commands (`/permission`, `/model`, `/theme`, `/context`, `/reasoning`, `/sessions`, `/resume`) without arguments to open an interactive TUI selector. Full syntax and aliases are documented in [`docs/cli.md`](docs/cli.md).

| Command / Syntax | Purpose |
| :--- | :--- |
| `/help` (`?`, `/h`) · `/status` (`/s`) · `/doctor` | View commands, inspect context/token dashboard, or run health diagnostics |
| `/permission` (`/p`) · `/model` (`/m`) · `/theme` (`/th`) | Switch permission mode, active model ID, or 24-bit color theme |
| `/context` (`/ctx`) · `/reasoning` · `/compact` (`/c`) | Tune token budgets, control reasoning view/effort, or compact history |
| `/undo` (`/u`) · `/retry` · `/continue [steps]` | Revert the last turn, resend a failed prompt, or continue past `-MaxSteps` |
| `/todo` (`/td`) · `/memory` (`/mem`) · `/reload` | Manage task checklist, view/update `MEMORY.md` (`ws`/`global`), or reload rules |
| `/sessions` · `/resume` (`/r`) · `/tree` (`/t`) · `/fork` | Browse/resume workspace sessions, switch DAG branches, or fork a session |
| `/save [name]` · `/export [path]` · `/import <path>` · `/new` | Save, export standalone `.html`/`.jsonl`, import `.jsonl`, or start fresh |
| `/agents` · `/agent:<role> <task>` · `/skills` · `/skill:<name>` | Inspect or invoke subagent roles and `SKILL.md` domain skills |
| `/<template> [args]` · `@path/to/file` · `!cmd` / `!!cmd` | Expand prompt templates, attach workspace files, or run operator commands |

---

## Security & Undo Boundaries

- **Workspace File Boundary:** `list_files`, `read_file`, `find_files`, `grep_files`, `write_file`, `edit_file`, and `@file` attachments enforce the active workspace root (with a read-only exception for registered global `SKILL.md` files), reject symlinks/NTFS junctions, and block `.env` secrets and the active config file.
- **OS-Scoped Shell Execution:** `run_command`, `!cmd`, and `!!cmd` are **not** sandboxed — they start in the workspace directory and execute under your OS account and host policies (AppLocker/WDAC). Operator `!` / `!!` shortcuts run directly in every mode, including `ReadOnly`.
- **Conflict-Aware `/undo`:** Reverts recorded `write_file`, `edit_file`, and `memory` tool changes (including in-process subagent edits) along with conversation and `todo` state, and refuses to overwrite files edited manually after the agent's write. Shell commands, manual `/memory` edits, configuration changes, exports, and network requests are outside undo coverage.

See [`docs/security.md`](docs/security.md) for the complete boundary matrix, worker architecture, and resource caps.

---

## Repository Structure

```text
.
├── CONSTITUTION.md       # Non-negotiable architectural principles & invariants
├── AGENTS.md             # Repository rules for coding agents
├── SECURITY.md           # Vulnerability reporting policy & security summary
├── shellossus.ps1        # Standalone pure-ASCII artifact (built from src/*.ps1)
├── build.ps1             # Bundler & ASCII/LF sync verifier (.\build.ps1 [-Check])
├── src/
│   ├── Config.ps1        # SHELLOSSUS_* config I/O, ACL privacy, path & secret guards
│   ├── Theme.ps1         # 9 TrueColor palettes and box-drawing glyphs
│   ├── ui/               # Ansi framing/gauges, TUI Cards/diffs, Input/pickers, Markdown/tables
│   ├── tools/            # Schemas, validation, ignore walk, files, search, shell, undo, web, memory, agents
│   ├── context/          # Layered prompt builder, skills/roles catalog, templates, session DAG, compaction
│   ├── Doctor.ps1        # Non-mutating runtime, endpoint, catalog & storage diagnostics
│   ├── cli/              # Profile installer, HTTP/SSE worker, Turn loop, REPL cards & slash Commands
│   └── Cli.ps1           # Top-level CLI entrypoint, setup wizard, single-shot & REPL loop
├── tests/
│   ├── smoke.ps1         # Build check + modular suites + ConstrainedLanguage child runs
│   ├── TestHelpers.ps1   # Shared assertions and temporary workspace harness
│   └── *.Tests.ps1       # Config, Theme, Tools, Context, Cli, Doctor, Reliability, ConstrainedLanguage
├── docs/                 # Canonical documentation (cli, customization, security, architecture)
└── examples/             # Sample SOUL.md, MEMORY.md, subagent role, prompt template & skill
```

---

## Development & Verification

Edit modular files under [`src/`](src/), regenerate [`shellossus.ps1`](shellossus.ps1), and run the full verification suite:

```powershell
.\build.ps1
.\tests\smoke.ps1
```

---

## Documentation

| Document | Contents |
| :--- | :--- |
| **[CLI, Configuration & Automation](docs/cli.md)** | All launch flags, `SHELLOSSUS_*` `.env` settings, REPL commands & aliases, `-Doctor`, `-Stream`, and `-Mode json` events |
| **[Customization & Extensibility](docs/customization.md)** | System prompt stack, `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `SKILL.md`, subagent roles, prompt templates, `@file`, and `!cmd` |
| **[Security, Boundaries & Enterprise](docs/security.md)** | Permission modes, workspace vs. OS scope, staged writes & `/undo`, internal workers, resource limits, and Citrix/VDI/CLM notes |
| **[Architecture & Build Pipeline](docs/architecture.md)** | Dual-distribution design, 36-module map, turn lifecycle, 13-tool reference, and `smoke.ps1` verification |
| **[Project Constitution](CONSTITUTION.md)** | Core engineering invariants and non-negotiable design guarantees |
| **[Security Policy](SECURITY.md)** | Vulnerability disclosure process and response targets |

## License

[MIT](LICENSE)
