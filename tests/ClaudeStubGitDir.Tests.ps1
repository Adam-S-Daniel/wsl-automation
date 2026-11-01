#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Test-ClaudeStubGitDir' {
    # Private seam, called through InModuleScope. Get-WslDistroState and Invoke-WslExe are the
    # only things mocked; every wsl.exe call is recorded (its argument array) in order.

    BeforeEach {
        $script:wslCalls = [System.Collections.Generic.List[object]]::new()
        $script:probeAnswer = 'absent'
        $script:probeExit = 0
        $script:logFile = Join-Path $TestDrive 'keeper.log'
        Remove-Item -LiteralPath $script:logFile -ErrorAction SilentlyContinue

        Mock -ModuleName WslAutomation Get-WslDistroState { 'Running' }
        Mock -ModuleName WslAutomation Invoke-WslExe {
            $script:wslCalls.Add($Arguments)
            [pscustomobject]@{ ExitCode = $script:probeExit; Output = @($script:probeAnswer) }
        }
    }

    It 'never boots a stopped distro: no wsl.exe call and no log line' {
        Mock -ModuleName WslAutomation Get-WslDistroState { 'Stopped' }

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Skipped'
        Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
        Test-Path -LiteralPath $script:logFile | Should -BeFalse
    }

    It 'reports Absent and logs nothing when ~/repos has no .git' {
        $script:probeAnswer = 'absent'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Absent'
        Test-Path -LiteralPath $script:logFile | Should -BeFalse
    }

    It 'reports Repo and logs nothing when ~/repos/.git is a real repository' {
        $script:probeAnswer = 'repo'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Repo'
        Test-Path -LiteralPath $script:logFile | Should -BeFalse
    }

    It 'reports Stub and logs one warning line with the fix when ~/repos/.git is not a real repository' {
        $script:probeAnswer = 'stub'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Stub'
        Test-Path -LiteralPath $script:logFile | Should -BeTrue
        $lines = @(Get-Content -LiteralPath $script:logFile)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '~/repos/\.git is not a real git repository'
        $lines[0] | Should -Match 'mv ~/repos/\.git ~/repos/\.git\.stray'
    }

    It 'skips and logs nothing when the probe exits non-zero' {
        $script:probeExit = 1
        $script:probeAnswer = 'stub'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Skipped'
        Test-Path -LiteralPath $script:logFile | Should -BeFalse
    }

    It 'skips and logs nothing when the probe prints something unexpected' {
        $script:probeAnswer = 'garbage'

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Skipped'
        Test-Path -LiteralPath $script:logFile | Should -BeFalse
    }

    It 'does not throw when Invoke-WslExe throws' {
        Mock -ModuleName WslAutomation Invoke-WslExe { throw 'wsl.exe not found' }

        $result = InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        }

        $result | Should -Be 'Skipped'
    }

    It 'makes exactly one wsl.exe call: -d Ubuntu --exec sh -c <script>' {
        InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        } | Out-Null

        $script:wslCalls.Count | Should -Be 1
        $callArguments = $script:wslCalls[0]
        $callArguments.Count | Should -Be 6
        ($callArguments[0..4] -join '|') | Should -Be '-d|Ubuntu|--exec|sh|-c'
    }

    It 'tells a missing, stub and real .git apart when the probe script runs in a real sh' -Skip:(-not $IsLinux) {
        # The probe script is taken from the recorded wsl.exe call (its sixth argument) and run
        # against a throwaway home directory, so what the keeper asks the distro is what is tested.
        InModuleScope WslAutomation -Parameters @{ LogFile = $script:logFile } {
            param($LogFile)
            Test-ClaudeStubGitDir -DistroName 'Ubuntu' -LogFile $LogFile
        } | Out-Null
        $probeScript = $script:wslCalls[0][5]

        $originalHome = $env:HOME
        try {
            # No ~/repos/.git at all.
            $fakeHome = Join-Path $TestDrive 'home-absent'
            New-Item -ItemType Directory -Path (Join-Path $fakeHome 'repos') -Force | Out-Null
            $env:HOME = $fakeHome
            (& sh -c $probeScript | Out-String).Trim() | Should -Be 'absent' -Because 'a ~/repos without .git is the normal case'

            # The shape seen on 2026-10-02: only info/exclude inside .git.
            $fakeHome = Join-Path $TestDrive 'home-exclude-only'
            New-Item -ItemType Directory -Path (Join-Path $fakeHome 'repos' '.git' 'info') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $fakeHome 'repos' '.git' 'info' 'exclude') -Value '# stray'
            $env:HOME = $fakeHome
            (& sh -c $probeScript | Out-String).Trim() | Should -Be 'stub' -Because '.git/info/exclude alone is not a repository'

            # A real repository: HEAD file and objects folder.
            $fakeHome = Join-Path $TestDrive 'home-real-repo'
            New-Item -ItemType Directory -Path (Join-Path $fakeHome 'repos') -Force | Out-Null
            & git init -q (Join-Path $fakeHome 'repos') 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0 -Because 'git init is needed to build the real-repository case'
            $env:HOME = $fakeHome
            (& sh -c $probeScript | Out-String).Trim() | Should -Be 'repo' -Because 'a .git with HEAD and objects is a real repository'

            # A .git that is a regular file.
            $fakeHome = Join-Path $TestDrive 'home-git-file'
            New-Item -ItemType Directory -Path (Join-Path $fakeHome 'repos') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $fakeHome 'repos' '.git') -Value 'gitdir: /nowhere'
            $env:HOME = $fakeHome
            (& sh -c $probeScript | Out-String).Trim() | Should -Be 'stub' -Because 'a .git file is not wanted in ~/repos'
        }
        finally {
            $env:HOME = $originalHome
        }
    }
}
