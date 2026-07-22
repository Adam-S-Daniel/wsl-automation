#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Update-CcstatuslineConfig, intended for scheduled-task use.

.DESCRIPTION
    Thin wrapper that imports the WslAutomation module and calls
    Update-CcstatuslineConfig with the given parameters. Exits 0 for every
    outcome (including a source that isn't currently available); exits 1 on
    any error. Intended to run on a short recurring schedule (for example
    every 5 minutes) from a scheduled task.

.PARAMETER DistroName
    Name of the WSL distro to read the config from when -SourcePath is not
    given. Defaults to 'Ubuntu'.

.PARAMETER WslUser
    Linux username whose home directory holds the config. Passed through to
    Update-CcstatuslineConfig only when supplied.

.PARAMETER SourcePath
    Full UNC path to the WSL-side settings.json. Passed through to
    Update-CcstatuslineConfig only when supplied.

.PARAMETER DestinationPath
    Windows-side path the config is copied to. Passed through to
    Update-CcstatuslineConfig only when supplied.

.PARAMETER LogFile
    Path to this sync's log file. Passed through to Update-CcstatuslineConfig
    only when supplied.

.EXAMPLE
    ./sync-ccstatusline-config.ps1

    Syncs the ccstatusline settings.json from the 'Ubuntu' distro to the
    default Windows destination.
#>
[CmdletBinding()]
param(
    [string]$DistroName = 'Ubuntu',

    [string]$WslUser,

    [string]$SourcePath,

    [string]$DestinationPath,

    [string]$LogFile
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
    $syncParams = @{
        DistroName = $DistroName
    }
    if ($PSBoundParameters.ContainsKey('WslUser')) { $syncParams['WslUser'] = $WslUser }
    if ($PSBoundParameters.ContainsKey('SourcePath')) { $syncParams['SourcePath'] = $SourcePath }
    if ($PSBoundParameters.ContainsKey('DestinationPath')) { $syncParams['DestinationPath'] = $DestinationPath }
    if ($PSBoundParameters.ContainsKey('LogFile')) { $syncParams['LogFile'] = $LogFile }

    $result = Update-CcstatuslineConfig @syncParams
    Write-Information -MessageData "ccstatusline sync: $($result.Status)" -InformationAction Continue

    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
