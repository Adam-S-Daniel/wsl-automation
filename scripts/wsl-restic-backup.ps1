#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Invoke-WslResticBackup, intended for scheduled-task use.

.DESCRIPTION
    Thin wrapper that imports the WslAutomation module and calls
    Invoke-WslResticBackup with the given parameters. Exits 0 when the backup
    completed (fully or partially - a snapshot was saved either way), was
    skipped (already done today), or was deferred (recent wake) - a deferral is
    expected, retried behavior, not a failure. Exits 1 on any error. Pauses for
    a keypress on exit unless -NoPause is supplied, so a double-clicked run
    stays visible; scheduled-task invocations should pass -NoPause.

.PARAMETER BackupDir
    The OneDrive-synced backup directory. The restic repository is copied into
    its 'restic' subdirectory.

.PARAMETER RepoDir
    The restic repository on a local Windows drive, for example
    'D:\Backups\wsl-restic'.

.PARAMETER DistroName
    Name of the WSL distro to back up. Defaults to 'Ubuntu'.

.PARAMETER ScriptsDir
    Directory holding wsl-restic-backup.sh and wsl-restic-excludes.txt. Passed
    through to Invoke-WslResticBackup only when supplied.

.PARAMETER PasswordFile
    Path, inside the distro, of the restic password file. Passed through to
    Invoke-WslResticBackup only when supplied.

.PARAMETER LogFile
    Path to the log file this run appends to. Passed through to
    Invoke-WslResticBackup only when supplied.

.PARAMETER StatePath
    File holding the date of the last fully successful run. Passed through to
    Invoke-WslResticBackup only when supplied.

.PARAMETER MinMinutesSinceWake
    Minimum minutes that must have passed since this machine last booted or
    resumed from sleep before the backup runs. Passed through to
    Invoke-WslResticBackup only when supplied.

.PARAMETER WeeklyMaintenanceDay
    The day of the week the run also prunes and reads a sample of the
    repository data. Passed through to Invoke-WslResticBackup only when
    supplied.

.PARAMETER NoPause
    Skip the "Press Enter to close" prompt on exit. Use this for scheduled
    (unattended) runs.

.EXAMPLE
    ./wsl-restic-backup.ps1 -BackupDir 'C:\Users\<you>\OneDrive\Backups\WSL' -RepoDir 'D:\Backups\wsl-restic' -NoPause

    Runs an unattended backup with no closing prompt, as a scheduled task
    would.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessage(
    'PSAvoidUsingPlainTextForPassword',
    '',
    Justification = 'A path to the root-only password file inside the distro, not the password itself.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupDir,

    [Parameter(Mandatory)]
    [string]$RepoDir,

    [string]$DistroName = 'Ubuntu',

    [string]$ScriptsDir,

    [string]$PasswordFile,

    [string]$LogFile,

    [string]$StatePath,

    [int]$MinMinutesSinceWake,

    [System.DayOfWeek]$WeeklyMaintenanceDay,

    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Update before loading task code; a changed checkout runs this entry again in a fresh host.
. (Join-Path $PSScriptRoot 'update-task-checkout.ps1')
$taskBootstrap = Initialize-WslAutomationTask -ScriptPath $PSCommandPath -Parameters $PSBoundParameters
if ($taskBootstrap.Relaunched) { exit $taskBootstrap.ExitCode }

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

try {
    $backupParams = @{
        BackupDir  = $BackupDir
        RepoDir    = $RepoDir
        DistroName = $DistroName
    }
    if ($PSBoundParameters.ContainsKey('ScriptsDir')) { $backupParams['ScriptsDir'] = $ScriptsDir }
    if ($PSBoundParameters.ContainsKey('PasswordFile')) { $backupParams['PasswordFile'] = $PasswordFile }
    if ($PSBoundParameters.ContainsKey('LogFile')) { $backupParams['LogFile'] = $LogFile }
    if ($PSBoundParameters.ContainsKey('StatePath')) { $backupParams['StatePath'] = $StatePath }
    if ($PSBoundParameters.ContainsKey('MinMinutesSinceWake')) { $backupParams['MinMinutesSinceWake'] = $MinMinutesSinceWake }
    if ($PSBoundParameters.ContainsKey('WeeklyMaintenanceDay')) { $backupParams['WeeklyMaintenanceDay'] = $WeeklyMaintenanceDay }

    $result = Invoke-WslResticBackup @backupParams
    Write-Information -MessageData "Backup result: $($result.Status)" -InformationAction Continue

    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
finally {
    if (-not $NoPause) {
        Read-Host 'Press Enter to close'
    }
}
