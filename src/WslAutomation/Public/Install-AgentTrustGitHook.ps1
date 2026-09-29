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

        On non-Windows hosts (WSL/Linux) git ignores a hook that is not executable, so the hook
        file is set to mode 0755, and a current hook that lost its executable bit is fixed and
        counted as a change.

        Git copies template hooks only at init/clone, so clones that existed before the template
        was installed never get the hook. -IncludeExistingClones installs it into those too: for
        each direct child of each existing owner root whose .git is a directory. A .git file is a
        linked worktree and shares its main repo's hooks, so it is skipped, as is any repo with a
        local core.hooksPath (git would ignore the hook) and any repo whose post-checkout hook
        was not written by this installer (never overwritten, not even with -Force).

        Returns an object with TemplateDir, HookPath, Status ('Installed' or 'AlreadyInstalled')
        and ExistingClones (repo paths whose hook was written or whose mode was fixed; empty
        without -IncludeExistingClones). Status describes the template only.
    .PARAMETER TemplateDir
        Template directory. Defaults to ~/.git-templates/agent-trust.
    .PARAMETER PwshPath
        pwsh executable the hook runs. Defaults to Get-WslAutomationDefaultPwshPath on Windows
        and to the pwsh found on PATH elsewhere.
    .PARAMETER TrustScriptPath
        Absolute path of scripts/trust-agent-workspaces.ps1. Defaults to this checkout's copy.
    .PARAMETER Force
        Overwrite a different existing init.templateDir, and a template post-checkout hook this
        installer did not write. Never overwrites a foreign hook inside an existing clone.
    .PARAMETER IncludeExistingClones
        Also install the hook into existing clones directly under the owner roots.
    .PARAMETER OwnerRoot
        Directories whose direct children are existing clones. Only used with
        -IncludeExistingClones. Defaults to D:\repos\adam-s-daniel and D:\repos\jodidaniel on
        Windows and to ~/repos elsewhere (see Get-AgentTrustDefaultOwnerRoot).
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

        [switch]$Force,

        [switch]$IncludeExistingClones,

        [string[]]$OwnerRoot
    )

    if (-not $PwshPath) {
        $PwshPath = if ($IsWindows) { Get-WslAutomationDefaultPwshPath } else { (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
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

    # git silently ignores a non-executable hook, so off Windows the file must be 0755.
    $hookMode = [System.IO.UnixFileMode]0x1ED
    $isExecutable = {
        param([string]$File)
        ([System.IO.File]::GetUnixFileMode($File) -band [System.IO.UnixFileMode]::UserExecute) -ne 0
    }

    $status = 'AlreadyInstalled'
    $needsMode = $hookCurrent -and -not $IsWindows -and -not (& $isExecutable $hookPath)
    if ((-not $hookCurrent -or $needsMode) -and $PSCmdlet.ShouldProcess($hookPath, 'Write post-checkout trust hook')) {
        if (-not $hookCurrent) {
            New-Item -ItemType Directory -Path (Split-Path -Path $hookPath -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllBytes($hookPath, $utf8.GetBytes($hookText))
        }
        if (-not $IsWindows) {
            [System.IO.File]::SetUnixFileMode($hookPath, $hookMode)
        }
        $status = 'Installed'
    }

    if (($currentTemplate -ne $templateFull) -and $PSCmdlet.ShouldProcess('git config --global init.templateDir', "Set to $templateFull")) {
        $set = Invoke-GitExe -Arguments @('config', '--global', 'init.templateDir', $templateFull)
        if ($set.ExitCode -ne 0) {
            throw "git config --global init.templateDir failed: $($set.Output -join ' ')"
        }
        $status = 'Installed'
    }

    $existingClones = [System.Collections.Generic.List[string]]::new()
    if ($IncludeExistingClones) {
        if (-not $PSBoundParameters.ContainsKey('OwnerRoot')) {
            $OwnerRoot = Get-AgentTrustDefaultOwnerRoot
        }
        foreach ($root in $OwnerRoot) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-Verbose "Owner root not found, skipping: $root"
                continue
            }
            foreach ($child in Get-ChildItem -LiteralPath $root -Directory -Force) {
                $gitDir = Join-Path $child.FullName '.git'
                # A .git file is a linked worktree: it shares its main repo's hooks.
                if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) { continue }

                $local = Invoke-GitExe -Arguments @('-C', $child.FullName, 'config', '--local', '--get', 'core.hooksPath')
                if ($local.ExitCode -eq 0 -and $local.Output) {
                    Write-Warning "Skipping '$($child.FullName)': core.hooksPath is set locally to '$($local.Output[0])', so git ignores its hooks."
                    continue
                }

                $cloneHook = Join-Path $gitDir 'hooks' 'post-checkout'
                $cloneCurrent = $false
                if (Test-Path -LiteralPath $cloneHook -PathType Leaf) {
                    $cloneText = $utf8.GetString([System.IO.File]::ReadAllBytes($cloneHook))
                    if ($cloneText -ceq $hookText) {
                        $cloneCurrent = $true
                    }
                    elseif (-not $cloneText.Contains($marker)) {
                        Write-Warning "Skipping '$($child.FullName)': its post-checkout hook was not written by this installer."
                        continue
                    }
                }

                $cloneNeedsMode = $cloneCurrent -and -not $IsWindows -and -not (& $isExecutable $cloneHook)
                if ($cloneCurrent -and -not $cloneNeedsMode) { continue }
                if ($PSCmdlet.ShouldProcess($cloneHook, 'Write post-checkout trust hook')) {
                    if (-not $cloneCurrent) {
                        New-Item -ItemType Directory -Path (Split-Path -Path $cloneHook -Parent) -Force | Out-Null
                        [System.IO.File]::WriteAllBytes($cloneHook, $utf8.GetBytes($hookText))
                    }
                    if (-not $IsWindows) {
                        [System.IO.File]::SetUnixFileMode($cloneHook, $hookMode)
                    }
                    $existingClones.Add($child.FullName)
                }
            }
        }
    }

    [pscustomobject]@{
        TemplateDir    = $templateFull
        HookPath       = $hookPath
        Status         = $status
        ExistingClones = $existingClones.ToArray()
    }
}
