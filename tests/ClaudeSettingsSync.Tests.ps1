#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Invoke-ClaudeSettingsSync' {
    BeforeEach {
        # Safety seams: these tests never reach a real distro or run the real sync script.
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('alice') }
        }
        $script:summary = '2026-11-12T20:00:00Z sync-claude-settings mode=dry-run outcome=planned snapshot=absent windows=write(3 keys) wsl=nochange conflicts=1'
        Mock -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript {
            [pscustomobject]@{ ExitCode = 0; Output = @($script:summary) }
        }
        $script:syncScript = Join-Path $TestDrive 'Sync-ClaudeSettings.ps1'
        Set-Content -LiteralPath $script:syncScript -Value '# stub'
        $script:logFile = Join-Path $TestDrive 'claude-settings-sync.log'
        $script:common = @{
            SyncScriptPath      = $script:syncScript
            WindowsSettingsPath = 'C:\Users\example\.claude\settings.json'
            PwshPath            = 'C:\fake\pwsh.exe'
            ReportPath          = (Join-Path $TestDrive 'report.txt')
            LogFile             = $script:logFile
        }
    }

    It 'skips a stopped distro without touching the distro or the script' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }

        $result = Invoke-ClaudeSettingsSync @script:common

        $result.Status | Should -Be 'SkippedDistroNotRunning'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
        Should -Invoke -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript -Times 0 -Exactly
        Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'skipped'
    }

    It 'runs the script unattended with -DryRun and the derived WSL path unless -Live is given' {
        $result = Invoke-ClaudeSettingsSync @script:common -DistroName 'Debian'

        $result.Status | Should -Be 'DryRun'
        Should -Invoke -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript -Times 1 -Exactly -ParameterFilter {
            $PwshPath -eq 'C:\fake\pwsh.exe' -and
            $Arguments -contains '-Unattended' -and $Arguments -contains '-DryRun' -and
            $Arguments -contains '\\wsl.localhost\Debian\home\alice\.claude\settings.json' -and
            $Arguments -contains 'C:\Users\example\.claude\settings.json'
        }
    }

    It 'leaves out -DryRun with -Live' {
        $result = Invoke-ClaudeSettingsSync @script:common -Live

        $result.Status | Should -Be 'Completed'
        Should -Invoke -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '-Unattended' -and $Arguments -notcontains '-DryRun'
        }
    }

    It 'uses -WslUser without asking the distro' {
        Invoke-ClaudeSettingsSync @script:common -WslUser 'bob' | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
        Should -Invoke -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '\\wsl.localhost\Ubuntu\home\bob\.claude\settings.json'
        }
    }

    It 'skips when the WSL user cannot be determined' {
        Mock -ModuleName WslAutomation Invoke-WslExe { [pscustomobject]@{ ExitCode = 1; Output = @() } }

        $result = Invoke-ClaudeSettingsSync @script:common

        $result.Status | Should -Be 'SkippedNoWslUser'
        Should -Invoke -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript -Times 0 -Exactly
    }

    It 'logs the script summary line without its timestamp' {
        Invoke-ClaudeSettingsSync @script:common | Out-Null

        Get-Content -LiteralPath $script:logFile -Raw |
            Should -Match ([regex]::Escape('sync-claude-settings mode=dry-run outcome=planned snapshot=absent windows=write(3 keys) wsl=nochange conflicts=1'))
    }

    It 'logs nothing from the script output except an exact summary line' {
        Mock -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript {
            [pscustomobject]@{ ExitCode = 0; Output = @('API_TOKEN = sentinel-7f3a91', "$($script:summary) extra") }
        }

        Invoke-ClaudeSettingsSync @script:common | Out-Null

        $log = Get-Content -LiteralPath $script:logFile -Raw
        $log | Should -Not -Match 'sentinel'
        $log | Should -Not -Match 'extra'
        $log | Should -Match 'completed \(no summary line\)'
    }

    It 'logs the exit code, never the output, and throws when the script fails' {
        Mock -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript {
            [pscustomobject]@{ ExitCode = 1; Output = @('Cannot parse C:\Users\example\.claude\settings.json: sentinel-7f3a91') }
        }

        { Invoke-ClaudeSettingsSync @script:common } | Should -Throw 'Claude settings synchronization failed.'

        $log = Get-Content -LiteralPath $script:logFile -Raw
        $log | Should -Match 'exit code 1'
        $log | Should -Not -Match 'sentinel'
    }

    It 'throws, without running anything, when the sync script is missing' {
        $missing = Join-Path $TestDrive 'nope\Sync-ClaudeSettings.ps1'
        $params = $script:common.Clone()
        $params['SyncScriptPath'] = $missing

        { Invoke-ClaudeSettingsSync @params } | Should -Throw '*was not found*'

        Should -Invoke -ModuleName WslAutomation Invoke-ClaudeSettingsSyncScript -Times 0 -Exactly
    }

    It 'never routes a distro command through the default shell with --' {
        Invoke-ClaudeSettingsSync @script:common | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--'
        }
    }
}
