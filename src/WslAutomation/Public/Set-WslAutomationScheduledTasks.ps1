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
        supersedes them.

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
        $backupSettings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
        $backupPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

        if ($PSCmdlet.ShouldProcess($BackupTaskName, 'Register scheduled task')) {
            Register-WslScheduledTask -TaskName $BackupTaskName -Action $backupAction -Trigger $backupTrigger `
                -Settings $backupSettings -Principal $backupPrincipal
        }
    }

    # --- Keeper task: action + indefinitely-repeating trigger --------------
    $keeperScriptPath = Join-Path $ScriptsDir 'ensure-claude-session.ps1'
    $keeperArguments = "-NoProfile -File `"$keeperScriptPath`" -DistroName $DistroName"
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
    foreach ($legacyPath in $LegacyScriptsToArchive) {
        if (-not (Test-Path -LiteralPath $legacyPath)) {
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
