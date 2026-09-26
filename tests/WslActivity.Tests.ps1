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
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'uses --exec (never --) to run ps' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        Test-WslActivity -DistroName 'Ubuntu' | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq '-d' -and $Arguments[1] -eq 'Ubuntu' -and $Arguments[2] -eq '--exec' -and
            $Arguments -contains 'ps' -and ($Arguments -notcontains '--')
        }
    }

    It 'reports not active, returning its pid(s), when only the Remote Control session is present' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   12345 pts/3    claude          claude --remote-control'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeFalse
        $activity.RemoteControlPids | Should -Be @(12345)
        $activity.ActiveProcessCount | Should -Be 0
        $activity.ActiveCommands | Should -BeNullOrEmpty
    }

    It 'reports active when a non-shell process is present on an extra pty alongside the Remote Control session' {
        # A bare shell no longer counts as activity (idle prompts are excluded), so this uses
        # 'vim' - a real interactive process - on the extra pty instead.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   12345 pts/3    claude          claude --remote-control'
                    '   22222 pts/1    vim             vim notes.txt'
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
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   33333 ?        tmux: server    tmux'
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
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   12345 pts/3    claude          claude --remote-control'
                )
            }
        }

        { Test-WslActivity -DistroName 'Ubuntu' } | Should -Not -Throw
        $activity = Test-WslActivity -DistroName 'Ubuntu'
        $activity.IsActive | Should -BeFalse
        $activity.RemoteControlPids | Should -Be @(12345)
    }

    It 'fails safe (active, ProbeFailed) when the ps probe exits non-zero' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 1; Output = @('boom') }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.Reason | Should -Be 'ProbeFailed'
    }

    It 'never surfaces full process arguments on an active result' {
        # A bare shell no longer counts as activity, so this uses 'vim' - a real non-shell
        # process - to keep the result actually Active while checking args are never surfaced.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   22222 pts/1    vim             vim --some-sensitive-looking-flag'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        ($activity | ConvertTo-Json -Compress) | Should -Not -Match 'sensitive-looking-flag'
    }

    It 'reports ACTIVE with exactly one active terminal for a realistic mixed snapshot (agetty, logins, idle shells, docker-desktop, remote control, and one real claude session)' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '  287 tty1   agetty          agetty -o -p -- \u tty1 linux'
                    '  464 pts/1  login           login -f'
                    '  468 pts/1  bash            -bash'
                    '29796 pts/2  sh              sh'
                    '29807 pts/4  login           login -f'
                    '29877 pts/4  bash            -bash'
                    '30036 pts/3  docker-desktop- /run/docker-desktop/docker-desktop-user-distro proxy --distro-name Ubuntu'
                    '30506 pts/5  bash            -bash'
                    '31073 pts/5  claude          claude --resume abc123'
                    '31193 pts/5  npm             exec somemcp'
                    '31281 pts/5  sh              sh'
                    '31282 pts/5  node            node index.js'
                    '64297 pts/0  claude          claude --remote-control'
                    '64424 pts/0  npm             exec something'
                    '64491 pts/0  sh              sh'
                    '64492 pts/0  node            node index.js'
                    '71915 pts/6  bash            -bash'
                    '81342 pts/7  ps              ps -eo pid=,tty=,comm=,args='
                )
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
    }

    It 'reports not active for the same mixed snapshot with the real claude session (pts/5) removed' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '  287 tty1   agetty          agetty -o -p -- \u tty1 linux'
                    '  464 pts/1  login           login -f'
                    '  468 pts/1  bash            -bash'
                    '29796 pts/2  sh              sh'
                    '29807 pts/4  login           login -f'
                    '29877 pts/4  bash            -bash'
                    '30036 pts/3  docker-desktop- /run/docker-desktop/docker-desktop-user-distro proxy --distro-name Ubuntu'
                    '64297 pts/0  claude          claude --remote-control'
                    '64424 pts/0  npm             exec something'
                    '64491 pts/0  sh              sh'
                    '64492 pts/0  node            node index.js'
                    '71915 pts/6  bash            -bash'
                    '81342 pts/7  ps              ps -eo pid=,tty=,comm=,args='
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
                    '  287 tty1   agetty          agetty -o -p -- \u tty1 linux'
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
                    '30036 pts/3  docker-desktop- /run/docker-desktop/docker-desktop-user-distro proxy --distro-name Ubuntu'
                    '30037 pts/3  sh              sh'
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
                    '  100 pts/1  bash            -bash'
                    '  101 pts/1  vim             vim notes.txt'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.ActiveTerminalCount | Should -Be 1
        $activity.ActiveCommands | Should -Be @('vim')
    }
}
