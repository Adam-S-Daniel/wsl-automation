#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Invoke-ClaudeSessionKeeper session snapshot and restore' {
    # Get-ClaudeAgentSessions and Start-ClaudeSessionResume are the two wsl.exe-facing seams; the
    # snapshot itself is a real file under TestDrive, so the snapshot/restore bookkeeping between
    # keeper runs is exercised for real.

    BeforeAll {
        $script:idA = '11111111-1111-4111-8111-111111111111'
        $script:idB = '22222222-2222-4222-8222-222222222222'
        $script:idC = '33333333-3333-4333-8333-333333333333'

        function script:Write-TestSnapshot {
            param([object[]]$Sessions, [switch]$RestorePending)
            [pscustomobject]@{
                capturedAt     = '2026-10-01T00:00:00.0000000Z'
                restorePending = [bool]$RestorePending
                sessions       = @($Sessions)
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:snapshotPath
        }

        function script:New-TestSession {
            param([string]$Id, [string]$Cwd, [string]$Kind = 'background')
            [pscustomobject]@{ sessionId = $Id; cwd = $Cwd; kind = $Kind }
        }
    }

    BeforeEach {
        # Absolute safety net: nothing here may reach a real wsl.exe.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
        Mock -ModuleName WslAutomation Remove-WslBackupLock { }
        Mock -ModuleName WslAutomation Start-Sleep { }
        Mock -ModuleName WslAutomation Start-ClaudeLauncherTask { }
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $true }
        Mock -ModuleName WslAutomation Start-ClaudeSessionResume {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $script:lockPath = Join-Path $TestDrive 'backup.lock'
        $script:logFile = Join-Path $TestDrive 'keeper.log'
        $script:snapshotPath = Join-Path $TestDrive 'agents-snapshot.json'
        Remove-Item -LiteralPath $script:snapshotPath, $script:logFile -ErrorAction SilentlyContinue

        $script:keeperArgs = @{
            DistroName          = 'Ubuntu'
            LockPath            = $script:lockPath
            LogFile             = $script:logFile
            SessionSnapshotPath = $script:snapshotPath
        }
    }

    Context 'while the Remote Control server is alive' {

        BeforeEach {
            Mock -ModuleName WslAutomation Test-ClaudeSession { $true }
        }

        It 'writes the live session list to the snapshot, and resumes nothing' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @(
                    [pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/repos'; Kind = 'background' }
                    [pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/home/u/repos/x y'; Kind = 'interactive' }
                )
            }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.Status | Should -Be 'SessionPresent'
            $result.ResumedSessionCount | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly

            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.capturedAt | Should -Not -BeNullOrEmpty
            $snapshot.restorePending | Should -BeFalse
            @($snapshot.sessions).Count | Should -Be 2
            $snapshot.sessions[0].sessionId | Should -Be $script:idA
            $snapshot.sessions[1].cwd | Should -Be '/home/u/repos/x y'
            $snapshot.sessions[1].kind | Should -Be 'interactive'
            Get-ChildItem -LiteralPath $TestDrive -Filter 'agents-snapshot.json.tmp-*' | Should -BeNullOrEmpty
        }

        It 'writes an empty session list as an empty snapshot (known: no sessions)' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
            Write-TestSnapshot -Sessions @(New-TestSession -Id $script:idA -Cwd '/home/u/repos')

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            @($snapshot.sessions).Count | Should -Be 0
        }

        It 'never overwrites the snapshot when the session list cannot be read ($null)' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { $null }
            Write-TestSnapshot -Sessions @(New-TestSession -Id $script:idA -Cwd '/home/u/repos')
            $before = Get-Content -LiteralPath $script:snapshotPath -Raw

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            Get-Content -LiteralPath $script:snapshotPath -Raw | Should -Be $before
        }

        It 'does not create a snapshot when the session list cannot be read and none exists' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { $null }

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            Test-Path -LiteralPath $script:snapshotPath | Should -BeFalse
        }

        It 'does not write the snapshot under -DryRun' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @([pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/repos'; Kind = 'background' })
            }

            Invoke-ClaudeSessionKeeper @script:keeperArgs -DryRun | Out-Null

            Test-Path -LiteralPath $script:snapshotPath | Should -BeFalse
        }

        It 'finishes a pending restore first, then clears the mark without replacing the snapshot with the live list' {
            Write-TestSnapshot -RestorePending -Sessions @(
                (New-TestSession -Id $script:idA -Cwd '/home/u/repos/a')
                (New-TestSession -Id $script:idB -Cwd '/home/u/repos/b')
            )
            # The live list holds only the new rc's view: B survived, A was lost.
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @([pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/home/u/repos/b'; Kind = 'background' })
            }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.Status | Should -Be 'SessionPresent'
            $result.ResumedSessionCount | Should -Be 1
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq '11111111-1111-4111-8111-111111111111' -and $Cwd -eq '/home/u/repos/a' -and $DistroName -eq 'Ubuntu'
            }

            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.restorePending | Should -BeFalse
            @($snapshot.sessions).Count | Should -Be 2
            (Get-Content -LiteralPath $script:snapshotPath -Raw) | Should -Match ([regex]::Escape('"capturedAt": "2026-10-01T00:00:00.0000000Z"'))
        }

        It 'ignores a pending mark under -NoSessionRestore and just refreshes the snapshot' {
            Write-TestSnapshot -RestorePending -Sessions @(New-TestSession -Id $script:idA -Cwd '/home/u/repos/a')
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            Invoke-ClaudeSessionKeeper @script:keeperArgs -NoSessionRestore | Out-Null

            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.restorePending | Should -BeFalse
            @($snapshot.sessions).Count | Should -Be 0
        }
    }

    Context 'after the Remote Control server died' {

        BeforeEach {
            Mock -ModuleName WslAutomation Test-ClaudeSession { $false }
            Write-TestSnapshot -Sessions @(
                (New-TestSession -Id $script:idA -Cwd '/home/u/repos/proj-a')
                (New-TestSession -Id $script:idB -Cwd '/home/u/repos/proj-b' -Kind 'interactive')
                (New-TestSession -Id $script:idC -Cwd '/home/u/repos/with space')
            )
        }

        It 'launches the server and resumes exactly the snapshotted sessions that are no longer listed, each from its own cwd' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @([pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/home/u/repos/proj-b'; Kind = 'interactive' })
            }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.Status | Should -Be 'Launched'
            $result.ResumedSessionCount | Should -Be 2
            Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
                $LauncherTaskName -eq 'Claude Code Session Launcher'
            }
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 2 -Exactly
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq '11111111-1111-4111-8111-111111111111' -and $Cwd -eq '/home/u/repos/proj-a'
            }
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq '33333333-3333-4333-8333-333333333333' -and $Cwd -eq '/home/u/repos/with space'
            }
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly -ParameterFilter {
                $SessionId -eq '22222222-2222-4222-8222-222222222222'
            }

            # The snapshot is kept (not deleted), with no restore left pending.
            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.restorePending | Should -BeFalse
            @($snapshot.sessions).Count | Should -Be 3

            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match 'Session restore: 2 resumed, 0 failed, 0 skipped \(3 in snapshot, 1 already running\)'
            # Session ids may be logged; cwds (and names) never are.
            $log | Should -Not -Match 'proj-a'
        }

        It 'resumes nothing when every snapshotted session is still listed' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @(
                    [pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/x'; Kind = 'background' }
                    [pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/x'; Kind = 'background' }
                    [pscustomobject]@{ SessionId = '33333333-3333-4333-8333-333333333333'; Cwd = '/x'; Kind = 'background' }
                )
            }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.ResumedSessionCount | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
        }

        It 'counts a resume that exits nonzero as failed, not resumed' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
            Mock -ModuleName WslAutomation Start-ClaudeSessionResume {
                [pscustomobject]@{ ExitCode = [int]($SessionId -eq '11111111-1111-4111-8111-111111111111'); Output = @() }
            }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.ResumedSessionCount | Should -Be 2
            Get-Content -LiteralPath $script:logFile -Raw | Should -Match '2 resumed, 1 failed'
        }

        It 'skips and logs a snapshotted session id that is not a UUID, never passing it on' {
            Write-TestSnapshot -Sessions @(
                (New-TestSession -Id 'c2165965; rm -rf ~' -Cwd '/home/u/repos')
                (New-TestSession -Id $script:idA -Cwd '/home/u/repos')
            )
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.ResumedSessionCount | Should -Be 1
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq '11111111-1111-4111-8111-111111111111'
            }
            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match 'not a UUID'
            $log | Should -Match '1 resumed, 0 failed, 1 skipped'
        }

        It 'resumes nothing and keeps the restore pending when the live list cannot be read' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { $null }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.Status | Should -Be 'Launched'
            $result.ResumedSessionCount | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.restorePending | Should -BeTrue
            @($snapshot.sessions).Count | Should -Be 3
            Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'could not list current Claude sessions; will retry next run'
        }

        It 'restores on the next run, once the new server is alive, instead of forgetting the lost sessions' {
            # Run 1: rc dead, distro not up yet - nothing can be listed.
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { $null }
            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            # Run 2: the launcher's new rc is up, but none of the old sessions are listed.
            Mock -ModuleName WslAutomation Test-ClaudeSession { $true }
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.ResumedSessionCount | Should -Be 3
            (Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json).restorePending | Should -BeFalse

            # Run 3: back to normal - the snapshot follows the live list again.
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @([pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/repos/proj-a'; Kind = 'background' })
            }
            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 3 -Exactly
            @((Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json).sessions).Count | Should -Be 1
        }

        It 'does not throw, still launches, and logs once when the snapshot is missing' {
            Remove-Item -LiteralPath $script:snapshotPath
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.Status | Should -Be 'Launched'
            $result.ResumedSessionCount | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
            ([regex]::Matches((Get-Content -LiteralPath $script:logFile -Raw), 'no usable session snapshot')).Count | Should -Be 1
        }

        It 'does not throw, still launches, and leaves the file alone when the snapshot is corrupt' {
            Set-Content -LiteralPath $script:snapshotPath -Value '{ "sessions": [ not json'
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.Status | Should -Be 'Launched'
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
            Get-Content -LiteralPath $script:snapshotPath -Raw | Should -Match 'not json'
            Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'no usable session snapshot'
        }

        It 'neither lists nor resumes sessions under -NoSessionRestore' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs -NoSessionRestore

            $result.Status | Should -Be 'Launched'
            $result.ResumedSessionCount | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Get-ClaudeAgentSessions -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
        }

        It 'only logs the ids it would resume under -DryRun, and leaves the snapshot untouched' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
            $before = Get-Content -LiteralPath $script:snapshotPath -Raw

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs -DryRun

            $result.Status | Should -Be 'DryRun'
            $result.ResumedSessionCount | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
            Get-Content -LiteralPath $script:snapshotPath -Raw | Should -Be $before
            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match "DryRun: would resume Claude session $($script:idA)"
            $log | Should -Match "DryRun: would resume Claude session $($script:idC)"
        }
    }
}

