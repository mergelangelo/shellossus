# Customization & Extensibility Guide

`shellossus` adapts to your team, repository, and workflow using plain Markdown files stored in your workspace (`.shellossus/` or project root) and your user configuration directory (`%USERPROFILE%\.shellossus\` on Windows, `~/.shellossus/` on Linux/macOS) — no plugins, SDKs, or external registries required.

---

## How the System Prompt Is Assembled

At session start (and whenever `/reload` is run), `Build-SystemPrompt` in [`src/context/Prompt.ps1`](../src/context/Prompt.ps1) assembles the active system instructions in a deterministic order:

1. **Base System Prompt** — Built-in minimalist instruction, or replaced by `.shellossus/SYSTEM.md` (workspace first, then `~/.shellossus/SYSTEM.md`).
2. **Live `<capabilities>` Block** — OS, PowerShell edition, `LanguageMode`, workspace root, active permission mode, and enabled tools (automatically kept in sync when `/permission` changes).
3. **`APPEND_SYSTEM.md`** — Global `~/.shellossus/APPEND_SYSTEM.md` followed by workspace `.shellossus/APPEND_SYSTEM.md`.
4. **Ethos & Persona (`<soul>`)** — Global and workspace `SOUL.md` (also recognizing `ETHOS.md` and `SHELLOSSUS.md`).
5. **Persistent Memory (`<memory>`)** — Global `~/.shellossus/MEMORY.md` and workspace `.shellossus/MEMORY.md` / `MEMORY.md` (auto-synced in place whenever memory changes).
6. **Project Instructions (`AGENTS.md`)** — Global `~/.shellossus/AGENTS.md` and workspace root `AGENTS.md` (plus on-demand nested `AGENTS.md` files along accessed file paths).
7. **Skills Catalog (`<available_skills>`)** — Compact `name` + `description` + `location` index of discovered `SKILL.md` files (skipped with `-NoSkills`).
8. **Subagent Roles Catalog (`<available_agents>`)** — Built-in (`recon`, `audit`, `craft`) and custom `agents/*.md` role profiles.

Passing **`-NoContextFiles`** skips layers 1 (`SYSTEM.md`), 3 (`APPEND_SYSTEM.md`), 4 (`SOUL.md`), 5 (`MEMORY.md`), and 6 (`AGENTS.md`, including nested directory rules) while preserving the built-in base prompt and `<capabilities>` enforcement. Context files are bounded (256 KiB file cap; `SOUL.md`, `MEMORY.md`, and root `AGENTS.md` truncate at 8,000 characters per file; nested `AGENTS.md` caps at 64 KiB) and reject symlinks/reparse points.

---

## 1. Project Rules (`AGENTS.md`)

Use `AGENTS.md` for concrete repository facts: build/test commands, runtime constraints, coding style, and directory invariants.

- **Startup Loading:** `~/.shellossus/AGENTS.md` (user-wide conventions) and `<workspace>/AGENTS.md` (repository rules).
- **Hierarchical Directory Scoping:** When the model calls `read_file`, `write_file`, or `edit_file` on a path inside subdirectories, `shellossus` walks intermediate directories from the workspace root down to the target's parent. If any nested `AGENTS.md` files exist along that path and have not yet been shown in the active branch, `shellossus` returns `status = "instructions_required"` with those scoped rules first so the model applies them and retries the call.

---

## 2. Agent Persona & Craftsmanship Ethos (`SOUL.md`)

Use `SOUL.md` (or aliases `ETHOS.md` / `SHELLOSSUS.md`) to shape *how* the agent thinks and communicates — e.g., terse systems-engineering tone, surgical diffs, or domain-specific review rigor.

Loaded in order and wrapped in `<soul source="...">` blocks:
1. `~/.shellossus/SOUL.md` (`ETHOS.md`, `SHELLOSSUS.md`)
2. `<workspace>/.shellossus/SOUL.md` (`ETHOS.md`, `SHELLOSSUS.md`)
3. `<workspace>/SOUL.md` (`ETHOS.md`, `SHELLOSSUS.md`)

See [`examples/SOUL.md`](../examples/SOUL.md) for a ready-to-use template.

---

## 3. Persistent Cross-Session Memory (`MEMORY.md`)

`MEMORY.md` gives `shellossus` durable memory across separate CLI sessions without external vector databases:

- **Workspace Scope:** Uses `<workspace>/MEMORY.md` if it already exists; otherwise creates/updates `<workspace>/.shellossus/MEMORY.md`.
- **Global Scope:** Uses `MEMORY.md` alongside the active config file (normally `~/.shellossus/MEMORY.md`).
- **Model Tool (`memory`):** Supports `view`, `append`, `set`, and `clear` across `workspace` or `global` scope. Modifying calls are blocked in `ReadOnly`, prompt for confirmation in `Ask` mode, enforce a 256 KiB cap, and join the turn's `/undo` journal.
- **Interactive Slash Command (`/memory` or `/mem`):**
  ```text
  /memory                          # View workspace memory
  /memory global                   # View global memory
  /memory all                      # View both workspace and global memory
  /memory add Prefer pure ASCII    # Append a bullet to workspace memory
  /memory global add Concise tone  # Append a bullet to global memory
  /memory set <full markdown>      # Replace workspace memory content
  /memory clear [workspace|global] # Delete the target memory file
  ```

See [`examples/MEMORY.md`](../examples/MEMORY.md).

---

## 4. System Prompt Overrides (`SYSTEM.md` & `APPEND_SYSTEM.md`)

- **Replace Base Identity (`SYSTEM.md`):** Place `.shellossus/SYSTEM.md` in the workspace (takes precedence) or `SYSTEM.md` in `~/.shellossus/`. The live `<capabilities>` block is still appended automatically so permission and tool state remain accurate.
- **Extend Base Instructions (`APPEND_SYSTEM.md`):** Place `APPEND_SYSTEM.md` in `~/.shellossus/` and/or `<workspace>/.shellossus/` to add instructions without replacing the default prompt.

---

## 5. Domain Skills (`skills/*/SKILL.md`)

Skills keep specialized playbooks (SQL tuning, PowerShell 5.1 rules, internal API schemas) out of the base token budget until needed. `shellossus` scans up to 40 skills per root across:
- `~/.shellossus/skills/*/SKILL.md`
- `<workspace>/.shellossus/skills/*/SKILL.md`
- `<workspace>/skills/*/SKILL.md`

Only `name`, `description`, and `location` are injected into `<available_skills>`. The model loads the full `SKILL.md` via `read_file` when relevant (including registered global skills outside the workspace), or you can invoke a skill explicitly with `/skill:<name> [args]`. Set `disable-model-invocation: true` in frontmatter to keep a skill manual-only (`/skill:<name>`) and omit it from the model's automatic catalog.

```markdown
---
name: powershell-51
description: Best practices for Windows PowerShell 5.1 and ConstrainedLanguage scripts.
---
# Windows PowerShell 5.1 Guidelines
1. Prefer built-in cmdlets and native operators over .NET static methods.
2. Check `$val -is [bool]` before boolean coercion.
```

See [`examples/skills/powershell-51/SKILL.md`](../examples/skills/powershell-51/SKILL.md).

---

## 6. Subagent Role Profiles (`agents/*.md` & `run_agent`)

`shellossus` ships three built-in roles for `run_agent` and `/agent:<role> <task>`:
- **`recon`** *(aliases: `scout`, `explore`, `research`)* — Fast `ReadOnly` codebase exploration and search.
- **`audit`** *(aliases: `review`, `reviewer`, `security`)* — `ReadOnly` code, security, and bug review.
- **`craft`** *(aliases: `worker`, `coder`, `implementer`, `builder`)* — Focused implementation role inheriting parent write/command permissions.

Define custom roles in `~/.shellossus/agents/<name>.md`, `<workspace>/.shellossus/agents/<name>.md`, or `<workspace>/agents/<name>.md`:

```markdown
---
name: sql-auditor
description: Audit SQL queries for lock contention and missing indexes
permission: ReadOnly
tools: read_file, grep_files, find_files
---
Inspect target SQL scripts for table scans, lock escalation risks, and non-SARGable predicates.
```

`run_agent` supports single tasks (`prompt`), parallel `ReadOnly` worker pools (`parallel[]`, 1..8 tasks), and sequential multi-step workflows (`pipeline[]`, 1..8 steps passing `{previous}` or `$PREVIOUS`), with `context: "clean"` (default) or `"fork"`. See [`examples/agents/sql-auditor.md`](../examples/agents/sql-auditor.md).

---

## 7. Slash Prompt Templates (`.shellossus/prompts/*.md`)

Any Markdown file placed in `<workspace>/.shellossus/prompts/<name>.md` or `~/.shellossus/prompts/<name>.md` becomes a `/<name>` command in interactive mode and `-Prompt`:

- **Supported Placeholders:** `$ARGUMENTS` or `$@` (all arguments), `$1`..`$N` (positional arguments, respecting quotes), `${1:-default}` / `${ARGUMENTS:-default}` (fallback values), and `${@:2}` / `${@:2:3}` (argument slices).
- **Single-Pass Expansion:** Substituted user values are never re-parsed recursively for placeholders. If a template contains no placeholders, trailing arguments are appended once at the end.

```markdown
Perform a focused review of:
$ARGUMENTS
```

Invoke with `/review @src/tools/Files.ps1`. See [`examples/prompts/review.md`](../examples/prompts/review.md).

---

## 8. Inline Attachments (`@file`) & Shell Shortcuts (`!cmd` / `!!cmd`)

- **`@path/to/file`:** Attaches up to 300 lines / 20,000 characters of a workspace file inside `<file path="...">`. Only `@file` tokens written in your original prompt (including slash-command arguments) trigger file reads; text inside template bodies, model outputs, or subagent prompts is never auto-expanded into file reads.
- **`!cmd`:** Executes `cmd` in PowerShell from the workspace root, prints the output, and appends `[Shell command ...]` to the conversation so the model can see the result on your next message.
- **`!!cmd`:** Executes `cmd` locally in your terminal without recording anything in conversation history.
