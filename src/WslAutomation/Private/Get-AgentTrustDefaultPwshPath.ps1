function Get-AgentTrustDefaultPwshPath {
    <#
    .SYNOPSIS
        Resolves the pwsh the agent-trust git hook should run, preferring a path that survives updates.
    .DESCRIPTION
        Windows: Get-WslAutomationDefaultPwshPath. Elsewhere: the first EXISTING path among
        /usr/bin/pwsh, /usr/local/bin/pwsh, /snap/bin/pwsh and /opt/microsoft/powershell/7/pwsh,
        else the pwsh found on PATH. Under snap the PATH entry is version-pinned
        (/snap/powershell/<revision>/opt/powershell/pwsh) and vanishes on the next snap refresh,
        so falling back to one warns. Symlinks are deliberately not resolved: /snap/bin/pwsh is a
        symlink to the snap launcher and must be kept as-is.
    .PARAMETER IsWindowsHost
        Which platform to answer for. Defaults to $IsWindows; tests pass it explicitly.
    .PARAMETER Candidate
        Stable locations to probe, in order. Tests point these at files under $TestDrive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool]$IsWindowsHost = $IsWindows,

        [string[]]$Candidate = @('/usr/bin/pwsh', '/usr/local/bin/pwsh', '/snap/bin/pwsh', '/opt/microsoft/powershell/7/pwsh')
    )

    if ($IsWindowsHost) {
        return Get-WslAutomationDefaultPwshPath
    }

    foreach ($path in $Candidate) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    $resolved = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($resolved -and $resolved.StartsWith('/snap/', [System.StringComparison]::Ordinal) -and
        -not $resolved.StartsWith('/snap/bin/', [System.StringComparison]::Ordinal)) {
        Write-Warning -Message ("Resolved pwsh path '$resolved' is a version-pinned snap path and will break on the " +
            'next snap refresh. Pass -PwshPath explicitly with a stable path (for example /snap/bin/pwsh ' +
            'or /usr/bin/pwsh).')
    }
    return $resolved
}
