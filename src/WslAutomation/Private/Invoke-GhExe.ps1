function Invoke-GhExe {
    <#
    .SYNOPSIS
        Invokes gh.exe and captures its exit code and output.
    .DESCRIPTION
        This is the ONLY function in the module allowed to invoke gh.exe directly. Every other
        function must call through Invoke-GhExe so tests have a single mock seam and nothing ever
        calls the real gh.exe from automated tests.

        Never throws. When gh.exe cannot be found it returns ExitCode 127 and empty Output; a
        failure to start the process returns ExitCode 126. Callers must not log the Output: an
        HTTP error body can carry data that does not belong in a log.
    .PARAMETER Arguments
        Arguments to pass to gh.exe.
    .EXAMPLE
        Invoke-GhExe -Arguments @('auth', 'status')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
    if (-not $gh) {
        return [pscustomobject]@{ ExitCode = 127; Output = @() }
    }

    try {
        $rawOutput = & $gh.Source @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{ ExitCode = 126; Output = @() }
    }

    $output = @()
    foreach ($item in $rawOutput) {
        $line = $item.ToString()
        if ($line -ne '') {
            $output += $line
        }
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}
