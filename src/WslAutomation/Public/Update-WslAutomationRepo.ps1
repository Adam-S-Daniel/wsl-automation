function Update-WslAutomationRepo {
    <#
    .SYNOPSIS
        Best-effort self-update: fast-forwards the WslAutomation repo's working copy to origin.
    .DESCRIPTION
        Intended to be called at the start of every scheduled-task wrapper so scheduled runs
        always execute up-to-date code, without ever requiring a manual "git pull" on the
        machine. Real work (a fetch plus merge attempt) only happens at most once per
        -MinIntervalHours, tracked via a small JSON state file, so frequent callers (for example
        the session keeper, which runs every 5 minutes) do not hammer the remote or the disk.

        This function never throws. Any unexpected failure is caught, logged, and reported back
        as Status 'Error' so a self-update problem can never break the caller's own task.

        Returns a [pscustomobject] with Status, Branch, and RepoPath. Status is one of:
          - SkippedRecent: the last successful update was less than -MinIntervalHours ago; this
            run did nothing at all (not even a log line, to keep frequent callers' logs small).
          - Skipped: an update was due but declined, for example because of -WhatIf.
          - NotAGitRepo: -RepoPath is not (or is no longer) a git working copy.
          - NotOnBranch: the repo's current branch is not -Branch; left untouched.
          - WorkingTreeDirty: the repo has tracked (non-untracked) local modifications; left
            untouched rather than risking a merge over uncommitted work.
          - FetchFailed: `git fetch origin <Branch>` failed, for example no network. Success is
            not recorded, so the next call retries.
          - Updated: a fast-forward merge to origin/<Branch> succeeded.
          - Merged: the fast-forward failed but a regular merge to origin/<Branch> succeeded.
          - ConflictSkipped: the merge produced conflicts; the merge was aborted and the repo left
            unchanged. Success is not recorded, so the next call retries.
          - Error: an unexpected exception was caught; see the log file for details.
    .PARAMETER RepoPath
        Path to the git working copy to update.
    .PARAMETER MinIntervalHours
        Minimum time, in hours, between real update attempts. Defaults to 12.
    .PARAMETER Branch
        The branch expected to be checked out and kept current. Defaults to 'main'.
    .PARAMETER StateFile
        Path to the JSON file tracking the last successful update time. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\repo-update-state.json".
    .PARAMETER LogFile
        Path to this update's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\repo-update.log".
    .PARAMETER Now
        The reference instant used for the -MinIntervalHours gate and recorded on success.
        Defaults to the current time; primarily a test/override seam.
    .EXAMPLE
        Update-WslAutomationRepo -RepoPath 'C:\repo'

        Ensures 'main' is current in 'C:\repo', doing real work only if the last successful
        update was more than 12 hours ago.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,

        [int]$MinIntervalHours = 12,

        [string]$Branch = 'main',

        [string]$StateFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'repo-update-state.json'),

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'repo-update.log'),

        [datetime]$Now = (Get-Date)
    )

    try {
        $skipRecent = $false
        if (Test-Path -LiteralPath $StateFile) {
            try {
                $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
                if ($state.LastSuccessUtc) {
                    $lastSuccessUtc = ([datetime]$state.LastSuccessUtc).ToUniversalTime()
                    $elapsedHours = ($Now.ToUniversalTime() - $lastSuccessUtc).TotalHours
                    if ($elapsedHours -lt $MinIntervalHours) {
                        $skipRecent = $true
                    }
                }
            }
            catch {
                # State file missing/unparseable is non-fatal: treat as "no prior success" and proceed.
                Write-Verbose -Message "could not parse state file '$StateFile': $_"
            }
        }

        if ($skipRecent) {
            return [pscustomobject]@{ Status = 'SkippedRecent'; Branch = $Branch; RepoPath = $RepoPath }
        }

        if (-not $PSCmdlet.ShouldProcess($RepoPath, "Ensure '$Branch' is current")) {
            return [pscustomobject]@{ Status = 'Skipped'; Branch = $Branch; RepoPath = $RepoPath }
        }

        $branchResult = Invoke-GitExe -RepoPath $RepoPath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
        if ($branchResult.ExitCode -ne 0) {
            Write-WslAutomationLog -Message "'$RepoPath' is not a git repository" -LogFile $LogFile
            return [pscustomobject]@{ Status = 'NotAGitRepo'; Branch = $Branch; RepoPath = $RepoPath }
        }

        $currentBranch = "$($branchResult.Output | Select-Object -First 1)".Trim()
        if ($currentBranch -ne $Branch) {
            Write-WslAutomationLog -Message "'$RepoPath' is on branch '$currentBranch', not '$Branch'; skipping" -LogFile $LogFile
            return [pscustomobject]@{ Status = 'NotOnBranch'; Branch = $Branch; RepoPath = $RepoPath }
        }

        $statusResult = Invoke-GitExe -RepoPath $RepoPath -Arguments @('status', '--porcelain')
        $trackedChanges = @($statusResult.Output | Where-Object { -not "$_".StartsWith('??') })
        if ($trackedChanges.Count -gt 0) {
            Write-WslAutomationLog -Message "'$RepoPath' has a dirty working tree; skipping" -LogFile $LogFile
            return [pscustomobject]@{ Status = 'WorkingTreeDirty'; Branch = $Branch; RepoPath = $RepoPath }
        }

        $fetchResult = Invoke-GitExe -RepoPath $RepoPath -Arguments @('fetch', 'origin', $Branch)
        if ($fetchResult.ExitCode -ne 0) {
            Write-WslAutomationLog -Message "'$RepoPath': git fetch origin $Branch failed" -LogFile $LogFile
            return [pscustomobject]@{ Status = 'FetchFailed'; Branch = $Branch; RepoPath = $RepoPath }
        }

        $ffResult = Invoke-GitExe -RepoPath $RepoPath -Arguments @('merge', '--ff-only', "origin/$Branch")
        if ($ffResult.ExitCode -eq 0) {
            $successStatus = 'Updated'
        }
        else {
            $mergeResult = Invoke-GitExe -RepoPath $RepoPath -Arguments @('merge', "origin/$Branch")
            if ($mergeResult.ExitCode -eq 0) {
                $successStatus = 'Merged'
            }
            else {
                Invoke-GitExe -RepoPath $RepoPath -Arguments @('merge', '--abort') | Out-Null
                $conflictMessage = "'$RepoPath': merge conflict, left unchanged"
                Write-WslAutomationLog -Message $conflictMessage -LogFile $LogFile
                Write-Warning -Message $conflictMessage
                return [pscustomobject]@{ Status = 'ConflictSkipped'; Branch = $Branch; RepoPath = $RepoPath }
            }
        }

        $stateParent = Split-Path -Path $StateFile -Parent
        if ($stateParent -and -not (Test-Path -LiteralPath $stateParent)) {
            New-Item -ItemType Directory -Path $stateParent -Force | Out-Null
        }

        $stateObject = [pscustomobject]@{
            LastSuccessUtc = $Now.ToUniversalTime().ToString('o')
            Branch         = $Branch
        }
        $stateObject | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding utf8

        Write-WslAutomationLog -Message "ensured '$Branch' current ($successStatus)" -LogFile $LogFile
        return [pscustomobject]@{ Status = $successStatus; Branch = $Branch; RepoPath = $RepoPath }
    }
    catch {
        Write-WslAutomationLog -Message "unexpected error updating '$RepoPath': $_" -LogFile $LogFile
        return [pscustomobject]@{ Status = 'Error'; Branch = $Branch; RepoPath = $RepoPath }
    }
}
