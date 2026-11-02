# Customization Guide

`h-agent` supports project-level and user-level customization inspired by `pi-coding-agent`: project instructions (`AGENTS.md`), system prompt overrides (`SYSTEM.md` / `APPEND_SYSTEM.md`), domain skills (`SKILL.md`), and reusable prompt templates (`/template`).

---

## 1. Project Instructions (`AGENTS.md`)

`h-agent` automatically loads `AGENTS.md` from:
1. `%USERPROFILE%\.h-agent\AGENTS.md` (global user rules)
2. `<workspace>\AGENTS.md` (project-specific rules)

Use `AGENTS.md` to document coding conventions, build/test commands, database dialects, or architecture constraints.

---

## 2. System Prompt Overrides (`SYSTEM.md` & `APPEND_SYSTEM.md`)

- **Replace the base system prompt (`SYSTEM.md`):**
  Place a `SYSTEM.md` file in `<workspace>\.h-agent\SYSTEM.md` or `%USERPROFILE%\.h-agent\SYSTEM.md`.
- **Append to the system prompt (`APPEND_SYSTEM.md`):**
  Place an `APPEND_SYSTEM.md` file in `%USERPROFILE%\.h-agent\APPEND_SYSTEM.md` or `<workspace>\.h-agent\APPEND_SYSTEM.md`. Both global and workspace append files are combined in order.

---

## 3. Domain Skills (`skills/*/SKILL.md`)

Skills let you package specialized domain instructions (e.g., SQL optimization rules, internal API conventions, PowerShell 5.1 constraints) without bloating every prompt. At startup, `h-agent` scans:
- `%USERPROFILE%\.h-agent\skills\*\SKILL.md` (global skills)
- `<workspace>\.h-agent\skills\*\SKILL.md` (workspace hidden skills)
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

## 4. Prompt Templates (`.h-agent/prompts/*.md`)

Create Markdown files in `<workspace>\.h-agent\prompts\<name>.md` or `%USERPROFILE%\.h-agent\prompts\<name>.md` to define reusable slash commands.

- Invoke a template in interactive mode or via `-Prompt` by typing `/<name> [arguments]`.
- If the template contains `$ARGUMENTS`, it is replaced with the arguments passed after `/<name>`. Otherwise, arguments are appended to the end of the template.

Example `.h-agent/prompts/review.md`:

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
