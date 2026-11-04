function Invoke-DockerDesktopCli {
    <#
    .SYNOPSIS
        Invokes docker.exe and captures its exit code and output.
    .DESCRIPTION
        This is the ONLY function in the module allowed to invoke docker.exe directly. Every other
        function must call through Invoke-DockerDesktopCli so tests have a single mock seam and
        nothing ever calls the real docker.exe from automated tests.

        Never throws. When docker.exe cannot be found (Docker Desktop is not installed, or its
        CLI is not on PATH) it returns ExitCode 127 and empty Output; a failure to start the
        process returns ExitCode 126.
    .PARAMETER Arguments
        Arguments to pass to docker.exe.
    .EXAMPLE
        Invoke-DockerDesktopCli -Arguments @('desktop', 'status', '--format', 'json')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $docker) {
        return [pscustomobject]@{ ExitCode = 127; Output = @() }
    }

    try {
        $rawOutput = & $docker.Source @Arguments 2>&1
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
