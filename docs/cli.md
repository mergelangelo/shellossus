# CLI, Configuration & Automation Reference

This document covers every launch parameter, configuration variable, interactive REPL command, diagnostic check, and headless JSONL event supported by [`shellossus.ps1`](../shellossus.ps1).

---

## Configuration & Precedence

Settings resolve in strict order from highest to lowest priority:

1. **CLI Launch Arguments** (`-BaseUrl`, `-Model`, `-Workspace`, `-RequestTimeoutSec`, `-Stream`, `-Theme`, `-ContextWindow`, `-CompactThreshold`, etc.)
2. **`SHELLOSSUS_*` Environment Variables**
3. **Configuration File** (`-ConfigPath`, defaulting to `%USERPROFILE%\.shellossus\.env` on Windows or `~/.shellossus/.env` on Linux/macOS)

The configuration file is parsed strictly as plain `KEY=VALUE` data (never evaluated as PowerShell code). Saving an API key via `-Setup` verifies private directory and file permissions first; omit the key during setup or set `SHELLOSSUS_API_KEY` in the environment to avoid storing a plaintext key on disk.

### Supported `SHELLOSSUS_*` Keys

| Key | Equivalent Flag | Default | Description |
| :--- | :--- | :--- | :--- |
| `SHELLOSSUS_BASE_URL` | `-BaseUrl` | *(required)* | OpenAI-compatible base URL (normally ending in `/v1`). Must use `https://`, or `http://localhost` / `127.0.0.1` / `[::1]` for local servers. |
| `SHELLOSSUS_MODEL` | `-Model` | *(required)* | Provider model or deployment ID. |
| `SHELLOSSUS_API_KEY` | *(env / `.env` only)* | `'local'` on loopback | Bearer token for the API endpoint. Never passed on the command line so process arguments do not expose secrets. |
| `SHELLOSSUS_WORKSPACE` | `-Workspace` | `.` (current dir) | Default project root directory when `-Workspace` is omitted. |
| `SHELLOSSUS_CONTEXT_WINDOW` | `-ContextWindow` | `128000` (`128k`) | Model context window budget (e.g. `128k`, `64k`, `200000`). |
| `SHELLOSSUS_COMPACT_THRESHOLD` | `-CompactThreshold` | `96000` (`75%`) | Token count or percentage (e.g. `80k`, `70%`) that triggers auto-compaction. |
| `SHELLOSSUS_REQUEST_TIMEOUT_SEC` | `-RequestTimeoutSec` | `180` | Per-request model HTTP timeout in seconds (`10`..`1800`). |
| `SHELLOSSUS_STREAM` | `-Stream` | `false` | Set `true` or `1` to assemble responses over SSE (`stream = true`) on gateways with strict idle read timeouts (`-Stream:$false` overrides). |
| `SHELLOSSUS_THEME` | `-Theme` | `gruvbox-material` | Active 24-bit TrueColor theme ID. |

---

## Launch Parameters

