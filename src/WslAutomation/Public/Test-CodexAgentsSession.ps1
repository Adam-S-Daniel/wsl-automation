function Test-CodexAgentsSession {
    <#
    .SYNOPSIS
        Detects whether a 'codex agents' process (Codex's agents TUI) is running inside a WSL
        distro.
    .DESCRIPTION
        The Codex counterpart of Test-ClaudeSession, used by Invoke-ClaudeSessionKeeper to keep
        the always-on 'codex agents' tab open. Only inspects a distro that is already running
        (via Get-WslDistroState) - a stopped distro is reported as having no tab rather than
        being booted just to check it. When running, lists processes with 'pgrep -af codex'
        and returns $true when any line matches -Pattern.

        The default pattern requires 'codex agents' as the command and its first argument:
        'codex' at the start of the line, after a path separator, or after whitespace (a
        'pgrep -af' line starts with the pid), followed by exactly the word 'agents'. That
        keeps Codex's other long-running processes - 'codex app-server ...' and the
        'codex-code-mode-host' helper - and a bare 'codex' session from counting as the tab.
    .PARAMETER DistroName
        Name of the WSL distro to check. Defaults to 'Ubuntu'.
    .PARAMETER Pattern
        Regex a 'pgrep -af codex' line must match to count as the agents tab. Defaults to
        '(^|/|\s)codex agents(\s|$)'.
    .EXAMPLE
        Test-CodexAgentsSession -DistroName 'Ubuntu'

        Returns $true if 'codex agents' is running inside 'Ubuntu'.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$Pattern = '(^|/|\s)codex agents(\s|$)'
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        return $false
    }

    $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--', 'pgrep', '-af', 'codex')

    if ($result.ExitCode -ne 0) {
        return $false
    }

    $agentsLines = $result.Output | Where-Object { $_ -match $Pattern }

    return @($agentsLines).Count -gt 0
}
