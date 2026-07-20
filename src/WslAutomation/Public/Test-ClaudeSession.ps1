function Test-ClaudeSession {
    <#
    .SYNOPSIS
        Detects whether an interactive Claude Code session is currently running inside a WSL
        distro.
    .DESCRIPTION
        Only inspects a distro that is already running (via Get-WslDistroState) - a stopped
        distro is reported as having no session rather than being booted just to check it. When
        running, lists processes with 'pgrep -af claude' and counts how many look like a real
        interactive session as opposed to one of Claude Code's own background helper processes:
        'claude daemon run', 'claude bg-pty-host', and 'claude bg-spare' are infrastructure, not
        something a human is actually using, so they are excluded before counting.
    .PARAMETER DistroName
        Name of the WSL distro to check. Defaults to 'Ubuntu'.
    .PARAMETER IncludePattern
        Regex a process command line must match to be considered a Claude Code process at all.
        Defaults to '(^|/| )claude( |$)'.
    .PARAMETER ExcludePattern
        Regex that excludes known Claude Code background/helper processes from counting as a
        session. Defaults to 'daemon|bg-pty-host|bg-spare'.
    .EXAMPLE
        Test-ClaudeSession -DistroName 'Ubuntu'

        Returns $true if an interactive Claude Code session is running inside 'Ubuntu'.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$IncludePattern = '(^|/| )claude( |$)',

        [string]$ExcludePattern = 'daemon|bg-pty-host|bg-spare'
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        return $false
    }

    $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--', 'pgrep', '-af', 'claude')

    if ($result.ExitCode -ne 0) {
        return $false
    }

    $sessionLines = $result.Output | Where-Object { ($_ -match $IncludePattern) -and ($_ -notmatch $ExcludePattern) }

    return @($sessionLines).Count -gt 0
}
