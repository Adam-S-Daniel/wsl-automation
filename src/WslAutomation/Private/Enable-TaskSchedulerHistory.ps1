function Enable-TaskSchedulerHistory {
    <#
    .SYNOPSIS
        Enables the Task Scheduler operational event log if it is currently disabled.
    .DESCRIPTION
        Windows ships with the Microsoft-Windows-TaskScheduler/Operational log (the "History"
        tab in Task Scheduler) disabled. Without it, a scheduled task leaves only its last
        result code behind - no start/finish times, no per-run exit codes, and no record of a
        run that was terminated at its execution time limit.

        Reads the log's current state through the private Get-TaskSchedulerHistoryLog seam and,
        if it is not already enabled, sets its IsEnabled property and calls .SaveChanges() on
        the returned EventLogConfiguration object - preferred over shelling out to wevtutil.exe
        both because it is mockable through the same seam pattern as Invoke-WslExe, and because
        it needs no extra process. Tests mock Get-TaskSchedulerHistoryLog to return a
        pscustomobject carrying a SaveChanges ScriptMethod, so no test ever touches the real
        event log.
    .OUTPUTS
        System.String. One of 'AlreadyEnabled', 'Enabled', or 'Skipped' (the log was disabled
        but -WhatIf suppressed the change).
    .EXAMPLE
        Enable-TaskSchedulerHistory

        Enables the log if it is disabled; does nothing if it is already enabled.
    .EXAMPLE
        Enable-TaskSchedulerHistory -WhatIf

        Reports what would change without enabling anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $logConfig = Get-TaskSchedulerHistoryLog

    if ($logConfig.IsEnabled) {
        return 'AlreadyEnabled'
    }

    if ($PSCmdlet.ShouldProcess('Microsoft-Windows-TaskScheduler/Operational', 'Enable event log')) {
        $logConfig.IsEnabled = $true
        $logConfig.SaveChanges()
        return 'Enabled'
    }

    return 'Skipped'
}
