function Get-WslAutomationDefaultPwshPath {
    <#
    .SYNOPSIS
        Resolves a default pwsh.exe path for scheduled task registration that survives
        PowerShell package updates.
    .DESCRIPTION
        Store-installed (MSIX) PowerShell publishes a stable per-user execution alias at
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe" that is preserved across package
        updates. (Get-Command pwsh.exe).Source instead resolves to a version-pinned directory
        such as "C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.3.0_x64__8wekyb3d8bbwe",
        which is removed the next time the package updates - breaking any scheduled task action
        that points directly at it. This helper prefers the stable alias when it exists, and
        warns when it has to fall back to a resolved path that still looks version-pinned.
    .EXAMPLE
        Get-WslAutomationDefaultPwshPath
    #>
    [CmdletBinding()]
    param()

    $stableAliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $stableAliasPath) {
        return $stableAliasPath
    }

    $resolvedPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    $versionPinnedRoot = Join-Path $env:ProgramFiles 'WindowsApps'
    if ($resolvedPath -and $resolvedPath.StartsWith($versionPinnedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning -Message ("Resolved pwsh.exe path '$resolvedPath' is a version-pinned Microsoft Store " +
            'package path and will break on the next PowerShell update. Pass -PwshPath explicitly with a ' +
            'stable path (for example the per-user WindowsApps alias, or an MSI install under ' +
            'C:\Program Files\PowerShell\7).')
    }

    return $resolvedPath
}