Describe 'Invoke-ClaudeSessionKeeper codex agents tab' {

    BeforeEach {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
        Mock -ModuleName WslAutomation Start-Sleep { }
        Mock -ModuleName WslAutomation Start-ClaudeLauncherTask { }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $true }
        Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
        Mock -ModuleName WslAutomation Start-ClaudeSessionResume { }

        $script:keeperArgs = @{
            DistroName          = 'Ubuntu'
            LockPath            = (Join-Path $TestDrive 'backup.lock')
            LogFile             = (Join-Path $TestDrive 'keeper.log')
            SessionSnapshotPath = (Join-Path $TestDrive 'agents-snapshot.json')
        }
    }

    It 'starts the Codex launcher task when no codex agents tab is running' {
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $result.CodexAgentsLaunched | Should -BeTrue
        $result.Status | Should -Be 'SessionPresent'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Codex Agents Launcher'
        }
    }

    It 'honors -CodexLauncherTaskName' {
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $false }

        Invoke-ClaudeSessionKeeper @script:keeperArgs -CodexLauncherTaskName 'My Codex Tab' | Out-Null

        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'My Codex Tab'
        }
    }

    It 'launches nothing when the codex agents tab is already running' {
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $true }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $result.CodexAgentsLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
    }

    It 'launches both tabs, each through its own task, when neither is running' {
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $result.Status | Should -Be 'Launched'
        $result.CodexAgentsLaunched | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Claude Code Session Launcher'
        }
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Codex Agents Launcher'
        }
    }

    It 'neither checks for nor launches the tab under -NoCodexAgents' {
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs -NoCodexAgents

        $result.CodexAgentsLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Test-CodexAgentsSession -Times 0 -Exactly
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
    }

    It 'only logs the launch under -DryRun' {
        Mock -ModuleName WslAutomation Test-CodexAgentsSession { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs -DryRun

        $result.CodexAgentsLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
        Get-Content -LiteralPath $script:keeperArgs.LogFile -Raw | Should -Match 'DryRun: would launch a codex agents tab'
    }
}

