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
        It 'skips when the final backup file already exists and never calls the export' {
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
}
