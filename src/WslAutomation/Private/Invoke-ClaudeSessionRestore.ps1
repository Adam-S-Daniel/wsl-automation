function Invoke-ClaudeSessionRestore {
    <#
    .SYNOPSIS
        Resumes every snapshotted Claude Code session that is no longer active.
    .DESCRIPTION
        One restore pass for Invoke-ClaudeSessionKeeper. Compares the snapshot it is given
        against the live list from Get-ClaudeAgentSessions and resumes, with
        Start-ClaudeSessionResume, each snapshotted session whose SessionId is not listed. A
        session that is already listed is never resumed again, which is what makes a repeated
        pass harmless.

        A pass is reported Completed only when the live list could actually be read. When it
        cannot (Get-ClaudeAgentSessions returns $null - for example the distro is not Running
        yet because the launcher has only just started booting it), nothing is resumed and the
        caller keeps the restore pending for the next keeper run.

        A snapshotted SessionId that is not a UUID, or a Cwd that is not an absolute Linux path,
        is skipped and logged rather than passed on. With -DryRun nothing is resumed; the ids
        that would be are logged instead.

        Logging goes to the keeper's own log under LOCALAPPDATA: session ids and counts only,
        never a session's cwd, name or title.
    .PARAMETER DistroName
        Name of the WSL distro.
    .PARAMETER Snapshot
        Snapshot object from Read-ClaudeAgentSnapshot.
    .PARAMETER LogFile
        Path to the keeper's log file.
    .PARAMETER DryRun
        Log what would be resumed without resuming anything.
    .OUTPUTS
        An object with Completed (bool), Resumed, Failed and Skipped (counts).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,

        [Parameter(Mandatory)]
        [pscustomobject]$Snapshot,

        [Parameter(Mandatory)]
        [string]$LogFile,

        [switch]$DryRun
    )

    $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $resumed = 0
    $failed = 0
    $skipped = 0

    $current = Get-ClaudeAgentSessions -DistroName $DistroName
    if ($null -eq $current) {
        Write-WslAutomationLog -Message 'Session restore: could not list current Claude sessions; will retry next run' -LogFile $LogFile
        return [pscustomobject]@{ Completed = $false; Resumed = 0; Failed = 0; Skipped = 0 }
    }

    $currentIds = @($current | ForEach-Object { $_.SessionId })
    $missing = @($Snapshot.Sessions | Where-Object { $currentIds -notcontains $_.SessionId })

    foreach ($session in $missing) {
        if ($session.SessionId -notmatch $uuidPattern) {
            Write-WslAutomationLog -Message 'Session restore: skipping a snapshot entry whose session id is not a UUID' -LogFile $LogFile
            $skipped++
            continue
        }
        if ($session.Cwd -notmatch '^/') {
            Write-WslAutomationLog -Message "Session restore: skipping session $($session.SessionId) (cwd is not an absolute path)" -LogFile $LogFile
            $skipped++
            continue
        }

        if ($DryRun) {
            Write-WslAutomationLog -Message "DryRun: would resume Claude session $($session.SessionId)" -LogFile $LogFile
            continue
        }

        $result = Start-ClaudeSessionResume -DistroName $DistroName -SessionId $session.SessionId -Cwd $session.Cwd
        if ($null -ne $result -and $result.ExitCode -eq 0) {
            $resumed++
        }
        else {
            $exitCode = if ($null -ne $result) { $result.ExitCode } else { 'none' }
            Write-WslAutomationLog -Message "Session restore: resuming session $($session.SessionId) failed (exit $exitCode)" -LogFile $LogFile
            $failed++
        }
    }

    $snapshotCount = @($Snapshot.Sessions).Count
    $alreadyRunning = $snapshotCount - $missing.Count
    Write-WslAutomationLog -Message ("Session restore: $resumed resumed, $failed failed, $skipped skipped " +
        "($snapshotCount in snapshot, $alreadyRunning already running)") -LogFile $LogFile

    return [pscustomobject]@{ Completed = $true; Resumed = $resumed; Failed = $failed; Skipped = $skipped }
}
