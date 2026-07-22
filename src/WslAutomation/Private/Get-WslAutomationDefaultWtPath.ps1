function Get-WslAutomationDefaultWtPath {
    <#
    .SYNOPSIS
        Resolves a default wt.exe (Windows Terminal) path for scheduled task registration that
        survives Windows Terminal package updates.
    .DESCRIPTION
        Store-installed Windows Terminal publishes a stable per-user execution alias at
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" that is preserved across package
        updates, mirroring the pwsh.exe alias (see Get-WslAutomationDefaultPwshPath). Prefer that
        stable alias when it exists; otherwise fall back to whatever 'wt.exe' resolves to on PATH,
        or the bare name 'wt.exe' if it cannot be resolved (so the launcher task still has a
        plausible executable to run).
    .EXAMPLE
        Get-WslAutomationDefaultWtPath
    #>
    [CmdletBinding()]
    param()

    $stableAliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $stableAliasPath) {
        return $stableAliasPath
    }

    $resolvedPath = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    if ($resolvedPath) {
        return $resolvedPath
    }

    return 'wt.exe'
}
