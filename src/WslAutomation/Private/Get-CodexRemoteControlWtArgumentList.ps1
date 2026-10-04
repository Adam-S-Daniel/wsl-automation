function Get-CodexRemoteControlWtArgumentList {
    <#
    .SYNOPSIS
        Builds the Windows Terminal argument list that runs 'codex remote-control start' in the
        WSL distro's ~/repos directory.
    .DESCRIPTION
        The Codex counterpart of Get-ClaudeSessionWtArgumentList, and built by the same rules;
        read that function's help for the reasoning behind each one:

        - wt.exe does not quote array elements, so the '--title' text and the whole bash
          command carry their own embedded quotes to stay one argument each. Unquoted, wt.exe
          would hand bash only 'cd' as the command and 'remote-control start' would never
          reach codex.
        - '-p <DistroName>' picks the distro's Windows Terminal profile for its icon and
          colors, while the explicit wsl.exe command line still decides what runs.
        - 'wsl.exe --cd ~' is the only home-relative form wsl.exe accepts, so bash does the
          'cd ~/repos'; '|| cd ~' keeps a missing ~/repos from stopping codex from starting;
          'exec' leaves one process in the tab.
        - 'bash -l' is a login shell because codex lives in ~/.local/bin.

        'codex remote-control start' starts Codex's app-server daemon with remote control
        enabled. The daemon may detach and the command return, closing the tab; that is
        expected, because Test-CodexRemoteControl looks for the daemon process itself, not for
        this tab. The array is shared by Set-WslAutomationScheduledTasks, which joins it into
        the Codex launcher task's Argument string.
    .PARAMETER DistroName
        Name of the WSL distro (and, by convention, its Windows Terminal profile). Defaults to
        'Ubuntu'.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu'
    )

    return @(
        '-w', '0', 'new-tab', '-p', $DistroName, '--title', '"Codex Remote Control"',
        'wsl.exe', '-d', $DistroName, '--cd', '~', '--', 'bash', '-l', '-c',
        '"cd ~/repos || cd ~ && exec codex remote-control start"'
    )
}
