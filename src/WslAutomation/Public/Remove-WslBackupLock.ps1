function Remove-WslBackupLock {
    <#
    .SYNOPSIS
        Removes the WSL backup lock file if present.
    .DESCRIPTION
        Idempotent: does nothing, and never throws, when the lock file does not exist. Safe to
        call unconditionally from a finally block.
    .PARAMETER LockPath
        Path to the lock file. Defaults to Get-WslBackupLockPath.
    .EXAMPLE
        Remove-WslBackupLock
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LockPath = (Get-WslBackupLockPath)
    )

    if (Test-Path -LiteralPath $LockPath) {
        if ($PSCmdlet.ShouldProcess($LockPath, 'Remove WSL backup lock')) {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        }
    }
}
