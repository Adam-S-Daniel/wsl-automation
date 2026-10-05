#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
    . (Join-Path $PSScriptRoot '..' 'scripts' 'update-task-checkout.ps1')
}

Describe 'Checkout mutex name policy' {
    It 'uses the current host namespace by default and produces stable names' {
        InModuleScope WslAutomation {
            $name = Get-WslAutomationRepoMutexName -RepoPath $TestDrive
            $prefix = if ($IsWindows) { 'Global\WslAutomationRepoUpdate-' } else { 'WslAutomationRepoUpdate-' }
            $name.StartsWith($prefix) | Should -BeTrue
            $name | Should -BeExactly (Get-WslAutomationRepoMutexName -RepoPath $TestDrive)
        }
    }

    It 'uses the Windows global namespace and canonicalizes path case' {
        InModuleScope WslAutomation {
            $saved = Get-Variable IsWindows -Scope Script -ErrorAction SilentlyContinue
            $savedValue = if ($saved) { $saved.Value } else { $null }
            try {
                $script:IsWindows = $true
                $name = Get-WslAutomationRepoMutexName -RepoPath (Join-Path $TestDrive 'Example')
                $name.StartsWith('Global\WslAutomationRepoUpdate-') | Should -BeTrue
                $name | Should -BeExactly (Get-WslAutomationRepoMutexName -RepoPath (Join-Path $TestDrive 'example'))
                $name | Should -BeExactly (Get-WslAutomationRepoMutexName -RepoPath (Join-Path $TestDrive 'Example' '..' 'Example'))
            }
            finally {
                if ($saved) { Set-Variable IsWindows -Scope Script -Value $savedValue }
                else { Remove-Variable IsWindows -Scope Script }
            }
        }
    }

    It 'uses no session namespace off Windows and preserves case distinctions' {
        InModuleScope WslAutomation {
            $saved = Get-Variable IsWindows -Scope Script -ErrorAction SilentlyContinue
            $savedValue = if ($saved) { $saved.Value } else { $null }
            try {
                $script:IsWindows = $false
                $name = Get-WslAutomationRepoMutexName -RepoPath (Join-Path $TestDrive 'Example')
                $name.StartsWith('WslAutomationRepoUpdate-') | Should -BeTrue
                $name | Should -Not -BeExactly (Get-WslAutomationRepoMutexName -RepoPath (Join-Path $TestDrive 'example'))
            }
            finally {
                if ($saved) { Set-Variable IsWindows -Scope Script -Value $savedValue }
                else { Remove-Variable IsWindows -Scope Script }
            }
        }
    }

    It 'creates the mutex using the policy helper' {
        InModuleScope WslAutomation {
            Mock Get-WslAutomationRepoMutexName { 'WslAutomationTestMutex-Only' }
            $mutex = New-WslAutomationRepoMutex -RepoPath $TestDrive
            try { Should -Invoke Get-WslAutomationRepoMutexName -Times 1 -Exactly -ParameterFilter { $RepoPath -eq $TestDrive } }
            finally { $mutex.Dispose() }
        }
    }
}

