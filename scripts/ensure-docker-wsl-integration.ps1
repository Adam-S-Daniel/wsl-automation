#requires -Version 7.6
<#
.SYNOPSIS
    Scheduled-task wrapper for the Docker Desktop WSL integration watchdog.
.DESCRIPTION
    Updates this repository best-effort, then checks that Docker Desktop's WSL integration with
    the (already running) distro works, restarts Docker Desktop when it does not, and alerts the
    owner when the integration list no longer includes the distro or a restart did not help. It
    has no interactive prompts. Exits 0 for Healthy, Recovered, DockerNotRunning,
    DistroNotRunning, DeferredRecentWake and SettingsUnreadable, and 1 for Unrecovered,
    IntegrationNotConfigured or an error.
#>
[CmdletBinding()]
param(
    [string]$DistroName = 'Ubuntu',

    [switch]$DryRun,

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
    if ($DryRun) { $parameters['DryRun'] = $true }
    if ($PSBoundParameters.ContainsKey('LogFile')) { $parameters['LogFile'] = $LogFile }
    $result = Invoke-DockerWslIntegrationWatchdog @parameters
    Write-Information -MessageData "Docker WSL integration watchdog: $($result.Status)" -InformationAction Continue
    if ($result.Status -in @('Healthy', 'Recovered', 'DockerNotRunning', 'DistroNotRunning', 'DeferredRecentWake', 'SettingsUnreadable')) {
        exit 0
    }
    exit 1
}
catch {
    Write-Error -Message 'Docker WSL integration watchdog failed.'
    exit 1
}
