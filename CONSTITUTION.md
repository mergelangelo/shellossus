# THE CONSTITUTION OF H-AGENT

## PREAMBLE

**We, the architects and maintainers of `h-agent`**, in order to establish a sovereign, self-contained coding agent; to guarantee full agentic power on every Windows machine without foreign runtimes, package managers, or external binaries; to secure the inviolability of user workspaces and credentials; to preserve the integrity of conversational memory and disk state; and to bring the craft of autonomous software engineering to the most locked-down corporate, Citrix, VDI, and air-gapped environments on Earth, do ordain and establish this **Constitution for `h-agent`**.

---

## ARTICLE I — Sovereignty of the Runtime and Zero Dependencies

### Section 1. The Native PowerShell Mandate
`h-agent` is, and shall forever remain, a **100% native PowerShell coding agent**. It shall execute out of the box on standard **Windows PowerShell 5.1** and PowerShell 7+ without requiring Python, Node.js, Go, Rust, WSL, Docker, or any third-party runtime.

### Section 2. Prohibition of External Binaries and Modules
No tool, command, or subsystem of `h-agent` shall depend upon external command-line utilities (`rg`, `fd`, `git`, `jq`, `curl`) or external PowerShell gallery modules (`Install-Module`). All file discovery, regular-expression search, ignore-rule evaluation, diff generation, HTTP transport, and Markdown rendering shall be implemented natively in PowerShell.

### Section 3. ConstrainedLanguage Supremacy
Every function, tool, and code path in `h-agent` shall remain fully operational under PowerShell **`ConstrainedLanguage`** mode, AppLocker, and Windows Defender Application Control (WDAC). The invocation of arbitrary `.NET` static methods, custom type compilation (`Add-Type`), or restricted reflection APIs that violate `ConstrainedLanguage` boundaries is strictly prohibited.

---

## ARTICLE II — The Single-Script Republic and Source of Truth

### Section 1. Dual-Distribution Sovereignty
The codebase shall maintain a strict separation between **modular governance** and **single-file deployment**:
1. All human and agent edits shall be made exclusively within the modular source files under [`src/`](src/) (`Config.ps1`, `Theme.ps1`, `Tools.ps1`, `Context.ps1`, `Cli.ps1`).
2. The root [`h-agent.ps1`](h-agent.ps1) artifact is the unified, standalone instrument of deployment, generated deterministically by [`build.ps1`](build.ps1) and runnable by dropping a single file onto any Windows host.

### Section 2. The Pure ASCII Clause
All PowerShell source files (`src/*.ps1`, `h-agent.ps1`, `build.ps1`, `install.ps1`, and `tests/*.ps1`) shall be encoded strictly in **7-bit ASCII** with normalized LF line endings. No byte-order mark (BOM) or system codepage variance on Windows PowerShell 5.1 shall ever alter the parsing of `h-agent`.

### Section 3. Universal OpenAI-Compatible Diplomacy
`h-agent` shall communicate with language models through standard OpenAI-compatible `/v1/chat/completions` endpoints over UTF-8 file-backed HTTP transport, treating cloud providers, local inference servers (`Ollama`, `vLLM`, `LM Studio`), and internal corporate AI gateways as equals.

---

## ARTICLE III — Inviolability of the Workspace and Secret Sanctuary

### Section 1. Territorial Integrity of the Workspace
The user's workspace root is inviolable. No tool shall read, list, search, create, or modify any file outside the resolved workspace root, except for the narrow, read-only inspection of explicitly registered global `SKILL.md` files during `read_file`.

### Section 2. Prohibition of Symlink and Junction Secession
Before any path is accessed, `h-agent` shall inspect the target and walk every ancestor directory up to the workspace root. Any path traversing a symbolic link, NTFS junction, or reparse point (`Attributes -band 1024`) shall be summarily rejected.

### Section 3. Sanctuary of Credentials and Secrets
1. `.env` files, `.env.*` variants (excluding `.env.example`), and the active configuration file (`$ConfigPath`) are declared sacred and off-limits to the model. They shall never be read by `read_file`, listed by `list_files`, matched by `find_files` or `grep_files`, attached via `@file`, or written by `write_file`/`edit_file`.
2. Configuration files shall be parsed strictly as inert key-value data; embedded PowerShell subexpressions (`$(...)`) shall never be evaluated.
3. Child processes spawned by `run_command` shall have `H_AGENT_API_KEY` and `OPENAI_API_KEY` scrubbed from their environment prior to execution.

