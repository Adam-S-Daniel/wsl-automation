function Grant-ClaudeProjectTrust {
    <#
    .SYNOPSIS
        Sets projects[<key>].hasTrustDialogAccepted = true in a Claude Code ~/.claude.json.
    .DESCRIPTION
        Parses the file with ConvertFrom-Json -AsHashtable -DateKind String, adds or updates the
        entry for each forward-slash key, and writes the file back (ConvertTo-Json -Depth 100)
        only when something changed. Date strings are kept as strings, because the default
        conversion would rewrite them in local time. All other fields of the file and of each
        entry are preserved. An entry stored under the backslash spelling of a path is not
        touched. A missing or unparseable file is skipped. Returns the keys that were changed.
    .PARAMETER ConfigPath
        Path of the .claude.json file. It is never created.
    .PARAMETER Key
        Project keys, forward-slash form (for example 'D:/repos/owner/repo').
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

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Verbose "Claude config not found, skipping: $ConfigPath"
        return
    }

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    }
    catch {
        Write-Warning "Claude config is not valid JSON, skipping: $ConfigPath"
        return
    }
    if ($config -isnot [System.Collections.IDictionary]) {
        Write-Warning "Claude config is not a JSON object, skipping: $ConfigPath"
        return
    }

    if ($config['projects'] -isnot [System.Collections.IDictionary]) {
        $config['projects'] = @{}
    }
    $projects = $config['projects']

    $changed = @()
    foreach ($k in $Key) {
        if ($projects[$k] -isnot [System.Collections.IDictionary]) {
            $projects[$k] = @{}
        }
        if ($projects[$k]['hasTrustDialogAccepted'] -ne $true) {
            $projects[$k]['hasTrustDialogAccepted'] = $true
            $changed += $k
        }
    }

    if ($changed.Count -eq 0) {
        return
    }

    $json = $config | ConvertTo-Json -Depth 100
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    if (Write-AgentTrustFile -Path $ConfigPath -Bytes $bytes -WhatIf:$WhatIfPreference) {
        $changed
    }
}
