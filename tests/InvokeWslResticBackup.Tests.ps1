#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Invoke-WslResticBackup' {
    BeforeEach {
        $script:backupDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        $script:statePath = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString()) -AdditionalChildPath 'restic-last-success.txt'
        $script:logFile = Join-Path -Path $script:backupDir -ChildPath 'wsl-ubuntu-backup.log'
        New-Item -ItemType Directory -Path $script:backupDir -Force | Out-Null
        # Never touched for real: Invoke-RobocopyExe is mocked, and a drive-letter path is all
        # ConvertTo-WslMountPath needs.
        $script:repoDir = 'D:\Backups\wsl-restic'
        $script:scriptsDir = 'C:\repos\wsl-automation\scripts'

        # Pin the clock inside the module (the -Format branch drives the log timestamp). A
        # Wednesday, so the weekly maintenance day decides 'weekly' vs 'none' deterministically.
        $script:clock = @{ Now = [datetime]'2026-10-21T02:00:00' }
        $clock = $script:clock
        Mock -CommandName Get-Date -ModuleName WslAutomation -MockWith ({
                param([string]$Format)
                if ($Format) { $clock.Now.ToString($Format) } else { $clock.Now }
            }.GetNewClosure())

        # Well clear of -MinMinutesSinceWake by default; the wake-guard tests override this. No
        # test may read the real event log.
        Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith ({ $clock.Now.AddHours(-1) }.GetNewClosure())

        # The restic script's output, as Invoke-WslExe returns it: the summary lines plus lines
        # that must never be logged (a path, and wsl.exe's own chatter).
        $script:wslOutput = @(
            'wsl: Failed to start the systemd user session for ''someone''.',
            'new       /home/someone/private-notes.txt',
            'Added to the repository: 12.345 MiB (4.567 MiB stored)',
            'processed 123456 files, 20.123 GiB in 1:23',
            'errors=0'
        )
        $script:wslExitCode = 0
        Mock -CommandName Invoke-WslExe -ModuleName WslAutomation -MockWith {
            [pscustomobject]@{ ExitCode = $script:wslExitCode; Output = $script:wslOutput }
        }

        $script:robocopyCalls = [System.Collections.Generic.List[object]]::new()
        $script:robocopyExitCode = 1
        Mock -CommandName Invoke-RobocopyExe -ModuleName WslAutomation -MockWith {
            param($Arguments)
            $script:robocopyCalls.Add(@($Arguments))
            [pscustomobject]@{ ExitCode = $script:robocopyExitCode; Output = @('D:\Backups\wsl-restic\data\00\0011223344') }
        }

        $script:baseParams = @{
            BackupDir            = $script:backupDir
            RepoDir              = $script:repoDir
            ScriptsDir           = $script:scriptsDir
            StatePath            = $script:statePath
            WeeklyMaintenanceDay = [System.DayOfWeek]::Sunday
        }
    }

    Context 'skip guard' {
        It 'returns Skipped with no log line and no wsl or robocopy call when today already succeeded' {
            New-Item -ItemType Directory -Path (Split-Path $script:statePath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $script:statePath -Value '2026-10-21' -NoNewline

            $result = Invoke-WslResticBackup @script:baseParams

            $result.Status | Should -Be 'Skipped'
            Test-Path -LiteralPath $script:logFile | Should -BeFalse
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-RobocopyExe -ModuleName WslAutomation -Times 0 -Exactly
            Should -Invoke -CommandName Get-LastWakeTime -ModuleName WslAutomation -Times 0 -Exactly
        }

        It 'runs when the state file holds an earlier date' {
            New-Item -ItemType Directory -Path (Split-Path $script:statePath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $script:statePath -Value '2026-10-20' -NoNewline

            $result = Invoke-WslResticBackup @script:baseParams

            $result.Status | Should -Be 'Completed'
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly
        }
    }

    Context 'wake guard' {
        It 'defers with DeferredRecentWake and one log line, running nothing, too soon after a wake' {
            $clock = $script:clock
            Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith ({ $clock.Now.AddMinutes(-3) }.GetNewClosure())

            $result = Invoke-WslResticBackup @script:baseParams

            $result.Status | Should -Be 'DeferredRecentWake'
            @(Get-Content -LiteralPath $script:logFile) | Should -HaveCount 1
            (Get-Content -LiteralPath $script:logFile -Raw) | Should -Match 'Deferred: only 3 min since boot/resume \(need 10\)'
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-RobocopyExe -ModuleName WslAutomation -Times 0 -Exactly
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }

        It 'honors -MinMinutesSinceWake' {
            $clock = $script:clock
            Mock -CommandName Get-LastWakeTime -ModuleName WslAutomation -MockWith ({ $clock.Now.AddMinutes(-3) }.GetNewClosure())

            $result = Invoke-WslResticBackup @script:baseParams -MinMinutesSinceWake 2

            $result.Status | Should -Be 'Completed'
        }
    }

    Context 'the restic script call' {
        It 'runs the script as root from the scripts dir with the converted repo path and maintenance none' {
            Invoke-WslResticBackup @script:baseParams -DistroName 'Debian' | Out-Null

            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join '|') -eq (@(
                        '-d', 'Debian', '-u', 'root', '--cd', 'C:\repos\wsl-automation\scripts', '--exec', '/bin/bash',
                        './wsl-restic-backup.sh', '/mnt/d/Backups/wsl-restic', '/root/.config/restic/password',
                        './wsl-restic-excludes.txt', 'none'
                    ) -join '|')
            }
        }

        It 'passes maintenance weekly on -WeeklyMaintenanceDay' {
            $weeklyParams = $script:baseParams.Clone()
            $weeklyParams['WeeklyMaintenanceDay'] = [System.DayOfWeek]::Wednesday

            Invoke-WslResticBackup @weeklyParams | Out-Null

            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly -ParameterFilter {
                $Arguments[-1] -eq 'weekly'
            }
        }

        It 'passes -PasswordFile through' {
            Invoke-WslResticBackup @script:baseParams -PasswordFile '/etc/restic/pw' | Out-Null

            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly -ParameterFilter {
                $Arguments[-3] -eq '/etc/restic/pw'
            }
        }

        It 'logs the start line, the exit code and only the summary lines' {
            Invoke-WslResticBackup @script:baseParams | Out-Null

            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match '=== WSL restic backup starting ==='
            $log | Should -Match 'restic script exit 0 \(OK\)'
            $log | Should -Match ([regex]::Escape('restic: Added to the repository: 12.345 MiB (4.567 MiB stored)'))
            $log | Should -Match ([regex]::Escape('restic: processed 123456 files, 20.123 GiB in 1:23'))
            $log | Should -Match ([regex]::Escape('restic: errors=0'))
        }

        It 'never logs a non-summary output line, a path or a user name, on success or failure' -ForEach @(
            @{ ExitCode = 0 }, @{ ExitCode = 10 }, @{ ExitCode = 30 }
        ) {
            $script:wslExitCode = $ExitCode
            try { Invoke-WslResticBackup @script:baseParams | Out-Null } catch { $null = $_ }

            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Not -Match 'private-notes'
            $log | Should -Not -Match '/home/'
            $log | Should -Not -Match 'someone'
            $log | Should -Not -Match 'password'
            $log | Should -Not -Match ([regex]::Escape('0011223344'))
        }
    }

    Context 'exit codes' {
        It 'maps exit 0 to Completed' {
            $result = Invoke-WslResticBackup @script:baseParams

            $result.Status | Should -Be 'Completed'
            $result.ExitCode | Should -Be 0
        }

        It 'maps exit 10 to CompletedPartial, still copying and recording success' {
            $script:wslExitCode = 10

            $result = Invoke-WslResticBackup @script:baseParams

            $result.Status | Should -Be 'CompletedPartial'
            $result.ExitCode | Should -Be 10
            (Get-Content -LiteralPath $script:logFile -Raw) | Should -Match 'restic script exit 10 \(PARTIAL'
            $script:robocopyCalls.Count | Should -Be 2
            Get-Content -LiteralPath $script:statePath -Raw | Should -Be '2026-10-21'
        }

        It 'throws on exit <ExitCode> with "<Meaning>", copying nothing and writing no state' -ForEach @(
            @{ ExitCode = 20; Meaning = 'restic is not installed' },
            @{ ExitCode = 21; Meaning = 'password file or repository missing' },
            @{ ExitCode = 30; Meaning = 'restic backup failed' },
            @{ ExitCode = 40; Meaning = 'forget/prune failed' },
            @{ ExitCode = 50; Meaning = 'restic check failed' },
            @{ ExitCode = 1; Meaning = 'unexpected exit code' }
        ) {
            $script:wslExitCode = $ExitCode

            { Invoke-WslResticBackup @script:baseParams } | Should -Throw "*exit $ExitCode*"

            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match ([regex]::Escape("restic script exit $ExitCode"))
            $log | Should -Match ([regex]::Escape($Meaning))
            $log | Should -Match 'ERROR: restic backup failed'
            $log | Should -Not -Match 'restic backup complete'
            Should -Invoke -CommandName Invoke-RobocopyExe -ModuleName WslAutomation -Times 0 -Exactly
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }
    }

    Context 'the one-way copy to the OneDrive dir' {
        It 'copies everything but snapshots, then mirrors snapshots, and nothing else on a daily run' {
            Invoke-WslResticBackup @script:baseParams | Out-Null

            $copyDir = Join-Path $script:backupDir 'restic'
            $options = '/R:2|/W:5|/NP|/NFL|/NDL|/NJH|/NJS'
            $script:robocopyCalls.Count | Should -Be 2
            ($script:robocopyCalls[0] -join '|') | Should -Be "$($script:repoDir)|$copyDir|/E|/XD|$($script:repoDir)\snapshots|$($script:repoDir)\locks|$options"
            ($script:robocopyCalls[1] -join '|') | Should -Be "$($script:repoDir)\snapshots|$copyDir\snapshots|/MIR|$options"
            @($script:robocopyCalls | Where-Object { $_ -contains '/MIR' -and $_[0] -notlike '*snapshots' }) | Should -HaveCount 0
        }

        It 'mirrors index and then data, after the snapshots, only on the weekly maintenance run' {
            $weeklyParams = $script:baseParams.Clone()
            $weeklyParams['WeeklyMaintenanceDay'] = [System.DayOfWeek]::Wednesday

            Invoke-WslResticBackup @weeklyParams | Out-Null

            $copyDir = Join-Path $script:backupDir 'restic'
            $script:robocopyCalls.Count | Should -Be 4
            $script:robocopyCalls[0][2] | Should -Be '/E'
            ($script:robocopyCalls[1][0..2] -join '|') | Should -Be "$($script:repoDir)\snapshots|$copyDir\snapshots|/MIR"
            ($script:robocopyCalls[2][0..2] -join '|') | Should -Be "$($script:repoDir)\index|$copyDir\index|/MIR"
            ($script:robocopyCalls[3][0..2] -join '|') | Should -Be "$($script:repoDir)\data|$copyDir\data|/MIR"
            foreach ($call in $script:robocopyCalls) {
                ($call[-7..-1] -join '|') | Should -Be '/R:2|/W:5|/NP|/NFL|/NDL|/NJH|/NJS'
            }
        }

        It 'accepts robocopy exit 7 as success' {
            $script:robocopyExitCode = 7

            $result = Invoke-WslResticBackup @script:baseParams

            $result.Status | Should -Be 'Completed'
        }

        It 'throws on robocopy exit 8, stops copying, logs no robocopy output, and writes no state' {
            $script:robocopyExitCode = 8

            { Invoke-WslResticBackup @script:baseParams } | Should -Throw '*robocopy*exit 8*'

            $script:robocopyCalls.Count | Should -Be 1
            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match 'ERROR: robocopy .* failed \(exit 8\)'
            $log | Should -Not -Match '0011223344'
            $log | Should -Not -Match 'restic backup complete'
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }
    }

    Context 'on full success' {
        It 'writes today''s date to the state file, creating its directory, and logs completion' {
            Test-Path -LiteralPath (Split-Path $script:statePath -Parent) | Should -BeFalse

            Invoke-WslResticBackup @script:baseParams | Out-Null

            Get-Content -LiteralPath $script:statePath -Raw | Should -Be '2026-10-21'
            (Get-Content -LiteralPath $script:logFile -Raw) | Should -Match ([regex]::Escape('restic backup complete (copy to OneDrive dir done)'))
        }

        It 'then skips the next run the same day' {
            Invoke-WslResticBackup @script:baseParams | Out-Null

            (Invoke-WslResticBackup @script:baseParams).Status | Should -Be 'Skipped'
            Should -Invoke -CommandName Invoke-WslExe -ModuleName WslAutomation -Times 1 -Exactly
        }

        It 'does not take the backup lock, so the keeper never waits on it' {
            Mock -CommandName New-WslBackupLock -ModuleName WslAutomation -MockWith { }

            Invoke-WslResticBackup @script:baseParams | Out-Null

            Should -Invoke -CommandName New-WslBackupLock -ModuleName WslAutomation -Times 0 -Exactly
        }
    }
}

