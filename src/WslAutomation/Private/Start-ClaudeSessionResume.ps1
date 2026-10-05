function Start-ClaudeSessionResume {
    <#
    .SYNOPSIS
        Resumes one Claude Code session in the background, from its own working directory,
        inside a WSL distro.
    .DESCRIPTION
        Runs 'claude --bg --resume <sessionId>' from the session's cwd. That brings a session
        that died with its Remote Control server (or with the distro, when a backup's
        'wsl --export' stopped it) back into 'claude agents', idle, with its history intact.
        With -ContinuePrompt the resumed session is also given that text as its next message,
        so a session that was interrupted mid-turn carries on instead of waiting idle.

        The values reach bash as positional parameters, never spliced into the command text:
        the fixed script is 'cd -- "$1" && exec claude --bg --resume "$2"' (with a trailing
        '"$3"' for the prompt when -ContinuePrompt is given), and wsl.exe is called with
        '--exec' so the script, '$0' ('bash'), the cwd, the session id and the prompt arrive
        as separate, verbatim arguments. A cwd or prompt containing spaces or shell
        metacharacters therefore cannot change what runs. A login shell ('bash -l') is needed because claude
        lives in ~/.local/bin. If the cwd no longer exists the 'cd' fails, claude never runs,
        and the non-zero exit is reported to the caller.

        SessionId must be a UUID (the full 'sessionId' from 'claude agents --json', not the
        short 'id') and Cwd an absolute Linux path; anything else is rejected by parameter
        validation before wsl.exe is reached. The caller (Invoke-ClaudeSessionRestore) checks
        both first and logs a skip, so this is a second line of defense.

        This thin seam exists so the keeper's restore logic can be tested by mocking a plain
        function, mirroring Start-ClaudeLauncherTask; the actual wsl.exe call goes through
        Invoke-WslExe like every other one.
    .PARAMETER DistroName
        Name of the WSL distro to resume the session in.
    .PARAMETER SessionId
        Full session UUID to resume.
    .PARAMETER Cwd
        Absolute Linux path the session was running in.
    .PARAMETER ContinuePrompt
        Optional text sent to the resumed session as its first message. When empty, the session
        is resumed idle, exactly as without the parameter.
    .OUTPUTS
        The Invoke-WslExe result (ExitCode, Output), or $null when declined by -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [ValidatePattern('^/')]
        [string]$Cwd,

        [string]$ContinuePrompt
    )

    if (-not $PSCmdlet.ShouldProcess($SessionId, 'Resume Claude Code session')) {
        return $null
    }

    if (-not [string]::IsNullOrEmpty($ContinuePrompt)) {
        return Invoke-WslExe -Arguments @(
            '-d', $DistroName, '--exec', 'bash', '-l', '-c',
            'cd -- "$1" && exec claude --bg --resume "$2" "$3"',
            'bash', $Cwd, $SessionId, $ContinuePrompt
        )
    }

    return Invoke-WslExe -Arguments @(
        '-d', $DistroName, '--exec', 'bash', '-l', '-c',
        'cd -- "$1" && exec claude --bg --resume "$2"',
        'bash', $Cwd, $SessionId
    )
}
