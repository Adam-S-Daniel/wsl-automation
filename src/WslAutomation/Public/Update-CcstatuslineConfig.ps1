function Update-CcstatuslineConfig {
    <#
    .SYNOPSIS
        Syncs the ccstatusline settings.json from WSL (source of truth) to Windows.
    .DESCRIPTION
        ccstatusline's config is edited inside WSL; this copies the current settings.json out to
        a Windows-side path so Windows-hosted tooling can read it too. WSL is always treated as
        the source of truth - this never writes back into WSL.

        If -SourcePath is not given, it is derived from -DistroName (and -WslUser, itself
        derived via `wsl -d <DistroName> -- whoami` when not given) as
        \\wsl.localhost\<DistroName>\home\<WslUser>\.config\ccstatusline\settings.json.

        Returns a [pscustomobject] with Status and DestinationPath. Status is one of:
          - SourceUnavailable: the WSL user couldn't be determined, or the source file doesn't
            exist (for example because WSL is shut down). This is a no-op that intentionally
            leaves any existing local copy in place rather than treating a shut-down distro as
            "config deleted".
          - SourceInvalid: the source file exists but is not parseable JSON.
          - AlreadyInSync: the destination already has identical content; nothing was written.
          - Updated: the destination was created or overwritten from the source.
          - Skipped: an update was needed but declined, for example because of -WhatIf.
    .PARAMETER DistroName
        Name of the WSL distro to read the config from when -SourcePath is not given. Defaults
        to 'Ubuntu'.
    .PARAMETER WslUser
        Linux username whose home directory holds the config, used to build -SourcePath when it
        is not given. When not supplied, it is derived by running `whoami` inside the distro.
    .PARAMETER SourcePath
        Full UNC path to the WSL-side settings.json. When not supplied, it is built from
        -DistroName and -WslUser.
    .PARAMETER DestinationPath
        Windows-side path the config is copied to. Defaults to
        "$env:USERPROFILE\.config\ccstatusline\settings.json".
    .PARAMETER LogFile
        Path to this sync's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\ccstatusline-sync.log".
    .EXAMPLE
        Update-CcstatuslineConfig

        Derives the WSL user from the 'Ubuntu' distro and syncs its ccstatusline settings.json
        to the default Windows destination.
    .EXAMPLE
        Update-CcstatuslineConfig -DistroName 'Debian' -WslUser 'adam' -WhatIf

        Shows whether the Debian distro's config would be copied, without writing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$WslUser,

        [string]$SourcePath,

        [string]$DestinationPath = (Join-Path $env:USERPROFILE '.config\ccstatusline\settings.json'),

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'ccstatusline-sync.log')
    )

    if (-not $SourcePath) {
        if (-not $WslUser) {
            $whoami = Invoke-WslExe -Arguments @('-d', $DistroName, '--', 'whoami')
            $whoamiUser = $whoami.Output | Select-Object -First 1
            if ($whoami.ExitCode -ne 0 -or -not $whoamiUser -or -not "$whoamiUser".Trim()) {
                Write-WslAutomationLog -Message "could not determine WSL user for distro '$DistroName'" -LogFile $LogFile
                return [pscustomobject]@{ Status = 'SourceUnavailable'; DestinationPath = $DestinationPath }
            }
            $WslUser = "$whoamiUser".Trim()
        }

        $SourcePath = "\\wsl.localhost\$DistroName\home\$WslUser\.config\ccstatusline\settings.json"
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        # WSL may simply be shut down right now; that is not an error condition and any existing
        # local copy is left alone rather than being treated as stale/deleted.
        Write-WslAutomationLog -Message "source not available: $SourcePath" -LogFile $LogFile
        return [pscustomobject]@{ Status = 'SourceUnavailable'; DestinationPath = $DestinationPath }
    }

    $raw = Get-Content -LiteralPath $SourcePath -Raw
    try {
        $null = $raw | ConvertFrom-Json
    }
    catch {
        Write-WslAutomationLog -Message "source is not valid JSON: $SourcePath" -LogFile $LogFile
        return [pscustomobject]@{ Status = 'SourceInvalid'; DestinationPath = $DestinationPath }
    }

    if ((Test-Path -LiteralPath $DestinationPath) -and (Get-Content -LiteralPath $DestinationPath -Raw) -ceq $raw) {
        return [pscustomobject]@{ Status = 'AlreadyInSync'; DestinationPath = $DestinationPath }
    }

    if ($PSCmdlet.ShouldProcess($DestinationPath, 'Update ccstatusline settings from WSL')) {
        $destinationParent = Split-Path -Path $DestinationPath -Parent
        if ($destinationParent -and -not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }

        # The Windows-side copy is kept read-only as a guard against accidental edits on the
        # Windows side being silently clobbered by the next sync (WSL is always the source of
        # truth). This function is the one "determined actor" allowed to clear that guard: it
        # clears IsReadOnly, writes the new content, then immediately restores IsReadOnly so the
        # file is protected again the instant the sync finishes.
        if ((Test-Path -LiteralPath $DestinationPath) -and (Get-Item -LiteralPath $DestinationPath).IsReadOnly) {
            Set-ItemProperty -LiteralPath $DestinationPath -Name IsReadOnly -Value $false
        }
        Set-Content -LiteralPath $DestinationPath -Value $raw -NoNewline -Encoding utf8
        Set-ItemProperty -LiteralPath $DestinationPath -Name IsReadOnly -Value $true

        Write-WslAutomationLog -Message 'updated ccstatusline settings from WSL' -LogFile $LogFile
        return [pscustomobject]@{ Status = 'Updated'; DestinationPath = $DestinationPath }
    }

    return [pscustomobject]@{ Status = 'Skipped'; DestinationPath = $DestinationPath }
}
