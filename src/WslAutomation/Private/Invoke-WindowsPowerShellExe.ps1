function Invoke-WindowsPowerShellExe {
    <#
    .SYNOPSIS
        Invokes Windows PowerShell 5.1 (powershell.exe) and captures its exit code and output.
    .DESCRIPTION
        This is the ONLY function in the module allowed to invoke powershell.exe directly. It
        exists for the one job pwsh 7 cannot do: the Windows.UI.Notifications WinRT projection
        used for toasts is only available in Windows PowerShell 5.1. The child inherits this
        process's environment variables, which is how Show-WslAutomationToast hands it text
        without splicing the text into a command line.

        Never throws. When powershell.exe is missing it returns ExitCode 127 and empty Output; a
        failure to start the process returns ExitCode 126.
    .PARAMETER Arguments
        Arguments to pass to powershell.exe.
    .EXAMPLE
        Invoke-WindowsPowerShellExe -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath)) {
        return [pscustomobject]@{ ExitCode = 127; Output = @() }
    }

    try {
        $rawOutput = & $powerShellPath @Arguments 2>&1
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
