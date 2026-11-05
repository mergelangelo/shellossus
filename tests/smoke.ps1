param(
    [string]$Filter = '*.Tests.ps1'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$asciiTargets = @(
    (Join-Path $repoRoot 'build.ps1'),
    (Join-Path $repoRoot 'shellossus.ps1')
)
foreach ($scanDir in @((Join-Path $repoRoot 'src'), $PSScriptRoot)) {
    if (Test-Path -LiteralPath $scanDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $scanDir -Filter '*.ps1' -Recurse -File)) {
            $asciiTargets += $f.FullName
        }
    }
}
foreach ($targetFile in $asciiTargets) {
    if (-not (Test-Path -LiteralPath $targetFile)) { continue }
    $rawContent = Get-Content -LiteralPath $targetFile -Raw -Encoding UTF8 -ErrorAction Stop
    if ($null -ne $rawContent -and ([string]$rawContent -match '[^\x00-\x7F]')) {
        throw "Non-ASCII character detected in $targetFile. All .ps1 files must be strictly 7-bit ASCII."
    }
}

& "$PSScriptRoot\..\build.ps1" -Check

$suiteOrder = @(
    'Config.Tests.ps1',
    'Theme.Tests.ps1',
    'Tools.Tests.ps1',
    'Context.Tests.ps1',
    'Cli.Tests.ps1',
    'Doctor.Tests.ps1',
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
    if ($leaf -eq 'Doctor.Tests.ps1') {
        $doctorShell = if ($PSVersionTable.PSEdition -eq 'Core') {
            if ($env:OS -eq 'Windows_NT') { 'pwsh.exe' } else { 'pwsh' }
        }
        else { 'powershell.exe' }
        Write-Host '==> Running Doctor.Tests.ps1 in ConstrainedLanguage ...'
        & (Join-Path $PSHOME $doctorShell) -NoProfile -File $suite -ConstrainedLanguage
        if ($LASTEXITCODE -ne 0) { throw 'ConstrainedLanguage doctor checks failed.' }
        Write-Host '[PASS] Doctor.Tests.ps1 (ConstrainedLanguage)'
    }
}

Write-Host 'All smoke checks passed.'
