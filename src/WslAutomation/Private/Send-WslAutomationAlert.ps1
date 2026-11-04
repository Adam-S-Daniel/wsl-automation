function Send-WslAutomationAlert {
    <#
    .SYNOPSIS
        Alerts the owner through a toast and a self-alert email.
    .DESCRIPTION
        Shows a toast (Show-WslAutomationToast) and dispatches the fastmail-actions self-alert
        workflow with gh (Invoke-GhExe, an argument array - never a shell string). Each channel
        is attempted independently and logs one outcome-only line to -LogFile. The gh output is
        never logged: it could carry an HTTP error body. Never throws.

        The email workflow lives in a public repository, so the subject and body must be fixed
        text that carries no host name, user name or log text; the caller owns that.
    .PARAMETER Subject
        Toast message and email subject.
    .PARAMETER Body
        Email body.
    .PARAMETER LogFile
        Log file that receives the per-channel outcome lines.
    .PARAMETER WorkflowRepo
        Repository that owns the email workflow. Defaults to 'Adam-S-Daniel/fastmail-actions'.
    .PARAMETER WorkflowFile
        Workflow file to dispatch. Defaults to 'send-self-alert.yml'.
    .EXAMPLE
        Send-WslAutomationAlert -Subject 'Something broke' -Body 'Details.' -LogFile $logFile
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$Body,

        [Parameter(Mandatory)]
        [string]$LogFile,

        [string]$WorkflowRepo = 'Adam-S-Daniel/fastmail-actions',

        [string]$WorkflowFile = 'send-self-alert.yml'
    )

    $toastOk = $false
    try {
        $toastOk = [bool](Show-WslAutomationToast -Title 'Docker WSL integration' -Message $Subject)
    }
    catch {
        $toastOk = $false
    }
    $toastOutcome = if ($toastOk) { 'ok' } else { 'failed' }
    Write-WslAutomationLog -Message "alert toast: $toastOutcome" -LogFile $LogFile

    $emailOk = $false
    $emailExitCode = -1
    try {
        $ghResult = Invoke-GhExe -Arguments @('workflow', 'run', $WorkflowFile, '--repo', $WorkflowRepo, '-f', "subject=$Subject", '-f', "body=$Body")
        $emailExitCode = $ghResult.ExitCode
        $emailOk = ($emailExitCode -eq 0)
    }
    catch {
        $emailOk = $false
    }
    $emailOutcome = if ($emailOk) { 'dispatched' } else { "failed (exit $emailExitCode)" }
    Write-WslAutomationLog -Message "alert email: $emailOutcome" -LogFile $LogFile

    [pscustomobject]@{ Toast = $toastOk; Email = $emailOk }
}
