#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Set-AgentWorkspaceTrust.

.DESCRIPTION
    Imports the WslAutomation module and pre-trusts git working trees under the owner roots
    for Claude Code and Codex. Prints one object per changed entry, or "Nothing to change.".
    Never prompts. Exits 0 on success, 1 on any error.

.PARAMETER Path
    Specific directories to trust (must be under an owner root, others are skipped). When
    omitted, the owner roots and their direct git children are trusted.

.PARAMETER OwnerRoot
    Owner roots. Defaults to the folders in WSL_AUTOMATION_AGENT_OWNER_ROOTS (separated by ';' on
    Windows, ':' elsewhere). On Windows that is the user environment variable. On Linux, WSL and
    macOS it is the environment variable if set, else the key in
    ~/.config/wsl-automation/settings.env (WSL_AUTOMATION_SETTINGS overrides the path); not a
    shell profile, which a non-interactive or long-running process never reads. There is no
    built-in value; with none, the script fails with an error that names -OwnerRoot, the
    variable and the file.

.EXAMPLE
    ./trust-agent-workspaces.ps1

    Trusts every git working tree under the default owner roots.
#>
[CmdletBinding()]
param(
    [string[]]$Path,

    [string[]]$OwnerRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

try {
    $trustParams = @{}
    if ($PSBoundParameters.ContainsKey('Path')) { $trustParams['Path'] = $Path }
    if ($PSBoundParameters.ContainsKey('OwnerRoot')) { $trustParams['OwnerRoot'] = $OwnerRoot }

    $changed = @(Set-AgentWorkspaceTrust @trustParams)
    if ($changed.Count -eq 0) {
        Write-Output 'Nothing to change.'
    }
    else {
        $changed
    }
    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
