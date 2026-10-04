#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Repair-WslUserRuntime' {
    # Private seam, called through InModuleScope. Invoke-WslExe is the only thing mocked besides
    # the distro state, and it recognizes the three kinds of call the function makes: the probe
    # script, a loginctl call, and the wait script. Every call is recorded in order.

    BeforeEach {
        $script:wslCalls = [System.Collections.Generic.List[string]]::new()
        $script:probeAnswer = 'ok'
        $script:probeExit = 0
        $script:waitExit = 0
        $script:logFile = Join-Path $TestDrive 'keeper.log'
        Remove-Item -LiteralPath $script:logFile -ErrorAction SilentlyContinue

        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            $joined = $Arguments -join ' '
            if ($joined -match '\bloginctl (disable|enable)-linger (\d+)$') {
                $script:wslCalls.Add("$($Matches[1])-linger")
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }
            elseif ($joined -match 'is-system-running') {
                $script:wslCalls.Add('probe')
                [pscustomobject]@{ ExitCode = $script:probeExit; Output = @($script:probeAnswer) }
            }
            elseif ($joined -match 'n=0; while') {
                $script:wslCalls.Add('wait')
                [pscustomobject]@{ ExitCode = $script:waitExit; Output = @() }
            }
            else {
                throw "unexpected wsl.exe call: $joined"
            }
        }
    }

    It 'does one probe and nothing else, and logs nothing, when the user manager is active' {
        $script:probeAnswer = 'ok'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Healthy'
        $script:wslCalls | Should -Be @('probe')
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains 'loginctl'
        }
        Test-Path -LiteralPath $script:logFile | Should -BeFalse
    }

    It 'only enables lingering when the manager is inactive and lingering is off' {
        $script:probeAnswer = 'inactive 1000 off'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Restored'
        $script:wslCalls | Should -Be @('probe', 'enable-linger', 'wait')
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Ubuntu|--exec|loginctl|enable-linger|1000'
        }
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains 'disable-linger'
        }
    }

    It 'disables then enables lingering when the manager is inactive and lingering is on' {
        $script:probeAnswer = 'inactive 1000 on'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Restored'
        $script:wslCalls | Should -Be @('probe', 'disable-linger', 'enable-linger', 'wait')
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Ubuntu|--exec|loginctl|disable-linger|1000'
        }
    }

    It 'logs one line that carries neither the uid nor a user name when it restores the manager' {
        $script:probeAnswer = 'inactive 1000 off'

        InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile | Out-Null
        }

        $lines = @(Get-Content -LiteralPath $script:logFile)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'Restored the WSL user manager \(runtime dir was missing\)$'
        $lines[0] | Should -Not -Match '1000'
    }

    It 'reports Failed and logs a failure line when the manager does not come up' {
        $script:probeAnswer = 'inactive 1000 off'
        $script:waitExit = 1

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Failed'
        (Get-Content -LiteralPath $script:logFile -Raw) | Should -Match 'Could not restore the WSL user manager'
    }

    It 'under -DryRun logs the intent and never runs loginctl' {
        $script:probeAnswer = 'inactive 1000 on'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile -DryRun
        }

        $result | Should -Be 'DryRun'
        $script:wslCalls | Should -Be @('probe')
        (Get-Content -LiteralPath $script:logFile -Raw) | Should -Match 'DryRun: would restore the WSL user manager'
    }

    It 'leaves a distro without systemd, or one that is still booting, alone' {
        foreach ($answer in 'unsupported', 'booting') {
            $script:wslCalls.Clear()
            $script:probeAnswer = $answer

            $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
                param($LogFile)
                Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
            }

            $result | Should -Be 'Skipped'
            $script:wslCalls | Should -Be @('probe')
        }
    }

    It 'never boots a stopped distro: no wsl.exe call at all' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Skipped'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'does not act on a probe that fails or answers with something unrecognized' {
        $script:probeExit = 1
        $script:probeAnswer = 'inactive 1000 off'
        InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        } | Should -Be 'Skipped'

        $script:probeExit = 0
        $script:probeAnswer = 'inactive abc; reboot off'
        InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        } | Should -Be 'Skipped'

        $script:wslCalls | Should -Not -Contain 'enable-linger'
    }

    It 'does not throw when Invoke-WslExe throws' {
        Mock -ModuleName WslAutomation Invoke-WslExe { throw 'wsl.exe not found' }

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Repair-WslUserRuntime -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Skipped'
    }
}

