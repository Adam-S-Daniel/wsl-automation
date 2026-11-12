#requires -Version 7.6
<#
.SYNOPSIS
    Scheduled-task wrapper for Invoke-ClaudeSettingsSync.

.DESCRIPTION
    Updates this repository best-effort, then syncs Claude Code settings.json between Windows
    and WSL when the configured distro is already running. It has no interactive prompts and
    exits 0 on a normal completion or an intentionally skipped stopped distro, and 1 on an
    error. Without -Live it only plans: it runs the sync script with -DryRun and writes no
    settings files, backups or snapshot.

.PARAMETER DistroName
    Name of the WSL distro to sync with. Defaults to 'Ubuntu'.

.PARAMETER Live
    Let the sync write. Without it, the run is a dry run.

.PARAMETER SyncScriptPath
    Path to Sync-ClaudeSettings.ps1. Passed through only when supplied.

.PARAMETER LogFile
    Path to this sync's log file. Passed through only when supplied.
#>
[CmdletBinding()]
param(
    [string]$DistroName = 'Ubuntu',

    [switch]$Live,

    [string]$SyncScriptPath,

    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Update before loading task code; a changed checkout runs this entry again in a fresh host.
. (Join-Path $PSScriptRoot 'update-task-checkout.ps1')
$taskBootstrap = Initialize-WslAutomationTask -ScriptPath $PSCommandPath -Parameters $PSBoundParameters
if ($taskBootstrap.Relaunched) { exit $taskBootstrap.ExitCode }

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

try {
    $parameters = @{ DistroName = $DistroName }
    if ($Live) { $parameters['Live'] = $true }
    if ($PSBoundParameters.ContainsKey('SyncScriptPath')) { $parameters['SyncScriptPath'] = $SyncScriptPath }
    if ($PSBoundParameters.ContainsKey('LogFile')) { $parameters['LogFile'] = $LogFile }
    $result = Invoke-ClaudeSettingsSync @parameters
    Write-Information -MessageData "Claude settings sync: $($result.Status)" -InformationAction Continue
    exit 0
}
catch {
    Write-Error -Message 'Claude settings synchronization failed.'
    exit 1
}
