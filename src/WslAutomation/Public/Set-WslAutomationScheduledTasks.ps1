#requires -Version 7.6

function Set-WslAutomationScheduledTasks {
    <#
    .SYNOPSIS
        Registers or updates the scheduled tasks that drive WSL backups, the Claude Code
        session keeper, and the ccstatusline config sync.

    .DESCRIPTION
        Creates four Windows Scheduled Tasks, or updates them in place if they already exist:
        a daily backup task that runs scripts/wsl-ubuntu-backup.ps1; a session-keeper task that
        runs scripts/ensure-claude-session.ps1 on a short repeating interval; an on-demand
        launcher task the keeper triggers to actually open a Claude Code session in Windows
        Terminal; and a ccstatusline config sync task that runs scripts/sync-ccstatusline-config.ps1
        on its own short repeating interval.

        The keeper and ccstatusline tasks run as background S4U tasks (session 0), so their
        frequent checks never flash a console window on the desktop; the launcher is interactive
        (it must show a terminal) and on-demand (no trigger); the backup is interactive. Both S4U
        tasks require an MSI PowerShell 7 and the "Log on as a batch job" right - see -PwshPath
        and scripts/grant-keeper-batch-logon.ps1.

        When the backup task already exists, its Action and Triggers are replaced but its
        existing Settings and Principal objects are kept as-is. The keeper, launcher, and
        ccstatusline tasks' Settings and Principal are always (re)built fresh from this function's
        parameters, whether the task already exists or not, so their battery/idle behavior stays
        in sync. Re-running this function is idempotent for all four tasks.

        Also archives any legacy scripts passed via -LegacyScriptsToArchive by renaming them
        out of the way, so a stale scheduled task still pointing at an old script path fails
        loudly instead of silently continuing to run superseded automation.

        Windows-only: throws immediately if $IsWindows is false.

    .PARAMETER ScriptsDir
        Directory containing wsl-ubuntu-backup.ps1, ensure-claude-session.ps1, and
        sync-ccstatusline-config.ps1.

    .PARAMETER BackupDir
        Directory the backup task writes exported WSL archives to.

    .PARAMETER DistroName
        Name of the WSL distro to back up and to keep a Claude Code session alive in. Defaults
        to 'Ubuntu'.

    .PARAMETER Format
        Backup format passed through to wsl-ubuntu-backup.ps1: 'tar' or 'vhdx'. Defaults to
        'tar'.

    .PARAMETER WakeBackupToRun
        When set, the backup task is registered with -WakeToRun so Windows wakes the machine
        from sleep to run the backup. Off by default: on Modern Standby (S0 low-power idle)
        laptops - which never truly sleep and instead sit in connected standby - a scheduled
        wake pulls the SoC back out of its low-power phase and has been observed to hang the
        machine in a half-woken state that only a hard power-off recovers. With this off the
        backup instead relies on -StartWhenAvailable, running at the next opportunity the
        machine is already awake if its scheduled time was missed. Only enable this on hardware
        where scheduled wake is reliable (for example an S3-capable desktop). This only affects
        a freshly registered backup task; an existing task's Settings are preserved as-is.

    .PARAMETER BackupTaskName
        Name of the scheduled task that runs the backup. Defaults to 'WSL Ubuntu Daily Backup'.

    .PARAMETER KeeperTaskName
        Name of the scheduled task that runs the session keeper. Defaults to 'Claude Code
        Session Keeper'.

    .PARAMETER LauncherTaskName
        Name of the interactive, on-demand task the keeper triggers to open a Claude Code
        session. Defaults to 'Claude Code Session Launcher'.

    .PARAMETER BackupTime
        Time of day (HH:mm) the backup task's daily trigger fires. Defaults to '02:00'.

    .PARAMETER KeeperIntervalMinutes
        How often, in minutes, the keeper task repeats indefinitely. Defaults to 5.

    .PARAMETER CcstatuslineTaskName
        Name of the scheduled task that syncs the ccstatusline config from WSL. Defaults to
        'ccstatusline Config Sync'.

    .PARAMETER CcstatuslineIntervalMinutes
        How often, in minutes, the ccstatusline config sync task repeats indefinitely. Defaults
        to 5.

    .PARAMETER PwshPath
        Path to pwsh.exe used as the action executable for the pwsh-based tasks. Defaults to an
        MSI install of PowerShell 7 (C:\Program Files\PowerShell\7) when present - required for
        the S4U keeper and ccstatusline tasks, which run in session 0 where a Store-packaged pwsh
        cannot launch - then the per-user WindowsApps alias, then the pwsh.exe found on PATH. A
        warning is emitted if a Store-packaged path would be used for the keeper.

    .PARAMETER WtPath
        Path to wt.exe (Windows Terminal) used as the launcher task's action. Defaults to the
        stable per-user WindowsApps execution alias when present, else wt.exe on PATH.

    .PARAMETER LegacyScriptsToArchive
        Paths to legacy scripts that should be renamed out of the way because this module
        supersedes them. Workaround included for invocation via `pwsh -File ... -LegacyScriptsToArchive
        "C:\a.ps1","C:\b.ps1"` from another shell (notably Windows PowerShell 5.1): -File mode
        never re-parses commas, so the two paths can arrive flattened into one literal string
        "C:\a.ps1,C:\b.ps1". Any element that is a comma-joined list of rooted Windows paths
        (each looking like `C:\...` or `\\server\share\...`) is automatically expanded back into
        separate paths before archiving.

    .EXAMPLE
        Set-WslAutomationScheduledTasks -ScriptsDir 'C:\Users\<you>\repos\wsl-automation\scripts' -BackupDir 'C:\Backups\WSL'

        Registers (or updates) all four scheduled tasks using default names, backup time, and
        keeper/ccstatusline intervals.

    .EXAMPLE
        Set-WslAutomationScheduledTasks -ScriptsDir $PSScriptRoot -BackupDir 'C:\Backups\WSL' -WhatIf

        Shows what would change without actually registering, updating, or renaming anything.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseSingularNouns',
        '',
        Justification = 'This function manages four related scheduled tasks (backup, session keeper, session launcher, and ccstatusline config sync) by design; Set-WslAutomationScheduledTasks is the name specified by the project spec.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptsDir,

        [Parameter(Mandatory)]
        [string]$BackupDir,

        [string]$DistroName = 'Ubuntu',

        [ValidateSet('tar', 'vhdx')]
        [string]$Format = 'tar',

        [switch]$WakeBackupToRun,

        [string]$BackupTaskName = 'WSL Ubuntu Daily Backup',

        [string]$KeeperTaskName = 'Claude Code Session Keeper',

        [string]$LauncherTaskName = 'Claude Code Session Launcher',

        [string]$BackupTime = '02:00',

        [int]$KeeperIntervalMinutes = 5,

        [string]$CcstatuslineTaskName = 'ccstatusline Config Sync',

        [int]$CcstatuslineIntervalMinutes = 5,

        [string]$PwshPath = (Get-WslAutomationDefaultPwshPath),

        [string]$WtPath = (Get-WslAutomationDefaultWtPath),

        [string[]]$LegacyScriptsToArchive = @()
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
    $ScriptsDir = $ScriptsDir.TrimEnd('\')
    $PwshPath = $PwshPath.TrimEnd('\')

    # --- Backup task: action + single daily trigger -----------------------
    $backupScriptPath = Join-Path $ScriptsDir 'wsl-ubuntu-backup.ps1'
    $backupArguments = "-NoProfile -File `"$backupScriptPath`" -BackupDir `"$BackupDir`" -DistroName $DistroName -Format $Format -NoPause"
    $backupAction = New-ScheduledTaskAction -Execute $PwshPath -Argument $backupArguments
    $backupTrigger = New-ScheduledTaskTrigger -Daily -At $BackupTime

    $existingBackupTask = Get-ScheduledTask -TaskName $BackupTaskName -ErrorAction SilentlyContinue
    if ($existingBackupTask) {
        # Keep the existing Settings/Principal; only Action and Triggers are replaced (this
        # intentionally drops any logon/other trigger the task may have picked up over time).
        if ($PSCmdlet.ShouldProcess($BackupTaskName, 'Update scheduled task')) {
            Set-WslScheduledTask -TaskName $BackupTaskName -Action $backupAction -Trigger $backupTrigger `
                -Settings $existingBackupTask.Settings -Principal $existingBackupTask.Principal
        }
    }
    else {
        # -WakeToRun is opt-in (see -WakeBackupToRun): waking a Modern Standby laptop for the
        # backup can hang it in a half-woken state. -StartWhenAvailable still catches up a missed
        # run the next time the machine is awake, which is the intended behavior when not waking.
        $backupSettingsParams = @{
            StartWhenAvailable = $true
            ExecutionTimeLimit = New-TimeSpan -Hours 4
            MultipleInstances  = 'IgnoreNew'
        }
        if ($WakeBackupToRun) {
            $backupSettingsParams['WakeToRun'] = $true
        }
        $backupSettings = New-ScheduledTaskSettingsSet @backupSettingsParams
        $backupPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

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
        -RepetitionInterval (New-TimeSpan -Minutes $KeeperIntervalMinutes)

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
    # The background keeper triggers this task (by name) when no session is running. It is the one
    # task that runs in the user's interactive session, so its Windows Terminal window is actually
    # visible. Its action is wt.exe DIRECTLY (not pwsh) so even opening a session never flashes a
    # pwsh console. It has no trigger of its own - it only ever runs on demand (Trigger = $null;
    # Register-/Set-WslScheduledTask omit -Trigger entirely for it).
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
        -RepetitionInterval (New-TimeSpan -Minutes $CcstatuslineIntervalMinutes)

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

    # --- Summary -------------------------------------------------------------
    Write-Information -MessageData "Backup task '$BackupTaskName': $backupArguments (daily at $BackupTime)" -InformationAction Continue
    Write-Information -MessageData "Keeper task '$KeeperTaskName' (background/S4U): $keeperArguments (repeats every $KeeperIntervalMinutes min, indefinitely)" -InformationAction Continue
    Write-Information -MessageData "Launcher task '$LauncherTaskName' (interactive, on-demand): $WtPath $launcherArguments" -InformationAction Continue
    Write-Information -MessageData "ccstatusline task '$CcstatuslineTaskName' (background/S4U): $ccstatuslineArguments (repeats every $CcstatuslineIntervalMinutes min, indefinitely)" -InformationAction Continue
}
