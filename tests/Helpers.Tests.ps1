#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'WslAutomation helpers' {

    BeforeEach {
        # Absolute safety net: no test in this file may ever reach a real wsl.exe.
        # Individual tests below override this with more specific mocks as needed.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
    }

    Describe 'Write-WslAutomationLog' {
        # Write-WslAutomationLog is a private (non-exported) module member, so it can only be
        # called directly from -ModuleName WslAutomation's own scope, via InModuleScope. Only the
        # call itself runs there (the module runs under Set-StrictMode -Version Latest); setup and
        # assertions stay in this file's own, non-strict scope so plain Get-Content results (which
        # can be a single string, not an array) behave normally for -Count/index checks below.

        It 'appends a line matching the standard timestamp format' {
            $logFile = Join-Path $TestDrive 'plain.log'

            InModuleScope WslAutomation -Parameters @{ LogFile = $logFile } {
                param($LogFile)
                Write-WslAutomationLog -Message 'Hello world' -LogFile $LogFile
            }

            # @() forces array semantics even for a single-line file, where Get-Content would
            # otherwise return a plain [string] and $content[0] would index its first character.
            $content = @(Get-Content -Path $logFile)
            $content.Count | Should -Be 1
            $content[0] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  .+$'
            $content[0] | Should -Match 'Hello world'
        }

        It 'creates the parent directory when it does not exist' {
            $logFile = Join-Path $TestDrive 'nested' 'deeper' 'test.log'

            InModuleScope WslAutomation -Parameters @{ LogFile = $logFile } {
                param($LogFile)
                Write-WslAutomationLog -Message 'nested write' -LogFile $LogFile
            }

            Test-Path -Path $logFile | Should -BeTrue
        }

        It 'appends rather than overwrites on repeated calls' {
            $logFile = Join-Path $TestDrive 'append.log'

            InModuleScope WslAutomation -Parameters @{ LogFile = $logFile } {
                param($LogFile)
                Write-WslAutomationLog -Message 'first line' -LogFile $LogFile
                Write-WslAutomationLog -Message 'second line' -LogFile $LogFile
            }

            $content = Get-Content -Path $logFile
            $content.Count | Should -Be 2
            $content[0] | Should -Match 'first line'
            $content[1] | Should -Match 'second line'
        }

        It 'rotates the log to <LogFile>.1 when it exceeds MaxSizeMB' {
            $logFile = Join-Path $TestDrive 'rotate.log'
            $rotated = "$logFile.1"

            $lines = 1..1200 | ForEach-Object { 'x' * 1024 }
            Set-Content -Path $logFile -Value $lines -Encoding utf8

            (Get-Item -Path $logFile).Length | Should -BeGreaterThan 1MB

            InModuleScope WslAutomation -Parameters @{ LogFile = $logFile } {
                param($LogFile)
                Write-WslAutomationLog -Message 'trigger rotation' -LogFile $LogFile -MaxSizeMB 1
            }

            Test-Path -Path $rotated | Should -BeTrue

            # @() forces array semantics: after rotation this file has a single line, and
            # Get-Content would otherwise return a plain [string] here.
            $newContent = @(Get-Content -Path $logFile)
            $newContent.Count | Should -Be 1
            $newContent[0] | Should -Match 'trigger rotation'
        }

        It 'overwrites a pre-existing .1 file when rotating' {
            $logFile = Join-Path $TestDrive 'rotate2.log'
            $rotated = "$logFile.1"

            Set-Content -Path $rotated -Value 'stale rotated content' -Encoding utf8

            $lines = 1..1200 | ForEach-Object { 'x' * 1024 }
            Set-Content -Path $logFile -Value $lines -Encoding utf8

            InModuleScope WslAutomation -Parameters @{ LogFile = $logFile } {
                param($LogFile)
                Write-WslAutomationLog -Message 'second rotation' -LogFile $LogFile -MaxSizeMB 1
            }

            $rotatedContent = Get-Content -Path $rotated -Raw
            $rotatedContent | Should -Not -Match 'stale rotated content'
        }

        It 'does not rotate when MaxSizeMB is 0, however large the file' {
            $logFile = Join-Path $TestDrive 'norotate.log'

            $lines = 1..1200 | ForEach-Object { 'x' * 1024 }
            Set-Content -Path $logFile -Value $lines -Encoding utf8

            InModuleScope WslAutomation -Parameters @{ LogFile = $logFile } {
                param($LogFile)
                Write-WslAutomationLog -Message 'no rotation here' -LogFile $LogFile -MaxSizeMB 0
            }

            Test-Path -Path "$logFile.1" | Should -BeFalse

            $content = Get-Content -Path $logFile
            ($content | Where-Object { $_ -match 'no rotation here' }).Count | Should -Be 1
        }
    }

    Describe 'New-WslBackupLock' {

        It 'writes a parseable JSON lock file with ProcessId, StartedUtc and DistroName' {
            $lockPath = Join-Path $TestDrive 'backup.lock'

            $returned = New-WslBackupLock -LockPath $lockPath -DistroName 'Ubuntu'

            $returned | Should -Be $lockPath
            Test-Path -Path $lockPath | Should -BeTrue

            $data = Get-Content -Path $lockPath -Raw | ConvertFrom-Json
            $data.ProcessId | Should -Be $PID
            $data.DistroName | Should -Be 'Ubuntu'
            { [datetime]$data.StartedUtc } | Should -Not -Throw
        }

        It 'creates the parent directory when it does not exist' {
            $lockPath = Join-Path $TestDrive 'nested' 'lockdir' 'backup.lock'

            New-WslBackupLock -LockPath $lockPath -DistroName 'Ubuntu' | Out-Null

            Test-Path -Path $lockPath | Should -BeTrue
        }
    }

    Describe 'Test-WslBackupLock' {

        It 'reports Present false when the lock file is missing' {
            $lockPath = Join-Path $TestDrive 'missing.lock'

            $result = Test-WslBackupLock -LockPath $lockPath

            $result.Present | Should -BeFalse
            $result.Stale | Should -BeFalse
            $result.AgeMinutes | Should -BeNullOrEmpty
        }

        It 'reports Present true and Stale false for a freshly written lock' {
            $lockPath = Join-Path $TestDrive 'fresh.lock'
            New-WslBackupLock -LockPath $lockPath -DistroName 'Ubuntu' | Out-Null

            $result = Test-WslBackupLock -LockPath $lockPath -StaleMinutes 240

            $result.Present | Should -BeTrue
            $result.Stale | Should -BeFalse
            $result.AgeMinutes | Should -Not -BeNullOrEmpty
            $result.AgeMinutes | Should -BeLessThan 5
            $result.Data | Should -Not -BeNullOrEmpty
        }

        It 'reports Stale true when StartedUtc is older than StaleMinutes' {
            $lockPath = Join-Path $TestDrive 'stale.lock'
            $staleStart = (Get-Date).ToUniversalTime().AddHours(-5).ToString('o')
            $json = @{ ProcessId = 4242; StartedUtc = $staleStart; DistroName = 'Ubuntu' } | ConvertTo-Json
            Set-Content -Path $lockPath -Value $json -Encoding utf8

            $result = Test-WslBackupLock -LockPath $lockPath -StaleMinutes 240

            $result.Present | Should -BeTrue
            $result.Stale | Should -BeTrue
            $result.AgeMinutes | Should -BeGreaterThan 240
        }

        It 'treats corrupt JSON as Present, computing age from the file write time' {
            $lockPath = Join-Path $TestDrive 'corrupt.lock'
            Set-Content -Path $lockPath -Value '{ this is not valid json' -Encoding utf8

            $result = Test-WslBackupLock -LockPath $lockPath

            $result.Present | Should -BeTrue
            $result.AgeMinutes | Should -Not -BeNullOrEmpty
            $result.AgeMinutes | Should -BeLessThan 5
        }

        It 'does not throw under StrictMode on valid JSON missing StartedUtc, computing age from the file write time' {
            # A lock file written by an older/foreign tool, or any hand-edited JSON without a
            # StartedUtc key, still parses fine as JSON - it just lacks the property this
            # function normally reads age from. Under the module's Set-StrictMode -Version
            # Latest, a naive $data.StartedUtc access throws in that case instead of degrading;
            # this must instead fall back to the file's LastWriteTimeUtc like unparseable JSON
            # does.
            $lockPath = Join-Path $TestDrive 'missing-property.lock'
            Set-Content -Path $lockPath -Value '{"ProcessId":123}' -Encoding utf8

            { Test-WslBackupLock -LockPath $lockPath } | Should -Not -Throw

            $result = Test-WslBackupLock -LockPath $lockPath

            $result.Present | Should -BeTrue
            $result.AgeMinutes | Should -Not -BeNullOrEmpty
            $result.AgeMinutes | Should -BeLessThan 5
            $result.Data.ProcessId | Should -Be 123
        }
    }

    Describe 'Remove-WslBackupLock' {

        It 'removes an existing lock file' {
            $lockPath = Join-Path $TestDrive 'toremove.lock'
            New-WslBackupLock -LockPath $lockPath -DistroName 'Ubuntu' | Out-Null
            Test-Path -Path $lockPath | Should -BeTrue

            Remove-WslBackupLock -LockPath $lockPath

            Test-Path -Path $lockPath | Should -BeFalse
        }

        It 'is idempotent and never throws when the lock file is already absent' {
            $lockPath = Join-Path $TestDrive 'nolockhere.lock'

            { Remove-WslBackupLock -LockPath $lockPath } | Should -Not -Throw
            { Remove-WslBackupLock -LockPath $lockPath } | Should -Not -Throw
        }
    }

    Describe 'Get-WslDistroState' {

        It 'returns Running for a distro marked as the current default (leading *)' {
            Mock -ModuleName WslAutomation Invoke-WslExe {
                [pscustomobject]@{
                    ExitCode = 0
                    Output   = @(
                        'NAME                   STATE           VERSION'
                        '* Ubuntu                Running         2'
                        '  docker-desktop        Stopped         2'
                    )
                }
            }

            Get-WslDistroState -DistroName 'ubuntu' | Should -Be 'Running'

            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -eq '--list --verbose'
            }
        }

        It 'returns Stopped for a stopped distro' {
            Mock -ModuleName WslAutomation Invoke-WslExe {
                [pscustomobject]@{
                    ExitCode = 0
                    Output   = @(
                        'NAME                   STATE           VERSION'
                        '* Ubuntu                Running         2'
                        '  docker-desktop        Stopped         2'
                    )
                }
            }

            Get-WslDistroState -DistroName 'docker-desktop' | Should -Be 'Stopped'
        }

        It 'returns NotFound when no distro name matches' {
            Mock -ModuleName WslAutomation Invoke-WslExe {
                [pscustomobject]@{
                    ExitCode = 0
                    Output   = @(
                        'NAME                   STATE           VERSION'
                        '* Ubuntu                Running         2'
                        '  docker-desktop        Stopped         2'
                    )
                }
            }

            Get-WslDistroState -DistroName 'no-such-distro' | Should -Be 'NotFound'
        }

        It 'returns NotFound when wsl.exe exits with a nonzero code' {
            Mock -ModuleName WslAutomation Invoke-WslExe {
                [pscustomobject]@{ ExitCode = 1; Output = @() }
            }

            Get-WslDistroState -DistroName 'Ubuntu' | Should -Be 'NotFound'
        }
    }
}