Describe 'Noninteractive Git process configuration' {
    It 'overrides inherited interactive settings and removes askpass helpers' {
        InModuleScope WslAutomation {
            $names = @('GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE', 'GIT_ASKPASS', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'WSL_AUTOMATION_TEST_SENTINEL')
            $saved = @{}
            try {
                foreach ($name in $names) {
                    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
                    [Environment]::SetEnvironmentVariable($name, 'interactive-fixture')
                }
                $info = Get-WslAutomationGitStartInfo -Arguments @('-C', 'example folder', 'fetch', 'origin')
                $info.Environment['GIT_TERMINAL_PROMPT'] | Should -BeExactly '0'
                $info.Environment['GCM_INTERACTIVE'] | Should -BeExactly 'Never'
                foreach ($name in @('GIT_ASKPASS', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE')) {
                    $info.Environment.ContainsKey($name) | Should -BeFalse
                }
                $info.Environment['WSL_AUTOMATION_TEST_SENTINEL'] | Should -BeExactly 'interactive-fixture'
                $info.FileName | Should -BeExactly 'git'
                $info.UseShellExecute | Should -BeFalse
                $info.CreateNoWindow | Should -BeTrue
                $info.RedirectStandardOutput | Should -BeTrue
                $info.RedirectStandardError | Should -BeTrue
                @($info.ArgumentList) | Should -Be @('-C', 'example folder', 'fetch', 'origin')
            }
            finally {
                foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
            }
        }
    }

    It 'starts Git using the configuration helper' {
        # Parse the call wiring without launching a process or touching credentials.
        $path = Join-Path $PSScriptRoot '..' 'src' 'WslAutomation' 'Private' 'Invoke-GitExe.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-WslAutomationGitProcess' }, $true)
        $start = $function.Body.Find({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and $node.Expression.TypeName.FullName -eq 'Diagnostics.Process' -and $node.Member.Value -eq 'Start' }, $true)
        $start | Should -Not -BeNullOrEmpty
        $calls = @($start.Arguments[0].FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-WslAutomationGitStartInfo' }, $true))
        $calls.Count | Should -Be 1
        $calls[0].CommandElements[1] | Should -BeOfType ([Management.Automation.Language.CommandParameterAst])
        $calls[0].CommandElements[1].ParameterName | Should -BeExactly 'Arguments'
        $calls[0].CommandElements[2] | Should -BeOfType ([Management.Automation.Language.VariableExpressionAst])
        $calls[0].CommandElements[2].VariablePath.UserPath | Should -BeExactly 'Arguments'
    }
}

