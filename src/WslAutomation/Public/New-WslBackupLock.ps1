function New-WslBackupLock {
    <#
    .SYNOPSIS
        Creates a WSL backup lock file recording the current process and start time.
    .DESCRIPTION
        Writes a JSON lock file so other WSL Automation functions (for example the Claude Code
        session keeper) can detect that a backup is in progress and avoid interfering with WSL
        while an export is running.
    .PARAMETER LockPath
        Path to the lock file. Defaults to Get-WslBackupLockPath.
    .PARAMETER DistroName
        Name of the WSL distro being backed up.
    .EXAMPLE
        New-WslBackupLock -DistroName 'Ubuntu'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LockPath = (Get-WslBackupLockPath),

        [Parameter(Mandatory)]
        [string]$DistroName
    )

    $parent = Split-Path -Path $LockPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $lockData = [pscustomobject]@{
        ProcessId  = $PID
        StartedUtc = (Get-Date).ToUniversalTime().ToString('o')
        DistroName = $DistroName
    }

    if ($PSCmdlet.ShouldProcess($LockPath, 'Create WSL backup lock file')) {
        $lockData | ConvertTo-Json | Set-Content -LiteralPath $LockPath -Encoding utf8
    }

    return $LockPath
}
