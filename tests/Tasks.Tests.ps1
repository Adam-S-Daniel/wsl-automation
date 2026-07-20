#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Set-WslAutomationScheduledTasks' -Skip:(-not $IsWindows) {

    BeforeEach {
        # Absolute safety net: no test in this file may ever reach a real wsl.exe.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $script:scriptsDir = Join-Path $TestDrive 'scripts'
        $script:backupDir = Join-Path $TestDrive 'backups'
        New-Item -ItemType Directory -Path $script:scriptsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:backupDir -Force | Out-Null

        $script:capturedActions = @()
        $script:capturedTriggers = @()

        # None of these real Task Scheduler / rename cmdlets may ever execute for real from
        # this test file: every one of them is mocked at module scope so nothing here can
        # touch the actual Windows Task Scheduler, no matter what the implementation does.
        Mock -ModuleName WslAutomation New-ScheduledTaskAction {
            $action = [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
            $script:capturedActions += $action
            return $action
        }

        Mock -ModuleName WslAutomation New-ScheduledTaskTrigger {
            # Mirror the real ScheduledTasks contract: a trigger's Repetition property is $null
            # unless -RepetitionInterval was actually passed to New-ScheduledTaskTrigger (a
            # -Once trigger created without it has Repetition = $null, and mutating .Interval on
            # a null Repetition throws). Only -RepetitionInterval-based construction is
            # supported now - the implementation no longer mutates .Repetition after creation.
            $repetition = $null
            if ($RepetitionInterval) {
                $repetition = [pscustomobject]@{
                    Interval = "PT$([int]$RepetitionInterval.TotalMinutes)M"
                    Duration = if ($RepetitionDuration) { "PT$([int]$RepetitionDuration.TotalMinutes)M" } else { $null }
                }
            }
            $trigger = [pscustomobject]@{
                IsDaily    = [bool]$Daily
                IsOnce     = [bool]$Once
                IsAtLogOn  = [bool]$AtLogOn
                At         = $At
                Repetition = $repetition
            }
            $script:capturedTriggers += $trigger
            return $trigger
        }

        Mock -ModuleName WslAutomation New-ScheduledTaskSettingsSet {
            [pscustomobject]@{ FakeSettings = $true }
        }

        Mock -ModuleName WslAutomation New-ScheduledTaskPrincipal {
            [pscustomobject]@{ FakePrincipal = $true; UserId = $UserId }
        }

        # Register-/Set-ScheduledTask are real cmdletization (CDXML) functions on Windows whose
        # -Action/-Trigger/-Settings/-Principal parameters are strongly typed to CimInstance;
        # their dynamic-parameter binding does not mock reliably under Pester 5.7.1 even with
        # -RemoveParameterType (it works under 6.0.0 only). The module instead calls private
        # Register-WslScheduledTask / Set-WslScheduledTask wrapper functions (plain, untyped
        # PowerShell functions - see src/WslAutomation/Private) so those can be mocked directly,
        # consistently, under both Pester versions. The real CDXML cmdlets are still mocked here
        # too, purely as a defensive backstop so this test file can never reach the real Task
        # Scheduler no matter what the implementation calls.
        Mock -ModuleName WslAutomation Register-WslScheduledTask { }
        Mock -ModuleName WslAutomation Set-WslScheduledTask { }
        Mock -ModuleName WslAutomation Register-ScheduledTask { }
        Mock -ModuleName WslAutomation Set-ScheduledTask { }
        Mock -ModuleName WslAutomation Unregister-ScheduledTask { }
        Mock -ModuleName WslAutomation Rename-Item { }
    }

    Context 'when neither scheduled task already exists' {

        BeforeEach {
            Mock -ModuleName WslAutomation Get-ScheduledTask { $null }
        }

        It 'creates the backup task with an action whose arguments contain -NoPause and a quoted BackupDir' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            $backupAction = $script:capturedActions | Where-Object { $_.Argument -match 'wsl-ubuntu-backup\.ps1' }

            $backupAction | Should -Not -BeNullOrEmpty
            $backupAction.Argument | Should -Match '-NoPause'
            $backupAction.Argument | Should -Match ([regex]::Escape('"' + $script:backupDir + '"'))
        }

        It 'creates the keeper task with an action that references ensure-claude-session.ps1 and threads DistroName' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -DistroName 'Debian' -Confirm:$false

            $keeperAction = $script:capturedActions | Where-Object { $_.Argument -match 'ensure-claude-session\.ps1' }

            $keeperAction | Should -Not -BeNullOrEmpty
            $keeperAction.Argument | Should -Match '-DistroName Debian'
        }

        It 'creates exactly one daily trigger for the backup task and no logon trigger' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            Should -Invoke -ModuleName WslAutomation New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter {
                $Daily -eq $true
            }
            Should -Invoke -ModuleName WslAutomation New-ScheduledTaskTrigger -Times 0 -Exactly -ParameterFilter {
                $AtLogOn -eq $true
            }
        }

        It 'registers the backup task via Register-WslScheduledTask with the backup action and daily trigger' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            # ParameterFilter checks the actual Action.Argument and Trigger passed to the real
            # registration call, not just $script:capturedActions/$script:capturedTriggers (the
            # factory mocks' own captures) - an implementation that swapped the backup and
            # keeper actions, or registered the backup task with the wrong trigger, would fail
            # this even though it might still satisfy the factory-capture-only assertions above.
            Should -Invoke -ModuleName WslAutomation Register-WslScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'WSL Ubuntu Daily Backup' -and
                $Action.Argument -match 'wsl-ubuntu-backup\.ps1' -and
                $Action.Argument -match '-NoPause' -and
                $Trigger.IsDaily -eq $true
            }
        }

        It 'registers the keeper task via Register-WslScheduledTask with the keeper action and a once/repeating trigger' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            Should -Invoke -ModuleName WslAutomation Register-WslScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'Claude Code Session Keeper' -and
                $Action.Argument -match 'ensure-claude-session\.ps1' -and
                $Trigger.IsOnce -eq $true
            }
        }

        It 'configures the keeper task repetition interval from KeeperIntervalMinutes' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -KeeperIntervalMinutes 5

            $keeperTrigger = $script:capturedTriggers | Where-Object { $_.IsOnce }

            $keeperTrigger | Should -Not -BeNullOrEmpty
            $keeperTrigger.Repetition | Should -Not -BeNullOrEmpty
            $keeperTrigger.Repetition.Interval | Should -Be 'PT5M'
        }

        It 'registers the backup task without -WakeToRun by default (no scheduled wake on Modern Standby)' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            # New-ScheduledTaskSettingsSet is called for both tasks; neither may request WakeToRun
            # by default. -WakeToRun is a switch, so it binds as $true only when actually passed.
            Should -Invoke -ModuleName WslAutomation New-ScheduledTaskSettingsSet -Times 0 -Exactly -ParameterFilter {
                $WakeToRun -eq $true
            }
        }

        It 'registers the backup task with -WakeToRun when -WakeBackupToRun is set' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -WakeBackupToRun

            Should -Invoke -ModuleName WslAutomation New-ScheduledTaskSettingsSet -Times 1 -Exactly -ParameterFilter {
                $WakeToRun -eq $true
            }
        }

        It 'sanitizes a trailing backslash in BackupDir so the composed action arguments stay well-formed' {
            $backupDirWithTrailingSlash = $script:backupDir + '\'

            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $backupDirWithTrailingSlash `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            $backupAction = $script:capturedActions | Where-Object { $_.Argument -match 'wsl-ubuntu-backup\.ps1' }

            # A raw trailing backslash before the closing quote (...backups\") would escape the
            # quote under native command-line parsing and swallow every argument after it,
            # including -NoPause. Trimmed, the argument must end the BackupDir value cleanly.
            $backupAction.Argument | Should -Match ([regex]::Escape('-BackupDir "' + $script:backupDir + '"'))
            $backupAction.Argument | Should -Not -Match '\\"'
            $backupAction.Argument | Should -Match '-NoPause'
        }
    }

    Context 'when the backup task already exists' {

        BeforeEach {
            $script:existingBackupTask = [pscustomobject]@{
                TaskName  = 'WSL Ubuntu Daily Backup'
                Settings  = [pscustomobject]@{ ExistingSettings = $true }
                Principal = [pscustomobject]@{ ExistingPrincipal = $true }
            }

            Mock -ModuleName WslAutomation Get-ScheduledTask {
                if ($TaskName -eq 'WSL Ubuntu Daily Backup') {
                    return $script:existingBackupTask
                }
                return $null
            }
        }

        It 'updates it via Set-WslScheduledTask, preserving the existing Settings and Principal' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            Should -Invoke -ModuleName WslAutomation Set-WslScheduledTask -Times 1 -Exactly -ParameterFilter {
                $Settings -eq $script:existingBackupTask.Settings -and $Principal -eq $script:existingBackupTask.Principal
            }
        }

        It 'does not create a second backup task via Register-WslScheduledTask' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            Should -Invoke -ModuleName WslAutomation Register-WslScheduledTask -Times 0 -Exactly -ParameterFilter {
                $TaskName -eq 'WSL Ubuntu Daily Backup'
            }
        }

        It 'still sets exactly one daily trigger, dropping any prior logon trigger' {
            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false

            Should -Invoke -ModuleName WslAutomation Set-WslScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'WSL Ubuntu Daily Backup' -and
                $Trigger.Count -eq 1 -and $Trigger[0].IsDaily -eq $true
            }
        }
    }

    Context 'legacy script archiving' {

        BeforeEach {
            Mock -ModuleName WslAutomation Get-ScheduledTask { $null }
        }

        It 'renames a legacy script to a .superseded-<yyyyMMdd> name when it exists' {
            $legacyPath = Join-Path $TestDrive 'old-backup.ps1'
            Set-Content -Path $legacyPath -Value '# legacy script' -Encoding utf8
            $todaySuffix = (Get-Date).ToString('yyyyMMdd')

            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -LegacyScriptsToArchive @($legacyPath)

            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 1 -Exactly -ParameterFilter {
                ($Path -eq $legacyPath -or $LiteralPath -eq $legacyPath) -and
                ($NewName -match [regex]::Escape("superseded-$todaySuffix"))
            }
        }

        It 'does not attempt to rename a legacy path that does not exist' {
            $missingPath = Join-Path $TestDrive 'does-not-exist.ps1'

            {
                Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                    -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -LegacyScriptsToArchive @($missingPath)
            } | Should -Not -Throw

            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 0 -Exactly
        }

        It 'skips and warns instead of renaming when the archived target name already exists' {
            $legacyPath = Join-Path $TestDrive 'already-archived.ps1'
            Set-Content -Path $legacyPath -Value '# legacy script' -Encoding utf8
            $todaySuffix = (Get-Date).ToString('yyyyMMdd')
            $existingTargetPath = "$legacyPath.superseded-$todaySuffix"
            Set-Content -Path $existingTargetPath -Value '# already archived earlier today' -Encoding utf8

            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -LegacyScriptsToArchive @($legacyPath) -WarningVariable warnings

            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 0 -Exactly -ParameterFilter {
                ($Path -eq $legacyPath -or $LiteralPath -eq $legacyPath)
            }
            $warnings | Should -Not -BeNullOrEmpty
        }

        It 'expands a single comma-joined element of two rooted paths and renames both (pwsh -File comma-flattening workaround)' {
            # Simulates the proven -File argument-binding footgun: two array elements arriving
            # from another shell (e.g. Windows PowerShell 5.1 calling `pwsh -File ...`) flattened
            # into one literal comma-joined string, rather than -LegacyScriptsToArchive actually
            # receiving a two-element array.
            $legacyPathOne = Join-Path $TestDrive 'legacy-one.ps1'
            $legacyPathTwo = Join-Path $TestDrive 'legacy-two.ps1'
            Set-Content -Path $legacyPathOne -Value '# legacy script one' -Encoding utf8
            Set-Content -Path $legacyPathTwo -Value '# legacy script two' -Encoding utf8
            $todaySuffix = (Get-Date).ToString('yyyyMMdd')
            $flattenedElement = "$legacyPathOne,$legacyPathTwo"

            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -LegacyScriptsToArchive @($flattenedElement)

            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 1 -Exactly -ParameterFilter {
                ($Path -eq $legacyPathOne -or $LiteralPath -eq $legacyPathOne) -and
                ($NewName -match [regex]::Escape("superseded-$todaySuffix"))
            }
            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 1 -Exactly -ParameterFilter {
                ($Path -eq $legacyPathTwo -or $LiteralPath -eq $legacyPathTwo) -and
                ($NewName -match [regex]::Escape("superseded-$todaySuffix"))
            }
        }

        It 'warns when a legacy path does not exist and no .superseded-* sibling is present' {
            $missingPath = Join-Path $TestDrive 'no-sibling-yet.ps1'

            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -LegacyScriptsToArchive @($missingPath) -WarningVariable warnings

            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 0 -Exactly
            $warnings | Where-Object { $_ -match 'Legacy script not found' } | Should -Not -BeNullOrEmpty
        }

        It 'stays silent when a legacy path does not exist but a .superseded-* sibling from a previous run is present' {
            # An idempotent re-run: a prior invocation already renamed this legacy script out of
            # the way, so it no longer exists at its original path. That's expected, not an error.
            $missingPath = Join-Path $TestDrive 'archived-on-prior-run.ps1'
            $todaySuffix = (Get-Date).ToString('yyyyMMdd')
            $priorSupersededPath = "$missingPath.superseded-$todaySuffix"
            Set-Content -Path $priorSupersededPath -Value '# archived on a prior run' -Encoding utf8

            Set-WslAutomationScheduledTasks -ScriptsDir $script:scriptsDir -BackupDir $script:backupDir `
                -PwshPath 'C:\fake\pwsh.exe' -Confirm:$false -LegacyScriptsToArchive @($missingPath) -WarningVariable warnings

            Should -Invoke -ModuleName WslAutomation Rename-Item -Times 0 -Exactly
            $warnings | Where-Object { $_ -match 'Legacy script not found' } | Should -BeNullOrEmpty
        }
    }
}
