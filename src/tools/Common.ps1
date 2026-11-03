# Agent tools, permission modes, strict argument validation, fuzzy/batch file edits, shell runner, and disk undo.

$script:CurrentTurnWrites = @()
$script:AgentPermission = 'Ask'
$script:OutputMode = 'text'
$script:ShowReasoning = 'compact'
$script:ReasoningEffort = ''
$script:NoTools = $false
$script:EnabledTools = @()
$script:ExcludedTools = @()
$script:ActiveSessionId = ''
$script:ActiveSessionFile = ''
$script:ActiveModelId = ''
$script:Diagnostics = $false
$script:MaxRepeatToolCalls = 3
$script:ActiveWorkspace = ''
$script:ActiveEndpoint = ''
$script:ActiveApiKey = ''
$script:ActiveState = $null
$script:SubagentDepth = 0
$script:MaxSubagentDepth = 1
$script:ActiveSessionTodos = @()

function Resolve-ToolCanonicalName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $lower = $Name.Trim().ToLower()
    switch ($lower) {
        'read' { return 'read_file' }
        'ls' { return 'list_files' }
        'find' { return 'find_files' }
        'grep' { return 'grep_files' }
        'write' { return 'write_file' }
        'edit' { return 'edit_file' }
        'bash' { return 'run_command' }
        'powershell' { return 'run_command' }
        'subagent' { return 'run_agent' }
        'delegate' { return 'run_agent' }
        'delegate_task' { return 'run_agent' }
        'spawn_agent' { return 'run_agent' }
        'fetch' { return 'fetch_url' }
        'web_fetch' { return 'fetch_url' }
        'webfetch' { return 'fetch_url' }
        'search_web' { return 'web_search' }
        'websearch' { return 'web_search' }
        'todo' { return 'todo' }
        'todos' { return 'todo' }
        'manage_todo' { return 'todo' }
        'task_board' { return 'todo' }
        'tasks' { return 'todo' }
        'ask_user' { return 'ask_user' }
        'ask' { return 'ask_user' }
        'ask_question' { return 'ask_user' }
        'ask_user_question' { return 'ask_user' }
        'plan_review' { return 'ask_user' }
        'plan-review' { return 'ask_user' }
        'question' { return 'ask_user' }
        'user_question' { return 'ask_user' }
        'memory' { return 'memory' }
        'remember' { return 'memory' }
        'manage_memory' { return 'memory' }
        'recall' { return 'memory' }
        'note' { return 'memory' }
        default { return $lower }
    }
}

function Test-IsToolEnabled {
    param([string]$Name)
    $canon = Resolve-ToolCanonicalName -Name $Name
    if ($script:NoTools) { return $false }
    if ($canon -eq 'run_agent' -and $script:SubagentDepth -ge $script:MaxSubagentDepth) {
        return $false
    }
    if ($script:AgentPermission -eq 'ReadOnly' -and $canon -in @('write_file', 'edit_file', 'run_command')) {
        return $false
    }
    if ($script:EnabledTools -and $script:EnabledTools.Count -gt 0) {
        $matched = $false
        foreach ($pat in $script:EnabledTools) {
            $normPat = Resolve-ToolCanonicalName -Name $pat
            if ($canon -like $normPat -or $Name -like $pat) { $matched = $true; break }
        }
        if (-not $matched) { return $false }
    }
    if ($script:ExcludedTools -and $script:ExcludedTools.Count -gt 0) {
        foreach ($pat in $script:ExcludedTools) {
            $normPat = Resolve-ToolCanonicalName -Name $pat
            if ($canon -like $normPat -or $Name -like $pat) { return $false }
        }
    }
    return $true
}

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return "${Bytes}B" }
    if ($Bytes -lt 1048576) {
        $kb = [int](($Bytes * 10) / 1024)
        $frac = $kb % 10
        $whole = ($kb - $frac) / 10
        return "${whole}.${frac}KB"
    }
    $mb = [int](($Bytes * 10) / 1048576)
    $fracMb = $mb % 10
    $wholeMb = ($mb - $fracMb) / 10
    return "${wholeMb}.${fracMb}MB"
}

function Invoke-TruncateLine {
    param([string]$Line, [int]$MaxChars = 500)
    if ($null -eq $Line) { return @{ text = ''; wasTruncated = $false; was_truncated = $false } }
    if ($Line.Length -le $MaxChars) {
        return @{ text = $Line; wasTruncated = $false; was_truncated = $false }
    }
    return @{ text = ($Line.Substring(0, $MaxChars) + '... [truncated]'); wasTruncated = $true; was_truncated = $true }
}

