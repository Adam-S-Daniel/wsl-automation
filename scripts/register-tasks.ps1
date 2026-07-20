#requires -Version 7.6
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Wrapper script for Set-WslAutomationScheduledTasks; installs or updates the WSL backup
    and Claude Code session keeper scheduled tasks.

.DESCRIPTION
    Thin wrapper that imports the WslAutomation module and calls
    Set-WslAutomationScheduledTasks with the given parameters. Must be run from an elevated
    (Administrator) PowerShell session. Supports -WhatIf, which is passed straight through to
    Set-WslAutomationScheduledTasks so nothing is actually registered, updated, or renamed
    during a dry run.

.PARAMETER ScriptsDir
    Directory containing wsl-ubuntu-backup.ps1 and ensure-claude-session.ps1. Defaults to the
    directory this script lives in.

.PARAMETER BackupDir
    Directory the backup task writes exported WSL archives to.

.PARAMETER DistroName
    Name of the WSL distro to back up and to keep a Claude Code session alive in. Defaults to
    'Ubuntu'.

.PARAMETER Format
    Backup format passed through to wsl-ubuntu-backup.ps1: 'tar' or 'vhdx'. Defaults to 'tar'.

.PARAMETER WakeBackupToRun
    Register the backup task with -WakeToRun so Windows wakes the machine from sleep to run it.
    Off by default: on Modern Standby (S0 low-power idle) laptops a scheduled wake can hang the
    machine in a half-woken state, so the backup instead catches up via -StartWhenAvailable the
    next time the machine is awake. Enable only on hardware where scheduled wake is reliable
    (for example an S3-capable desktop).

.PARAMETER BackupTaskName
    Name of the scheduled task that runs the backup. Defaults to 'WSL Ubuntu Daily Backup'.

.PARAMETER KeeperTaskName
    Name of the scheduled task that runs the session keeper. Defaults to 'Claude Code Session
    Keeper'.

.PARAMETER BackupTime
    Time of day (HH:mm) the backup task's daily trigger fires. Defaults to '02:00'.

.PARAMETER KeeperIntervalMinutes
    How often, in minutes, the keeper task repeats indefinitely. Defaults to 5.

.PARAMETER PwshPath
    Path to pwsh.exe used as the action executable for both tasks. Defaults to the stable
    per-user WindowsApps execution alias when present (survives PowerShell package updates),
    else the pwsh.exe found on PATH.

.PARAMETER LegacyScriptsToArchive
    Paths to legacy scripts that should be renamed out of the way because this module
    supersedes them. Workaround included for invocation via `pwsh -File ... -LegacyScriptsToArchive
    "C:\a.ps1","C:\b.ps1"` from another shell (notably Windows PowerShell 5.1): -File mode
    never re-parses commas, so the two paths can arrive flattened into one literal string
    "C:\a.ps1,C:\b.ps1". Any element that is a comma-joined list of rooted Windows paths (each
    looking like `C:\...` or `\\server\share\...`) is automatically expanded back into separate
    paths before archiving.

.EXAMPLE
    ./register-tasks.ps1 -BackupDir 'C:\Backups\WSL'

    Registers (or updates) both scheduled tasks from an elevated prompt, using default names,
    backup time, and keeper interval.

.EXAMPLE
    ./register-tasks.ps1 -BackupDir 'C:\Backups\WSL' -WhatIf

    Shows what would change without actually registering, updating, or renaming anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ScriptsDir = $PSScriptRoot,

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

    # This script runs before Import-Module (the module isn't loaded until the body below), so
    # it cannot call the module's private Get-WslAutomationDefaultPwshPath helper and instead
    # inlines the same stable-alias-preferring logic. (Get-Command pwsh.exe).Source alone
    # resolves to a version-pinned "C:\Program Files\WindowsApps\Microsoft.PowerShell_<ver>_..."
    # path on Store installs, which is removed on the next PowerShell package update and breaks
    # both scheduled tasks until someone re-runs this script.
    [string]$PwshPath = $(
        $stableAliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
        if (Test-Path -LiteralPath $stableAliasPath) {
            $stableAliasPath
        }
        else {
            $resolvedPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            $versionPinnedRoot = Join-Path $env:ProgramFiles 'WindowsApps'
            if ($resolvedPath -and $resolvedPath.StartsWith($versionPinnedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning -Message ("Resolved pwsh.exe path '$resolvedPath' is a version-pinned Microsoft Store " +
                    'package path and will break on the next PowerShell update. Pass -PwshPath explicitly with a ' +
                    'stable path (for example the per-user WindowsApps alias, or an MSI install under ' +
                    'C:\Program Files\PowerShell\7).')
            }
            $resolvedPath
        }
    ),

    [string[]]$LegacyScriptsToArchive = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

try {
    Set-WslAutomationScheduledTasks -ScriptsDir $ScriptsDir -BackupDir $BackupDir -DistroName $DistroName `
        -Format $Format -WakeBackupToRun:$WakeBackupToRun -BackupTaskName $BackupTaskName `
        -KeeperTaskName $KeeperTaskName -BackupTime $BackupTime `
        -KeeperIntervalMinutes $KeeperIntervalMinutes -PwshPath $PwshPath `
        -LegacyScriptsToArchive $LegacyScriptsToArchive -WhatIf:$WhatIfPreference

    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