Describe 'ConvertTo-WslMountPath' {
    It 'converts <Path> to <Expected>' -ForEach @(
        @{ Path = 'D:\Backups\wsl-restic'; Expected = '/mnt/d/Backups/wsl-restic' },
        @{ Path = 'D:\Backups\wsl-restic\'; Expected = '/mnt/d/Backups/wsl-restic' },
        @{ Path = 'c:\Users\Me\Restic Repo'; Expected = '/mnt/c/Users/Me/Restic Repo' },
        @{ Path = 'E:/forward/slashes/'; Expected = '/mnt/e/forward/slashes' },
        @{ Path = 'D:\'; Expected = '/mnt/d' },
        @{ Path = 'D:'; Expected = '/mnt/d' }
    ) {
        InModuleScope WslAutomation -Parameters @{ Path = $Path } {
            param($Path)
            ConvertTo-WslMountPath -Path $Path
        } | Should -BeExactly $Expected
    }

    It 'throws on <Path>' -ForEach @(
        @{ Path = '\\server\share\restic' },
        @{ Path = 'Backups\restic' },
        @{ Path = 'D:Backups' },
        @{ Path = '/mnt/d/Backups' }
    ) {
        {
            InModuleScope WslAutomation -Parameters @{ Path = $Path } {
                param($Path)
                ConvertTo-WslMountPath -Path $Path
            }
        } | Should -Throw '*drive-letter*'
    }
}