function Invoke-TruncateHead {
    param([string]$Content, [int]$MaxLines = 2000, [int]$MaxBytes = 51200)
    if (-not $Content) {
        return @{
            content = ''
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = 0
            total_lines = 0
            totalBytes = 0
            total_bytes = 0
            outputLines = 0
            output_lines = 0
            outputBytes = 0
            output_bytes = 0
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $norm = $Content.Replace("`r`n", "`n")
    $lines = @($norm -split "`n")
    if ($norm.EndsWith("`n") -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $totalLines = $lines.Count
    $totalBytes = $norm.Length
    if ($totalLines -le $MaxLines -and $totalBytes -le $MaxBytes) {
        return @{
            content = $norm
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = $totalLines
            total_lines = $totalLines
            totalBytes = $totalBytes
            total_bytes = $totalBytes
            outputLines = $totalLines
            output_lines = $totalLines
            outputBytes = $totalBytes
            output_bytes = $totalBytes
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    if ($lines.Count -gt 0 -and ([string]$lines[0]).Length -gt $MaxBytes) {
        return @{
            content = ''
            truncated = $true
            truncatedBy = 'bytes'
            truncated_by = 'bytes'
            totalLines = $totalLines
            total_lines = $totalLines
            totalBytes = $totalBytes
            total_bytes = $totalBytes
            outputLines = 0
            output_lines = 0
            outputBytes = 0
            output_bytes = 0
            lastLinePartial = $false
            firstLineExceedsLimit = $true
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $outBytes = 0
    $truncBy = 'lines'
    $outLines = @(for ($i = 0; $i -lt $lines.Count -and $i -lt $MaxLines; $i++) {
        $ln = [string]$lines[$i]
        $lnBytes = $ln.Length + $(if ($i -gt 0) { 1 } else { 0 })
        if (($outBytes + $lnBytes) -gt $MaxBytes) {
            $truncBy = 'bytes'
            break
        }
        $outBytes += $lnBytes
        $ln
    })
    if ($outLines.Count -ge $MaxLines -and $outBytes -le $MaxBytes) {
        $truncBy = 'lines'
    }
    $outText = $outLines -join "`n"
    return @{
        content = $outText
        truncated = $true
        truncatedBy = $truncBy
        truncated_by = $truncBy
        totalLines = $totalLines
        total_lines = $totalLines
        totalBytes = $totalBytes
        total_bytes = $totalBytes
        outputLines = $outLines.Count
        output_lines = $outLines.Count
        outputBytes = $outText.Length
        output_bytes = $outText.Length
        lastLinePartial = $false
        firstLineExceedsLimit = $false
        maxLines = $MaxLines
        maxBytes = $MaxBytes
    }
}

function Invoke-TruncateTail {
    param([string]$Content, [int]$MaxLines = 2000, [int]$MaxBytes = 51200)
    if (-not $Content) {
        return @{
            content = ''
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = 0
            total_lines = 0
            totalBytes = 0
            total_bytes = 0
            outputLines = 0
            output_lines = 0
            outputBytes = 0
            output_bytes = 0
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $norm = $Content.Replace("`r`n", "`n")
    $lines = @($norm -split "`n")
    if ($norm.EndsWith("`n") -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $totalLines = $lines.Count
    $totalBytes = $norm.Length
    if ($totalLines -le $MaxLines -and $totalBytes -le $MaxBytes) {
        return @{
            content = $norm
            truncated = $false
            truncatedBy = $null
            truncated_by = $null
            totalLines = $totalLines
            total_lines = $totalLines
            totalBytes = $totalBytes
            total_bytes = $totalBytes
            outputLines = $totalLines
            output_lines = $totalLines
            outputBytes = $totalBytes
            output_bytes = $totalBytes
            lastLinePartial = $false
            firstLineExceedsLimit = $false
            maxLines = $MaxLines
            maxBytes = $MaxBytes
        }
    }
    $outBytes = 0
    $truncBy = 'lines'
    $lastPartial = $false
    $revLines = @(for ($i = $lines.Count - 1; $i -ge 0 -and (($lines.Count - 1 - $i) -lt $MaxLines); $i--) {
        $ln = [string]$lines[$i]
        $isFirst = ($i -eq ($lines.Count - 1))
        $lnBytes = $ln.Length + $(if (-not $isFirst) { 1 } else { 0 })
        if (($outBytes + $lnBytes) -gt $MaxBytes) {
            $truncBy = 'bytes'
            if ($isFirst -and $ln.Length -gt $MaxBytes) {
                $lastPartial = $true
                $ln.Substring($ln.Length - $MaxBytes)
            }
            break
        }
        $outBytes += $lnBytes
        $ln
    })
    $outLines = @(for ($j = $revLines.Count - 1; $j -ge 0; $j--) {
        $revLines[$j]
    })
    if ($outLines.Count -ge $MaxLines -and $outBytes -le $MaxBytes) {
        $truncBy = 'lines'
    }
    $outText = $outLines -join "`n"
    return @{
        content = $outText
        truncated = $true
        truncatedBy = $truncBy
        truncated_by = $truncBy
        totalLines = $totalLines
        total_lines = $totalLines
        totalBytes = $totalBytes
        total_bytes = $totalBytes
        outputLines = $outLines.Count
        output_lines = $outLines.Count
        outputBytes = $outText.Length
        output_bytes = $outText.Length
        lastLinePartial = $lastPartial
        firstLineExceedsLimit = $false
        maxLines = $MaxLines
        maxBytes = $MaxBytes
    }
}

function Get-AgentEnvironment {
    param([string]$Root = '')
    $effRoot = if ($Root) { $Root } elseif ($script:ActiveWorkspace) { $script:ActiveWorkspace } else { (Get-Location).Path }
    if ($effRoot -and (Test-Path -LiteralPath $effRoot)) {
        $item = Get-Item -LiteralPath $effRoot -Force -ErrorAction SilentlyContinue
        if ($item) { $effRoot = $item.FullName }
    }
    $osDesc = if ($PSVersionTable -and $PSVersionTable.OS) {
        [string]$PSVersionTable.OS
    }
    elseif ($env:OS) {
        [string]$env:OS
    }
    elseif ($PSVersionTable -and $PSVersionTable.Platform) {
        [string]$PSVersionTable.Platform
    }
    else {
        'Windows'
    }
    $psVer = if ($PSVersionTable -and $PSVersionTable.PSVersion) { [string]$PSVersionTable.PSVersion } else { '5.1' }
    $editionName = if ($PSVersionTable -and $PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
    $langMode = if ($ExecutionContext -and $ExecutionContext.SessionState -and $ExecutionContext.SessionState.LanguageMode) {
        [string]$ExecutionContext.SessionState.LanguageMode
    }
    else {
        'FullLanguage'
    }
    $preferPwsh = ($editionName -eq 'Core')
    $shellCmd = if ($preferPwsh) {
        $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command -Name 'powershell' -ErrorAction SilentlyContinue }
        $c
    }
    else {
        $c = Get-Command -Name 'powershell' -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue }
        $c
    }
    $shellExe = if ($shellCmd -and $shellCmd.Name) {
        if ($shellCmd.Name -match '(?i)^pwsh') { 'pwsh' } else { 'powershell' }
    }
    elseif ($preferPwsh) {
        'pwsh'
    }
    else {
        'powershell'
    }
    $shellVer = $psVer
    if ($shellCmd -and $shellCmd.Version -and ([string]$shellCmd.Version -ne '0.0.0.0')) {
        $shellVer = [string]$shellCmd.Version
    }
    return @{
        os = $osDesc
        ps_version = $psVer
        ps_edition = $editionName
        language_mode = $langMode
        shell_exe = $shellExe
        shell_version = $shellVer
        workspace = [string]$effRoot
    }
}

function Get-AgentCapabilities {
    param([string]$Root = '')
    $envInfo = Get-AgentEnvironment -Root $Root
    $perm = if ($script:AgentPermission -in @('ReadOnly', 'Ask', 'AutoEdit', 'Auto')) { $script:AgentPermission } else { 'Ask' }
    $tools = @()
    $toolNames = @()
    foreach ($name in @('list_files', 'read_file')) {
        if (-not (Test-IsToolEnabled -Name $name)) { continue }
        $description = 'List up to 200 entries in a directory. Names only; no file contents.'
        $properties = @{
            path = @{ type = 'string'; description = 'Workspace-relative path; . means the root.' }
        }
        if ($name -eq 'list_files') {
            $properties.limit = @{ type = 'integer'; description = 'Optional maximum number of entries to return (1..500, default 200).' }
        }
        if ($name -eq 'read_file') {
            $description = 'Read a UTF-8 text file: up to 300 lines and 20000 characters, maximum file size 1 MiB. Returns total_lines and pagination metadata.'
            $properties.start_line = @{ type = 'integer'; description = 'Optional 1-based first line to read (default 1).' }
            $properties.max_lines = @{ type = 'integer'; description = 'Optional maximum number of lines to read (1..300, default 300).' }
            $properties.start_char = @{ type = 'integer'; description = 'Optional 1-based character offset within start_line for reading long lines (default 1).' }
            $properties.offset = @{ type = 'integer'; description = 'Optional alias for start_line (1-based line offset).' }
            $properties.limit = @{ type = 'integer'; description = 'Optional alias for max_lines (1..300).' }
        }
        $toolNames += $name
        $tools += @{
            type = 'function'
            function = @{
                name = $name
                description = $description
                parameters = @{
                    type = 'object'
                    properties = $properties
                    required = @('path')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'find_files') {
        $toolNames += 'find_files'
        $tools += @{
            type = 'function'
            function = @{
                name = 'find_files'
                description = 'Find files or directories recursively by wildcard pattern (e.g. *.sql, src/*.ps1), respecting .gitignore/.ignore.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        path = @{ type = 'string'; description = 'Workspace-relative directory path; . means the root.' }
                        pattern = @{ type = 'string'; description = 'File name or relative path wildcard pattern, e.g. *.sql or src/*.ps1.' }
                        limit = @{ type = 'integer'; description = 'Optional maximum number of results (1..1000, default 200).' }
                    }
                    required = @('path', 'pattern')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'grep_files') {
        $toolNames += 'grep_files'
        $tools += @{
            type = 'function'
            function = @{
                name = 'grep_files'
                description = 'Search UTF-8 text files for a regex or literal pattern (respecting .gitignore/.ignore), returning matching paths, line numbers, and lines.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        path = @{ type = 'string'; description = 'Workspace-relative file or directory path; . means the root.' }
                        pattern = @{ type = 'string'; description = 'Regex or literal search pattern.' }
                        literal = @{ type = 'boolean'; description = 'Set true for literal substring match instead of regex.' }
                        case_sensitive = @{ type = 'boolean'; description = 'Set true for case-sensitive matching.' }
                        include = @{ type = 'string'; description = 'Optional file name wildcard filter, e.g. *.sql or *.ps1.' }
                        glob = @{ type = 'string'; description = 'Optional alias for include wildcard filter.' }
                        context_lines = @{ type = 'integer'; description = 'Optional surrounding context lines (0..5).' }
                        limit = @{ type = 'integer'; description = 'Optional maximum number of matches to return (1..500, default 100).' }
                        file_offset = @{ type = 'integer'; description = 'Optional 0-based file offset. To continue, use next_file_offset together with next_start_line from the previous result (default 0).' }
                        start_line = @{ type = 'integer'; description = 'Optional 1-based first matching line to include in the file at file_offset; later files start at line 1 (default 1).' }
                    }
                    required = @('path', 'pattern')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'fetch_url') {
        $toolNames += 'fetch_url'
        $tools += @{
            type = 'function'
            function = @{
                name = 'fetch_url'
                description = 'Fetch an HTTP/HTTPS URL and return readable text, Markdown, or JSON content (up to 20000 characters by default).'
                parameters = @{
                    type = 'object'
                    properties = @{
                        url = @{ type = 'string'; description = 'HTTP or HTTPS URL to fetch.' }
                        max_chars = @{ type = 'integer'; description = 'Optional maximum characters to return (500..50000, default 20000).' }
                        raw = @{ type = 'boolean'; description = 'Optional: set true to return raw HTML without tag stripping.' }
                    }
                    required = @('url')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'web_search') {
        $toolNames += 'web_search'
        $tools += @{
            type = 'function'
            function = @{
                name = 'web_search'
                description = 'Search the web for a query and return matching result titles, URLs, and snippets.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        query = @{ type = 'string'; description = 'Search query text.' }
                        limit = @{ type = 'integer'; description = 'Optional maximum number of results (1..20, default 8).' }
                    }
                    required = @('query')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'todo') {
        $toolNames += 'todo'
        $tools += @{
            type = 'function'
            function = @{
                name = 'todo'
                description = 'Track task plan and progress during multi-step work. Call this to initialize or update the active todo list (replaces entire list on each call).'
                parameters = @{
                    type = 'object'
                    properties = @{
                        todos = @{
                            type = 'array'
                            description = 'Complete ordered list of task items: array of {content, status}. Status must be pending, in_progress, or completed.'
                            items = @{
                                type = 'object'
                                properties = @{
                                    content = @{ type = 'string'; description = 'Clear, concise description of the task.' }
                                    status = @{ type = 'string'; description = 'Task status: pending, in_progress, or completed.' }
                                }
                                required = @('content', 'status')
                            }
                        }
                    }
                    required = @('todos')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'ask_user') {
        $toolNames += 'ask_user'
        $tools += @{
            type = 'function'
            function = @{
                name = 'ask_user'
                description = 'Ask the user a concise question, request an architectural decision, or present a Markdown implementation plan for explicit review and approval before making changes.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        question = @{
                            type = 'string'
                            description = 'The question or plan summary to present to the user.'
                        }
                        options = @{
                            type = 'array'
                            description = 'Optional choices to show the user (list of strings or objects with label and description). Put recommended choice first.'
                            items = @{ type = 'string' }
                        }
                        intent = @{
                            type = 'string'
                            description = "Presentation intent: 'question' for architectural/decision choices (default), or 'plan-review' for reviewing a Markdown plan before modifying files."
                            enum = @('question', 'plan-review')
                        }
                        plan = @{
                            type = 'string'
                            description = "Markdown text of the plan under review (used when intent is 'plan-review')."
                        }
                        allow_custom = @{
                            type = 'boolean'
                            description = 'Whether the user can provide custom free-text feedback if none of the options fit (default true).'
                        }
                    }
                    required = @('question')
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'memory') {
        $toolNames += 'memory'
        $tools += @{
            type = 'function'
            function = @{
                name = 'memory'
                description = 'Record, view, or manage persistent long-term memories, user preferences, and project invariants that survive across CLI sessions in MEMORY.md.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        action = @{
                            type = 'string'
                            description = "Action to perform: 'append' to add a new memory note (default), 'view' to read memory, 'set' to replace memory content, or 'clear' to reset."
                            enum = @('append', 'view', 'set', 'clear')
                        }
                        content = @{
                            type = 'string'
                            description = "The fact, preference, or architectural invariant to record (required for 'append' and 'set')."
                        }
                        scope = @{
                            type = 'string'
                            description = "Storage scope: 'workspace' (default, stored in .shellossus/MEMORY.md) or 'global' (stored in global config MEMORY.md)."
                            enum = @('workspace', 'global')
                        }
                    }
                }
            }
        }
    }
    if ($perm -ne 'ReadOnly') {
        foreach ($name in @('write_file', 'edit_file')) {
            if (-not (Test-IsToolEnabled -Name $name)) { continue }
            $properties = @{ path = @{ type = 'string'; description = 'Workspace-relative text file path. Parent directory must exist.' } }
            if ($name -eq 'write_file') {
                $description = 'Create a UTF-8 text file (or overwrite when overwrite=true).'
                $properties.content = @{ type = 'string'; description = 'Complete file contents, up to 1 MiB.' }
                $properties.overwrite = @{ type = 'boolean'; description = 'Set true to overwrite an existing file (saves a backup).' }
                $required = @('path', 'content')
            }
            else {
                $description = 'Replace one or more unique blocks in a UTF-8 text file (supports single old_text/new_text or batch edits[] array; saves a backup).'
                $properties.old_text = @{ type = 'string'; description = 'Single edit: nonempty text occurring once in the file.' }
                $properties.new_text = @{ type = 'string'; description = 'Single edit: replacement text.' }
                $properties.edits = @{
                    type = 'array'
                    description = 'Optional batch of non-overlapping edits: array of {old_text, new_text} objects.'
                    items = @{
                        type = 'object'
                        properties = @{
                            old_text = @{ type = 'string' }
                            new_text = @{ type = 'string' }
                        }
                        required = @('old_text', 'new_text')
                    }
                }
                $required = @('path')
            }
            $toolNames += $name
            $tools += @{ type = 'function'; function = @{ name = $name; description = $description; parameters = @{ type = 'object'; properties = $properties; required = $required } } }
        }
        if (Test-IsToolEnabled -Name 'run_command') {
            $toolNames += 'run_command'
            $tools += @{
                type = 'function'
                function = @{
                    name = 'run_command'
                    description = 'Execute a PowerShell command in the workspace directory.'
                    parameters = @{
                        type = 'object'
                        properties = @{
                            command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                            timeout_sec = @{ type = 'integer'; description = 'Optional timeout in seconds (1..600, default 60).' }
                        }
                        required = @('command')
                    }
                }
            }
        }
    }
    if (Test-IsToolEnabled -Name 'run_agent') {
        $toolNames += 'run_agent'
        $tools += @{
            type = 'function'
            function = @{
                name = 'run_agent'
                description = 'Delegate a task, parallel fan-out, or sequential pipeline to isolated subagents (roles: recon [ReadOnly], audit [ReadOnly], craft [inherits permission]). Keeps main context clean.'
                parameters = @{
                    type = 'object'
                    properties = @{
                        role = @{ type = 'string'; description = 'Optional subagent role: recon (ReadOnly search), audit (ReadOnly review), craft (inherits permission), or custom role name.' }
                        prompt = @{ type = 'string'; description = 'Single-task instruction for the subagent (mutually exclusive with parallel and pipeline).' }
                        context = @{ type = 'string'; description = 'Optional context mode for single/pipeline tasks: clean (default, fresh context) or fork (clones parent conversation history).' }
                        max_steps = @{ type = 'integer'; description = 'Optional step budget per subagent run (1..50, default 15).' }
                        parallel = @{
                            type = 'array'
                            description = 'Concurrent ReadOnly fan-out tasks (1..8 items of {role, prompt}).'
                            items = @{
                                type = 'object'
                                properties = @{
                                    role = @{ type = 'string' }
                                    prompt = @{ type = 'string' }
                                }
                                required = @('prompt')
                            }
                        }
                        pipeline = @{
                            type = 'array'
                            description = 'Sequential pipeline steps (1..8 items of {role, prompt, context}); use {previous} or $PREVIOUS in prompt to reference prior step output.'
                            items = @{
                                type = 'object'
                                properties = @{
                                    role = @{ type = 'string' }
                                    prompt = @{ type = 'string' }
                                    context = @{ type = 'string' }
                                }
                                required = @('prompt')
                            }
                        }
                    }
                    required = @()
                }
            }
        }
    }
    $canRead = [bool]($toolNames | Where-Object { $_ -in @('list_files', 'read_file', 'find_files', 'grep_files') })
    $canWrite = [bool]($toolNames | Where-Object { $_ -in @('write_file', 'edit_file') })
    $canExec = ($toolNames -contains 'run_command')
    return @{
        permission = $perm
        no_tools = [bool]$script:NoTools
        enabled_filter = @($script:EnabledTools)
        excluded_filter = @($script:ExcludedTools)
        tool_names = $toolNames
        tools = $tools
        can_read = $canRead
        can_write = $canWrite
        can_exec = $canExec
        write_requires_confirmation = (($perm -eq 'Ask') -and $canWrite)
        exec_requires_confirmation = (($perm -in @('Ask', 'AutoEdit')) -and $canExec)
        environment = $envInfo
        signature = ("{0}|{1}" -f $perm, ($toolNames -join ','))
    }
}

function Get-AgentTools {
    return @((Get-AgentCapabilities).tools)
}

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

function Test-AgentToolArguments {
    param([string]$Name, $Arguments)
    if ($null -eq $Arguments -or $Arguments -is [string] -or $Arguments -is [ValueType] -or $Arguments -is [array]) {
        throw 'Tool arguments must be a JSON object.'
    }
    $schemas = @{
        list_files = @{
            required = @('path')
            types = @{ path = 'string'; limit = 'integer' }
        }
        read_file = @{
            required = @('path')
            types = @{ path = 'string'; start_line = 'integer'; max_lines = 'integer'; start_char = 'integer'; offset = 'integer'; limit = 'integer' }
        }
        find_files = @{
            required = @('path', 'pattern')
            types = @{ path = 'string'; pattern = 'string'; limit = 'integer' }
        }
        grep_files = @{
            required = @('path', 'pattern')
            types = @{ path = 'string'; pattern = 'string'; literal = 'boolean'; case_sensitive = 'boolean'; include = 'string'; glob = 'string'; context_lines = 'integer'; limit = 'integer'; file_offset = 'integer'; start_line = 'integer' }
        }
        write_file = @{
            required = @('path', 'content')
            types = @{ path = 'string'; content = 'string'; overwrite = 'boolean' }
        }
        edit_file = @{
            required = @('path')
            types = @{ path = 'string'; old_text = 'string'; new_text = 'string'; edits = 'array' }
        }
        run_command = @{
            required = @('command')
            types = @{ command = 'string'; timeout_sec = 'integer' }
        }
        run_agent = @{
            required = @()
            types = @{ role = 'string'; prompt = 'string'; context = 'string'; max_steps = 'integer'; parallel = 'array'; pipeline = 'array' }
        }
        fetch_url = @{
            required = @('url')
            types = @{ url = 'string'; max_chars = 'integer'; raw = 'boolean' }
        }
        web_search = @{
            required = @('query')
            types = @{ query = 'string'; limit = 'integer' }
        }
        todo = @{
            required = @('todos')
            types = @{ todos = 'array' }
        }
        ask_user = @{
            required = @('question')
            types = @{ question = 'string'; options = 'array'; intent = 'string'; plan = 'string'; allow_custom = 'boolean' }
        }
        memory = @{
            required = @()
            types = @{ action = 'string'; content = 'string'; scope = 'string' }
        }
    }
    $schema = $schemas[$Name]
    if (-not $schema) { throw 'Unknown tool.' }
    $propNames = @(Get-ObjectPropertyNames -InputObject $Arguments)
    foreach ($p in $propNames) {
        if ($schema.types.Keys -notcontains $p) {
            throw "Unknown argument '$p' for tool '$Name'."
        }
    }
    foreach ($req in $schema.required) {
        if ($propNames -notcontains $req -or $null -eq $Arguments.$req) {
            throw "Missing required argument '$req' for tool '$Name'."
        }
    }
    foreach ($p in $propNames) {
        $val = $Arguments.$p
        if ($null -eq $val) { continue }
        $expectedType = $schema.types[$p]
        if ($expectedType -eq 'string') {
            if ($val -isnot [string]) { throw "Argument '$p' must be a string." }
        }
        elseif ($expectedType -eq 'boolean') {
            if ($val -isnot [bool]) { throw "Argument '$p' must be a boolean." }
        }
        elseif ($expectedType -eq 'integer') {
            if (($val -isnot [int] -and $val -isnot [long]) -or ($val -is [bool])) {
                throw "Argument '$p' must be an integer."
            }
        }
        elseif ($expectedType -eq 'array') {
            if ($val -isnot [array]) { throw "Argument '$p' must be an array." }
        }
    }
    if ($Name -eq 'edit_file') {
        $hasEdits = ($propNames -contains 'edits' -and $null -ne $Arguments.edits)
        $hasSingle = ($propNames -contains 'old_text' -or $propNames -contains 'new_text')
        if ($hasEdits -and $hasSingle) {
            throw 'Provide either old_text/new_text or edits[], not both.'
        }
        if ($hasEdits) {
            if ($Arguments.edits.Count -eq 0) { throw 'edits array must not be empty.' }
            foreach ($ed in $Arguments.edits) {
                if ($null -eq $ed -or $ed -is [string] -or $ed -is [ValueType] -or $ed -is [array]) {
                    throw 'Each edit in edits[] must be an object.'
                }
                $edProps = @(Get-ObjectPropertyNames -InputObject $ed)
                foreach ($ep in $edProps) {
                    if ($ep -notin @('old_text', 'new_text')) {
                        throw "Unknown property '$ep' in edits[] item."
                    }
                }
                if ($edProps -notcontains 'old_text' -or $edProps -notcontains 'new_text' -or $ed.old_text -isnot [string] -or -not $ed.old_text -or $ed.new_text -isnot [string]) {
                    throw 'Each edit must have nonempty string old_text and string new_text.'
                }
            }
        }
        else {
            if ($propNames -notcontains 'old_text' -or $propNames -notcontains 'new_text' -or $Arguments.old_text -isnot [string] -or -not $Arguments.old_text -or $Arguments.new_text -isnot [string]) {
                throw 'Expected nonempty old_text and string new_text.'
            }
        }
    }
    if ($Name -eq 'run_agent') {
        $hasPrompt = ($propNames -contains 'prompt' -and $null -ne $Arguments.prompt)
        $hasParallel = ($propNames -contains 'parallel' -and $null -ne $Arguments.parallel)
        $hasPipeline = ($propNames -contains 'pipeline' -and $null -ne $Arguments.pipeline)
        $modeCount = ($(if ($hasPrompt) { 1 } else { 0 }) + $(if ($hasParallel) { 1 } else { 0 }) + $(if ($hasPipeline) { 1 } else { 0 }))
        if ($modeCount -eq 0) {
            throw 'run_agent requires one of: prompt, parallel[], or pipeline[].'
        }
        if ($modeCount -gt 1) {
            throw 'Provide only one execution mode: prompt, parallel[], or pipeline[].'
        }
        if ($propNames -contains 'context' -and $null -ne $Arguments.context) {
            if ($Arguments.context -notin @('clean', 'fork')) {
                throw "Argument 'context' must be 'clean' or 'fork'."
            }
            if ($hasParallel -and $Arguments.context -eq 'fork') {
                throw "Argument 'context' cannot be 'fork' when using parallel[]."
            }
        }
        if ($propNames -contains 'max_steps' -and $null -ne $Arguments.max_steps) {
            if ($Arguments.max_steps -lt 1 -or $Arguments.max_steps -gt 50) {
                throw 'max_steps must be between 1 and 50.'
            }
        }
        if ($hasPrompt) {
            if (-not $Arguments.prompt.Trim()) {
                throw 'prompt must be a nonempty string.'
            }
        }
        if ($hasParallel) {
            if ($Arguments.parallel.Count -lt 1 -or $Arguments.parallel.Count -gt 8) {
                throw 'parallel[] must contain between 1 and 8 tasks.'
            }
            foreach ($pt in $Arguments.parallel) {
                if ($null -eq $pt -or $pt -is [string] -or $pt -is [ValueType] -or $pt -is [array]) {
                    throw 'Each task in parallel[] must be an object.'
                }
                $ptProps = @(Get-ObjectPropertyNames -InputObject $pt)
                foreach ($pp in $ptProps) {
                    if ($pp -notin @('role', 'prompt')) {
                        throw "Unknown property '$pp' in parallel[] item."
                    }
                }
                if ($ptProps -notcontains 'prompt' -or $pt.prompt -isnot [string] -or -not $pt.prompt.Trim()) {
                    throw 'Each task in parallel[] must have a nonempty string prompt.'
                }
                if ($ptProps -contains 'role' -and $null -ne $pt.role -and $pt.role -isnot [string]) {
                    throw "Property 'role' in parallel[] item must be a string."
                }
            }
        }
        if ($hasPipeline) {
            if ($Arguments.pipeline.Count -lt 1 -or $Arguments.pipeline.Count -gt 8) {
                throw 'pipeline[] must contain between 1 and 8 steps.'
            }
            foreach ($ps in $Arguments.pipeline) {
                if ($null -eq $ps -or $ps -is [string] -or $ps -is [ValueType] -or $ps -is [array]) {
                    throw 'Each step in pipeline[] must be an object.'
                }
                $psProps = @(Get-ObjectPropertyNames -InputObject $ps)
                foreach ($sp in $psProps) {
                    if ($sp -notin @('role', 'prompt', 'context')) {
                        throw "Unknown property '$sp' in pipeline[] item."
                    }
                }
                if ($psProps -notcontains 'prompt' -or $ps.prompt -isnot [string] -or -not $ps.prompt.Trim()) {
                    throw 'Each step in pipeline[] must have a nonempty string prompt.'
                }
                if ($psProps -contains 'role' -and $null -ne $ps.role -and $ps.role -isnot [string]) {
                    throw "Property 'role' in pipeline[] item must be a string."
                }
                if ($psProps -contains 'context' -and $null -ne $ps.context) {
                    if ($ps.context -isnot [string] -or $ps.context -notin @('clean', 'fork')) {
                        throw "Property 'context' in pipeline[] item must be 'clean' or 'fork'."
                    }
                }
            }
        }
    }
    if ($Name -eq 'todo') {
        if ($null -eq $Arguments.todos -or $Arguments.todos -isnot [array]) {
            throw 'todos must be an array.'
        }
        foreach ($item in $Arguments.todos) {
            if ($null -eq $item -or $item -is [string] -or $item -is [ValueType] -or $item -is [array]) {
                throw 'Each item in todos[] must be an object with content and status.'
            }
            $itemProps = @(Get-ObjectPropertyNames -InputObject $item)
            foreach ($ip in $itemProps) {
                if ($ip -notin @('content', 'status')) {
                    throw "Unknown property '$ip' in todo item."
                }
            }
            if ($itemProps -notcontains 'content' -or $item.content -isnot [string] -or -not $item.content.Trim()) {
                throw 'Each todo item must have a nonempty string content.'
            }
            if ($itemProps -notcontains 'status' -or $item.status -isnot [string] -or $item.status.ToLower() -notin @('pending', 'in_progress', 'completed')) {
                throw "Each todo item must have status 'pending', 'in_progress', or 'completed'."
            }
        }
    }
    if ($Name -eq 'ask_user') {
        if (-not $Arguments.question -or -not $Arguments.question.Trim()) {
            throw 'question must be a nonempty string.'
        }
        if ($Arguments.intent -and $Arguments.intent.ToLower() -notin @('question', 'plan-review')) {
            throw "intent must be 'question' or 'plan-review'."
        }
    }
    if ($Name -eq 'memory') {
        $act = if ($Arguments.action) { ([string]$Arguments.action).Trim().ToLower() } else { 'append' }
        if ($act -notin @('append', 'view', 'set', 'clear')) {
            throw "action must be 'append', 'view', 'set', or 'clear'."
        }
        $scope = if ($Arguments.scope) { ([string]$Arguments.scope).Trim().ToLower() } else { 'workspace' }
        if ($scope -notin @('workspace', 'global')) {
            throw "scope must be 'workspace' or 'global'."
        }
        if (($act -eq 'append' -or $act -eq 'set') -and (-not $Arguments.content -or -not [string]$Arguments.content.Trim())) {
            throw "content must be a nonempty string for action '$act'."
        }
    }
}
