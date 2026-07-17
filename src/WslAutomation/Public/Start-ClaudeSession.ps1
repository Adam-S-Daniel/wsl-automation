function Start-ClaudeSession {
    <#
    .SYNOPSIS
        Launches a new interactive Claude Code session inside a WSL distro.
    .DESCRIPTION
        Starts a host executable (Windows Terminal by default) with an argument list that opens
        a new tab, enters the given WSL distro at the user's home directory, and starts an
        interactive login shell running 'claude'. Intended to be called only after
        Test-ClaudeSession has confirmed no session is already running, so callers do not end up
        with duplicate sessions.
    .PARAMETER DistroName
        Name of the WSL distro to launch into. Defaults to 'Ubuntu'.
    .PARAMETER Executable
        Host executable to start. Defaults to 'wt.exe' (Windows Terminal).
    .PARAMETER ArgumentList
        Arguments passed to -Executable. Defaults to opening a new Windows Terminal tab titled
        'Claude Code' that runs 'wsl.exe -d <DistroName> --cd ~ -- bash -l -c claude'.
    .EXAMPLE
        Start-ClaudeSession -DistroName 'Ubuntu'

        Opens a new Windows Terminal tab running Claude Code inside the 'Ubuntu' distro.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$Executable = 'wt.exe',

        [string[]]$ArgumentList = @(
            '-w', '0', 'new-tab', '--title', 'Claude Code',
            'wsl.exe', '-d', $DistroName, '--cd', '~', '--', 'bash', '-l', '-c', 'claude'
        )
    )

    if ($PSCmdlet.ShouldProcess($Executable, "Launch Claude Code session in $DistroName")) {
        Start-Process -FilePath $Executable -ArgumentList $ArgumentList
    }
}
