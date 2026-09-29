function Set-AgentWorkspaceTrust {
    <#
    .SYNOPSIS
        Pre-trusts git working trees under the owner roots for Claude Code and Codex.
    .DESCRIPTION
        Trust granted to a parent folder does not extend to nested git repositories, so every
        clone and worktree would otherwise raise its own trust prompt. This marks directories as
        trusted in both agents' user-level config files:

          - Claude Code: projects[<forward-slash path>].hasTrustDialogAccepted = true in
            ~/.claude.json (undocumented file format). The file is never created.
          - Codex: a [projects.'<path>'] table with trust_level = "trusted" in
            ~/.codex/config.toml, once for the Windows path and once for the WSL /mnt/<drive>/
            path. The file is created when its directory exists. When run by pwsh on Linux only
            the Linux path is written (no /mnt key), for example [projects."/home/u/repos/x"].

        Without -Path (scan mode) each owner root itself and every direct child directory that
        has a .git entry (directory or file, so worktrees count) is trusted. With -Path only
        those directories are trusted, and any path that is not equal to or under an owner root
        is skipped silently (see -Verbose).

        A changed config file is first copied to "<file>.bak-agent-trust" (one backup, overwritten
        each time) and then replaced atomically via "<file>.tmp". Nothing is written when
        everything is already trusted. Never prompts.

        Returns one object per key that was changed: Agent ('Claude' or 'Codex') and Key.
    .PARAMETER Path
        Specific directories to trust. When omitted, the owner roots are scanned.
    .PARAMETER OwnerRoot
        Directories whose git children may be trusted. Defaults to D:\repos\adam-s-daniel and
        D:\repos\jodidaniel on Windows, and to ~/repos on WSL/Linux (see
        Get-AgentTrustDefaultOwnerRoot).
    .PARAMETER ClaudeConfigPath
        Claude Code's user config. Defaults to ~/.claude.json (on Linux, /home/<user>/.claude.json).
    .PARAMETER CodexConfigPath
        Codex's user config. Defaults to ~/.codex/config.toml.
    .EXAMPLE
        Set-AgentWorkspaceTrust

        Trusts every git working tree directly under the two default owner roots.
    .EXAMPLE
        Set-AgentWorkspaceTrust -Path 'D:\repos\jodidaniel\new-repo' -WhatIf

        Shows what trusting one new clone would change.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Path,

        [string[]]$OwnerRoot,

        [string]$ClaudeConfigPath = (Join-Path $HOME '.claude.json'),

        [string]$CodexConfigPath = (Join-Path $HOME '.codex/config.toml')
    )

    if (-not $PSBoundParameters.ContainsKey('OwnerRoot')) {
        $OwnerRoot = Get-AgentTrustDefaultOwnerRoot
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $trimChars = if ($IsWindows) { [char[]]('\', '/') } else { [char[]]('/') }

    $normalize = {
        param([string]$Value)
        $full = [System.IO.Path]::GetFullPath($Value)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $root.Length) { $full = $full.TrimEnd($trimChars) }
        $full
    }

    $roots = @($OwnerRoot | ForEach-Object { & $normalize $_ })

    $targets = [System.Collections.Generic.List[string]]::new()
    if ($PSBoundParameters.ContainsKey('Path')) {
        foreach ($candidate in $Path) {
            $full = & $normalize $candidate
            $inside = $false
            foreach ($root in $roots) {
                if ($full.Equals($root, $comparison) -or
                    $full.StartsWith($root.TrimEnd($sep) + $sep, $comparison)) {
                    $inside = $true
                    break
                }
            }
            if ($inside) {
                $targets.Add($full)
            }
            else {
                Write-Verbose "Skipping path outside the owner roots: $full"
            }
        }
    }
    else {
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-Verbose "Owner root not found, skipping: $root"
                continue
            }
            $targets.Add($root)
            foreach ($child in Get-ChildItem -LiteralPath $root -Directory -Force) {
                if (Test-Path -LiteralPath (Join-Path $child.FullName '.git')) {
                    $targets.Add((& $normalize $child.FullName))
                }
            }
        }
    }

    $uniqueTargets = @($targets | Sort-Object -Unique -CaseSensitive:(-not $IsWindows))
    if ($uniqueTargets.Count -eq 0) {
        return
    }

    $claudeKeys = @($uniqueTargets | ForEach-Object { $_.Replace('\', '/') })

    $codexKeys = foreach ($target in $uniqueTargets) {
        $target
        if ($target -match '^([A-Za-z]):\\(.*)$') {
            '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace('\', '/')
        }
    }

    foreach ($key in @(Grant-ClaudeProjectTrust -ConfigPath $ClaudeConfigPath -Key $claudeKeys -WhatIf:$WhatIfPreference)) {
        [pscustomobject]@{ Agent = 'Claude'; Key = $key }
    }
    foreach ($key in @(Grant-CodexProjectTrust -ConfigPath $CodexConfigPath -Key @($codexKeys) -WhatIf:$WhatIfPreference)) {
        [pscustomobject]@{ Agent = 'Codex'; Key = $key }
    }
}
