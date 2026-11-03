function ConvertTo-WslLocalTimeTrigger {
    <#
    .SYNOPSIS
        Rewrites a scheduled task trigger's StartBoundary as local wall-clock time.
    .DESCRIPTION
        New-ScheduledTaskTrigger in PowerShell 7 writes StartBoundary in UTC ('...Z'), and Task
        Scheduler stores it with the UTC offset in effect at registration ('...-04:00'). A
        boundary with an offset is "synchronized across time zones": it fires at that fixed UTC
        instant, so a daily task registered during daylight time runs an hour early in local
        time after the clocks fall back, and an hour late after they spring forward. A boundary
        with no offset is local time and keeps its wall-clock time across the change.

        The boundary is converted to the local time it names and written back without an
        offset. A boundary that already has none is left unchanged. The
        trigger is modified in place and passed through.
    .PARAMETER Trigger
        Scheduled task trigger object, as returned by New-ScheduledTaskTrigger.
    .EXAMPLE
        $trigger = New-ScheduledTaskTrigger -Daily -At '12:37' | ConvertTo-WslLocalTimeTrigger
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Trigger
    )

    process {
        $property = $Trigger.PSObject.Properties['StartBoundary']
        # Only a boundary with a 'Z' or '+hh:mm' suffix is rewritten. One without is already local
        # and is kept as written: parsing it could move a time that does not exist locally (one
        # inside the spring-forward gap) by an hour.
        if ($null -ne $property -and [string]$property.Value -match '(Z|[+-]\d{2}:\d{2})$') {
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $instant = [System.DateTimeOffset]::Parse($property.Value, $culture)
            $Trigger.StartBoundary = $instant.LocalDateTime.ToString('yyyy-MM-ddTHH:mm:ss', $culture)
        }
        $Trigger
    }
}