Describe 'Update-WslAutomationRepo' {
    BeforeEach {
        $script:logFile = Join-Path $TestDrive 'repo-update.log'
        $script:gitCalls = [Collections.Generic.List[string]]::new()
        $script:branch = 'main'
        $script:dirty = @()
        $script:fetchExit = 0
        $script:ancestorExit = 0
        $script:mergeExit = 0
        $script:switchExit = 0
        $script:switchMoves = $false
        $script:mergeMoves = $false
        $script:headReads = 0
        $script:headReadReleaseCounts = [Collections.Generic.List[int]]::new()
        $script:finalHeadFailure = ''
        $script:changed = $false
        $script:locked = $true
        $script:released = 0
        $script:disposed = 0
        $script:gitFailure = ''
        if (Test-Path $script:logFile) { Remove-Item $script:logFile }
        Mock -ModuleName WslAutomation New-WslAutomationRepoMutex {
            $fake = [pscustomobject]@{}
            $fake | Add-Member ScriptMethod WaitOne { param($milliseconds) $script:lockWait = $milliseconds; $script:locked }
            $fake | Add-Member ScriptMethod ReleaseMutex { $script:released++ }
            $fake | Add-Member ScriptMethod Dispose { $script:disposed++ }
            $fake
        }
        Mock -ModuleName WslAutomation Invoke-GitExe {
            $command = $Arguments -join ' '
            $script:gitCalls.Add($command)
            # Model a command moving HEAD before it returns an error or throws.
            if ($command -eq 'switch main' -and $script:switchMoves) { $script:mergeMoves = $true }
            if ($command -eq 'merge --ff-only origin/main' -and $script:changed) { $script:mergeMoves = $true }
            if ($command -eq $script:gitFailure) { throw 'credential-bearing exception' }
            $code = 0
            $output = @()
            switch ($command) {
                'rev-parse HEAD' {
                    $script:headReads++
                    $script:headReadReleaseCounts.Add($script:released)
                    if ($script:headReads -gt 1 -and $script:finalHeadFailure -eq 'throw') { throw 'HEAD read failed' }
                    if ($script:headReads -gt 1 -and $script:finalHeadFailure -eq 'exit') { $code = 1 }
                    $output = @(if ($script:mergeMoves) { 'b' * 40 } else { 'a' * 40 })
                }
                'rev-parse --abbrev-ref HEAD' { $output = @($script:branch) }
                'status --porcelain' { $output = $script:dirty }
                'fetch origin' { $code = $script:fetchExit }
                'merge-base --is-ancestor HEAD origin/main' { $code = $script:ancestorExit }
                'merge --ff-only origin/main' { $code = $script:mergeExit }
                'switch main' { $code = $script:switchExit }
                default { throw "unexpected Git command: $command" }
            }
            [pscustomobject]@{ ExitCode = $code; Output = $output }
        }
    }

    It 'fast-forwards clean main with every Git call bounded and releases the lock' {
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -TimeoutSeconds 7
        $result.Status | Should -Be 'Updated'
        $result.Changed | Should -BeFalse
        ($script:gitCalls -join '|') | Should -Be 'rev-parse HEAD|fetch origin|rev-parse --abbrev-ref HEAD|status --porcelain|merge-base --is-ancestor HEAD origin/main|merge --ff-only origin/main|rev-parse HEAD'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 7 -Exactly -ParameterFilter { $TimeoutSeconds -eq 7 }
        $script:released | Should -Be 1
        $script:disposed | Should -Be 1
        $script:lockWait | Should -Be 5000
        @($script:headReadReleaseCounts) | Should -Be @(0, 0)
        Test-Path $script:logFile | Should -BeFalse
    }

    It 'detects a behind checkout changing HEAD' {
        $script:changed = $true
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile
        $result.Status | Should -Be 'Updated'
        $result.Changed | Should -BeTrue
        Get-Content $script:logFile -Raw | Should -Match 'updated checkout HEAD'
    }

    It 'fetches on every call rather than using the old 12-hour gate' {
        1..2 | ForEach-Object { Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile | Out-Null }
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 2 -Exactly -ParameterFilter { $Arguments[0] -eq 'fetch' }
    }

    It 'switches a clean feature branch to main before merging, even at the same HEAD' {
        $script:branch = 'feature-example'
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile
        $result.Status | Should -Be 'Updated'
        $result.Changed | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq 'switch main' }
        $script:gitCalls.IndexOf('switch main') | Should -BeLessThan $script:gitCalls.IndexOf('merge --ff-only origin/main')
    }

    It 'warns and preserves a dirty <Branch> checkout (<Change>)' -ForEach @(
        @{ Branch = 'feature-example'; Change = ' M src/example.ps1' },
        @{ Branch = 'main'; Change = ' M src/example.ps1' },
        @{ Branch = 'feature-example'; Change = '?? example.txt' }
    ) {
        $script:branch = $Branch
        $script:dirty = @($Change)
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Status | Should -Be 'WorkingTreeDirty'
        $result.Changed | Should -BeFalse
        $warnings | Should -Not -BeNullOrEmpty
        Get-Content $script:logFile -Raw | Should -Match 'WARNING.*WorkingTreeDirty'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -in @('switch', 'merge') }
    }

    It 'warns without merging when main has local commits' {
        $script:ancestorExit = 1
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Diverged'
        $warnings | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'merge' }
    }

    It 'fails open and warns on fetch exit <Code>, including timeout' -ForEach @(@{ Code = 1 }, @{ Code = 124 }) {
        $script:fetchExit = $Code
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Status | Should -Be 'FetchFailed'
        $warnings | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -in @('switch', 'merge') }
        $script:released | Should -Be 1
    }

    It 'never falls back to a regular merge after a failed fast-forward' {
        $script:mergeExit = 1
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        $result.Changed | Should -BeFalse
        $warnings | Should -Not -BeNullOrEmpty
        Get-Content $script:logFile -Raw | Should -Match 'WARNING.*Error'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'merge' -and $Arguments[1] -eq '--ff-only' }
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -in @('reset', 'stash', 'clean') -or ($Arguments[0] -eq 'merge' -and $Arguments[1] -ne '--ff-only') }
    }

    It 'does not reload after a failed switch that leaves HEAD unchanged' {
        $script:branch = 'feature-example'
        $script:switchExit = 1
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        $result.Changed | Should -BeFalse
        $script:headReads | Should -Be 2
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'merge' }
    }

    It 'verifies movement after a <Command> that <Failure>' -ForEach @(
        @{ Command = 'switch main'; Failure = 'exits nonzero' },
        @{ Command = 'switch main'; Failure = 'throws' },
        @{ Command = 'merge --ff-only origin/main'; Failure = 'exits nonzero' },
        @{ Command = 'merge --ff-only origin/main'; Failure = 'throws' }
    ) {
        $script:branch = 'feature-example'
        if ($Command -eq 'switch main') { $script:switchMoves = $true; $script:switchExit = 1 }
        else { $script:changed = $true; $script:mergeExit = 1 }
        if ($Failure -eq 'throws') { $script:gitFailure = $Command }
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        $result.Changed | Should -BeTrue
        $script:headReads | Should -Be 2
        @($script:headReadReleaseCounts) | Should -Be @(0, 0)
        $script:gitCalls[$script:gitCalls.Count - 1] | Should -Be 'rev-parse HEAD'
        $script:released | Should -Be 1
    }

    It 'does not reload after a thrown <_> that leaves HEAD unchanged' -ForEach @('switch main', 'merge --ff-only origin/main') {
        $script:branch = 'feature-example'
        $script:gitFailure = $_
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        $result.Changed | Should -BeFalse
        $script:headReads | Should -Be 2
        @($script:headReadReleaseCounts) | Should -Be @(0, 0)
    }

    It 'preserves verified switch movement when ancestry later fails' {
        $script:branch = 'feature-example'
        $script:switchMoves = $true
        $script:ancestorExit = 1
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Diverged'
        $result.Changed | Should -BeTrue
        $script:headReads | Should -Be 2
    }

    It 'does not claim unverified movement when the final HEAD read <_>' -ForEach @('exit', 'throw') {
        $script:changed = $true
        $script:finalHeadFailure = $_
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        $result.Changed | Should -BeFalse
        $warnings | Should -Not -BeNullOrEmpty
        $script:headReads | Should -Be 2
    }

    It 'skips Git on lock contention and never releases an unowned lock' {
        $script:locked = $false
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -LockTimeoutSeconds 0 -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Status | Should -Be 'LockBusy'
        $warnings | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly
        $script:released | Should -Be 0
        $script:disposed | Should -Be 1
    }

    It 'contains exceptions without logging their data and releases its lock' {
        $script:gitFailure = 'rev-parse HEAD'
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        Get-Content $script:logFile -Raw | Should -Not -Match 'credential-bearing'
        $script:released | Should -Be 1
    }

    It 'does no work under WhatIf' {
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WhatIf
        $result.Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName WslAutomation New-WslAutomationRepoMutex -Times 0 -Exactly
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly
    }

    It 'does not switch or merge when status cannot be read' {
        $script:gitFailure = 'status --porcelain'
        $result = Update-WslAutomationRepo -RepoPath $TestDrive -LogFile $script:logFile -WarningAction SilentlyContinue
        $result.Status | Should -Be 'Error'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -in @('switch', 'merge') }
    }
}

