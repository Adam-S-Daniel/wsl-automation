function Update-WslAutomationRepo {
    <#
    .SYNOPSIS
        Best-effort checkout of main followed by a fast-forward to origin/main.
    .DESCRIPTION
        Every call fetches origin under a per-checkout mutex. Local changes (including
        untracked files) and local commits are preserved. No regular merge, reset, stash,
        or clean is attempted. Git failures and lock contention warn and fail open.
        Changed tells entry scripts to reload their code, including after a branch switch.
        The former 12-hour state-file gate is intentionally removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'repo-update.log'),
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30,
        [ValidateRange(0, 30)][int]$LockTimeoutSeconds = 5
    )

    $result = [pscustomobject]@{ Status = 'Error'; Branch = 'main'; RepoPath = $RepoPath; Changed = $false }
    $mutex = $null
    $ownsMutex = $false
    try {
        if (-not $PSCmdlet.ShouldProcess($RepoPath, 'Update checkout to origin/main')) {
            $result.Status = 'Skipped'
            return $result
        }
        $mutex = New-WslAutomationRepoMutex -RepoPath $RepoPath
        try { $ownsMutex = $mutex.WaitOne($LockTimeoutSeconds * 1000) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) {
            $result.Status = 'LockBusy'
            throw 'another task is updating this checkout'
        }

        $gitParams = @{ RepoPath = $RepoPath; TimeoutSeconds = $TimeoutSeconds }
        $before = Invoke-GitExe @gitParams -Arguments @('rev-parse', 'HEAD')
        if ($before.ExitCode -ne 0) {
            $result.Status = 'NotAGitRepo'
            throw 'cannot read checkout HEAD'
        }
        $fetch = Invoke-GitExe @gitParams -Arguments @('fetch', 'origin')
        if ($fetch.ExitCode -ne 0) {
            $result.Status = 'FetchFailed'
            throw 'fetch failed or timed out'
        }
        $branch = Invoke-GitExe @gitParams -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
        $status = Invoke-GitExe @gitParams -Arguments @('status', '--porcelain')
        if ($branch.ExitCode -ne 0 -or $status.ExitCode -ne 0) { throw 'cannot inspect checkout' }
        if (@($status.Output).Count -gt 0) {
            $result.Status = 'WorkingTreeDirty'
            throw 'working tree is dirty; leaving it untouched'
        }
        if (($branch.Output | Select-Object -First 1) -ne 'main') {
            $result.Changed = $true
            $switch = Invoke-GitExe @gitParams -Arguments @('switch', 'main')
            if ($switch.ExitCode -ne 0) { throw 'cannot switch to main' }
        }
        $ancestor = Invoke-GitExe @gitParams -Arguments @('merge-base', '--is-ancestor', 'HEAD', 'origin/main')
        if ($ancestor.ExitCode -eq 1) {
            $result.Status = 'Diverged'
            throw 'main has local commits; skipping fast-forward'
        }
        if ($ancestor.ExitCode -ne 0) { throw 'cannot check fast-forward ancestry' }
        $result.Changed = $true
        $merge = Invoke-GitExe @gitParams -Arguments @('merge', '--ff-only', 'origin/main')
        if ($merge.ExitCode -ne 0) { throw 'fast-forward failed or timed out; no regular merge attempted' }
        # Conservatively reload if a later HEAD read fails after a successful merge.
        $result.Changed = $true
        $after = Invoke-GitExe @gitParams -Arguments @('rev-parse', 'HEAD')
        if ($after.ExitCode -ne 0) { throw 'cannot read updated HEAD' }
        $result.Changed = (($before.Output -join '') -ne ($after.Output -join '')) -or
            (($branch.Output | Select-Object -First 1) -ne 'main')
        $result.Status = 'Updated'
        Write-WslAutomationLog -Message 'ensured main current (fast-forward only)' -LogFile $LogFile
    }
    catch {
        # Git output and exception text can contain credential-bearing URLs. Log only a
        # fixed status; a failed log write must also leave the task free to continue.
        $message = "WARNING: checkout update skipped ($($result.Status)); continuing with current code"
        try { Write-WslAutomationLog -Message $message -LogFile $LogFile } catch { Write-Verbose 'checkout update log unavailable' }
        Write-Warning -Message $message
    }
    finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
    $result
}
