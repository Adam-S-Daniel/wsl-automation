function Get-ClaudeWindowsSessionWtArgumentList {
    <#
    .SYNOPSIS
        Builds the Windows Terminal argument list that opens a Remote Control Claude Code
        session, run by the Windows claude executable in a pwsh tab, in the Windows repos
        directory.
    .DESCRIPTION
        The Windows counterpart of Get-ClaudeSessionWtArgumentList, built by the same rules;
        read that function's help for the reasoning behind each one:

        - wt.exe and the scheduled task's Argument string do not quote array elements, so the
          '--title' text, the '-d' directory and the whole pwsh command carry their own
          embedded quotes to stay one argument each. Unquoted, pwsh would receive only 'claude'
          as its command and 'rc --spawn same-dir' would never reach it.
        - '-p PowerShell' picks the Windows Terminal PowerShell 7 profile for its icon and
          colors, while the explicit pwsh.exe command line still decides what runs.
        - '-d' sets the starting directory. D:\Repos is a folder of clones, not a git
          repository, so the session is pinned with '--spawn same-dir' for the same reason as
          the WSL launcher: a saved 'worktree' spawn mode would fail every on-demand session
          with a base-branch error.
        - A trailing backslash on -ReposDir is trimmed, because inside the embedded quotes it
          would escape the closing quote.
        - pwsh loads the user's profile (no -NoProfile) so 'claude' on the user PATH resolves
          the way it does in a normal tab.
        - There is no -NoExit, so the tab closes when claude exits and the keeper relaunches
          it, the same as the WSL tab's exec.

        Never put ';' in these arguments: wt.exe treats it as a command separator. The array is
        shared by Set-WslAutomationScheduledTasks, which joins it into the Windows launcher
        task's Argument string.
    .PARAMETER ReposDir
        Starting directory of the tab. Defaults to 'D:\Repos'.
    .PARAMETER TerminalProfile
        Name of the Windows Terminal profile the tab uses. Defaults to 'PowerShell'.
    #>
    [CmdletBinding()]
    param(
        [string]$ReposDir = 'D:\Repos',

        [string]$TerminalProfile = 'PowerShell'
    )

    $ReposDir = $ReposDir.TrimEnd('\')

    return @(
        '-w', '0', 'new-tab', '-p', $TerminalProfile, '--title', '"Claude Code (Windows)"',
        '-d', "`"$ReposDir`"", 'pwsh.exe', '-NoLogo', '-Command', '"claude rc --spawn same-dir"'
    )
}
