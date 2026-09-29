function Get-CodexTrustedText {
    <#
    .SYNOPSIS
        Returns TOML text in which the [projects.<path>] table has trust_level = "trusted".
    .DESCRIPTION
        Text-level editor (no TOML library is available). Finds the table header for the path
        in either basic-string (backslashes doubled) or literal-string spelling. If found, an
        untrusted trust_level line is replaced, or a missing one inserted after the header. If
        not found, a new table is appended. Everything else is preserved byte for byte, and the
        newline style given by -NewLine is used for anything added. Returns the input unchanged
        when the path is already trusted.
    .PARAMETER Text
        Current file content (may be empty).
    .PARAMETER Path
        The project path, exactly as it should appear in the key.
    .PARAMETER NewLine
        LF or CRLF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$NewLine = "`n"
    )

    $basicKey = '"' + $Path.Replace('\', '\\').Replace('"', '\"') + '"'
    $literalKey = "'" + $Path + "'"
    $headerPattern = '^\s*\[\s*projects\s*\.\s*(?:' + [regex]::Escape($basicKey) + '|' +
        [regex]::Escape($literalKey) + ')\s*\]\s*(?:#.*)?$'
    $trustedLine = 'trust_level = "trusted"'
    $trustedValuePattern = '^\s*trust_level\s*=\s*(["' + "'" + '])trusted\1\s*(?:#.*)?$'

    # Each element keeps its own line terminator.
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($part in [regex]::Split($Text, '(?<=\n)')) {
        if ($part -ne '') { $lines.Add($part) }
    }

    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd("`r", "`n") -match $headerPattern) {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -ge 0) {
        $trustIndex = -1
        for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
            $content = $lines[$i].TrimEnd("`r", "`n")
            if ($content -match '^\s*\[') { break }
            if ($content -match '^\s*trust_level\s*=') { $trustIndex = $i; break }
        }

        if ($trustIndex -ge 0) {
            $content = $lines[$trustIndex].TrimEnd("`r", "`n")
            if ($content -match $trustedValuePattern) {
                return $Text
            }
            $eol = $lines[$trustIndex].Substring($content.Length)
            $lines[$trustIndex] = $trustedLine + $eol
        }
        else {
            if (-not $lines[$headerIndex].EndsWith("`n")) {
                $lines[$headerIndex] += $NewLine
            }
            $lines.Insert($headerIndex + 1, $trustedLine + $NewLine)
        }
        return -join $lines
    }

    $newKey = if ($Path.Contains("'")) { $basicKey } else { $literalKey }
    $prefix = ''
    if ($Text.Length -gt 0) {
        if (-not $Text.EndsWith("`n")) { $prefix = $NewLine }
        $prefix += $NewLine
    }
    return $Text + $prefix + "[projects.$newKey]" + $NewLine + $trustedLine + $NewLine
}
