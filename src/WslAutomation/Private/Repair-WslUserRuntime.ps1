function Repair-WslUserRuntime {
    <#
    .SYNOPSIS
        Best-effort: restarts a dead systemd user manager (user@<uid>.service) of the default
        user inside a running WSL distro.
    .DESCRIPTION
        Used by Invoke-ClaudeSessionKeeper before its session work. When the default user's
        systemd --user manager dies (for example a stray kill(-1, SIGKILL) run as that user),
        systemd removes /run/user/<uid> and does not start the manager again by itself: new
        shells complain that XDG_RUNTIME_DIR is not a directory, snap apps fail with 'cannot
        create XDG_RUNTIME_DIR' and user timers stop. See the AGENTS.md note on the 2026-10-04
        incident.

        Starting user@<uid> as a plain user needs a password, but enabling lingering does not
        (polkit allows a user to change their own lingering), and enabling it starts the
        manager and recreates the runtime directory. So when the manager is not running:

        - lingering off: 'loginctl enable-linger <uid>';
        - lingering on: 'loginctl disable-linger <uid>' then 'loginctl enable-linger <uid>',
          because enabling an already enabled lingering has nothing to change. (The sequence
          is inferred from loginctl(1), which only says that enabling spawns a manager; it
          has not been exercised against a dead manager with lingering already on.)

        It then waits briefly for the manager to come up (inside the distro, in one call) and
        logs one non-identifying line. The user is addressed by numeric uid and neither the uid
        nor the user name is ever logged.

        The common path is two cheap calls: Get-WslDistroState (a stopped distro is never
        booted just to check it) and one 'sh -c' probe that prints a single word. The probe
        leaves a distro without systemd, a root default user, a booting system and a manager
        that is active, activating, reloading or deactivating alone.

        Never throws: any failure is logged (when it happened during a repair) or reported
        through -Verbose, and the keeper carries on.
    .PARAMETER DistroName
        Name of the WSL distro to check. Defaults to 'Ubuntu'.
    .PARAMETER LogFile
        Path to the keeper's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\keeper.log".
    .PARAMETER DryRun
        Only log that a repair would run; never run loginctl.
    .OUTPUTS
        One of 'Skipped' (distro not running, no systemd, root user, booting, or a failed
        check), 'Healthy', 'Restored', 'Failed' or 'DryRun'.
    .EXAMPLE
        Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $logFile

        Does nothing when the user manager is running, otherwise restarts it.
    #>
    [CmdletBinding()]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'keeper.log'),

        [switch]$DryRun
    )

    # Plain 'sh' on purpose and no double quotes in the scripts: wsl.exe hands the arguments
    # over verbatim with --exec, and the less quoting there is, the less there is to get wrong.
    # Prints one of: unsupported | booting | ok | inactive <uid> on | inactive <uid> off.
    $probeScript = 'test -d /run/systemd/system || { echo unsupported; exit 0; }; ' +
        'uid=$(id -u); test $uid -ne 0 || { echo unsupported; exit 0; }; ' +
        'case $(systemctl is-system-running) in starting|initializing) echo booting; exit 0;; esac; ' +
        'case $(systemctl is-active user@$uid.service) in active|activating|reloading|deactivating) echo ok; exit 0;; esac; ' +
        'if test -e /var/lib/systemd/linger/$(id -un); then echo inactive $uid on; else echo inactive $uid off; fi'

    # Exits 0 as soon as the manager is active, 1 after about ten seconds.
    $waitScript = 'n=0; while test $n -lt 10; do ' +
        'systemctl is-active --quiet user@$1.service && exit 0; n=$((n+1)); sleep 1; done; exit 1'

    try {
        if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
            return 'Skipped'
        }

        $probe = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'sh', '-c', $probeScript)
        if ($probe.ExitCode -ne 0) {
            Write-Verbose -Message 'WSL user manager check failed; skipping'
            return 'Skipped'
        }

        $verdict = @($probe.Output | Where-Object { "$_" -match '^(?:ok|unsupported|booting|inactive \d+ (?:on|off))\s*$' }) |
            Select-Object -Last 1
        if (-not $verdict) {
            Write-Verbose -Message 'WSL user manager check gave no usable answer; skipping'
            return 'Skipped'
        }
        $verdict = "$verdict".Trim()

        if ($verdict -eq 'ok') {
            return 'Healthy'
        }
        if ($verdict -in 'unsupported', 'booting') {
            return 'Skipped'
        }

        $fields = $verdict -split ' '
        $uid = $fields[1]
        $lingerOn = $fields[2] -eq 'on'

        if ($DryRun) {
            Write-WslAutomationLog -Message 'DryRun: would restore the WSL user manager (runtime dir was missing)' -LogFile $LogFile
            return 'DryRun'
        }

        if ($lingerOn) {
            # Best effort: even if this fails, the enable below is still worth trying.
            Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'loginctl', 'disable-linger', $uid) | Out-Null
        }
        Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'loginctl', 'enable-linger', $uid) | Out-Null

        $recheck = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'sh', '-c', $waitScript, 'sh', $uid)
        if ($recheck.ExitCode -eq 0) {
            Write-WslAutomationLog -Message 'Restored the WSL user manager (runtime dir was missing)' -LogFile $LogFile
            return 'Restored'
        }

        Write-WslAutomationLog -Message 'Could not restore the WSL user manager (runtime dir still missing)' -LogFile $LogFile
        return 'Failed'
    }
    catch {
        Write-Verbose -Message 'WSL user manager repair failed with an error; skipping'
        return 'Skipped'
    }
}
