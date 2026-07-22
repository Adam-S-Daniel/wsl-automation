#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Update-WslAutomationRepo' {

    BeforeEach {
        $script:stateFile = Join-Path $TestDrive 'state.json'
        $script:logFile = Join-Path $TestDrive 'repo-update.log'
        $script:now = [datetime]'2026-07-22T12:00:00Z'

        # $TestDrive is shared across every It in this Describe; force-remove any state/log
        # leftovers from a prior test so each test starts from a clean slate regardless of order.
        foreach ($leftoverPath in @($script:stateFile, $script:logFile)) {
            if (Test-Path -LiteralPath $leftoverPath) {
                Remove-Item -LiteralPath $leftoverPath -Force
            }
        }

        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('main') } }
            if ($Arguments[0] -eq 'status') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments[0] -eq 'fetch') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments -contains '--ff-only') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
    }

    It 'returns SkippedRecent and never calls git when the last success was within the interval' {
        $state = [pscustomobject]@{
            LastSuccessUtc = ($script:now.ToUniversalTime().AddHours(-1)).ToString('o')
            Branch         = 'main'
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:stateFile -Encoding utf8

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'SkippedRecent'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly
    }

    It 'updates and rewrites the state file when the last success is stale' {
        $oldTimestamp = ($script:now.ToUniversalTime().AddHours(-13)).ToString('o')
        $state = [pscustomobject]@{ LastSuccessUtc = $oldTimestamp; Branch = 'main' }
        $state | ConvertTo-Json | Set-Content -LiteralPath $script:stateFile -Encoding utf8

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'Updated'

        $newState = Get-Content -LiteralPath $script:stateFile -Raw | ConvertFrom-Json
        { [datetime]$newState.LastSuccessUtc } | Should -Not -Throw
        $newState.LastSuccessUtc | Should -Not -Be $oldTimestamp

        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments[0] -eq 'fetch' }
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments -contains '--ff-only' }
    }

    It 'updates and creates the state file when no prior state file exists' {
        Test-Path -LiteralPath $script:stateFile | Should -BeFalse

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'Updated'
        Test-Path -LiteralPath $script:stateFile | Should -BeTrue
    }

    It 'returns NotOnBranch and never fetches when the repo is on a different branch' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('feature-x') } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'NotOnBranch'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -ParameterFilter { $Arguments[0] -eq 'fetch' }
    }

    It 'returns NotAGitRepo when rev-parse fails' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 1; Output = @() } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'NotAGitRepo'
    }

    It 'returns WorkingTreeDirty and never fetches when there is a tracked modification' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('main') } }
            if ($Arguments[0] -eq 'status') { return [pscustomobject]@{ ExitCode = 0; Output = @(' M src/foo.ps1') } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'WorkingTreeDirty'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -ParameterFilter { $Arguments[0] -eq 'fetch' }
    }

    It 'proceeds to Updated when the working tree has only untracked files' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('main') } }
            if ($Arguments[0] -eq 'status') { return [pscustomobject]@{ ExitCode = 0; Output = @('?? .claude/') } }
            if ($Arguments[0] -eq 'fetch') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments -contains '--ff-only') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'Updated'
    }

    It 'returns FetchFailed, never merges, and does not write the state file when fetch fails' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('main') } }
            if ($Arguments[0] -eq 'status') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments[0] -eq 'fetch') { return [pscustomobject]@{ ExitCode = 1; Output = @() } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'FetchFailed'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -ParameterFilter { $Arguments[0] -eq 'merge' }
        Test-Path -LiteralPath $script:stateFile | Should -BeFalse
    }

    It 'returns Merged and writes state when the fast-forward fails but a plain merge succeeds' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('main') } }
            if ($Arguments[0] -eq 'status') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments[0] -eq 'fetch') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments -contains '--ff-only') { return [pscustomobject]@{ ExitCode = 1; Output = @() } }
            if ($Arguments[0] -eq 'merge') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now

        $result.Status | Should -Be 'Merged'
        Test-Path -LiteralPath $script:stateFile | Should -BeTrue
    }

    It 'returns ConflictSkipped, aborts the merge, and does not write state when both merges fail' {
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments -contains 'rev-parse') { return [pscustomobject]@{ ExitCode = 0; Output = @('main') } }
            if ($Arguments[0] -eq 'status') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments[0] -eq 'fetch') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments -contains '--ff-only') { return [pscustomobject]@{ ExitCode = 1; Output = @() } }
            if ($Arguments -contains '--abort') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments[0] -eq 'merge') { return [pscustomobject]@{ ExitCode = 1; Output = @() } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now -WarningAction SilentlyContinue

        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments -contains '--abort' }
        $result.Status | Should -Be 'ConflictSkipped'
        Test-Path -LiteralPath $script:stateFile | Should -BeFalse
    }

    It 'returns Skipped and never calls git under -WhatIf' {
        $result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now -WhatIf

        $result.Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly
    }

    It 'catches an unexpected exception and returns Error instead of throwing' {
        Mock -ModuleName WslAutomation Invoke-GitExe { throw 'boom' }

        { $script:result = Update-WslAutomationRepo -RepoPath 'C:\fake\repo' -StateFile $script:stateFile -LogFile $script:logFile -Now $script:now } | Should -Not -Throw
        $script:result.Status | Should -Be 'Error'
    }
}
