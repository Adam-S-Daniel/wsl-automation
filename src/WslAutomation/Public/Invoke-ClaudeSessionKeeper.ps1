function Invoke-ClaudeSessionKeeper {
    <#
    .SYNOPSIS
        Ensures an interactive Claude Code session is running inside a WSL distro, waiting out
        any in-progress backup first.
    .DESCRIPTION
        Intended to run on a short recurring schedule (for example every 5 minutes) so a Claude
        Code session is always available without ever colliding with a WSL export backup.
        Before doing anything else it checks the shared backup lock (see New-WslBackupLock /
        Test-WslBackupLock): if a backup is in progress it polls on an interval, waiting up to a
        maximum total time, then proceeds anyway rather than waiting forever. A lock left behind
        by a crashed or killed backup run is detected as stale (older than -LockStaleMinutes)
        and is cleared immediately, with no waiting.

        Once the lock is clear - or ignored as stale, or the wait is exhausted - it checks
        whether a Claude Code session is already running (Test-ClaudeSession) and only launches
        a new one when none is found. Because the keeper itself runs as a background (session 0)
        scheduled task - so its frequent check never flashes a window on the desktop - it cannot
        show a terminal directly; it launches by triggering the interactive on-demand launcher
        task (Start-ClaudeLauncherTask) instead.
    .PARAMETER DistroName
        Name of the WSL distro to check/launch into. Defaults to 'Ubuntu'.
    .PARAMETER LauncherTaskName
        Name of the interactive scheduled task that actually opens the session. Defaults to
        'Claude Code Session Launcher'.
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
    .PARAMETER DryRun
        When a session would be launched, only log the intent and return 'DryRun' instead of
        actually starting one.
    .EXAMPLE
        Invoke-ClaudeSessionKeeper

        Waits out any backup, then launches a Claude Code session if one isn't already running.
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

    if (Test-ClaudeSession -DistroName $DistroName) {
        Write-WslAutomationLog -Message 'Claude session present; nothing to do' -LogFile $LogFile
        return [pscustomobject]@{ Status = 'SessionPresent'; WaitedSeconds = [int]$waited }
    }

    if ($DryRun) {
        Write-WslAutomationLog -Message 'DryRun: would launch a Claude session' -LogFile $LogFile
        return [pscustomobject]@{ Status = 'DryRun'; WaitedSeconds = [int]$waited }
    }

    Start-ClaudeLauncherTask -LauncherTaskName $LauncherTaskName
    Write-WslAutomationLog -Message "Launched new Claude session (via '$LauncherTaskName')" -LogFile $LogFile
    return [pscustomobject]@{ Status = 'Launched'; WaitedSeconds = [int]$waited }
}
