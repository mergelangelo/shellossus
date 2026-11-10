# Tool argument normalizers (accepting common model parameter aliases and camelCase variants).

function Get-ObjectPropertyNames {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [hashtable]) { return @($InputObject.Keys) }
    return @(Get-Member -InputObject $InputObject -MemberType NoteProperty | ForEach-Object { $_.Name })
}

function Test-IsJsonObject {
    param($Value)
    # $true only when not null, not string, not ValueType, not array
    return (($null -ne $Value) -and ($Value -isnot [string]) -and ($Value -isnot [ValueType]) -and ($Value -isnot [array]))
}

function ConvertTo-NormalizedObjectArray {
    param($Value, [scriptblock]$ItemNormalizer, [scriptblock]$SingleItemDetector, [int]$MaxItems)
    # String: ConvertFrom-Json, wrap a single object.
    # One object: wrap when SingleItemDetector says so.
    # Array: normalize each object through ItemNormalizer.
    # Failures to parse a string leave the original value in place.
    if ($Value -is [string]) {
        try {
            $parsed = $Value | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -is [array]) {
                $Value = $parsed
            }
            elseif ($null -ne $parsed) {
                $Value = @($parsed)
            }
        }
        catch {
            return $Value
        }
    }
    elseif ((Test-IsJsonObject -Value $Value) -and ($null -ne $SingleItemDetector)) {
        $isSingle = & $SingleItemDetector $Value
        if ($isSingle) {
            $Value = @($Value)
        }
    }

    if ($Value -is [array]) {
        if ($MaxItems -gt 0 -and $Value.Count -gt $MaxItems) {
            throw "edits[] may contain at most $MaxItems operations."
        }
        $normArr = @()
        foreach ($item in $Value) {
            if ((Test-IsJsonObject -Value $item) -and ($null -ne $ItemNormalizer)) {
                $normArr += (& $ItemNormalizer $item)
            }
            else {
                $normArr += $item
            }
        }
        return ,$normArr
    }
    return $Value
}

function Format-EditArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $out = @{}
    foreach ($p in $props) {
        if ($p -eq 'oldText' -and ($props -notcontains 'old_text')) { $out['old_text'] = $Arguments.$p }
        elseif ($p -eq 'newText' -and ($props -notcontains 'new_text')) { $out['new_text'] = $Arguments.$p }
        elseif ($p -in @('file_path', 'filepath', 'filePath') -and ($props -notcontains 'path') -and (-not $out.ContainsKey('path'))) { $out['path'] = $Arguments.$p }
        elseif ($p -in @('oldText', 'newText', 'file_path', 'filepath', 'filePath')) {
            # Canonical name is already present. Drop the alias so validation does not see it.
        }
        else { $out[$p] = $Arguments.$p }
    }
    if ($out.ContainsKey('edits') -and $null -ne $out['edits']) {
        $out['edits'] = ConvertTo-NormalizedObjectArray -Value $out['edits'] -MaxItems $script:AgentMaxBatchEdits -ItemNormalizer {
            param($Item)
            $ip = @(Get-ObjectPropertyNames -InputObject $Item)
            $normItem = @{}
            foreach ($k in $ip) {
                if ($k -eq 'oldText' -and ($ip -notcontains 'old_text')) { $normItem['old_text'] = $Item.$k }
                elseif ($k -eq 'newText' -and ($ip -notcontains 'new_text')) { $normItem['new_text'] = $Item.$k }
                elseif ($k -eq 'oldText' -or $k -eq 'newText') {
                    # Canonical name is already present. Drop the alias so validation does not see it.
                }
                else { $normItem[$k] = $Item.$k }
            }
            return $normItem
        } -SingleItemDetector {
            param($Item)
            $names = @(Get-ObjectPropertyNames -InputObject $Item)
            return (($names -contains 'old_text' -or $names -contains 'oldText') -and ($names -contains 'new_text' -or $names -contains 'newText'))
        }
    }
    return $out
}

