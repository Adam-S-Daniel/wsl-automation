#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Invoke-ClaudeSessionKeeper' {

    BeforeEach {
        # Absolute safety net: no test in this file may ever reach a real wsl.exe.
        # Test-WslBackupLock / Test-ClaudeSession / Start-ClaudeSession are mocked directly below,
        # so Invoke-WslExe should never actually be reached, but this guards against any indirect path.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $script:lockPath = Join-Path $TestDrive 'backup.lock'
        $script:logFile = Join-Path $TestDrive 'keeper.log'

        Mock -ModuleName WslAutomation Remove-WslBackupLock { }
        Mock -ModuleName WslAutomation Start-ClaudeSession { }
        Mock -ModuleName WslAutomation Start-Sleep { }
    }

    It 'returns SessionPresent and does not launch when there is no lock and a session already exists' {
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $true }

        $result = Invoke-ClaudeSessionKeeper -DistroName 'Ubuntu' -LockPath $script:lockPath -LogFile $script:logFile

        $result.Status | Should -Be 'SessionPresent'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeSession -Times 0 -Exactly
        Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 0 -Exactly
    }

    It 'launches a session and returns Launched when there is no lock and no session exists' {
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }

        $result = Invoke-ClaudeSessionKeeper -DistroName 'Ubuntu' -LockPath $script:lockPath -LogFile $script:logFile

        $result.Status | Should -Be 'Launched'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeSession -Times 1 -Exactly
        Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 0 -Exactly
    }

    It 'returns DryRun and does not launch a session when -DryRun is set and no session exists' {
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }

        $result = Invoke-ClaudeSessionKeeper -DistroName 'Ubuntu' -LockPath $script:lockPath -LogFile $script:logFile -DryRun

        $result.Status | Should -Be 'DryRun'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeSession -Times 0 -Exactly
    }

    It 'waits through a fresh lock that clears after two polls, then launches' {
        $script:lockCallCount = 0
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            $script:lockCallCount++
            if ($script:lockCallCount -le 2) {
                [pscustomobject]@{ Present = $true; Stale = $false; AgeMinutes = 1.0; Data = $null }
            }
            else {
                [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
            }
        }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }

        $result = Invoke-ClaudeSessionKeeper -DistroName 'Ubuntu' -LockPath $script:lockPath -LogFile $script:logFile `
            -MaxWaitMinutes 60 -PollSeconds 30

        Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 2 -Exactly
        Should -Invoke -ModuleName WslAutomation Remove-WslBackupLock -Times 0 -Exactly
        $result.Status | Should -Be 'Launched'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeSession -Times 1 -Exactly

        $logContent = Get-Content -Path $script:logFile -Raw
        ([regex]::Matches($logContent, 'Backup in progress; waiting')).Count | Should -Be 1
    }

    It 'removes a stale lock immediately, without sleeping, and still launches' {
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $true; Stale = $true; AgeMinutes = 300.0; Data = $null }
        }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }

        $result = Invoke-ClaudeSessionKeeper -DistroName 'Ubuntu' -LockPath $script:lockPath -LogFile $script:logFile

        Should -Invoke -ModuleName WslAutomation Remove-WslBackupLock -Times 1 -Exactly
        Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 0 -Exactly
        $result.Status | Should -Be 'Launched'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeSession -Times 1 -Exactly

        $logContent = Get-Content -Path $script:logFile -Raw
        $logContent | Should -Match 'Ignoring stale backup lock'
    }

    It 'proceeds after the max wait is exhausted, sleeping exactly twice, and still launches' {
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $true; Stale = $false; AgeMinutes = 0.5; Data = $null }
        }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }

        $result = Invoke-ClaudeSessionKeeper -DistroName 'Ubuntu' -LockPath $script:lockPath -LogFile $script:logFile `
            -MaxWaitMinutes 1 -PollSeconds 30

        Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 2 -Exactly
        Should -Invoke -ModuleName WslAutomation Remove-WslBackupLock -Times 0 -Exactly
        $result.Status | Should -Be 'Launched'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeSession -Times 1 -Exactly

        $logContent = Get-Content -Path $script:logFile -Raw
        $logContent | Should -Match 'Backup still running after 1 min wait; proceeding anyway'
    }
}

Describe 'Test-ClaudeSession' {
    # Test-ClaudeSession's include/exclude pattern filtering is exercised for real here (unlike
    # Invoke-ClaudeSessionKeeper's tests above, which mock Test-ClaudeSession itself). This is
    # exactly the kind of parsing that regresses silently: a change that made a helper process
    # line count as a session would launch nothing new while the keeper reports SessionPresent
    # forever.

    BeforeEach {
        # Get-WslDistroState itself calls through to Invoke-WslExe; mocking it directly here
        # keeps each test focused on the pgrep-output parsing under test.
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
    }

    It 'counts a real interactive session line and returns true' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @('12345 bash -l -c claude')
            }
        }

        Test-ClaudeSession -DistroName 'Ubuntu' | Should -BeTrue
    }

    It 'excludes each known infrastructure helper line (daemon, bg-pty-host, bg-spare) and returns false' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    '100 claude daemon run'
                    '101 claude bg-pty-host'
                    '102 claude bg-spare'
                )
            }
        }

        Test-ClaudeSession -DistroName 'Ubuntu' | Should -BeFalse
    }

    It 'returns false without ever checking pgrep when the distro is not Running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('12345 bash -l -c claude') }
        }

        Test-ClaudeSession -DistroName 'Ubuntu' | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'returns false when pgrep exits nonzero, even with a matching-looking output line' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 1; Output = @('12345 bash -l -c claude') }
        }

        Test-ClaudeSession -DistroName 'Ubuntu' | Should -BeFalse
    }
}
