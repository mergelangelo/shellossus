# Project Memory

- **Encoding:** All PowerShell scripts must remain strictly 7-bit ASCII with LF line endings.
- **Language Mode:** All changes must pass tests under PowerShell ConstrainedLanguage mode.
- **Single Artifact:** `shellossus.ps1` in repository root is built from `src/` via `build.ps1` and verified by `build.ps1 -Check`.
