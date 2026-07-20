function Get-WslBackupLockPath {
    <#
    .SYNOPSIS
        Returns the default path used for the WSL backup lock file.
    .DESCRIPTION
        The lock file lives under the current user's local application data folder so it never
        requires elevation and is scoped to the current user.
    .EXAMPLE
        Get-WslBackupLockPath
    #>
    [CmdletBinding()]
    param()

    Join-Path -Path $env:LOCALAPPDATA -ChildPath 'wsl-automation' -AdditionalChildPath 'backup.lock'
}