Describe 'Test-CodexAgentsSession' {

    BeforeEach {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
    }

    It 'recognizes "<Line>" as the codex agents tab' -ForEach @(
        @{ Line = 'codex agents' }
        @{ Line = '4242 codex agents' }
        @{ Line = '/home/x/.local/bin/codex agents --foo' }
        @{ Line = '4242 /home/x/.local/bin/codex agents --foo' }
        @{ Line = '4242 node /home/x/.local/bin/codex agents' }
    ) {
        $pgrepLine = $Line
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @($pgrepLine) }
        }.GetNewClosure()

        Test-CodexAgentsSession -DistroName 'Ubuntu' | Should -BeTrue
    }

    It 'rejects "<Line>"' -ForEach @(
        @{ Line = 'codex app-server --listen stdio' }
        @{ Line = '4242 /home/x/.local/bin/codex app-server' }
        @{ Line = '4242 codex-code-mode-host' }
        @{ Line = '4242 /home/x/.local/bin/codex-code-mode-host agents' }
        @{ Line = 'codex' }
        @{ Line = '4242 codex' }
        @{ Line = '4242 codex agentsx' }
        @{ Line = '4242 mycodex agents' }
    ) {
        $pgrepLine = $Line
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @($pgrepLine) }
        }.GetNewClosure()

        Test-CodexAgentsSession -DistroName 'Ubuntu' | Should -BeFalse
    }

    It 'runs pgrep -af codex inside the named distro' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('1 codex agents') }
        }

        Test-CodexAgentsSession -DistroName 'Debian' | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Debian|--|pgrep|-af|codex'
        }
    }

    It 'returns false without ever running pgrep when the distro is not Running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('1 codex agents') }
        }

        Test-CodexAgentsSession -DistroName 'Ubuntu' | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'returns false when pgrep exits nonzero' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 1; Output = @('1 codex agents') }
        }

        Test-CodexAgentsSession -DistroName 'Ubuntu' | Should -BeFalse
    }
}

