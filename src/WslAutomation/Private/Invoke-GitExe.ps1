function New-WslAutomationGitStartInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.Environment['GCM_INTERACTIVE'] = 'Never'
    # An inherited askpass program could still open a credential dialog.
    foreach ($name in @('GIT_ASKPASS', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE')) {
        $startInfo.Environment.Remove($name) | Out-Null
    }
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo
}

function Start-WslAutomationGitProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not $PSCmdlet.ShouldProcess('git', 'Start bounded Git process')) { throw 'Git process start skipped' }
    [Diagnostics.Process]::Start((New-WslAutomationGitStartInfo -Arguments $Arguments))
}

function Invoke-GitExe {
    <#
    .SYNOPSIS
        Invokes git with a deadline and captures its exit code and output.
    .DESCRIPTION
        The module's single Git seam. Arguments never pass through a shell, authentication
        prompts are disabled, and only a process started here can be stopped on timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$RepoPath,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $gitArgs = @()
    if ($RepoPath) { $gitArgs += @('-C', $RepoPath) }
    $gitArgs += $Arguments
    $process = Start-WslAutomationGitProcess -Arguments $gitArgs
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $outputTask = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr))
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        $remaining = [Math]::Max(0, ($TimeoutSeconds * 1000) - [int]$timer.ElapsedMilliseconds)
        if (-not $finished -or -not $outputTask.Wait($remaining)) {
            # Never signal a special pid, including one returned by an incomplete test mock.
            if ($process.Id -is [int] -and $process.Id -gt 1 -and -not $process.HasExited) {
                $process.Kill($true)
            }
            return [pscustomobject]@{ ExitCode = 124; Output = @() }
        }
        $output = @(($stdout.Result + "`n" + $stderr.Result) -split '\r?\n' | Where-Object { $_ -ne '' })
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
    finally {
        $process.Dispose()
    }
}
