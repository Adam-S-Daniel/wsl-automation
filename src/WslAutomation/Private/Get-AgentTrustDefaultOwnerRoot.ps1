function Get-AgentTrustDefaultOwnerRoot {
    <#
    .SYNOPSIS
        Returns the default owner roots for agent workspace trust on this platform.
    .DESCRIPTION
        Windows: D:\repos\adam-s-daniel and D:\repos\jodidaniel. Anywhere else (WSL/Linux, where
        clones live flat under ~/repos): the single directory ~/repos.
    .PARAMETER IsWindowsHost
        Which platform to answer for. Defaults to $IsWindows; tests pass it explicitly.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [bool]$IsWindowsHost = $IsWindows
    )

    if ($IsWindowsHost) {
        return @('D:\repos\adam-s-daniel', 'D:\repos\jodidaniel')
    }
    return @(Join-Path $HOME 'repos')
}
