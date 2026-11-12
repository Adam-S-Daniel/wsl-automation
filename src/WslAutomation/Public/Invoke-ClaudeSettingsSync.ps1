function Invoke-ClaudeSettingsSync {
    <#
    .SYNOPSIS
        Syncs Claude Code settings.json between Windows and WSL, without ever starting WSL.
    .DESCRIPTION
        Runs the adam-agentskills skill script Sync-ClaudeSettings.ps1 (a three-way merge against
        a last-synced snapshot) in -Unattended mode, so it never prompts and leaves a conflict
        alone. It runs only when the distro is already running, so a scheduled task cannot boot
        WSL just to read a settings file.

        Everything logged is an outcome only: the script's own one-line summary (counts, no key
        names or values) when it matches the exact shape the script prints, and nothing else
        from its output. The key-level report (key names and same/changed markers, never
        values) is written to -ReportPath for review.

        Writes nothing unless -Live is given: without it the script runs with -DryRun, which
        writes no settings, backups or snapshot.
    .PARAMETER DistroName
        Name of the WSL distro whose ~/.claude/settings.json is synced. Defaults to 'Ubuntu'.
    .PARAMETER WslUser
        Linux username that owns the home directory. When not supplied, it is derived by
        running `whoami` inside the (already running) distro.
    .PARAMETER SyncScriptPath
        Path to Sync-ClaudeSettings.ps1. Defaults to the skill's copy in the adam-agentskills
        clone next to this repository (D:\repos\<owner>\adam-agentskills on this fleet's
        layout), which the clone-sync task keeps current.
    .PARAMETER WindowsSettingsPath
        The Windows settings.json. Defaults to "$env:USERPROFILE\.claude\settings.json".
    .PARAMETER PwshPath
        The pwsh.exe that runs the script.
    .PARAMETER Live
        Let the script write settings files, backups and its snapshot. Without it, -DryRun.
    .PARAMETER ReportPath
        Where the key-level report goes. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\claude-settings-sync-report.txt".
    .PARAMETER LogFile
        Path to this sync's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\claude-settings-sync.log".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$WslUser,

        [string]$SyncScriptPath = (Join-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent) -ChildPath 'adam-agentskills\plugins\adam-coding-local\skills\sync-cc-settings-between-wsl-and-windows\scripts\Sync-ClaudeSettings.ps1'),

        [string]$WindowsSettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),

        [string]$PwshPath = (Get-WslAutomationDefaultPwshPath),

        [switch]$Live,

        [string]$ReportPath = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'claude-settings-sync-report.txt'),

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'claude-settings-sync.log')
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        Write-WslAutomationLog -Message "skipped: distro '$DistroName' is not running" -LogFile $LogFile
        return [pscustomobject]@{ Status = 'SkippedDistroNotRunning' }
    }

    if (-not (Test-Path -LiteralPath $SyncScriptPath)) {
        Write-WslAutomationLog -Message "sync script not found: $SyncScriptPath" -LogFile $LogFile
        throw 'Sync-ClaudeSettings.ps1 was not found; is the adam-agentskills clone present?'
    }

    if (-not $WslUser) {
        # --exec runs whoami directly, and wsl.exe can print a warning on stderr while exiting 0
        # (see Update-CcstatuslineConfig), so pick the one line that looks like a username.
        $whoami = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'whoami')
        $candidateUsers = @($whoami.Output | ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -match '^[a-z_][a-z0-9_-]*[$]?$' } | Select-Object -Unique)
        if ($whoami.ExitCode -ne 0 -or $candidateUsers.Count -ne 1) {
            Write-WslAutomationLog -Message "could not determine WSL user for distro '$DistroName'" -LogFile $LogFile
            return [pscustomobject]@{ Status = 'SkippedNoWslUser' }
        }
        $WslUser = $candidateUsers[0]
    }
    $wslSettingsPath = "\\wsl.localhost\$DistroName\home\$WslUser\.claude\settings.json"

    $arguments = @(
        '-NoProfile', '-File', $SyncScriptPath,
        '-WindowsSettingsPath', $WindowsSettingsPath,
        '-WslSettingsPath', $wslSettingsPath,
        '-ReportPath', $ReportPath,
        '-Unattended'
    )
    if (-not $Live) { $arguments += '-DryRun' }

    $result = Invoke-ClaudeSettingsSyncScript -PwshPath $PwshPath -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        # Never log the script's output: a failure can quote a path or a parse error.
        Write-WslAutomationLog -Message "sync failed: exit code $($result.ExitCode)" -LogFile $LogFile
        throw 'Claude settings synchronization failed.'
    }

    # Forward only the script's exact one-line summary (counts and fixed words); anything else
    # stays unlogged.
    $summaryPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z sync-claude-settings mode=(live|dry-run) outcome=[a-z-]+ snapshot=[a-z]+ windows=(nochange|write\(\d+ keys\)) wsl=(nochange|write\(\d+ keys\)) conflicts=\d+$'
    $summary = $result.Output | Where-Object { $_ -match $summaryPattern } | Select-Object -Last 1
    if ($summary) {
        Write-WslAutomationLog -Message ($summary -replace '^\S+ ', '') -LogFile $LogFile
    }
    else {
        Write-WslAutomationLog -Message 'completed (no summary line)' -LogFile $LogFile
    }

    [pscustomobject]@{ Status = if ($Live) { 'Completed' } else { 'DryRun' } }
}
