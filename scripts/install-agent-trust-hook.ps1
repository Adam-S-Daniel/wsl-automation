#requires -Version 7.6
<#
.SYNOPSIS
    Wrapper script for Install-AgentTrustGitHook.

.DESCRIPTION
    Installs a git template directory whose post-checkout hook pre-trusts every new clone and
    worktree for Claude Code and Codex, and points the global git config init.templateDir at
    it. Never prompts. Exits 0 on success, 1 on any error.

.PARAMETER TemplateDir
    Template directory. Defaults to ~/.git-templates/agent-trust.

.PARAMETER Force
    Replace a different existing init.templateDir, or a post-checkout hook not written by this
    installer.

.EXAMPLE
    ./install-agent-trust-hook.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TemplateDir,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

try {
    $installParams = @{
        TrustScriptPath = Join-Path $PSScriptRoot 'trust-agent-workspaces.ps1'
        Force           = $Force
        WhatIf          = $WhatIfPreference
    }
    if ($PSBoundParameters.ContainsKey('TemplateDir')) { $installParams['TemplateDir'] = $TemplateDir }

    Install-AgentTrustGitHook @installParams
    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
