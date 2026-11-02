# Zero Dependencies. One Script. Full Agent Power.
### 100% Native PowerShell Agent for Windows PowerShell 5.1+

**No Python. No Node.js. No external modules or binaries.** While other agents demand heavy runtimes, `h-agent` runs out of the box on every Windows machine.

Drop a single `.ps1` file onto any Windows desktop or server and connect to any OpenAI-compatible API (cloud, local Ollama/vLLM, or internal corporate gateway).

## Key Features

| Capability | What It Does |
| --- | --- |
| **7 Built-in Tools** | `list_files`, `read_file` (line & character pagination), `find_files` (path globs + `.gitignore`), `grep_files` (regex/literal, `include` filter, `context_lines`, file-offset pagination), `write_file`, `edit_file` (fuzzy whitespace/quote matching + atomic batch `edits[]`), and `run_command` (timeout, streaming disk logs, API key scrubbing) |
| **4 Permission Modes** | `ReadOnly` (reads/search only), `Ask` *(default: prompts `WRITE` / `RUN`)*, `AutoEdit` (auto-approves file writes with backup; asks `RUN`), `Auto` (auto-approves writes and commands) |
| **Transactional Disk `/undo`** | Staged writes via temporary files with verification, colored diff previews, automatic backups, manual-edit conflict detection, and full multi-step disk rollback via `/undo` |
| **Session Tree, Fork & Export** | Workspace-scoped `.jsonl` sessions (`-Continue`, `/sessions`, `/resume`), branch navigation (`/tree`), session forking (`/fork`), and standalone HTML export (`/export`) |
| **Smart Context Compaction** | Iterative structured handoffs (`/compact [focus]`) with cumulative `<read-files>` / `<modified-files>` tracking and automatic context-overflow recovery |
| **Context & Extensibility** | Auto-loads `AGENTS.md`, `CLAUDE.md`, `SYSTEM.md`, `APPEND_SYSTEM.md`, `skills/*/SKILL.md` (`/skill:name`), `/<template>` prompts (`$1`, `$@`, `${1:-default}`), `@file` attachments, and `!cmd` / `!!cmd` |
| **TrueColor Terminal UI** | `sainnhe/gruvbox-material` (dark medium) palette with Markdown headings, lists, code blocks, auto-aligned tables, collapsible `reasoning` blocks, and `-Mode json` event streaming |
| **Enterprise & Lockdown Ready** | Pure ASCII single-script distribution (`h-agent.ps1`), NTFS junction/symlink boundary protection, `.env` secret blocking, and full `ConstrainedLanguage` mode compatibility |

## Quick Start

### 1. Install Launcher (One-Time)

Clone the repository or copy [`h-agent.ps1`](h-agent.ps1) and [`install.ps1`](install.ps1) into a permanent folder (e.g. `C:\Users\YOU\Tools\h-agent`), then run:

```powershell
.\install.ps1
```

Open a new PowerShell window and configure your API endpoint, model ID, and key (stored in `%USERPROFILE%\.h-agent\.env`, outside your project):

```powershell
h-agent -Setup
```

### 2. Run in Any Project

```powershell
cd C:\path\to\project
h-agent
```

Common launch flags:

```powershell
h-agent -Continue                        # Resume latest session for current workspace
h-agent -Permission AutoEdit             # Edit files without prompting; ask before shell commands
h-agent -Prompt "Explain @src/Tools.ps1" # Single-shot non-interactive mode
```

## Interactive Commands

| Command | Description |
| --- | --- |
| `/help` | List available interactive commands |
| `/status` | Show active model, permission mode, token estimate, and session path |
| `/permission <mode>` | Switch mode: `ReadOnly`, `Ask`, `AutoEdit`, `Auto` |
| `/reasoning <opt>` | Display: `compact`, `full`, `hide`; Effort: `low`, `medium`, `high`, `default` |
| `/undo` | Revert last turn in conversation and restore modified/created files on disk |
| `/retry` | Resend the last failed user prompt |
| `/compact [focus]` | Summarize older turns into a structured context handoff |
| `/name [name]` | Set or display the session name |
| `/tree [entry-id]` | Show the conversation tree or switch active branch to `<entry-id>` |
| `/fork [entry-id]` (`/clone`) | Fork the active branch (or from `<entry-id>`) into a new session file |
| `/export [path.html\|.jsonl]` | Export the session to a standalone Gruvbox Material HTML page or JSONL |
| `/import <path.jsonl>` | Import and resume a JSONL session file |
| `/copy` | Copy the last assistant message to the clipboard |
| `/reload` | Reload `AGENTS.md`, `CLAUDE.md`, `SYSTEM.md`, skills, and prompt templates |
| `/hotkeys` | Show input shortcuts and syntax reference |
| `/model <id>` | Switch model ID for the current session |
| `/sessions` | List recent saved sessions |
| `/resume <num\|name>` | Load a saved session |
| `/save [name]` | Save current session (optionally under a custom filename) |
| `/new` (`/clear`) | Start a fresh session |
| `/skill:<name> [args]` | Invoke a skill directly with arguments |
| `/<template> [args]` | Expand a prompt template from `.h-agent/prompts/<name>.md` (`$1`, `$@`, `${1:-default}`, `${@:2}`) |
| `@path/to/file` | Attach a workspace file inline into your prompt |
| `!cmd` / `!!cmd` | Execute a shell command (`!` appends output to context; `!!` is local-only) |
| `/exit` (`/quit`) | Quit `h-agent` |

## Repository Structure

```text
.
├── CONSTITUTION.md     # Project constitution: core principles, safety guarantees, and invariants
├── h-agent.ps1         # Standalone single-file distribution (built from src/*.ps1)
├── build.ps1           # Bundler and sync verifier (.\build.ps1 / .\build.ps1 -Check)
├── install.ps1         # PowerShell profile launcher installer
├── src/
│   ├── Config.ps1      # .env parser, workspace path boundary & reparse-point checks
│   ├── Theme.ps1       # Gruvbox Material RGB palette, Markdown & table renderer
│   ├── Tools.ps1       # Tool schemas, argument validator, file I/O, undo, shell runner
│   ├── Context.ps1     # System prompt builder, skills, templates, sessions, compaction
│   └── Cli.ps1         # Agent turn loop, retry/overflow recovery, interactive REPL
├── tests/
│   ├── smoke.ps1       # Test runner (.\build.ps1 -Check + all *.Tests.ps1 suites)
│   └── *.Tests.ps1     # Modular suites (Config, Theme, Tools, Context, Cli, ConstrainedLanguage)
├── docs/
│   ├── architecture.md # Internal design, module boundaries, and build pipeline
│   ├── security.md     # Permission model, workspace isolation, and enterprise notes
│   └── customization.md# Guide to AGENTS.md, skills, prompt templates, and sessions
└── examples/           # Sample prompt templates and skills
```

## Development & Testing

Edit modular files under [`src/`](src/), rebuild [`h-agent.ps1`](h-agent.ps1), and run the smoke test suite:

```powershell
.\build.ps1
.\tests\smoke.ps1
```

## Documentation

- [Project Constitution](CONSTITUTION.md)
- [Architecture & Build Pipeline](docs/architecture.md)
- [Security, Permissions & Enterprise Guide](docs/security.md)
- [Customization: AGENTS.md, Skills & Prompt Templates](docs/customization.md)

## License

[MIT](LICENSE)
