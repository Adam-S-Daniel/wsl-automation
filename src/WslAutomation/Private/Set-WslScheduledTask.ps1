function Set-WslScheduledTask {
    <#
    .SYNOPSIS
        Thin wrapper around Set-ScheduledTask.
    .DESCRIPTION
        Set-ScheduledTask is a cmdletized (CDXML) command whose -Action/-Trigger/-Settings/
        -Principal parameters are strongly typed to CimInstance/CimInstance[] on Windows. Their
        dynamic-parameter binding does not mock reliably under Pester 5.7.1 (binding throws when
        a test's fake object is passed in place of a real CimInstance), even though the exact
        same mock works under Pester 6.0.0. This private seam exists so
        Set-WslAutomationScheduledTasks can be tested by mocking a plain function (this one)
        instead of the real Set-ScheduledTask, mirroring the Invoke-WslExe pattern used for
        wsl.exe.
    .PARAMETER TaskName
        Name of the scheduled task to update.
    .PARAMETER Action
        Scheduled task action object, as returned by New-ScheduledTaskAction.
    .PARAMETER Trigger
        Scheduled task trigger object(s), as returned by New-ScheduledTaskTrigger.
    .PARAMETER Settings
        Scheduled task settings object, as returned by New-ScheduledTaskSettingsSet.
    .PARAMETER Principal
        Scheduled task principal object, as returned by New-ScheduledTaskPrincipal.
    .EXAMPLE
        Set-WslScheduledTask -TaskName 'Example' -Action $action -Trigger $trigger -Settings $settings -Principal $principal
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,

        $Action,

        $Trigger,

        $Settings,

        $Principal
    )

    if ($PSCmdlet.ShouldProcess($TaskName, 'Set scheduled task')) {
        # -Trigger is omitted (not passed as $null) for an on-demand-only task such as the
        # interactive session launcher, which has no trigger to update.
        $setParams = @{
            TaskName  = $TaskName
            Action    = $Action
            Settings  = $Settings
            Principal = $Principal
        }
        if ($null -ne $Trigger) {
            $setParams['Trigger'] = $Trigger
        }

        Set-ScheduledTask @setParams | Out-Null
    }
}
