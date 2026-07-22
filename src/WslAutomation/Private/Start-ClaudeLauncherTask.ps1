function Start-ClaudeLauncherTask {
    <#
    .SYNOPSIS
        Triggers the on-demand scheduled task that opens an interactive Claude Code session.
    .DESCRIPTION
        The session keeper runs as a background (session 0) scheduled task so its frequent
        "is a session already running?" check never flashes a window on the desktop. A
        background task cannot itself show a GUI on the user's desktop, so when it needs to
        launch a session it instead starts a separate, interactive on-demand task (registered
        by Set-WslAutomationScheduledTasks) that opens Windows Terminal in the user's session.

        This thin seam exists so Invoke-ClaudeSessionKeeper can be tested by mocking a plain
        function instead of the real Start-ScheduledTask, mirroring the Invoke-WslExe /
        Register-WslScheduledTask pattern used elsewhere in the module.
    .PARAMETER LauncherTaskName
        Name of the interactive launcher scheduled task to start.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$LauncherTaskName
    )

    if ($PSCmdlet.ShouldProcess($LauncherTaskName, 'Start scheduled task')) {
        Start-ScheduledTask -TaskName $LauncherTaskName
    }
}
