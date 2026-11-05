# Master tool call dispatcher.

function Invoke-AgentTool {
    param([string]$Root, $Call)
    try {
        $rawName = [string]$Call.function.name
        $name = Resolve-ToolCanonicalName -Name $rawName
        if ($name -notin @('list_files', 'read_file', 'find_files', 'grep_files', 'fetch_url', 'web_search', 'write_file', 'edit_file', 'run_command', 'run_agent', 'todo', 'ask_user', 'memory')) { throw 'Unknown tool.' }
        if ($script:AgentPermission -eq 'ReadOnly' -and $name -in @('write_file', 'edit_file', 'run_command')) {
            throw 'Permission mode ReadOnly does not allow file modifications or commands.'
        }
        if (-not (Test-IsToolEnabled -Name $name)) {
            throw "Tool '$name' is disabled by current tool configuration."
        }
        $arguments = $Call.function.arguments | ConvertFrom-Json -ErrorAction Stop
        if ($name -eq 'edit_file') {
            $arguments = Format-EditArguments -Arguments $arguments
        }
        elseif ($name -eq 'run_agent') {
            $arguments = Format-RunAgentArguments -Arguments $arguments
        }
        elseif ($name -eq 'todo') {
            $arguments = Format-TodoArguments -Arguments $arguments
        }
        elseif ($name -eq 'ask_user') {
            $arguments = Format-AskUserArguments -Arguments $arguments
        }
        elseif ($name -eq 'memory') {
            $arguments = Format-MemoryArguments -Arguments $arguments
        }
        Test-AgentToolArguments -Name $name -Arguments $arguments
        if ($name -eq 'memory') { return (Invoke-AgentMemory -Root $Root -Arguments $arguments) }
        if ($name -eq 'ask_user') { return (Invoke-AgentAskUser -Arguments $arguments) }
        if ($name -eq 'todo') { return (Invoke-AgentTodo -Arguments $arguments) }
        if ($name -eq 'fetch_url') { return (Invoke-AgentFetchUrl -Arguments $arguments) }
        if ($name -eq 'web_search') { return (Invoke-AgentWebSearch -Arguments $arguments) }
        if ($name -eq 'run_agent') { return (Invoke-AgentSubagent -Root $Root -Arguments $arguments) }
        if ($name -eq 'run_command') { return (Invoke-AgentCommand -Root $Root -Arguments $arguments) }
        if ($name -in @('write_file', 'edit_file')) { return (Invoke-AgentWrite -Root $Root -Name $name -Arguments $arguments) }
        $toolStart = Get-Date
        $allowSkill = ($name -eq 'read_file')
        $path = Resolve-AgentPath -Root $Root -RelativePath $arguments.path -AllowRegisteredSkill:$allowSkill
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($name -eq 'list_files') {
            return (Invoke-AgentListFiles -Path $path -Item $item -Arguments $arguments -ToolStart $toolStart)
        }
        if ($name -eq 'find_files') {
            return (Invoke-AgentFindFiles -Root $Root -Path $path -Item $item -Arguments $arguments -ToolStart $toolStart)
        }
        if ($name -eq 'grep_files') {
            return (Invoke-AgentGrepFiles -Root $Root -Path $path -Item $item -Arguments $arguments -ToolStart $toolStart)
        }
        return (Invoke-AgentReadFile -Path $path -Item $item -Arguments $arguments -ToolStart $toolStart)
    }
    catch { return (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
}