Describe 'Initialize-WslAutomationTask' {
    BeforeEach {
        $script:entry = Join-Path $TestDrive 'scripts' 'example.ps1'
        $script:originalGuard = $env:WSL_AUTOMATION_TASK_REEXEC
        $env:WSL_AUTOMATION_TASK_REEXEC = $null
        Mock Import-Module { }
        Mock Update-WslAutomationRepo { [pscustomobject]@{ Changed = $false } }
        Mock Invoke-WslAutomationTaskProcess { }
    }
    AfterEach { $env:WSL_AUTOMATION_TASK_REEXEC = $script:originalGuard }

    It 'continues the original task after an unchanged or skipped update' {
        $result = Initialize-WslAutomationTask -ScriptPath $script:entry -Parameters @{}
        $result.Relaunched | Should -BeFalse
        Should -Invoke Update-WslAutomationRepo -Times 1 -Exactly
        Should -Invoke Invoke-WslAutomationTaskProcess -Times 0 -Exactly
    }

    It 'reloads changed code once in a fresh host, preserves parameters, and propagates exit status' {
        Mock Update-WslAutomationRepo { [pscustomobject]@{ Changed = $true } }
        Mock Invoke-WslAutomationTaskProcess { $script:childGuard = $env:WSL_AUTOMATION_TASK_REEXEC; $script:taskProcessExitCode = 3 }
        $result = Initialize-WslAutomationTask -ScriptPath $script:entry -Parameters @{
            BackupDir = 'C:\example folder'; DistroName = 'Ubuntu'; RetentionCount = 4
            NoPause = [System.Management.Automation.SwitchParameter]::new($true)
            IgnoreActivity = [System.Management.Automation.SwitchParameter]::new($false)
        }
        $result.Relaunched | Should -BeTrue
        $result.ExitCode | Should -Be 3
        $script:childGuard | Should -Be $script:entry
        Should -Invoke Invoke-WslAutomationTaskProcess -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq '-NoProfile' -and $Arguments[1] -eq '-File' -and $Arguments[2] -eq $script:entry -and
            $Arguments -contains 'C:\example folder' -and $Arguments -contains '-NoPause:True' -and
            $Arguments -contains '-IgnoreActivity:False' -and $Arguments -contains '4'
        }
        $env:WSL_AUTOMATION_TASK_REEXEC | Should -BeNullOrEmpty
    }

    It 'runs the updated entry from disk in a fresh host after a changed HEAD' {
        New-Item -ItemType Directory (Split-Path $script:entry -Parent) -Force | Out-Null
        Set-Content $script:entry "throw 'stale entry must not run'"
        Mock Update-WslAutomationRepo {
            # Model the merge replacing the entry while its original host is already loaded.
            Set-Content $script:entry @'
param([string]$DistroName, [switch]$NoPause)
if ($env:WSL_AUTOMATION_TASK_REEXEC -ne $PSCommandPath) { throw 'missing recursion guard' }
if (-not $NoPause) { throw 'lost unattended switch' }
Write-Output "updated entry:$DistroName"
exit 4
'@
            [pscustomobject]@{ Changed = $true }
        }
        Mock Invoke-WslAutomationTaskProcess {
            # This child runs only the Git-free fixture above. It cannot signal processes,
            # import production task code, access credentials, or contact a network.
            $script:childOutput = & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) @Arguments
            $script:taskProcessExitCode = $LASTEXITCODE
        }
        $result = Initialize-WslAutomationTask -ScriptPath $script:entry -Parameters @{ DistroName = 'ExampleDistro'; NoPause = [System.Management.Automation.SwitchParameter]::new($true) }
        $result.Relaunched | Should -BeTrue
        $result.ExitCode | Should -Be 4
        $script:childOutput | Should -Be 'updated entry:ExampleDistro'
        Should -Invoke Update-WslAutomationRepo -Times 1 -Exactly
        Should -Invoke Invoke-WslAutomationTaskProcess -Times 1 -Exactly
    }

    It 'guards the child from fetching or relaunching again' {
        $env:WSL_AUTOMATION_TASK_REEXEC = $script:entry
        Mock Update-WslAutomationRepo { [pscustomobject]@{ Changed = $true } }
        $result = Initialize-WslAutomationTask -ScriptPath $script:entry -Parameters @{}
        $result.Relaunched | Should -BeFalse
        Should -Invoke Update-WslAutomationRepo -Times 0 -Exactly
        Should -Invoke Invoke-WslAutomationTaskProcess -Times 0 -Exactly
    }

    It 'lets a different task update despite an inherited guard' {
        $env:WSL_AUTOMATION_TASK_REEXEC = 'other-task.ps1'
        Initialize-WslAutomationTask -ScriptPath $script:entry -Parameters @{} | Out-Null
        Should -Invoke Update-WslAutomationRepo -Times 1 -Exactly
    }

    It 'warns and lets the task continue when the bootstrap throws' {
        Mock Update-WslAutomationRepo { throw 'credential-bearing exception' }
        $result = Initialize-WslAutomationTask -ScriptPath $script:entry -Parameters @{} -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Relaunched | Should -BeFalse
        $warnings | Should -Not -BeNullOrEmpty
        ($warnings -join '') | Should -Not -Match 'credential-bearing'
    }
}

