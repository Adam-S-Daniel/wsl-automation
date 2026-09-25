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
    .PARAMETER LogFile
        Path to this sync's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\codex-cloud-sync.log". Every logged line is an
        outcome only - never wslpath or bash output, which may contain account or repository
        data. The one exception is the reconciler's own aggregate-only summary line, logged
        only when it is an exact match for one of the two summary lines the reconciler prints
        (dry run or complete); anything else - including a summary line the reconciler
        appended extra text to - stays unlogged.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$ScriptPath = (Join-Path -Path (Split-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -Parent) -ChildPath 'scripts\sync-codex-cloud-environments.sh'),

        [switch]$DryRun,

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'codex-cloud-sync.log')
    )

    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        Write-WslAutomationLog -Message "skipped: distro '$DistroName' is not running" -LogFile $LogFile
        return [pscustomobject]@{ Status = 'SkippedDistroNotRunning' }
    }

    # --exec runs wslpath directly; -- would hand the Windows path to the distro's
    # default shell, which strips its backslashes before wslpath ever sees them.
    $pathResult = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'wslpath', '-a', '-u', $ScriptPath)

    # During a WSL transition (e.g. right after a resume), wsl.exe can print an informational
    # "wsl: ..." line - for example a failed systemd user session warning - on stderr while
    # still exiting 0. Invoke-WslExe merges stderr into Output, so such a line would otherwise
    # be mistaken for a second (invalid) path result. Drop it before checking the output shape.
    $pathOutputLines = @($pathResult.Output | Where-Object { $_ -notmatch '^wsl: ' })

    if ($pathResult.ExitCode -ne 0 -or $pathOutputLines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($pathOutputLines[0])) {
        Write-WslAutomationLog -Message "path conversion failed: wslpath exit code $($pathResult.ExitCode), $($pathOutputLines.Count) output line(s)" -LogFile $LogFile
        throw 'Could not convert the Codex Cloud synchronizer path for WSL.'
    }

    # -l starts a login shell so the login profile puts ~/.local/bin (codex, jq) on PATH.
    $arguments = @('-d', $DistroName, '--exec', 'bash', '-l', $pathOutputLines[0])
    if ($DryRun) {
        $arguments += '--dry-run'
    }
    $syncResult = Invoke-WslExe -Arguments $arguments
    if ($syncResult.ExitCode -ne 0) {
        Write-WslAutomationLog -Message "sync failed: bash exit code $($syncResult.ExitCode)" -LogFile $LogFile
        throw 'Codex Cloud environment synchronization failed.'
    }

    $statusLabel = if ($DryRun) { 'dry run completed' } else { 'completed' }
    # The reconciler's status output is aggregate-only (counts, never account or repository
    # data), but nothing here should trust that blindly - only forward it to the log when it
    # is an exact, fully anchored match for one of the two summary lines
    # scripts/sync-codex-cloud-environments.sh prints, and drop it silently otherwise (for
    # example if extra text were ever appended to it).
    $summaryLine = $syncResult.Output | Where-Object { $_ -match '^Codex Cloud environment sync (dry run: \d+ proposed changes, \d+ unchanged|complete: \d+ created, \d+ updated, \d+ unchanged)$' } | Select-Object -Last 1
    if ($summaryLine) {
        Write-WslAutomationLog -Message "${statusLabel}: $summaryLine" -LogFile $LogFile
    }
    else {
        Write-WslAutomationLog -Message $statusLabel -LogFile $LogFile
    }

    return [pscustomobject]@{ Status = if ($DryRun) { 'DryRun' } else { 'Completed' } }
}