### Section 4. Hierarchy of Ignore Laws
File discovery (`find_files`) and content search (`grep_files`) shall respect `.gitignore`, `.ignore`, and `.fdignore` laws—including wildcard globs (`*`, `**`, `?`), directory-only rules, and negation overrides (`!pattern`). When a search begins in a subdirectory, ignore laws shall be loaded top-down from the workspace root through every ancestor directory to the target path and its descendants.

---

## ARTICLE IV — Due Process of Tool Execution and Disk Reversibility

### Section 1. The Four Estates of Permission
No mutation of disk or execution of shell commands shall occur without the consent of the active Permission Estate:
1. **`ReadOnly`**: Exposes only read and search tools (`list_files`, `read_file`, `find_files`, `grep_files`); all write and shell tools are constitutionally barred.
2. **`Ask`**: Requires explicit human ratification (`WRITE` for file modifications, `RUN` for shell commands) after displaying a visual preview.
3. **`AutoEdit`**: Grants autonomous authority for file creations and edits while preserving mandatory human ratification (`RUN`) for shell commands.
4. **`Auto`**: Grants full autonomous authority within the bounds of Article III.

### Section 2. Strict Schema Jurisdiction
Every tool invocation shall undergo strict runtime schema validation prior to execution. Unknown parameters, missing required fields, and coerced types (such as passing the string `"false"` where a `[bool]` is required) shall be rejected before any side effect occurs.

### Section 3. Transactional Staging and Verified Backups
1. No file shall be modified in place without due process. Every `write_file` and `edit_file` operation shall first write the proposed content to an isolated temporary staging file, verify the staged bytes, confirm the target file has not changed during human confirmation, and create a byte-verified backup copy before atomically moving the staged file into place.
2. Line endings (`CRLF` vs `LF`) of existing files shall be faithfully preserved. Fuzzy matching (ignoring trailing whitespace, BOM, and typographic punctuation) and multi-block batch `edits[]` shall be applied atomically from bottom to top, rejecting any overlapping ranges.

### Section 4. The Right of `/undo` and Protection of Manual Labor
1. Every turn shall record its chain of disk mutations (`created` and `modified` files) onto the undo stack.
2. Before `/undo` (or automatic turn rollback on failure) touches a single byte on disk, a **preflight check** shall verify the entire restoration chain in reverse order.
3. Multiple sequential edits—or creation followed by edits—to the same file within a single turn shall be validated as a continuous chain and unwound to the exact pre-turn state.
4. **Manual User Labor is Sacred:** If a user manually modifies a file after an agent write, `/undo` shall refuse to overwrite the user's changes and shall preserve all backup files intact so the user may resolve the conflict and retry `/undo` without data loss.

### Section 5. Bounded Shell Execution and Full Audit Logs
Shell commands executed via `run_command` shall stream standard output and error directly to temporary disk files without unbounded memory buffering, enforce strict wall-clock timeouts (`Wait-Process` + forced termination), and persist full untruncated logs under `.h-agent/output/` whenever terminal output is truncated.

---

## ARTICLE V — Integrity of Context, Memory, and the Session Tree

### Section 1. Pagination Without Omission
1. `read_file` shall enforce a dual budget of 300 lines and 20,000 characters per page. Whenever the character budget is reached before the line limit, `end_line` and `next_start_line` shall reflect the exact lines returned so that no line is ever silently skipped between pages.
2. Single lines exceeding 20,000 characters shall be paginated horizontally via `start_char` and `next_start_char`.
3. `grep_files` shall explicitly report `truncated`, `truncation_reason` (`max_matches`, `max_files`, or both), `files_scanned`, `total_files`, and `next_file_offset` so the model is never misled by an incomplete search.

### Section 2. Rejection of Truncated Model Decrees
Both the main agent turn loop (`Invoke-AgentTurn`) and context compaction (`Invoke-AgentCompact`) shall inspect `finish_reason` on every model response. Any response terminated prematurely (`finish_reason=length` or `content_filter`) shall be rejected immediately before mutating conversation state or executing partial tool calls.

