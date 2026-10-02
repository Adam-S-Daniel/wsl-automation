#requires -Version 7.6

function Invoke-WslBackup {
    <#
    .SYNOPSIS
        Exports a WSL distro to a backup file via a local staging area, with retention pruning.

    .DESCRIPTION
        Invoke-WslBackup exports the given WSL distro (tar or vhdx) to a local staging
        directory first, then atomically moves the completed export into the final
        backup directory. Staging avoids exporting a large file directly into a
        OneDrive-synced (or similarly watched) destination, which would otherwise
        cause continuous partial-file re-sync churn.

        'wsl --export' stops the distro it exports (see AGENTS.md's "wsl --export stops the
        running distro" section), so before exporting this function runs three gates, in order:

        1. A wake guard: too soon after a boot or a resume from sleep, 'wsl --export' can fail
           outright while WSL is still transitioning (Get-LastWakeTime, -MinMinutesSinceWake).
        2. A force check: once the newest existing backup (any tag/format) is at least
           -ForceAfterDays whole days old (or none exists), the export is forced through regardless of
           activity, rather than let a persistently busy distro postpone every backup forever.
           A forced export stops the distro and ends any running agent sessions, so it only
           happens inside the quiet overnight window (-ForceWindowStartHour to
           -ForceWindowEndHour, local time). Overdue but outside that window, the check falls
           through to the activity gate: an idle distro still backs up at any hour, a busy one
           is deferred until the window opens.
        3. Unless forced or -IgnoreActivity is set, an activity gate (Test-WslActivity): a distro
           that looks actively in use is left alone rather than stopped out from under the user.

        Immediately before the export - after the lock is held - the Claude Code Remote Control
        session (the keeper's always-on session) is stopped best-effort with SIGTERM. It does not
        count as activity on its own, and the keeper relaunches it within its own polling
        interval, so there is nothing gained by leaving it running through an export that is
        about to stop the whole distro anyway.

        Any OTHER Claude Code session Test-WslActivity found idle (IdleClaudePids - see that
        function's help) is stopped the same way, best-effort, at the same point. An idle session
        is resumable with 'claude --resume', and 'wsl --export' is about to stop the whole distro
        regardless, so nothing is lost by stopping it first instead of letting the export's own
        forced 'systemctl poweroff' take it down uncleanly. Only the count of sessions stopped is
        logged - never a session id, a pid, or any other identifying detail.

        A backup.lock file is held for the duration of the export so other
        automation (for example Invoke-ClaudeSessionKeeper) can detect that a
        backup is in progress and wait rather than interrupt it.

        On success, old backups beyond -RetentionCount are pruned per tag
        (daily/weekly) and the set of retained backups is logged.

        Throws a terminating error on any failure; callers should not rely on a
        returned "failed" status.

    .PARAMETER BackupDir
        Directory the finished backup file is written to. Created if missing.

    .PARAMETER DistroName
        Name of the WSL distro to export. Defaults to 'Ubuntu'.

    .PARAMETER Format
        Export format: 'tar' or 'vhdx'. Defaults to 'tar'.

    .PARAMETER StagingDir
        Local scratch directory the export is written to before being moved into
        BackupDir. Defaults to a 'wsl-backup-staging' folder under the current
        user's temp directory.

    .PARAMETER LogFile
        Path to the log file this run appends to. Defaults to a
        'wsl-<distro>-backup.log' file inside BackupDir.

    .PARAMETER RetentionCount
        Number of backups to keep per tag (daily/weekly). Older backups beyond
        this count are deleted. Defaults to 2.

    .PARAMETER LockPath
        Path to the backup lock file. Defaults to the module's standard lock
        path under $env:LOCALAPPDATA.

    .PARAMETER ForceAfterDays
        Once the newest existing backup (any tag/format) is at least this many whole days old, or none
        exists, force the export through regardless of WSL activity - but only inside the force
        window (-ForceWindowStartHour to -ForceWindowEndHour). 0 disables forcing entirely.
        Defaults to 3.

    .PARAMETER ForceWindowStartHour
        Local hour of day (0-23) at which the force window opens, inclusive. A forced export only
        proceeds when the current local hour is inside the window; outside it, an overdue backup
        falls through to the activity gate instead. Defaults to 2 (with the default end hour of 6,
        the window is 02:00:00 through 05:59:59). A start hour greater than the end hour wraps
        midnight (22 to 4 is 22:00 through 03:59). Equal start and end hours mean no window
        restriction: force at any hour.

    .PARAMETER ForceWindowEndHour
        Local hour of day (0-23) at which the force window closes, exclusive. Defaults to 6. See
        -ForceWindowStartHour.

    .PARAMETER MinMinutesSinceWake
        Minimum number of minutes that must have passed since this machine last booted or resumed
        from sleep before an export is attempted. Defaults to 10 (see AGENTS.md's "wsl --export
        fails on a transitioning WSL" section for why 5 was not enough).

    .PARAMETER IgnoreActivity
        Skip the activity gate (Test-WslActivity) entirely and export regardless of whether WSL
        looks in use. The wake guard still applies.

    .EXAMPLE
        Invoke-WslBackup -BackupDir 'C:\Backups\WSL'

        Exports the 'Ubuntu' distro as a tar file into C:\Backups\WSL, staging it
        locally first, deferring if the machine just woke or the distro looks in active use.

    .EXAMPLE
        Invoke-WslBackup -BackupDir 'C:\Backups\WSL' -Format vhdx -RetentionCount 4

        Exports as a VHDX and keeps the newest 4 daily and newest 4 weekly backups.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$BackupDir,

        [string]$DistroName = 'Ubuntu',

        [ValidateSet('tar', 'vhdx')]
        [string]$Format = 'tar',

        [string]$StagingDir = (Join-Path ([IO.Path]::GetTempPath()) 'wsl-backup-staging'),

        [string]$LogFile = (Join-Path $BackupDir "wsl-$($DistroName.ToLowerInvariant())-backup.log"),

        [int]$RetentionCount = 2,

        [string]$LockPath = (Get-WslBackupLockPath),

        [int]$ForceAfterDays = 3,

        [ValidateRange(0, 23)]
        [int]$ForceWindowStartHour = 2,

        [ValidateRange(0, 23)]
        [int]$ForceWindowEndHour = 6,

        [int]$MinMinutesSinceWake = 10,

        [switch]$IgnoreActivity
    )

    # Step 1: compute prefix / tag / final file name.
    $prefix = "wsl-$($DistroName.ToLowerInvariant())"
    $now = Get-Date
    $tag = if ($now.DayOfWeek -eq [System.DayOfWeek]::Sunday) { 'weekly' } else { 'daily' }
    $dateStamp = $now.ToString('yyyy-MM-dd')
    $FileName = "$prefix-$tag-$dateStamp.$Format"
    $finalPath = Join-Path $BackupDir $FileName

    # Step 2: skip-guard, ahead of everything else and with NO log line - the backup task's
    # hourly retry trigger (see Set-WslAutomationScheduledTasks) would otherwise add up to 23
    # identical "already exists" lines to the log every day.
    if (Test-Path -LiteralPath $finalPath) {
        $existingItem = Get-Item -LiteralPath $finalPath
        $skipSizeMB = [math]::Round($existingItem.Length / 1MB, 2)
        return [pscustomobject]@{
            Status   = 'Skipped'
            FilePath = $finalPath
            SizeMB   = $skipSizeMB
        }
    }

    # Step 3: wake guard. 'wsl --export' can fail outright (exit -1) while WSL is still
    # transitioning after a boot or a resume - see AGENTS.md - so refuse to attempt it too soon
    # after either.
    $lastWakeTime = Get-LastWakeTime
    $minutesSinceWake = ((Get-Date) - $lastWakeTime).TotalMinutes
    if ($minutesSinceWake -lt $MinMinutesSinceWake) {
        $roundedMinutesSinceWake = [math]::Floor($minutesSinceWake)
        Write-WslAutomationLog -Message "Deferred: only $roundedMinutesSinceWake min since boot/resume (need $MinMinutesSinceWake)" -LogFile $LogFile
        return [pscustomobject]@{
            Status   = 'DeferredRecentWake'
            FilePath = $null
            SizeMB   = $null
        }
    }

    # Step 4: force check - once the newest existing backup (any tag/format) is at least
    # -ForceAfterDays whole days old, or none exists, the export proceeds regardless of activity rather
    # than let a persistently busy distro postpone every backup forever. A forced export stops the
    # distro and kills running agent sessions, so it is only allowed inside the quiet overnight
    # window; overdue but outside it, the activity gate below still applies.
    $existingBackups = @(Get-ChildItem -Path $BackupDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$prefix-*" -and ($_.Extension -eq '.tar' -or $_.Extension -eq '.vhdx') })
    $newestExistingBackup = $existingBackups | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    $backupAgeDays = if ($newestExistingBackup) { [math]::Floor(((Get-Date) - $newestExistingBackup.LastWriteTime).TotalDays) } else { $null }
    $backupAgeDisplay = if ($null -ne $backupAgeDays) { "$backupAgeDays day(s) old" } else { 'unknown (no prior backup exists)' }
    $overdue = $ForceAfterDays -gt 0 -and (-not $newestExistingBackup -or $backupAgeDays -ge $ForceAfterDays)
    # Start inclusive, end exclusive, local time. Start > end wraps midnight; start == end means
    # no restriction (force at any hour).
    $inForceWindow = if ($ForceWindowStartHour -eq $ForceWindowEndHour) { $true }
    elseif ($ForceWindowStartHour -lt $ForceWindowEndHour) { $now.Hour -ge $ForceWindowStartHour -and $now.Hour -lt $ForceWindowEndHour }
    else { $now.Hour -ge $ForceWindowStartHour -or $now.Hour -lt $ForceWindowEndHour }
    $force = $overdue -and $inForceWindow
    $forceWindowStart = '{0:00}:00' -f $ForceWindowStartHour
    $forceWindowEnd = '{0:00}:00' -f $ForceWindowEndHour

    # Step 5: activity gate. Deferring while WSL looks actively used is what keeps 'wsl --export'
    # - which stops the whole distro - from silently killing the user's work. -IgnoreActivity and
    # a forced export both skip the check outright; only a forced export also logs why. An overdue
    # backup outside the force window is NOT forced: it goes through the gate and, if deferred,
    # the log line says it is waiting for the window.
    $activity = $null
    if ($IgnoreActivity) {
        # Skip the gate entirely and silently - the operator asked for this explicitly.
    }
    elseif ($force) {
        $forceWindowDisplay = if ($ForceWindowStartHour -eq $ForceWindowEndHour) { 'any hour' } else { "$forceWindowStart-$forceWindowEnd" }
        Write-WslAutomationLog -Message "Forcing export: newest backup is $backupAgeDisplay (limit $ForceAfterDays; force window $forceWindowDisplay)" -LogFile $LogFile
    }
    else {
        $activity = Test-WslActivity -DistroName $DistroName
        if ($activity.IsActive) {
            $activeCommandsJoined = $activity.ActiveCommands -join ', '
            $overdueNote = if ($overdue) { "; overdue - forcing only between $forceWindowStart and $forceWindowEnd" } else { '' }
            Write-WslAutomationLog -Message "Deferred: WSL in use ($($activity.ActiveProcessCount) interactive process(es): $activeCommandsJoined); newest backup is $backupAgeDisplay$overdueNote" -LogFile $LogFile
            return [pscustomobject]@{
                Status   = 'DeferredBusy'
                FilePath = $null
                SizeMB   = $null
            }
        }
    }

    # Step 6: only now commit to actually running the export.
    Write-WslAutomationLog -Message "=== WSL backup starting (distro=$DistroName format=$Format) ===" -LogFile $LogFile

    # Step 7: ensure directories exist.
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $StagingDir)) {
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }

    # Step 8: clean stale staging artifacts from prior runs.
    Get-ChildItem -Path $StagingDir -Filter "$prefix-*.$Format" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $StagingDir -Filter '*.partial' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # A hard kill (ExecutionTimeLimit, power loss) mid Move-Item (step 14) can orphan a
    # "<name>.<Format>.partial" file directly in BackupDir. Nothing else in this function ever
    # revisits BackupDir looking for these - the retention filter and the retained-listing
    # extension check both exclude ".partial" - so left alone they persist forever, consuming
    # disk/OneDrive quota. Sweep any such leftovers here, before every export.
    Get-ChildItem -Path $BackupDir -Filter "$prefix-*.$Format.partial" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Step 9: acquire the backup lock; everything after this runs in try/finally.
    New-WslBackupLock -LockPath $LockPath -DistroName $DistroName | Out-Null

    try {
        # Step 10: best-effort stop the Claude Code Remote Control session right before the
        # export. 'wsl --export' is about to stop the whole distro regardless, and the keeper
        # relaunches the session within its own polling interval, so nothing is preserved by
        # leaving it running through the export - and killing it first means the export's own
        # forced 'systemctl poweroff' doesn't take it down uncleanly instead.
        if ($null -eq $activity) {
            # Not gathered above under -IgnoreActivity or a forced export - gather it now, purely
            # to learn the Remote Control session's pid(s).
            $activity = Test-WslActivity -DistroName $DistroName
        }
        foreach ($remoteControlProcessId in $activity.RemoteControlPids) {
            try {
                Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'kill', '-TERM', "$remoteControlProcessId") | Out-Null
                Write-WslAutomationLog -Message 'Stopped Claude Remote Control session before export (the keeper relaunches it)' -LogFile $LogFile
            }
            catch {
                Write-WslAutomationLog -Message "Failed to stop Claude Remote Control session (pid $remoteControlProcessId): $_" -LogFile $LogFile
            }
        }

        # Step 10b: best-effort stop every OTHER idle Claude session too, for the same reason -
        # 'wsl --export' is about to stop the distro anyway, and an idle session is resumable
        # with 'claude --resume'. Only the count is logged, never a pid or session id.
        $stoppedIdleClaudeCount = 0
        foreach ($idleClaudeProcessId in $activity.IdleClaudePids) {
            try {
                Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'kill', '-TERM', "$idleClaudeProcessId") | Out-Null
                $stoppedIdleClaudeCount++
            }
            catch {
                # Best-effort - a failure here is not worth failing the backup over, and the
                # message must never carry a pid or session id.
                Write-Verbose 'Failed to stop an idle Claude session before export'
            }
        }
        if ($stoppedIdleClaudeCount -gt 0) {
            Write-WslAutomationLog -Message "Stopped $stoppedIdleClaudeCount idle Claude session(s) before export (resumable with claude --resume)" -LogFile $LogFile
        }

        $stagingPath = Join-Path $StagingDir $FileName

        # Step 11: run the export.
        $exportArgs = @('--export', $DistroName, $stagingPath)
        if ($Format -eq 'vhdx') {
            $exportArgs += '--vhd'
        }
        $result = Invoke-WslExe -Arguments $exportArgs

        # Step 12: handle export failure.
        if ($result.ExitCode -ne 0) {
            Write-WslAutomationLog -Message "ERROR: wsl --export failed (exit $($result.ExitCode))" -LogFile $LogFile
            Write-WslAutomationLog -Message "  args: wsl $($exportArgs -join ' ')" -LogFile $LogFile
            foreach ($line in $result.Output) {
                $trimmedLine = "$line".Trim()
                if ($trimmedLine) {
                    Write-WslAutomationLog -Message "  wsl: $trimmedLine" -LogFile $LogFile
                }
            }
            if (Test-Path -LiteralPath $stagingPath) {
                Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
            }
            throw "wsl --export failed (exit $($result.ExitCode))"
        }

        # Step 13: verify the staging file landed and is non-empty.
        $stagingItem = Get-Item -LiteralPath $stagingPath -ErrorAction SilentlyContinue
        if (-not $stagingItem -or $stagingItem.Length -le 0) {
            Write-WslAutomationLog -Message "ERROR: staging file missing or empty after export ($stagingPath)" -LogFile $LogFile
            throw "Staging file missing or empty after export: $stagingPath"
        }

        # Step 14: move into place via a two-step move + rename.
        $finalPartialPath = "$finalPath.partial"
        try {
            Move-Item -LiteralPath $stagingPath -Destination $finalPartialPath -Force
            Rename-Item -LiteralPath $finalPartialPath -NewName $FileName -Force
        }
        catch {
            if (Test-Path -LiteralPath $finalPartialPath) {
                Remove-Item -LiteralPath $finalPartialPath -Force -ErrorAction SilentlyContinue
            }
            Write-WslAutomationLog -Message "ERROR: failed to move backup into place: $($_.Exception.Message)" -LogFile $LogFile
            throw
        }

        # Step 15: log completion size.
        $finalItem = Get-Item -LiteralPath $finalPath
        $sizeMB = [math]::Round($finalItem.Length / 1MB, 2)
        Write-WslAutomationLog -Message "Export complete: $sizeMB MB" -LogFile $LogFile

        # Step 16: retention pruning per tag.
        foreach ($retentionTag in @('daily', 'weekly')) {
            $matchingBackups = Get-ChildItem -Path $BackupDir -Filter "$prefix-$retentionTag-*.$Format" -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name -Descending
            $backupsToRemove = $matchingBackups | Select-Object -Skip $RetentionCount
            foreach ($oldBackup in $backupsToRemove) {
                Write-WslAutomationLog -Message "Removing old $retentionTag backup: $($oldBackup.Name)" -LogFile $LogFile
                Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # Step 17: list retained backups (both formats, any tag).
        Write-WslAutomationLog -Message 'Retained:' -LogFile $LogFile
        $retainedBackups = Get-ChildItem -Path $BackupDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$prefix-*" -and ($_.Extension -eq '.tar' -or $_.Extension -eq '.vhdx') } |
            Sort-Object -Property Name -Descending
        foreach ($retainedItem in $retainedBackups) {
            $retainedSizeMB = [math]::Round($retainedItem.Length / 1MB, 2)
            $retainedStamp = $retainedItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Write-WslAutomationLog -Message "  $($retainedItem.Name)  [$retainedSizeMB MB]  $retainedStamp" -LogFile $LogFile
        }

        # Step 18: done.
        Write-WslAutomationLog -Message '=== Done ===' -LogFile $LogFile

        return [pscustomobject]@{
            Status   = 'Completed'
            FilePath = $finalPath
            SizeMB   = $sizeMB
        }
    }
    finally {
        Remove-WslBackupLock -LockPath $LockPath
    }
}
