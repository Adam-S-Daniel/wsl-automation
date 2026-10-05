#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

    function Get-ExpectedTag {
        if ((Get-Date).DayOfWeek -eq 'Sunday') { 'weekly' } else { 'daily' }
    }

    # Writes a fixture backup whose real LastWriteTime (which the force check reads, not the date
    # in the file name) is the given instant.
    function Write-AgedBackup {
        param([string]$Directory, [datetime]$LastWriteTime)
        $path = Join-Path -Path $Directory -ChildPath "wsl-ubuntu-daily-$($LastWriteTime.ToString('yyyy-MM-dd')).tar"
        Set-Content -Path $path -Value 'aged' -NoNewline
        (Get-Item -Path $path).LastWriteTime = $LastWriteTime
    }
}

Describe 'Invoke-WslBackup' {
    BeforeEach {
        $script:backupDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        $script:stagingDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        $script:lockPath = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString()) -AdditionalChildPath 'backup.lock'
        New-Item -ItemType Directory -Path $script:backupDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:stagingDir -Force | Out-Null

        # Every test in this Describe block that reaches past the skip-guard now runs through the
        # wake guard and the activity gate. Default both to "clear to export" here - well past
        # -MinMinutesSinceWake and idle - so tests that predate the gate keep exercising only what
        # they were written to exercise; tests for the gates themselves override these per-test.
        # Per the rules for this repo, no test may touch the real event log or run real wsl.exe -
        # Get-LastWakeTime and Test-WslActivity are private/public module functions, so mocking
        # them by name (like Invoke-WslExe below) keeps this file entirely off both.
        Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith {
            (Get-Date).AddHours(-1)
        }

        # The pre-export session recording (step 10) lists sessions through wsl.exe and writes
        # the keeper's snapshot under -SessionSnapshotPath, whose default is built from
        # LOCALAPPDATA. Point that at the test drive (so no test can touch the real file, and the
        # default resolves on a machine without LOCALAPPDATA) and default the list to "no sessions".
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        $script:snapshotPath = Join-Path $env:LOCALAPPDATA 'wsl-automation' 'agents-snapshot.json'
        Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith { , @() }
        Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
            [pscustomobject]@{
                IsActive           = $false
                Reason             = 'Idle'
                ActiveProcessCount = 0
                ActiveCommands     = @()
                RemoteControlPids  = @()
                IdleClaudePids     = @()
            }
        }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:savedLocalAppData
    }

    Context 'a successful tar export' {
        It 'returns Completed, produces the final file, empties staging, logs Done, and releases the lock' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -DistroName 'Ubuntu' -Format 'tar' `
                -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $result.FilePath | Should -Exist
            $result.SizeMB | Should -BeGreaterOrEqual 0

            Get-ChildItem -Path $script:stagingDir -File | Should -BeNullOrEmpty

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            $logFile | Should -Exist
            $logContent = Get-Content -Path $logFile -Raw
            $logContent | Should -Match ([regex]::Escape('=== WSL backup starting (distro=Ubuntu format=tar) ==='))
            $logContent | Should -Match '=== Done ==='

            Test-Path -Path $script:lockPath | Should -BeFalse

            # Pins the export target to StagingDir, not directly to BackupDir - if the
            # implementation exported straight into BackupDir (defeating the stage-then-move
            # design this module exists for), staging would trivially stay empty and the mock
            # would still create the final file, so this must be asserted explicitly rather than
            # inferred from the staging-is-empty check above.
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq '--export' -and $Arguments[2] -like "$($script:stagingDir)*"
            }

            # The two-step .partial move (spec step 9) leaves no .partial artifact behind in
            # BackupDir once a run completes successfully.
            Get-ChildItem -Path $script:backupDir -Filter '*.partial' -File | Should -BeNullOrEmpty
        }
    }

    Context 'export format flag handling' {
        It 'does not pass --vhd when Format is tar' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -Format 'tar' `
                -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            Should -Not -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -ParameterFilter {
                $Arguments -contains '--vhd'
            }
        }

        It 'passes --vhd when Format is vhdx' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                Set-Content -Path $Arguments[2] -Value 'fake vhdx payload' -NoNewline
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -Format 'vhdx' `
                -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -ParameterFilter {
                $Arguments -contains '--vhd'
            }
        }
    }

    Context 'export failure' {
        It 'throws, logs the error and wsl output, cleans staging, and releases the lock' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                Set-Content -Path $Arguments[2] -Value 'partial junk' -NoNewline
                [pscustomobject]@{ ExitCode = 1; Output = @('boom') }
            }

            { Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath } |
                Should -Throw

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            $logContent = Get-Content -Path $logFile -Raw
            $logContent | Should -Match 'ERROR:'
            $logContent | Should -Match '  wsl: boom'

            Get-ChildItem -Path $script:stagingDir -File | Should -BeNullOrEmpty
            Test-Path -Path $script:lockPath | Should -BeFalse
        }
    }

    Context 'skip guard' {
        It 'skips when the final backup file already exists, never calls the export, and logs nothing' {
            # No log line at all for this case (unlike the deferral statuses below, which do log
            # one line): the backup task's hourly retry trigger would otherwise add up to 23
            # identical "already exists" lines to the log every day.
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $tag = Get-ExpectedTag
            $fileName = "wsl-ubuntu-$tag-$(Get-Date -Format 'yyyy-MM-dd').tar"
            $finalPath = Join-Path -Path $script:backupDir -ChildPath $fileName
            Set-Content -Path $finalPath -Value 'already here' -NoNewline

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Skipped'
            Should -Not -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation
            Should -Not -Invoke -CommandName Get-LastWakeTime -ModuleName WslAutomation
            Should -Not -Invoke -CommandName Test-WslActivity -ModuleName WslAutomation

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            Test-Path -Path $logFile | Should -BeFalse
        }
    }

    Context 'retention' {
        It 'keeps only the newest RetentionCount daily tar backups and leaves other-format backups untouched' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $tag = Get-ExpectedTag
            $oldDates = 5, 4, 3 | ForEach-Object { (Get-Date).AddDays(-$_).ToString('yyyy-MM-dd') }
            foreach ($d in $oldDates) {
                $oldTarPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$d.tar"
                $oldVhdxPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$d.vhdx"
                Set-Content -Path $oldTarPath -Value 'old tar' -NoNewline
                Set-Content -Path $oldVhdxPath -Value 'old vhdx' -NoNewline
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -Format 'tar' `
                -StagingDir $script:stagingDir -LockPath $script:lockPath -RetentionCount 2

            $result.Status | Should -Be 'Completed'

            $tarFiles = Get-ChildItem -Path $script:backupDir -Filter "wsl-ubuntu-$tag-*.tar"
            $tarFiles.Count | Should -Be 2
            $keptLeaf = Split-Path -Path $result.FilePath -Leaf
            $keptLeaf | Should -BeIn $tarFiles.Name

            $vhdxFiles = Get-ChildItem -Path $script:backupDir -Filter "wsl-ubuntu-$tag-*.vhdx"
            $vhdxFiles.Count | Should -Be 3
        }
    }

    Context 'orphaned .partial cleanup in BackupDir' {
        It 'removes a leftover "<name>.partial" file in BackupDir left by a prior killed run, before exporting' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $tag = Get-ExpectedTag
            $orphanDate = (Get-Date).AddDays(-3).ToString('yyyy-MM-dd')
            $orphanedPartialPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$orphanDate.tar.partial"
            Set-Content -Path $orphanedPartialPath -Value 'half-written export from a killed run' -NoNewline

            $result = Invoke-WslBackup -BackupDir $script:backupDir -Format 'tar' `
                -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            # Neither the retention filter nor the retained-listing extension check matches
            # ".partial", so without an explicit sweep this file would persist forever.
            Test-Path -Path $orphanedPartialPath | Should -BeFalse
        }
    }

    Context 'zero-length staging file' {
        It 'throws when the exported staging file is zero-length' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                New-Item -ItemType File -Path $Arguments[2] -Force | Out-Null
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            { Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath } |
                Should -Throw

            Test-Path -Path $script:lockPath | Should -BeFalse
        }
    }

    Context 'wake guard' {
        It 'defers with DeferredRecentWake and never exports when the machine woke recently' {
            Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith { (Get-Date).AddMinutes(-5) }
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'DeferredRecentWake'
            Should -Not -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            (Get-Content -Path $logFile -Raw) | Should -Match 'Deferred: only \d+ min since boot/resume \(need 10\)'
        }
    }

    Context 'activity gate' {
        BeforeEach {
            # The force window reads the local hour, so pin Get-Date inside the module (this also
            # drives the log timestamp, hence the -Format branch). A Friday, so the tag is daily.
            $script:clock = @{ Now = [datetime]'2026-10-02T03:30:00' }
            $clock = $script:clock
            Mock -CommandName Get-Date -ModuleName WslAutomation -MockWith ({
                    param([string]$Format)
                    if ($Format) { $clock.Now.ToString($Format) } else { $clock.Now }
                }.GetNewClosure())
            # The outer BeforeEach's wake time is relative to the real clock; keep it an hour back
            # on the pinned one so the wake guard stays clear.
            Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith ({ $clock.Now.AddHours(-1) }.GetNewClosure())
        }

        It 'defers with DeferredBusy, never exports, and never logs process arguments when busy with a fresh backup' {
            # The force check reads real LastWriteTime (per spec), not the date embedded in the
            # filename, so the fixture file's timestamp has to be backdated explicitly.
            $tag = Get-ExpectedTag
            $freshDate = $script:clock.Now.AddDays(-1).ToString('yyyy-MM-dd')
            $freshBackupPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$freshDate.tar"
            Set-Content -Path $freshBackupPath -Value 'fresh' -NoNewline
            (Get-Item -Path $freshBackupPath).LastWriteTime = $script:clock.Now.AddDays(-1)

            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
                    IdleClaudePids     = @()
                }
            }
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'DeferredBusy'
            Should -Not -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            $logContent = Get-Content -Path $logFile -Raw
            $logContent | Should -Match 'Deferred: WSL in use \(1 interactive process\(es\): bash\); newest backup is 1 day\(s\) old'
            # Test-WslActivity never returns raw process arguments, so there is nothing for the
            # log to leak - this pins that no args-shaped text sneaks into the message.
            $logContent | Should -Not -Match '--'
        }

        It 'exports and logs "Forcing" when busy, inside the force window, and the newest backup is older than ForceAfterDays' {
            $tag = Get-ExpectedTag
            $oldDate = $script:clock.Now.AddDays(-10).ToString('yyyy-MM-dd')
            $oldBackupPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$oldDate.tar"
            Set-Content -Path $oldBackupPath -Value 'old' -NoNewline
            (Get-Item -Path $oldBackupPath).LastWriteTime = $script:clock.Now.AddDays(-10)

            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
                    IdleClaudePids     = @()
                }
            }
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            (Get-Content -Path $logFile -Raw) | Should -Match 'Forcing export: newest backup is 10 day\(s\) old \(limit 3; force window 02:00-06:00\)'
        }

        It 'exports when busy, inside the force window, and no backups exist at all' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
                    IdleClaudePids     = @()
                }
            }
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
        }

        It 'exports when -IgnoreActivity is set, even though WSL looks busy' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
                    IdleClaudePids     = @()
                }
            }
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath -IgnoreActivity

            $result.Status | Should -Be 'Completed'
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq '--export'
            }
        }
    }

    Context 'force window' {
        BeforeEach {
            # The force window reads the local hour, so pin Get-Date inside the module (this also
            # drives the log timestamp, hence the -Format branch). A Friday, so the tag is daily.
            $script:clock = @{ Now = [datetime]'2026-10-02T03:30:00' }
            $clock = $script:clock
            Mock -CommandName Get-Date -ModuleName WslAutomation -MockWith ({
                    param([string]$Format)
                    if ($Format) { $clock.Now.ToString($Format) } else { $clock.Now }
                }.GetNewClosure())
            # The outer BeforeEach's wake time is relative to the real clock; keep it an hour back
            # on the pinned one so the wake guard stays clear.
            Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith ({ $clock.Now.AddHours(-1) }.GetNewClosure())

            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
                    IdleClaudePids     = @()
                }
            }
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }
            $script:logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
        }

        It 'forces an overdue backup through a busy distro when the hour is inside the window' {
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-10)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            # Busy distro, yet exported: the force path skipped the activity gate's deferral.
            $result.Status | Should -Be 'Completed'
            (Get-Content -Path $script:logFile -Raw) | Should -Match 'Forcing export: .*force window 02:00-06:00'
            (Get-Content -Path $script:logFile -Raw) | Should -Not -Match 'Deferred'
        }

        It 'defers a busy distro when overdue but outside the window, and says it is waiting for the window' {
            $script:clock.Now = [datetime]'2026-10-02T12:00:00'
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-10)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'DeferredBusy'
            Should -Not -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation
            $logContent = Get-Content -Path $script:logFile -Raw
            $logContent | Should -Match ([regex]::Escape('Deferred: WSL in use (1 interactive process(es): bash); newest backup is 10 day(s) old; overdue - forcing only between 02:00 and 06:00'))
            $logContent | Should -Not -Match 'Forcing export'
        }

        It 'does not mention the window when deferring a backup that is not overdue' {
            $script:clock.Now = [datetime]'2026-10-02T12:00:00'
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-1)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'DeferredBusy'
            (Get-Content -Path $script:logFile -Raw) | Should -Not -Match 'overdue'
        }

        It 'defers a busy distro outside the window when no backup exists at all' {
            $script:clock.Now = [datetime]'2026-10-02T12:00:00'

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'DeferredBusy'
            (Get-Content -Path $script:logFile -Raw) | Should -Match 'overdue - forcing only between 02:00 and 06:00'
        }

        It 'exports an overdue backup outside the window when the distro is idle, without logging "Forcing"' {
            $script:clock.Now = [datetime]'2026-10-02T12:00:00'
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-10)
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $false
                    Reason             = 'Idle'
                    ActiveProcessCount = 0
                    ActiveCommands     = @()
                    RemoteControlPids  = @()
                    IdleClaudePids     = @()
                }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            (Get-Content -Path $script:logFile -Raw) | Should -Not -Match 'Forcing export'
        }

        It 'treats the window as start-inclusive, end-exclusive: <Time> -> <Expected>' -ForEach @(
            @{ Time = '2026-10-02T01:59:59'; Expected = 'DeferredBusy' }
            @{ Time = '2026-10-02T02:00:00'; Expected = 'Completed' }
            @{ Time = '2026-10-02T05:59:59'; Expected = 'Completed' }
            @{ Time = '2026-10-02T06:00:00'; Expected = 'DeferredBusy' }
        ) {
            $script:clock.Now = [datetime]$Time
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-10)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be $Expected
        }

        It 'supports a window that wraps midnight (22 -> 4): <Time> -> <Expected>' -ForEach @(
            @{ Time = '2026-10-02T21:59:59'; Expected = 'DeferredBusy' }
            @{ Time = '2026-10-02T22:00:00'; Expected = 'Completed' }
            @{ Time = '2026-10-02T23:30:00'; Expected = 'Completed' }
            @{ Time = '2026-10-03T00:00:00'; Expected = 'Completed' }
            @{ Time = '2026-10-03T03:59:59'; Expected = 'Completed' }
            @{ Time = '2026-10-03T04:00:00'; Expected = 'DeferredBusy' }
            @{ Time = '2026-10-03T12:00:00'; Expected = 'DeferredBusy' }
        ) {
            $script:clock.Now = [datetime]$Time
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-10)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath `
                -ForceWindowStartHour 22 -ForceWindowEndHour 4

            $result.Status | Should -Be $Expected
        }

        It 'forces at any hour when start equals end: <Time> with window <Hour>-<Hour>' -ForEach @(
            @{ Time = '2026-10-02T12:00:00'; Hour = 0 }
            @{ Time = '2026-10-02T12:00:00'; Hour = 12 }
            @{ Time = '2026-10-02T03:00:00'; Hour = 7 }
        ) {
            $script:clock.Now = [datetime]$Time
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-10)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath `
                -ForceWindowStartHour $Hour -ForceWindowEndHour $Hour

            $result.Status | Should -Be 'Completed'
            (Get-Content -Path $script:logFile -Raw) | Should -Match 'Forcing export: .*force window any hour'
        }

        It 'defaults ForceAfterDays to 3: a 3-day-old backup is forced inside the window' {
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-3)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            (Get-Content -Path $script:logFile -Raw) | Should -Match 'Forcing export: newest backup is 3 day\(s\) old \(limit 3;'
        }

        It 'defaults ForceAfterDays to 3: a 2-day-old backup is not forced, even inside the window' {
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-2)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'DeferredBusy'
            $logContent = Get-Content -Path $script:logFile -Raw
            $logContent | Should -Not -Match 'Forcing export'
            $logContent | Should -Not -Match 'overdue'
        }

        It 'never forces when ForceAfterDays is 0, even inside the window' {
            Write-AgedBackup -Directory $script:backupDir -LastWriteTime $script:clock.Now.AddDays(-30)

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath -ForceAfterDays 0

            $result.Status | Should -Be 'DeferredBusy'
            (Get-Content -Path $script:logFile -Raw) | Should -Not -Match 'overdue'
        }

        It 'rejects a window hour outside 0-23: <Parameter> <Value>' -ForEach @(
            @{ Parameter = 'ForceWindowStartHour'; Value = 24 }
            @{ Parameter = 'ForceWindowStartHour'; Value = -1 }
            @{ Parameter = 'ForceWindowEndHour'; Value = 24 }
            @{ Parameter = 'ForceWindowEndHour'; Value = -1 }
        ) {
            $extra = @{ $Parameter = $Value }

            { Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath @extra } |
                Should -Throw
        }
    }

    Context 'Remote Control session stop' {
        It 'sends kill -TERM to each Remote Control pid, strictly before the export call' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $false
                    Reason             = 'Idle'
                    ActiveProcessCount = 0
                    ActiveCommands     = @()
                    RemoteControlPids  = @(4242)
                    IdleClaudePids     = @()
                }
            }

            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                $script:callOrder.Add($Arguments -join ' ')
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'

            $killIndex = -1
            $exportIndex = -1
            for ($i = 0; $i -lt $script:callOrder.Count; $i++) {
                if ($killIndex -lt 0 -and $script:callOrder[$i] -match 'kill -TERM 4242') { $killIndex = $i }
                if ($exportIndex -lt 0 -and $script:callOrder[$i] -match '^--export ') { $exportIndex = $i }
            }
            $killIndex | Should -BeGreaterOrEqual 0
            $exportIndex | Should -BeGreaterOrEqual 0
            $killIndex | Should -BeLessThan $exportIndex

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            (Get-Content -Path $logFile -Raw) | Should -Match 'Stopped Claude Remote Control session before export'
        }
    }

    Context 'idle Claude session stop' {
        It 'sends kill -TERM to each idle Claude pid strictly before the export call, and logs only the count' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $false
                    Reason             = 'Idle'
                    ActiveProcessCount = 0
                    ActiveCommands     = @()
                    RemoteControlPids  = @()
                    IdleClaudePids     = @(31073, 42424)
                }
            }

            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                $script:callOrder.Add($Arguments -join ' ')
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'

            $killIndexes = @()
            $exportIndex = -1
            for ($i = 0; $i -lt $script:callOrder.Count; $i++) {
                if ($script:callOrder[$i] -match 'kill -TERM (31073|42424)') { $killIndexes += $i }
                if ($exportIndex -lt 0 -and $script:callOrder[$i] -match '^--export ') { $exportIndex = $i }
            }
            $killIndexes.Count | Should -Be 2
            $exportIndex | Should -BeGreaterOrEqual 0
            foreach ($killIndex in $killIndexes) {
                $killIndex | Should -BeLessThan $exportIndex
            }

            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            $logContent = Get-Content -Path $logFile -Raw
            $logContent | Should -Match 'Stopped 2 idle Claude session\(s\) before export \(resumable with claude --resume\)'
            # Never a session id, pid or path in the log.
            $logContent | Should -Not -Match '31073'
            $logContent | Should -Not -Match '42424'
        }

        It 'logs nothing extra when there are no idle Claude sessions to stop' {
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
            (Get-Content -Path $logFile -Raw) | Should -Not -Match 'idle Claude session'
        }
    }

    Context 'recording sessions for the keeper before the export' {
        BeforeEach {
            $script:idWorking = '11111111-1111-4111-8111-111111111111'
            $script:idIdle = '22222222-2222-4222-8222-222222222222'
            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
                param($Arguments)
                $script:callOrder.Add($Arguments -join ' ')
                if ($Arguments[0] -eq '--export') {
                    Set-Content -Path $Arguments[2] -Value 'fake tar payload' -NoNewline
                }
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }
            $script:logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
        }

        It 'writes a restore-pending snapshot of the listed sessions strictly before any kill -TERM and before the export' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $false
                    Reason             = 'Idle'
                    ActiveProcessCount = 0
                    ActiveCommands     = @()
                    RemoteControlPids  = @(4242)
                    IdleClaudePids     = @(31073)
                }
            }
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith {
                , @(
                    [pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/a'; Kind = 'background'; Working = $true }
                    [pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/home/u/b'; Kind = 'background'; Working = $false }
                )
            }
            Mock -CommandName Write-ClaudeAgentSnapshot -ModuleName WslAutomation -MockWith {
                $script:callOrder.Add("snapshot pending=$([bool]$RestorePending) sessions=$(@($Sessions).Count) path=$Path")
            }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $snapshotIndex = -1
            $exportIndex = -1
            $killIndexes = @()
            for ($i = 0; $i -lt $script:callOrder.Count; $i++) {
                if ($snapshotIndex -lt 0 -and $script:callOrder[$i] -like 'snapshot *') { $snapshotIndex = $i }
                if ($script:callOrder[$i] -match 'kill -TERM') { $killIndexes += $i }
                if ($exportIndex -lt 0 -and $script:callOrder[$i] -match '^--export ') { $exportIndex = $i }
            }
            $snapshotIndex | Should -BeGreaterOrEqual 0
            $killIndexes.Count | Should -Be 2
            foreach ($killIndex in $killIndexes) {
                $snapshotIndex | Should -BeLessThan $killIndex
            }
            $snapshotIndex | Should -BeLessThan $exportIndex
            $script:callOrder[$snapshotIndex] | Should -Be "snapshot pending=True sessions=2 path=$($script:snapshotPath)"

            $logContent = Get-Content -Path $script:logFile -Raw
            $logContent | Should -Match ([regex]::Escape('Recorded 2 Claude session(s) for the keeper to resume after the export'))
            $logContent | Should -Not -Match $script:idWorking
            $logContent | Should -Not -Match $script:idIdle
        }

        It 'persists the sessions, including which were mid-turn, as a restore-pending snapshot file' {
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith {
                , @(
                    [pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/a'; Kind = 'background'; Working = $true }
                    [pscustomobject]@{ SessionId = '22222222-2222-4222-8222-222222222222'; Cwd = '/home/u/b'; Kind = 'background'; Working = $false }
                )
            }

            Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath | Out-Null

            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
            $snapshot.restorePending | Should -BeTrue
            @($snapshot.sessions).Count | Should -Be 2
            $snapshot.sessions[0].sessionId | Should -Be $script:idWorking
            $snapshot.sessions[0].working | Should -BeTrue
            $snapshot.sessions[1].working | Should -BeFalse
        }

        It 'honors -SessionSnapshotPath' {
            $customPath = Join-Path $TestDrive 'custom' 'snapshot.json'

            Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath `
                -SessionSnapshotPath $customPath | Out-Null

            $customPath | Should -Exist
            $script:snapshotPath | Should -Not -Exist
        }

        It 'marks the keeper''s last snapshot restore-pending, with the same sessions and timestamp, when the list is unreadable' {
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith { $null }
            New-Item -ItemType Directory -Path (Split-Path $script:snapshotPath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $script:snapshotPath -Value ('{"capturedAt":"2026-10-01T00:00:00.0000000Z","restorePending":false,"sessions":[' +
                '{"sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/home/u/a","kind":"background","working":true}]}')

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json -DateKind String
            $snapshot.restorePending | Should -BeTrue
            $snapshot.capturedAt | Should -Be '2026-10-01T00:00:00.0000000Z'
            @($snapshot.sessions).Count | Should -Be 1
            $snapshot.sessions[0].sessionId | Should -Be $script:idWorking
            $snapshot.sessions[0].working | Should -BeTrue
            $logContent = Get-Content -Path $script:logFile -Raw
            $logContent | Should -Match 'kept the keeper''s last snapshot for restore'
            $logContent | Should -Not -Match $script:idWorking
        }

        It 'leaves a snapshot that is already restore-pending untouched when the list is unreadable' {
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith { $null }
            Mock -CommandName Write-ClaudeAgentSnapshot -ModuleName WslAutomation -MockWith { }
            New-Item -ItemType Directory -Path (Split-Path $script:snapshotPath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $script:snapshotPath -Value ('{"capturedAt":"2026-10-01T00:00:00.0000000Z","restorePending":true,"sessions":[' +
                '{"sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/home/u/a","kind":"background"}]}')

            Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath | Out-Null

            Should -Invoke -CommandName Write-ClaudeAgentSnapshot -ModuleName WslAutomation -Times 0 -Exactly
        }

        It 'records nothing, and says so, when the list is unreadable and no snapshot exists' {
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith { $null }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $script:snapshotPath | Should -Not -Exist
            Get-Content -Path $script:logFile -Raw | Should -Match 'nothing to record for restore'
        }

        It 'still exports, and logs the failure without any id, when the snapshot step throws' {
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith {
                , @([pscustomobject]@{ SessionId = '11111111-1111-4111-8111-111111111111'; Cwd = '/home/u/a'; Kind = 'background'; Working = $true })
            }
            Mock -CommandName Write-ClaudeAgentSnapshot -ModuleName WslAutomation -MockWith { throw 'disk full for 11111111-1111-4111-8111-111111111111' }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
            $result.FilePath | Should -Exist
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq '--export'
            }
            $logContent = Get-Content -Path $script:logFile -Raw
            $logContent | Should -Match 'Failed to record Claude sessions for restore'
            $logContent | Should -Not -Match $script:idWorking
            Test-Path -Path $script:lockPath | Should -BeFalse
        }

        It 'still exports when listing the sessions throws' {
            Mock -CommandName Get-ClaudeAgentSessions -ModuleName WslAutomation -MockWith { throw 'boom' }

            $result = Invoke-WslBackup -BackupDir $script:backupDir -StagingDir $script:stagingDir -LockPath $script:lockPath

            $result.Status | Should -Be 'Completed'
        }
    }
}
