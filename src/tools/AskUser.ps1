# Interactive user clarification questions and plan review approval tool (ask_user).

function Invoke-AgentAskUser {
    param($Arguments)
    $toolStart = Get-Date
    $q = [string]$Arguments.question
    $opts = @($Arguments.options)
    $intent = if ($Arguments.intent) { [string]$Arguments.intent } else { 'question' }
    $plan = if ($Arguments.plan) { [string]$Arguments.plan } else { '' }
    $allowCustom = if ($null -ne $Arguments.allow_custom) { [bool]$Arguments.allow_custom } else { $true }

    if ($script:OutputMode -eq 'json') {
        return (@{
            status    = 'cancelled'
            question  = $q
            intent    = $intent
            answer    = $null
            custom    = $null
            approved  = $false
            cancelled = $true
            message   = 'Interactive user questions are disabled in JSON mode.'
        } | ConvertTo-Json -Depth 5 -Compress)
    }

    if ($intent -eq 'plan-review' -and $plan) {
        Write-PlanReviewCard -Question $q -Plan $plan
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

    $hasCustomOpt = $false
    foreach ($it in $selectorItems) {
        $lblLow = [string]$it.label.ToLower()
        $valLow = [string]$it.value.ToLower()
        if ($lblLow -match '^(other|custom|manual)' -or $valLow -match '^(other|custom|manual)') {
            $hasCustomOpt = $true
            break
        }
    }
    if ($allowCustom -and -not $hasCustomOpt -and $selectorItems.Count -gt 0) {
        $customLabel = if ($intent -eq 'plan-review') { 'Other (type feedback)' } else { 'Other (type custom response)' }
        $customDesc = if ($intent -eq 'plan-review') { 'Provide custom feedback or instructions' } else { 'Type your own custom answer' }
        $selectorItems += @{
            label = $customLabel
            value = '__custom__'
            description = $customDesc
            active = $false
        }
    }

    $customChoice = $null
    $chosenAnswer = $null
    $isCancelled = $false
    $isApproved = $false

    $title = if ($intent -eq 'plan-review') { "Plan Review: $q" } else { "Question: $q" }
    $prompt = if ($allowCustom) { 'Select number or type response (Enter cancels)' } else { 'Select number (Enter cancels)' }
    $isPlanReview = $intent -eq 'plan-review'
    $picked = Invoke-TuiSelector -Title $title -Items $selectorItems -PromptText $prompt -AllowFreeText:$allowCustom -ExactMatch:$isPlanReview -PassThru
    if ($null -eq $picked) {
        $isCancelled = $true
    }
    elseif ($picked -is [hashtable]) {
        $chosenAnswer = [string]$picked.value
    }
    else {
        $chosenAnswer = [string]$picked
        $customChoice = $chosenAnswer
    }

    if (-not $isCancelled -and $allowCustom -and $chosenAnswer -in @('__custom__', 'other', 'custom', 'o')) {
        $promptLabel = if ($intent -eq 'plan-review') { 'Enter custom feedback: ' } else { 'Enter custom response: ' }
        Write-Host ('  ' + $script:Gm.BoldYellow + $promptLabel + $script:Gm.Fg) -NoNewline
        $custRaw = Read-Host
        Write-Host $script:Gm.Reset -NoNewline
        if ($null -ne $custRaw -and $custRaw.Trim()) {
            $chosenAnswer = $custRaw.Trim()
            $customChoice = $chosenAnswer
        }
        else {
            $isCancelled = $true
            $chosenAnswer = $null
            $customChoice = $null
        }
    }

    if (-not $isCancelled -and $isPlanReview -and $picked -is [hashtable] -and $null -eq $customChoice) {
        $approvalOption = '\A(?:Approve|Yes|Ok(?:ay)?|Accept)(?: \(Recommended\))?\z'
        $isApproved = $picked.label -match $approvalOption -and $picked.value -match $approvalOption
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