Describe 'Invoke-GitExe timeout seam' {
    BeforeEach {
        $script:waitResult = $true
        $script:fakePid = 10
        $script:killed = 0
        $script:processDisposed = 0
        Mock -ModuleName WslAutomation Start-WslAutomationGitProcess {
            $reader = [pscustomobject]@{}
            $reader | Add-Member ScriptMethod ReadToEndAsync { [Threading.Tasks.Task]::FromResult([string]'example') }
            $fake = [pscustomobject]@{ Id = $script:fakePid; HasExited = $false; ExitCode = 0; StandardOutput = $reader; StandardError = $reader }
            $fake | Add-Member ScriptMethod WaitForExit { param($milliseconds) $script:processWait = $milliseconds; $script:waitResult }
            $fake | Add-Member ScriptMethod Kill { param($entireTree) $script:killTree = $entireTree; $script:killed++ }
            $fake | Add-Member ScriptMethod Dispose { $script:processDisposed++ }
            $fake
        }
    }

    It 'captures output and passes each argument intact to the process seam' {
        $result = InModuleScope WslAutomation { Invoke-GitExe -RepoPath 'C:\example folder' -Arguments @('fetch', 'origin') }
        $result.ExitCode | Should -Be 0
        $result.Output.Count | Should -Be 2
        Should -Invoke -ModuleName WslAutomation Start-WslAutomationGitProcess -Times 1 -Exactly -ParameterFilter { ($Arguments -join '|') -eq '-C|C:\example folder|fetch|origin' }
        $script:killed | Should -Be 0
        $script:processDisposed | Should -Be 1
    }

    It 'reports timeout and stops only its own mocked child' {
        $script:waitResult = $false
        $result = InModuleScope WslAutomation { Invoke-GitExe -Arguments @('fetch', 'origin') -TimeoutSeconds 1 }
        $result.ExitCode | Should -Be 124
        $result.Output | Should -BeNullOrEmpty
        $script:killed | Should -Be 1
        $script:killTree | Should -BeTrue
        $script:processWait | Should -Be 1000
        $script:processDisposed | Should -Be 1
    }

    It 'never signals unsafe mocked pid <_>' -ForEach @(-1, 0, 1, '10') {
        $script:waitResult = $false
        $script:fakePid = $_
        $result = InModuleScope WslAutomation { Invoke-GitExe -Arguments @('fetch', 'origin') -TimeoutSeconds 1 }
        $result.ExitCode | Should -Be 124
        $script:killed | Should -Be 0
    }
}

