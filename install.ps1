param(
    [string]$AgentPath = "$PSScriptRoot\h-agent.ps1",
    [string]$ProfilePath = $PROFILE
)

# Adds a wrapper to this user's current-host profile. Does not modify policy.
$ErrorActionPreference = 'Stop'
$resolvedAgent = (Resolve-Path -LiteralPath $AgentPath -ErrorAction Stop).ProviderPath
if ((Get-Item -LiteralPath $resolvedAgent).PSIsContainer) { throw 'AgentPath must be a script file.' }
if (-not $ProfilePath) { throw 'No PowerShell profile path is available.' }
$escaped = $resolvedAgent.Replace("'", "''")
$block = "# >>> h-agent >>>`r`nfunction global:h-agent { & '$escaped' @args }`r`n# <<< h-agent <<<"
$existing = ''
if (Test-Path -LiteralPath $ProfilePath) {
    $existing = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
    if ($null -eq $existing) { $existing = '' }
    $starts = @($existing -split '(?m)^# >>> h-agent >>>\r?$').Count - 1
    $ends = @($existing -split '(?m)^# <<< h-agent <<<\r?$').Count - 1
    if ($starts -gt 1 -or $ends -gt 1 -or $starts -ne $ends) { throw 'Unexpected h-agent profile markers; edit the profile manually.' }
    if ($starts -eq 1) {
        # Use literal slicing: paths with dollar signs are never regex replacements.
        $start = $existing.IndexOf('# >>> h-agent >>>', [StringComparison]::Ordinal)
        $end = $existing.IndexOf('# <<< h-agent <<<', [StringComparison]::Ordinal)
        if ($end -lt $start) { throw 'Invalid h-agent profile marker order.' }
        $end += '# <<< h-agent <<<'.Length
        $updated = $existing.Substring(0, $start) + $block + $existing.Substring($end)
    }
    else { $updated = $existing + "`r`n" + $block + "`r`n" }
    $backup = $ProfilePath + '.h-agent-backup-' + (Get-Date -Format 'yyyyMMddHHmmssfff')
    Copy-Item -LiteralPath $ProfilePath -Destination $backup -ErrorAction Stop
    Write-Host "Profile backup: $backup"
}
else { $updated = $block + "`r`n" }
$parent = Split-Path $ProfilePath -Parent
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding UTF8 -NoNewline
Write-Host "Command registered in: $ProfilePath" -ForegroundColor Green
Write-Host 'Open a new PowerShell window, then run: h-agent -Setup'
Write-Host 'If profiles are blocked, use your approved script launch method; no policies were changed.'
