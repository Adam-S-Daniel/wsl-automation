function Invoke-WslExe {
    <#
    .SYNOPSIS
        Invokes wsl.exe and captures its exit code and output.
    .DESCRIPTION
        This is the ONLY function in the module allowed to invoke wsl.exe directly. Every other
        function must call through Invoke-WslExe so tests have a single mock seam and nothing
        ever calls the real wsl.exe from automated tests.
    .PARAMETER Arguments
        Arguments to pass to wsl.exe.
    .EXAMPLE
        Invoke-WslExe -Arguments @('--list', '--verbose')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $savedEncoding = [Console]::OutputEncoding
    try {
        # wsl.exe's own management output (e.g. '--list --verbose', error text) is UTF-16LE.
        # Output passed through from a command run inside a distro (e.g.
        # 'wsl -d Ubuntu -- pgrep -af claude') is UTF-8, emitted by the Linux process itself.
        # Decoding everything here as UTF-8 leaves genuine UTF-8 passthrough output correct, and
        # turns each UTF-16LE management-output character into two characters - the original
        # ASCII byte followed by a NUL - rather than mojibake. Those NULs are stripped below, so
        # both output classes end up readable (verified against live wsl.exe).
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $rawOutput = & wsl.exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $savedEncoding
    }

    $output = @()
    foreach ($item in $rawOutput) {
        $line = $item.ToString() -replace "`0", ''
        if ($line -ne '') {
            $output += $line
        }
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}