function Format-RunAgentArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $out = @{}
    foreach ($p in $props) {
        if ($p -eq 'task' -and ($props -notcontains 'prompt')) { $out['prompt'] = $Arguments.$p }
        elseif ($p -eq 'agent' -and ($props -notcontains 'role')) { $out['role'] = $Arguments.$p }
        elseif ($p -eq 'tasks' -and ($props -notcontains 'parallel')) { $out['parallel'] = $Arguments.$p }
        elseif (($p -eq 'chain' -or $p -eq 'steps') -and ($props -notcontains 'pipeline') -and (-not $out.ContainsKey('pipeline'))) { $out['pipeline'] = $Arguments.$p }
        elseif ($p -eq 'maxSteps' -and ($props -notcontains 'max_steps')) { $out['max_steps'] = $Arguments.$p }
        elseif ($p -in @('task', 'agent', 'tasks', 'chain', 'steps', 'maxSteps')) {
            # Canonical name is already present. Drop the alias so validation does not see it.
        }
        else { $out[$p] = $Arguments.$p }
    }
    foreach ($arrField in @('parallel', 'pipeline')) {
        if ($out.ContainsKey($arrField) -and $null -ne $out[$arrField]) {
            $out[$arrField] = ConvertTo-NormalizedObjectArray -Value $out[$arrField] -ItemNormalizer {
                param($Item)
                $ip = @(Get-ObjectPropertyNames -InputObject $Item)
                $normItem = @{}
                foreach ($k in $ip) {
                    if ($k -eq 'task' -and ($ip -notcontains 'prompt')) { $normItem['prompt'] = $Item.$k }
                    elseif ($k -eq 'agent' -and ($ip -notcontains 'role')) { $normItem['role'] = $Item.$k }
                    elseif ($k -in @('task', 'agent')) {
                        # Canonical name is already present. Drop the alias so validation does not see it.
                    }
                    else { $normItem[$k] = $Item.$k }
                }
                return $normItem
            } -SingleItemDetector {
                param($Item)
                $names = @(Get-ObjectPropertyNames -InputObject $Item)
                return ($names -contains 'prompt' -or $names -contains 'task')
            }
        }
    }
    return $out
}

function Format-TodoArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $out = @{}
    foreach ($p in $props) {
        if (($p -eq 'tasks' -or $p -eq 'items' -or $p -eq 'checklist') -and ($props -notcontains 'todos') -and (-not $out.ContainsKey('todos'))) {
            $out['todos'] = $Arguments.$p
        }
        elseif ($p -in @('tasks', 'items', 'checklist')) {
            # Canonical name is already present. Drop the alias so validation does not see it.
        }
        else {
            $out[$p] = $Arguments.$p
        }
    }
    if ($out.ContainsKey('todos') -and $null -ne $out['todos']) {
        $out['todos'] = ConvertTo-NormalizedObjectArray -Value $out['todos'] -ItemNormalizer {
            param($Item)
            $ip = @(Get-ObjectPropertyNames -InputObject $Item)
            $normItem = @{}
            foreach ($k in $ip) {
                if (($k -eq 'task' -or $k -eq 'title' -or $k -eq 'text' -or $k -eq 'description') -and ($ip -notcontains 'content') -and (-not $normItem.ContainsKey('content'))) {
                    $normItem['content'] = $Item.$k
                }
                elseif (($k -eq 'state' -or $k -eq 'done') -and ($ip -notcontains 'status') -and (-not $normItem.ContainsKey('status'))) {
                    if ($k -eq 'done' -and $Item.$k -is [bool]) {
                        $normItem['status'] = if ($Item.$k) { 'completed' } else { 'pending' }
                    }
                    else {
                        $normItem['status'] = $Item.$k
                    }
                }
                elseif ($k -in @('task', 'title', 'text', 'description', 'state', 'done')) {
                    # Canonical name is already present. Drop the alias so validation does not see it.
                }
                else {
                    $normItem[$k] = $Item.$k
                }
            }
            return $normItem
        } -SingleItemDetector {
            param($Item)
            return $true
        }
    }
    return $out
}

