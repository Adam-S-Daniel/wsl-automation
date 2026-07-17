#requires -Version 7.6
<#
.SYNOPSIS
    Runs "git pull" against a local repository and logs the result.

.DESCRIPTION
    Generalized repo puller: runs 'git -C <RepoPath> pull', captures its combined
    stdout/stderr output, and appends a timestamped block recording the attempt to a per-repo
    log file under LogDir. Not tied to any single project, so the same script can be used to
    keep this repository, or any other local git checkout, up to date from a scheduled task.

.PARAMETER RepoPath
    Path to the local git working copy to pull.

.PARAMETER LogDir
    Directory the per-repo pull log is written to. Defaults to a 'wsl-automation\logs' folder
    under the current user's local application data directory.

.EXAMPLE
    ./pull-repo.ps1 -RepoPath 'C:\Users\<you>\repos\some-project'

    Pulls the repository and appends the result to
    %LOCALAPPDATA%\wsl-automation\logs\pull-some-project.log
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoPath,

    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PullRepoLogLine {
    <#
    .SYNOPSIS
        Appends one timestamped line to the given pull log file and echoes it.
    .PARAMETER Message
        The message text to log.
    .PARAMETER LogFile
        Full path to the log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$LogFile
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    Write-Information -MessageData $line -InformationAction Continue
}

try {
    $repoName = Split-Path -Path ($RepoPath.TrimEnd('\', '/')) -Leaf
    $logFile = Join-Path $LogDir "pull-$repoName.log"
    $logFileParent = Split-Path -Path $logFile -Parent

    if ($logFileParent -and -not (Test-Path -LiteralPath $logFileParent)) {
        New-Item -ItemType Directory -Path $logFileParent -Force | Out-Null
    }

    Write-PullRepoLogLine -Message "=== git pull starting (repo=$RepoPath) ===" -LogFile $logFile

    # Native "git pull" exit codes must be handled ourselves rather than promoted to a
    # terminating PowerShell error, so a failed pull is still fully logged before we throw.
    $previousNativeErrorPref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $pullOutput = & git -C $RepoPath pull 2>&1
        $pullExitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPref
    }

    foreach ($outputLine in $pullOutput) {
        $trimmedLine = "$outputLine".Trim()
        if ($trimmedLine) {
            Write-PullRepoLogLine -Message "  git: $trimmedLine" -LogFile $logFile
        }
    }

    if ($pullExitCode -ne 0) {
        Write-PullRepoLogLine -Message "ERROR: git pull failed (exit $pullExitCode)" -LogFile $logFile
        throw "git pull failed for '$RepoPath' (exit $pullExitCode)"
    }

    Write-PullRepoLogLine -Message '=== Done ===' -LogFile $logFile

    exit 0
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}
