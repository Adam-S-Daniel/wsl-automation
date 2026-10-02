function Get-CodexAgentsWtArgumentList {
    <#
    .SYNOPSIS
        Builds the Windows Terminal argument list that opens a 'codex agents' tab in the WSL
        distro's ~/repos directory.
    .DESCRIPTION
        The Codex counterpart of Get-ClaudeSessionWtArgumentList, and built by the same rules;
        read that function's help for the reasoning behind each one:

        - wt.exe does not quote array elements, so the '--title' text and the whole bash
          command carry their own embedded quotes to stay one argument each. Unquoted, wt.exe
          would hand bash only 'cd' as the command and 'agents' would never reach codex.
        - '-p <DistroName>' picks the distro's Windows Terminal profile for its icon and
          colors, while the explicit wsl.exe command line still decides what runs.
        - 'wsl.exe --cd ~' is the only home-relative form wsl.exe accepts, so bash does the
          'cd ~/repos'; '|| cd ~' keeps a missing ~/repos from closing the tab before codex
          starts (which would make the keeper reopen it every interval); 'exec' leaves one
          process in the tab.
        - 'bash -l' is a login shell because codex lives in ~/.local/bin.

        The tab runs 'codex agents', Codex's agents TUI, which Test-CodexAgentsSession looks for.
        The array is shared by Set-WslAutomationScheduledTasks, which joins it into the Codex
        launcher task's Argument string.
    .PARAMETER DistroName
        Name of the WSL distro (and, by convention, its Windows Terminal profile). Defaults to
        'Ubuntu'.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu'
    )

    return @(
        '-w', '0', 'new-tab', '-p', $DistroName, '--title', '"Codex Agents"',
        'wsl.exe', '-d', $DistroName, '--cd', '~', '--', 'bash', '-l', '-c',
        '"cd ~/repos || cd ~ && exec codex agents"'
    )
}