function Format-AskUserArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $q = ''
    foreach ($p in @('question', 'query', 'prompt', 'title', 'message', 'text')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            if ($Arguments.$p -isnot [string]) { $q = $Arguments.$p; break }
            if ($Arguments.$p) { $q = [string]$Arguments.$p; break }
        }
    }

    $intent = 'question'
    $hasExplicitIntent = $false
    foreach ($p in @('intent', 'mode', 'type')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            $hasExplicitIntent = $true
            if ($Arguments.$p -isnot [string]) { $intent = $Arguments.$p; break }
            if ($Arguments.$p) { $intent = ([string]$Arguments.$p).Trim().ToLower(); break }
        }
    }
    if ((-not $hasExplicitIntent) -and ($props -contains 'plan' -or $props -contains 'plan_review' -or $props -contains 'planReview' -or $props -contains 'plan_text' -or $props -contains 'planText' -or $props -contains 'markdown' -or $props -contains 'body' -or $props -contains 'content' -or $props -contains 'details')) {
        $intent = 'plan-review'
    }

    $plan = ''
    $hasPlanVal = $false
    foreach ($p in @('plan', 'plan_review', 'planReview', 'plan_text', 'planText', 'markdown', 'body', 'content', 'details')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            if ($Arguments.$p -isnot [string]) { $plan = $Arguments.$p; $hasPlanVal = $true; break }
            if ($Arguments.$p) { $plan = [string]$Arguments.$p; $hasPlanVal = $true; break }
        }
    }

    $allowCustom = $true
    foreach ($p in @('allow_custom', 'allowCustom', 'custom', 'free_text', 'freeText')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            if ($Arguments.$p -is [bool]) { $allowCustom = [bool]$Arguments.$p }
            else { $allowCustom = $Arguments.$p }
            break
        }
    }

    $rawOptions = $null
    foreach ($p in @('options', 'choices', 'answers', 'items')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            $rawOptions = $Arguments.$p
            break
        }
    }
    if ($rawOptions -is [string]) {
        try {
            $parsed = $rawOptions | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -is [array]) {
                $rawOptions = $parsed
            }
            elseif (Test-IsJsonObject -Value $parsed) {
                $rawOptions = @($parsed)
            }
            elseif ($null -eq $parsed) {
                # [] and null emit nothing. An empty list uses the Yes/No or plan-review default.
                $rawOptions = @()
            }
            else {
                # A parsed number or boolean is not an option list.
                $rawOptions = $parsed
            }
        }
        catch {}
    }
    # A value type is not an option list. Keep it so validation can reject the type.
    # A string that parsed into an array is no longer a value type and still normalizes.
    $keepRawOptions = $false
    if ($rawOptions -is [ValueType]) { $keepRawOptions = $true }
    $normOptions = @()
    if ($keepRawOptions) {
        $normOptions = $rawOptions
    }
    elseif ($null -ne $rawOptions) {
        foreach ($opt in @($rawOptions)) {
            if ($opt -is [string]) {
                $optStr = ([string]$opt).Trim()
                if ($optStr) {
                    $normOptions += @{ label = $optStr; value = $optStr; description = '' }
                }
            }
            elseif ($null -ne $opt -and $opt -isnot [ValueType] -and $opt -isnot [array]) {
                $op = @(Get-ObjectPropertyNames -InputObject $opt)
                $lbl = ''
                foreach ($k in @('label', 'name', 'text', 'title', 'value')) {
                    if ($op -contains $k -and $opt.$k) { $lbl = [string]$opt.$k; break }
                }
                $val = if ($op -contains 'value' -and $opt.value) { [string]$opt.value } else { $lbl }
                $desc = ''
                foreach ($k in @('description', 'desc', 'detail')) {
                    if ($op -contains $k -and $opt.$k) { $desc = [string]$opt.$k; break }
                }
                if ($lbl) {
                    $normOptions += @{ label = $lbl; value = $val; description = $desc }
                }
            }
        }
    }

    if ((-not $keepRawOptions) -and ($normOptions.Count -eq 0)) {
        if ($intent -eq 'plan-review') {
            $normOptions = @(
                @{ label = 'Approve (Recommended)'; value = 'Approve'; description = 'Accept plan and begin implementation' },
                @{ label = 'Revise'; value = 'Revise'; description = 'Request changes to the plan' },
                @{ label = 'Decline'; value = 'Decline'; description = 'Reject plan and stop' }
            )
        }
        else {
            $normOptions = @(
                @{ label = 'Yes'; value = 'Yes'; description = '' },
                @{ label = 'No'; value = 'No'; description = '' }
            )
        }
    }

    $out = @{
        question = $q
        options = $normOptions
        intent = $intent
        allow_custom = $allowCustom
    }
    if ($hasPlanVal) { $out['plan'] = $plan }
    $knownProps = @(
        'question', 'query', 'prompt', 'title', 'message', 'text',
        'plan', 'plan_review', 'planReview', 'plan_text', 'planText', 'markdown', 'body', 'content', 'details',
        'intent', 'mode', 'type',
        'allow_custom', 'allowCustom', 'custom', 'free_text', 'freeText',
        'options', 'choices', 'answers', 'items'
    )
    foreach ($p in $props) {
        if ($p -notin $knownProps) {
            $out[$p] = $Arguments.$p
        }
    }
    return $out
}

