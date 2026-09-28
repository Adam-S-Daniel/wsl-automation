function Test-WslActivity {
    <#
    .SYNOPSIS
        Detects whether a WSL distro is being actively used interactively, so a backup export -
        which stops the distro - can be deferred rather than kill live work.
    .DESCRIPTION
        'wsl --export' stops the distro it exports (see AGENTS.md's "wsl --export stops the
        running distro" section), so Invoke-WslBackup uses this to decide whether the distro
        looks busy before exporting it.

        Only inspects a distro that is already Running (via Get-WslDistroState) - a stopped
        distro is reported as not active rather than being booted just to check it.

        When running, lists every process with
        'wsl -d <DistroName> --exec ps -eo pid=,ppid=,tty=,comm=,args='. '--exec' is used
        deliberately, never '--', which would route the command through the distro's default
        shell and mangle the arguments.

        Each output line is parsed as pid, ppid, tty, comm, then the remainder as args. A line
        that does not start with a numeric pid and ppid - for example a 'wsl: ...' warning that
        Invoke-WslExe merges in from stderr - is ignored rather than misparsed.

        The Claude Code Remote Control session (the keeper's always-on session, kept alive so it
        can be driven from claude.ai or the phone) does not count as activity by itself: it is
        identified as any process whose comm is 'claude' and whose args match
        -RemoteControlPattern, and its pid(s) and tty(s) are recorded separately. This
        identification, and everything downstream of it, is unchanged by the Claude session-status
        check below.

        Every OTHER 'claude' process (i.e. not identified as Remote Control) is checked for
        whether its own interactive session is idle, one 'wsl --exec' call per pid:
        'wsl -d <DistroName> --exec sh -c "cat \"$HOME/.claude/sessions/$1.json\"" sh <pid>'.
        '--exec' again passes the arguments verbatim with no distro-shell mangling, so '$HOME' and
        '$1' are expanded only by the inner 'sh'. Claude Code (observed in version 2.1.282) writes
        this file per running session with a 'pid' and a 'status' field ('busy' while a turn is
        running, presumably 'idle' while waiting for input - other values, e.g. a permission
        prompt, may exist). The session is treated as IDLE only if all of the following hold: the
        file is read successfully (exit 0), its content parses as JSON, its 'pid' field equals the
        process's own pid, and its 'status' field equals exactly 'idle'. ANY other outcome - a
        missing file, a non-zero exit, a parse error, a pid mismatch, status 'busy', or any other
        status value - is treated as BUSY. This session-file format is Claude Code-internal and
        undocumented, so this check deliberately fails safe to busy on anything it does not
        recognise. Nothing about a session file's content (including status) is ever logged or
        otherwise surfaced; only the owning pid is returned, in IdleClaudePids.

        Before the pty rules below run, every idle Claude process and all of its descendants (MCP
        servers, shells it spawned, etc. - found by walking the ppid relationships among ALL
        processes this check saw) are removed from consideration entirely. This means a pty
        holding only an idle Claude session's process tree plus a login shell is idle, exactly as
        if that tree were not there at all. A pty holding a BUSY Claude session's tree is
        unaffected by this and is considered by the pty rules exactly as it was before this check
        existed.

        Only 'pts/*' ttys are considered for the tty rule below - a real console tty (e.g.
        'tty1', a getty's always-present login prompt), 'console', and '?' (no tty at all) are
        ignored by it, since none of them can be a user's interactive terminal. Within the
        remaining ptys, two more things are excluded before anything counts as activity:

        - the Remote Control session's own pty(s), as before; and
        - any pty on which any process's comm starts with 'docker-desktop' (the WSL integration's
          own always-present proxy process, never a user), and any process anywhere whose comm
          starts with 'docker-desktop', even one off such a pty.

        Of what remains, an idle login prompt or a shell sitting at an empty prompt loses nothing
        meaningful if a backup interrupts it, so a pty only counts as ACTIVE if it carries at
        least one process whose comm is NOT in the shell/login set: 'login', 'bash', 'sh', 'dash',
        'zsh', 'fish', '-bash', '-sh', '-zsh'. A pty holding only login and/or shell processes is
        idle.

        The distro overall is considered ACTIVE if, excluding the 'ps' process this check itself
        runs:

        - any pty, per the rules above, is itself active; or
        - any process's comm is 'tmux: server', 'tmux', 'screen', or 'SCREEN' (a multiplexer
          session, which commonly runs detached with no tty of its own, so it is never subject to
          the pty rules above).

        ActiveProcessCount counts the non-shell/login processes on active ptys, plus any
        multiplexer processes; ActiveCommands lists their distinct comm names; ActiveTerminalCount
        counts the active ptys themselves (a detached multiplexer session adds to the process
        count and to ActiveCommands but, having no pty, never to the terminal count).

        Process argument lists are never returned or logged - only distinct command names - since
        the backup log lives in a shared OneDrive folder.

        If the 'ps' probe itself fails to run (non-zero exit), this fails safe by reporting the
        distro as active (Reason 'ProbeFailed') rather than risk exporting out from under a user
        who is actually there; Invoke-WslBackup's -ForceAfterDays override still applies on top of
        that.
    .PARAMETER DistroName
        Name of the WSL distro to inspect. Defaults to 'Ubuntu'.
    .PARAMETER RemoteControlPattern
        Regex a process's args must match, alongside a comm of 'claude', to be identified as the
        Remote Control session. Defaults to '--remote-control'.
    .EXAMPLE
        Test-WslActivity -DistroName 'Ubuntu'

        Returns an object describing whether 'Ubuntu' currently looks actively used.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$RemoteControlPattern = '--remote-control'
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        return [pscustomobject]@{
            IsActive            = $false
            Reason              = 'NotRunning'
            ActiveProcessCount  = 0
            ActiveCommands      = @()
            ActiveTerminalCount = 0
            RemoteControlPids   = @()
            IdleClaudePids      = @()
        }
    }

    $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'ps', '-eo', 'pid=,ppid=,tty=,comm=,args=')

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            IsActive            = $true
            Reason              = 'ProbeFailed'
            ActiveProcessCount  = 0
            ActiveCommands      = @()
            ActiveTerminalCount = 0
            RemoteControlPids   = @()
            IdleClaudePids      = @()
        }
    }

    $processes = @()
    foreach ($line in $result.Output) {
        $trimmedLine = $line.Trim()
        if ($trimmedLine -eq '') {
            continue
        }

        # A line that does not start with a numeric pid and ppid - e.g. a 'wsl: ...' stderr
        # warning Invoke-WslExe merges into Output - is ignored rather than misparsed as a
        # process.
        $tokens = $trimmedLine -split '\s+'
        if ($tokens.Count -lt 4 -or $tokens[0] -notmatch '^\d+$' -or $tokens[1] -notmatch '^\d+$') {
            continue
        }

        # ps's comm field can itself contain a single embedded space - tmux's server process's
        # comm is literally 'tmux: server' - so that one case is special-cased rather than always
        # treating the fourth token alone as comm, which would otherwise misparse it as comm
        # 'tmux:' with 'server' folded into the start of args.
        if ($tokens.Count -ge 5 -and $tokens[3] -eq 'tmux:' -and $tokens[4] -eq 'server') {
            $comm = 'tmux: server'
            $argTokens = if ($tokens.Count -ge 6) { $tokens[5..($tokens.Count - 1)] } else { @() }
        }
        else {
            $comm = $tokens[3]
            $argTokens = if ($tokens.Count -ge 5) { $tokens[4..($tokens.Count - 1)] } else { @() }
        }

        $processes += [pscustomobject]@{
            ProcessId = [int]$tokens[0]
            ParentId  = [int]$tokens[1]
            Tty       = $tokens[2]
            Comm      = $comm
            ProcArgs  = $argTokens -join ' '
        }
    }

    $remoteControlPids = @()
    $remoteControlTtys = @()
    foreach ($process in $processes) {
        if ($process.Comm -eq 'claude' -and $process.ProcArgs -match $RemoteControlPattern) {
            $remoteControlPids += $process.ProcessId
            if ($process.Tty -ne '?') {
                $remoteControlTtys += $process.Tty
            }
        }
    }

    # Every other 'claude' process gets its own session status checked, one call per pid. The
    # session-file format is Claude Code-internal and undocumented, so anything other than a
    # clean parse with a matching pid and a status of exactly 'idle' is treated as busy - see
    # .DESCRIPTION.
    $idleClaudePids = @()
    $otherClaudeProcesses = @($processes | Where-Object {
            $_.Comm -eq 'claude' -and $remoteControlPids -notcontains $_.ProcessId
        })
    foreach ($claudeProcess in $otherClaudeProcesses) {
        $claudeProcessId = $claudeProcess.ProcessId
        $isIdle = $false
        try {
            $sessionResult = Invoke-WslExe -Arguments @(
                '-d', $DistroName, '--exec', 'sh', '-c',
                'cat "$HOME/.claude/sessions/$1.json"', 'sh', "$claudeProcessId"
            )
            if ($sessionResult.ExitCode -eq 0) {
                $sessionJsonText = $sessionResult.Output -join "`n"
                $sessionInfo = $sessionJsonText | ConvertFrom-Json -ErrorAction Stop
                if ($sessionInfo.pid -eq $claudeProcessId -and $sessionInfo.status -ceq 'idle') {
                    $isIdle = $true
                }
            }
        }
        catch {
            # Missing file, non-zero exit surfaced as an exception, malformed JSON - all fail
            # safe to busy ($isIdle stays $false). Never log the exception or the file content.
        }

        if ($isIdle) {
            $idleClaudePids += $claudeProcessId
        }
    }

    # Idle Claude sessions and every one of their descendants (MCP servers, shells they spawned,
    # etc.) are removed from consideration entirely before the pty rules below run. The ppid map
    # is built from every process this check saw, before any filtering.
    $childrenByParent = @{}
    foreach ($process in $processes) {
        if (-not $childrenByParent.ContainsKey($process.ParentId)) {
            $childrenByParent[$process.ParentId] = [System.Collections.Generic.List[int]]::new()
        }
        $childrenByParent[$process.ParentId].Add($process.ProcessId)
    }

    $idleClaudeAndDescendantIds = [System.Collections.Generic.HashSet[int]]::new()
    $pendingProcessIds = [System.Collections.Generic.Queue[int]]::new()
    foreach ($idleClaudeProcessId in $idleClaudePids) {
        if ($idleClaudeAndDescendantIds.Add($idleClaudeProcessId)) {
            $pendingProcessIds.Enqueue($idleClaudeProcessId)
        }
    }
    while ($pendingProcessIds.Count -gt 0) {
        $currentProcessId = $pendingProcessIds.Dequeue()
        if ($childrenByParent.ContainsKey($currentProcessId)) {
            foreach ($childProcessId in $childrenByParent[$currentProcessId]) {
                if ($idleClaudeAndDescendantIds.Add($childProcessId)) {
                    $pendingProcessIds.Enqueue($childProcessId)
                }
            }
        }
    }

    $processes = @($processes | Where-Object { -not $idleClaudeAndDescendantIds.Contains($_.ProcessId) })

    $shellCommands = @('login', 'bash', 'sh', 'dash', 'zsh', 'fish', '-bash', '-sh', '-zsh')
    $multiplexerCommands = @('tmux: server', 'tmux', 'screen', 'SCREEN')

    # Any pty carrying a docker-desktop process is excluded outright, on top of the Remote
    # Control session's own pty(s).
    $dockerDesktopTtys = @($processes | Where-Object { $_.Comm -like 'docker-desktop*' } |
            Select-Object -ExpandProperty Tty -Unique)
    $excludedTtys = @($remoteControlTtys + $dockerDesktopTtys | Select-Object -Unique)

    # Only pts/* ttys are candidate user terminals - a console getty, 'console' and '?' (no tty
    # at all) are always infrastructure or headless, never a user. 'ps' itself and any
    # docker-desktop process are never counted, even on a pty this loop would otherwise consider.
    $candidateProcesses = @($processes | Where-Object {
            $_.Comm -ne 'ps' -and
            $_.Comm -notlike 'docker-desktop*' -and
            $_.Tty -like 'pts/*' -and
            $excludedTtys -notcontains $_.Tty
        })

    # A pty only counts as active if it carries at least one process outside the shell/login set
    # - an idle prompt loses nothing meaningful if the backup interrupts it.
    $activeProcesses = @()
    $activeTerminalCount = 0
    foreach ($ttyGroup in @($candidateProcesses | Group-Object -Property Tty)) {
        $nonShellProcesses = @($ttyGroup.Group | Where-Object { $shellCommands -notcontains $_.Comm })
        if ($nonShellProcesses.Count -gt 0) {
            $activeTerminalCount++
            $activeProcesses += $nonShellProcesses
        }
    }

    # A multiplexer session commonly runs detached with no tty of its own, so it is active
    # regardless of the pty rules above, and never adds to ActiveTerminalCount.
    $activeProcesses += @($processes | Where-Object { $multiplexerCommands -contains $_.Comm })

    if ($activeProcesses.Count -gt 0) {
        return [pscustomobject]@{
            IsActive            = $true
            Reason              = 'Active'
            ActiveProcessCount  = $activeProcesses.Count
            ActiveCommands      = @($activeProcesses | Select-Object -ExpandProperty Comm -Unique)
            ActiveTerminalCount = $activeTerminalCount
            RemoteControlPids   = $remoteControlPids
            IdleClaudePids      = $idleClaudePids
        }
    }

    return [pscustomobject]@{
        IsActive            = $false
        Reason              = 'Idle'
        ActiveProcessCount  = 0
        ActiveCommands      = @()
        ActiveTerminalCount = 0
        RemoteControlPids   = $remoteControlPids
        IdleClaudePids      = $idleClaudePids
    }
}
