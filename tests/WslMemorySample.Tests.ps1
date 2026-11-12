#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Write-WslMemorySample' -Skip:(-not $IsWindows) {

    BeforeEach {
        # Every collaborator is mocked: nothing here may reach a real counter, process list,
        # CIM class or wsl.exe.
        $script:logDir = Join-Path $TestDrive "memlog-$([guid]::NewGuid())"
        $script:csvPath = Join-Path $script:logDir 'samples.csv'

        # Counter values in bytes (the paging file usage is a percentage), under the computer
        # name prefix a real Get-Counter puts on every path.
        Mock -ModuleName WslAutomation Get-Counter {
            [pscustomobject]@{
                CounterSamples = @(
                    [pscustomobject]@{ Path = '\\TESTPC\memory\available bytes'; CookedValue = [double](8GB) },
                    [pscustomobject]@{ Path = '\\TESTPC\memory\standby cache normal priority bytes'; CookedValue = [double](4GB) },
                    [pscustomobject]@{ Path = '\\TESTPC\memory\modified page list bytes'; CookedValue = [double](0.5GB) },
                    [pscustomobject]@{ Path = '\\TESTPC\memory\committed bytes'; CookedValue = [double](20GB) },
                    [pscustomobject]@{ Path = '\\TESTPC\memory\commit limit'; CookedValue = [double](40GB) },
                    [pscustomobject]@{ Path = '\\TESTPC\paging file(_total)\% usage'; CookedValue = 12.345 }
                )
            }
        }
        # TotalVisibleMemorySize is in KB: 32 GB.
        Mock -ModuleName WslAutomation Get-CimInstance {
            [pscustomobject]@{ TotalVisibleMemorySize = [uint64]33554432 }
        }

        $script:processes = @{
            'vmmemWSL'           = @([pscustomobject]@{ WorkingSet64 = [int64](6GB); PrivateMemorySize64 = [int64](5GB) })
            # Two tiny processes whose sum rounds up while each alone would round down to 0.
            'vmmem'              = @(
                [pscustomobject]@{ WorkingSet64 = [int64](0.0049GB); PrivateMemorySize64 = [int64](0.5GB) },
                [pscustomobject]@{ WorkingSet64 = [int64](0.0049GB); PrivateMemorySize64 = [int64](0.25GB) }
            )
            'Memory Compression' = @([pscustomobject]@{ WorkingSet64 = [int64](1.5GB); PrivateMemorySize64 = [int64](9GB) })
            'chrome'             = @(
                [pscustomobject]@{ WorkingSet64 = [int64](9GB); PrivateMemorySize64 = [int64](1.5GB) },
                [pscustomobject]@{ WorkingSet64 = [int64](9GB); PrivateMemorySize64 = [int64](2GB) },
                [pscustomobject]@{ WorkingSet64 = [int64](9GB); PrivateMemorySize64 = [int64](0.5GB) }
            )
        }
        # Like the real cmdlet, a name with no matching process emits nothing.
        Mock -ModuleName WslAutomation Get-Process {
            if ($script:processes.ContainsKey("$Name")) { $script:processes["$Name"] }
        }

        $script:meminfoOutput = @(
            'MemTotal:       16777216 kB',
            'MemFree:         1000000 kB',
            'MemAvailable:   10485760 kB',
            'Buffers:          524288 kB',
            'Cached:          3145728 kB',
            'SwapCached:            0 kB',
            'AnonPages:       4194304 kB',
            'SwapTotal:       4194304 kB',
            'SwapFree:        3145728 kB',
            'Committed_AS:   12582912 kB',
            'some avg10=0.50 avg60=0.40 avg300=1.25 total=999',
            'full avg10=0.00 avg60=0.00 avg300=0.07 total=10'
        )
        $script:wslExitCode = 0
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = $script:wslExitCode; Output = $script:meminfoOutput }
        }
    }

    Context 'when the WSL VM is running' {

        It 'writes the Windows columns in GB from counters, CIM and process totals, rounded only at the end' {
            Write-WslMemorySample -LogDir $script:logDir

            $row = Import-Csv -LiteralPath $script:csvPath
            @($row).Count | Should -Be 1
            $row.Win_TotalGB | Should -Be '32'
            $row.Win_AvailGB | Should -Be '8'
            $row.Win_StandbyGB | Should -Be '4'
            $row.Win_ModifiedGB | Should -Be '0.5'
            $row.Win_CommitGB | Should -Be '20'
            $row.Win_CommitLimitGB | Should -Be '40'
            $row.Win_PagefilePct | Should -Be '12.3'
            $row.Win_CompressionGB | Should -Be '1.5'
            $row.Chrome_PrivateGB | Should -Be '4'
            $row.VmmemWSL_WSGB | Should -Be '6'
            $row.VmmemWSL_PrivGB | Should -Be '5'
            $row.OtherVmmem_WSGB | Should -Be '0.01'
            $row.OtherVmmem_PrivGB | Should -Be '0.75'
            $row.WSL_Running | Should -Be '1'
        }

        It 'computes the WSL columns from /proc/meminfo and /proc/pressure/memory' {
            Write-WslMemorySample -LogDir $script:logDir

            $row = Import-Csv -LiteralPath $script:csvPath
            $row.WSL_TotalGB | Should -Be '16'
            $row.WSL_UsedGB | Should -Be '6'
            $row.WSL_AvailGB | Should -Be '10'
            $row.WSL_CacheGB | Should -Be '3.5'
            $row.WSL_AnonGB | Should -Be '4'
            $row.WSL_SwapUsedGB | Should -Be '1'
            $row.WSL_CommittedGB | Should -Be '12'
            $row.WSL_PSISome300 | Should -Be '1.25'
            $row.WSL_PSIFull300 | Should -Be '0.07'
        }

        It 'reads the requested distro through Invoke-WslExe exactly once' {
            Write-WslMemorySample -LogDir $script:logDir -DistroName 'Debian'

            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq '-d' -and $Arguments[1] -eq 'Debian' -and $Arguments[2] -eq '--exec' -and
                $Arguments[3] -eq 'sh' -and $Arguments[4] -eq '-c' -and
                $Arguments[5] -match '/proc/meminfo' -and $Arguments[5] -match '/proc/pressure/memory'
            }
        }

        It 'defaults the distro to Ubuntu' {
            Write-WslMemorySample -LogDir $script:logDir

            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
                $Arguments[1] -eq 'Ubuntu'
            }
        }

        It 'leaves only the pressure columns empty when the kernel has no pressure file' {
            $script:meminfoOutput = @($script:meminfoOutput | Where-Object { $_ -notmatch '^(some|full) ' })

            Write-WslMemorySample -LogDir $script:logDir

            $row = Import-Csv -LiteralPath $script:csvPath
            $row.WSL_TotalGB | Should -Be '16'
            $row.WSL_PSISome300 | Should -BeNullOrEmpty
            $row.WSL_PSIFull300 | Should -BeNullOrEmpty
        }

        It 'leaves the WSL columns empty, without throwing, when wsl.exe fails' {
            $script:wslExitCode = 1

            { Write-WslMemorySample -LogDir $script:logDir } | Should -Not -Throw

            $row = Import-Csv -LiteralPath $script:csvPath
            $row.WSL_Running | Should -Be '1'
            foreach ($column in 'WSL_TotalGB', 'WSL_UsedGB', 'WSL_AvailGB', 'WSL_CacheGB', 'WSL_AnonGB', 'WSL_SwapUsedGB', 'WSL_CommittedGB', 'WSL_PSISome300', 'WSL_PSIFull300') {
                $row.$column | Should -BeNullOrEmpty -Because $column
            }
            $row.Win_TotalGB | Should -Be '32'
        }

        It 'leaves the WSL columns empty when the reply is missing meminfo fields' {
            $script:meminfoOutput = @('wsl: some warning line', 'MemTotal:       16777216 kB')

            { Write-WslMemorySample -LogDir $script:logDir } | Should -Not -Throw

            $row = Import-Csv -LiteralPath $script:csvPath
            $row.WSL_TotalGB | Should -BeNullOrEmpty
            $row.WSL_UsedGB | Should -BeNullOrEmpty
        }
    }

    Context 'when the WSL VM is not running' {

        BeforeEach {
            $script:processes.Remove('vmmemWSL')
        }

        It 'never calls wsl.exe, so logging cannot boot the VM' {
            Write-WslMemorySample -LogDir $script:logDir

            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
        }

        It 'writes WSL_Running 0, zero vmmemWSL columns and empty WSL columns, with the Windows columns intact' {
            Write-WslMemorySample -LogDir $script:logDir

            $row = Import-Csv -LiteralPath $script:csvPath
            $row.WSL_Running | Should -Be '0'
            $row.VmmemWSL_WSGB | Should -Be '0'
            $row.VmmemWSL_PrivGB | Should -Be '0'
            foreach ($column in 'WSL_TotalGB', 'WSL_UsedGB', 'WSL_AvailGB', 'WSL_CacheGB', 'WSL_AnonGB', 'WSL_SwapUsedGB', 'WSL_CommittedGB', 'WSL_PSISome300', 'WSL_PSIFull300') {
                $row.$column | Should -BeNullOrEmpty -Because $column
            }
            $row.Win_TotalGB | Should -Be '32'
            $row.Chrome_PrivateGB | Should -Be '4'
        }

        It 'counts every other missing process as 0' {
            $script:processes.Clear()

            Write-WslMemorySample -LogDir $script:logDir

            $row = Import-Csv -LiteralPath $script:csvPath
            $row.Win_CompressionGB | Should -Be '0'
            $row.Chrome_PrivateGB | Should -Be '0'
            $row.OtherVmmem_WSGB | Should -Be '0'
            $row.OtherVmmem_PrivGB | Should -Be '0'
            $row.WSL_Running | Should -Be '0'
        }
    }

    Context 'the CSV file' {

        It 'creates the log directory, including missing parents, when it does not exist' {
            $nested = Join-Path $script:logDir 'a\b'

            Write-WslMemorySample -LogDir $nested

            Test-Path -LiteralPath (Join-Path $nested 'samples.csv') | Should -BeTrue
        }

        It 'writes the columns in the documented order, with a local timestamp first' {
            Write-WslMemorySample -LogDir $script:logDir

            $expected = @(
                'Time', 'Win_TotalGB', 'Win_AvailGB', 'Win_StandbyGB', 'Win_ModifiedGB', 'Win_CommitGB', 'Win_CommitLimitGB',
                'Win_PagefilePct', 'Win_CompressionGB', 'Chrome_PrivateGB', 'VmmemWSL_WSGB', 'VmmemWSL_PrivGB',
                'OtherVmmem_WSGB', 'OtherVmmem_PrivGB', 'WSL_Running', 'WSL_TotalGB', 'WSL_UsedGB', 'WSL_AvailGB',
                'WSL_CacheGB', 'WSL_AnonGB', 'WSL_SwapUsedGB', 'WSL_CommittedGB', 'WSL_PSISome300', 'WSL_PSIFull300'
            )
            $header = Get-Content -LiteralPath $script:csvPath -TotalCount 1
            $header | Should -Be (($expected | ForEach-Object { "`"$_`"" }) -join ',')
            (Import-Csv -LiteralPath $script:csvPath).Time | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }

        It 'writes the header once and appends a row per call' {
            Write-WslMemorySample -LogDir $script:logDir
            Write-WslMemorySample -LogDir $script:logDir

            $lines = @(Get-Content -LiteralPath $script:csvPath)
            $lines.Count | Should -Be 3
            @($lines | Where-Object { $_ -like '"Time",*' }).Count | Should -Be 1
            @(Import-Csv -LiteralPath $script:csvPath).Count | Should -Be 2
        }
    }
}
