# Tool argument normalizers (accepting common model parameter aliases and camelCase variants).

function Get-ObjectPropertyNames {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [hashtable]) { return @($InputObject.Keys) }
    return @(Get-Member -InputObject $InputObject -MemberType NoteProperty | ForEach-Object { $_.Name })
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
        if ($p -eq 'oldText') { $out['old_text'] = $Arguments.$p }
        elseif ($p -eq 'newText') { $out['new_text'] = $Arguments.$p }
        else { $out[$p] = $Arguments.$p }
    }
    if ($out.ContainsKey('edits') -and $null -ne $out['edits']) {
        $rawEdits = $out['edits']
        if ($rawEdits -is [string]) {
            try {
                $parsed = $rawEdits | ConvertFrom-Json -ErrorAction Stop
                if ($parsed -is [array]) { $rawEdits = $parsed }
                elseif ($null -ne $parsed) { $rawEdits = @($parsed) }
            }
            catch {}
        }
        elseif ($rawEdits -isnot [array] -and $rawEdits -isnot [ValueType]) {
            $edItemProps = @(Get-ObjectPropertyNames -InputObject $rawEdits)
            if (($edItemProps -contains 'old_text' -or $edItemProps -contains 'oldText') -and ($edItemProps -contains 'new_text' -or $edItemProps -contains 'newText')) {
                $rawEdits = @($rawEdits)
            }
        }
        if ($rawEdits -is [array]) {
            $normArr = @()
            foreach ($item in $rawEdits) {
                if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array]) {
                    $ip = @(Get-ObjectPropertyNames -InputObject $item)
                    $normItem = @{}
                    foreach ($k in $ip) {
                        if ($k -eq 'oldText') { $normItem['old_text'] = $item.$k }
                        elseif ($k -eq 'newText') { $normItem['new_text'] = $item.$k }
                        else { $normItem[$k] = $item.$k }
                    }
                    $normArr += $normItem
                }
                else {
                    $normArr += $item
                }
            }
            $out['edits'] = $normArr
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
        elseif (($p -eq 'chain' -or $p -eq 'steps') -and ($props -notcontains 'pipeline')) { $out['pipeline'] = $Arguments.$p }
        elseif ($p -eq 'maxSteps' -and ($props -notcontains 'max_steps')) { $out['max_steps'] = $Arguments.$p }
        else { $out[$p] = $Arguments.$p }
    }
    foreach ($arrField in @('parallel', 'pipeline')) {
        if ($out.ContainsKey($arrField) -and $null -ne $out[$arrField]) {
            $rawArr = $out[$arrField]
            if ($rawArr -is [string]) {
                try {
                    $parsed = $rawArr | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed -is [array]) { $rawArr = $parsed }
                    elseif ($null -ne $parsed) { $rawArr = @($parsed) }
                }
                catch {}
            }
            elseif ($rawArr -isnot [array] -and $rawArr -isnot [ValueType]) {
                $itemProps = @(Get-ObjectPropertyNames -InputObject $rawArr)
                if ($itemProps -contains 'prompt' -or $itemProps -contains 'task') {
                    $rawArr = @($rawArr)
                }
            }
            if ($rawArr -is [array]) {
                $normArr = @()
                foreach ($item in $rawArr) {
                    if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array]) {
                        $ip = @(Get-ObjectPropertyNames -InputObject $item)
                        $normItem = @{}
                        foreach ($k in $ip) {
                            if ($k -eq 'task' -and ($ip -notcontains 'prompt')) { $normItem['prompt'] = $item.$k }
                            elseif ($k -eq 'agent' -and ($ip -notcontains 'role')) { $normItem['role'] = $item.$k }
                            else { $normItem[$k] = $item.$k }
                        }
                        $normArr += $normItem
                    }
                    else {
                        $normArr += $item
                    }
                }
                $out[$arrField] = $normArr
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
        if (($p -eq 'tasks' -or $p -eq 'items' -or $p -eq 'checklist') -and ($props -notcontains 'todos')) {
            $out['todos'] = $Arguments.$p
        }
        else {
            $out[$p] = $Arguments.$p
        }
    }
    if ($out.ContainsKey('todos') -and $null -ne $out['todos']) {
        $rawTodos = $out['todos']
        if ($rawTodos -is [string]) {
            try {
                $parsed = $rawTodos | ConvertFrom-Json -ErrorAction Stop
                if ($parsed -is [array]) { $rawTodos = $parsed }
                elseif ($null -ne $parsed) { $rawTodos = @($parsed) }
            }
            catch {}
        }
        elseif ($rawTodos -isnot [array] -and $rawTodos -isnot [ValueType]) {
            $rawTodos = @($rawTodos)
        }
        if ($rawTodos -is [array]) {
            $normArr = @()
            foreach ($item in $rawTodos) {
                if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array]) {
                    $ip = @(Get-ObjectPropertyNames -InputObject $item)
                    $normItem = @{}
                    foreach ($k in $ip) {
                        if (($k -eq 'task' -or $k -eq 'title' -or $k -eq 'text' -or $k -eq 'description') -and ($ip -notcontains 'content')) {
                            $normItem['content'] = $item.$k
                        }
                        elseif (($k -eq 'state' -or $k -eq 'done') -and ($ip -notcontains 'status')) {
                            if ($k -eq 'done' -and $item.$k -is [bool]) {
                                $normItem['status'] = if ($item.$k) { 'completed' } else { 'pending' }
                            }
                            else {
                                $normItem['status'] = $item.$k
                            }
                        }
                        else {
                            $normItem[$k] = $item.$k
                        }
                    }
                    $normArr += $normItem
                }
                else {
                    $normArr += $item
                }
            }
            $out['todos'] = $normArr
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
    foreach ($p in @('question', 'query', 'prompt', 'title', 'message')) {
        if ($props -contains $p -and $Arguments.$p) { $q = [string]$Arguments.$p; break }
    }

    $intent = 'question'
    if ($props -contains 'intent' -and $Arguments.intent) {
        $intent = ([string]$Arguments.intent).Trim().ToLower()
    }
    elseif ($props -contains 'plan' -or $props -contains 'plan_review' -or $props -contains 'planReview') {
        $intent = 'plan-review'
    }

    $plan = ''
    foreach ($p in @('plan', 'plan_text', 'planText', 'markdown')) {
        if ($props -contains $p -and $Arguments.$p) { $plan = [string]$Arguments.$p; break }
    }

    $allowCustom = $true
    if ($props -contains 'allow_custom' -and $null -ne $Arguments.allow_custom) {
        $allowCustom = [bool]$Arguments.allow_custom
    }
    elseif ($props -contains 'allowCustom' -and $null -ne $Arguments.allowCustom) {
        $allowCustom = [bool]$Arguments.allowCustom
    }

    $rawOptions = $null
    foreach ($p in @('options', 'choices', 'answers')) {
        if ($props -contains $p -and $null -ne $Arguments.$p) {
            $rawOptions = $Arguments.$p
            break
        }
    }
    if ($rawOptions -is [string]) {
        try {
            $parsed = $rawOptions | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -is [array]) { $rawOptions = $parsed }
            elseif ($null -ne $parsed) { $rawOptions = @($parsed) }
        }
        catch {}
    }
    $normOptions = @()
    if ($null -ne $rawOptions) {
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

    if ($normOptions.Count -eq 0) {
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
    if ($plan) { $out['plan'] = $plan }
    return $out
}

function Format-MemoryArguments {
    param($Arguments, $ArgsObj = $null)
    if ($null -eq $Arguments -and $null -ne $ArgsObj) { $Arguments = $ArgsObj }
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        return $Arguments
    }
    $props = @(Get-ObjectPropertyNames -InputObject $Arguments)
    $action = 'append'
    if ($props -contains 'action' -and $Arguments.action) {
        $action = ([string]$Arguments.action).Trim().ToLower()
    }
    elseif ($props -contains 'view' -and [bool]$Arguments.view) {
        $action = 'view'
    }
    elseif ($props -contains 'clear' -and [bool]$Arguments.clear) {
        $action = 'clear'
    }

    $scope = 'workspace'
    if ($props -contains 'scope' -and $Arguments.scope) {
        $scope = ([string]$Arguments.scope).Trim().ToLower()
    }

    $content = ''
    foreach ($p in @('content', 'note', 'text', 'memory', 'value')) {
        if ($props -contains $p -and $Arguments.$p) {
            $content = [string]$Arguments.$p
            break
        }
    }

    $out = @{
        action = $action
        scope = $scope
    }
    if ($content) { $out['content'] = $content }
    return $out
}
