#requires -Version 7.6
<#
.SYNOPSIS
    Shared bootstrap for existing scheduled-task entry points.
.DESCRIPTION
    Dot-source this file and call Initialize-WslAutomationTask before importing task code.
    -UpdateOnly is the Windows-side bootstrap used by the WSL census entry point.
#>
[CmdletBinding()]
param([switch]$UpdateOnly)

function Invoke-WslAutomationTaskProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    # Use this host's executable, not a WindowsApps alias or a different pwsh on PATH.
    & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) @Arguments
    $script:taskProcessExitCode = $LASTEXITCODE
}

function Initialize-WslAutomationTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters
    )

    $result = [pscustomobject]@{ Relaunched = $false; ExitCode = 0 }
    if ($env:WSL_AUTOMATION_TASK_REEXEC -eq $ScriptPath) { return $result }
    try {
        $repoPath = Split-Path (Split-Path $ScriptPath -Parent) -Parent
        Import-Module (Join-Path $repoPath 'src' 'WslAutomation') -Force
        $update = Update-WslAutomationRepo -RepoPath $repoPath -Confirm:$false
        if (-not $update.Changed) { return $result }
    }
    catch {
        Write-Warning 'WARNING: checkout bootstrap failed; continuing with current code'
        return $result
    }

    # Preserve all bound scalar and switch parameters without constructing shell code.
    $arguments = @('-NoProfile', '-File', $ScriptPath)
    foreach ($name in $Parameters.Keys) {
        $value = $Parameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            $arguments += "-${name}:$([bool]$value)"
        }
        else {
            $arguments += @("-$name", [string]$value)
        }
    }
    $previousGuard = $env:WSL_AUTOMATION_TASK_REEXEC
    try {
        $env:WSL_AUTOMATION_TASK_REEXEC = $ScriptPath
        $script:taskProcessExitCode = 0
        Invoke-WslAutomationTaskProcess -Arguments $arguments | Out-Host
        $result.Relaunched = $true
        $result.ExitCode = $script:taskProcessExitCode
    }
    finally {
        $env:WSL_AUTOMATION_TASK_REEXEC = $previousGuard
    }
    $result
}

if ($UpdateOnly) {
    # The caller re-execs bash from disk even when HEAD did not change.
    try {
        Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
        Update-WslAutomationRepo -RepoPath (Split-Path $PSScriptRoot -Parent) -Confirm:$false | Out-Null
    }
    catch {
        Write-Warning 'WARNING: checkout bootstrap failed; continuing with current code'
    }
    exit 0
}
