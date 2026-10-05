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
            param([string]$Id, [string]$Cwd, [string]$Kind = 'background', [switch]$Working)
            [pscustomobject]@{ sessionId = $Id; cwd = $Cwd; kind = $Kind; working = [bool]$Working }
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
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $true }
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

        It 'does not overwrite a restore-pending snapshot the backup wrote while this run was listing sessions' {
            # The backup lands its restore-pending snapshot after this run's first snapshot read
            # but before its refresh write: simulated by a list call that writes the file.
            $path = $script:snapshotPath
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                Set-Content -LiteralPath $path -Value ('{"capturedAt":"2026-10-01T00:00:00.0000000Z","restorePending":true,' +
                    '"sessions":[{"sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/home/u/repos/a","kind":"background","working":true}]}')
                , @()
            }.GetNewClosure()

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.restorePending | Should -BeTrue
            @($snapshot.sessions).Count | Should -Be 1
            $snapshot.sessions[0].working | Should -BeTrue
        }

        It 'does not overwrite the snapshot when a fresh backup lock appeared after this run''s own lock check' {
            Write-TestSnapshot -Sessions @(New-TestSession -Id $script:idA -Cwd '/home/u/repos/a' -Working)
            $before = Get-Content -LiteralPath $script:snapshotPath -Raw
            # First lock check (the wait loop) sees no backup; the re-check right before the write does.
            $lockChecks = [System.Collections.Generic.List[int]]::new()
            Mock -ModuleName WslAutomation Test-WslBackupLock {
                $lockChecks.Add(1)
                [pscustomobject]@{ Present = ($lockChecks.Count -gt 1); Stale = $false; AgeMinutes = 0; Data = $null }
            }.GetNewClosure()
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            $lockChecks.Count | Should -Be 2
            Get-Content -LiteralPath $script:snapshotPath -Raw | Should -Be $before
        }

        It 'still refreshes the snapshot when the lock re-check finds only a stale lock' {
            Write-TestSnapshot -Sessions @(New-TestSession -Id $script:idA -Cwd '/home/u/repos/a')
            $lockChecks = [System.Collections.Generic.List[int]]::new()
            Mock -ModuleName WslAutomation Test-WslBackupLock {
                $lockChecks.Add(1)
                # The first (wait loop) check is clear; the re-check sees a stale lock file.
                [pscustomobject]@{ Present = ($lockChecks.Count -gt 1); Stale = $true; AgeMinutes = 999; Data = $null }
            }.GetNewClosure()
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            @((Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json).sessions).Count | Should -Be 0
        }

        It 'records the working flag of a live session in the snapshot' {
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions {
                , @(
                    [pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/repos'; Kind = 'background'; Working = $true }
                    [pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/home/u/repos'; Kind = 'background'; Working = $false }
                )
            }

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.sessions[0].working | Should -BeTrue
            $snapshot.sessions[1].working | Should -BeFalse
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
            $log | Should -Match 'Session restore: 2 resumed \(0 asked to continue\), 0 failed, 0 skipped \(3 in snapshot, 1 already running\)'
            # Session ids may be logged; cwds (and names) never are.
            $log | Should -Not -Match 'proj-a'
        }

        It 'asks a session that was mid-turn to continue, resumes an idle one bare, and counts the former in the summary' {
            Write-TestSnapshot -Sessions @(
                (New-TestSession -Id $script:idA -Cwd '/home/u/repos/proj-a' -Working)
                (New-TestSession -Id $script:idB -Cwd '/home/u/repos/proj-b')
            )
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

            $result.ResumedSessionCount | Should -Be 2
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq '11111111-1111-4111-8111-111111111111' -and
                $ContinuePrompt -eq ('This session was interrupted mid-turn when its WSL distro was stopped (a backup export or a crash). ' +
                    'Continue the task you were working on from where you left off.')
            }
            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter {
                $SessionId -eq '22222222-2222-4222-8222-222222222222' -and -not $ContinuePrompt
            }
            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match 'Session restore: 2 resumed \(1 asked to continue\), 0 failed, 0 skipped \(2 in snapshot, 0 already running\)'
            $log | Should -Not -Match 'proj-a'
            $log | Should -Not -Match 'interrupted mid-turn'
        }

        It 'does not count a failed resume of a mid-turn session as asked to continue' {
            Write-TestSnapshot -Sessions @(New-TestSession -Id $script:idA -Cwd '/home/u/repos/proj-a' -Working)
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
            Mock -ModuleName WslAutomation Start-ClaudeSessionResume {
                [pscustomobject]@{ ExitCode = 1; Output = @() }
            }

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            Get-Content -LiteralPath $script:logFile -Raw | Should -Match '0 resumed \(0 asked to continue\), 1 failed'
        }

        It 'reads an older snapshot without a working field as idle sessions, resumed without a prompt' {
            Set-Content -LiteralPath $script:snapshotPath -Value ('{"capturedAt":"x","restorePending":false,"sessions":[' +
                '{"sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/home/u/repos/a","kind":"background"}]}')
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 1 -Exactly -ParameterFilter { -not $ContinuePrompt }
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
            Get-Content -LiteralPath $script:logFile -Raw | Should -Match '2 resumed \(0 asked to continue\), 1 failed'
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
            $log | Should -Match '1 resumed \(0 asked to continue\), 0 failed, 1 skipped'
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

        It 'says under -DryRun which sessions would be asked to continue' {
            Write-TestSnapshot -Sessions @(
                (New-TestSession -Id $script:idA -Cwd '/home/u/repos/proj-a' -Working)
                (New-TestSession -Id $script:idB -Cwd '/home/u/repos/proj-b')
            )
            Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }

            Invoke-ClaudeSessionKeeper @script:keeperArgs -DryRun | Out-Null

            Should -Invoke -ModuleName WslAutomation Start-ClaudeSessionResume -Times 0 -Exactly
            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match "DryRun: would resume Claude session $($script:idA) and ask it to continue"
            $log | Should -Match "DryRun: would resume Claude session $($script:idB)\s*(\r?\n|$)"
        }
    }
}

