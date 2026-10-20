function Get-WindowsProcessCommandLine {
    <#
    .SYNOPSIS
        Returns the command lines of the Windows processes with a given image name.
    .DESCRIPTION
        A thin seam over Get-CimInstance Win32_Process, so Test-ClaudeWindowsSession can be
        tested by mocking a plain function, the way Invoke-WslExe is. -Name is restricted to
        file-name characters by ValidatePattern, which keeps it safe to embed in the WQL
        filter. A process whose command line cannot be read yields nothing. Off Windows it
        returns an empty array.
    .PARAMETER Name
        Image name to match, for example 'claude.exe'.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+$')]
        [string]$Name
    )

    if (-not $IsWindows) {
        return , @()
    }

    return , @(
        Get-CimInstance -ClassName Win32_Process -Filter "Name = '$Name'" -ErrorAction Stop |
            ForEach-Object { $_.CommandLine } |
            Where-Object { $_ }
    )
}
