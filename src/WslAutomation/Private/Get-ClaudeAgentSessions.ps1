function Get-ClaudeAgentSessions {
    <#
    .SYNOPSIS
        Lists the Claude Code sessions currently active inside a WSL distro, from
        'claude agents --json'.
    .DESCRIPTION
        Runs 'claude agents --json' inside the distro through a login shell ('bash -l -c'),
        because claude lives in ~/.local/bin, which only a login shell puts on PATH. It is
        invoked with 'wsl --exec' so wsl.exe hands the arguments to bash verbatim, with no
        extra shell of its own in between. The command needs no TTY.

        The output is a JSON array with one object per active session, for example
        {"pid":1411684,"id":"c2165965","cwd":"/home/u/repos","kind":"background",
        "sessionId":"c2165965-516f-5d82-ad4d-afa62ee6a8ed","name":"...","status":"idle",...}.
        Each one becomes an object with SessionId (the full 'sessionId', not the short 'id'),
        Cwd and Kind ('background' or 'interactive'). An entry missing sessionId or cwd is
        skipped: neither can be resumed without the other. Nothing else - in particular not the
        session's name or title - is carried through.

        Fails closed and never throws. A distro that is not Running (checked with
        Get-WslDistroState first, so a stopped distro is never booted just to ask), a non-zero
        exit, output with no JSON array in it, or a parse failure all return $null, which is
        deliberately distinct from an empty array: $null means "unknown, try again later",
        while an empty array means "known, and there are no sessions". The array is returned
        with the unary comma so PowerShell does not unroll an empty or one-element result into
        $null or a scalar. Any lines before the first one that opens the array (for example
        text a login profile prints) are ignored.
    .PARAMETER DistroName
        Name of the WSL distro to query. Defaults to 'Ubuntu'.
    .EXAMPLE
        $sessions = Get-ClaudeAgentSessions -DistroName 'Ubuntu'
        if ($null -ne $sessions) { $sessions.SessionId }
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseSingularNouns',
        '',
        Justification = 'Returns the list of sessions as one array, by design.')]
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu'
    )

    try {
        if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
            return $null
        }

        $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'bash', '-l', '-c', 'claude agents --json')
        if ($result.ExitCode -ne 0) {
            return $null
        }

        $lines = @($result.Output)
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ("$($lines[$i])" -match '^\s*\[') {
                $start = $i
                break
            }
        }
        if ($start -lt 0) {
            return $null
        }

        $parsed = ($lines[$start..($lines.Count - 1)] -join "`n") | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
        if ($parsed -isnot [array]) {
            return $null
        }

        $sessions = @(
            foreach ($entry in $parsed) {
                if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                    continue
                }
                $sessionIdProperty = $entry.PSObject.Properties['sessionId']
                $cwdProperty = $entry.PSObject.Properties['cwd']
                if (-not $sessionIdProperty -or -not $cwdProperty) {
                    continue
                }
                $sessionId = "$($sessionIdProperty.Value)"
                $cwd = "$($cwdProperty.Value)"
                if ([string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($cwd)) {
                    continue
                }
                $kindProperty = $entry.PSObject.Properties['kind']
                [pscustomobject]@{
                    SessionId = $sessionId
                    Cwd       = $cwd
                    Kind      = if ($kindProperty) { "$($kindProperty.Value)" } else { $null }
                }
            }
        )

        return , $sessions
    }
    catch {
        return $null
    }
}