Describe 'Get-ClaudeAgentSessions' {
    # Private seam: called through InModuleScope. The empty-array-versus-$null assertions run
    # inside the scope so nothing can unroll the result before it is checked.

    BeforeEach {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
    }

    It 'runs claude agents --json through a login shell with --exec, and maps sessionId, cwd and kind' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    ('[{"pid":1411684,"id":"c2165965","cwd":"/home/passp/repos","kind":"background","startedAt":1790962276692,' +
                        '"sessionId":"c2165965-516f-5d82-ad4d-afa62ee6a8ed","name":"a title","status":"idle","state":"blocked"},' +
                        '{"pid":2,"id":"d1","cwd":"/home/passp","kind":"interactive","sessionId":"d1d1d1d1-0000-4000-8000-000000000000"}]')
                )
            }
        }

        $sessions = InModuleScope WslAutomation { Get-ClaudeAgentSessions -DistroName 'Ubuntu' }

        @($sessions).Count | Should -Be 2
        $sessions[0].SessionId | Should -Be 'c2165965-516f-5d82-ad4d-afa62ee6a8ed'
        $sessions[0].Cwd | Should -Be '/home/passp/repos'
        $sessions[0].Kind | Should -Be 'background'
        $sessions[1].Kind | Should -Be 'interactive'
        # Only these three fields are carried; the session's name/title never is.
        @($sessions[0].PSObject.Properties.Name) | Should -Be @('SessionId', 'Cwd', 'Kind')
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Ubuntu|--exec|bash|-l|-c|claude agents --json'
        }
    }

    It 'skips entries missing sessionId or cwd' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    ('[{"id":"a","cwd":"/x"},{"sessionId":"b0000000-0000-4000-8000-000000000000"},' +
                        '{"sessionId":"","cwd":"/x"},{"sessionId":"c0000000-0000-4000-8000-000000000000","cwd":"/y"}]')
                )
            }
        }

        $ids = InModuleScope WslAutomation { (Get-ClaudeAgentSessions -DistroName 'Ubuntu').SessionId }

        $ids | Should -Be @('c0000000-0000-4000-8000-000000000000')
    }

    It 'returns an empty array, not $null, for "[]"' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('[]') }
        }

        InModuleScope WslAutomation {
            $r = Get-ClaudeAgentSessions -DistroName 'Ubuntu'
            ($null -ne $r) -and ($r -is [array]) -and ($r.Count -eq 0)
        } | Should -BeTrue
    }

    It 'returns a one-element array (not a scalar) for one session' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('[{"sessionId":"c0000000-0000-4000-8000-000000000000","cwd":"/y"}]') }
        }

        InModuleScope WslAutomation {
            $r = Get-ClaudeAgentSessions -DistroName 'Ubuntu'
            ($r -is [array]) -and ($r.Count -eq 1)
        } | Should -BeTrue
    }

    It 'ignores text a login profile prints before the JSON' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @('Welcome to Ubuntu', '[', '{"sessionId":"c0000000-0000-4000-8000-000000000000","cwd":"/y"}', ']')
            }
        }

        $ids = InModuleScope WslAutomation { (Get-ClaudeAgentSessions -DistroName 'Ubuntu').SessionId }

        $ids | Should -Be @('c0000000-0000-4000-8000-000000000000')
    }

    It 'fails closed to $null for <Case>' -ForEach @(
        @{ Case = 'a nonzero exit'; ExitCode = 1; Output = @('[]') }
        @{ Case = 'unparseable output'; ExitCode = 0; Output = @('[ not json') }
        @{ Case = 'no output'; ExitCode = 0; Output = @() }
        @{ Case = 'a JSON object instead of an array'; ExitCode = 0; Output = @('{"sessions":[]}') }
    ) {
        $exit = $ExitCode
        $out = $Output
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = $exit; Output = $out }
        }.GetNewClosure()

        InModuleScope WslAutomation { $null -eq (Get-ClaudeAgentSessions -DistroName 'Ubuntu') } | Should -BeTrue
    }

    It 'returns $null instead of throwing when wsl.exe itself throws' {
        Mock -ModuleName WslAutomation Invoke-WslExe { throw 'wsl.exe not found' }

        InModuleScope WslAutomation { $null -eq (Get-ClaudeAgentSessions -DistroName 'Ubuntu') } | Should -BeTrue
    }

    It 'returns $null without running anything in a distro that is not Running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }
        Mock -ModuleName WslAutomation Invoke-WslExe { [pscustomobject]@{ ExitCode = 0; Output = @('[]') } }

        InModuleScope WslAutomation { $null -eq (Get-ClaudeAgentSessions -DistroName 'Ubuntu') } | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }
}