function Test-MemoryFlagTrue {
    param($Value)
    # [bool]"false" and [bool]"0" are $true. Accept only a real boolean $true or the strings true and 1.
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string] -and (($Value -ieq 'true') -or ($Value -eq '1'))) { return $true }
    return $false
}

function Format-MemoryArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $action = 'append'
    if ($props -contains 'action' -and $null -ne $Arguments.action) {
        if ($Arguments.action -is [string]) {
            if ($Arguments.action) { $action = ([string]$Arguments.action).Trim().ToLower() }
        }
        else {
            $action = $Arguments.action
        }
    }
    elseif ($props -contains 'view' -and (Test-MemoryFlagTrue $Arguments.view)) {
        $action = 'view'
    }
    elseif ($props -contains 'clear' -and (Test-MemoryFlagTrue $Arguments.clear)) {
        $action = 'clear'
    }

    $scope = 'workspace'
    if ($props -contains 'scope' -and $null -ne $Arguments.scope) {
        if ($Arguments.scope -is [string]) {
            if ($Arguments.scope) { $scope = ([string]$Arguments.scope).Trim().ToLower() }
        }
        else {
            $scope = $Arguments.scope
        }
    }

    $hasContent = $false
    $content = ''
    foreach ($p in @('content', 'note', 'text', 'memory', 'value')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            if ($Arguments.$p -is [string]) {
                if ($Arguments.$p) {
                    $content = [string]$Arguments.$p
                    $hasContent = $true
                    break
                }
            }
            else {
                $content = $Arguments.$p
                $hasContent = $true
                break
            }
        }
    }

    $out = @{
        action = $action
        scope = $scope
    }
    if ($hasContent) { $out['content'] = $content }
    $knownProps = @('action', 'view', 'clear', 'scope', 'content', 'note', 'text', 'memory', 'value')
    foreach ($p in $props) {
        if ($p -notin $knownProps) {
            $out[$p] = $Arguments.$p
        }
    }
    return $out
}

function Format-AgentToolArguments {
    param([string]$Name, $Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    if ($Name -eq 'edit_file') {
        return (Format-EditArguments -Arguments $Arguments)
    }
    if ($Name -eq 'run_agent') {
        return (Format-RunAgentArguments -Arguments $Arguments)
    }
    if ($Name -eq 'todo') {
        return (Format-TodoArguments -Arguments $Arguments)
    }
    if ($Name -eq 'ask_user') {
        return (Format-AskUserArguments -Arguments $Arguments)
    }
    if ($Name -eq 'memory') {
        return (Format-MemoryArguments -Arguments $Arguments)
    }
    if ($Name -in @('list_files', 'read_file', 'find_files', 'grep_files', 'write_file')) {
        $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
        if ($props -contains 'file_path' -or $props -contains 'filepath' -or $props -contains 'filePath') {
            $out = @{}
            foreach ($p in $props) {
                if ($p -in @('file_path', 'filepath', 'filePath')) {
                    if (($props -notcontains 'path') -and (-not $out.ContainsKey('path'))) {
                        $out['path'] = $Arguments.$p
                    }
                }
                else {
                    $out[$p] = $Arguments.$p
                }
            }
            return $out
        }
    }
    return $Arguments
}