Describe 'Existing task entries fail open after checkout warnings' {
    BeforeAll {
        # Replace exits using the real AST so entries can be invoked safely within Pester.
        $script:fixtureScripts = Join-Path $TestDrive 'entry-fixtures' 'scripts'
        New-Item -ItemType Directory $script:fixtureScripts -Force | Out-Null
        $helperPath = Join-Path $PSScriptRoot '..' 'scripts' 'update-task-checkout.ps1'
        $helperAst = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$null, [ref]$null)
        $helperSource = Get-Content $helperPath -Raw
        $processFunction = $helperAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WslAutomationTaskProcess' }, $true)
        # A mutant that unexpectedly reloads must not launch any real task process.
        $helperSource = $helperSource.Remove($processFunction.Extent.StartOffset, $processFunction.Extent.EndOffset - $processFunction.Extent.StartOffset).Insert(
            $processFunction.Extent.StartOffset, "function Invoke-WslAutomationTaskProcess { throw 'native task process forbidden in entry fixture' }")
        Set-Content (Join-Path $script:fixtureScripts 'update-task-checkout.ps1') $helperSource
        foreach ($entry in @('ensure-claude-session.ps1', 'sync-ccstatusline-config.ps1', 'sync-codex-cloud-environments.ps1', 'wsl-ubuntu-backup.ps1')) {
            $path = Join-Path $PSScriptRoot '..' 'scripts' $entry
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $source = Get-Content $path -Raw
            $exits = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] }, $true) | Sort-Object { $_.Extent.StartOffset } -Descending)
            foreach ($exitNode in $exits) {
                $source = $source.Remove($exitNode.Extent.StartOffset, 4).Insert($exitNode.Extent.StartOffset, 'return')
            }
            Set-Content (Join-Path $script:fixtureScripts $entry) $source
        }
    }
    BeforeEach {
        $script:entryFailureMode = 'timeout'
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $script:savedEntryGuard = $env:WSL_AUTOMATION_TASK_REEXEC
        $env:LOCALAPPDATA = $TestDrive
        $env:WSL_AUTOMATION_TASK_REEXEC = $null
        Mock Import-Module { }
        Mock -ModuleName WslAutomation Invoke-GitExe {
            if ($Arguments[0] -eq 'fetch' -and $script:entryFailureMode -eq 'timeout') { return [pscustomobject]@{ ExitCode = 124; Output = @() } }
            $output = @()
            if ($Arguments -contains '--abbrev-ref') { $output = @('feature-example') }
            elseif ($Arguments[0] -eq 'rev-parse') { $output = @('a' * 40) }
            elseif ($Arguments[0] -eq 'status') { $output = @(' M example.ps1') }
            [pscustomobject]@{ ExitCode = 0; Output = $output }
        }
        # No task may reach any real distro, session launcher, config file, or backup.
        Mock Invoke-ClaudeSessionKeeper { [pscustomobject]@{ Status = 'AlreadyRunning'; WaitedSeconds = 0; ResumedSessionCount = 0; CodexRemoteControlLaunched = $false } }
        Mock Update-CcstatuslineConfig { [pscustomobject]@{ Status = 'Updated' } }
        Mock Invoke-CodexCloudEnvironmentSync { [pscustomobject]@{ Status = 'Completed' } }
        Mock Invoke-WslBackup { [pscustomobject]@{ Status = 'Deferred'; FilePath = '' } }
        Mock Read-Host { throw 'an unattended task must not prompt' }
    }
    AfterEach {
        $env:LOCALAPPDATA = $script:savedLocalAppData
        $env:WSL_AUTOMATION_TASK_REEXEC = $script:savedEntryGuard
    }

    It 'continues <Entry> after a fetch timeout and retains its bound parameters' -ForEach @(
        @{ Entry = 'ensure-claude-session.ps1'; Work = 'Invoke-ClaudeSessionKeeper' },
        @{ Entry = 'sync-ccstatusline-config.ps1'; Work = 'Update-CcstatuslineConfig' },
        @{ Entry = 'sync-codex-cloud-environments.ps1'; Work = 'Invoke-CodexCloudEnvironmentSync' },
        @{ Entry = 'wsl-ubuntu-backup.ps1'; Work = 'Invoke-WslBackup' }
    ) {
        $parameters = @{ DistroName = 'ExampleDistro' }
        if ($Entry -eq 'wsl-ubuntu-backup.ps1') { $parameters.BackupDir = 'C:\example'; $parameters.NoPause = $true }
        & (Join-Path $script:fixtureScripts $Entry) @parameters -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        Should -Invoke $Work -Times 1 -Exactly -ParameterFilter { $DistroName -eq 'ExampleDistro' }
        $warnings | Should -Not -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'continues the keeper on a dirty feature branch without switching or merging' {
        $script:entryFailureMode = 'dirty'
        & (Join-Path $script:fixtureScripts 'ensure-claude-session.ps1') -DistroName 'ExampleDistro' -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Invoke-ClaudeSessionKeeper -Times 1 -Exactly -ParameterFilter { $DistroName -eq 'ExampleDistro' }
        $warnings | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments[0] -in @('switch', 'merge') }
    }
}
