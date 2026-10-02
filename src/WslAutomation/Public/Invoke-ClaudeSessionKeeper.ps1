function Invoke-ClaudeSessionKeeper {
    <#
    .SYNOPSIS
        Ensures an interactive Claude Code session with Remote Control enabled is running inside
        a WSL distro, waiting out any in-progress backup first.
    .DESCRIPTION
        Intended to run on a short recurring schedule (for example every 5 minutes) so a Claude
        Code session that can be driven from claude.ai or the phone is always available, without
        ever colliding with a WSL export backup.
        Before doing anything else it checks the shared backup lock (see New-WslBackupLock /
        Test-WslBackupLock): if a backup is in progress it polls on an interval, waiting up to a
        maximum total time, then proceeds anyway rather than waiting forever. A lock left behind
        by a crashed or killed backup run is detected as stale (older than -LockStaleMinutes)
        and is cleared immediately, with no waiting.

        Once the lock is clear - or ignored as stale, or the wait is exhausted - it checks
        whether a Remote Control session is already running (Test-ClaudeSession) and only
        launches a new one when none is found. Only Remote Control counts: a plain 'claude' tab
        opened by hand cannot be reached remotely, so the keeper opens a Remote Control session
        alongside it rather than treating it as satisfied. Because the keeper itself runs as a
        background (session 0) scheduled task - so its frequent check never flashes a window on
        the desktop - it cannot show a terminal directly; it launches by triggering the
        interactive on-demand launcher task (Start-ClaudeLauncherTask) instead.

        Session snapshot and restore. When 'claude rc' dies - the user quits it, or a backup's
        'wsl --export' stops the whole distro - the Claude Code sessions running under it stop
        too and drop out of 'claude agents'. So every run that finds the Remote Control server
        alive also records the active sessions (Get-ClaudeAgentSessions: id, cwd, kind) in
        -SessionSnapshotPath, written atomically and never overwritten when the list could not
        be read. A run that finds it dead launches a new one as above and then resumes every
        snapshotted session that is not listed any more, from its own cwd, with
        'claude --bg --resume <id>' (Start-ClaudeSessionResume) - the same command that
        restores one by hand. Sessions that are still listed are skipped, so a repeated restore
        is harmless.

        If the live list cannot be read in that run (typically the distro is still stopped,
        because the launcher has only just begun booting it), the snapshot is marked
        restorePending and kept; the next run - which will normally find the new Remote Control
        server alive - restores first and only then goes back to refreshing the snapshot.
        Without that mark the next run would overwrite the snapshot with the post-crash list
        and the lost sessions would be forgotten. The snapshot file itself is never deleted.

        Known limitation: the snapshot is up to one keeper interval old, so a session the user
        deliberately ended within that interval before 'claude rc' died is brought back.

        Codex agents tab. After the Claude handling, the keeper also keeps one Windows Terminal
        tab running 'codex agents' (Codex's agents TUI): if Test-CodexAgentsSession finds none,
        it starts the Codex launcher task (-CodexLauncherTaskName, registered by
        Set-WslAutomationScheduledTasks) through the same Start-ClaudeLauncherTask seam.
    .PARAMETER DistroName
        Name of the WSL distro to check/launch into. Defaults to 'Ubuntu'.
    .PARAMETER LauncherTaskName
        Name of the interactive scheduled task that actually opens the Remote Control session.
        Defaults to 'Claude Code Session Launcher'.
    .PARAMETER MaxWaitMinutes
        Maximum total time to wait for a fresh backup lock to clear before proceeding anyway.
        Defaults to 60.
    .PARAMETER PollSeconds
        How long to sleep between lock checks while waiting. Defaults to 30.
    .PARAMETER LockPath
        Path to the backup lock file. Defaults to Get-WslBackupLockPath.
    .PARAMETER LockStaleMinutes
        Age, in minutes, beyond which a present lock is treated as stale/abandoned rather than
        an active backup. Defaults to 240.
    .PARAMETER LogFile
        Path to the keeper's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\keeper.log".
    .PARAMETER SessionSnapshotPath
        Path to the snapshot of active Claude Code sessions used for restore. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\agents-snapshot.json".
    .PARAMETER NoSessionRestore
        Never resume snapshotted sessions after the Remote Control server is found dead. The
        snapshot is still refreshed while it is alive.
    .PARAMETER CodexLauncherTaskName
        Name of the interactive scheduled task that opens the 'codex agents' tab. Defaults to
        'Codex Agents Launcher'.
    .PARAMETER NoCodexAgents
        Do not check for, or launch, the 'codex agents' tab.
    .PARAMETER DryRun
        When a session would be launched, only log the intent and return 'DryRun' instead of
        actually starting one. Also logs the session ids a restore would resume, and the codex
        agents tab it would open, without doing either, and never writes the snapshot.
    .OUTPUTS
        An object with Status ('SessionPresent', 'Launched' or 'DryRun'), WaitedSeconds,
        ResumedSessionCount and CodexAgentsLaunched.
    .EXAMPLE
        Invoke-ClaudeSessionKeeper

        Waits out any backup, then launches a Remote Control Claude Code session if one isn't
        already running.
    .EXAMPLE
        Invoke-ClaudeSessionKeeper -DryRun

        Runs the same checks but never actually launches a session.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$LauncherTaskName = 'Claude Code Session Launcher',

        [int]$MaxWaitMinutes = 60,

        [int]$PollSeconds = 30,

        [string]$LockPath = (Get-WslBackupLockPath),

        [int]$LockStaleMinutes = 240,

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'keeper.log'),

        [string]$SessionSnapshotPath = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'agents-snapshot.json'),

        [switch]$NoSessionRestore,

        [string]$CodexLauncherTaskName = 'Codex Agents Launcher',

        [switch]$NoCodexAgents,

        [switch]$DryRun
    )

    $maxIterations = [math]::Ceiling(($MaxWaitMinutes * 60) / $PollSeconds)
    $iterationsSlept = 0
    $waited = 0

    while ($true) {
        $lock = Test-WslBackupLock -LockPath $LockPath -StaleMinutes $LockStaleMinutes

        if (-not $lock.Present) {
            break
        }

        if ($lock.Stale) {
            $ageMinutes = [math]::Round($lock.AgeMinutes)
            Write-WslAutomationLog -Message "Ignoring stale backup lock (age $ageMinutes min)" -LogFile $LogFile
            Remove-WslBackupLock -LockPath $LockPath
            break
        }

        if ($iterationsSlept -ge $maxIterations) {
            $message = "Backup still running after $MaxWaitMinutes min wait; proceeding anyway"
            Write-WslAutomationLog -Message $message -LogFile $LogFile
            Write-Warning -Message $message
            break
        }

        if ($iterationsSlept -eq 0) {
            Write-WslAutomationLog -Message "Backup in progress; waiting (max $MaxWaitMinutes min)" -LogFile $LogFile
        }

        Start-Sleep -Seconds $PollSeconds
        $iterationsSlept++
        $waited += $PollSeconds
    }

    $status = $null
    $resumedCount = 0

    if (Test-ClaudeSession -DistroName $DistroName) {
        $status = 'SessionPresent'
        Write-WslAutomationLog -Message 'Claude Remote Control session present; nothing to do' -LogFile $LogFile

        $snapshot = $null
        if (-not $NoSessionRestore) {
            $snapshot = Read-ClaudeAgentSnapshot -Path $SessionSnapshotPath
        }

        if ($snapshot -and $snapshot.RestorePending) {
            # The Remote Control server died on an earlier run and the restore could not run
            # then (typically: the distro was stopped by a backup and was not Running yet).
            # Restore now, BEFORE refreshing the snapshot - the live list no longer contains
            # the lost sessions, so refreshing first would forget them.
            $restore = Invoke-ClaudeSessionRestore -DistroName $DistroName -Snapshot $snapshot -LogFile $LogFile -DryRun:$DryRun
            $resumedCount = $restore.Resumed
            if ($restore.Completed -and -not $DryRun) {
                Write-ClaudeAgentSnapshot -Path $SessionSnapshotPath -Sessions $snapshot.Sessions -CapturedAt $snapshot.CapturedAt
            }
        }
        elseif (-not $DryRun) {
            $sessions = Get-ClaudeAgentSessions -DistroName $DistroName
            if ($null -ne $sessions) {
                Write-ClaudeAgentSnapshot -Path $SessionSnapshotPath -Sessions $sessions
            }
        }
    }
    else {
        if ($DryRun) {
            $status = 'DryRun'
            Write-WslAutomationLog -Message 'DryRun: would launch a Claude Remote Control session' -LogFile $LogFile
        }
        else {
            $status = 'Launched'
            Start-ClaudeLauncherTask -LauncherTaskName $LauncherTaskName
            Write-WslAutomationLog -Message "Launched new Claude Remote Control session (via '$LauncherTaskName')" -LogFile $LogFile
        }

        if (-not $NoSessionRestore) {
            $snapshot = Read-ClaudeAgentSnapshot -Path $SessionSnapshotPath
            if (-not $snapshot) {
                Write-WslAutomationLog -Message 'Session restore: no usable session snapshot (missing or unreadable); skipping' -LogFile $LogFile
            }
            else {
                if (-not $DryRun -and -not $snapshot.RestorePending) {
                    # Mark the snapshot first so a run that cannot list sessions yet (distro not
                    # Running) leaves the restore to the next run instead of letting that run
                    # overwrite the snapshot with the post-crash list.
                    Write-ClaudeAgentSnapshot -Path $SessionSnapshotPath -Sessions $snapshot.Sessions `
                        -CapturedAt $snapshot.CapturedAt -RestorePending
                }
                $restore = Invoke-ClaudeSessionRestore -DistroName $DistroName -Snapshot $snapshot -LogFile $LogFile -DryRun:$DryRun
                $resumedCount = $restore.Resumed
                if ($restore.Completed -and -not $DryRun) {
                    Write-ClaudeAgentSnapshot -Path $SessionSnapshotPath -Sessions $snapshot.Sessions -CapturedAt $snapshot.CapturedAt
                }
            }
        }
    }

    $codexLaunched = $false
    if (-not $NoCodexAgents -and -not (Test-CodexAgentsSession -DistroName $DistroName)) {
        if ($DryRun) {
            Write-WslAutomationLog -Message 'DryRun: would launch a codex agents tab' -LogFile $LogFile
        }
        else {
            Start-ClaudeLauncherTask -LauncherTaskName $CodexLauncherTaskName
            Write-WslAutomationLog -Message "Launched new codex agents tab (via '$CodexLauncherTaskName')" -LogFile $LogFile
            $codexLaunched = $true
        }
    }

    return [pscustomobject]@{
        Status              = $status
        WaitedSeconds       = [int]$waited
        ResumedSessionCount = [int]$resumedCount
        CodexAgentsLaunched = $codexLaunched
    }
}
