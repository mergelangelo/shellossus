# Interactive user clarification questions and plan review approval tool (ask_user).

function Invoke-AgentAskUser {
    param($Arguments)
    $toolStart = Get-Date
    $q = [string]$Arguments.question
    $opts = @($Arguments.options)
    $intent = if ($Arguments.intent) { [string]$Arguments.intent } else { 'question' }
    $plan = if ($Arguments.plan) { [string]$Arguments.plan } else { '' }
    $allowCustom = if ($null -ne $Arguments.allow_custom) { [bool]$Arguments.allow_custom } else { $true }

    if ($script:OutputMode -ne 'json') {
        if ($intent -eq 'plan-review' -and $plan) {
            Write-PlanReviewCard -Question $q -Plan $plan
        }
    }

    $selectorItems = @()
    foreach ($opt in $opts) {
        $lbl = [string]$opt.label
        $val = if ($opt.value) { [string]$opt.value } else { $lbl }
        $desc = if ($opt.description) { [string]$opt.description } else { '' }
        $selectorItems += @{
            label = $lbl
            value = $val
            description = $desc
            active = $false
        }
    }

    $customChoice = $null
    $chosenAnswer = $null
    $isCancelled = $false
    $isApproved = $false

    if ($script:OutputMode -eq 'json') {
        $mocked = Read-Host
        if ($mocked -and $mocked.Trim()) {
            $trimmedMock = $mocked.Trim()
            if ($trimmedMock -match '^\d+$') {
                $idx = [int]$trimmedMock - 1
                if ($idx -ge 0 -and $idx -lt $selectorItems.Count) {
                    $chosenAnswer = $selectorItems[$idx].value
                }
                else {
                    $chosenAnswer = $trimmedMock
                }
            }
            else {
                $matchedItem = $selectorItems | Where-Object { $_.value -ieq $trimmedMock -or $_.label -ieq $trimmedMock } | Select-Object -First 1
                if ($matchedItem) {
                    $chosenAnswer = $matchedItem.value
                }
                else {
                    $chosenAnswer = $trimmedMock
                    $customChoice = $trimmedMock
                }
            }
        }
        else {
            if ($selectorItems.Count -gt 0) {
                $chosenAnswer = $selectorItems[0].value
            }
            else {
                $isCancelled = $true
            }
        }
    }
    else {
        $title = if ($intent -eq 'plan-review') { "Plan Review: $q" } else { "Question: $q" }
        $prompt = if ($allowCustom) { 'Select number or type response (Enter cancels)' } else { 'Select number (Enter cancels)' }
        $picked = Invoke-TuiSelector -Title $title -Items $selectorItems -PromptText $prompt -AllowFreeText:$allowCustom
        if ($null -eq $picked -or -not [string]$picked.Trim()) {
            $isCancelled = $true
        }
        else {
            $pickedStr = [string]$picked.Trim()
            $matchedItem = $selectorItems | Where-Object { $_.value -ieq $pickedStr -or $_.label -ieq $pickedStr } | Select-Object -First 1
            if ($matchedItem) {
                $chosenAnswer = $matchedItem.value
            }
            else {
                $chosenAnswer = $pickedStr
                $customChoice = $pickedStr
            }
        }
    }

    if (-not $isCancelled -and $intent -eq 'plan-review') {
        if ($chosenAnswer -match '^(Approve|Yes|Ok|Accept)') {
            $isApproved = $true
        }
    }

    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)
    $summaryText = if ($isCancelled) {
        'cancelled'
    }
    elseif ($intent -eq 'plan-review') {
        if ($isApproved) { "Approved ($chosenAnswer)" } else { "Feedback ($chosenAnswer)" }
    }
    else {
        "Answered: $chosenAnswer"
    }

    $statusVal = if ($isCancelled) { 'cancelled' } else { 'ok' }
    Write-ToolCallCard -Name 'ask_user' -Target $intent -Detail $q -Status $statusVal -Summary $summaryText -ElapsedMs $elapsedMs

    $resultObj = @{
        question = $q
        intent = $intent
        answer = $chosenAnswer
        custom = $customChoice
        approved = $isApproved
        cancelled = $isCancelled
    }
    return ($resultObj | ConvertTo-Json -Depth 5 -Compress)
}
