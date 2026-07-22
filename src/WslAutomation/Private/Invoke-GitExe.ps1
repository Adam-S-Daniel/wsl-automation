function Invoke-GitExe {
    <#
    .SYNOPSIS
        Invokes git.exe and captures its exit code and output.
    .DESCRIPTION
        This is the ONLY function in the module allowed to invoke git.exe directly. Every other
        function must call through Invoke-GitExe so tests have a single mock seam and nothing
        ever calls the real git.exe from automated tests.
    .PARAMETER Arguments
        Arguments to pass to git.exe.
    .PARAMETER RepoPath
        When given, prepended as `-C <RepoPath>` so git operates against that repository
        regardless of the current working directory.
    .EXAMPLE
        Invoke-GitExe -RepoPath 'C:\repo' -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$RepoPath
    )

    $gitArgs = @()
    if ($RepoPath) {
        $gitArgs += @('-C', $RepoPath)
    }
    $gitArgs += $Arguments

    $savedPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $raw = & git @gitArgs 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $savedPreference
    }

    $output = @()
    foreach ($item in $raw) {
        $line = "$item"
        if ($line -ne '') {
            $output += $line
        }
    }

    [pscustomobject]@{
        ExitCode = $exit
        Output   = $output
    }
}
