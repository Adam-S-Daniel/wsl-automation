#requires -Version 7.6

function Set-WslAutomationScheduledTasks {
    <#
    .SYNOPSIS
        Registers or updates the scheduled tasks that drive WSL backups, the Claude Code
        session keeper and its two launchers, ccstatusline config sync, Codex Cloud environment
        sync, the daily usage census publish, the daily session miner, the weekly memory curation,
        the every-minute waiting feed publish, the daily task health publish, and the Docker
        Desktop WSL integration watchdog.

    .DESCRIPTION
        Creates twelve Windows Scheduled Tasks, or updates them in place if they already exist:
        a daily backup task that runs scripts/wsl-restic-backup.ps1 (a live restic backup of the
        running distro - see Invoke-WslResticBackup); a session-keeper task that
        runs scripts/ensure-claude-session.ps1 on a short repeating interval; an on-demand
        launcher task the keeper triggers to actually open a Remote Control Claude Code session
        in Windows Terminal; a second on-demand launcher task the keeper triggers to run
        'codex remote-control start'; and a ccstatusline config sync task that runs scripts/sync-ccstatusline-config.ps1
        on its own short repeating interval; and a Codex Cloud environment sync task that runs
        scripts/sync-codex-cloud-environments.ps1 at midnight and noon while the distro is running;
        and a usage census publish task that runs scripts/publish-usage-census.sh inside the
        distro once a day, calling wsl.exe directly so no pwsh is involved; and a session miner
        task that runs scripts/run-session-miner.sh the same way once a day; and a memory curation
        task that runs scripts/run-memory-curation.sh the same way once a week; and a waiting feed
        publish task that runs scripts/publish-waiting-feed.sh inside the distro every minute, the
        same way; and a task health publish task that runs scripts/publish-task-health.sh the same
        way once a day; and a Docker WSL integration watchdog task that runs
        scripts/ensure-docker-wsl-integration.ps1 (through conhost --headless) at logon and every
        30 minutes, restarting Docker Desktop when its WSL integration with the distro is broken.

        The watchdog is the one pwsh-based task that is Interactive, not S4U: 'docker desktop
        restart' relaunches the Docker Desktop GUI, which must land in the user's session rather
        than session 0, and the alert toast needs the user's desktop. conhost.exe --headless runs
        its pwsh without a console window, so the interactive run does not flash one.

        The backup, keeper and ccstatusline tasks run as background S4U tasks (session 0), so
        they never flash a console window on the desktop; both launchers are interactive (they
        must show a terminal) and on-demand (no trigger). The three pwsh-based S4U tasks require
        an MSI PowerShell 7 and the "Log on as a batch job" right - see -PwshPath and
        scripts/grant-keeper-batch-logon.ps1. The usage census, session miner, memory curation, waiting feed and task health tasks are S4U too, but
        their action is wsl.exe itself, so they need no pwsh at all.

        Every task's Settings and Principal are always (re)built fresh from this function's
        parameters, whether the task already exists or not, so their battery/idle behavior stays
        in sync; the Codex remote control launcher is built exactly like the Claude Code one.
        That now includes the backup task, which used to keep an existing task's Settings and
        Principal: re-running this function is what switches an existing backup task from the
        interactive 'wsl --export' backup to the background restic one in place. Re-running
        this function is idempotent for all twelve tasks.

        The backup task's trigger fires daily at -BackupTime and then repeats every
        -BackupRetryIntervalMinutes for the following day, so a run Invoke-WslBackup itself
        deferred (a recent wake, or WSL in active use) - or one simply missed because the machine
        was asleep at -BackupTime - gets retried on an hourly cadence instead of relying on
        -StartWhenAvailable, which used to fire a missed run the instant the machine woke, before
        WSL had finished its own post-wake transition (see AGENTS.md).

        Also archives any legacy scripts passed via -LegacyScriptsToArchive by renaming them
        out of the way, so a stale scheduled task still pointing at an old script path fails
        loudly instead of silently continuing to run superseded automation.

        Windows-only: throws immediately if $IsWindows is false.

    .PARAMETER ScriptsDir
        Directory containing wsl-restic-backup.ps1 (and the wsl-restic-backup.sh and
        wsl-restic-excludes.txt it runs), ensure-claude-session.ps1, and
        sync-ccstatusline-config.ps1, sync-codex-cloud-environments.ps1, and
        publish-usage-census.sh, run-session-miner.sh, run-memory-curation.sh, publish-waiting-feed.sh and publish-task-health.sh.

    .PARAMETER BackupDir
        The OneDrive-synced directory the backup task copies the restic repository into (its
        'restic' subdirectory) and writes its log to.

    .PARAMETER ResticRepoDir
        The restic repository on a local Windows drive, for example 'D:\Backups\wsl-restic'.
        Must be a drive-letter path; the distro reaches it at /mnt/<drive>/... .

    .PARAMETER DistroName
        Name of the WSL distro to back up and to keep a Remote Control Claude Code session alive
        in. Defaults to 'Ubuntu'.

    .PARAMETER WakeBackupToRun
        When set, the backup task is registered with -WakeToRun so Windows wakes the machine
        from sleep to run the backup. Off by default: on Modern Standby (S0 low-power idle)
        laptops - which never truly sleep and instead sit in connected standby - a scheduled
        wake pulls the SoC back out of its low-power phase and has been observed to hang the
        machine in a half-woken state that only a hard power-off recovers. With this off, a
        missed 02:00 run is instead caught by the trigger's own hourly repetition
        (-BackupRetryIntervalMinutes) the next time the machine is awake - not by
        -StartWhenAvailable, which this task no longer sets on either a fresh registration or an
        update: it used to fire a missed run the instant the machine woke, straight into the WSL
        transition window Invoke-WslResticBackup's own wake guard now defers instead (see
        AGENTS.md). Only enable -WakeBackupToRun on hardware where scheduled wake is reliable
        (for example an S3-capable desktop). The backup task's settings are rebuilt on every
        run, so this applies to an existing task too: re-running without it turns WakeToRun
        off.

    .PARAMETER BackupTaskName
        Name of the scheduled task that runs the backup. Defaults to 'WSL Ubuntu Daily Backup'.

    .PARAMETER KeeperTaskName
        Name of the scheduled task that runs the session keeper. Defaults to 'Claude Code
        Session Keeper'.

    .PARAMETER LauncherTaskName
        Name of the interactive, on-demand task the keeper triggers to open a Remote Control
        Claude Code session. Defaults to 'Claude Code Session Launcher'.

    .PARAMETER CodexLauncherTaskName
        Name of the interactive, on-demand task the keeper triggers to run
        'codex remote-control start'. Defaults to 'Codex Remote Control Launcher'. The keeper looks the task up by its own
        -CodexLauncherTaskName default, so a different name here also has to be passed to the
        keeper.

    .PARAMETER BackupTime
        Time of day (HH:mm) the backup task's daily trigger fires. Defaults to '02:00'.

    .PARAMETER BackupRetryIntervalMinutes
        How often, in minutes, the backup task's trigger repeats over the day following
        -BackupTime, so a run deferred by Invoke-WslResticBackup's wake guard (or simply missed
        because the machine was asleep) gets retried without -StartWhenAvailable. Once a run
        succeeds, the rest of the day's retries skip silently.
        Defaults to 60.

    .PARAMETER KeeperIntervalMinutes
        How often, in minutes, the keeper task repeats indefinitely. Defaults to 5.

    .PARAMETER CcstatuslineTaskName
        Name of the scheduled task that syncs the ccstatusline config from WSL. Defaults to
        'ccstatusline Config Sync'.

    .PARAMETER CcstatuslineIntervalMinutes
        How often, in minutes, the ccstatusline config sync task repeats indefinitely. Defaults
        to 5.

    .PARAMETER CodexCloudEnvironmentSyncTaskName
        Name of the scheduled task that reconciles Codex Cloud environments. Defaults to
        'Codex Cloud Environment Sync'.

    .PARAMETER UsageCensusTaskName
        Name of the scheduled task that publishes the daily usage census from WSL. Defaults to
        'Usage Census Publish'.

    .PARAMETER UsageCensusTime
        Time of day (HH:mm) the usage census task's daily trigger fires. Defaults to '12:37':
        the laptop is usually awake at midday, and :37 is well clear of the backup's :00 hourly
        retries.

    .PARAMETER SessionMinerTaskName
        Name of the scheduled task that runs the daily session miner from WSL. Defaults to
        'Session Miner'.

    .PARAMETER SessionMinerTime
        Time of day (HH:mm) the session miner task's daily trigger fires. Defaults to '12:47',
        ten minutes after the usage census so the two never overlap.

    .PARAMETER MemoryCurationTaskName
        Name of the scheduled task that runs the weekly memory curation from WSL. Defaults to
        'Memory Curation'.

    .PARAMETER MemoryCurationTime
        Time of day (HH:mm) the memory curation task's weekly (Monday) trigger fires. Defaults
        to '13:47', an hour after the session miner so the two never overlap.

    .PARAMETER WaitingFeedTaskName
        Name of the scheduled task that publishes the waiting feed (the Claude Code cloud
        sessions waiting on the owner) from WSL every minute. Defaults to
        'Claude Waiting Feed Publish'.

    .PARAMETER TaskHealthTaskName
        Name of the scheduled task that publishes the daily task health snapshot (counts, states
        and timestamps only) from WSL. Defaults to 'Task Health Publish'.

    .PARAMETER TaskHealthTime
        Time of day (HH:mm) the task health task's daily trigger fires. Defaults to '23:47',
        late in the day so the snapshot reflects that day's runs, and well clear of every other
        task's time.

    .PARAMETER DockerWatchdogTaskName
        Name of the scheduled task that runs the Docker Desktop WSL integration watchdog.
        Defaults to 'Docker WSL Integration Watchdog'.

    .PARAMETER DockerWatchdogIntervalMinutes
        How often, in minutes, the watchdog task repeats indefinitely. Defaults to 30. The
        watchdog's own wake guard defers a repetition that lands right after a boot or resume.

    .PARAMETER DockerWatchdogLogonDelayMinutes
        Delay, in minutes, after logon before the watchdog's at-logon trigger fires. Defaults to
        12: WSL's post-boot init window runs to roughly 270 seconds, and Docker Desktop starts at
        login too, so the check waits beyond both (see AGENTS.md).

    .PARAMETER WslExePath
        Path to wsl.exe used as the usage census, session miner, memory curation, waiting feed and task health tasks' action. Defaults to
        %SystemRoot%\System32\wsl.exe.

    .PARAMETER ConhostPath
        Path to conhost.exe used as the Docker watchdog task's action executable, with
        --headless so the interactive run shows no console window. Defaults to
        %SystemRoot%\System32\conhost.exe.

    .PARAMETER PwshPath
        Path to pwsh.exe used as the action executable for the pwsh-based tasks. Defaults to an
        MSI install of PowerShell 7 (C:\Program Files\PowerShell\7) when present - required for
        the S4U keeper and ccstatusline tasks, which run in session 0 where a Store-packaged pwsh
        cannot launch - then the per-user WindowsApps alias, then the pwsh.exe found on PATH. A
        warning is emitted if a Store-packaged path would be used for the keeper.

    .PARAMETER WtPath
        Path to wt.exe (Windows Terminal) used as both launcher tasks' action. Defaults to the
        stable per-user WindowsApps execution alias when present, else wt.exe on PATH.

    .PARAMETER LegacyScriptsToArchive
        Paths to legacy scripts that should be renamed out of the way because this module
        supersedes them. Workaround included for invocation via `pwsh -File ... -LegacyScriptsToArchive
        "C:\a.ps1","C:\b.ps1"` from another shell (notably Windows PowerShell 5.1): -File mode
        never re-parses commas, so the two paths can arrive flattened into one literal string
        "C:\a.ps1,C:\b.ps1". Any element that is a comma-joined list of rooted Windows paths
        (each looking like `C:\...` or `\\server\share\...`) is automatically expanded back into
        separate paths before archiving.

    .PARAMETER SkipTaskHistory
        Skips enabling the Microsoft-Windows-TaskScheduler/Operational event log (the "History"
        tab in Task Scheduler), which this function otherwise enables once per run if it is
        currently disabled. A failure to enable it only warns; it never aborts task
        registration. See README.md's "Task history" section for what the log records and how
        to read it.

    .EXAMPLE
        Set-WslAutomationScheduledTasks -ScriptsDir 'C:\Users\<you>\repos\wsl-automation\scripts' -BackupDir 'C:\Users\<you>\OneDrive\Backups\WSL' -ResticRepoDir 'D:\Backups\wsl-restic'

        Registers (or updates) all twelve scheduled tasks using default names, backup time, and
        keeper/ccstatusline intervals, the twice-daily Codex Cloud environment sync, and the
        daily usage census publish, the daily session miner, the weekly memory curation, the every-minute waiting feed publish, the daily task health
        publish, and the Docker WSL integration watchdog.

    .EXAMPLE
        Set-WslAutomationScheduledTasks -ScriptsDir $PSScriptRoot -BackupDir 'C:\Backups\WSL' -ResticRepoDir 'D:\Backups\wsl-restic' -WhatIf

        Shows what would change without actually registering, updating, or renaming anything.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseSingularNouns',
        '',
        Justification = 'This function manages seven related scheduled tasks by design; Set-WslAutomationScheduledTasks is the name specified by the project spec.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptsDir,

        [Parameter(Mandatory)]
        [string]$BackupDir,

        [Parameter(Mandatory)]
        [string]$ResticRepoDir,

        [string]$DistroName = 'Ubuntu',

        [switch]$WakeBackupToRun,

        [string]$BackupTaskName = 'WSL Ubuntu Daily Backup',

        [string]$KeeperTaskName = 'Claude Code Session Keeper',

        [string]$LauncherTaskName = 'Claude Code Session Launcher',

        [string]$CodexLauncherTaskName = 'Codex Remote Control Launcher',

        [string]$BackupTime = '02:00',

        [int]$BackupRetryIntervalMinutes = 60,

        [int]$KeeperIntervalMinutes = 5,

        [string]$CcstatuslineTaskName = 'ccstatusline Config Sync',

        [int]$CcstatuslineIntervalMinutes = 5,

        [string]$CodexCloudEnvironmentSyncTaskName = 'Codex Cloud Environment Sync',

        [string]$UsageCensusTaskName = 'Usage Census Publish',

        [string]$UsageCensusTime = '12:37',

        [string]$SessionMinerTaskName = 'Session Miner',

        [string]$SessionMinerTime = '12:47',

        [string]$MemoryCurationTaskName = 'Memory Curation',

        [string]$MemoryCurationTime = '13:47',

        [string]$WaitingFeedTaskName = 'Claude Waiting Feed Publish',

        [string]$TaskHealthTaskName = 'Task Health Publish',

        [string]$TaskHealthTime = '23:47',

        [string]$DockerWatchdogTaskName = 'Docker WSL Integration Watchdog',

        [int]$DockerWatchdogIntervalMinutes = 30,

        [int]$DockerWatchdogLogonDelayMinutes = 12,

        [string]$WslExePath = (Join-Path $env:SystemRoot 'System32\wsl.exe'),

        [string]$ConhostPath = (Join-Path $env:SystemRoot 'System32\conhost.exe'),

        [string]$PwshPath = (Get-WslAutomationDefaultPwshPath),

        [string]$WtPath = (Get-WslAutomationDefaultWtPath),

        [string[]]$LegacyScriptsToArchive = @(),

        [switch]$SkipTaskHistory
    )

    if (-not $IsWindows) {
        throw 'Set-WslAutomationScheduledTasks can only run on Windows.'
    }

    # A trailing separator is a common way to type or tab-complete a directory (for example
    # 'D:\WSLBackups\'). Embedded raw into a double-quoted native command-line argument, a
    # trailing backslash escapes the closing quote instead of terminating the value, corrupting
    # every argument after it - including silently dropping -NoPause, which reintroduces the
    # Read-Host hang under the hidden scheduled task that -NoPause exists to prevent. Trim
    # defensively for every user-supplied path embedded in a quoted argument string below.
    $BackupDir = $BackupDir.TrimEnd('\')
    $ResticRepoDir = $ResticRepoDir.TrimEnd('\')
    $ScriptsDir = $ScriptsDir.TrimEnd('\')
    $PwshPath = $PwshPath.TrimEnd('\')

    # --- Backup task: action + daily trigger repeating over the following day ---------------
    # The live restic backup (Invoke-WslResticBackup) replaced the 'wsl --export' one under the
    # same task name, so re-running the installer switches the task in place. wsl-ubuntu-backup.ps1
    # and Invoke-WslBackup stay in the module as a manual-only command.
    $backupScriptPath = Join-Path $ScriptsDir 'wsl-restic-backup.ps1'
    $backupArguments = "-NoProfile -File `"$backupScriptPath`" -BackupDir `"$BackupDir`" -RepoDir `"$ResticRepoDir`" -DistroName $DistroName -NoPause"
    $backupAction = New-ScheduledTaskAction -Execute $PwshPath -Argument $backupArguments
    # Every trigger goes through ConvertTo-WslLocalTimeTrigger so its start time is local
    # wall-clock time and does not shift by an hour when the clocks change.
    $backupTrigger = New-ScheduledTaskTrigger -Daily -At $BackupTime | ConvertTo-WslLocalTimeTrigger

    # -Daily has no -RepetitionInterval/-RepetitionDuration parameter set at all (unlike -Once,
    # see the keeper trigger comment below), and a trigger built without one has Repetition =
    # $null - mutating .Repetition.Interval on that $null throws the same "property 'Interval'
    # cannot be found" error a -Once trigger hits. Building a whole new MSFT_TaskRepetitionPattern
    # CimInstance and assigning it to .Repetition (rather than mutating a property on the existing
    # null one) is the construction that actually works; verified by hand against pwsh 7.6's
    # ScheduledTasks module (construction only, nothing registered).
    # [System.Xml.XmlConvert]::ToString(timespan) is used rather than hand-formatting an ISO 8601
    # duration string so a non-round-number interval (for example 90 minutes) still comes out
    # correct ('PT1H30M'), not just the common cases.
    $backupRepetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
        Interval          = [System.Xml.XmlConvert]::ToString([timespan]::FromMinutes($BackupRetryIntervalMinutes))
        Duration          = [System.Xml.XmlConvert]::ToString([timespan]::FromDays(1))
        StopAtDurationEnd = $false
    }
    $backupTrigger.Repetition = $backupRepetition

    # Settings/Principal are always rebuilt fresh for the backup task now, like the keeper's,
    # whether it already exists or not. They used to be carried through from an existing task,
    # because that task was the interactive 'wsl --export' backup and its settings were tuned by
    # hand. Switching it to the restic backup needs every one of them to change, and carrying
    # them through would silently keep the export's:
    # - Principal: S4U (session 0) instead of Interactive. The export needed the user's own
    #   session; 'wsl.exe -u root' does not, and S4U is what keeps the run from ever opening a
    #   window on the desktop (see the keeper principal below).
    # - Battery: allowed to start on battery and not stopped when unplugged. The AC-only rule
    #   existed because a 27-65 GB export ran on battery; a daily restic run takes a minute or
    #   two, and an AC-only task on a laptop that is rarely plugged in would rarely back up.
    # - ExecutionTimeLimit: 2 hours instead of the export's 4.
    # - StartWhenAvailable: off - the trigger's own -BackupRetryIntervalMinutes repetition is
    #   what catches up a missed run, without firing the instant the machine wakes into WSL's
    #   post-wake transition window.
    # - WakeToRun: only with -WakeBackupToRun (waking a Modern Standby laptop for the backup can
    #   hang it in a half-woken state). Because the settings are rebuilt, this now applies to an
    #   existing task too.
    # - MultipleInstances IgnoreNew, so a slow run is never doubled up by the next retry.
    $backupSettingsParams = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable         = $false
        ExecutionTimeLimit         = New-TimeSpan -Hours 2
        MultipleInstances          = 'IgnoreNew'
    }
    if ($WakeBackupToRun) {
        $backupSettingsParams['WakeToRun'] = $true
    }
    $backupSettings = New-ScheduledTaskSettingsSet @backupSettingsParams
    $backupPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingBackupTask = Get-ScheduledTask -TaskName $BackupTaskName -ErrorAction SilentlyContinue
    if ($existingBackupTask) {
        # Only the Action, Triggers, Settings and Principal are replaced; any logon or other
        # trigger the task picked up over time is dropped in favor of the one daily trigger.
        if ($PSCmdlet.ShouldProcess($BackupTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $BackupTaskName -Action $backupAction -Trigger $backupTrigger `
                -Settings $backupSettings -Principal $backupPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($BackupTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $BackupTaskName -Action $backupAction -Trigger $backupTrigger `
                -Settings $backupSettings -Principal $backupPrincipal
        }
    }

    # --- Keeper task: action + indefinitely-repeating trigger --------------
    $keeperScriptPath = Join-Path $ScriptsDir 'ensure-claude-session.ps1'
    # The keeper runs as a background (session 0, S4U) task - see $keeperPrincipal below - so its
    # routine every-few-minutes "is a session already running?" check can never flash a window on
    # the desktop: session 0 has no interactive desktop to draw one on. It therefore does not (and
    # cannot) open the terminal itself; when a session needs starting it triggers the interactive
    # launcher task below.
    $keeperArguments = "-NoProfile -File `"$keeperScriptPath`" -DistroName $DistroName"
    $keeperAction = New-ScheduledTaskAction -Execute $PwshPath -Argument $keeperArguments

    # A Store-packaged pwsh (per-user WindowsApps alias or version-pinned WindowsApps package
    # path) cannot be activated in the session 0 the S4U keeper runs in - the task fails with
    # access denied every interval, silently. Warn loudly so the operator installs PowerShell 7
    # via MSI (see the README and scripts/grant-keeper-batch-logon.ps1) instead.
    $windowsAppsRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        (Join-Path $env:ProgramFiles 'WindowsApps')
    )
    foreach ($windowsAppsRoot in $windowsAppsRoots) {
        if ($PwshPath -and $PwshPath.StartsWith($windowsAppsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning ("Keeper task pwsh '$PwshPath' is a Store-packaged path; a Store pwsh cannot launch in the " +
                'non-interactive session 0 the S4U keeper uses, so the keeper would fail every interval. Install ' +
                'PowerShell 7 via MSI (C:\Program Files\PowerShell\7) and re-run, or pass -PwshPath to a non-Store pwsh.')
            break
        }
    }

    # -RepetitionInterval at creation time is the construction pwsh 7.6's ScheduledTasks module
    # actually supports for an indefinitely-repeating trigger: a -Once trigger built without it
    # has Repetition = $null (mutating .Repetition.Interval on it afterward throws "The property
    # 'Interval' cannot be found on this object"), and separately assigning Repetition.Duration =
    # '' is rejected by the Task Scheduler XML validator at registration time. Leaving
    # -RepetitionDuration unset here is required, not incidental - it is what makes the
    # repetition indefinite.
    $keeperTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $KeeperIntervalMinutes) | ConvertTo-WslLocalTimeTrigger

    # Settings/Principal are always rebuilt fresh for the keeper task, regardless of whether
    # it already exists, so its battery/idle behavior always matches this function's defaults.
    $keeperSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    # S4U ("run whether the user is logged on or not", no stored password) runs the check in the
    # non-interactive session 0 - the only way to guarantee its console never appears on the
    # desktop, even briefly. -WindowStyle Hidden could not: Task Scheduler still creates the pwsh
    # console window before pwsh can hide it, producing the brief pop-to-front this replaced.
    $keeperPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingKeeperTask = Get-ScheduledTask -TaskName $KeeperTaskName -ErrorAction SilentlyContinue
    if ($existingKeeperTask) {
        if ($PSCmdlet.ShouldProcess($KeeperTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $KeeperTaskName -Action $keeperAction -Trigger $keeperTrigger `
                -Settings $keeperSettings -Principal $keeperPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($KeeperTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $KeeperTaskName -Action $keeperAction -Trigger $keeperTrigger `
                -Settings $keeperSettings -Principal $keeperPrincipal
        }
    }

    # --- Launcher task: interactive, on-demand terminal opener --------------
    # The background keeper triggers this task (by name) when no Remote Control session is
    # running. It is the one task that runs in the user's interactive session, so its Windows
    # Terminal window is actually visible. Its action is wt.exe DIRECTLY (not pwsh) so even opening
    # a session never flashes a pwsh console. It has no trigger of its own - it only ever runs on
    # demand (Trigger = $null; Register-/Set-WslScheduledTask omit -Trigger entirely for it). The
    # session it opens runs 'claude rc' (Remote Control server mode), which is what makes sessions
    # reachable from claude.ai and the phone, and what Test-ClaudeSession looks for - see Get-ClaudeSessionWtArgumentList.
    $launcherArguments = (Get-ClaudeSessionWtArgumentList -DistroName $DistroName) -join ' '
    $launcherAction = New-ScheduledTaskAction -Execute $WtPath -Argument $launcherArguments
    $launcherSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew
    $launcherPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

    $existingLauncherTask = Get-ScheduledTask -TaskName $LauncherTaskName -ErrorAction SilentlyContinue
    if ($existingLauncherTask) {
        if ($PSCmdlet.ShouldProcess($LauncherTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $LauncherTaskName -Action $launcherAction -Trigger $null `
                -Settings $launcherSettings -Principal $launcherPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($LauncherTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $LauncherTaskName -Action $launcherAction -Trigger $null `
                -Settings $launcherSettings -Principal $launcherPrincipal
        }
    }

    # --- Codex remote control launcher task: interactive, on-demand terminal opener ---
    # Built exactly like the Claude Code launcher above - same wt.exe action shape, settings and
    # interactive principal, no trigger of its own - but the tab runs 'codex remote-control start'
    # (see Get-CodexRemoteControlWtArgumentList). The keeper triggers it by name when
    # Test-CodexRemoteControl finds no remote-control daemon.
    $codexLauncherArguments = (Get-CodexRemoteControlWtArgumentList -DistroName $DistroName) -join ' '
    $codexLauncherAction = New-ScheduledTaskAction -Execute $WtPath -Argument $codexLauncherArguments
    $codexLauncherSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew
    $codexLauncherPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

    $existingCodexLauncherTask = Get-ScheduledTask -TaskName $CodexLauncherTaskName -ErrorAction SilentlyContinue
    if ($existingCodexLauncherTask) {
        if ($PSCmdlet.ShouldProcess($CodexLauncherTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $CodexLauncherTaskName -Action $codexLauncherAction -Trigger $null `
                -Settings $codexLauncherSettings -Principal $codexLauncherPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($CodexLauncherTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $CodexLauncherTaskName -Action $codexLauncherAction -Trigger $null `
                -Settings $codexLauncherSettings -Principal $codexLauncherPrincipal
        }
    }

    # --- ccstatusline task: background config sync -------------------------
    # Purely background work (reads the ccstatusline config out of WSL) that never needs a window,
    # so - like the keeper - it runs as an S4U/session-0 task. Otherwise it would flash its own
    # pwsh console every interval, the very flash the keeper split removed. -WindowStyle Hidden is
    # dropped for the same reason it was dropped from the keeper (it only shrinks, not removes, the
    # flash). Same session-0 requirements apply as the keeper: an MSI pwsh (see the warning above)
    # and the batch-logon right.
    $ccstatuslineScriptPath = Join-Path $ScriptsDir 'sync-ccstatusline-config.ps1'
    $ccstatuslineArguments = "-NoProfile -File `"$ccstatuslineScriptPath`" -DistroName $DistroName"
    $ccstatuslineAction = New-ScheduledTaskAction -Execute $PwshPath -Argument $ccstatuslineArguments

    # Same indefinite-repetition construction as the keeper trigger above (-Once + creation-time
    # -RepetitionInterval, never mutated afterward); see the comment on $keeperTrigger for why.
    $ccstatuslineTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $CcstatuslineIntervalMinutes) | ConvertTo-WslLocalTimeTrigger

    # Settings/Principal are always rebuilt fresh for the ccstatusline task too, regardless of
    # whether it already exists, so its battery/idle behavior always matches this function's
    # defaults.
    $ccstatuslineSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $ccstatuslinePrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingCcstatuslineTask = Get-ScheduledTask -TaskName $CcstatuslineTaskName -ErrorAction SilentlyContinue
    if ($existingCcstatuslineTask) {
        if ($PSCmdlet.ShouldProcess($CcstatuslineTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $CcstatuslineTaskName -Action $ccstatuslineAction -Trigger $ccstatuslineTrigger `
                -Settings $ccstatuslineSettings -Principal $ccstatuslinePrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($CcstatuslineTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $CcstatuslineTaskName -Action $ccstatuslineAction -Trigger $ccstatuslineTrigger `
                -Settings $ccstatuslineSettings -Principal $ccstatuslinePrincipal
        }
    }

    # --- Codex Cloud environment sync: exactly two daily triggers ---------
    # This S4U task is background-only like the keeper and ccstatusline sync. It deliberately
    # has no StartWhenAvailable setting: it preserves the exact noon/midnight attempts and a
    # missed time stays missed. The wrapper checks state but never starts WSL.
    $codexCloudSyncScriptPath = Join-Path $ScriptsDir 'sync-codex-cloud-environments.ps1'
    $codexCloudSyncArguments = "-NoProfile -File `"$codexCloudSyncScriptPath`" -DistroName $DistroName"
    $codexCloudSyncAction = New-ScheduledTaskAction -Execute $PwshPath -Argument $codexCloudSyncArguments
    $codexCloudSyncTriggers = @(
        (New-ScheduledTaskTrigger -Daily -At '00:00' | ConvertTo-WslLocalTimeTrigger),
        (New-ScheduledTaskTrigger -Daily -At '12:00' | ConvertTo-WslLocalTimeTrigger)
    )
    $codexCloudSyncSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
    $codexCloudSyncPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingCodexCloudSyncTask = Get-ScheduledTask -TaskName $CodexCloudEnvironmentSyncTaskName -ErrorAction SilentlyContinue
    if ($existingCodexCloudSyncTask) {
        if ($PSCmdlet.ShouldProcess($CodexCloudEnvironmentSyncTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $CodexCloudEnvironmentSyncTaskName -Action $codexCloudSyncAction -Trigger $codexCloudSyncTriggers `
                -Settings $codexCloudSyncSettings -Principal $codexCloudSyncPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($CodexCloudEnvironmentSyncTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $CodexCloudEnvironmentSyncTaskName -Action $codexCloudSyncAction -Trigger $codexCloudSyncTriggers `
                -Settings $codexCloudSyncSettings -Principal $codexCloudSyncPrincipal
        }
    }

    # --- Catch-up settings shared by the three daily wsl.exe publish tasks ---
    # Usage census, session miner and task health run once a day; a laptop asleep at that minute
    # used to skip the day (Task Scheduler result 0x800710E0, 2147946720 - Session Miner went
    # two days without a real run). StartWhenAvailable now runs the missed task once the machine
    # wakes. The backup keeps it off because wsl --export dies inside WSL's post-wake transition
    # window; these scripts only need a working wsl.exe, so a catch-up that lands in that window
    # and fails is retried (3 times, 10 minutes apart - past the ~270 s window) instead.
    $catchUpSettingsParams = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable         = $true
        RestartCount               = 3
        RestartInterval            = New-TimeSpan -Minutes 10
        ExecutionTimeLimit         = New-TimeSpan -Minutes 15
        MultipleInstances          = 'IgnoreNew'
    }

    # --- Usage census publish: one daily trigger, wsl.exe as the action -----
    # Background-only like the Codex Cloud sync, but the action is wsl.exe DIRECTLY (no pwsh in
    # between) with --cd into the scripts directory and bash running the wrapper. As an S4U task
    # it runs in session 0, so no console window can ever appear. The owner's WSL git
    # authenticates through `gh auth git-credential` with a file-stored token, which works in an
    # S4U logon. StartWhenAvailable is on (see the catch-up settings above): a missed day is caught up on
    # wake, and the restart settings retry a run that hits WSL's post-wake window (see AGENTS.md). $ScriptsDir was trimmed of
    # any trailing backslash above, which would otherwise escape the closing quote.
    $usageCensusArguments = "--distribution $DistroName --cd `"$ScriptsDir`" --exec /bin/bash ./publish-usage-census.sh"
    $usageCensusAction = New-ScheduledTaskAction -Execute $WslExePath -Argument $usageCensusArguments
    $usageCensusTrigger = New-ScheduledTaskTrigger -Daily -At $UsageCensusTime | ConvertTo-WslLocalTimeTrigger
    $usageCensusSettings = New-ScheduledTaskSettingsSet @catchUpSettingsParams
    $usageCensusPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingUsageCensusTask = Get-ScheduledTask -TaskName $UsageCensusTaskName -ErrorAction SilentlyContinue
    if ($existingUsageCensusTask) {
        if ($PSCmdlet.ShouldProcess($UsageCensusTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $UsageCensusTaskName -Action $usageCensusAction -Trigger $usageCensusTrigger `
                -Settings $usageCensusSettings -Principal $usageCensusPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($UsageCensusTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $UsageCensusTaskName -Action $usageCensusAction -Trigger $usageCensusTrigger `
                -Settings $usageCensusSettings -Principal $usageCensusPrincipal
        }
    }

    # --- Session miner: one daily trigger, wsl.exe as the action ------------
    # Built exactly like the usage census task above (wsl.exe directly, S4U, session 0, no
    # StartWhenAvailable): a missed day is simply mined the next day, since the miner reads
    # whatever transcripts exist then. It runs only on the owner's own computer (skills-evals
    # ADR 0015) and exits 2 without ~/.config/privacy-denylist.txt.
    $sessionMinerArguments = "--distribution $DistroName --cd `"$ScriptsDir`" --exec /bin/bash ./run-session-miner.sh"
    $sessionMinerAction = New-ScheduledTaskAction -Execute $WslExePath -Argument $sessionMinerArguments
    $sessionMinerTrigger = New-ScheduledTaskTrigger -Daily -At $SessionMinerTime | ConvertTo-WslLocalTimeTrigger
    $sessionMinerSettings = New-ScheduledTaskSettingsSet @catchUpSettingsParams
    $sessionMinerPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingSessionMinerTask = Get-ScheduledTask -TaskName $SessionMinerTaskName -ErrorAction SilentlyContinue
    if ($existingSessionMinerTask) {
        if ($PSCmdlet.ShouldProcess($SessionMinerTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $SessionMinerTaskName -Action $sessionMinerAction -Trigger $sessionMinerTrigger `
                -Settings $sessionMinerSettings -Principal $sessionMinerPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($SessionMinerTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $SessionMinerTaskName -Action $sessionMinerAction -Trigger $sessionMinerTrigger `
                -Settings $sessionMinerSettings -Principal $sessionMinerPrincipal
        }
    }

    # --- Memory curation: one weekly (Monday) trigger, wsl.exe as the action
    # Built like the session miner above (wsl.exe directly, S4U, session 0, no StartWhenAvailable):
    # a missed week is simply curated the next Monday. The wrapper bounds its own Claude run at 2
    # hours, so the task's limit of 3 hours only ever stops a wedged wrapper.
    $memoryCurationArguments = "--distribution $DistroName --cd `"$ScriptsDir`" --exec /bin/bash ./run-memory-curation.sh"
    $memoryCurationAction = New-ScheduledTaskAction -Execute $WslExePath -Argument $memoryCurationArguments
    $memoryCurationTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $MemoryCurationTime | ConvertTo-WslLocalTimeTrigger
    $memoryCurationSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    $memoryCurationPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingMemoryCurationTask = Get-ScheduledTask -TaskName $MemoryCurationTaskName -ErrorAction SilentlyContinue
    if ($existingMemoryCurationTask) {
        if ($PSCmdlet.ShouldProcess($MemoryCurationTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $MemoryCurationTaskName -Action $memoryCurationAction -Trigger $memoryCurationTrigger `
                -Settings $memoryCurationSettings -Principal $memoryCurationPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($MemoryCurationTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $MemoryCurationTaskName -Action $memoryCurationAction -Trigger $memoryCurationTrigger `
                -Settings $memoryCurationSettings -Principal $memoryCurationPrincipal
        }
    }

    # --- Waiting feed publish: every minute, wsl.exe as the action ----------
    # Same shape as the usage census (wsl.exe directly, S4U, session 0), but repeating every
    # minute with the indefinite-repetition construction the keeper trigger documents above
    # (-Once + creation-time -RepetitionInterval, no -RepetitionDuration). The script is cheap
    # when nothing changed, so a 5 minute limit is generous; IgnoreNew keeps a slow run (a hung
    # push) from stacking up behind itself. No StartWhenAvailable: the feed is a live view, so a
    # missed minute is just skipped.
    $waitingFeedArguments = "--distribution $DistroName --cd `"$ScriptsDir`" --exec /bin/bash ./publish-waiting-feed.sh"
    $waitingFeedAction = New-ScheduledTaskAction -Execute $WslExePath -Argument $waitingFeedArguments
    $waitingFeedTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) | ConvertTo-WslLocalTimeTrigger
    $waitingFeedSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $waitingFeedPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingWaitingFeedTask = Get-ScheduledTask -TaskName $WaitingFeedTaskName -ErrorAction SilentlyContinue
    if ($existingWaitingFeedTask) {
        if ($PSCmdlet.ShouldProcess($WaitingFeedTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $WaitingFeedTaskName -Action $waitingFeedAction -Trigger $waitingFeedTrigger `
                -Settings $waitingFeedSettings -Principal $waitingFeedPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($WaitingFeedTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $WaitingFeedTaskName -Action $waitingFeedAction -Trigger $waitingFeedTrigger `
                -Settings $waitingFeedSettings -Principal $waitingFeedPrincipal
        }
    }

    # --- Task health publish: one daily trigger, wsl.exe as the action ------
    # Built exactly like the usage census (wsl.exe directly, S4U, session 0, shared catch-up settings):
    # a missed day is caught up on wake, since the snapshot is only a heartbeat the cloud audit compares
    # against its own clock. The script makes one Windows PowerShell call for task states, which
    # an S4U logon may make unelevated; the 15 minute limit is generous for one call and a push.
    $taskHealthArguments = "--distribution $DistroName --cd `"$ScriptsDir`" --exec /bin/bash ./publish-task-health.sh"
    $taskHealthAction = New-ScheduledTaskAction -Execute $WslExePath -Argument $taskHealthArguments
    $taskHealthTrigger = New-ScheduledTaskTrigger -Daily -At $TaskHealthTime | ConvertTo-WslLocalTimeTrigger
    $taskHealthSettings = New-ScheduledTaskSettingsSet @catchUpSettingsParams
    $taskHealthPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U

    $existingTaskHealthTask = Get-ScheduledTask -TaskName $TaskHealthTaskName -ErrorAction SilentlyContinue
    if ($existingTaskHealthTask) {
        if ($PSCmdlet.ShouldProcess($TaskHealthTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $TaskHealthTaskName -Action $taskHealthAction -Trigger $taskHealthTrigger `
                -Settings $taskHealthSettings -Principal $taskHealthPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($TaskHealthTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $TaskHealthTaskName -Action $taskHealthAction -Trigger $taskHealthTrigger `
                -Settings $taskHealthSettings -Principal $taskHealthPrincipal
        }
    }

    # --- Docker WSL integration watchdog: logon + every 30 minutes, conhost --headless ----------
    # Repairs Docker Desktop's WSL integration with the distro (and alerts when it cannot); see
    # Invoke-DockerWslIntegrationWatchdog and AGENTS.md. The action is conhost.exe --headless
    # wrapping pwsh: the task is Interactive (below), and --headless keeps that interactive run
    # from flashing a console window the way a bare pwsh would.
    $dockerWatchdogScriptPath = Join-Path $ScriptsDir 'ensure-docker-wsl-integration.ps1'
    $dockerWatchdogArguments = "--headless `"$PwshPath`" -NoProfile -File `"$dockerWatchdogScriptPath`" -DistroName $DistroName"
    $dockerWatchdogAction = New-ScheduledTaskAction -Execute $ConhostPath -Argument $dockerWatchdogArguments

    # Trigger 1: at logon of the current user, delayed so the check never races WSL's post-boot
    # init window (up to ~270 s) or Docker Desktop's own start at login (see AGENTS.md). Task
    # Scheduler wants the delay as an ISO 8601 duration; XmlConvert formats a non-round number
    # of minutes correctly too.
    $dockerWatchdogLogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME" | ConvertTo-WslLocalTimeTrigger
    $dockerWatchdogLogonTrigger.Delay = [System.Xml.XmlConvert]::ToString([timespan]::FromMinutes($DockerWatchdogLogonDelayMinutes))
    # Trigger 2: the same indefinite-repetition construction as the keeper trigger above (-Once +
    # creation-time -RepetitionInterval, never mutated afterward). A repetition tick that lands
    # right after a boot is deferred by the function's own wake guard.
    $dockerWatchdogRepeatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $DockerWatchdogIntervalMinutes) | ConvertTo-WslLocalTimeTrigger
    $dockerWatchdogTriggers = @($dockerWatchdogLogonTrigger, $dockerWatchdogRepeatTrigger)

    # No StartWhenAvailable: a missed tick is simply covered by the next one, and a catch-up at
    # wake would land in the post-wake transition window.
    $dockerWatchdogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
    # Interactive, not S4U, on purpose: 'docker desktop restart' relaunches the Docker Desktop
    # GUI, which must land in the user's session (an S4U task runs in session 0, where the GUI
    # would start unseen and without the user's desktop), and the alert toast needs the user's
    # desktop too. Still the current user, never SYSTEM.
    $dockerWatchdogPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

    $existingDockerWatchdogTask = Get-ScheduledTask -TaskName $DockerWatchdogTaskName -ErrorAction SilentlyContinue
    if ($existingDockerWatchdogTask) {
        if ($PSCmdlet.ShouldProcess($DockerWatchdogTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $DockerWatchdogTaskName -Action $dockerWatchdogAction -Trigger $dockerWatchdogTriggers `
                -Settings $dockerWatchdogSettings -Principal $dockerWatchdogPrincipal
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($DockerWatchdogTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $DockerWatchdogTaskName -Action $dockerWatchdogAction -Trigger $dockerWatchdogTriggers `
                -Settings $dockerWatchdogSettings -Principal $dockerWatchdogPrincipal
        }
    }

    # --- Archive legacy scripts this module supersedes ----------------------
    $archiveTimestamp = Get-Date -Format 'yyyyMMdd'

    # When register-tasks.ps1 is invoked as `pwsh -File ... -LegacyScriptsToArchive
    # "C:\a.ps1","C:\b.ps1"` from another shell (notably Windows PowerShell 5.1), native-command
    # argument handling flattens the two array elements into ONE literal string
    # "C:\a.ps1,C:\b.ps1" before pwsh's -File mode ever sees it - -File never re-parses commas
    # into an array the way a real PowerShell-to-PowerShell call would. Test-Path then fails on
    # the joined string and archiving silently does nothing. Work around it by expanding any
    # element that is a comma-joined list of rooted Windows paths back into its parts; an element
    # without a comma, or whose comma-split fragments don't all look like rooted paths, is left
    # alone (a legitimate single path may itself contain a comma).
    $expandedLegacyScriptsToArchive = foreach ($rawLegacyPath in $LegacyScriptsToArchive) {
        if ($rawLegacyPath -notlike '*,*') {
            $rawLegacyPath
            continue
        }

        $legacyPathFragments = $rawLegacyPath -split ','
        $anyFragmentNotRooted = $legacyPathFragments | Where-Object {
            $_ -notmatch '^[A-Za-z]:[\\/]' -and $_ -notmatch '^\\\\'
        }

        if ($anyFragmentNotRooted) {
            $rawLegacyPath
        }
        else {
            $legacyPathFragments
        }
    }

    foreach ($legacyPath in $expandedLegacyScriptsToArchive) {
        if (-not (Test-Path -LiteralPath $legacyPath)) {
            $legacyLeafForMissingCheck = Split-Path -Path $legacyPath -Leaf
            $legacyParentForMissingCheck = Split-Path -Path $legacyPath -Parent
            $supersededSiblingPattern = "$legacyLeafForMissingCheck.superseded-*"
            $supersededSiblingPath = if ($legacyParentForMissingCheck) {
                Join-Path $legacyParentForMissingCheck $supersededSiblingPattern
            }
            else {
                $supersededSiblingPattern
            }

            # An idempotent re-run naturally hits this: a previous run already renamed the
            # legacy script out of the way, so it no longer exists at its original path. Only
            # warn when there's no evidence that already happened.
            if (-not (Test-Path -Path $supersededSiblingPath)) {
                Write-Warning "Legacy script not found, nothing archived: $legacyPath"
            }
            continue
        }

        $archiveName = (Split-Path -Path $legacyPath -Leaf) + ".superseded-$archiveTimestamp"
        $legacyParent = Split-Path -Path $legacyPath -Parent
        $archivePath = if ($legacyParent) { Join-Path $legacyParent $archiveName } else { $archiveName }

        if (Test-Path -LiteralPath $archivePath) {
            Write-Warning "Archive target already exists, skipping: $archivePath"
            continue
        }

        if ($PSCmdlet.ShouldProcess($legacyPath, "Rename to $archiveName")) {
            Rename-Item -LiteralPath $legacyPath -NewName $archiveName
        }
    }

    # --- Task Scheduler operational log (History tab) ----------------------
    # Disabled on a fresh Windows install. Without it a scheduled task leaves only its last
    # result code behind - no start/finish times, no per-run exit code, no record of a run that
    # was terminated at its execution time limit (see AGENTS.md's interactive-prompt section).
    # This is best-effort and never fatal: every task above has already been registered or
    # updated by the time this runs, so a failure here only warns.
    if ($SkipTaskHistory) {
        $taskHistoryResult = 'Skipped (-SkipTaskHistory)'
    }
    else {
        try {
            $taskHistoryResult = Enable-TaskSchedulerHistory -WhatIf:$WhatIfPreference -Confirm:$false
        }
        catch {
            Write-Warning "Failed to enable Task Scheduler history (Microsoft-Windows-TaskScheduler/Operational): $_"
            $taskHistoryResult = 'Failed'
        }
    }

    # --- Summary -------------------------------------------------------------
    Write-Information -MessageData "Backup task '$BackupTaskName' (background/S4U, live restic backup): $backupArguments (daily at $BackupTime, retrying every $BackupRetryIntervalMinutes min for up to 1 day; allowed on battery)" -InformationAction Continue
    Write-Information -MessageData "Keeper task '$KeeperTaskName' (background/S4U): $keeperArguments (repeats every $KeeperIntervalMinutes min, indefinitely)" -InformationAction Continue
    Write-Information -MessageData "Launcher task '$LauncherTaskName' (interactive, on-demand): $WtPath $launcherArguments" -InformationAction Continue
    Write-Information -MessageData "Codex remote control launcher task '$CodexLauncherTaskName' (interactive, on-demand): $WtPath $codexLauncherArguments" -InformationAction Continue
    Write-Information -MessageData "ccstatusline task '$CcstatuslineTaskName' (background/S4U): $ccstatuslineArguments (repeats every $CcstatuslineIntervalMinutes min, indefinitely)" -InformationAction Continue
    Write-Information -MessageData "Codex Cloud task '$CodexCloudEnvironmentSyncTaskName' (background/S4U): $codexCloudSyncArguments (daily at 00:00 and 12:00)" -InformationAction Continue
    Write-Information -MessageData "Usage census task '$UsageCensusTaskName' (background/S4U): $WslExePath $usageCensusArguments (daily at $UsageCensusTime)" -InformationAction Continue
    Write-Information -MessageData "Session miner task '$SessionMinerTaskName' (background/S4U): $WslExePath $sessionMinerArguments (daily at $SessionMinerTime)" -InformationAction Continue
    Write-Information -MessageData "Memory curation task '$MemoryCurationTaskName' (background/S4U): $WslExePath $memoryCurationArguments (weekly on Monday at $MemoryCurationTime)" -InformationAction Continue
    Write-Information -MessageData "Waiting feed task '$WaitingFeedTaskName' (background/S4U): $WslExePath $waitingFeedArguments (repeats every 1 min, indefinitely)" -InformationAction Continue
    Write-Information -MessageData "Task health task '$TaskHealthTaskName' (background/S4U): $WslExePath $taskHealthArguments (daily at $TaskHealthTime)" -InformationAction Continue
    Write-Information -MessageData "Docker watchdog task '$DockerWatchdogTaskName' (interactive, headless): $ConhostPath $dockerWatchdogArguments (at logon after $DockerWatchdogLogonDelayMinutes min, then every $DockerWatchdogIntervalMinutes min, indefinitely)" -InformationAction Continue
    Write-Information -MessageData "Task Scheduler history (Microsoft-Windows-TaskScheduler/Operational): $taskHistoryResult" -InformationAction Continue
}
