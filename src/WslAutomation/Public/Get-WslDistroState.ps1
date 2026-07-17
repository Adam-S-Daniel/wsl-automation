function Get-WslDistroState {
    <#
    .SYNOPSIS
        Reports whether a WSL distro is Running, Stopped, or NotFound.
    .DESCRIPTION
        Parses the output of 'wsl.exe --list --verbose' (via Invoke-WslExe) to determine the
        current state of the named distro. This only reads state; it never boots a stopped
        distro as a side effect.
    .PARAMETER DistroName
        Name of the WSL distro to look up.
    .EXAMPLE
        Get-WslDistroState -DistroName 'Ubuntu'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )

    $result = Invoke-WslExe -Arguments @('--list', '--verbose')

    if ($result.ExitCode -ne 0) {
        return 'NotFound'
    }

    $dataLines = @($result.Output | Select-Object -Skip 1)

    foreach ($line in $dataLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') {
            continue
        }
        if ($trimmed.StartsWith('*')) {
            $trimmed = $trimmed.Substring(1).Trim()
        }

        $fields = $trimmed -split '\s+'
        if ($fields.Count -lt 3) {
            continue
        }

        $name = $fields[0]
        $state = $fields[1]

        if ($name -ieq $DistroName) {
            return $state
        }
    }

    return 'NotFound'
}
