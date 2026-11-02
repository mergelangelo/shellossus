# Customization Guide

`shellossus` supports project-level and user-level customization: project instructions (`AGENTS.md`, `CLAUDE.md`), system prompt overrides (`SYSTEM.md` / `APPEND_SYSTEM.md`), domain skills (`SKILL.md`), and reusable prompt templates (`/template`).

---

## 1. Project Instructions (`AGENTS.md`)

`shellossus` automatically loads `AGENTS.md` from:
1. `%USERPROFILE%\.shellossus\AGENTS.md` (global user rules)
2. `<workspace>\AGENTS.md` (project-specific rules)

Use `AGENTS.md` to document coding conventions, build/test commands, database dialects, or architecture constraints.

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
- If the template contains `$ARGUMENTS`, it is replaced with the arguments passed after `/<name>`. Otherwise, arguments are appended to the end of the template.

Example `.shellossus/prompts/review.md`:

```markdown
Review the following files for bugs, edge cases, and security issues:
$ARGUMENTS
```

Usage:

```text
You: /review @src/Tools.ps1
```

---

## 5. Inline File Attachments (`@file`) & Shell Shortcuts (`!cmd`)

- **`@path/to/file`:** Any `@relative/path` token in your prompt automatically attaches the first 300 lines (up to 20,000 characters) of that workspace file in a `<file path="...">...</file>` block.
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
