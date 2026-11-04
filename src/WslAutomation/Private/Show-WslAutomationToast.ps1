function Show-WslAutomationToast {
    <#
    .SYNOPSIS
        Shows a Windows toast notification in the signed-in user's session.
    .DESCRIPTION
        Runs a FIXED script in Windows PowerShell 5.1 (through Invoke-WindowsPowerShellExe) with
        -EncodedCommand. The title and message reach the child only through the environment
        variables WSL_AUTOMATION_TOAST_TITLE and WSL_AUTOMATION_TOAST_MESSAGE, which are set
        for the call and restored to their previous values afterward; they are never spliced into
        the script, so no text can change what the script does. The script XML-escapes both
        values before building the toast.

        Needs the user's interactive desktop, so it only displays when the calling task runs in
        the user's session (the Docker watchdog task is Interactive for this reason). Returns
        $true when the child exits 0, else $false. Never throws.
    .PARAMETER Title
        First line of the toast.
    .PARAMETER Message
        Second line of the toast.
    .EXAMPLE
        Show-WslAutomationToast -Title 'Docker WSL integration' -Message 'Ubuntu integration is broken'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message
    )

    # Fixed text: nothing from the caller is ever interpolated into it.
    $toastScript = @'
$ErrorActionPreference = 'Stop'
$title = [System.Security.SecurityElement]::Escape($env:WSL_AUTOMATION_TOAST_TITLE)
$message = [System.Security.SecurityElement]::Escape($env:WSL_AUTOMATION_TOAST_MESSAGE)
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>' + $title + '</text><text>' + $message + '</text></binding></visual></toast>')
$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
$notifier.Show($toast)
'@
    $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($toastScript))

    $titleVariable = 'WSL_AUTOMATION_TOAST_TITLE'
    $messageVariable = 'WSL_AUTOMATION_TOAST_MESSAGE'
    $previousTitle = [Environment]::GetEnvironmentVariable($titleVariable)
    $previousMessage = [Environment]::GetEnvironmentVariable($messageVariable)
    try {
        [Environment]::SetEnvironmentVariable($titleVariable, $Title)
        [Environment]::SetEnvironmentVariable($messageVariable, $Message)
        $result = Invoke-WindowsPowerShellExe -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedScript)
        return ($result.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        [Environment]::SetEnvironmentVariable($titleVariable, $previousTitle)
        [Environment]::SetEnvironmentVariable($messageVariable, $previousMessage)
    }
}
