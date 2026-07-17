function Write-WslAutomationLog {
    <#
    .SYNOPSIS
        Appends a timestamped line to a WSL Automation log file.
    .DESCRIPTION
        Ensures the log file's parent directory exists, rotates the log file when it exceeds
        MaxSizeMB by renaming it to '<LogFile>.1' (overwriting any previous rotation), appends
        the formatted log line, and echoes the same line via Write-Information.
    .PARAMETER Message
        The message text to log.
    .PARAMETER LogFile
        Full path to the log file.
    .PARAMETER MaxSizeMB
        Rotate the log when its size exceeds this many megabytes. 0 disables rotation. Default 10.
    .EXAMPLE
        Write-WslAutomationLog -Message 'Starting backup' -LogFile 'C:\logs\backup.log'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$LogFile,

        [int]$MaxSizeMB = 10
    )

    $parent = Split-Path -Path $LogFile -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($MaxSizeMB -gt 0 -and (Test-Path -LiteralPath $LogFile)) {
        $existing = Get-Item -LiteralPath $LogFile
        if ($existing.Length -gt ($MaxSizeMB * 1MB)) {
            $rotatedPath = "$LogFile.1"
            Move-Item -LiteralPath $LogFile -Destination $rotatedPath -Force
        }
    }

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    Write-Information -MessageData $line -InformationAction Continue
}
