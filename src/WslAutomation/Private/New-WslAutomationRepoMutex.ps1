function Get-WslAutomationRepoMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    # Global on Windows: interactive backup and S4U tasks run in different sessions.
    $canonicalPath = [IO.Path]::GetFullPath($RepoPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($IsWindows) { $canonicalPath = $canonicalPath.ToUpperInvariant() }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($canonicalPath)))
    $prefix = if ($IsWindows) { 'Global\' } else { '' }
    "${prefix}WslAutomationRepoUpdate-$digest"
}

function New-WslAutomationRepoMutex {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RepoPath)

    if (-not $PSCmdlet.ShouldProcess('checkout update lock', 'Create mutex')) { throw 'lock creation skipped' }
    [Threading.Mutex]::new($false, (Get-WslAutomationRepoMutexName -RepoPath $RepoPath))
}
