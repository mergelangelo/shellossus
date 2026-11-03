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
    if ($leaf -eq 'Reliability.Tests.ps1') {
        # Run the same regression scenarios against freshly loaded constrained
        # functions, without changing the language mode of the smoke runner.
        $testShellName = if ($PSVersionTable.PSEdition -eq 'Core') {
            if ($env:OS -eq 'Windows_NT') { 'pwsh.exe' } else { 'pwsh' }
        }
        else { 'powershell.exe' }
        Write-Host '==> Running Reliability.Tests.ps1 in ConstrainedLanguage ...'
        & (Join-Path $PSHOME $testShellName) -NoProfile -File $suite -ConstrainedLanguage
        if ($LASTEXITCODE -ne 0) { throw 'ConstrainedLanguage reliability checks failed.' }
        Write-Host '[PASS] Reliability.Tests.ps1 (ConstrainedLanguage)'
    }
}

Write-Host 'All smoke checks passed.'
