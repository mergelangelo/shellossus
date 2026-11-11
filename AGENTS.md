# Repository Guidelines for Coding Agents

0. **Project Constitution:** Read and uphold [`CONSTITUTION.md`](CONSTITUTION.md) before proposing or implementing any change.
1. **Target Runtime:** Windows PowerShell 5.1, PowerShell 7+, and PowerShell `ConstrainedLanguage` mode.
   - Never introduce external runtimes, binaries, or PowerShell Gallery modules.
   - Avoid `.NET` static method invocations, `Add-Type`, or object method calls blocked in `ConstrainedLanguage` (prefer native PowerShell operators and built-in cmdlets).
2. **Pure ASCII in `.ps1` Files:** Keep all `.ps1` files (`src/*.ps1`, `build.ps1`, `shellossus.ps1`, `tests/*.ps1`) strictly 7-bit ASCII with LF line endings so Windows PowerShell 5.1 parses them identically regardless of BOM or system codepage.
3. **Source of Truth:** Edit modular files in [`src/`](src/) (`Config.ps1`, `Theme.ps1`, `ui/*.ps1`, `tools/*.ps1`, `context/*.ps1`, `Doctor.ps1`, `cli/*.ps1`, `Cli.ps1`) and run `.\build.ps1` to regenerate the standalone [`shellossus.ps1`](shellossus.ps1) artifact. Never hand-edit `shellossus.ps1`.
4. **Verification:** Run `.\tests\smoke.ps1` (which runs `.\build.ps1 -Check`, executes all `tests/*.Tests.ps1` suites, and verifies `ConstrainedLanguage` execution in dedicated child processes). Targeted suites can run via `.\tests\smoke.ps1 -Filter *Tools*`.
5. **Documentation Hygiene:** Keep each Markdown file aligned with its single canonical role — [`README.md`](README.md) (concise product overview & quick start), [`docs/cli.md`](docs/cli.md) (flags, `.env`, REPL commands, JSONL events), [`docs/customization.md`](docs/customization.md) (context layers, skills, agents, templates, memory), [`docs/security.md`](docs/security.md) (permissions, boundaries, `/undo`, limits, enterprise notes), and [`docs/architecture.md`](docs/architecture.md) (36-module map, turn lifecycle, tool table, test pipeline). Do not dump low-level protocol caveats into `README.md`.