### Setup, Launcher & Diagnostics

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-Install` | off | Register `shellossus` (and an optional conflict-checked shortcut) in `$PROFILE`. |
| `-ProfilePath <path>` | `$PROFILE` | Target PowerShell profile file used by `-Install`. |
| `-Shortcut <name>` | interactive | Non-interactive shortcut name for `-Install` (e.g. `s`, `sss`, `shos`). |
| `-NoShortcut` | off | Skip registering a short alias during `-Install`. |
| `-Setup` | off | Interactive wizard to configure endpoint, model, masked API key, and default workspace. |
| `-ConfigPath <path>` | `~/.shellossus/.env` | Path to the `SHELLOSSUS_*` configuration file. |
| `-Doctor` | off | Run runtime, config, workspace, session-storage, and `GET /models` checks, then exit (`0` if all checks pass/warn, `1` on any failed check). |
| `-Mascot` | off | Render the 20x16 half-block pixel mascot and exit. |

### Connection, Execution & Permissions

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-BaseUrl <url>` | `$env:SHELLOSSUS_BASE_URL` | API base URL (e.g. `https://api.openai.com/v1` or `http://localhost:11434/v1`). |
| `-Model <id>` | `$env:SHELLOSSUS_MODEL` | Active model ID. |
| `-Workspace <dir>` | `.` | Active workspace boundary for file tools and command working directory. |
| `-Permission <mode>` | `Ask` | Tool permission mode: `ReadOnly`, `Ask`, `AutoEdit`, or `Auto` (see [`docs/security.md`](security.md)). |
| `-Prompt <text>` | `''` | Run a single prompt non-interactively and exit. Required when `-Mode json` is used without `-Doctor`. |
| `-LiteralPrompt` | off | Treat `-Prompt` as literal text without expanding `/template` commands or `@file` attachments. |
| `-Mode <text\|json>` | `text` | Output format: `text` (24-bit TUI) or `json` (machine-readable JSONL event stream). |
| `-Stream` | off | Assemble model responses over SSE (`stream = true`) across chat turns, compaction, and subagents. Responses are verified for terminal `[DONE]` and `finish_reason` before rendering or tool execution. |
| `-RequestTimeoutSec <n>` | `180` | Per-request model HTTP timeout (`10`..`1800`s). Transient retries within one step share a `3600`s wall-clock cap. |
| `-MaxSteps <n>` | `50` | Maximum model-tool loop iterations per turn (`1`..`500`). |
| `-MaxRepeatCalls <n>` | `3` | Loop-guard threshold (`1`..`50`) for identical tool calls without an intervening state change. For `N >= 2`, attempt `N` returns a warning (`N = 1` warns on the first repeat) and the next identical attempt stops the turn. |
| `-ReasoningEffort <lvl>` | provider default | Pass `reasoning_effort` (`low`, `medium`, `high`) to reasoning-capable models. |

