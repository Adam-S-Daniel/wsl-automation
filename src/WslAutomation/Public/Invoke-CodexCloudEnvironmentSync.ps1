function Invoke-CodexCloudEnvironmentSync {
    <#
    .SYNOPSIS
        Reconciles Codex Cloud environments for repositories connected to the current account.
    .DESCRIPTION
        Runs the Linux reconciler only when the selected WSL distro is already running. This
        prevents a scheduled task from starting WSL just to contact Codex Cloud. The reconciler
        itself emits aggregate-only status and never prints authentication or repository data.
    .PARAMETER DistroName
        Name of the already-running distro that owns the Codex CLI login state.
    .PARAMETER ScriptPath
        Windows path to scripts/sync-codex-cloud-environments.sh.
    .PARAMETER DryRun
        Passes --dry-run to the Linux reconciler after completing all discovery checks.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$ScriptPath = (Join-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent) -ChildPath 'scripts\sync-codex-cloud-environments.sh'),

        [switch]$DryRun
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        return [pscustomobject]@{ Status = 'SkippedDistroNotRunning' }
    }

    # --exec runs wslpath directly; -- would hand the Windows path to the distro's
    # default shell, which strips its backslashes before wslpath ever sees them.
    $pathResult = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'wslpath', '-a', '-u', $ScriptPath)
    if ($pathResult.ExitCode -ne 0 -or $pathResult.Output.Count -ne 1 -or [string]::IsNullOrWhiteSpace($pathResult.Output[0])) {
        throw 'Could not convert the Codex Cloud synchronizer path for WSL.'
    }

    # -l starts a login shell so the login profile puts ~/.local/bin (codex, jq) on PATH.
    $arguments = @('-d', $DistroName, '--exec', 'bash', '-l', $pathResult.Output[0])
    if ($DryRun) {
        $arguments += '--dry-run'
    }
    $syncResult = Invoke-WslExe -Arguments $arguments
    if ($syncResult.ExitCode -ne 0) {
        throw 'Codex Cloud environment synchronization failed.'
    }

    return [pscustomobject]@{ Status = if ($DryRun) { 'DryRun' } else { 'Completed' } }
}
