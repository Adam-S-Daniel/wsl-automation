function Get-ClaudeRemoteControlPattern {
    <#
    .SYNOPSIS
        Returns the one regex that recognizes a Claude Code Remote Control process by its args.
    .DESCRIPTION
        Single source of truth, shared by the -RemoteControlPattern defaults of
        Test-ClaudeSession and Test-WslActivity so the two can never disagree about what counts
        as the keeper's session.

        The launcher runs the server subcommand 'claude rc' (alias of 'claude remote-control').
        The pattern matches that subcommand as a whole, whitespace-delimited word, and also the
        older interactive '--remote-control' flag the keeper used to launch with, so a session
        started before the switch is still recognized and no duplicate is launched.

        It deliberately does not match a word that merely contains 'rc' (a path such as
        '/tmp/rcfile', 'src', 'rc.md'), nor '--remote-control-session-name-prefix' on its own.
        Known limitation: a bare 'rc' that is a whole word anywhere in the args (for example a
        prompt text 'claude fix the rc script') also matches. Anchoring to the first argument
        is not possible because Test-ClaudeSession matches a whole 'pgrep -af' line, where the
        args follow a pid and a command path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return '(^|\s)(rc|remote-control)(\s|$)|(^|\s)--remote-control(\s|=|$)'
}
