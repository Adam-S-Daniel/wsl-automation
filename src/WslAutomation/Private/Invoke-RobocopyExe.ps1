function Invoke-RobocopyExe {
    <#
    .SYNOPSIS
        Invokes robocopy.exe and captures its exit code and output.
    .DESCRIPTION
        This is the ONLY function in the module allowed to invoke robocopy.exe directly. Every
        other function must call through Invoke-RobocopyExe so tests have a single mock seam and
        nothing ever runs the real robocopy.exe from automated tests.

        Robocopy's exit code is a bit field, not a plain success flag: 0-7 all mean success (1
        files copied, 2 extra files seen, 4 mismatches), and 8 or more means at least one copy
        failed. Interpreting it is left to the caller.
    .PARAMETER Arguments
        Arguments to pass to robocopy.exe.
    .EXAMPLE
        Invoke-RobocopyExe -Arguments @('D:\src', 'E:\dst', '/E')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $rawOutput = & robocopy.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    $output = @()
    foreach ($item in $rawOutput) {
        $line = "$item".Trim()
        if ($line -ne '') {
            $output += $line
        }
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}
