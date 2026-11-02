param(
    [string]$AgentPath = "$PSScriptRoot\shellossus.ps1",
    [string]$ProfilePath = $PROFILE
)

# Adds a wrapper to this user's current-host profile. Does not modify policy.
$ErrorActionPreference = 'Stop'
$resolvedAgent = (Resolve-Path -LiteralPath $AgentPath -ErrorAction Stop).ProviderPath
if ((Get-Item -LiteralPath $resolvedAgent).PSIsContainer) { throw 'AgentPath must be a script file.' }
if (-not $ProfilePath) { throw 'No PowerShell profile path is available.' }
$escaped = $resolvedAgent.Replace("'", "''")
$block = "# >>> shellossus >>>`r`nfunction global:shellossus { & '$escaped' @args }`r`n# <<< shellossus <<<"
$existing = ''
if (Test-Path -LiteralPath $ProfilePath) {
    $existing = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
    if ($null -eq $existing) { $existing = '' }
    $starts = @($existing -split '(?m)^# >>> shellossus >>>\r?$').Count - 1
    $ends = @($existing -split '(?m)^# <<< shellossus <<<\r?$').Count - 1
    if ($starts -gt 1 -or $ends -gt 1 -or $starts -ne $ends) { throw 'Unexpected shellossus profile markers; edit the profile manually.' }
    if ($starts -eq 1) {
        # Use literal slicing: paths with dollar signs are never regex replacements.
        $start = $existing.IndexOf('# >>> shellossus >>>', [StringComparison]::Ordinal)
        $end = $existing.IndexOf('# <<< shellossus <<<', [StringComparison]::Ordinal)
        if ($end -lt $start) { throw 'Invalid shellossus profile marker order.' }
        $end += '# <<< shellossus <<<'.Length
        $updated = $existing.Substring(0, $start) + $block + $existing.Substring($end)
    }
    else { $updated = $existing + "`r`n" + $block + "`r`n" }
    $backup = $ProfilePath + '.shellossus-backup-' + (Get-Date -Format 'yyyyMMddHHmmssfff')
    Copy-Item -LiteralPath $ProfilePath -Destination $backup -ErrorAction Stop
    Write-Host "Profile backup: $backup"
}
else { $updated = $block + "`r`n" }
$parent = Split-Path $ProfilePath -Parent
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding UTF8 -NoNewline
Write-Host "Command registered in: $ProfilePath" -ForegroundColor Green
Write-Host 'Open a new PowerShell window, then run: shellossus -Setup'
Write-Host 'If profiles are blocked, use your approved script launch method; no policies were changed.'