Describe 'Invoke-ClaudeSessionKeeper user manager repair' {

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:logFile = Join-Path $TestDrive 'keeper.log'
        $script:lockCalls = 0

        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        Mock -ModuleName WslAutomation Start-Sleep { $script:order.Add('sleep') }
        Mock -ModuleName WslAutomation Remove-WslBackupLock { }
        Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
        Mock -ModuleName WslAutomation Start-ClaudeSessionResume { }
        Mock -ModuleName WslAutomation Start-ClaudeLauncherTask { }
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $true }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $true }
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
        Mock -ModuleName WslAutomation Repair-WslUserRuntime { $script:order.Add('repair'); 'Healthy' }

        $script:keeperArgs = @{
            DistroName          = 'Ubuntu'
            LockPath            = (Join-Path $TestDrive 'backup.lock')
            LogFile             = $script:logFile
            SessionSnapshotPath = (Join-Path $TestDrive 'agents-snapshot.json')
        }
    }

    It 'runs the repair once per keeper run, for the keeper distro and log file' {
        Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

        Should -Invoke -ModuleName WslAutomation Repair-WslUserRuntime -Times 1 -Exactly -ParameterFilter {
            $DistroName -eq 'Ubuntu' -and $LogFile -eq $script:logFile -and -not $DryRun
        }
    }

    It 'passes -DryRun through' {
        Invoke-ClaudeSessionKeeper @script:keeperArgs -DryRun | Out-Null

        Should -Invoke -ModuleName WslAutomation Repair-WslUserRuntime -Times 1 -Exactly -ParameterFilter { $DryRun }
    }

    It 'waits out a backup lock first: no repair until the lock is clear' {
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            $script:lockCalls++
            [pscustomobject]@{ Present = ($script:lockCalls -le 2); Stale = $false; AgeMinutes = 1.0; Data = $null }
        }

        Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

        $script:order | Should -Be @('sleep', 'sleep', 'repair')
    }

    It 'repairs before it looks for a Claude session' {
        Mock -ModuleName WslAutomation Test-ClaudeSession { $script:order.Add('session-check'); $true }

        Invoke-ClaudeSessionKeeper @script:keeperArgs | Out-Null

        $script:order | Should -Be @('repair', 'session-check')
    }
}

Describe 'Invoke-ClaudeSessionKeeper when the user manager repair cannot reach wsl.exe' {
    # Repair-WslUserRuntime is NOT mocked here: only the wsl.exe seam fails, to prove the keeper
    # carries on with the session work.

    BeforeEach {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe { throw 'wsl.exe not found' }
        Mock -ModuleName WslAutomation Start-Sleep { }
        Mock -ModuleName WslAutomation Remove-WslBackupLock { }
        Mock -ModuleName WslAutomation Get-ClaudeAgentSessions { , @() }
        Mock -ModuleName WslAutomation Start-ClaudeSessionResume { }
        Mock -ModuleName WslAutomation Start-ClaudeLauncherTask { }
        Mock -ModuleName WslAutomation Test-CodexRemoteControl { $true }
        Mock -ModuleName WslAutomation Test-ClaudeSession { $false }
        Mock -ModuleName WslAutomation Test-WslBackupLock {
            [pscustomobject]@{ Present = $false; Stale = $false; AgeMinutes = $null; Data = $null }
        }
    }

    It 'does not throw and still launches the Remote Control session' {
        $keeperArgs = @{
            DistroName          = 'Ubuntu'
            LockPath            = (Join-Path $TestDrive 'backup.lock')
            LogFile             = (Join-Path $TestDrive 'keeper.log')
            SessionSnapshotPath = (Join-Path $TestDrive 'agents-snapshot.json')
        }

        $result = Invoke-ClaudeSessionKeeper @keeperArgs

        $result.Status | Should -Be 'Launched'
        Should -Invoke -ModuleName WslAutomation Start-ClaudeLauncherTask -Times 1 -Exactly
    }
}
