function Get-TaskSchedulerHistoryLog {
    <#
    .SYNOPSIS
        Returns the EventLogConfiguration object for the Task Scheduler operational log.
    .DESCRIPTION
        Thin wrapper around Get-WinEvent -ListLog for the
        Microsoft-Windows-TaskScheduler/Operational log. This is the ONLY function allowed to
        call Get-WinEvent for that log; Enable-TaskSchedulerHistory calls through this seam
        instead, mirroring the Invoke-WslExe pattern used for wsl.exe, so a test can mock this
        function to return a fake object (with a mockable IsEnabled property and a SaveChanges
        ScriptMethod) and never touch the real event log.
    .EXAMPLE
        Get-TaskSchedulerHistoryLog
    #>
    [CmdletBinding()]
    param()

    Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational'
}
