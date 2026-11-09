# Canonical tool definitions. Get-AgentToolSpecifications is the single table
# for OpenAI function schemas and argument validation.

function Get-AgentToolSpecifications {
    # Ordered as Get-AgentCapabilities emits tools when every tool is enabled.
    # required is the top-level required list. extra names a validator in Validation.ps1.
    $specs = @(
        @{
            name = 'list_files'
            description = 'List up to 200 entries in a directory. Names only; no file contents.'
            required = @('path')
            properties = @{
                path = @{ type = 'string'; description = 'Workspace-relative path; . means the root.' }
                limit = @{ type = 'integer'; description = 'Optional maximum number of entries to return (1..500, default 200).' }
            }
        },
        @{
            name = 'read_file'
            description = 'Read a UTF-8 text file: up to 300 lines and 20000 characters, maximum file size 1 MiB. Returns total_lines and pagination metadata.'
            required = @('path')
            properties = @{
                path = @{ type = 'string'; description = 'Workspace-relative path; . means the root.' }
                start_line = @{ type = 'integer'; description = 'Optional 1-based first line to read (default 1).' }
                max_lines = @{ type = 'integer'; description = 'Optional maximum number of lines to read (1..300, default 300).' }
                start_char = @{ type = 'integer'; description = 'Optional 1-based character offset within start_line for reading long lines (default 1).' }
                offset = @{ type = 'integer'; description = 'Optional alias for start_line (1-based line offset).' }
                limit = @{ type = 'integer'; description = 'Optional alias for max_lines (1..300).' }
            }
        },
        @{
            name = 'find_files'
            description = 'Find files or directories recursively by wildcard pattern (e.g. *.sql, src/*.ps1), respecting .gitignore/.ignore.'
            required = @('path', 'pattern')
            properties = @{
                path = @{ type = 'string'; description = 'Workspace-relative directory path; . means the root.' }
                pattern = @{ type = 'string'; description = 'File name or relative path wildcard pattern, e.g. *.sql or src/*.ps1.' }
                limit = @{ type = 'integer'; description = 'Optional maximum number of results (1..1000, default 200).' }
            }
        },
        @{
            name = 'grep_files'
            description = 'Search UTF-8 text files for a regex or literal pattern (respecting .gitignore/.ignore), returning matching paths, line numbers, and lines.'
            required = @('path', 'pattern')
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
        },
        @{
            name = 'fetch_url'
            description = 'Fetch an HTTP/HTTPS URL and return readable text, Markdown, or JSON content (up to 20000 characters by default).'
            required = @('url')
            properties = @{
                url = @{ type = 'string'; description = 'HTTP or HTTPS URL to fetch.' }
                max_chars = @{ type = 'integer'; description = 'Optional maximum characters to return (500..50000, default 20000).' }
                raw = @{ type = 'boolean'; description = 'Optional: set true to return raw HTML without tag stripping.' }
            }
        },
        @{
            name = 'web_search'
            description = 'Search the web for a query and return matching result titles, URLs, and snippets.'
            required = @('query')
            properties = @{
                query = @{ type = 'string'; description = 'Search query text.' }
                limit = @{ type = 'integer'; description = 'Optional maximum number of results (1..20, default 8).' }
            }
        },
        @{
            name = 'todo'
            description = 'Track task plan and progress during multi-step work. Call this to initialize or update the active todo list (replaces entire list on each call).'
            required = @('todos')
            extra = 'Test-AgentTodoArguments'
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
        },
        @{
            name = 'ask_user'
            description = 'Ask the user a concise question, request an architectural decision, or present a Markdown implementation plan for explicit review and approval before making changes.'
            required = @('question')
            extra = 'Test-AgentAskUserArguments'
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
        },
        @{
            name = 'memory'
            description = 'Record, view, or manage persistent long-term memories, user preferences, and project invariants that survive across CLI sessions in MEMORY.md.'
            required = @()
            extra = 'Test-AgentMemoryArguments'
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
        },
        @{
            name = 'write_file'
            description = 'Create a UTF-8 text file (or overwrite when overwrite=true).'
            required = @('path', 'content')
            properties = @{
                path = @{ type = 'string'; description = 'Workspace-relative text file path. Parent directory must exist.' }
                content = @{ type = 'string'; description = 'Complete file contents, up to 1 MiB.' }
                overwrite = @{ type = 'boolean'; description = 'Set true to overwrite an existing file (saves a backup).' }
            }
        },
        @{
            name = 'edit_file'
            description = 'Replace one or more unique blocks in a UTF-8 text file (supports single old_text/new_text or batch edits[] array; saves a backup).'
            required = @('path')
            extra = 'Test-AgentEditFileArguments'
            properties = @{
                path = @{ type = 'string'; description = 'Workspace-relative text file path. Parent directory must exist.' }
                old_text = @{ type = 'string'; description = 'Single edit: nonempty text occurring once in the file.' }
                new_text = @{ type = 'string'; description = 'Single edit: replacement text.' }
                edits = @{
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
            }
        },
        @{
            name = 'run_command'
            description = 'Execute PowerShell with the user''s OS permissions, starting in the workspace directory.'
            required = @('command')
            properties = @{
                command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                timeout_sec = @{ type = 'integer'; description = 'Optional timeout in seconds (1..600, default 60).' }
            }
        },
        @{
            name = 'run_agent'
            description = 'Delegate a task, parallel fan-out, or sequential pipeline to isolated subagents (roles: recon [ReadOnly], audit [ReadOnly], craft [inherits permission]). Keeps main context clean.'
            required = @()
            extra = 'Test-AgentRunAgentArguments'
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
        }
    )
    return $specs
}

function Get-AgentCapabilities {
    param([string]$Root = '')
    $envInfo = Get-AgentEnvironment -Root $Root
    $perm = if ($script:AgentPermission -in @('ReadOnly', 'Ask', 'AutoEdit', 'Auto')) { $script:AgentPermission } else { 'Ask' }
    $tools = @()
    $toolNames = @()
    $readOnlyBlocked = @('write_file', 'edit_file', 'run_command')
    foreach ($spec in @(Get-AgentToolSpecifications)) {
        $name = [string]$spec.name
        if ($perm -eq 'ReadOnly' -and ($readOnlyBlocked -contains $name)) { continue }
        if (-not (Test-IsToolEnabled -Name $name)) { continue }
        $requiredNames = @()
        foreach ($reqName in @($spec.required)) {
            if ($reqName) { $requiredNames += [string]$reqName }
        }
        $toolNames += $name
        $tools += @{
            type = 'function'
            function = @{
                name = $name
                description = [string]$spec.description
                parameters = @{
                    type = 'object'
                    properties = $spec.properties
                    required = $requiredNames
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
        exec_requires_confirmation = (($perm -in @('Ask', 'AutoEdit')) -and $canExec -and -not $script:AutoApproveCommands)
        environment = $envInfo
        signature = ("{0}|{1}" -f $perm, ($toolNames -join ','))
    }
}

function Get-AgentTools {
    return @((Get-AgentCapabilities).tools)
}