Describe 'Invoke-WslExe' {
    # Every test above mocks Invoke-WslExe itself (the module's single approved mock seam), so
    # Invoke-WslExe's own body - including its NUL-stripping - never actually runs anywhere else
    # in this file. These tests instead mock the native wsl.exe command one level down, so the
    # real Invoke-WslExe function executes, while still guaranteeing no real wsl.exe is ever
    # invoked.

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

        function ConvertTo-Utf16AsUtf8Artifact {
            <#
            Simulates the real artifact of decoding a UTF-16LE byte stream as UTF-8: every
            character arrives with a trailing NUL (e.g. 'U<NUL>b<NUL>u<NUL>n<NUL>t<NUL>u<NUL>'),
            which is what wsl.exe's own management output looks like once Invoke-WslExe reads it
            back under UTF8 console encoding.
            #>
            param([Parameter(Mandatory)][string]$Text)
            -join ($Text.ToCharArray() | ForEach-Object { "$_`0" })
        }
    }

    It 'strips interleaved NULs from simulated wsl.exe management output' {
        $script:headerLine = ConvertTo-Utf16AsUtf8Artifact 'NAME                   STATE           VERSION'
        $script:dataLine = ConvertTo-Utf16AsUtf8Artifact '* Ubuntu                Running         2'

        Mock -CommandName wsl.exe -ModuleName WslAutomation {
            $global:LASTEXITCODE = 0
            $script:headerLine
            $script:dataLine
        }

        $result = InModuleScope WslAutomation {
            Invoke-WslExe -Arguments @('--list', '--verbose')
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Be @(
            'NAME                   STATE           VERSION'
            '* Ubuntu                Running         2'
        )
    }

    It 'lets Get-WslDistroState parse Running correctly end-to-end through the real NUL-stripping' {
        $script:headerLine = ConvertTo-Utf16AsUtf8Artifact 'NAME                   STATE           VERSION'
        $script:dataLine = ConvertTo-Utf16AsUtf8Artifact '* Ubuntu                Running         2'

        Mock -CommandName wsl.exe -ModuleName WslAutomation {
            $global:LASTEXITCODE = 0
            $script:headerLine
            $script:dataLine
        }

        Get-WslDistroState -DistroName 'Ubuntu' | Should -Be 'Running'
    }
}
