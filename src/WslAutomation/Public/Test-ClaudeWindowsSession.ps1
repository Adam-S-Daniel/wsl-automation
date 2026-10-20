function Test-ClaudeWindowsSession {
    <#
    .SYNOPSIS
        Detects whether a Remote Control Claude Code session is running as a Windows process.
    .DESCRIPTION
        The Windows counterpart of Test-ClaudeSession, used by Invoke-ClaudeSessionKeeper to
        keep 'claude rc' running in a Windows Terminal tab. Reads the command lines of the
        Windows claude executable's processes (Get-WindowsProcessCommandLine) and returns $true
        when any line matches -RemoteControlPattern and not -ExcludePattern.

        Only Remote Control counts: a plain 'claude' tab opened by hand cannot be reached
        remotely, so the keeper opens a Remote Control session alongside it rather than
        treating it as satisfied. The default exclude pattern drops Claude Code's own helper
        processes (the daemon and the background pty host and spare processes), whose command
        lines can contain a bare 'rc' word without being the Remote Control server.

        WSL claude processes are Linux processes and are invisible here, and Windows processes
        are invisible to Test-ClaudeSession, so the two keepers never satisfy each other. The
        keeper runs as S4U in session 0 under the same user, which can read the command lines
        of that user's interactive processes.

        If the process list cannot be read, the result is $false.
    .PARAMETER ProcessName
        Image name of the Windows claude executable. Defaults to 'claude.exe'.
    .PARAMETER RemoteControlPattern
        Regex a command line must match to count as Remote Control. Defaults to
        Get-ClaudeRemoteControlPattern.
    .PARAMETER ExcludePattern
        Regex that disqualifies a command line even when it matches. Defaults to
        'daemon|bg-pty-host|bg-spare'.
    .EXAMPLE
        Test-ClaudeWindowsSession

        Returns $true if a Windows 'claude rc' Remote Control session is running.
    #>
    [CmdletBinding()]
    param(
        [string]$ProcessName = 'claude.exe',

        [string]$RemoteControlPattern = (Get-ClaudeRemoteControlPattern),

        [string]$ExcludePattern = 'daemon|bg-pty-host|bg-spare'
    )

    try {
        $lines = Get-WindowsProcessCommandLine -Name $ProcessName
    }
    catch {
        return $false
    }

    $sessionLines = @($lines) | Where-Object { $_ -match $RemoteControlPattern -and $_ -notmatch $ExcludePattern }

    return @($sessionLines).Count -gt 0
}
