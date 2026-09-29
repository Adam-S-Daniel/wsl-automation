#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Test-WslActivity' {

    BeforeEach {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
    }

    It 'returns not active without probing when the distro is not Running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
        $activity.Reason | Should -Be 'NotRunning'
        $activity.IdleClaudePids | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'uses --exec (never --) to run ps, requesting ppid' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        Test-WslActivity -DistroName 'Ubuntu' | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq '-d' -and $Arguments[1] -eq 'Ubuntu' -and $Arguments[2] -eq '--exec' -and
            $Arguments -contains 'ps' -and $Arguments -contains 'pid=,ppid=,tty=,comm=,args=' -and
            ($Arguments -notcontains '--')
        }
    }

    It 'reports not active, returning its pid(s), when only the Remote Control session is present' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999      1 ?        ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    '   12345      1 pts/3    claude          claude --remote-control'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
        $activity.RemoteControlPids | Should -Be @(12345)
        $activity.ActiveProcessCount | Should -Be 0
        $activity.ActiveCommands | Should -BeNullOrEmpty
        $activity.IdleClaudePids | Should -BeNullOrEmpty
    }

    It 'reports active when a non-shell process is present on an extra pty alongside the Remote Control session' {
        # A bare shell no longer counts as activity (idle prompts are excluded), so this uses
        # 'vim' - a real interactive process - on the extra pty instead.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999      1 ?        ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    '   12345      1 pts/3    claude          claude --remote-control'
                    '   22222      1 pts/1    vim             vim notes.txt'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.ActiveProcessCount | Should -Be 1
        $activity.ActiveCommands | Should -Be @('vim')
        $activity.ActiveTerminalCount | Should -Be 1
        $activity.RemoteControlPids | Should -Be @(12345)
    }

    It 'reports active when a tmux server is present, even though it has no tty' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999      1 ?        ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    '   33333      1 ?        tmux: server    tmux'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.ActiveCommands | Should -Be @('tmux: server')
    }

    It 'ignores an unparseable "wsl: ..." warning line merged into output' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    "wsl: Detected localhost address, resolving to eth0's IP"
                    '   99999      1 ?        ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    '   12345      1 pts/3    claude          claude --remote-control'
                )
            }
        }

        { Test-WslActivity -DistroName 'Ubuntu' } | Should -Not -Throw
        $activity = Test-WslActivity -DistroName 'Ubuntu'
        $activity.IsActive | Should -BeFalse
        $activity.RemoteControlPids | Should -Be @(12345)
    }

    It 'ignores a line whose ppid column is not numeric, rather than misparsing it' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999      1 ?        ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    '   12345      ? pts/3    claude          claude --remote-control'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
        $activity.RemoteControlPids | Should -BeNullOrEmpty
    }

    It 'fails safe (active, ProbeFailed) when the ps probe exits non-zero' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 1; Output = @('boom') }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.Reason | Should -Be 'ProbeFailed'
        $activity.IdleClaudePids | Should -BeNullOrEmpty
    }

    It 'never surfaces full process arguments on an active result' {
        # A bare shell no longer counts as activity, so this uses 'vim' - a real non-shell
        # process - to keep the result actually Active while checking args are never surfaced.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999      1 ?        ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    '   22222      1 pts/1    vim             vim --some-sensitive-looking-flag'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        ($activity | ConvertTo-Json -Compress) | Should -Not -Match 'sensitive-looking-flag'
    }

    It 'reports ACTIVE with exactly one active terminal for a realistic mixed snapshot (agetty, logins, idle shells, docker-desktop, remote control, and one BUSY claude session)' {
        # The pts/5 claude session (pid 31073) is not the Remote Control session, so its own
        # session status is checked; this mock answers that lookup with status 'busy', so it (and
        # its npm/node children) count as activity exactly as before this feature existed.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            param($Arguments)
            if ($Arguments -contains 'ps') {
                return [pscustomobject]@{
                    ExitCode = 0
                    Output   = @(
                        '  287      1 tty1   agetty          agetty -o -p -- \u tty1 linux'
                        '  464      1 pts/1  login           login -f'
                        '  468    464 pts/1  bash            -bash'
                        '29796      1 pts/2  sh              sh'
                        '29807      1 pts/4  login           login -f'
                        '29877  29807 pts/4  bash            -bash'
                        '30036      1 pts/3  docker-desktop- /run/docker-desktop/docker-desktop-user-distro proxy --distro-name Ubuntu'
                        '30506      1 pts/5  bash            -bash'
                        '31073  30506 pts/5  claude          claude --resume abc123'
                        '31193  31073 pts/5  npm             exec somemcp'
                        '31281  31193 pts/5  sh              sh'
                        '31282  31281 pts/5  node            node index.js'
                        '64297      1 pts/0  claude          claude --remote-control'
                        '64424  64297 pts/0  npm             exec something'
                        '64491  64424 pts/0  sh              sh'
                        '64492  64491 pts/0  node            node index.js'
                        '71915      1 pts/6  bash            -bash'
                        '81342      1 pts/7  ps              ps -eo pid=,ppid=,tty=,comm=,args='
                    )
                }
            }
            # The session-status lookup for pid 31073 (the only non-Remote-Control claude process).
            return [pscustomobject]@{
                ExitCode = 0
                Output   = @('{"pid":31073,"sessionId":"x","status":"busy"}')
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.ActiveTerminalCount | Should -Be 1
        $activity.ActiveCommands | Should -Contain 'claude'
        $activity.ActiveCommands | Should -Not -Contain 'agetty'
        $activity.ActiveCommands | Should -Not -Contain 'bash'
        $activity.ActiveCommands | Should -Not -Contain 'docker-desktop-'
        $activity.RemoteControlPids | Should -Be @(64297)
        $activity.IdleClaudePids | Should -BeNullOrEmpty
    }

    It 'reports not active for the same mixed snapshot with the real claude session (pts/5) removed' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '  287      1 tty1   agetty          agetty -o -p -- \u tty1 linux'
                    '  464      1 pts/1  login           login -f'
                    '  468    464 pts/1  bash            -bash'
                    '29796      1 pts/2  sh              sh'
                    '29807      1 pts/4  login           login -f'
                    '29877  29807 pts/4  bash            -bash'
                    '30036      1 pts/3  docker-desktop- /run/docker-desktop/docker-desktop-user-distro proxy --distro-name Ubuntu'
                    '64297      1 pts/0  claude          claude --remote-control'
                    '64424  64297 pts/0  npm             exec something'
                    '64491  64424 pts/0  sh              sh'
                    '64492  64491 pts/0  node            node index.js'
                    '71915      1 pts/6  bash            -bash'
                    '81342      1 pts/7  ps              ps -eo pid=,ppid=,tty=,comm=,args='
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
    }

    It 'ignores tty1 (a real console tty), not pts/*, even with a non-shell comm' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '  287      1 tty1   agetty          agetty -o -p -- \u tty1 linux'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
    }

    It 'excludes a pty entirely when a docker-desktop proxy shares it with a sibling shell' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '30036      1 pts/3  docker-desktop- /run/docker-desktop/docker-desktop-user-distro proxy --distro-name Ubuntu'
                    '30037  30036 pts/3  sh              sh'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
    }

    It 'reports active for a pty holding a shell plus a real editor process' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '  100      1 pts/1  bash            -bash'
                    '  101    100 pts/1  vim             vim notes.txt'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.ActiveTerminalCount | Should -Be 1
        $activity.ActiveCommands | Should -Be @('vim')
    }

    Context 'Claude Code session status (idle sessions do not count as activity)' {

        BeforeAll {
            # Shared snapshot for these tests: pid 500 is the login shell on pts/5; pid 31073 is
            # a non-Remote-Control claude session on pts/5 with an npm/sh/node MCP child tree.
            function Get-ClaudeTreeInvokeWslExeMock {
                param(
                    [string]$SessionStatusJson = $null,
                    [int]$SessionStatusExitCode = 0,
                    [switch]$ExtraIdlePtyVim
                )

                # Captured into plain locals - rather than read directly from the parameters
                # inside the returned scriptblock below - so both parameters are used here, in
                # this function's own body, and not only inside the nested closure.
                $capturedSessionStatusJson = $SessionStatusJson
                $capturedSessionStatusExitCode = $SessionStatusExitCode

                $psLines = @(
                    '  500      1 pts/5  bash            -bash'
                    '31073    500 pts/5  claude          claude --resume abc123'
                    '31193  31073 pts/5  npm             exec somemcp'
                    '31281  31193 pts/5  sh              sh'
                    '31282  31281 pts/5  node            node index.js'
                    '81342      1 pts/7  ps              ps -eo pid=,ppid=,tty=,comm=,args='
                )
                if ($ExtraIdlePtyVim) {
                    $psLines += '  600      1 pts/1  vim             vim notes.txt'
                }

                return {
                    param($Arguments)
                    if ($Arguments -contains 'ps') {
                        return [pscustomobject]@{ ExitCode = 0; Output = $psLines }
                    }
                    return [pscustomobject]@{
                        ExitCode = $capturedSessionStatusExitCode
                        Output   = if ($null -ne $capturedSessionStatusJson) { @($capturedSessionStatusJson) } else { @() }
                    }
                }.GetNewClosure()
            }
        }

        It '(a) reports not active, with IdleClaudePids populated, when the session file reports status idle' {
            Mock -ModuleName WslAutomation Invoke-WslExe (
                Get-ClaudeTreeInvokeWslExeMock -SessionStatusJson '{"pid":31073,"sessionId":"x","status":"idle"}'
            )

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeFalse
            $activity.IdleClaudePids | Should -Be @(31073)
        }

        It '(b) reports active, with claude in ActiveCommands, when the session file reports status busy' {
            Mock -ModuleName WslAutomation Invoke-WslExe (
                Get-ClaudeTreeInvokeWslExeMock -SessionStatusJson '{"pid":31073,"sessionId":"x","status":"busy"}'
            )

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeTrue
            $activity.ActiveCommands | Should -Contain 'claude'
            $activity.IdleClaudePids | Should -BeNullOrEmpty
        }

        It '(c) reports active when the session file is missing (cat exits non-zero)' {
            Mock -ModuleName WslAutomation Invoke-WslExe (
                Get-ClaudeTreeInvokeWslExeMock -SessionStatusExitCode 1
            )

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeTrue
            $activity.ActiveCommands | Should -Contain 'claude'
            $activity.IdleClaudePids | Should -BeNullOrEmpty
        }

        It '(d) reports active when the session file content is malformed JSON' {
            Mock -ModuleName WslAutomation Invoke-WslExe (
                Get-ClaudeTreeInvokeWslExeMock -SessionStatusJson '{not valid json'
            )

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeTrue
            $activity.ActiveCommands | Should -Contain 'claude'
            $activity.IdleClaudePids | Should -BeNullOrEmpty
        }

        It '(e) reports active when the session file pid does not match the process pid, even with status idle' {
            Mock -ModuleName WslAutomation Invoke-WslExe (
                Get-ClaudeTreeInvokeWslExeMock -SessionStatusJson '{"pid":99999,"sessionId":"x","status":"idle"}'
            )

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeTrue
            $activity.ActiveCommands | Should -Contain 'claude'
            $activity.IdleClaudePids | Should -BeNullOrEmpty
        }

        It '(f) reports active because of vim on another pty, while still reporting the idle claude session' {
            Mock -ModuleName WslAutomation Invoke-WslExe (
                Get-ClaudeTreeInvokeWslExeMock -SessionStatusJson '{"pid":31073,"sessionId":"x","status":"idle"}' -ExtraIdlePtyVim
            )

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeTrue
            $activity.ActiveCommands | Should -Be @('vim')
            $activity.ActiveCommands | Should -Not -Contain 'claude'
            $activity.IdleClaudePids | Should -Be @(31073)
        }

        It '(g) reports not active with both an idle claude session and a Remote Control session present, both pid lists populated' {
            Mock -ModuleName WslAutomation Invoke-WslExe {
                param($Arguments)
                if ($Arguments -contains 'ps') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        Output   = @(
                            '  500      1 pts/5  bash            -bash'
                            '31073    500 pts/5  claude          claude --resume abc123'
                            '31193  31073 pts/5  npm             exec somemcp'
                            '64297      1 pts/0  claude          claude --remote-control'
                        )
                    }
                }
                return [pscustomobject]@{
                    ExitCode = 0
                    Output   = @('{"pid":31073,"sessionId":"x","status":"idle"}')
                }
            }

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.IsActive | Should -BeFalse
            $activity.RemoteControlPids | Should -Be @(64297)
            $activity.IdleClaudePids | Should -Be @(31073)
        }
    }

    Context 'default RemoteControlPattern' {
        # Same shared regex as Test-ClaudeSession, matched here against ProcArgs only (args
        # without comm).

        It 'identifies "claude <ProcArgs>" as the Remote Control session, not as activity' -ForEach @(
            @{ ProcArgs = 'rc' }
            @{ ProcArgs = 'rc --name x' }
            @{ ProcArgs = 'remote-control' }
            @{ ProcArgs = 'remote-control --continue' }
            @{ ProcArgs = '--remote-control' }
        ) {
            $psLine = "   12345      1 pts/3    claude          claude $ProcArgs"
            Mock -ModuleName WslAutomation Invoke-WslExe {
                [pscustomobject]@{ ExitCode = 0; Output = @($psLine) }
            }.GetNewClosure()

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.RemoteControlPids | Should -Be @(12345)
            $activity.IsActive | Should -BeFalse
            $activity.ActiveProcessCount | Should -Be 0
        }

        It 'does not identify "claude <ProcArgs>" as the Remote Control session' -ForEach @(
            @{ ProcArgs = '--remote-control-session-name-prefix foo' }
            @{ ProcArgs = '/tmp/rcfile' }
            @{ ProcArgs = 'src' }
            @{ ProcArgs = '--resume abc' }
            @{ ProcArgs = 'Read the file docs/rc.md' }
        ) {
            $psLine = "   12345      1 pts/3    claude          claude $ProcArgs"
            Mock -ModuleName WslAutomation Invoke-WslExe {
                [pscustomobject]@{ ExitCode = 0; Output = @($psLine) }
            }.GetNewClosure()

            $activity = Test-WslActivity -DistroName 'Ubuntu'

            $activity.RemoteControlPids | Should -BeNullOrEmpty
        }
    }
}
