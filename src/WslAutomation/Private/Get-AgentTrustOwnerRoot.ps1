function Get-AgentTrustOwnerRoot {
    <#
    .SYNOPSIS
        Returns the owner roots for agent workspace trust from the one configured value.
    .DESCRIPTION
        The roots are a list separated by [System.IO.Path]::PathSeparator (';' on Windows, ':'
        elsewhere). There is no built-in value on any platform. Where the list comes from:

          - Windows: the user environment variable WSL_AUTOMATION_AGENT_OWNER_ROOTS only. The
            settings file is never read there.
          - Linux, WSL and macOS: the same variable when it is set and non-empty, otherwise the
            key WSL_AUTOMATION_AGENT_OWNER_ROOTS in the settings file
            ${WSL_AUTOMATION_SETTINGS:-~/.config/wsl-automation/settings.env}, the file the Bash
            tasks use (scripts/task-settings.sh). The file is the place for it because the
            git post-checkout hook runs in whatever process runs git, and a non-interactive or
            long-running process never reads a shell profile.

        The file is read as data, never sourced: blank lines and # comments are skipped, every
        other line must be KEY=VALUE, the last assignment of the key wins, one pair of surrounding
        single or double quotes is removed, and a leading ~/ on an entry expands to $HOME/. Other
        values must be absolute paths. A missing, unreadable or malformed file counts as unset.

        When nothing is configured this throws a terminating error that names the -OwnerRoot
        parameter, the variable and the settings file path.
    .PARAMETER Value
        The raw variable text. Defaults to the environment variable; tests pass it explicitly.
    .PARAMETER SettingsPath
        The settings file to read off Windows. Defaults to $env:WSL_AUTOMATION_SETTINGS, else
        ~/.config/wsl-automation/settings.env.
    .PARAMETER IsWindowsHost
        Which platform to answer for. Defaults to $IsWindows; tests pass it explicitly.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$Value = $env:WSL_AUTOMATION_AGENT_OWNER_ROOTS,
        [string]$SettingsPath,
        [bool]$IsWindowsHost = $IsWindows
    )

    $key = 'WSL_AUTOMATION_AGENT_OWNER_ROOTS'
    $separator = [System.IO.Path]::PathSeparator
    $splitOptions = [System.StringSplitOptions]::RemoveEmptyEntries -bor [System.StringSplitOptions]::TrimEntries

    if (-not $IsWindowsHost -and [string]::IsNullOrWhiteSpace($SettingsPath)) {
        $SettingsPath = if ($env:WSL_AUTOMATION_SETTINGS) { $env:WSL_AUTOMATION_SETTINGS } else { Join-Path $HOME '.config/wsl-automation/settings.env' }
    }

    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $roots = @($Value.Split($separator, $splitOptions))
    }
    elseif (-not $IsWindowsHost) {
        $fileValue = $null
        try {
            if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
                $fileValue = $null
                $malformed = $false
                foreach ($line in [System.IO.File]::ReadAllLines($SettingsPath)) {
                    if ($line -match '^\s*(#.*)?$') { continue }
                    if ($line -notmatch '^([A-Z_][A-Z0-9_]*)=(.*)$') { $malformed = $true; break }
                    if ($Matches[1] -ceq $key) { $fileValue = $Matches[2] }
                }
                if ($malformed) { $fileValue = $null }
            }
        }
        catch { $fileValue = $null }

        if (-not [string]::IsNullOrWhiteSpace($fileValue)) {
            $fileValue = $fileValue.Trim()
            if ($fileValue.Length -ge 2 -and ($fileValue[0] -eq '"' -or $fileValue[0] -eq "'") -and $fileValue[-1] -eq $fileValue[0]) {
                $fileValue = $fileValue.Substring(1, $fileValue.Length - 2)
            }
            $roots = @($fileValue.Split($separator, $splitOptions) | ForEach-Object {
                    if ($_ -like '~/*') { Join-Path $HOME $_.Substring(2) } else { $_ }
                })
            foreach ($root in $roots) {
                if (-not [System.IO.Path]::IsPathRooted($root)) {
                    throw "$key in the settings file holds the relative path '$root'; use absolute paths (or a leading ~/)."
                }
            }
        }
    }
    if ($roots.Count -eq 0) {
        $example = if ($IsWindowsHost) { 'C:\src\<owner>' } else { '~/src' }
        $where = if ($IsWindowsHost) {
            "[Environment]::SetEnvironmentVariable('$key', 'C:\src\<owner>', 'User'), then start a new terminal"
        }
        else {
            $shown = if ($HOME -and $SettingsPath.StartsWith($HOME)) { '~' + $SettingsPath.Substring($HOME.Length) } else { $SettingsPath }
            "a line $key=$example in the settings file $shown (WSL_AUTOMATION_SETTINGS overrides the path; a shell profile is not read by non-interactive or long-running processes)"
        }
        throw ("No agent trust owner roots are configured. Pass -OwnerRoot, or set the environment variable " +
            "$key to the folders that hold your clones, separated by '$separator', for example $example; " +
            "on this platform: $where.")
    }
    return $roots
}