Describe 'Invoke-ClaudeSessionKeeper codex remote control' {

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

    It 'starts the Codex launcher task when no remote-control daemon is running' {
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $result.CodexRemoteControlLaunched | Should -BeTrue
        $result.Status | Should -Be 'SessionPresent'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Codex Remote Control Launcher'
        }
        Get-Content -LiteralPath $script:keeperArgs.LogFile -Raw |
            Should -Match "Started codex remote-control start \(via 'Codex Remote Control Launcher'\)"
    }

    It 'honors -CodexLauncherTaskName' {
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $false }

        Invoke-ClaudeSessionKeeper @script:keeperArgs -CodexLauncherTaskName 'My Codex Tab' | Out-Null

        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'My Codex Tab'
        }
    }

    It 'launches nothing when the remote-control daemon is already running' {
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $true }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $result.CodexRemoteControlLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
    }

    It 'starts the daemon once, then leaves it alone on later runs once pgrep shows it (even after its tab closed)' {
        # Real Test-CodexRemoteControl against a mocked process list: the first run sees only
        # look-alikes, later runs see the detached daemon - and no 'codex remote-control start'
        # launcher, as when the command daemonizes and its tab closes.
        $script:codexProcessLines = @(
            '100 codex exec --json example',
            '101 codex remote-control pair',
            '102 vim /home/example/notes/codex remote-control start.md'
        )
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = $script:codexProcessLines }
        } -ParameterFilter { ($Arguments -join '|') -eq '-d|Ubuntu|--|pgrep|-af|codex' }

        $first = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $script:codexProcessLines += '200 /home/example/.local/bin/codex app-server --remote-control --listen unix:// --managed-daemon'
        $second = Invoke-ClaudeSessionKeeper @script:keeperArgs
        $third = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $first.CodexRemoteControlLaunched | Should -BeTrue
        $second.CodexRemoteControlLaunched | Should -BeFalse
        $third.CodexRemoteControlLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Codex Remote Control Launcher'
        }
    }

    It 'launches both, each through its own task, when neither is running' {
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs

        $result.Status | Should -Be 'Launched'
        $result.CodexRemoteControlLaunched | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Claude Code Session Launcher'
        }
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly -ParameterFilter {
            $LauncherTaskName -eq 'Codex Remote Control Launcher'
        }
    }

    It 'neither checks for nor starts the daemon under -NoCodexRemoteControl' {
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs -NoCodexRemoteControl

        $result.CodexRemoteControlLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Test-CodexRemoteControl -Times 0 -Exactly
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
    }

    It 'only logs the start under -DryRun' {
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $false }

        $result = Invoke-ClaudeSessionKeeper @script:keeperArgs -DryRun

        $result.CodexRemoteControlLaunched | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 0 -Exactly
        Get-Content -LiteralPath $script:keeperArgs.LogFile -Raw | Should -Match 'DryRun: would run codex remote-control start'
    }
}