Describe 'Start-ClaudeSessionResume' {

    BeforeEach {
        Mock -ModuleName WslAutomation Invoke-WslExe { [pscustomobject]@{ ExitCode = 0; Output = @() } }
    }

    It 'passes the cwd and session id to a fixed bash script as separate positional arguments' {
        $result = InModuleScope WslAutomation {
            Start-ClaudeSessionResume -DistroName 'Ubuntu' -SessionId 'c2165965-516f-5d82-ad4d-afa62ee6a8ed' -Cwd '/home/u/my repo; rm -rf ~'
        }

        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 10 -and
            ($Arguments[0..6] -join '|') -eq '-d|Ubuntu|--exec|bash|-l|-c|cd -- "$1" && exec claude --bg --resume "$2"' -and
            $Arguments[7] -eq 'bash' -and
            $Arguments[8] -eq '/home/u/my repo; rm -rf ~' -and
            $Arguments[9] -eq 'c2165965-516f-5d82-ad4d-afa62ee6a8ed'
        }
    }

    It 'rejects <Case> before reaching wsl.exe' -ForEach @(
        @{ Case = 'a non-UUID session id'; SessionId = 'c2165965'; Cwd = '/home/u' }
        @{ Case = 'a session id with shell text'; SessionId = 'c2165965-516f-5d82-ad4d-afa62ee6a8ed; id'; Cwd = '/home/u' }
        @{ Case = 'a relative cwd'; SessionId = 'c2165965-516f-5d82-ad4d-afa62ee6a8ed'; Cwd = 'repos' }
    ) {
        InModuleScope WslAutomation -Parameters @{ S = $SessionId; C = $Cwd } {
            { Start-ClaudeSessionResume -DistroName 'Ubuntu' -SessionId $S -Cwd $C } | Should -Throw
        }
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }
}

