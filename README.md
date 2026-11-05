# Zero Dependencies. One File. Full Agent Power.
### Pure PowerShell 5.1+ Agent for Desktops & Servers

**No Python. No Node.js. No third-party modules.** `shellossus` needs nothing but PowerShell itself — built into Windows by default, and available on Linux and macOS via `pwsh`.

Drop [`shellossus.ps1`](shellossus.ps1) onto any machine and connect to any OpenAI-compatible API (cloud, local Ollama/vLLM, or internal corporate gateway).

## Key Features

| Capability | What It Does |
| --- | --- |
| **13 Built-in Tools** | `list_files`, `read_file` (line & character pagination), `find_files` (path globs + `.gitignore`), `grep_files` (regex/literal, filters, context, `file_offset` + `start_line` continuation), `write_file`, `edit_file` (fuzzy matching + batch `edits[]`), `run_command`, `run_agent` (single, parallel, pipeline), `fetch_url`, `web_search`, `todo`, `ask_user`, and `memory` (workspace/global persistent notes). See the [tool reference](docs/architecture.md#built-in-tool-reference). |
| **Subagent Delegation** | Built-in roles (`recon`, `audit`, `craft`) + custom `.shellossus/agents/*.md` profiles, `/agents` catalog, `/agent:<role> <task>` shortcut, and unified parent `/undo` across subagent file edits |
| **4 Permission Modes** | `ReadOnly` (blocks model file edits, memory writes, and commands), `Ask` *(default: prompts `WRITE` / `RUN`)*, `AutoEdit` (auto-approves file writes with backup; asks `RUN`), `Auto` (auto-approves writes and commands) |
| **Verified File Edits & `/undo`** | Staged writes, diff previews, backups, and manual-edit conflict detection for `write_file` / `edit_file`, including in-process subagent edits. Shell commands and `memory` changes are outside undo coverage. |
| **First-Run Diagnostics** | `-Doctor` / `/doctor` explains runtime, configuration, endpoint, model catalog, and session storage problems without generating a model response |
| **Session Tree, Fork & Export** | Workspace-scoped `.jsonl` sessions (`-Continue`, `/sessions`, `/resume`), branch navigation (`/tree`), session forking (`/fork`), and standalone HTML export (`/export`) |
| **Smart Context Compaction** | Iterative structured handoffs (`/compact [focus]`) with cumulative `<read-files>` / `<modified-files>` tracking and automatic context-overflow recovery |
| **Context & Extensibility** | Auto-loads `AGENTS.md`, `SOUL.md` (ethos/persona), `MEMORY.md` (cross-session memory), `SYSTEM.md`, `APPEND_SYSTEM.md`, `skills/*/SKILL.md` (`/skill:name`), `/<template>` prompts (`$1`, `$@`, `${1:-default}`), `@file` attachments, and `!cmd` / `!!cmd` |
| **TrueColor Terminal UI & 9 Themes** | Built-in palettes (`gruvbox-material`, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `one-dark`, `rose-pine`, `kanagawa`, `catppuccin-latte`) with `/theme` picker, Markdown headings, lists, code blocks, auto-aligned tables, collapsible `reasoning` blocks, and `-Mode json` event streaming |
| **Enterprise & Lockdown Ready** | Pure ASCII single-script distribution (`shellossus.ps1`), NTFS junction/symlink boundary protection, `.env` secret blocking, and full `ConstrainedLanguage` mode compatibility |

## Quick Start

### 1. Install Launcher (One-Time)

Clone the repository or copy [`shellossus.ps1`](shellossus.ps1) into a permanent folder (e.g. `C:\Users\YOU\Tools\shellossus`), then run:

```powershell
.\shellossus.ps1 -Install
```

During installation, `-Install` always registers the full `shellossus` command and lets you pick an optional shortcut (`s`, `sss`, `shos`, a custom name, or no shortcut), verifying with `Get-Command -All` that the chosen shortcut does not conflict with existing commands. Non-interactive installation is also supported:

```powershell
.\shellossus.ps1 -Install -Shortcut s
.\shellossus.ps1 -Install -NoShortcut
```

Open a new PowerShell window and configure your API endpoint, model ID, and key (stored in `%USERPROFILE%\.shellossus\.env`, outside your project):

```powershell
shellossus -Setup
```

Check the setup before entering a chat (also works when configuration is missing or invalid):

```powershell
shellossus -Doctor
# Without the launcher: .\shellossus.ps1 -Doctor
shellossus -Doctor -Mode json             # One JSON report; exit 1 for failed checks
```

Doctor checks the PowerShell version and language mode, effective endpoint/model/key settings, workspace access, and session-directory create/write/rename/read/delete access. It creates the session directory if needed, removes its temporary probe, and skips storage checks with `-NoSession`. It sends one authenticated `GET <BaseUrl>/models` with a 10-second request timeout (DNS resolution can take longer); it does not follow redirects or generate a completion. Missing `/models` support, an unlisted model, or rate limiting produces a warning, not proof that chat is broken. A successful catalog lookup does not verify chat or tool-call support. Reports hide the API key and omit server response bodies; they still contain local paths, the validated API base URL, and the configured model ID.

Settings use the same precedence as normal startup: launch arguments for endpoint/model/workspace, then `SHELLOSSUS_*` environment variables, legacy `H_AGENT_*`, then the saved configuration. The API key comes from `SHELLOSSUS_API_KEY`, legacy `H_AGENT_API_KEY`, or the configuration file. Use an **HTTPS API base URL**, normally ending in `/v1`; local HTTP-only servers need an HTTPS gateway to work with the current CLI.

### 2. Run in Any Project

```powershell
cd C:\path\to\project
shellossus
```

Common launch flags:

```powershell
shellossus -Continue                        # Resume latest session for current workspace
shellossus -Permission AutoEdit             # Edit files without prompting; ask before shell commands
shellossus -Prompt "Explain @src/tools/Files.ps1" # Single-shot non-interactive mode
shellossus -Mascot                          # Display the 8x8 mascot without starting a chat
```

## Interactive Commands

| Command | Description |
| --- | --- |
| `/help` | List available interactive commands |
| `/status` | Show active model, permission mode, token estimate, and session path |
| `/doctor` | Check the current runtime, settings, endpoint/model catalog, and session storage |
| `/mascot` | Display the 8×8 mascot |
| `/permission <mode>` | Switch mode: `ReadOnly`, `Ask`, `AutoEdit`, `Auto` |
| `/diagnostics [on\|off]` | Show or toggle pre-request capability and tool diagnostics |
| `/reasoning <opt>` | Display: `compact`, `full`, `hide`; Effort: `low`, `medium`, `high`, `default` |
| `/continue [steps]` | Continue execution after hitting the step limit (or continue the last response) |
| `/undo` | Revert the last tracked turn and its `write_file` / `edit_file` changes; see coverage below |
| `/todo [clear]` (`/td`) | Display or clear active task plan checklist |
| `/retry` | Resend the last failed user prompt |
| `/compact [focus]` | Summarize older turns into a structured context handoff |
| `/name [name]` | Set or display the session name |
| `/tree [entry-id]` | Show the conversation tree or switch active branch to `<entry-id>` |
| `/fork [entry-id]` (`/clone`) | Fork the active branch (or from `<entry-id>`) into a new session file |
| `/export [path.html\|.jsonl]` | Export the session to a standalone Gruvbox Material HTML page or JSONL |
| `/import <path.jsonl>` | Import and resume a JSONL session file |
| `/copy` | Copy the last assistant message to the clipboard |
| `/memory [clear\|add ..]` (`/mem`) | View, clear, or record persistent cross-session memories in `MEMORY.md` |
| `/reload` | Reload context files (`AGENTS.md`, `SOUL.md`, `MEMORY.md`, `SYSTEM.md`), skills, and templates |
| `/hotkeys` | Show input shortcuts and syntax reference |
| `/model <id>` | Switch model ID for the current session |
| `/theme [name]` (`/th`) | Pick or switch color theme (`gruvbox-material`, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `one-dark`, `rose-pine`, `kanagawa`, `catppuccin-latte`) |
| `/sessions` | List recent saved sessions |
| `/resume <num\|name>` | Load a saved session |
| `/save [name]` | Save current session (optionally under a custom filename) |
| `/new` (`/clear`) | Start a fresh session |
| `/agents` | List built-in (`recon`, `audit`, `craft`) and custom subagent roles |
| `/agent:<role> <task>` | Delegate `<task>` to a specific subagent role |
| `/skill:<name> [args]` | Invoke a skill directly with arguments |
| `/<template> [args]` | Expand a prompt template from `.shellossus/prompts/<name>.md` (`$1`, `$@`, `${1:-default}`, `${@:2}`) |
| `@path/to/file` | Attach a workspace file inline into your prompt |
| `!cmd` / `!!cmd` | Execute a shell command (`!` appends output to context; `!!` is local-only) |
| `/exit` (`/quit`) | Quit `shellossus` |

## Workspace and Undo Boundaries

`list_files`, `read_file`, `find_files`, `grep_files`, `write_file`, `edit_file`, and `@file` attachments enforce workspace paths and reject reparse-point traversal. `read_file` can also read explicitly registered global `SKILL.md` files. **Shell commands are not sandboxed**: `run_command`, `!cmd`, and `!!cmd` start in the workspace but retain your OS permissions and can access other paths, programs, and the network. User-entered `!` / `!!` shortcuts run directly, without the model tool's permission prompt, including in `ReadOnly` mode.

`memory` has workspace and global scopes. Global notes live beside the active configuration file; memory writes are blocked in `ReadOnly` but currently do not ask for `WRITE` in other modes. Sessions, exports, temporary files, and global customization files also have paths outside the workspace. See the [full boundary and permission reference](docs/security.md).

`/undo` covers recorded `write_file` / `edit_file` changes in the active process, including in-process subagent edits. It checks backups and manual-edit conflicts before restoring files. It does **not** undo shell effects, `memory`, task-board state, settings, exports, network effects, or changes from other processes. Undo history is not restored by loading a saved session. A restore-time I/O failure can leave a partially restored turn; this is not a filesystem-wide transaction or a replacement for version control.

## Repository Structure

```text
.
├── CONSTITUTION.md     # Project constitution: core principles, safety guarantees, and invariants
├── SECURITY.md         # Vulnerability reporting policy and threat model
├── shellossus.ps1      # Standalone single-file distribution (built from src/*.ps1)
├── build.ps1           # Bundler and sync verifier (.\build.ps1 / .\build.ps1 -Check)
├── src/
│   ├── Config.ps1      # .env parser, workspace path boundary & reparse-point checks
│   ├── Theme.ps1       # Gruvbox Material RGB palette, status bar, and prompt frame
│   ├── ui/             # TUI cards/diffs (Cards), multiline/picker input (Input), Markdown/tables (Markdown)
│   ├── tools/          # Modular tools & schemas (Common, Schemas, Normalizers, Validation, Ignore, Files, Search, Shell, Undo, Web, Todo, AskUser, Memory, Agents, Dispatch)
│   ├── context/        # Prompt builder, skills/roles catalog, templates, session tree, persistence, compaction
│   ├── Doctor.ps1      # Runtime, endpoint, model catalog, and session storage diagnostics
│   ├── cli/            # Profile installer (Install), HTTP transport (Http), agent turn loop (Turn), REPL cards & pickers (Repl)
│   └── Cli.ps1         # CLI entrypoint, setup, single-shot execution, and interactive REPL loop
├── tests/
│   ├── smoke.ps1       # Test runner (.\build.ps1 -Check + all *.Tests.ps1 suites)
│   └── *.Tests.ps1     # Modular suites (Config, Theme, Tools, Context, Cli, Doctor, Reliability, ConstrainedLanguage)
├── docs/
│   ├── architecture.md # Internal design, module boundaries, and build pipeline
│   ├── security.md     # Permission model, workspace isolation, and enterprise notes
│   ├── customization.md# Guide to AGENTS.md, skills, prompt templates, and sessions
│   └── assets/         # Screenshots, screencasts, and terminal demos
└── examples/           # Sample agents, SOUL.md, prompt templates, and domain skills
```

## Development & Testing

Edit modular files under [`src/`](src/), rebuild [`shellossus.ps1`](shellossus.ps1), and run the smoke test suite:

```powershell
.\build.ps1
.\tests\smoke.ps1
```

## Documentation

- [Project Constitution](CONSTITUTION.md)
- [Security Policy](SECURITY.md)
- [Architecture & Build Pipeline](docs/architecture.md)
- [Security, Permissions & Enterprise Guide](docs/security.md)
- [Customization: AGENTS.md, Skills & Prompt Templates](docs/customization.md)

## License

[MIT](LICENSE)
