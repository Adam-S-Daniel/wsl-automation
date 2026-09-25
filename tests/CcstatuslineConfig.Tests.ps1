#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Update-CcstatuslineConfig' -Skip:(-not $IsWindows) {

    BeforeEach {
        # Absolute safety net: no test in this file may ever reach a real wsl.exe.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $script:src = Join-Path $TestDrive 'source-settings.json'
        $script:dst = Join-Path $TestDrive 'dest-settings.json'

        # $TestDrive is shared across every It in this Describe, and several tests leave the
        # destination behind marked read-only. Force-remove any leftovers from a prior test so
        # each test starts from a clean slate regardless of run order.
        foreach ($leftoverPath in @($script:src, $script:dst)) {
            if (Test-Path -LiteralPath $leftoverPath) {
                Remove-Item -LiteralPath $leftoverPath -Force
            }
        }
    }

    It 'returns SourceUnavailable and does not create the destination when the source path does not exist' {
        $result = Update-CcstatuslineConfig -SourcePath $script:src -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'SourceUnavailable'
        Test-Path -LiteralPath $script:dst | Should -BeFalse
    }

    It 'returns SourceInvalid and does not create the destination when the source is not valid JSON' {
        Set-Content -LiteralPath $script:src -Value 'not json{' -NoNewline -Encoding utf8

        $result = Update-CcstatuslineConfig -SourcePath $script:src -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'SourceInvalid'
        Test-Path -LiteralPath $script:dst | Should -BeFalse
    }

    It 'creates the destination read-only with the source content and returns Updated when the destination is absent' {
        Set-Content -LiteralPath $script:src -Value '{"version":3}' -NoNewline -Encoding utf8

        $result = Update-CcstatuslineConfig -SourcePath $script:src -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'Updated'
        Test-Path -LiteralPath $script:dst | Should -BeTrue
        (Get-Content -LiteralPath $script:dst -Raw) | Should -Be '{"version":3}'
        (Get-Item -LiteralPath $script:dst).IsReadOnly | Should -BeTrue
    }

    It 'returns AlreadyInSync and leaves the destination untouched when its content already matches the source' {
        Set-Content -LiteralPath $script:src -Value '{"version":3}' -NoNewline -Encoding utf8
        Set-Content -LiteralPath $script:dst -Value '{"version":3}' -NoNewline -Encoding utf8
        Set-ItemProperty -LiteralPath $script:dst -Name IsReadOnly -Value $true

        $result = Update-CcstatuslineConfig -SourcePath $script:src -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'AlreadyInSync'
    }

    It 'clears, overwrites, and restores read-only on a destination that already exists with different content' {
        Set-Content -LiteralPath $script:src -Value '{"version":3}' -NoNewline -Encoding utf8
        Set-Content -LiteralPath $script:dst -Value '{"version":1}' -NoNewline -Encoding utf8
        Set-ItemProperty -LiteralPath $script:dst -Name IsReadOnly -Value $true

        $result = Update-CcstatuslineConfig -SourcePath $script:src -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'Updated'
        (Get-Content -LiteralPath $script:dst -Raw) | Should -Be '{"version":3}'
        (Get-Item -LiteralPath $script:dst).IsReadOnly | Should -BeTrue
    }

    It 'derives the WSL user via whoami when -SourcePath and -WslUser are not given' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('passp') }
        }

        Update-CcstatuslineConfig -DistroName 'Ubuntu' -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log') | Out-Null

        # On most machines the derived UNC path won't exist, so the outcome would be
        # SourceUnavailable; on a machine that genuinely has that WSL distro/user/config, it may
        # resolve for real. Either way the destination stays safely under $TestDrive - the point
        # of this test is only that the whoami-based derivation ran with the right arguments.
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -ParameterFilter {
            $Arguments -contains 'whoami'
        }
    }

    It 'invokes whoami with --exec, never --' {
        # Regression: wsl.exe -- <cmd> hands the command line to the distro's default shell.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @('passp') }
        }

        Update-CcstatuslineConfig -DistroName 'Ubuntu' -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log') | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq "-d|Ubuntu|--exec|whoami"
        }
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--'
        }
    }

    It 'picks the username line out of whoami output that also carries a WSL transition warning on stderr' {
        # Regression: while WSL is restarting (e.g. right after the daily backup), wsl.exe can
        # print a warning on stderr and still exit 0. Invoke-WslExe merges stderr into Output, so
        # the warning line arrives ahead of the real username - it must not be used as-is.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @(
                    "wsl: Failed to start the systemd user session for 'passp'. See journalctl for more details.",
                    'passp'
                )
            }
        }
        # Force the SourceUnavailable branch deterministically regardless of what UNC paths
        # happen to resolve on the machine running this test - the point here is only which
        # username the derivation used, observed through the path it builds and logs.
        Mock -ModuleName WslAutomation Test-Path { $false }

        $result = Update-CcstatuslineConfig -DistroName 'Ubuntu' -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'SourceUnavailable'
        $logContent = Get-Content -LiteralPath (Join-Path $TestDrive 'sync.log') -Raw
        $logContent | Should -Match ([regex]::Escape('\\wsl.localhost\Ubuntu\home\passp\.config\ccstatusline\settings.json'))
        $logContent | Should -Not -Match 'Failed to start'
    }

    It 'returns SourceUnavailable without logging raw output when whoami output is only a WSL transition warning' {
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{
                ExitCode = 0
                Output   = @("wsl: Failed to start the systemd user session for 'passp'. See journalctl for more details.")
            }
        }

        $result = Update-CcstatuslineConfig -DistroName 'Ubuntu' -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log')

        $result.Status | Should -Be 'SourceUnavailable'
        Test-Path -LiteralPath $script:dst | Should -BeFalse
        $logContent = Get-Content -LiteralPath (Join-Path $TestDrive 'sync.log') -Raw
        $logContent | Should -Match "could not determine WSL user for distro 'Ubuntu'"
        $logContent | Should -Not -Match 'Failed to start'
    }

    It 'does not write the destination and returns Skipped under -WhatIf' {
        Set-Content -LiteralPath $script:src -Value '{"version":3}' -NoNewline -Encoding utf8

        $result = Update-CcstatuslineConfig -SourcePath $script:src -DestinationPath $script:dst `
            -LogFile (Join-Path $TestDrive 'sync.log') -WhatIf

        $result.Status | Should -Be 'Skipped'
        Test-Path -LiteralPath $script:dst | Should -BeFalse
    }
}
