# Repository Guidelines for Coding Agents

0. **Project Constitution:** Read and uphold [`CONSTITUTION.md`](CONSTITUTION.md) before proposing or implementing any change.
1. **Target Runtime:** Windows PowerShell 5.1 and PowerShell `ConstrainedLanguage` mode.
   - Do not use external modules or binaries.
   - Avoid `.NET` static method invocations or object method calls that are blocked in `ConstrainedLanguage` (prefer native PowerShell operators and built-in cmdlets).
2. **Pure ASCII in `.ps1` Files:** Keep all `.ps1` files (`src/*.ps1`, `build.ps1`, `shellossus.ps1`, `install.ps1`, `tests/*.ps1`) strictly ASCII so Windows PowerShell 5.1 parses them identically regardless of BOM or system codepage.
3. **Source of Truth:** Edit modular files in `src/` (`Config.ps1`, `Theme.ps1`, `Tools.ps1`, `Context.ps1`, `Cli.ps1`) and run `.\build.ps1` to regenerate the root `shellossus.ps1`.
4. **Verification:** Run `.\tests\smoke.ps1` (which begins with `.\build.ps1 -Check`, executes `tests/*.Tests.ps1`, and ends with `ConstrainedLanguage` verification). Individual suites can also be run via `.\tests\smoke.ps1 -Filter *Tools*` or directly (`.\tests\Tools.Tests.ps1`).
