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

    It 'reports active when an extra pts shell is present alongside the Remote Control session' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   12345 pts/3    claude          claude --remote-control'
                    '   22222 pts/1    bash            -bash'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        $activity.IsActive | Should -BeTrue
        $activity.ActiveProcessCount | Should -Be 1
        $activity.ActiveCommands | Should -Be @('bash')
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
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '   99999 ?        ps              ps -eo pid=,tty=,comm=,args='
                    '   22222 pts/1    bash            -bash --some-sensitive-looking-flag'
                )
            }
        }

        $activity = Test-WslActivity -DistroName 'Ubuntu'

        ($activity | ConvertTo-Json -Compress) | Should -Not -Match 'sensitive-looking-flag'
    }
}
