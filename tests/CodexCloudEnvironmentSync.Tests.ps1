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
    }

    It 'skips a stopped distro without invoking any distro command' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }

        $result = Invoke-CodexCloudEnvironmentSync -DistroName 'Ubuntu'

        $result.Status | Should -Be 'SkippedDistroNotRunning'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
    }

    It 'converts the Windows script path then runs bash only when the distro is running' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            if ($Arguments -contains 'wslpath') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('/workspace/scripts/sync-codex-cloud-environments.sh') }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @('Codex Cloud environment sync complete: 0 created, 0 updated, 1 unchanged') }
        }

        $result = Invoke-CodexCloudEnvironmentSync -DistroName 'Debian' -ScriptPath 'C:\repo\scripts\sync-codex-cloud-environments.sh'

        $result.Status | Should -Be 'Completed'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Debian|--|wslpath|-a|-u|C:\repo\scripts\sync-codex-cloud-environments.sh'
        }
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq '-d|Debian|--|bash|/workspace/scripts/sync-codex-cloud-environments.sh'
        }
    }

    It 'passes --dry-run to bash' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }

        $result = Invoke-CodexCloudEnvironmentSync -DryRun

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

        { Invoke-CodexCloudEnvironmentSync } | Should -Throw 'Codex Cloud environment synchronization failed.'
    }
}
