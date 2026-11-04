function Invoke-DockerWslIntegrationWatchdog {
    <#
    .SYNOPSIS
        Detects a broken Docker Desktop WSL integration with a running distro, repairs it with a
        Docker Desktop restart, and alerts the owner when it cannot.
    .DESCRIPTION
        After a reboot, Docker Desktop's WSL integration with a distro can fail: Docker's
        pre-bootstrap force-unmounts its shared-socket mounts under /mnt/wsl (a mount peer group
        shared across distros), the distro powers off moments later, and its shutdown unmounts
        /mnt/wsl/docker-desktop/shared-sockets/host-services, so the integration cannot reach
        backend.sock. Skipping the integration in Docker's error dialog then removes the distro
        from Docker's integration list. A Docker Desktop restart re-creates the mounts and
        recovers the first case; only the owner can restore the second (see AGENTS.md).

        The flow, one outcome-only log line per step (no user name, host name or profile path is
        ever logged):

        1. Recently woken or booted machine: Status DeferredRecentWake, nothing else runs.
        2. Docker Desktop not running: Status DockerNotRunning. No alert, no restart.
        3. The distro missing from IntegratedWslDistros in Docker's settings store: Status
           IntegrationNotConfigured, an alert, and NO restart (a restart cannot fix it).
           An unreadable settings store is Status SettingsUnreadable (log only).
        4. The distro not running: Status DistroNotRunning. A stopped distro is never booted.
        5. A probe inside the distro (the shared socket exists and 'docker version' answers):
           Status Healthy, and the alert state is cleared.
        6. Otherwise up to -MaxRestarts attempts, each: 'docker desktop restart', wait for the
           engine, wait for the probe. Success is Status Recovered (alert state cleared).
        7. Still broken: Status Unrecovered and an alert.

        Alerts (a toast and a self-alert email, see Send-WslAutomationAlert) are deduplicated by
        status: the state file remembers the last alerted status and a repeat of the same status
        sends nothing until Healthy or Recovered clears it. Waits are counted as accumulated
        poll seconds, not by the wall clock.
    .PARAMETER DistroName
        Name of the WSL distro whose Docker integration is watched. Defaults to 'Ubuntu'.
    .PARAMETER SettingsStorePath
        Docker Desktop's settings-store.json. Defaults to "$env:APPDATA\Docker\settings-store.json".
    .PARAMETER LogFile
        Log file. Defaults to "$env:LOCALAPPDATA\wsl-automation\docker-wsl-watchdog.log".
    .PARAMETER StatePath
        Alert dedupe state file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\docker-wsl-watchdog-state.json".
    .PARAMETER MaxRestarts
        Maximum Docker Desktop restarts per run. Defaults to 2.
    .PARAMETER EngineWaitSeconds
        How long after a restart to wait for Docker Desktop to report running. Defaults to 180.
    .PARAMETER IntegrationWaitSeconds
        How long after the engine is running to wait for the probe to pass. Defaults to 120.
    .PARAMETER PollSeconds
        Seconds between polls while waiting. Defaults to 10.
    .PARAMETER MinMinutesSinceWake
        Minutes since the last boot or resume before the watchdog acts, so it never races the
        post-boot WSL and Docker start-up. Defaults to 10.
    .PARAMETER DryRun
        Logs what would be restarted and alerted, without restarting Docker Desktop, sending an
        alert or writing the state file.
    .EXAMPLE
        Invoke-DockerWslIntegrationWatchdog -DistroName 'Ubuntu'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$SettingsStorePath = (Join-Path $env:APPDATA 'Docker\settings-store.json'),

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation\docker-wsl-watchdog.log'),

        [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'wsl-automation\docker-wsl-watchdog-state.json'),

        [int]$MaxRestarts = 2,

        [int]$EngineWaitSeconds = 180,

        [int]$IntegrationWaitSeconds = 120,

        [int]$PollSeconds = 10,

        [int]$MinMinutesSinceWake = 10,

        [switch]$DryRun
    )

    $subjectSuffix = ', via "Docker WSL Integration Watchdog" https://github.com/Adam-S-Daniel/wsl-automation/blob/main/scripts/ensure-docker-wsl-integration.ps1'
    $pollStep = [Math]::Max(1, $PollSeconds)
    $restarts = 0
    $alerted = $false

    $log = { param($Message) Write-WslAutomationLog -Message $Message -LogFile $LogFile }
    $finish = { param($Status) [pscustomobject]@{ Status = $Status; Restarts = $restarts; Alerted = $alerted } }

    # True when Docker Desktop answers 'desktop status' with Status 'running'.
    $isEngineRunning = {
        $cli = Invoke-DockerDesktopCli -Arguments @('desktop', 'status', '--format', 'json')
        if ($cli.ExitCode -ne 0) { return $false }
        try {
            $parsed = ($cli.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return $false
        }
        if ($null -eq $parsed -or -not $parsed.PSObject.Properties['Status']) { return $false }
        return ([string]$parsed.Status -ieq 'running')
    }

    # Sends an alert unless the same status was already alerted. Returns $true when at least one
    # channel delivered it.
    $raiseAlert = {
        param($AlertStatus, $Subject, $Body)

        $lastAlert = $null
        if (Test-Path -LiteralPath $StatePath) {
            try {
                $savedState = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $savedState -and $savedState.PSObject.Properties['lastAlert']) {
                    $lastAlert = [string]$savedState.lastAlert
                }
            }
            catch {
                # A corrupt state file counts as no state.
                $lastAlert = $null
            }
        }
        if ($lastAlert -eq $AlertStatus) {
            & $log "alert suppressed: $AlertStatus was already alerted"
            return $false
        }
        if ($DryRun) {
            & $log "dry run: would alert ($AlertStatus)"
            return $false
        }

        $sent = Send-WslAutomationAlert -Subject ($Subject + $subjectSuffix) -Body $Body -LogFile $LogFile
        $delivered = [bool]($sent.Toast -or $sent.Email)
        if ($delivered) {
            $stateJson = [pscustomobject]@{ lastAlert = $AlertStatus; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json
            $stateDirectory = Split-Path -Path $StatePath -Parent
            if ($stateDirectory -and -not (Test-Path -LiteralPath $stateDirectory)) {
                New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
            }
            $temporaryPath = "$StatePath.tmp"
            Set-Content -LiteralPath $temporaryPath -Value $stateJson -Encoding utf8
            Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
        }
        else {
            & $log "alert not delivered on any channel; will retry next run ($AlertStatus)"
        }
        return $delivered
    }


    # 1. Wake guard.
    $minutesSinceWake = ((Get-Date) - (Get-LastWakeTime)).TotalMinutes
    if ($minutesSinceWake -lt $MinMinutesSinceWake) {
        Write-WslAutomationLog -Message "deferred: machine booted or resumed less than $MinMinutesSinceWake minutes ago" -LogFile $LogFile
        return (& $finish 'DeferredRecentWake')
    }

    # 2. Docker Desktop must be running; a stopped Docker is the owner's choice, not a fault.
    if (-not (& $isEngineRunning)) {
        & $log 'Docker Desktop is not running; nothing to check'
        return (& $finish 'DockerNotRunning')
    }

    # 3. The distro must still be in Docker's integration list.
    $settings = $null
    try {
        $settings = Get-Content -LiteralPath $SettingsStorePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $settings = $null
    }
    if ($null -eq $settings -or $settings -isnot [pscustomobject]) {
        & $log 'Docker Desktop settings store is missing or unreadable'
        return (& $finish 'SettingsUnreadable')
    }
    $integratedDistros = @()
    $integratedProperty = $settings.PSObject.Properties['IntegratedWslDistros']
    if ($null -ne $integratedProperty -and $null -ne $integratedProperty.Value) {
        $integratedDistros = @($integratedProperty.Value)
    }
    if ($integratedDistros -notcontains $DistroName) {
        & $log "Docker Desktop WSL integration does not include '$DistroName'; a restart cannot fix this, alerting"
        $notConfiguredBody = "Docker Desktop's WSL integration list no longer includes $DistroName, so Docker commands inside $DistroName do not work. Open Docker Desktop > Settings > Resources > WSL integration, turn $DistroName back on, and choose Apply & restart."
        $alerted = & $raiseAlert 'IntegrationNotConfigured' "Docker Desktop WSL integration no longer includes $DistroName" $notConfiguredBody
        return (& $finish 'IntegrationNotConfigured')
    }

    # 4. Never boot a stopped distro.
    if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
        & $log "distro '$DistroName' is not running; not touching it"
        return (& $finish 'DistroNotRunning')
    }

    # 5. Probe.
    if (Test-DockerWslIntegration -DistroName $DistroName) {
        & $log "Docker WSL integration with '$DistroName' is healthy"
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        return (& $finish 'Healthy')
    }
    & $log "Docker WSL integration with '$DistroName' is broken"

    # 6. Repair: restart Docker Desktop, which re-creates the shared-socket mounts.
    $distroStopped = $false
    for ($attempt = 1; $attempt -le $MaxRestarts; $attempt++) {
        if ($DryRun) {
            & $log "dry run: would restart Docker Desktop (attempt $attempt of $MaxRestarts)"
            break
        }

        & $log "restarting Docker Desktop (attempt $attempt of $MaxRestarts)"
        $restartResult = Invoke-DockerDesktopCli -Arguments @('desktop', 'restart')
        $restarts++
        & $log "docker desktop restart exit code $($restartResult.ExitCode)"

        $engineUp = $false
        $waitedSeconds = 0
        do {
            Start-Sleep -Seconds $pollStep
            $waitedSeconds += $pollStep
            $engineUp = [bool](& $isEngineRunning)
        } while (-not $engineUp -and $waitedSeconds -lt $EngineWaitSeconds)
        if (-not $engineUp) {
            & $log "Docker Desktop did not report running within $EngineWaitSeconds seconds (attempt $attempt)"
            continue
        }

        $healthy = $false
        $waitedSeconds = 0
        while ($true) {
            # A restart can take the distro down with it; the probe would boot it again.
            if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
                $distroStopped = $true
                break
            }
            if (Test-DockerWslIntegration -DistroName $DistroName) {
                $healthy = $true
                break
            }
            if ($waitedSeconds -ge $IntegrationWaitSeconds) { break }
            Start-Sleep -Seconds $pollStep
            $waitedSeconds += $pollStep
        }

        if ($healthy) {
            & $log "Docker WSL integration with '$DistroName' recovered after $restarts restart(s)"
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            return (& $finish 'Recovered')
        }
        if ($distroStopped) {
            & $log "distro '$DistroName' stopped during recovery; not touching it"
            return (& $finish 'DistroNotRunning')
        }
        & $log "integration still broken after restart attempt $attempt"
    }

    # 7. Still broken.
    $unrecoveredBody = "Docker Desktop's WSL integration with $DistroName is broken. The watchdog restarted Docker Desktop $restarts time(s) and the integration did not come back. Try this: quit Docker Desktop, run 'wsl --shutdown', then start Docker Desktop again."
    $alerted = & $raiseAlert 'Unrecovered' "Docker Desktop WSL integration with $DistroName is broken and a restart did not fix it" $unrecoveredBody
    return (& $finish 'Unrecovered')
}
