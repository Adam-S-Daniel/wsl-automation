#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Invoke-CodexCloudEnvironmentSync' {
    BeforeEach {
        # Safety seam: these tests must never call a real distro or execute the shell reconciler.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('/workspace/scripts/sync-codex-cloud-environments.sh') }
        }
        $script:logFile = Join-Path $TestDrive 'codex-cloud-sync.log'
    }

    It 'skips a stopped distro without invoking any distro command' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }

        $result = Invoke-CodexCloudEnvironmentSync -DistroName 'Ubuntu' -LogFile $script:logFile

        $result.Status | Should -Be 'SkippedDistroNotRunning'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
        Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'skipped'
    }

    It 'converts the Windows script path then runs bash only when the distro is running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            if ($Arguments -contains 'wslpath') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('/workspace/scripts/sync-codex-cloud-environments.sh') }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @('Codex Cloud environment sync complete: 0 created, 0 updated, 1 unchanged') }
        }

        $result = Invoke-CodexCloudEnvironmentSync -DistroName 'Debian' -ScriptPath 'C:\repo\scripts\sync-codex-cloud-environments.sh' -LogFile $script:logFile

        $result.Status | Should -Be 'Completed'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Debian|--exec|wslpath|-a|-u|C:\repo\scripts\sync-codex-cloud-environments.sh'
        }
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Debian|--exec|bash|-l|/workspace/scripts/sync-codex-cloud-environments.sh'
        }
    }

    It 'never routes a distro command through the default shell with --' {
        # Regression: wsl.exe -- <cmd> hands the command line to the distro's default
        # shell, which strips backslashes from a Windows path before wslpath sees it.
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }

        Invoke-CodexCloudEnvironmentSync -DistroName 'Debian' -ScriptPath 'C:\repo\scripts\sync-codex-cloud-environments.sh' -LogFile $script:logFile | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--'
        }
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 2 -Exactly
    }

    It 'passes --dry-run to bash' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }

        $result = Invoke-CodexCloudEnvironmentSync -DryRun -LogFile $script:logFile

        $result.Status | Should -Be 'DryRun'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -ParameterFilter {
            $Arguments -contains '--dry-run'
        }
    }

    It 'throws a sanitized error when bash fails' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            if ($Arguments -contains 'wslpath') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('/workspace/scripts/sync-codex-cloud-environments.sh') }
            }
            return [pscustomobject]@{ ExitCode = 1; Output = @('secret response body') }
        }

        { Invoke-CodexCloudEnvironmentSync -LogFile $script:logFile } | Should -Throw 'Codex Cloud environment synchronization failed.'

        Get-Content -LiteralPath $script:logFile -Raw | Should -Not -Match 'secret'
    }

    It 'tolerates a wsl.exe transition warning ahead of the wslpath output' {
        # Regression: wsl.exe can print an informational "wsl: ..." line (stderr, merged into
        # Output) while still exiting 0 during a WSL transition, e.g. a failed systemd user
        # session right after a resume. That must not be mistaken for a second path result.
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            if ($Arguments -contains 'wslpath') {
                return [pscustomobject]@{
                    ExitCode = 0
                    Output   = @(
                        "wsl: Failed to start the systemd user session for 'x'. See journalctl for more details.",
                        '/workspace/scripts/sync-codex-cloud-environments.sh'
                    )
                }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @('Codex Cloud environment sync complete: 0 created, 0 updated, 1 unchanged') }
        }

        $result = Invoke-CodexCloudEnvironmentSync -LogFile $script:logFile

        $result.Status | Should -Be 'Completed'
    }

    It 'logs a completed outcome on success' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            if ($Arguments -contains 'wslpath') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('/workspace/scripts/sync-codex-cloud-environments.sh') }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @('Codex Cloud environment sync complete: 0 created, 0 updated, 1 unchanged') }
        }

        Invoke-CodexCloudEnvironmentSync -LogFile $script:logFile | Out-Null

        Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'completed'
    }
}
