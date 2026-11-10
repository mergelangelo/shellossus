# Customization Guide

`shellossus` supports project-level and user-level customization: project instructions (`AGENTS.md`), persona and ethos (`SOUL.md`), persistent cross-session memory (`MEMORY.md`), system prompt overrides (`SYSTEM.md` / `APPEND_SYSTEM.md`), domain skills (`SKILL.md`), and reusable prompt templates (`/template`).

---

## 1. Project Instructions & Ethos (`AGENTS.md`, `SOUL.md`)

`shellossus` automatically loads `AGENTS.md` and persona ethos `SOUL.md` from:
1. `%USERPROFILE%\.shellossus\AGENTS.md` / `SOUL.md` (global rules and agent persona)
2. `<workspace>\.shellossus\SOUL.md` or `<workspace>\SOUL.md` (project persona and tone)
3. `<workspace>\AGENTS.md` (project-specific rules)

- Nested `AGENTS.md` files along a file's path are provided to the agent parent-first before `read_file`, `write_file`, or `edit_file` proceeds. The tool call is retried after the model receives the rules. `-NoContextFiles` disables this behavior. Commands and search tools do not automatically load path-specific rules.
- Use `AGENTS.md` to document coding conventions, build/test commands, database dialects, or architecture constraints.
- Use `SOUL.md` (or `ETHOS.md` / `SHELLOSSUS.md`) to define the agent's persona, communication principles, craftsmanship philosophy, and core behavioral invariants.

---

## 2. System Prompt Overrides (`SYSTEM.md` & `APPEND_SYSTEM.md`)

- **Replace the base system prompt (`SYSTEM.md`):**
  Place a `SYSTEM.md` file in `<workspace>\.shellossus\SYSTEM.md` or `%USERPROFILE%\.shellossus\SYSTEM.md`.
- **Append to the system prompt (`APPEND_SYSTEM.md`):**
  Place an `APPEND_SYSTEM.md` file in `%USERPROFILE%\.shellossus\APPEND_SYSTEM.md` or `<workspace>\.shellossus\APPEND_SYSTEM.md`. Both global and workspace append files are combined in order.

---

## 3. Domain Skills (`skills/*/SKILL.md`)

Skills let you package specialized domain instructions (e.g., SQL optimization rules, internal API conventions, PowerShell 5.1 constraints) without bloating every prompt. At startup, `shellossus` scans:
- `%USERPROFILE%\.shellossus\skills\*\SKILL.md` (global skills)
- `<workspace>\.shellossus\skills\*\SKILL.md` (workspace hidden skills)
- `<workspace>\skills\*\SKILL.md` (workspace skills)

Only the skill's `name`, `description`, and path are injected into the system prompt catalog. When a task matches a skill, the model reads the full `SKILL.md` on demand using `read_file`.

Example `SKILL.md`:

```markdown
---
name: sql-tuning
description: Guidelines for optimizing analytical SQL queries and indexing.
---
# SQL Tuning Rules
1. Always inspect execution plans before adding indexes.
2. Prefer explicit column lists over `SELECT *`.
```

See [`examples/skills/powershell-51/SKILL.md`](../examples/skills/powershell-51/SKILL.md) for a complete example.

---

## 4. Prompt Templates (`.shellossus/prompts/*.md`)

Create Markdown files in `<workspace>\.shellossus\prompts\<name>.md` or `%USERPROFILE%\.shellossus\prompts\<name>.md` to define reusable slash commands.

- Invoke a template in interactive mode or via `-Prompt` by typing `/<name> [arguments]`.
- Arguments fill placeholders such as `$ARGUMENTS` and `$1`. A template without placeholders appends its arguments once.
- For `/skill:<name>` without placeholders, arguments appear after the skill body. For `/agent:<role>`, arguments already used by placeholders appear in the role text. The delegation includes any remaining arguments separately.

Example `.shellossus/prompts/review.md`:

```markdown
Review the following files for bugs, edge cases, and security issues:
$ARGUMENTS
```

Usage:

```text
You: /review @src/tools/Files.ps1
```

---

## 5. Inline File Attachments (`@file`) & Shell Shortcuts (`!cmd`)

- **`@path/to/file`** in your original input, including slash-command arguments, attaches the first 300 lines (up to 20,000 characters) of that workspace file in a `<file path="...">...</file>` block. Template bodies and subagent task text are passed through without reading their `@file` references.
- **`!command`:** Runs a PowerShell command in the workspace root, prints the output, and appends the command + output to the conversation context.
- **`!!command`:** Runs a PowerShell command locally in the terminal without adding its output to the conversation context.

---

## 6. Subagent Role Profiles (`.shellossus/agents/*.md`)

`shellossus` includes three built-in subagent roles (`recon`, `audit`, and `craft`) for the `run_agent` tool. You can also define custom subagent roles in:
- `%USERPROFILE%\.shellossus\agents\<name>.md`
- `<workspace>\.shellossus\agents\<name>.md`
- `<workspace>\agents\<name>.md`

Example `.shellossus/agents/sql-auditor.md`:

```markdown
---
name: sql-auditor
description: Audit SQL queries for lock contention and full table scans
permission: ReadOnly
tools: read_file, grep_files
---
Inspect the target SQL files for missing indexes, lock escalation risks, and non-SARGable predicates.
```

Use `/agents` in interactive mode to inspect available roles, or `/agent:<role> <task>` to delegate a task directly to that role.

---

## 7. Persistent Memory (`MEMORY.md` & `/memory`)

`shellossus` supports persistent long-term memory across CLI sessions:
- **Automatic Loading:** At launch or turn start, `<workspace>\.shellossus\MEMORY.md` (or `<workspace>\MEMORY.md`) and `%USERPROFILE%\.shellossus\MEMORY.md` are injected directly into the system prompt inside a `<memory>` block.
- **Agent Tool (`memory`):** The model can call the `memory` tool with actions `append`, `view`, `set`, and `clear` to record architecture invariants, user preferences, and important facts.
- **Interactive Commands:**
  - `/memory` (or `/mem`) — view currently saved project memories.
  - `/memory add <fact>` — quickly record a persistent memory note.
  - `/memory clear` — clear the project memory file.
