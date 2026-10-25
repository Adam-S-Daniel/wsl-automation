#requires -Version 7.6
<#
.SYNOPSIS
    Scheduled-task wrapper for Codex Cloud environment synchronization.
.DESCRIPTION
    Updates this repository best-effort, then reconciles Codex Cloud environments when the
    configured WSL distro is already running. It has no interactive prompts and exits 0 on a
    normal completion or an intentionally skipped stopped distro, and 1 on a synchronization error.
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
    $result = Invoke-CodexCloudEnvironmentSync @parameters
    Write-Information -MessageData "Codex Cloud environment sync: $($result.Status)" -InformationAction Continue
    exit 0
}
catch {
    Write-Error -Message 'Codex Cloud environment synchronization failed.'
    exit 1
}
