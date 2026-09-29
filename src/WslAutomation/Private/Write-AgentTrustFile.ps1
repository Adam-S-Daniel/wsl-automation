function Write-AgentTrustFile {
    <#
    .SYNOPSIS
        Replaces a config file atomically after backing the original up.
    .DESCRIPTION
        Copies an existing file to "<Path>.bak-agent-trust" (a single backup, overwritten each
        time), writes the new bytes to "<Path>.tmp", then moves the temp file over the original.
        The caller decides the encoding by passing the bytes. Returns $true when written.
    .PARAMETER Path
        The file to replace or create.
    .PARAMETER Bytes
        The complete new content.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write agent trust config')) {
        return $false
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-agent-trust" -Force
    }
    $tmpPath = "$Path.tmp"
    [System.IO.File]::WriteAllBytes($tmpPath, $Bytes)
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    return $true
}
