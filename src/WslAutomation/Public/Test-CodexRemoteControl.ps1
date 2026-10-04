function Test-CodexRemoteControl {
    <#
    .SYNOPSIS
        Detects whether Codex's remote-control app-server daemon (what
        'codex remote-control start' starts) is running inside a WSL distro.
    .DESCRIPTION
        The Codex counterpart of Test-ClaudeSession, used by Invoke-ClaudeSessionKeeper to keep
        'codex remote-control start' running. Only inspects a distro that is already running
        (via Get-WslDistroState) - a stopped distro is reported as having no daemon rather than
        being booted just to check it. When running, lists processes with 'pgrep -af codex'
        and returns $true when any line matches -Pattern.

        The check is keyed to the daemon, not to the terminal tab that launched it, so it is
        right whether 'codex remote-control start' stays in the foreground or detaches and
        returns. The default pattern matches either:

        - the managed daemon: 'codex app-server' with both '--remote-control' and
          '--managed-daemon' among its arguments (the command line codex-cli 0.160.0 gives
          the daemon), or
        - the launcher itself, 'codex remote-control start', while it is still running.

        In both, 'codex' must be the command - at the start of the line or after the pgrep
        pid, optionally behind a path or a 'node' interpreter - so an editor or shell with
        those words in a file name does not count. 'codex remote-control pair', 'codex exec',
        'codex agents', the 'codex app-server daemon pid-update-loop' helper, a desktop app's
        'codex ... app-server' without remote control, and 'codex-code-mode-host' do not count
        either.
    .PARAMETER DistroName
        Name of the WSL distro to check. Defaults to 'Ubuntu'.
    .PARAMETER Pattern
        Regex a 'pgrep -af codex' line must match to count as the remote-control daemon.
        Defaults to the daemon-or-launcher pattern described above.
    .EXAMPLE
        Test-CodexRemoteControl -DistroName 'Ubuntu'

        Returns $true if Codex's remote-control daemon is running inside 'Ubuntu'.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$Pattern = '^(?:\d+\s+)?(?:\S*/)?(?:node\s+(?:\S*/)?)?codex\s+(?:remote-control\s+start(?:\s|$)|app-server(?=(?:\s.*)?\s--remote-control(?:\s|$))(?=(?:\s.*)?\s--managed-daemon(?:\s|$)))'
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        return $false
    }

    $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--', 'pgrep', '-af', 'codex')

    if ($result.ExitCode -ne 0) {
        return $false
    }

    $daemonLines = $result.Output | Where-Object { $_ -match $Pattern }

    return @($daemonLines).Count -gt 0
}
