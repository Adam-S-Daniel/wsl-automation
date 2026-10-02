function Write-ClaudeAgentSnapshot {
    <#
    .SYNOPSIS
        Atomically writes the keeper's snapshot of active Claude Code sessions.
    .DESCRIPTION
        Serializes { capturedAt, restorePending, sessions: [{ sessionId, cwd, kind }] } to a
        temporary file next to -Path and then moves it over -Path with Move-Item -Force, so a
        reader (the next keeper run) never sees a half-written file. Creates the parent
        directory if needed. Only the session id, cwd and kind are stored - never a session's
        name or title.

        RestorePending marks a snapshot whose sessions have not been restored yet after the
        Remote Control server was found dead; while it is set, Invoke-ClaudeSessionKeeper does
        not overwrite the snapshot with the live list (which would no longer contain the lost
        sessions).
    .PARAMETER Path
        Path to the snapshot file.
    .PARAMETER Sessions
        Session objects with SessionId, Cwd and Kind properties (as returned by
        Get-ClaudeAgentSessions or Read-ClaudeAgentSnapshot). May be empty.
    .PARAMETER RestorePending
        Whether a restore of these sessions is still outstanding.
    .PARAMETER CapturedAt
        ISO 8601 timestamp of when the session list was taken. Defaults to now (UTC); pass the
        original value when only RestorePending changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions,

        [switch]$RestorePending,

        [string]$CapturedAt = ((Get-Date).ToUniversalTime().ToString('o'))
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $snapshot = [pscustomobject]@{
        capturedAt     = $CapturedAt
        restorePending = [bool]$RestorePending
        sessions       = @(
            foreach ($session in $Sessions) {
                [pscustomobject]@{
                    sessionId = $session.SessionId
                    cwd       = $session.Cwd
                    kind      = $session.Kind
                }
            }
        )
    }

    $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        Set-Content -LiteralPath $tempPath -Value ($snapshot | ConvertTo-Json -Depth 4) -Encoding utf8
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
