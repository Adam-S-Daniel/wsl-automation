#requires -Version 7.6

function Set-WslAutomationScheduledTasks {
    <#
    .SYNOPSIS
        Registers or updates the scheduled tasks that drive WSL backups and the Claude Code
        session keeper.

    .DESCRIPTION
        Creates two Windows Scheduled Tasks, or updates them in place if they already exist:
        a daily backup task that runs scripts/wsl-ubuntu-backup.ps1, and a session-keeper task
        that runs scripts/ensure-claude-session.ps1 on a short repeating interval.

        When the backup task already exists, its Action and Triggers are replaced but its
        existing Settings and Principal objects are kept as-is. The keeper task's Settings and
        Principal are always (re)built fresh from this function's parameters, whether the task
        already exists or not, so its battery/idle behavior stays in sync. Re-running this
        function is idempotent for both tasks.

        Also archives any legacy scripts passed via -LegacyScriptsToArchive by renaming them
        out of the way, so a stale scheduled task still pointing at an old script path fails
        loudly instead of silently continuing to run superseded automation.

        Windows-only: throws immediately if $IsWindows is false.

    .PARAMETER ScriptsDir
        Directory containing wsl-ubuntu-backup.ps1 and ensure-claude-session.ps1.

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

    .PARAMETER BackupTime
        Time of day (HH:mm) the backup task's daily trigger fires. Defaults to '02:00'.

    .PARAMETER KeeperIntervalMinutes
        How often, in minutes, the keeper task repeats indefinitely. Defaults to 5.

    .PARAMETER PwshPath
        Path to pwsh.exe used as the action executable for both tasks. Defaults to the stable
        per-user WindowsApps execution alias when present (survives PowerShell package
        updates), else the pwsh.exe found on PATH.

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

        Registers (or updates) both scheduled tasks using default names, backup time, and
        keeper interval.

    .EXAMPLE
        Set-WslAutomationScheduledTasks -ScriptsDir $PSScriptRoot -BackupDir 'C:\Backups\WSL' -WhatIf

        Shows what would change without actually registering, updating, or renaming anything.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseSingularNouns',
        '',
        Justification = 'This function manages two related scheduled tasks (backup and session keeper) by design; Set-WslAutomationScheduledTasks is the name specified by the project spec.')]
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

        [string]$BackupTime = '02:00',

        [int]$KeeperIntervalMinutes = 5,

        [string]$PwshPath = (Get-WslAutomationDefaultPwshPath),

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
    # -WindowStyle Hidden keeps the routine every-few-minutes "is a session already
    # running?" check from flashing a pwsh console window on the desktop. It only hides
    # pwsh's own window (and any wsl.exe it runs shares that hidden console); when the
    # keeper does need to start a session it launches wt.exe, a separate GUI process that
    # still opens its window normally.
    $keeperArguments = "-NoProfile -WindowStyle Hidden -File `"$keeperScriptPath`" -DistroName $DistroName"
    $keeperAction = New-ScheduledTaskAction -Execute $PwshPath -Argument $keeperArguments

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
    $keeperPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

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
    Write-Information -MessageData "Keeper task '$KeeperTaskName': $keeperArguments (repeats every $KeeperIntervalMinutes min, indefinitely)" -InformationAction Continue
}
