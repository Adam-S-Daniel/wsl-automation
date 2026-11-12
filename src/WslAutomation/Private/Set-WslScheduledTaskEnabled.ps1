function Set-WslScheduledTaskEnabled {
    <#
    .SYNOPSIS
        Thin wrapper around Enable-ScheduledTask and Disable-ScheduledTask.
    .DESCRIPTION
        Enable-ScheduledTask and Disable-ScheduledTask are cmdletized (CDXML) commands, so this
        private seam exists for the same reason as Register-WslScheduledTask and
        Set-WslScheduledTask: Set-WslAutomationScheduledTasks can be tested by mocking a plain
        function instead of the real cmdlets.
    .PARAMETER TaskName
        Name of the scheduled task to enable or disable.
    .PARAMETER Enabled
        $true to enable the task, $false to disable it.
    .EXAMPLE
        Set-WslScheduledTaskEnabled -TaskName 'Example' -Enabled $false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    $verb = if ($Enabled) { 'Enable scheduled task' } else { 'Disable scheduled task' }
    if ($PSCmdlet.ShouldProcess($TaskName, $verb)) {
        if ($Enabled) {
            Enable-ScheduledTask -TaskName $TaskName | Out-Null
        }
        else {
            Disable-ScheduledTask -TaskName $TaskName | Out-Null
        }
    }
}
