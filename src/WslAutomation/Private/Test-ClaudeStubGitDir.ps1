function Test-ClaudeStubGitDir {
    <#
    .SYNOPSIS
        Warns when ~/repos holds a .git that is not a real git repository.
    .DESCRIPTION
        Used by Invoke-ClaudeSessionKeeper on every run. ~/repos is the folder of clones that
        'claude rc' (the Claude Code Remote Control server) runs in, and it is not a git
        repository itself. When something leaves a .git in it that has no HEAD file and no
        objects folder (for example Claude Code writing .git/info/exclude there), Claude Code
        treats ~/repos as a git repository anyway, and every claude.ai Project thread that asks
        for a worktree fails to start ("Failed to resolve base branch HEAD"). The thread shows
        no output and reports the session as dropped after about two minutes. A running
        'claude rc' keeps believing the folder is a repository until it is restarted. See the
        AGENTS.md note on this.

        The check is one 'sh -c' probe inside the distro that prints a single word: 'absent'
        (no .git, the normal case), 'repo' (a directory with a HEAD file and an objects folder,
        the same test Claude Code uses) or 'stub' (anything else). Only a stub is logged, as one
        line per keeper run while it exists. The function only warns: it never moves, deletes or
        changes anything, never boots a stopped distro (Get-WslDistroState is checked first) and
        never throws. Any failure is reported through -Verbose and the keeper carries on.
    .PARAMETER DistroName
        Name of the WSL distro to check. Defaults to 'Ubuntu'.
    .PARAMETER LogFile
        Path to the keeper's log file. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\keeper.log".
    .OUTPUTS
        One of 'Skipped' (distro not running, or a failed or unusable check), 'Absent', 'Repo'
        or 'Stub'.
    .EXAMPLE
        Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $logFile

        Does nothing when ~/repos has no .git or a real one, otherwise logs a warning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$DistroName = 'Ubuntu',

        [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'keeper.log')
    )

    # Plain 'sh' on purpose and no double quotes in the script: wsl.exe hands the arguments
    # over verbatim with --exec, and the less quoting there is, the less there is to get wrong.
    # Prints one of: absent | repo | stub. The test for 'repo' (a directory holding a HEAD file
    # and an objects folder) is the same one Claude Code itself uses before it trusts a .git.
    # A .git that is a file or a symlink counts as a stub, because ~/repos should hold no .git
    # at all.
    $probeScript = 'd=$HOME/repos/.git; if ! test -e $d && ! test -L $d; then echo absent; elif test -d $d && ! test -L $d && test -f $d/HEAD && test -d $d/objects; then echo repo; else echo stub; fi'

    try {
        if ((Get-WslDistroState -DistroName $DistroName) -ne 'Running') {
            return 'Skipped'
        }

        $probe = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'sh', '-c', $probeScript)
        if ($probe.ExitCode -ne 0) {
            Write-Verbose -Message 'Stub .git check in ~/repos failed; skipping'
            return 'Skipped'
        }

        $verdict = @($probe.Output | Where-Object { "$_" -match '^(?:absent|repo|stub)\s*$' }) |
            Select-Object -Last 1
        if (-not $verdict) {
            Write-Verbose -Message 'Stub .git check in ~/repos gave no usable answer; skipping'
            return 'Skipped'
        }
        $verdict = "$verdict".Trim()

        if ($verdict -eq 'absent') {
            return 'Absent'
        }
        if ($verdict -eq 'repo') {
            return 'Repo'
        }

        $message = 'Warning: ~/repos/.git is not a real git repository (no HEAD file or objects folder), ' +
            'so claude rc treats ~/repos as one and every Project thread that asks for a worktree ' +
            'fails to start. Fix: mv ~/repos/.git ~/repos/.git.stray, then restart claude rc.'
        Write-WslAutomationLog -Message $message -LogFile $LogFile
        return 'Stub'
    }
    catch {
        Write-Verbose -Message 'Stub .git check in ~/repos failed with an error; skipping'
        return 'Skipped'
    }
}