### Section 3. The Session Tree and Lawful Branching
1. Every session shall be persisted atomically as workspace-scoped JSONL with a `session_meta` header and a parent-linked entry tree (`id`, `parent_id`).
2. Cross-workspace session contamination is forbidden: `/resume` and `-Continue` shall never load a session belonging to a different workspace root, and resuming a session shall synchronize the active model and clear stale undo stacks.
3. **Lawful Boundaries Only:** Neither `/tree` branch switching nor `/fork` session cloning shall permit branching from an incomplete `assistant` turn whose `tool_calls` lack their corresponding `role = 'tool'` result records.

### Section 4. Perpetuity of Context Compaction
1. Context compaction (`/compact` and automatic overflow recovery) shall summarize older turns into a structured handoff (`Goal`, `Constraints & Preferences`, `Progress`, `Key Decisions`, `Next Steps`, `Critical Context`) while preserving cumulative `<read-files>` and `<modified-files>` XML records across iterative compactions.
2. Cut points shall never land directly on a `role = 'tool'` message.
3. Compaction shall be recorded as a first-class `compaction` node in the session tree (`entry_type = 'compaction'`, `first_kept_entry_id`) so that switching branches via `/tree` or resuming from disk preserves the compacted context without severing historical branches.

---

## ARTICLE VI — Separation of Streams and Terminal Aesthetics

### Section 1. Purity of the JSON Stream
When invoked in `-Mode json`, `stdout` is reserved exclusively for machine-readable JSONL event records (`turn_start`, `message_end`, `tool_execution_start`, `tool_execution_end`, `turn_end`). All decorative `Write-Host` logs, diff previews, and interactive `Read-Host` prompts shall be suppressed; any unapproved write or command in `json` mode shall immediately return a structured `status = 'cancelled'` result without blocking on standard input.

### Section 2. The Gruvbox Material Standard
In interactive and text modes, `h-agent` shall render output using the 24-bit TrueColor `sainnhe/gruvbox-material` (dark medium) palette, aligning Markdown tables by visible character width (`Get-VisibleLength`) so that ANSI escape sequences never distort column geometry.

---

## ARTICLE VII — Extensibility and Local Autonomy

### Section 1. Constitutional Hierarchy of Instructions
`h-agent` shall assemble its system prompt from layered local authorities without external network calls:
1. Base system prompt or `.h-agent/SYSTEM.md` override;
2. `APPEND_SYSTEM.md` additions;
3. Hierarchical `AGENTS.md` and `CLAUDE.md` laws discovered from the workspace root;
4. Project and global Skills (`SKILL.md`) exposed via an `<available_skills>` XML catalog and invocable via `/skill:<name>` or `read_file`;
5. Markdown Prompt Templates (`.h-agent/prompts/*.md`) supporting positional, slice, and default argument substitution (`$1`, `$@`, `$ARGUMENTS`, `${1:-default}`, `${@:2}`) without recursive re-expansion.

---

## ARTICLE VIII — Supreme Verification and Amendments

### Section 1. Mandatory Judicial Review (`smoke.ps1`)
No change to `src/*.ps1` shall be deemed lawful unless [`build.ps1`](build.ps1) has regenerated [`h-agent.ps1`](h-agent.ps1) and the full test judiciary ([`tests/smoke.ps1`](tests/smoke.ps1)—comprising `Config.Tests.ps1`, `Theme.Tests.ps1`, `Tools.Tests.ps1`, `Context.Tests.ps1`, `Cli.Tests.ps1`, and `ConstrainedLanguage.Tests.ps1`) has passed without error in Windows PowerShell 5.1.

### Section 2. Amendments
This Constitution may be amended only when new capabilities preserve the core guarantees of **Article I (Zero Dependencies & `ConstrainedLanguage`)**, **Article II (Single-Script ASCII Distribution)**, **Article III (Workspace & Secret Sanctuary)**, **Article IV (Transactional Disk Safety & `/undo`)**, and **Article V (Context & Tree Integrity)**, and when accompanied by regression tests in [`tests/`](tests/).
