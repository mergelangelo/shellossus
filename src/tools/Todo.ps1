# Task state checklist and progress tracking tool (todo).

function Invoke-AgentTodo {
    param($Arguments)
    $toolStart = Get-Date
    $normList = @()
    foreach ($item in @($Arguments.todos)) {
        $cnt = [string]$item.content
        $st = ([string]$item.status).Trim().ToLower()
        if ($st -notin @('pending', 'in_progress', 'completed')) {
            $st = 'pending'
        }
        $normList += @{
            content = $cnt.Trim()
            status = $st
        }
    }
    $script:ActiveSessionTodos = @($normList)
    if ($null -ne $script:ActiveState) {
        $script:ActiveState.todos = @($normList)
    }
    $total = $normList.Count
    $completed = @($normList | Where-Object { $_.status -eq 'completed' }).Count
    $inProgress = @($normList | Where-Object { $_.status -eq 'in_progress' }).Count
    $pending = @($normList | Where-Object { $_.status -eq 'pending' }).Count
    $elapsedMs = [int](((Get-Date) - $toolStart).TotalMilliseconds)

    $summaryText = "$completed/$total completed" + $(if ($inProgress -gt 0) { ", $inProgress in progress" } else { '' })
    Write-ToolCallCard -Name 'todo' -Target "$total tasks" -Status 'ok' -Summary $summaryText -ElapsedMs $elapsedMs
    Write-TodoCard -Todos $normList

    $resultObj = @{
        success = $true
        total = $total
        completed = $completed
        in_progress = $inProgress
        pending = $pending
        todos = @($normList)
    }
    return ($resultObj | ConvertTo-Json -Depth 5 -Compress)
}
