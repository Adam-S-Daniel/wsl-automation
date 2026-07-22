function Get-WslAutomationDefaultPwshPath {
    <#
    .SYNOPSIS
        Resolves a default pwsh.exe path for scheduled task registration that survives
        PowerShell package updates.
    .DESCRIPTION
        Prefers an MSI install of PowerShell 7 at "C:\Program Files\PowerShell\7\pwsh.exe". That
        path is both stable across updates AND launchable from the non-interactive session 0 used
        by the S4U session-keeper task. A Store (MSIX) PowerShell - whether via its per-user
        execution alias "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe" or its version-pinned
        package path - CANNOT be activated in session 0 (the task fails with access denied), so it
        is only a fallback here, suitable for the interactive backup task but not the background
        keeper. (Get-Command pwsh.exe).Source is the last resort and, on a Store-only machine,
        resolves to a version-pinned "C:\Program Files\WindowsApps\Microsoft.PowerShell_<ver>_..."
        path that is removed on the next package update; that case is warned about.
    .EXAMPLE
        Get-WslAutomationDefaultPwshPath
    #>
    [CmdletBinding()]
    param()

    $msiInstallPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $msiInstallPath) {
        return $msiInstallPath
    }

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
