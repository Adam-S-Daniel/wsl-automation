function Grant-CodexProjectTrust {
    <#
    .SYNOPSIS
        Marks project paths as trusted in a Codex config.toml.
    .DESCRIPTION
        Applies Get-CodexTrustedText for each key and writes the file back only when something
        changed, preserving its BOM and newline style (default LF). A missing file is created
        when its directory exists; when the directory is missing Codex is skipped. Returns the
        keys that were changed.
    .PARAMETER ConfigPath
        Path of the Codex config.toml.
    .PARAMETER Key
        Project paths (Windows form and WSL form both belong here).
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        'PSShouldProcess',
        '',
        Justification = 'ShouldProcess is delegated to Write-AgentTrustFile, which receives -WhatIf.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string[]]$Key
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $hasBom = $false
    $text = ''
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $original = [System.IO.File]::ReadAllBytes($ConfigPath)
        $hasBom = $original.Length -ge 3 -and $original[0] -eq 0xEF -and $original[1] -eq 0xBB -and $original[2] -eq 0xBF
        $skip = if ($hasBom) { 3 } else { 0 }
        $text = $utf8.GetString($original, $skip, $original.Length - $skip)
    }
    else {
        $directory = Split-Path -Path $ConfigPath -Parent
        if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
            Write-Verbose "Codex config directory not found, skipping: $ConfigPath"
            return
        }
    }

    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

    $changed = @()
    $updated = $text
    foreach ($k in $Key) {
        $next = Get-CodexTrustedText -Text $updated -Path $k -NewLine $newLine
        if ($next -cne $updated) {
            $updated = $next
            $changed += $k
        }
    }

    if ($changed.Count -eq 0) {
        return
    }

    $bytes = [byte[]]@()
    if ($hasBom) { $bytes += [byte[]](0xEF, 0xBB, 0xBF) }
    $bytes += $utf8.GetBytes($updated)
    if (Write-AgentTrustFile -Path $ConfigPath -Bytes $bytes -WhatIf:$WhatIfPreference) {
        $changed
    }
}