Describe 'Claude agent snapshot file' {

    It 'round-trips sessions, keeping a one-element list an array, and leaves no temp file behind' {
        $path = Join-Path $TestDrive 'nested' 'agents-snapshot.json'

        $snapshot = InModuleScope WslAutomation -Parameters @{ P = $path } {
            Write-ClaudeAgentSnapshot -Path $P -Sessions @(
                [pscustomobject]@{ SessionId = 'c0000000-0000-4000-8000-000000000000'; Cwd = '/y'; Kind = 'background' }
            ) -RestorePending
            Read-ClaudeAgentSnapshot -Path $P
        }

        $snapshot.RestorePending | Should -BeTrue
        $snapshot.CapturedAt | Should -Not -BeNullOrEmpty
        @($snapshot.Sessions).Count | Should -Be 1
        $snapshot.Sessions[0].SessionId | Should -Be 'c0000000-0000-4000-8000-000000000000'
        (Get-Content -LiteralPath $path -Raw) | Should -Match '"sessions":\s*\['
        Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp-*' | Should -BeNullOrEmpty
    }

    It 'reads <Case> as $null' -ForEach @(
        @{ Case = 'a missing file'; Content = $null }
        @{ Case = 'invalid JSON'; Content = '{ nope' }
        @{ Case = 'JSON without a sessions list'; Content = '{"capturedAt":"x"}' }
        @{ Case = 'a JSON array'; Content = '[]' }
    ) {
        $path = Join-Path $TestDrive "snapshot-$([guid]::NewGuid().ToString('N')).json"
        if ($null -ne $Content) { Set-Content -LiteralPath $path -Value $Content }

        InModuleScope WslAutomation -Parameters @{ P = $path } {
            $null -eq (Read-ClaudeAgentSnapshot -Path $P)
        } | Should -BeTrue
    }
}
