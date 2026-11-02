---
name: powershell-51
description: Best practices for writing Windows PowerShell 5.1 and ConstrainedLanguage compatible scripts.
---
# Windows PowerShell 5.1 & ConstrainedLanguage Guidelines

1. **Avoid Blocked .NET Invocations:**
   - In `ConstrainedLanguage` mode, arbitrary `.NET` static method calls (such as `[System.IO.Path]::GetFullPath(...)` or `[guid]::NewGuid()`) and method calls on non-core `.NET` objects are blocked.
   - Use built-in cmdlets (`Join-Path`, `Split-Path`, `Get-Item`, `Get-Random`, `Get-Member`, `Start-Process`, `Wait-Process`, `Stop-Process`) and native PowerShell operators (`-ieq`, `-cne`, `-match`, `-replace`).
2. **Strict Boolean & Type Validation:**
   - Never cast untrusted strings with `[bool]$val` because any non-empty string (including `"false"`) evaluates to `$true` in PowerShell. Check `$val -is [bool]` first.
3. **Encoding Safety:**
   - Keep `.ps1` source files pure ASCII so Windows PowerShell 5.1 reads them identically regardless of UTF-8 BOM or system ANSI codepage.
   - Always specify `-Encoding UTF8` when reading or writing data files with `Get-Content` / `Set-Content`.
