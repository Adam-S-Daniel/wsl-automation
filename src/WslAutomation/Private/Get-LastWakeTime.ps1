function Get-LastWakeTime {
    <#
    .SYNOPSIS
        Returns the timestamp of this machine's most recent boot or resume from sleep.
    .DESCRIPTION
        Invoke-WslBackup uses this to defer an export attempted too soon after either: 'wsl
        --export' can fail outright (exit -1) while WSL is still transitioning after a boot or a
        resume, up to roughly 270 seconds afterward (see AGENTS.md's "wsl --export fails on a
        transitioning WSL" section).

        Returns the later of:

        - the OS boot time (Win32_OperatingSystem.LastBootUpTime) - this alone already covers a
          resume from Fast Startup's hybrid hibernate, which Kernel-Boot Id 27 reports as 0x1
          rather than a full 0x0 boot but which still resets LastBootUpTime; and
        - the newest System-log wake event from Microsoft-Windows-Kernel-Power Id 507 or
          Microsoft-Windows-Power-Troubleshooter Id 1 - a real sleep/resume, which does not reset
          LastBootUpTime.

        A provider with no matching event (or one this account cannot query) is treated as having
        none, falling back to boot time alone; this never throws.
    .PARAMETER MaxEvents
        Maximum number of matching events requested per provider before taking the newest.
        Defaults to 5.
    .EXAMPLE
        Get-LastWakeTime

        Returns the later of the last boot time and the last detected resume-from-sleep time.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [int]$MaxEvents = 5
    )

    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime

    $wakeEventTimes = @()

    try {
        $kernelPowerEvents = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id           = 507
        } -MaxEvents $MaxEvents -ErrorAction Stop
        $wakeEventTimes += $kernelPowerEvents | Select-Object -ExpandProperty TimeCreated
    }
    catch {
        # No matching events, or this account cannot query the log - fall back to boot time.
        Write-Verbose "No Microsoft-Windows-Kernel-Power Id 507 events: $_"
    }

    try {
        $troubleshooterEvents = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Power-Troubleshooter'
            Id           = 1
        } -MaxEvents $MaxEvents -ErrorAction Stop
        $wakeEventTimes += $troubleshooterEvents | Select-Object -ExpandProperty TimeCreated
    }
    catch {
        # No matching events, or this account cannot query the log - fall back to boot time.
        Write-Verbose "No Microsoft-Windows-Power-Troubleshooter Id 1 events: $_"
    }

    $newestWakeEvent = $wakeEventTimes | Sort-Object -Descending | Select-Object -First 1

    if ($newestWakeEvent -and $newestWakeEvent -gt $bootTime) {
        return $newestWakeEvent
    }

    return $bootTime
}
