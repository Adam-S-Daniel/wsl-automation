function Install-AgentTrustGitHook {
    <#
    .SYNOPSIS
        Installs a git template so every new clone or worktree is pre-trusted for Claude Code and Codex.
    .DESCRIPTION
        Writes "<TemplateDir>/hooks/post-checkout" (LF line endings, no BOM). On a fresh clone or
        `git worktree add` git runs post-checkout with the null sha as the previous HEAD; the hook
        then runs scripts/trust-agent-workspaces.ps1 for that directory and never fails the
        checkout. Then sets the global git config init.templateDir to the template directory.

        If init.templateDir is already set to a different value this throws unless -Force is
        given. If core.hooksPath is set globally, git ignores template hooks and a warning
        names its value. Idempotent; never prompts. Git is invoked through Invoke-GitExe.

        Returns an object with TemplateDir, HookPath and Status ('Installed' or 'AlreadyInstalled').
    .PARAMETER TemplateDir
        Template directory. Defaults to ~/.git-templates/agent-trust.
    .PARAMETER PwshPath
        pwsh executable the hook runs. Defaults to Get-WslAutomationDefaultPwshPath.
    .PARAMETER TrustScriptPath
        Absolute path of scripts/trust-agent-workspaces.ps1. Defaults to this checkout's copy.
    .PARAMETER Force
        Overwrite a different existing init.templateDir, and a post-checkout hook this installer
        did not write.
    .EXAMPLE
        Install-AgentTrustGitHook

        Installs the template under ~/.git-templates/agent-trust and points git at it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$TemplateDir = (Join-Path $HOME '.git-templates/agent-trust'),

        [string]$PwshPath,

        [string]$TrustScriptPath = (Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'trust-agent-workspaces.ps1'),

        [switch]$Force
    )

    if (-not $PwshPath) {
        $PwshPath = Get-WslAutomationDefaultPwshPath
    }
    if (-not $PwshPath) {
        throw 'Could not resolve pwsh.exe; pass -PwshPath.'
    }

    $marker = '# Installed by wsl-automation scripts/install-agent-trust-hook.ps1.'
    $templateFull = [System.IO.Path]::GetFullPath($TemplateDir).Replace('\', '/')
    $pwshForHook = [System.IO.Path]::GetFullPath($PwshPath).Replace('\', '/')
    $scriptForHook = [System.IO.Path]::GetFullPath($TrustScriptPath).Replace('\', '/')

    $hookText = @(
        '#!/bin/sh',
        $marker,
        '# On a fresh clone or worktree (previous HEAD is the null sha) mark the new tree',
        '# trusted for Claude Code and Codex. Never fails the checkout.',
        '[ "$1" = "0000000000000000000000000000000000000000" ] || exit 0',
        ('"{0}" -NoProfile -NonInteractive -File "{1}" -Path "$(pwd -W 2>/dev/null || pwd)" >/dev/null 2>&1' -f $pwshForHook, $scriptForHook),
        'exit 0'
    ) -join "`n"
    $hookText += "`n"

    $hookPath = Join-Path $templateFull 'hooks' 'post-checkout'

    $existing = Invoke-GitExe -Arguments @('config', '--global', '--get', 'init.templateDir')
    $currentTemplate = if ($existing.ExitCode -eq 0 -and $existing.Output) { "$($existing.Output[0])".Trim() } else { $null }
    $templateDiffers = $currentTemplate -and
        -not ($currentTemplate.Replace('\', '/').TrimEnd('/') -ieq $templateFull.TrimEnd('/'))
    if ($templateDiffers -and -not $Force) {
        throw "init.templateDir is already set to '$currentTemplate'; refusing to overwrite it with '$templateFull'. Re-run with -Force to replace it."
    }

    $hooksPath = Invoke-GitExe -Arguments @('config', '--global', '--get', 'core.hooksPath')
    if ($hooksPath.ExitCode -eq 0 -and $hooksPath.Output) {
        Write-Warning "core.hooksPath is set to '$($hooksPath.Output[0])', so git ignores template hooks; the trust hook will not run until it is unset."
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $hookCurrent = $false
    if (Test-Path -LiteralPath $hookPath -PathType Leaf) {
        $currentText = $utf8.GetString([System.IO.File]::ReadAllBytes($hookPath))
        if ($currentText -ceq $hookText) {
            $hookCurrent = $true
        }
        elseif (-not $currentText.Contains($marker) -and -not $Force) {
            throw "'$hookPath' exists and was not written by this installer; re-run with -Force to overwrite it."
        }
    }

    $status = 'AlreadyInstalled'
    if (-not $hookCurrent -and $PSCmdlet.ShouldProcess($hookPath, 'Write post-checkout trust hook')) {
        New-Item -ItemType Directory -Path (Split-Path -Path $hookPath -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($hookPath, $utf8.GetBytes($hookText))
        $status = 'Installed'
    }

    if (($currentTemplate -ne $templateFull) -and $PSCmdlet.ShouldProcess('git config --global init.templateDir', "Set to $templateFull")) {
        $set = Invoke-GitExe -Arguments @('config', '--global', 'init.templateDir', $templateFull)
        if ($set.ExitCode -ne 0) {
            throw "git config --global init.templateDir failed: $($set.Output -join ' ')"
        }
        $status = 'Installed'
    }

    [pscustomobject]@{
        TemplateDir = $templateFull
        HookPath    = $hookPath
        Status      = $status
    }
}
