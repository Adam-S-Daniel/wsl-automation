function Set-CcstatuslineStatusLine {
    <#
    .SYNOPSIS
        Points Windows Claude Code's statusLine at the Windows ccstatusline runtime.
    .DESCRIPTION
        Claude Code's statusLine is a per-OS command: the WSL entry points at a Linux path, so it
        cannot be copied to Windows (the settings sync skill deliberately never does). This adds
        the Windows entry to settings.json, which runs the ccstatusline.exe shim that
        `bun add -g ccstatusline` creates.

        Every other key in the file, and its order, is preserved, as are the file's UTF-8 BOM
        presence, newline style (CRLF or LF) and trailing newline. A file that already exists is
        backed up next to itself before it is changed. env.CCSTATUSLINE_WIDTH is added when that
        env key is absent (Windows needs a fixed width; WSL auto-detects it) and an existing
        value is never changed.

        Returns a [pscustomobject] with Status, SettingsPath and BackupPath (the backup file, or
        $null when none was made). Status is one of:
          - SettingsInvalid: the file exists but is not a JSON object (or its env is not an
            object). Nothing was written.
          - Conflict: statusLine already holds a different value and -Force was not given.
            Nothing was written.
          - AlreadySet: statusLine already equals the desired value and the width is set;
            nothing was written.
          - Updated: the file was created or rewritten.
          - Skipped: a change was needed but declined, for example because of -WhatIf.
    .PARAMETER SettingsPath
        Windows Claude Code settings file. Defaults to "$env:USERPROFILE\.claude\settings.json".
    .PARAMETER Command
        The statusLine command. Defaults to the bun global bin shim under
        "$env:USERPROFILE\.bun\bin", written with forward slashes.
    .PARAMETER Padding
        statusLine padding. Defaults to 0, like the WSL entry.
    .PARAMETER RefreshInterval
        statusLine refreshInterval in seconds. Defaults to 20, like the WSL entry.
    .PARAMETER Width
        Value for env.CCSTATUSLINE_WIDTH, written only when that env key is absent. Defaults to
        '130'.
    .PARAMETER Force
        Replace an existing statusLine that differs from the desired one. A backup is still
        taken first.
    .EXAMPLE
        Set-CcstatuslineStatusLine

        Adds the default Windows statusLine to the current user's Claude Code settings.
    .EXAMPLE
        Set-CcstatuslineStatusLine -Force -WhatIf

        Shows whether a differing statusLine would be replaced, without writing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),

        # Forward slashes so the path survives whichever shell Claude Code runs the status-line
        # command through (Git Bash treats backslashes as escapes).
        [string]$Command = ((Join-Path $env:USERPROFILE '.bun\bin\ccstatusline.exe') -replace '\\', '/'),

        [int]$Padding = 0,

        [int]$RefreshInterval = 20,

        [string]$Width = '130',

        [switch]$Force
    )

    $desired = [ordered]@{
        type            = 'command'
        command         = $Command
        padding         = $Padding
        refreshInterval = $RefreshInterval
    }

    $fileExists = Test-Path -LiteralPath $SettingsPath -PathType Leaf
    $hadBom = $false
    $newline = "`r`n"
    $hadTrailingNewline = $true
    $settings = [ordered]@{}

    if ($fileExists) {
        $bytes = [System.IO.File]::ReadAllBytes($SettingsPath)
        $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $offset = if ($hadBom) { 3 } else { 0 }
        $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes, $offset, $bytes.Length - $offset)
        $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $hadTrailingNewline = $text.EndsWith("`n")

        try {
            # -DateKind String keeps ISO-date-looking values as the exact strings they were on disk.
            $settings = $text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -ErrorAction Stop
        }
        catch {
            $settings = $null
        }
        if ($settings -isnot [System.Collections.IDictionary] -or
            ($settings.Contains('env') -and $settings['env'] -isnot [System.Collections.IDictionary])) {
            return [pscustomobject]@{ Status = 'SettingsInvalid'; SettingsPath = $SettingsPath; BackupPath = $null }
        }
    }

    $statusLineMatches = $false
    if ($settings.Contains('statusLine')) {
        $existing = $settings['statusLine']
        if ($existing -is [System.Collections.IDictionary] -and $existing.Count -eq $desired.Count) {
            $statusLineMatches = $true
            foreach ($key in $desired.Keys) {
                if (-not $existing.Contains($key) -or "$($existing[$key])" -cne "$($desired[$key])") {
                    $statusLineMatches = $false
                    break
                }
            }
        }
        if (-not $statusLineMatches -and -not $Force) {
            return [pscustomobject]@{ Status = 'Conflict'; SettingsPath = $SettingsPath; BackupPath = $null }
        }
    }

    $hasWidth = $settings.Contains('env') -and $settings['env'].Contains('CCSTATUSLINE_WIDTH')
    if ($statusLineMatches -and $hasWidth) {
        return [pscustomobject]@{ Status = 'AlreadySet'; SettingsPath = $SettingsPath; BackupPath = $null }
    }

    if (-not $PSCmdlet.ShouldProcess($SettingsPath, 'Set the ccstatusline statusLine')) {
        return [pscustomobject]@{ Status = 'Skipped'; SettingsPath = $SettingsPath; BackupPath = $null }
    }

    $backupPath = $null
    if ($fileExists) {
        # Same <yyyyMMdd-HHmmss>-ET-<name>.bak naming (US Eastern time) as the
        # sync-cc-settings-between-wsl-and-windows skill, so its backups and this one sort together.
        $eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
        $stamp = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $eastern).ToString('yyyyMMdd-HHmmss')
        $backupPath = Join-Path (Split-Path -Path $SettingsPath -Parent) "$stamp-ET-settings.json.bak"
        Copy-Item -LiteralPath $SettingsPath -Destination $backupPath -Force
    }
    else {
        $settingsParent = Split-Path -Path $SettingsPath -Parent
        if ($settingsParent -and -not (Test-Path -LiteralPath $settingsParent)) {
            New-Item -ItemType Directory -Path $settingsParent -Force | Out-Null
        }
    }

    $settings['statusLine'] = $desired
    if (-not $settings.Contains('env')) {
        $settings['env'] = [ordered]@{}
    }
    if (-not $settings['env'].Contains('CCSTATUSLINE_WIDTH')) {
        $settings['env']['CCSTATUSLINE_WIDTH'] = $Width
    }

    $json = ($settings | ConvertTo-Json -Depth 100).TrimEnd("`r", "`n") -replace "\r?\n", $newline
    if ($hadTrailingNewline) {
        $json += $newline
    }
    [System.IO.File]::WriteAllText($SettingsPath, $json, [System.Text.UTF8Encoding]::new($hadBom))

    return [pscustomobject]@{ Status = 'Updated'; SettingsPath = $SettingsPath; BackupPath = $backupPath }
}
