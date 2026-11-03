param(
    [string]$Filter = '*.Tests.ps1'
)

$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\..\build.ps1" -Check

$suiteOrder = @(
    'Config.Tests.ps1',
    'Theme.Tests.ps1',
    'Tools.Tests.ps1',
    'Context.Tests.ps1',
    'Cli.Tests.ps1',
    'Reliability.Tests.ps1',
    'ConstrainedLanguage.Tests.ps1'
)

$matchedSuites = @()
foreach ($suiteName in $suiteOrder) {
    if ($suiteName -like $Filter) {
        $suitePath = Join-Path $PSScriptRoot $suiteName
        if (-not (Test-Path -LiteralPath $suitePath)) {
            throw "Missing test suite: $suitePath"
        }
        $matchedSuites += $suitePath
    }
}

if ($matchedSuites.Count -eq 0) {
    throw "No test suites matched filter: $Filter"
}

foreach ($suite in $matchedSuites) {
    $leaf = Split-Path $suite -Leaf
    Write-Host "==> Running $leaf ..."
    & $suite
    Write-Host "[PASS] $leaf"
}

Write-Host 'All smoke checks passed.'
