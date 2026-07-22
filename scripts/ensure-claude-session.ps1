#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Invoke-ClaudeSessionKeeper, intended for scheduled-task use.

.DESCRIPTION
    Thin wrapper that imports the WslAutomation module and calls
    Invoke-ClaudeSessionKeeper with the given parameters. Exits 0 whether a
    session was already present, one was launched, or -DryRun was used;
    exits 1 on any error. Intended to run frequently (for example every 5
    minutes) from a scheduled task.

.PARAMETER DistroName
    Name of the WSL distro to check/launch into. Defaults to 'Ubuntu'.

.PARAMETER MaxWaitMinutes
    Maximum time to wait for an in-progress backup lock to clear before
    proceeding anyway. Passed through to Invoke-ClaudeSessionKeeper only when
    supplied.

.PARAMETER PollSeconds
    How long to sleep between backup-lock checks while waiting. Passed
    through to Invoke-ClaudeSessionKeeper only when supplied.

.PARAMETER LockPath
    Path to the backup lock file. Passed through to Invoke-ClaudeSessionKeeper
    only when supplied.

.PARAMETER LockStaleMinutes
    Age, in minutes, after which a present lock is treated as stale. Passed
    through to Invoke-ClaudeSessionKeeper only when supplied.

.PARAMETER LogFile
    Path to the keeper's log file. Passed through to
    Invoke-ClaudeSessionKeeper only when supplied.

.PARAMETER DryRun
    Only log what would happen; never actually launch a Claude Code session.

.EXAMPLE
    ./ensure-claude-session.ps1

    Waits out any backup, then launches a Claude Code session inside
    'Ubuntu' if one isn't already running.
#>
[CmdletBinding()]
param(
    [string]$DistroName = 'Ubuntu',

    [int]$MaxWaitMinutes,

    [int]$PollSeconds,

    [string]$LockPath,

    [int]$LockStaleMinutes,

    [string]$LogFile,

    [switch]$DryRun
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
    $keeperParams = @{
        DistroName = $DistroName
    }
    if ($PSBoundParameters.ContainsKey('MaxWaitMinutes')) { $keeperParams['MaxWaitMinutes'] = $MaxWaitMinutes }
    if ($PSBoundParameters.ContainsKey('PollSeconds')) { $keeperParams['PollSeconds'] = $PollSeconds }
    if ($PSBoundParameters.ContainsKey('LockPath')) { $keeperParams['LockPath'] = $LockPath }
    if ($PSBoundParameters.ContainsKey('LockStaleMinutes')) { $keeperParams['LockStaleMinutes'] = $LockStaleMinutes }
    if ($PSBoundParameters.ContainsKey('LogFile')) { $keeperParams['LogFile'] = $LogFile }
    if ($DryRun) { $keeperParams['DryRun'] = $true }

    $result = Invoke-ClaudeSessionKeeper @keeperParams
    Write-Information -MessageData "Keeper result: $($result.Status) (waited $($result.WaitedSeconds)s)" -InformationAction Continue

    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
