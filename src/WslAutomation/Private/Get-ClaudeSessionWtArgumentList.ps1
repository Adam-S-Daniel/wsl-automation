function Get-ClaudeSessionWtArgumentList {
    <#
    .SYNOPSIS
        Builds the Windows Terminal argument list that opens a Remote Control Claude Code
        session in the WSL distro's ~/repos directory.
    .DESCRIPTION
        Single source of truth for the wt.exe arguments, shared by Start-ClaudeSession (which
        passes the array to Start-Process) and Set-WslAutomationScheduledTasks (which joins it
        into the launcher task's Argument string). Neither of those consumers quotes array
        elements that contain spaces, so any value that has to stay one argument - the
        '--title' text, and the whole bash command below - carries its own embedded quotes.

        The session is started with '--remote-control' so it registers with Claude Code's
        Remote Control service and can be driven from claude.ai or the mobile app. That is the
        whole point of keeping one alive unattended, and it is also what Test-ClaudeSession
        looks for, so the flag has to reach the distro intact: unquoted, wt.exe would pass
        '--remote-control' to bash rather than to claude (it becomes bash's $0), producing a
        plain local session the keeper never recognizes and therefore relaunches every
        interval.

        The 'cd ~/repos' is bash's job, not wsl.exe's. 'wsl.exe --cd' accepts exactly three
        shapes - the bare '~', an absolute Linux path starting with '/', or an absolute Windows
        path - so '--cd ~/repos' is read as a Windows path and does not land where it looks
        like it should, and the absolute Linux path cannot be written down here because the
        distro's username is not known when this list is built. '--cd ~' therefore still puts
        wsl.exe in the home directory, and bash - which does expand '~' - takes it from there.

        '|| cd ~' keeps a missing ~/repos from costing the session entirely. Without it the
        failed cd would short-circuit the '&&' and the tab would close before claude ever
        started, so the keeper would reopen it every interval, forever. With it the session
        opens in the home directory instead and bash prints the failed cd, which is visible in
        the tab rather than silent. 'exec' replaces bash with claude so the tab has one process
        rather than two.

        '-p <DistroName>' selects the matching Windows Terminal WSL profile so the tab adopts
        that profile's icon and colours. Without it, passing a raw command line to 'new-tab'
        launches with the generic console icon (a plain 'C:\'-style glyph), which reads as a
        Windows shell rather than the WSL session it actually is. The explicit
        'wsl.exe ... bash -l -c "cd ~/repos || cd ~ && exec claude --remote-control"' command
        line still overrides what the profile runs.
    .PARAMETER DistroName
        Name of the WSL distro (and, by convention, its Windows Terminal profile). Defaults to
        'Ubuntu'.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu'
    )

    return @(
        '-w', '0', 'new-tab', '-p', $DistroName, '--title', '"Claude Code"',
        'wsl.exe', '-d', $DistroName, '--cd', '~', '--', 'bash', '-l', '-c',
        '"cd ~/repos || cd ~ && exec claude --remote-control"'
    )
}
