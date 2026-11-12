#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Write-WslMemorySample, intended for scheduled-task use.

.DESCRIPTION
    Thin wrapper that imports the WslAutomation module and calls Write-WslMemorySample with
    the given parameters, appending one row of Windows and WSL memory statistics to
    <LogDir>\samples.csv. Exits 0 on success; exits 1 on any error. Intended to run on a
    short recurring schedule (for example every 5 minutes) from a scheduled task. It never
    starts the WSL VM: the WSL columns stay empty while it is not running.

.PARAMETER LogDir
    Directory holding samples.csv. Created when it does not exist.

.PARAMETER DistroName
    Name of the WSL distro to read memory statistics from. Defaults to 'Ubuntu'.

.EXAMPLE
    ./log-wsl-memory.ps1 -LogDir "$env:LOCALAPPDATA\WslMemoryLog"

    Appends one memory sample for the 'Ubuntu' distro.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LogDir,

    [string]$DistroName = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Update before loading task code; a changed checkout runs this entry again in a fresh host.
. (Join-Path $PSScriptRoot 'update-task-checkout.ps1')
$taskBootstrap = Initialize-WslAutomationTask -ScriptPath $PSCommandPath -Parameters $PSBoundParameters
if ($taskBootstrap.Relaunched) { exit $taskBootstrap.ExitCode }

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

try {
    Write-WslMemorySample -LogDir $LogDir -DistroName $DistroName

    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