### Sessions, Context & Tool Filtering

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-Continue` | off | Resume the most recent session belonging to the current workspace. |
| `-Session <name\|path>` | new session | Resume an existing workspace session file (or create a named `.jsonl` file). |
| `-Fork <name\|path>` | `''` | Fork an existing workspace session into a new session file at startup. |
| `-SessionName <text>` | `''` | Assign a human-readable display name to a new or forked session. |
| `-SessionDir <dir>` | `<ConfigDir>/sessions` | Directory where `.jsonl` session files are stored. |
| `-NoSession` | off | Ephemeral mode: do not create or write session `.jsonl` files on disk. |
| `-Export <path>` | `''` | Export the loaded session (or a `.jsonl` path) to standalone themed `.html` or `.jsonl` and exit. |
| `-ContextWindow <spec>` | `128k` | Context window size in tokens (accepts integers or `k` suffix, e.g. `64k`). |
| `-CompactThreshold <spec>`| `96k` | Auto-compaction threshold in tokens or percentage (e.g. `80k` or `75%`). |
| `-Tools <csv>` | all mode-allowed | Allowlist of tool names or wildcards (e.g. `read_file,grep_files`). |
| `-ExcludeTools <csv>` | none | Denylist of tool names to remove from the session. |
| `-NoTools` | off | Disable all model tools (pure chat completion mode). |
| `-NoContextFiles` | off | Skip automatic loading of `SYSTEM.md`, `APPEND_SYSTEM.md`, `AGENTS.md`, `SOUL.md` (and aliases), and `MEMORY.md`. |
| `-NoSkills` | off | Disable discovery and `/skill:<name>` invocation of `SKILL.md` files. |
| `-NoPromptTemplates` | off | Disable discovery and `/<template>` expansion of `.shellossus/prompts/*.md`. |
| `-Theme <id>` | `gruvbox-material` | Palette: `gruvbox-material`, `catppuccin-mocha`, `tokyo-night`, `dracula`, `nord`, `one-dark`, `rose-pine`, `kanagawa`, `catppuccin-latte`. |
| `-HideReasoning` | off | Start with model reasoning output hidden (`compact` is default). |
| `-Diagnostics` | off | Enable pre-request capability and tool-sync diagnostics. |

*(Internal switches `-LibraryOnly` and `-InternalWorker` are reserved for test harnesses and isolated worker subprocesses.)*

---

## Interactive REPL Commands & Input Syntax

Commands marked with *(picker)* open an interactive TUI selector when called without arguments.

### Mode, Model & Diagnostics

| Command | Short Alias | Description |
| :--- | :--- | :--- |
| `/help` | `?`, `/?`, `/h`, `/hotkeys` | Show the TUI command and input syntax card. |
| `/permission [mode]` | `/p`, `/perm` | *(picker)* Switch mode: `ReadOnly`, `Ask`, `AutoEdit`, `Auto`. |
| `/model [id]` | `/m` | *(picker)* Switch active model ID (also updates `SHELLOSSUS_MODEL` if saved). |
| `/theme [id]` | `/th` | *(picker)* Switch 24-bit color theme. |
| `/context [win] [comp]` | `/ctx` | *(picker)* Set context window and auto-compaction threshold (e.g. `/ctx 128k 80k` or `/ctx 128k 70%`). |
| `/reasoning [opt]` | `/thinking` | *(picker)* View mode (`compact`, `full`, `hide`) or API effort (`low`, `medium`, `high`, `default`). |
| `/status` | `/s`, `/tokens`, `/session` | Display active model, permission badge, context gauge, token usage, session leaf, and tools. |
| `/diagnostics [on\|off]` | — | Show or toggle pre-request capability diagnostics. |
| `/doctor` | — | Run runtime, endpoint, model catalog, and session storage checks in-place. |
| `/mascot` | — | Render the pixel mascot card. |

### Turn Control, Undo, Tasks & Memory

| Command | Short Alias | Description |
| :--- | :--- | :--- |
| `/undo` | `/u` | Revert the last tracked turn (file edits, subagent edits, `memory` tool writes, conversation, and `todo` board). |
| `/retry` | — | Resend the last failed user prompt (including its original `@file` attachments). |
| `/continue [steps]` | — | Continue execution after hitting `-MaxSteps` (1..500 steps) or continue from the last message. |
| `/compact [focus]` | `/c` | Summarize older history into a structured handoff (optionally guided by `<focus>`). |
| `/todo [clear]` | `/td`, `/todos` | Display or clear the active session task checklist. |
| `/memory [scope] [cmd]` | `/mem` | Manage `MEMORY.md` across `workspace` (`ws`/`-w`), `global` (`g`/`-g`), or `all`: `view`, `add <text>`, `set <text>`, `clear`. |
| `/copy` | — | Copy the last assistant message to the system clipboard. |
| `/reload` | — | Reload `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `SYSTEM.md`, skills, and prompt templates from disk. |

### Sessions & Conversation Tree

| Command | Short Alias | Description |
| :--- | :--- | :--- |
| `/sessions` | — | *(picker)* Browse and resume saved sessions for the current workspace. |
| `/resume [num\|name]` | `/r` | *(picker)* Resume a workspace session by list number or filename. |
| `/tree [entry-id]` | `/t` | Inspect the conversation DAG or switch the active branch to `<entry-id>`. |
| `/fork [entry-id]` | `/clone` | Fork the active branch (or from `<entry-id>`) into a new session file. |
| `/name [text]` | — | Display or set the current session's human-readable name. |
| `/save [name]` | — | Save the current session (optionally under a custom `.jsonl` filename). |
| `/export [path]` | `/share` | Export the session to standalone themed `.html` (default) or `.jsonl`. |
| `/import <path.jsonl>` | — | Validate, import, and resume a workspace-matching `.jsonl` session file. |
| `/new` | `/clear` | Start a fresh session and reset temporary approvals. |
| `/exit` | `/quit`, `/q` | Exit `shellossus`. |

### Delegation, Skills & Prompt Input Syntax

| Syntax | Behavior |
| :--- | :--- |
| `/agents` | List built-in (`recon`, `audit`, `craft`) and custom `.shellossus/agents/*.md` subagent roles. |
| `/agent:<role> <task>` | Delegate `<task>` directly to a subagent role. |
| `/skills` | List discovered workspace and global `SKILL.md` skills. |
| `/skill:<name> [args]` | Inject a skill's instructions directly into the turn with optional arguments. |
| `/<template> [args]` | Expand `.shellossus/prompts/<template>.md` or `~/.shellossus/prompts/<template>.md`. |
| `@path/to/file` | Attach the first 300 lines (up to 20,000 chars) of a workspace file inline. |
| `!command` | Run a PowerShell command immediately and append its exit code + output to conversation context. |
| `!!command` | Run a PowerShell command locally in the terminal without adding output to context. |
| `""" ... """` / `` ``` ... ``` `` / `<<< ... >>>` | Multi-line fenced input block. Multi-line clipboard pastes and trailing `\` line continuations are also joined automatically. |

---

## First-Run Diagnostics (`-Doctor` / `/doctor`)

`shellossus -Doctor` validates the local environment before entering a chat session (even when configuration is missing or invalid):

- **Checked (`checks`):** PowerShell version, `LanguageMode`, configuration syntax and key-storage privacy, request timeout and stream settings, workspace accessibility and reparse-point safety, session directory create/write/rename/read/delete probe (skipped with `-NoSession`), API key presence, model ID presence, and one non-redirecting authenticated `GET <BaseUrl>/models` probe (10-second request timeout; DNS resolution is OS-governed).
- **Warnings vs. Failures:** Connectivity failures, TLS/redirect errors, and HTTP `401`/`403`/`407`/`5xx` fail the check (`exit 1`). Optional `/models` routes returning `404`/`405`/`501`, rate limiting (`429`), or deployment aliases omitted from `/models` produce warnings (`exit 0`).
- **Explicitly Untested (`not_tested`):** Background `POST /chat/completions` worker round-trips (`chat_transport`), model completion/tool-calling behavior (`chat_contract`), and `fetch_url` / `web_search` in `ConstrainedLanguage` (`web_tools`).
- **Redaction:** Reports redact the API key and omit raw server bodies/headers, while displaying local paths, the validated base URL, and the model ID.

---

## Headless Automation & JSONL Mode (`-Mode json`)

Combine `-Prompt` with `-Mode json` for scripts, CI pipelines, and editor integrations:

```powershell
.\shellossus.ps1 -Mode json -NoSession -Permission ReadOnly -Prompt "Summarize @README.md"
```

In `json` mode, `stdout` emits strictly valid, ASCII-escaped JSONL objects (one per line) with all TUI prompts suppressed. Any tool call requiring interactive confirmation immediately returns `status = "cancelled"` unless permitted by `-Permission AutoEdit` or `-Permission Auto`.

| Event `type` | Emitted When | Key Payload Fields |
| :--- | :--- | :--- |
| `diagnostics` | Pre-turn diagnostics (`-Diagnostics`) or config key-storage warning | `check` / capability sync fields |
| `turn_start` | Before each model step in a turn | `model`, `step` |
| `message_end` | Model response validated and accepted | `role`, `content`, `tool_calls` |
| `tool_execution_start` | Before a tool call executes | `id`, `name` |
| `tool_execution_end` | After a tool call completes (or loop-guard triggers) | `id`, `name`, `result` (JSON string) |
| `turn_end` | Turn finishes or aborts | `status` (`completed`, `error`, `loop_detected`, `step_limit_reached`), `step`, `usage_input_tokens`, `usage_output_tokens`, `error` / `rollback_error` / `recovery_manifest` |
| `doctor` | `shellossus -Doctor -Mode json` | `checks`, `not_tested`, `failures`, `warnings`, `exit_code` |
