# Discovery and command expansion for skills (SKILL.md) and subagent roles (.shellossus/agents/*.md).

function Get-SkillsCatalog {
    param([string]$Root, [string]$ConfigDir)
    $script:RegisteredSkills = @{}
    $script:SkillsByName = @{}
    if ($script:NoSkills) { return '' }
    $dirs = @()
    if ($ConfigDir) { $dirs += (Join-Path $ConfigDir 'skills') }
    if ($Root) {
        $dirs += (Join-Path $Root '.shellossus/skills')
        $dirs += (Join-Path $Root '.h-agent/skills')
        $dirs += (Join-Path $Root 'skills')
    }
    $entries = @()
    $xmlSkills = @()
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $dItem = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        if (-not $dItem -or (($dItem.Attributes -band 1024) -ne 0)) { continue }
        $skillCountInDir = 0
        foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $d -SearchPath $d -FilesOnly)) {
            $skillFile = $walkEntry.item
            if ($skillFile.Name -ine 'SKILL.md') { continue }
            if ($skillCountInDir -ge 40) { break }
            $skillCountInDir++
            if (($skillFile.Attributes -band 1024) -ne 0 -or $skillFile.Length -gt 128KB) { continue }
            $hasReparse = $false
            $cursor = $skillFile
            while ($null -ne $cursor) {
                if (($cursor.Attributes -band 1024) -ne 0) { $hasReparse = $true; break }
                if ($cursor.PSIsContainer) { $cursor = $cursor.Parent }
                else { $cursor = $cursor.Directory }
            }
            if ($hasReparse) { continue }
            $raw = Get-Content -LiteralPath $skillFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $raw) { continue }
            $skillName = $skillFile.Directory.Name
            $skillDesc = 'Domain skill instructions.'
            $disableModelInvocation = $false
            if ($raw -match '(?m)^name:\s*(.+)$') { $skillName = $Matches[1].Trim().Trim('"', "'") }
            if ($raw -match '(?m)^description:\s*(.+)$') { $skillDesc = $Matches[1].Trim().Trim('"', "'") }
            if ($raw -match '(?m)^disable-model-invocation:\s*(true|false)\s*$') {
                $disableModelInvocation = ($Matches[1].Trim().ToLower() -eq 'true')
            }
            if ($script:SkillsByName.ContainsKey($skillName)) { continue }
            $rel = if ($Root) { Get-WorkspaceRelativePath -Root $Root -FullPath $skillFile.FullName } else { $skillFile.FullName }
            $script:RegisteredSkills[$skillFile.FullName] = $skillFile.FullName
            $script:RegisteredSkills[$rel] = $skillFile.FullName
            $script:RegisteredSkills[$skillName] = $skillFile.FullName
            $script:RegisteredSkills["skills/$skillName/SKILL.md"] = $skillFile.FullName
            $script:SkillsByName[$skillName] = @{
                name = $skillName
                description = $skillDesc
                file_path = $skillFile.FullName
                rel_path = $rel
                disable_model_invocation = $disableModelInvocation
            }
            if (-not $disableModelInvocation) {
                $entries += "- $skillName ($rel): $skillDesc"
                $xmlSkills += ("  <skill>`n    <name>" + (Escape-XmlText $skillName) + "</name>`n    <description>" + (Escape-XmlText $skillDesc) + "</description>`n    <location>" + (Escape-XmlText $rel) + "</location>`n  </skill>")
            }
        }
    }
    if ($entries.Count -eq 0) { return '' }
    return ("Available skills (use read_file on the skill path when relevant):`n" + ($entries -join "`n") + "`n<available_skills>`n" + ($xmlSkills -join "`n") + "`n</available_skills>")
}

function Resolve-SkillCommand {
    param([string]$Root, [string]$ConfigDir, [string]$InputText)
    if ($InputText -notmatch '^/skill:([a-zA-Z0-9_-]+)(?:\s+(.*))?$') { return $null }
    $skillName = $Matches[1]
    $skillArgs = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
    if (-not $script:SkillsByName -or $script:SkillsByName.Count -eq 0) {
        $null = Get-SkillsCatalog -Root $Root -ConfigDir $ConfigDir
    }
    if (-not $script:SkillsByName.ContainsKey($skillName)) { return $null }
    $skillInfo = $script:SkillsByName[$skillName]
    $raw = Get-Content -LiteralPath $skillInfo.file_path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $body = $raw -replace '(?s)^---\r?\n.*?\r?\n---\r?\n?', ''
    $expanded = Expand-TemplateArgs -Content $body.Trim() -ArgsString $skillArgs
    $outXml = "<skill name=`"$skillName`" path=`"$($skillInfo.rel_path)`">`n" + $expanded + "`n</skill>"
    if ($skillArgs -and ($body -notmatch '\$(?:\d+|@|ARGUMENTS|\{)')) {
        $outXml += "`n`nUser: $skillArgs"
    }
    return $outXml
}