Describe 'Test-CodexRemoteControl' {

    BeforeEach {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
    }

    It 'recognizes "<Line>" as the remote-control daemon' -ForEach @(
        # The managed daemon, as codex-cli 0.160.0 names it (path is a fake example).
        @{ Line = '4242 /home/x/.codex/packages/standalone/releases/0.0.0/bin/codex app-server --remote-control --listen unix:// --managed-daemon' }
        @{ Line = '4242 codex app-server --managed-daemon --remote-control' }
        @{ Line = 'codex app-server --remote-control --managed-daemon --listen unix://' }
        # The launcher itself, while it is still running in the foreground.
        @{ Line = 'codex remote-control start' }
        @{ Line = '4242 codex remote-control start' }
        @{ Line = '4242 /home/x/.local/bin/codex remote-control start --json' }
        @{ Line = '4242 node /home/x/.local/bin/codex remote-control start' }
    ) {
        $pgrepLine = $Line
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @($pgrepLine) }
        }.GetNewClosure()

        Test-CodexRemoteControl -DistroName 'Ubuntu' | Should -BeTrue
    }

    It 'rejects "<Line>"' -ForEach @(
        @{ Line = '4242 codex exec --json example' }
        @{ Line = '4242 codex remote-control pair' }
        @{ Line = '4242 codex remote-control stop' }
        @{ Line = '4242 codex remote-control' }
        @{ Line = '4242 codex agents' }
        @{ Line = '4242 codex' }
        @{ Line = '4242 vim /home/x/notes/codex remote-control start.md' }
        @{ Line = '4242 less codex remote-control start' }
        @{ Line = '4242 codex remote-control start.md' }
        @{ Line = '4242 mycodex remote-control start' }
        @{ Line = '4242 /home/x/.local/bin/codex app-server daemon pid-update-loop' }
        @{ Line = '4242 codex app-server --listen stdio' }
        @{ Line = '4242 codex app-server --managed-daemon --listen unix://' }
        @{ Line = '4242 codex app-server --remote-control --listen unix://' }
        @{ Line = '4242 codex app-server --remote-controlx --managed-daemon' }
        @{ Line = '4242 /mnt/c/x/codex -c features.example=true app-server --analytics-default-enabled' }
        @{ Line = '4242 codex-code-mode-host' }
        @{ Line = '4242 grep codex app-server --remote-control --managed-daemon' }
    ) {
        $pgrepLine = $Line
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @($pgrepLine) }
        }.GetNewClosure()

        Test-CodexRemoteControl -DistroName 'Ubuntu' | Should -BeFalse
    }

    It 'finds the daemon among other codex processes' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @(
                    '10 codex agents',
                    '11 codex app-server --remote-control --listen unix:// --managed-daemon',
                    '12 codex app-server daemon pid-update-loop'
                )
            }
        }

        Test-CodexRemoteControl -DistroName 'Ubuntu' | Should -BeTrue
    }

    It 'runs pgrep -af codex inside the named distro' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('1 codex remote-control start') }
        }

        Test-CodexRemoteControl -DistroName 'Debian' | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Debian|--|pgrep|-af|codex'
        }
    }

    It 'returns false without ever running pgrep when the distro is not Running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('1 codex remote-control start') }
        }

        Test-CodexRemoteControl -DistroName 'Ubuntu' | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'returns false when pgrep exits nonzero' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 1; Output = @('1 codex remote-control start') }
        }

        Test-CodexRemoteControl -DistroName 'Ubuntu' | Should -BeFalse
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
        # Only these four fields are carried; the session's name/title never is.
        @($sessions[0].PSObject.Properties.Name) | Should -Be @('SessionId', 'Cwd', 'Kind', 'Working')
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Ubuntu|--exec|bash|-l|-c|claude agents --json'
        }
    }

    It 'maps Working from status "busy" or state "working" exactly, and to $false otherwise or when missing' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    ('[{"sessionId":"a0000000-0000-4000-8000-000000000000","cwd":"/x","status":"busy"},' +
                        '{"sessionId":"b0000000-0000-4000-8000-000000000000","cwd":"/x","state":"working"},' +
                        '{"sessionId":"c0000000-0000-4000-8000-000000000000","cwd":"/x","status":"idle","state":"blocked"},' +
                        '{"sessionId":"d0000000-0000-4000-8000-000000000000","cwd":"/x"},' +
                        '{"sessionId":"e0000000-0000-4000-8000-000000000000","cwd":"/x","status":"Busy","state":"Working"},' +
                        '{"sessionId":"f0000000-0000-4000-8000-000000000000","cwd":"/x","status":"idle","state":"working"}]')
                )
            }
        }

        $working = InModuleScope WslAutomation { @((Get-ClaudeAgentSessions -DistroName 'Ubuntu').Working) }

        $working | Should -Be @($true, $true, $false, $false, $false, $true)
        $working | ForEach-Object { $_ | Should -BeOfType [bool] }
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

    It 'adds the prompt as a separate trailing argument after the session id, never inside the script text' {
        $prompt = 'Continue; "quoted" $(touch /tmp/x) text'
        InModuleScope WslAutomation -Parameters @{ P = $prompt } {
            Start-ClaudeSessionResume -DistroName 'Ubuntu' -SessionId 'c2165965-516f-5d82-ad4d-afa62ee6a8ed' -Cwd '/home/u/repo' -ContinuePrompt $P
        } | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 11 -and
            ($Arguments[0..6] -join '|') -eq '-d|Ubuntu|--exec|bash|-l|-c|cd -- "$1" && exec claude --bg --resume "$2" "$3"' -and
            $Arguments[7] -eq 'bash' -and
            $Arguments[8] -eq '/home/u/repo' -and
            $Arguments[9] -eq 'c2165965-516f-5d82-ad4d-afa62ee6a8ed' -and
            $Arguments[10] -eq 'Continue; "quoted" $(touch /tmp/x) text'
        }
    }

    It 'keeps the original argument array when the prompt is empty' {
        InModuleScope WslAutomation {
            Start-ClaudeSessionResume -DistroName 'Ubuntu' -SessionId 'c2165965-516f-5d82-ad4d-afa62ee6a8ed' -Cwd '/home/u/repo' -ContinuePrompt ''
        } | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 10 -and $Arguments[6] -eq 'cd -- "$1" && exec claude --bg --resume "$2"'
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

    It 'round-trips the working flag per session' {
        $path = Join-Path $TestDrive 'working-snapshot.json'

        $snapshot = InModuleScope WslAutomation -Parameters @{ P = $path } {
            Write-ClaudeAgentSnapshot -Path $P -Sessions @(
                [pscustomobject]@{ SessionId = 'a0000000-0000-4000-8000-000000000000'; Cwd = '/x'; Kind = 'background'; Working = $true }
                [pscustomobject]@{ SessionId = 'b0000000-0000-4000-8000-000000000000'; Cwd = '/x'; Kind = 'background'; Working = $false }
                [pscustomobject]@{ SessionId = 'c0000000-0000-4000-8000-000000000000'; Cwd = '/x'; Kind = 'background' }
            )
            Read-ClaudeAgentSnapshot -Path $P
        }

        @($snapshot.Sessions.Working) | Should -Be @($true, $false, $false)
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).sessions[0].working | Should -BeTrue
    }

    It 'reads a snapshot written before the working field existed with Working = $false' {
        $path = Join-Path $TestDrive 'old-snapshot.json'
        Set-Content -LiteralPath $path -Value ('{"capturedAt":"2026-10-01T00:00:00Z","restorePending":false,"sessions":[' +
            '{"sessionId":"a0000000-0000-4000-8000-000000000000","cwd":"/x","kind":"background"}]}')

        $snapshot = InModuleScope WslAutomation -Parameters @{ P = $path } { Read-ClaudeAgentSnapshot -Path $P }

        @($snapshot.Sessions).Count | Should -Be 1
        $snapshot.Sessions[0].Working | Should -BeFalse
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
