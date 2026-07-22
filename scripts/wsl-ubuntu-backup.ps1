#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Invoke-WslBackup, intended for scheduled-task use.

.DESCRIPTION
    Thin wrapper that imports the WslAutomation module and calls
    Invoke-WslBackup with the given parameters. Exits 0 when the backup
    completed or was skipped (already exists for today), exits 1 on any
    error. Pauses for a keypress on exit unless -NoPause is supplied, so a
    double-clicked run stays visible; scheduled-task invocations should pass
    -NoPause.

.PARAMETER BackupDir
    Directory the finished backup file is written to. Created if missing.

.PARAMETER DistroName
    Name of the WSL distro to export. Defaults to 'Ubuntu'.

.PARAMETER Format
    Export format: 'tar' or 'vhdx'. Defaults to 'tar'.

.PARAMETER StagingDir
    Local scratch directory the export is written to before being moved into
    BackupDir. Passed through to Invoke-WslBackup only when supplied.

.PARAMETER LogFile
    Path to the log file this run appends to. Passed through to
    Invoke-WslBackup only when supplied.

.PARAMETER RetentionCount
    Number of backups to keep per tag (daily/weekly). Passed through to
    Invoke-WslBackup only when supplied.

.PARAMETER NoPause
    Skip the "Press Enter to close" prompt on exit. Use this for scheduled
    (unattended) runs.

.EXAMPLE
    ./wsl-ubuntu-backup.ps1 -BackupDir 'C:\Backups\WSL' -NoPause

    Runs an unattended backup with no closing prompt, as a scheduled task
    would.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupDir,

    [string]$DistroName = 'Ubuntu',

    [ValidateSet('tar', 'vhdx')]
    [string]$Format = 'tar',

    [string]$StagingDir,

    [string]$LogFile,

    [int]$RetentionCount,

    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

# Best-effort: keep the repo current (12h-gated inside) so scheduled tasks run
# up-to-date code. A self-update failure must never fail the task itself.
try {
    Update-WslAutomationRepo -RepoPath (Split-Path -Path $PSScriptRoot -Parent) | Out-Null
}
catch {
    Write-Warning "repo self-update skipped: $_"
}

try {
    $backupParams = @{
        BackupDir  = $BackupDir
        DistroName = $DistroName
        Format     = $Format
    }
    if ($PSBoundParameters.ContainsKey('StagingDir')) { $backupParams['StagingDir'] = $StagingDir }
    if ($PSBoundParameters.ContainsKey('LogFile')) { $backupParams['LogFile'] = $LogFile }
    if ($PSBoundParameters.ContainsKey('RetentionCount')) { $backupParams['RetentionCount'] = $RetentionCount }

    $result = Invoke-WslBackup @backupParams
    Write-Information -MessageData "Backup result: $($result.Status) - $($result.FilePath)" -InformationAction Continue

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