function Resolve-AgentRoleCanonicalName {
    param([string]$Name)
    if (-not $Name) { return 'craft' }
    $lower = $Name.Trim().ToLower()
    switch ($lower) {
        'recon' { return 'recon' }
        'scout' { return 'recon' }
        'explore' { return 'recon' }
        'explorer' { return 'recon' }
        'research' { return 'recon' }
        'researcher' { return 'recon' }
        'audit' { return 'audit' }
        'auditor' { return 'audit' }
        'review' { return 'audit' }
        'reviewer' { return 'audit' }
        'craft' { return 'craft' }
        'worker' { return 'craft' }
        'coder' { return 'craft' }
        'builder' { return 'craft' }
        'self' { return 'craft' }
        'default' { return 'craft' }
        default { return $lower }
    }
}

function Get-BuiltinAgentRoles {
    return @(
        @{
            name = 'recon'
            permission = 'ReadOnly'
            description = 'Fast read-only codebase reconnaissance (find, grep, and read files without polluting main context).'
            system_prompt = 'You are a Shellossus recon subagent operating in ReadOnly mode. Explore the workspace efficiently using list_files, find_files, grep_files, and read_file. Do not attempt to modify files or run commands. Return a concise, factual report with exact file paths and line numbers.'
            tools = @()
            model = ''
            builtin = $true
        },
        @{
            name = 'audit'
            permission = 'ReadOnly'
            description = 'Read-only code review, bug hunting, and security/correctness verification.'
            system_prompt = 'You are a Shellossus audit subagent operating in ReadOnly mode. Inspect the target code for bugs, edge cases, security issues, and regressions. Cite exact file paths and line numbers and prioritize actionable findings.'
            tools = @()
            model = ''
            builtin = $true
        },
        @{
            name = 'craft'
            permission = 'inherit'
            description = 'Full-capability implementation subagent that inherits session permissions to read, edit files, and run commands.'
            system_prompt = 'You are a Shellossus craft subagent. Complete the delegated engineering task accurately within workspace boundaries, verify your changes, and return a concise summary of what you changed and why.'
            tools = @()
            model = ''
            builtin = $true
        }
    )
}

