function Get-ClaudeSessionWtArgumentList {
    <#
    .SYNOPSIS
        Builds the Windows Terminal argument list that opens a Remote Control Claude Code
        session in a WSL distro.
    .DESCRIPTION
        Single source of truth for the wt.exe arguments, shared by Start-ClaudeSession (which
        passes the array to Start-Process) and Set-WslAutomationScheduledTasks (which joins it
        into the launcher task's Argument string). Neither of those consumers quotes array
        elements that contain spaces, so any value that has to stay one argument - the
        '--title' text, and the 'claude --remote-control' command below - carries its own
        embedded quotes.

        The session is started with '--remote-control' so it registers with Claude Code's
        Remote Control service and can be driven from claude.ai or the mobile app. That is the
        whole point of keeping one alive unattended, and it is also what Test-ClaudeSession
        looks for, so the flag has to reach the distro intact: unquoted, wt.exe would pass
        '--remote-control' to bash rather than to claude (it becomes bash's $0), producing a
        plain local session the keeper never recognizes and therefore relaunches every
        interval.

        '-p <DistroName>' selects the matching Windows Terminal WSL profile so the tab adopts
        that profile's icon and colours. Without it, passing a raw command line to 'new-tab'
        launches with the generic console icon (a plain 'C:\'-style glyph), which reads as a
        Windows shell rather than the WSL session it actually is. The explicit
        'wsl.exe ... bash -l -c "claude --remote-control"' command line still overrides what
        the profile runs.
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
        'wsl.exe', '-d', $DistroName, '--cd', '~', '--', 'bash', '-l', '-c', '"claude --remote-control"'
    )
}
