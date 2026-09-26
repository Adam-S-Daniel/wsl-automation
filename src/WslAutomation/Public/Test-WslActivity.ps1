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
        'wsl -d <DistroName> --exec ps -eo pid=,tty=,comm=,args='. '--exec' is used deliberately,
        never '--', which would route the command through the distro's default shell and mangle
        the arguments.

        Each output line is parsed as pid, tty, comm, then the remainder as args. A line that
        does not start with a numeric pid - for example a 'wsl: ...' warning that Invoke-WslExe
        merges in from stderr - is ignored rather than misparsed.

        The Claude Code Remote Control session (the keeper's always-on session, kept alive so it
        can be driven from claude.ai or the phone) does not count as activity by itself: it is
        identified as any process whose comm is 'claude' and whose args match
        -RemoteControlPattern, and its pid(s) and tty(s) are recorded separately.

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
        }
    }

    $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'ps', '-eo', 'pid=,tty=,comm=,args=')

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            IsActive            = $true
            Reason              = 'ProbeFailed'
            ActiveProcessCount  = 0
            ActiveCommands      = @()
            ActiveTerminalCount = 0
            RemoteControlPids   = @()
        }
    }

    $processes = @()
    foreach ($line in $result.Output) {
        $trimmedLine = $line.Trim()
        if ($trimmedLine -eq '') {
            continue
        }

        # A line that does not start with a numeric pid - e.g. a 'wsl: ...' stderr warning
        # Invoke-WslExe merges into Output - is ignored rather than misparsed as a process.
        $tokens = $trimmedLine -split '\s+'
        if ($tokens.Count -lt 3 -or $tokens[0] -notmatch '^\d+$') {
            continue
        }

        # ps's comm field can itself contain a single embedded space - tmux's server process's
        # comm is literally 'tmux: server' - so that one case is special-cased rather than always
        # treating the third token alone as comm, which would otherwise misparse it as comm
        # 'tmux:' with 'server' folded into the start of args.
        if ($tokens.Count -ge 4 -and $tokens[2] -eq 'tmux:' -and $tokens[3] -eq 'server') {
            $comm = 'tmux: server'
            $argTokens = if ($tokens.Count -ge 5) { $tokens[4..($tokens.Count - 1)] } else { @() }
        }
        else {
            $comm = $tokens[2]
            $argTokens = if ($tokens.Count -ge 4) { $tokens[3..($tokens.Count - 1)] } else { @() }
        }

        $processes += [pscustomobject]@{
            ProcessId = [int]$tokens[0]
            Tty       = $tokens[1]
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
        }
    }

    return [pscustomobject]@{
        IsActive            = $false
        Reason              = 'Idle'
        ActiveProcessCount  = 0
        ActiveCommands      = @()
        ActiveTerminalCount = 0
        RemoteControlPids   = $remoteControlPids
    }
}
