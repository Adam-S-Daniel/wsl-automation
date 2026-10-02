function Read-ClaudeAgentSnapshot {
    <#
    .SYNOPSIS
        Reads the keeper's snapshot of active Claude Code sessions written by
        Write-ClaudeAgentSnapshot.
    .DESCRIPTION
        Returns an object with CapturedAt (string), RestorePending (bool) and Sessions (an
        array of SessionId/Cwd/Kind objects), or $null when the file is missing, unreadable,
        not JSON, or not shaped like a snapshot. Never throws: a corrupt snapshot only costs
        one restore, never the keeper run. Session entries missing a sessionId or cwd are
        dropped, the same rule Get-ClaudeAgentSessions applies to live output.
    .PARAMETER Path
        Path to the snapshot file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }

        $parsed = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String -ErrorAction Stop
        if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
            return $null
        }

        $sessionsProperty = $parsed.PSObject.Properties['sessions']
        if (-not $sessionsProperty) {
            return $null
        }

        $sessions = @(
            foreach ($entry in @($sessionsProperty.Value)) {
                if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                    continue
                }
                $sessionIdProperty = $entry.PSObject.Properties['sessionId']
                $cwdProperty = $entry.PSObject.Properties['cwd']
                if (-not $sessionIdProperty -or -not $cwdProperty -or
                    [string]::IsNullOrWhiteSpace("$($sessionIdProperty.Value)") -or
                    [string]::IsNullOrWhiteSpace("$($cwdProperty.Value)")) {
                    continue
                }
                $kindProperty = $entry.PSObject.Properties['kind']
                [pscustomobject]@{
                    SessionId = "$($sessionIdProperty.Value)"
                    Cwd       = "$($cwdProperty.Value)"
                    Kind      = if ($kindProperty) { "$($kindProperty.Value)" } else { $null }
                }
            }
        )

        $capturedAtProperty = $parsed.PSObject.Properties['capturedAt']
        $restorePendingProperty = $parsed.PSObject.Properties['restorePending']

        return [pscustomobject]@{
            CapturedAt     = if ($capturedAtProperty) { "$($capturedAtProperty.Value)" } else { $null }
            RestorePending = [bool]($restorePendingProperty -and $restorePendingProperty.Value -eq $true)
            Sessions       = $sessions
        }
    }
    catch {
        return $null
    }
}
