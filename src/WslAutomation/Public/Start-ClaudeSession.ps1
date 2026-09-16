function Start-ClaudeSession {
    <#
    .SYNOPSIS
        Launches a new interactive Claude Code session, with Remote Control enabled, inside a
        WSL distro.
    .DESCRIPTION
        Starts a host executable (Windows Terminal by default) with an argument list that opens
        a new tab, enters the given WSL distro, changes to ~/repos, and starts an interactive
        login shell running 'claude --remote-control'. Intended to be called only after
        Test-ClaudeSession has confirmed no session is already running, so callers do not end up
        with duplicate sessions.
    .PARAMETER DistroName
        Name of the WSL distro to launch into. Defaults to 'Ubuntu'.
    .PARAMETER Executable
        Host executable to start. Defaults to 'wt.exe' (Windows Terminal).
    .PARAMETER ArgumentList
        Arguments passed to -Executable. Defaults to opening a new Windows Terminal tab titled
        'Claude Code', using the <DistroName> profile, that runs
        'wsl.exe -d <DistroName> --cd ~ -- bash -l -c "cd ~/repos || cd ~ && exec claude --remote-control"'.
        See Get-ClaudeSessionWtArgumentList for why the title and the bash command are
        pre-quoted, why bash does the cd rather than wsl.exe, and why the profile is
        selected.
    .EXAMPLE
        Start-ClaudeSession -DistroName 'Ubuntu'

        Opens a new Windows Terminal tab running Claude Code with Remote Control enabled in
        ~/repos inside the 'Ubuntu' distro.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$Executable = 'wt.exe',

        [string[]]$ArgumentList = (Get-ClaudeSessionWtArgumentList -DistroName $DistroName)
    )

    if ($PSCmdlet.ShouldProcess($Executable, "Launch Remote Control Claude Code session in $DistroName")) {
        Start-Process -FilePath $Executable -ArgumentList $ArgumentList
    }
}
