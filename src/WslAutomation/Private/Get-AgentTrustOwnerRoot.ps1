function Get-AgentTrustOwnerRoot {
    <#
    .SYNOPSIS
        Returns the owner roots for agent workspace trust from the one configured value.
    .DESCRIPTION
        The roots come from the environment variable WSL_AUTOMATION_AGENT_OWNER_ROOTS, a list
        separated by [System.IO.Path]::PathSeparator (';' on Windows, ':' elsewhere). There is no
        built-in value on any platform: when the variable is unset or has no entries this throws
        a terminating error that names the variable and the -OwnerRoot parameter.
    .PARAMETER Value
        The raw variable text. Defaults to the environment variable; tests pass it explicitly.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$Value = $env:WSL_AUTOMATION_AGENT_OWNER_ROOTS
    )

    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $roots = @($Value.Split([System.IO.Path]::PathSeparator, [System.StringSplitOptions]::RemoveEmptyEntries -bor [System.StringSplitOptions]::TrimEntries))
    }
    if ($roots.Count -eq 0) {
        $separator = [System.IO.Path]::PathSeparator
        $example = if ($IsWindows) { 'C:\src\<owner>' } else { '~/src' }
        throw ("No agent trust owner roots are configured. Pass -OwnerRoot, or set the environment variable " +
            "WSL_AUTOMATION_AGENT_OWNER_ROOTS to the folders that hold your clones, separated by '$separator', " +
            "for example $example (on Windows: [Environment]::SetEnvironmentVariable('WSL_AUTOMATION_AGENT_OWNER_ROOTS', 'C:\src\<owner>', 'User'), " +
            "then start a new terminal).")
    }
    return $roots
}
