$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TestHelpers.ps1"

$tableLines = @(Format-MarkdownTable -Lines @('| Col | Val |', '|---|---|', '| a | **bold** |') -Indent '')
$plainTable = @($tableLines | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' })
Assert-True ($plainTable[0] -eq '| Col | Val  |') 'Table header alignment failed.'
Assert-True ($plainTable[1] -eq '|-----+------|') 'Table separator alignment failed.'
Assert-True ($plainTable[2] -eq '| a   | bold |') 'Table cell markdown stripping or padding failed.'

$inlineOut = Format-MarkdownInline -Text 'Hello **world** and `SELECT *`'
Assert-True ($inlineOut.Contains('38;2;231;138;78') -and (-not $inlineOut.Contains('**')) -and (-not $inlineOut.Contains('`'))) 'Gruvbox Material inline markdown formatting failed.'

Write-AgentReasoning -Text "Step 1`nStep 2`nStep 3`nStep 4"
Write-AgentReply -Content "# Title`n## Subtitle`n> quote`n- **item** with ``code```n| A | B |`n|---|---|`n| 1 | 2 |`n``````sql`nSELECT 1;`n``````"
