function Test-WslBackupLock {
    <#
    .SYNOPSIS
        Inspects the WSL backup lock file and reports whether it is present and/or stale.
    .DESCRIPTION
        Reads the lock file written by New-WslBackupLock. Age is computed from the recorded
        StartedUtc timestamp when the file parses as JSON; otherwise age falls back to the
        file's LastWriteTimeUtc. A lock older than StaleMinutes is reported as stale.
    .PARAMETER LockPath
        Path to the lock file. Defaults to Get-WslBackupLockPath.
    .PARAMETER StaleMinutes
        Age in minutes beyond which a present lock is considered stale. Default 240.
    .EXAMPLE
        Test-WslBackupLock -StaleMinutes 240
    #>
    [CmdletBinding()]
    param(
        [string]$LockPath = (Get-WslBackupLockPath),

        [int]$StaleMinutes = 240
    )

    if (-not (Test-Path -LiteralPath $LockPath)) {
        return [pscustomobject]@{
            Present    = $false
            Stale      = $false
            AgeMinutes = $null
            Data       = $null
        }
    }

    $fileInfo = Get-Item -LiteralPath $LockPath
    $data = $null

    try {
        $rawContent = Get-Content -LiteralPath $LockPath -Raw
        $data = $rawContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $data = $null
    }

    # ConvertFrom-Json auto-detects ISO 8601 strings and returns StartedUtc as a [datetime]
    # (Kind=Utc) rather than a string. Handle both shapes explicitly: coercing a DateTime
    # through [datetime]::Parse() would stringify it with the default (non-round-trip)
    # format first, silently dropping its UTC marker and corrupting the Kind on reparse.
    $started = $null
    if ($data -and $data.PSObject.Properties['StartedUtc'] -and $data.StartedUtc) {
        if ($data.StartedUtc -is [datetime]) {
            $started = $data.StartedUtc
        }
        else {
            try {
                $started = [datetime]::Parse(
                    [string]$data.StartedUtc,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                )
            }
            catch {
                $started = $null
            }
        }
    }

    if ($started) {
        $ageMinutes = ((Get-Date).ToUniversalTime() - $started.ToUniversalTime()).TotalMinutes
    }
    else {
        $ageMinutes = ((Get-Date).ToUniversalTime() - $fileInfo.LastWriteTimeUtc).TotalMinutes
    }

    return [pscustomobject]@{
        Present    = $true
        Stale      = ($ageMinutes -gt $StaleMinutes)
        AgeMinutes = $ageMinutes
        Data       = $data
    }
}
