# Workspace ignore rules (.gitignore, .ignore, .fdignore) and directory tree walking.

function Convert-IgnorePatternToRule {
    param([string]$Line, [string]$DirPrefix = '')
    $trimmed = $Line.Trim()
    if (-not $trimmed) { return $null }
    if ($trimmed.StartsWith('#') -and (-not $trimmed.StartsWith('\#'))) { return $null }
    $pat = $trimmed
    $negated = $false
    if ($pat.StartsWith('!')) {
        $negated = $true
        $pat = $pat.Substring(1)
    }
    elseif ($pat.StartsWith('\!') -or $pat.StartsWith('\#')) {
        $pat = $pat.Substring(1)
    }
    if (-not $pat) { return $null }
    $dirOnly = $pat.EndsWith('/')
    if ($dirOnly) { $pat = $pat.TrimEnd('/') }
    if (-not $pat) { return $null }
    $anchored = $pat.StartsWith('/')
    if ($anchored) { $pat = $pat.TrimStart('/') }
    if ($pat.Contains('/')) { $anchored = $true }
    $charClasses = @()
    if ($pat.Contains('[')) {
        $sb = ''
        $i = 0
        while ($i -lt $pat.Length) {
            $ch = [string]$pat[$i]
            if ($ch -eq '[' -and ($i -eq 0 -or ([string]$pat[$i - 1]) -ne '\')) {
                $j = $i + 1
                if ($j -lt $pat.Length -and (([string]$pat[$j]) -eq '!' -or ([string]$pat[$j]) -eq '^')) { $j++ }
                if ($j -lt $pat.Length -and ([string]$pat[$j]) -eq ']') { $j++ }
                $closeIdx = -1
                while ($j -lt $pat.Length) {
                    $c = [string]$pat[$j]
                    if ($c -eq '/') { break }
                    if ($c -eq '\' -and ($j + 1) -lt $pat.Length) {
                        $j += 2
                        continue
                    }
                    if ($c -eq ']') {
                        $closeIdx = $j
                        break
                    }
                    $j++
                }
                if ($closeIdx -gt ($i + 1)) {
                    $inner = $pat.Substring($i + 1, $closeIdx - $i - 1)
                    $negClass = $false
                    if ($inner.StartsWith('!') -or $inner.StartsWith('^')) {
                        $negClass = $true
                        $inner = $inner.Substring(1)
                    }
                    $candidateRx = if ($negClass) { '[^/' + $inner + ']' } else { '[' + $inner + ']' }
                    $validClass = $false
                    try {
                        $null = '' -match $candidateRx
                        $validClass = $true
                    }
                    catch {
                        $validClass = $false
                    }
                    if ($validClass) {
                        $ccIdx = $charClasses.Count
                        $charClasses += $candidateRx
                        $sb += "__CC_${ccIdx}__"
                        $i = $closeIdx + 1
                        continue
                    }
                }
            }
            $sb += $ch
            $i++
        }
        $pat = $sb
    }
    $rx = $pat -replace '([.+^$()\[\]{}|\\])', '\$1'
    $rx = $rx -replace '/\*\*/', '__DBLSTAR_SLASH__'
    $rx = $rx -replace '^\*\*/', '__LEAD_DBLSTAR__'
    $rx = $rx -replace '/\*\*$', '__TRAIL_DBLSTAR__'
    $rx = $rx -replace '\*\*', '__ANY__'
    $rx = $rx -replace '\*', '[^/]*'
    $rx = $rx -replace '\?', '[^/]'
    $rx = $rx.Replace('__DBLSTAR_SLASH__', '(?:/.*)?/')
    $rx = $rx.Replace('__LEAD_DBLSTAR__', '(?:.+/)?')
    $rx = $rx.Replace('__TRAIL_DBLSTAR__', '(?:/.*)?')
    $rx = $rx.Replace('__ANY__', '.*')
    for ($ccIdx = 0; $ccIdx -lt $charClasses.Count; $ccIdx++) {
        $rx = $rx.Replace("__CC_${ccIdx}__", [string]$charClasses[$ccIdx])
    }
    $prefRx = if ($DirPrefix) { ($DirPrefix -replace '([.+^$()\[\]{}|\\*?\-])', '\$1') } else { '' }
    $tailRx = if ($dirOnly) { '/.*$' } else { '(?:/.*)?$' }
    $finalRx = if ($anchored) {
        '^' + $prefRx + $rx + $tailRx
    }
    else {
        '^' + $prefRx + '(?:.+/)?' + $rx + $tailRx
    }
    return @{
        regex = $finalRx
        negated = $negated
        pattern = $trimmed
    }
}

function Compress-IgnoreRules {
    param([array]$Rules)
    if (-not $Rules -or $Rules.Count -eq 0) { return @() }
    if ($Rules.Count -eq 1 -and $Rules[0].combined) { return $Rules }
    $valid = @(foreach ($r in $Rules) {
        if ($null -ne $r -and $r.regex) { $r }
    })
    if ($valid.Count -eq 0) { return @() }
    $firstNeg = [bool]$valid[0].negated
    $allSame = $true
    foreach ($v in $valid) {
        if ([bool]$v.negated -ne $firstNeg) {
            $allSame = $false
            break
        }
    }
    if ($allSame) {
        $rxParts = @(foreach ($v in $valid) {
            if ($v.combined) { [string]$v.regex } else { "(?:$($v.regex))" }
        })
        return @(@{
            regex = ($rxParts -join '|')
            negated = $firstNeg
            combined = $true
        })
    }
    $segments = @()
    $startIdx = 0
    $currNeg = $firstNeg
    for ($i = 1; $i -le $valid.Count; $i++) {
        $isEnd = ($i -eq $valid.Count)
        $nextNeg = if (-not $isEnd) { [bool]$valid[$i].negated } else { (-not $currNeg) }
        if ($isEnd -or ($nextNeg -ne $currNeg)) {
            $rxParts = @(for ($j = $startIdx; $j -lt $i; $j++) {
                $item = $valid[$j]
                if ($item.combined) { [string]$item.regex } else { "(?:$($item.regex))" }
            })
            $segments += @{
                regex = ($rxParts -join '|')
                negated = $currNeg
                combined = $true
            }
            $startIdx = $i
            $currNeg = $nextNeg
        }
    }
    return $segments
}

function Read-DirectoryIgnoreRules {
    param([string]$RootFull, [string]$DirFull)
    $relDir = Get-WorkspaceRelativePath -Root $RootFull -FullPath $DirFull
    $dirPrefix = if ($DirFull -ieq $RootFull -or -not $relDir -or $relDir -eq '.') { '' } else { $relDir.Replace('\', '/').Trim('/') + '/' }
    $localRules = @(foreach ($igName in @('.gitignore', '.ignore', '.fdignore')) {
        $igFile = Join-Path $DirFull $igName
        if (-not (Test-Path -LiteralPath $igFile)) { continue }
        $igItem = Get-Item -LiteralPath $igFile -Force -ErrorAction SilentlyContinue
        if (-not $igItem -or $igItem.PSIsContainer -or (($igItem.Attributes -band 1024) -ne 0) -or $igItem.Length -gt 256KB) { continue }
        foreach ($line in @(Get-Content -LiteralPath $igFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $r = Convert-IgnorePatternToRule -Line ([string]$line) -DirPrefix $dirPrefix
            if ($null -ne $r) { $r }
        }
    })
    return $localRules
}

function Get-AncestorIgnoreRules {
    param([string]$RootFull, [string]$ScanDir)
    $ancestorsRev = @()
    $currDir = $ScanDir
    $guard = 0
    while ($currDir -and ($currDir -ine $RootFull) -and ($guard -lt 100)) {
        $guard++
        $parentDir = Split-Path $currDir -Parent
        if (-not $parentDir -or ($parentDir -ieq $currDir)) { break }
        $currDir = $parentDir.TrimEnd('\').TrimEnd('/')
        $ancestorsRev += $currDir
    }
    $ancestorDirs = @()
    for ($i = $ancestorsRev.Count - 1; $i -ge 0; $i--) {
        if (-not ($ancestorDirs -contains $ancestorsRev[$i])) {
            $ancestorDirs += $ancestorsRev[$i]
        }
    }
    if (($ScanDir -ine $RootFull) -and (-not ($ancestorDirs -contains $RootFull))) {
        $ancestorDirs = @($RootFull) + $ancestorDirs
    }
    $rawRules = @(foreach ($d in $ancestorDirs) {
        Read-DirectoryIgnoreRules -RootFull $RootFull -DirFull $d
    })
    return @(Compress-IgnoreRules -Rules $rawRules)
}

function Invoke-WorkspaceIgnoreScan {
    param([string]$RootFull, [string]$CurrentDir, [array]$ParentRules = @(), [int]$Depth = 0, [int]$MaxDepth = 64)
    if ($Depth -gt $MaxDepth) { return }
    $localRules = @(Read-DirectoryIgnoreRules -RootFull $RootFull -DirFull $CurrentDir)
    foreach ($lr in $localRules) { $lr }
    $activeRules = @(if ($localRules.Count -gt 0) {
        Compress-IgnoreRules -Rules (@($ParentRules) + $localRules)
    }
    else {
        $ParentRules
    })
    $subDirs = @(Get-ChildItem -LiteralPath $CurrentDir -Force -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)
    foreach ($sd in $subDirs) {
        if (($sd.Attributes -band 1024) -ne 0) { continue }
        if ($sd.Name -ieq '.git' -or $sd.Name -ieq 'node_modules') { continue }
        $relDir = Get-WorkspaceRelativePath -Root $RootFull -FullPath $sd.FullName
        if (Test-PathIgnored -RelativePath $relDir -IsDir $true -Rules $activeRules) { continue }
        Invoke-WorkspaceIgnoreScan -RootFull $RootFull -CurrentDir $sd.FullName -ParentRules $activeRules -Depth ($Depth + 1) -MaxDepth $MaxDepth
    }
}

function Get-WorkspaceIgnoreRules {
    param([string]$Root, [string]$SearchPath = '')
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return @() }
    $rootFull = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\').TrimEnd('/')
    $scanItem = if ($SearchPath -and (Test-Path -LiteralPath $SearchPath)) { Get-Item -LiteralPath $SearchPath -Force } else { Get-Item -LiteralPath $Root -Force }
    $scanDir = if ($scanItem.PSIsContainer) { $scanItem.FullName.TrimEnd('\').TrimEnd('/') } else { (Split-Path $scanItem.FullName -Parent).TrimEnd('\').TrimEnd('/') }
    $ancestorRules = @(Get-AncestorIgnoreRules -RootFull $rootFull -ScanDir $scanDir)
    $scannedRules = @(if ($scanItem.PSIsContainer) {
        Invoke-WorkspaceIgnoreScan -RootFull $rootFull -CurrentDir $scanDir -ParentRules $ancestorRules
    }
    else {
        Read-DirectoryIgnoreRules -RootFull $rootFull -DirFull $scanDir
    })
    return @(Compress-IgnoreRules -Rules ($ancestorRules + $scannedRules))
}

function Test-PathIgnored {
    param([string]$RelativePath, [bool]$IsDir, [array]$Rules)
    if (-not $Rules -or $Rules.Count -eq 0 -or -not $RelativePath) { return $false }
    $norm = $RelativePath.Replace('\', '/').TrimStart('/')
    $check = if ($IsDir) { $norm.TrimEnd('/') + '/' } else { $norm }
    $ignored = $false
    foreach ($r in $Rules) {
        $rNeg = [bool]$r.negated
        if ($rNeg -ne $ignored) { continue }
        if ($check -match $r.regex) {
            $ignored = (-not $rNeg)
        }
    }
    return $ignored
}

function Invoke-WorkspaceWalk {
    param(
        [string]$RootFull,
        [string]$CurrentDir,
        [array]$ParentRules = @(),
        [switch]$FilesOnly,
        [int]$Depth = 0,
        [int]$MaxDepth = 64
    )
    if ($Depth -gt $MaxDepth) { return }
    $localRules = @(Read-DirectoryIgnoreRules -RootFull $RootFull -DirFull $CurrentDir)
    $activeRules = @(if ($localRules.Count -gt 0) {
        Compress-IgnoreRules -Rules (@($ParentRules) + $localRules)
    }
    elseif ($Depth -eq 0 -and $ParentRules.Count -gt 0) {
        Compress-IgnoreRules -Rules $ParentRules
    }
    else {
        $ParentRules
    })
    $entries = @(Get-ChildItem -LiteralPath $CurrentDir -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    $dirsToEnter = @(foreach ($child in $entries) {
        if (($child.Attributes -band 1024) -ne 0) { continue }
        if ($child.PSIsContainer) {
            if ($child.Name -ieq '.git' -or $child.Name -ieq 'node_modules') { continue }
            $relDir = Get-WorkspaceRelativePath -Root $RootFull -FullPath $child.FullName
            if (Test-PathIgnored -RelativePath $relDir -IsDir $true -Rules $activeRules) { continue }
            if (-not $FilesOnly) {
                @{ item = $child; rel_path = $relDir; is_dir = $true }
            }
            $child
        }
        else {
            if (Test-IsSecretFile $child) { continue }
            $relFile = Get-WorkspaceRelativePath -Root $RootFull -FullPath $child.FullName
            if (Test-PathIgnored -RelativePath $relFile -IsDir $false -Rules $activeRules) { continue }
            @{ item = $child; rel_path = $relFile; is_dir = $false }
        }
    })
    foreach ($entryOrDir in $dirsToEnter) {
        if ($entryOrDir -is [hashtable]) {
            $entryOrDir
        }
        else {
            Invoke-WorkspaceWalk -RootFull $RootFull -CurrentDir $entryOrDir.FullName -ParentRules $activeRules -FilesOnly:$FilesOnly -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
    }
}

function Get-WorkspaceWalkEntries {
    param([string]$Root, [string]$SearchPath = '', [switch]$FilesOnly)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return @() }
    $rootFull = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\').TrimEnd('/')
    $scanItem = if ($SearchPath -and (Test-Path -LiteralPath $SearchPath)) { Get-Item -LiteralPath $SearchPath -Force } else { Get-Item -LiteralPath $Root -Force }
    if (-not $scanItem.PSIsContainer) {
        if (($scanItem.Attributes -band 1024) -ne 0 -or (Test-IsSecretFile $scanItem)) { return @() }
        $relFile = Get-WorkspaceRelativePath -Root $rootFull -FullPath $scanItem.FullName
        $rules = @(Get-WorkspaceIgnoreRules -Root $rootFull -SearchPath $scanItem.FullName)
        if (Test-PathIgnored -RelativePath $relFile -IsDir $false -Rules $rules) { return @() }
        return @(@{ item = $scanItem; rel_path = $relFile; is_dir = $false })
    }
    $scanDir = $scanItem.FullName.TrimEnd('\').TrimEnd('/')
    $ancestorRules = @(Get-AncestorIgnoreRules -RootFull $rootFull -ScanDir $scanDir)
    return @(Invoke-WorkspaceWalk -RootFull $rootFull -CurrentDir $scanDir -ParentRules $ancestorRules -FilesOnly:$FilesOnly)
}