function Get-AgentRolesCatalog {
    param([string]$Root, [string]$ConfigDir)
    $script:AgentRolesByName = @{}
    foreach ($bRole in @(Get-BuiltinAgentRoles)) {
        $script:AgentRolesByName[$bRole.name] = $bRole
    }
    $dirs = @()
    if ($ConfigDir) { $dirs += (Join-Path $ConfigDir 'agents') }
    if ($Root) {
        $dirs += (Join-Path $Root '.shellossus/agents')
        $dirs += (Join-Path $Root '.h-agent/agents')
        $dirs += (Join-Path $Root 'agents')
    }
    $customEntries = @()
    $xmlAgents = @()
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $dItem = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        if (-not $dItem -or (($dItem.Attributes -band 1024) -ne 0)) { continue }
        $roleCountInDir = 0
        foreach ($walkEntry in @(Get-WorkspaceWalkEntries -Root $d -SearchPath $d -FilesOnly)) {
            $roleFile = $walkEntry.item
            if ($roleFile.Extension -ine '.md') { continue }
            if ($roleCountInDir -ge 40) { break }
            $roleCountInDir++
            if (($roleFile.Attributes -band 1024) -ne 0 -or $roleFile.Length -gt 128KB) { continue }
            $hasReparse = $false
            $cursor = $roleFile
            while ($null -ne $cursor) {
                if (($cursor.Attributes -band 1024) -ne 0) { $hasReparse = $true; break }
                if ($cursor.PSIsContainer) { $cursor = $cursor.Parent }
                else { $cursor = $cursor.Directory }
            }
            if ($hasReparse) { continue }
            $raw = Get-Content -LiteralPath $roleFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $raw) { continue }
            $baseName = ($roleFile.Name -replace '\.md$', '').ToLower()
            $roleName = $baseName
            $roleDesc = 'Custom subagent role.'
            $rolePerm = 'inherit'
            $roleModel = ''
            $roleTools = @()
            if ($raw -match '(?m)^name:\s*(.+)$') { $roleName = $Matches[1].Trim().Trim('"', "'").ToLower() }
            if ($raw -match '(?m)^description:\s*(.+)$') { $roleDesc = $Matches[1].Trim().Trim('"', "'") }
            if ($raw -match '(?m)^permission:\s*(.+)$') {
                $pVal = $Matches[1].Trim().Trim('"', "'")
                if ($pVal -ieq 'ReadOnly') { $rolePerm = 'ReadOnly' }
            }
            if ($raw -match '(?m)^model:\s*(.+)$') { $roleModel = $Matches[1].Trim().Trim('"', "'") }
            if ($raw -match '(?m)^tools:\s*(.+)$') {
                $tRaw = $Matches[1].Trim().Trim('"', "'", '[', ']')
                $roleTools = @($tRaw -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                if ($roleTools.Count -gt 0) {
                    $hasWriteOrExec = $false
                    foreach ($rt in $roleTools) {
                        $cRt = Resolve-ToolCanonicalName -Name $rt
                        if ($cRt -in @('write_file', 'edit_file', 'run_command')) { $hasWriteOrExec = $true; break }
                    }
                    if (-not $hasWriteOrExec) { $rolePerm = 'ReadOnly' }
                }
            }
            $body = ($raw -replace '(?s)^---\r?\n.*?\r?\n---\r?\n?', '').Trim()
            if (-not $body) { $body = $roleDesc }
            $rel = if ($Root) { Get-WorkspaceRelativePath -Root $Root -FullPath $roleFile.FullName } else { $roleFile.FullName }
            $roleObj = @{
                name = $roleName
                permission = $rolePerm
                description = $roleDesc
                system_prompt = $body
                tools = $roleTools
                model = $roleModel
                file_path = $roleFile.FullName
                rel_path = $rel
                builtin = $false
            }
            $script:AgentRolesByName[$roleName] = $roleObj
            $customEntries += "- $roleName ($rel, permission=$rolePerm): $roleDesc"
            $xmlAgents += ("  <agent>`n    <name>" + (Escape-XmlText $roleName) + "</name>`n    <permission>" + (Escape-XmlText $rolePerm) + "</permission>`n    <description>" + (Escape-XmlText $roleDesc) + "</description>`n    <location>" + (Escape-XmlText $rel) + "</location>`n  </agent>")
        }
    }
    if ($customEntries.Count -eq 0) { return '' }
    return ("Custom subagent roles (invoke via run_agent role=<name>):`n" + ($customEntries -join "`n") + "`n<available_agents>`n" + ($xmlAgents -join "`n") + "`n</available_agents>")
}

function Resolve-AgentRole {
    param([string]$Name, [string]$Root = '', [string]$ConfigDir = '')
    if (-not $script:AgentRolesByName -or $script:AgentRolesByName.Count -eq 0) {
        $null = Get-AgentRolesCatalog -Root $Root -ConfigDir $ConfigDir
    }
    $canon = Resolve-AgentRoleCanonicalName -Name $Name
    if ($script:AgentRolesByName.ContainsKey($canon)) {
        return $script:AgentRolesByName[$canon]
    }
    $avail = @($script:AgentRolesByName.Keys | Sort-Object) -join ', '
    throw "Unknown agent role '$Name'. Available roles: $avail."
}

function Resolve-AgentRoleCommand {
    param([string]$Root, [string]$ConfigDir, [string]$InputText)
    if ($InputText -notmatch '^/agent:([a-zA-Z0-9_-]+)(?:\s+(.*))?$') { return $null }
    $rawRole = $Matches[1]
    $roleArgs = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
    if (-not $script:AgentRolesByName -or $script:AgentRolesByName.Count -eq 0) {
        $null = Get-AgentRolesCatalog -Root $Root -ConfigDir $ConfigDir
    }
    $canonRole = Resolve-AgentRoleCanonicalName -Name $rawRole
    if (-not $script:AgentRolesByName.ContainsKey($canonRole)) { return $null }
    $roleInfo = $script:AgentRolesByName[$canonRole]
    $expanded = Expand-TemplateArgs -Content $roleInfo.system_prompt -ArgsString $roleArgs
    $outXml = "<agent_role name=`"$($roleInfo.name)`" permission=`"$($roleInfo.permission)`">`n" + $expanded + "`n</agent_role>"
    if ($roleArgs) {
        $outXml += "`n`nDelegate this task using run_agent with role=`"$($roleInfo.name)`": $roleArgs"
    }
    return $outXml
}
