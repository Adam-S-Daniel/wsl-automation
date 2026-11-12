function Invoke-ClaudeSettingsSyncScript {
    <#
    .SYNOPSIS
        Runs Sync-ClaudeSettings.ps1 in its own pwsh and captures its exit code and output.
    .DESCRIPTION
        The module's seam for the settings sync script, so tests never run the real one.
        Arguments never pass through a shell.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & $PwshPath @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output | ForEach-Object { "$_" })
    }
}
