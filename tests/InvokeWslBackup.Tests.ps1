#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

    function Get-ExpectedTag {
        if ((Get-Date).DayOfWeek -eq 'Sunday') { 'weekly' } else { 'daily' }
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
        Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
            [pscustomobject]@{
                IsActive           = $false
                Reason             = 'Idle'
                ActiveProcessCount = 0
                ActiveCommands     = @()
                RemoteControlPids  = @()
            }
        }
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
        It 'defers with DeferredBusy, never exports, and never logs process arguments when busy with a fresh backup' {
            # The force check reads real LastWriteTime (per spec), not the date embedded in the
            # filename, so the fixture file's timestamp has to be backdated explicitly.
            $tag = Get-ExpectedTag
            $freshDate = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
            $freshBackupPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$freshDate.tar"
            Set-Content -Path $freshBackupPath -Value 'fresh' -NoNewline
            (Get-Item -Path $freshBackupPath).LastWriteTime = (Get-Date).AddDays(-1)

            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
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

        It 'exports and logs "Forcing" when busy but the newest backup is older than ForceAfterDays' {
            $tag = Get-ExpectedTag
            $oldDate = (Get-Date).AddDays(-10).ToString('yyyy-MM-dd')
            $oldBackupPath = Join-Path -Path $script:backupDir -ChildPath "wsl-ubuntu-$tag-$oldDate.tar"
            Set-Content -Path $oldBackupPath -Value 'old' -NoNewline
            (Get-Item -Path $oldBackupPath).LastWriteTime = (Get-Date).AddDays(-10)

            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
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
            (Get-Content -Path $logFile -Raw) | Should -Match 'Forcing export: newest backup is 10 day\(s\) old \(limit 9\)'
        }

        It 'exports when busy and no backups exist at all' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $true
                    Reason             = 'Active'
                    ActiveProcessCount = 1
                    ActiveCommands     = @('bash')
                    RemoteControlPids  = @()
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

    Context 'Remote Control session stop' {
        It 'sends kill -TERM to each Remote Control pid, strictly before the export call' {
            Mock -CommandName Test-WslActivity -ModuleName WslAutomation -MockWith {
                [pscustomobject]@{
                    IsActive           = $false
                    Reason             = 'Idle'
                    ActiveProcessCount = 0
                    ActiveCommands     = @()
                    RemoteControlPids  = @(4242)
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
}
