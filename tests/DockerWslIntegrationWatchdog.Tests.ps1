#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

    $script:subjectSuffix = ', via "Docker WSL Integration Watchdog" https://github.com/Adam-S-Daniel/wsl-automation/blob/main/scripts/ensure-docker-wsl-integration.ps1'

    function Invoke-TestWatchdog {
        param([hashtable]$Extra = @{})
        $parameters = @{
            DistroName        = 'Ubuntu'
            SettingsStorePath = $script:settingsPath
            LogFile           = $script:logFile
            StatePath         = $script:statePath
        }
        foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
        Invoke-DockerWslIntegrationWatchdog @parameters
    }

    # Send-WslAutomationAlert and Show-WslAutomationToast are private seams: call them in module scope.
    function Invoke-TestSendAlert {
        param([string]$Subject, [string]$Body, [string]$LogFile, [string]$WorkflowRepo, [string]$WorkflowFile, [string]$ToastMessage)
        $params = @{ Subject = $Subject; Body = $Body; LogFile = $LogFile }
        if ($ToastMessage) { $params['ToastMessage'] = $ToastMessage }
        if ($WorkflowRepo) { $params['WorkflowRepo'] = $WorkflowRepo }
        if ($WorkflowFile) { $params['WorkflowFile'] = $WorkflowFile }
        InModuleScope WslAutomation -Parameters @{ Params = $params } {
            param($Params)
            Send-WslAutomationAlert @Params
        }
    }

    function Invoke-TestToast {
        param([string]$Title, [string]$Message)
        InModuleScope WslAutomation -Parameters @{ ToastTitle = $Title; ToastMessage = $Message } {
            param($ToastTitle, $ToastMessage)
            Show-WslAutomationToast -Title $ToastTitle -Message $ToastMessage
        }
    }}

Describe 'Invoke-DockerWslIntegrationWatchdog' {

    BeforeEach {
        $script:settingsPath = Join-Path $TestDrive 'settings-store.json'
        $script:logFile = Join-Path $TestDrive 'watchdog.log'
        $script:statePath = Join-Path $TestDrive 'watchdog-state.json'
        Remove-Item -LiteralPath $script:settingsPath, $script:logFile, $script:statePath -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":["Ubuntu","Debian"]}'

        # Scripted fakes: a sequence is consumed one entry per call and its last entry repeats.
        $script:engineSequence = @('running')
        $script:engineCalls = 0
        $script:statusExitCode = 0
        $script:probeSequence = @(0)
        $script:probeCalls = 0
        $script:distroState = 'Running'
        $script:alertResult = [pscustomobject]@{ Toast = $true; Email = $true }

        # Safety seams: nothing here may reach a real wsl.exe, docker.exe, gh.exe or toast.
        Mock -ModuleName WslAutomation Invoke-WslExe {
            $index = [Math]::Min($script:probeCalls, $script:probeSequence.Count - 1)
            $script:probeCalls++
            [pscustomobject]@{ ExitCode = [int]$script:probeSequence[$index]; Output = @() }
        }
        Mock -ModuleName WslAutomation Invoke-DockerDesktopCli {
            if ($Arguments -contains 'restart') {
                return [pscustomobject]@{ ExitCode = 0; Output = @() }
            }
            $index = [Math]::Min($script:engineCalls, $script:engineSequence.Count - 1)
            $script:engineCalls++
            [pscustomobject]@{ ExitCode = $script:statusExitCode; Output = @("{`"Mode`":`"linux`",`"Status`":`"$($script:engineSequence[$index])`"}") }
        }
        Mock -ModuleName WslAutomation Invoke-GhExe { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock -ModuleName WslAutomation Invoke-WindowsPowerShellExe { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock -ModuleName WslAutomation Show-WslAutomationToast { $true }
        Mock -ModuleName WslAutomation Send-WslAutomationAlert { $script:alertResult }
        Mock -ModuleName WslAutomation Get-WslDistroState { $script:distroState }
        # A fixed clock: the machine woke three hours before "now".
        Mock -ModuleName WslAutomation Get-Date { [datetime]::new(2026, 11, 1, 12, 0, 0) }
        Mock -ModuleName WslAutomation Get-LastWakeTime { [datetime]::new(2026, 11, 1, 9, 0, 0) }
        Mock -ModuleName WslAutomation Start-Sleep { }
    }

    Context 'wake guard' {

        It 'defers to DeferredRecentWake before any CLI, distro or settings call when the machine woke less than 10 minutes ago' {
            Mock -ModuleName WslAutomation Get-LastWakeTime { [datetime]::new(2026, 11, 1, 11, 55, 0) }

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'DeferredRecentWake'
            $result.Restarts | Should -Be 0
            $result.Alerted | Should -BeFalse
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Get-WslDistroState -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
        }

        It 'proceeds once exactly 10 minutes have passed' {
            Mock -ModuleName WslAutomation Get-LastWakeTime { [datetime]::new(2026, 11, 1, 11, 50, 0) }

            (Invoke-TestWatchdog).Status | Should -Be 'Healthy'
        }

        It 'honors -MinMinutesSinceWake' {
            Mock -ModuleName WslAutomation Get-LastWakeTime { [datetime]::new(2026, 11, 1, 11, 40, 0) }

            (Invoke-TestWatchdog -Extra @{ MinMinutesSinceWake = 30 }).Status | Should -Be 'DeferredRecentWake'
        }
    }

    Context 'Docker Desktop is not running' {

        It 'returns DockerNotRunning, with no alert and no restart, when the status command fails' {
            $script:statusExitCode = 1

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'DockerNotRunning'
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
            Should -Invoke -ModuleName WslAutomation Get-WslDistroState -Times 0 -Exactly
        }

        It 'returns DockerNotRunning when the status is anything but running' {
            $script:engineSequence = @('stopped')

            (Invoke-TestWatchdog).Status | Should -Be 'DockerNotRunning'
        }

        It 'returns DockerNotRunning when the status output is not JSON' {
            Mock -ModuleName WslAutomation Invoke-DockerDesktopCli { [pscustomobject]@{ ExitCode = 0; Output = @('not json') } }

            (Invoke-TestWatchdog).Status | Should -Be 'DockerNotRunning'
        }

        It 'asks docker for the status as JSON' {
            Invoke-TestWatchdog | Out-Null

            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join '|') -eq 'desktop|status|--format|json'
            }
        }
    }

    Context 'Docker settings store' {

        It 'returns SettingsUnreadable, logging only, when the file is missing' {
            Remove-Item -LiteralPath $script:settingsPath

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'SettingsUnreadable'
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Get-WslDistroState -Times 0 -Exactly
            Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'settings store'
        }

        It 'returns SettingsUnreadable when the file is not valid JSON' {
            Set-Content -LiteralPath $script:settingsPath -Value '{ this is not json'

            (Invoke-TestWatchdog).Status | Should -Be 'SettingsUnreadable'
        }

        It 'returns IntegrationNotConfigured, alerts and never restarts when the distro is not in IntegratedWslDistros' {
            Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":["Debian"]}'

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'IntegrationNotConfigured'
            $result.Alerted | Should -BeTrue
            $result.Restarts | Should -Be 0
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
            Should -Invoke -ModuleName WslAutomation Get-WslDistroState -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 1 -Exactly -ParameterFilter {
                $Subject -eq ('Docker Desktop WSL integration no longer includes Ubuntu' + $script:subjectSuffix) -and
                $ToastMessage -eq 'Docker Desktop WSL integration no longer includes Ubuntu' -and
                $Body -match 'Settings > Resources > WSL integration' -and $Body -match 'Apply & restart' -and $Body -match 'Ubuntu'
            }
        }

        It 'treats a missing IntegratedWslDistros property as an empty list' {
            Set-Content -LiteralPath $script:settingsPath -Value '{"OtherSetting":true}'

            (Invoke-TestWatchdog).Status | Should -Be 'IntegrationNotConfigured'
        }

        It 'matches the distro name case-insensitively' {
            Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":["ubuntu"]}'

            (Invoke-TestWatchdog).Status | Should -Be 'Healthy'
        }

        It 'reads the settings store named by -SettingsStorePath' {
            $otherPath = Join-Path $TestDrive 'other-settings.json'
            Set-Content -LiteralPath $otherPath -Value '{"IntegratedWslDistros":["Debian"]}'

            (Invoke-TestWatchdog -Extra @{ SettingsStorePath = $otherPath }).Status | Should -Be 'IntegrationNotConfigured'
        }
    }

    Context 'distro state' {

        It 'returns DistroNotRunning and never probes (or boots) a stopped distro' {
            $script:distroState = 'Stopped'

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'DistroNotRunning'
            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
        }

        It 'returns DistroNotRunning for a distro wsl.exe does not list' {
            $script:distroState = 'NotFound'

            (Invoke-TestWatchdog).Status | Should -Be 'DistroNotRunning'
            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 0 -Exactly
        }

        It 'stops with DistroNotRunning, not a probe, if a restart took the distro down' {
            $script:probeSequence = @(1)
            $script:distroStates = [System.Collections.Generic.Queue[string]]::new([string[]]@('Running', 'Stopped'))
            Mock -ModuleName WslAutomation Get-WslDistroState {
                if ($script:distroStates.Count -gt 0) { $script:distroStates.Dequeue() } else { 'Stopped' }
            }

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'DistroNotRunning'
            $result.Restarts | Should -Be 1
            $script:probeCalls | Should -Be 1
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
        }
    }

    Context 'healthy integration' {

        It 'returns Healthy after one probe with the documented command, restarting and alerting nothing' {
            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'Healthy'
            $result.Restarts | Should -Be 0
            $result.Alerted | Should -BeFalse
            Should -Invoke -ModuleName WslAutomation Invoke-WslExe -Times 1 -Exactly -ParameterFilter {
                $Arguments.Count -eq 6 -and
                ($Arguments[0..3] -join '|') -eq '--distribution|Ubuntu|--exec|sh' -and
                $Arguments[4] -eq '-c' -and
                $Arguments[5] -eq 'test -S /mnt/wsl/docker-desktop/shared-sockets/host-services/backend.sock && timeout 20 docker version --format "{{.Server.Version}}" >/dev/null 2>&1'
            }
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
        }

        It 'removes the alert state' {
            Set-Content -LiteralPath $script:statePath -Value '{"lastAlert":"Unrecovered","at":"2026-11-01T00:00:00Z"}'

            Invoke-TestWatchdog | Out-Null

            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }
    }

    Context 'repair by restarting Docker Desktop' {

        It 'recovers on the first restart' {
            $script:probeSequence = @(1, 0)
            Set-Content -LiteralPath $script:statePath -Value '{"lastAlert":"Unrecovered","at":"2026-11-01T00:00:00Z"}'

            $result = Invoke-TestWatchdog

            $result.Status | Should -Be 'Recovered'
            $result.Restarts | Should -Be 1
            $result.Alerted | Should -BeFalse
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join '|') -eq 'desktop|restart'
            }
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }

        It 'recovers on the second restart' {
            # Initial probe fails; attempt 1 probes three times (0, 10 and 20 s) and fails; attempt 2 succeeds.
            $script:probeSequence = @(1, 1, 1, 1, 0)

            $result = Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 20; PollSeconds = 10 }

            $result.Status | Should -Be 'Recovered'
            $result.Restarts | Should -Be 2
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 2 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
        }

        It 'returns Unrecovered after exactly MaxRestarts restarts and alerts once' {
            $script:probeSequence = @(1)

            $result = Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 20; PollSeconds = 10 }

            $result.Status | Should -Be 'Unrecovered'
            $result.Restarts | Should -Be 2
            $result.Alerted | Should -BeTrue
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 2 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 1 -Exactly -ParameterFilter {
                $Subject -eq ('Docker Desktop WSL integration with Ubuntu is broken and a restart did not fix it' + $script:subjectSuffix) -and
                $ToastMessage -eq 'Docker Desktop WSL integration with Ubuntu is broken and a restart did not fix it' -and
                $Body -match 'Ubuntu' -and $Body -match 'wsl --shutdown' -and $Body -match 'Quit Docker Desktop|quit Docker Desktop'
            }
        }

        It 'honors -MaxRestarts' {
            $script:probeSequence = @(1)

            $result = Invoke-TestWatchdog -Extra @{ MaxRestarts = 3; IntegrationWaitSeconds = 10; PollSeconds = 10 }

            $result.Restarts | Should -Be 3
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 3 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
        }

        It 'counts the engine wait in accumulated poll seconds and moves on when the engine never comes back' {
            # The first status call (the "is Docker running" gate) says running; every later one says starting.
            $script:engineSequence = @('running', 'starting')
            $script:probeSequence = @(1)

            $result = Invoke-TestWatchdog -Extra @{ EngineWaitSeconds = 30; PollSeconds = 10 }

            $result.Status | Should -Be 'Unrecovered'
            $result.Restarts | Should -Be 2
            # Gate + 2 attempts x (30 s / 10 s) polls; the integration probe ran only once (before the first restart).
            $script:engineCalls | Should -Be 7
            $script:probeCalls | Should -Be 1
            Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 6 -Exactly -ParameterFilter { $Seconds -eq 10 }
        }

        It 'counts the integration wait in accumulated poll seconds' {
            $script:probeSequence = @(1)

            Invoke-TestWatchdog -Extra @{ MaxRestarts = 1; IntegrationWaitSeconds = 30; PollSeconds = 10 } | Out-Null

            # Initial probe + (0, 10, 20 and 30 s) probes after the restart.
            $script:probeCalls | Should -Be 5
            # One engine poll sleep + three integration sleeps.
            Should -Invoke -ModuleName WslAutomation Start-Sleep -Times 4 -Exactly
        }
    }

    Context 'DryRun' {

        It 'never restarts, alerts or writes state for a broken integration, and says what it would do' {
            $script:probeSequence = @(1)

            $result = Invoke-TestWatchdog -Extra @{ DryRun = $true }

            $result.Status | Should -Be 'Unrecovered'
            $result.Restarts | Should -Be 0
            $result.Alerted | Should -BeFalse
            Should -Invoke -ModuleName WslAutomation Invoke-DockerDesktopCli -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'restart' }
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Match 'would restart Docker Desktop'
            $log | Should -Match 'would alert'
        }

        It 'never alerts for a missing integration either' {
            Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":[]}'

            $result = Invoke-TestWatchdog -Extra @{ DryRun = $true }

            $result.Status | Should -Be 'IntegrationNotConfigured'
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 0 -Exactly
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
            Get-Content -LiteralPath $script:logFile -Raw | Should -Match 'would alert'
        }
    }

    Context 'alert deduplication' {

        It 'writes the last alerted status to the state file as JSON' {
            $script:probeSequence = @(1)

            Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 } | Out-Null

            $stateText = Get-Content -LiteralPath $script:statePath -Raw
            ($stateText | ConvertFrom-Json).lastAlert | Should -Be 'Unrecovered'
            $stateText | Should -Match '"at":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
            Test-Path -LiteralPath "$($script:statePath).tmp" | Should -BeFalse
        }

        It 'sends nothing the second time the same status occurs' {
            $script:probeSequence = @(1)

            $first = Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 }
            $second = Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 }

            $first.Alerted | Should -BeTrue
            $second.Status | Should -Be 'Unrecovered'
            $second.Alerted | Should -BeFalse
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 1 -Exactly
        }

        It 'dedupes IntegrationNotConfigured too, but alerts again when the status changes' {
            Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":[]}'
            Invoke-TestWatchdog | Out-Null
            Invoke-TestWatchdog | Out-Null
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 1 -Exactly

            Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":["Ubuntu"]}'
            $script:probeSequence = @(1)
            (Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 }).Alerted | Should -BeTrue

            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 2 -Exactly
        }

        It 'alerts again after a Healthy run clears the state' {
            $script:probeSequence = @(1)
            Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 } | Out-Null
            Test-Path -LiteralPath $script:statePath | Should -BeTrue

            $script:probeCalls = 0
            $script:probeSequence = @(0)
            (Invoke-TestWatchdog).Status | Should -Be 'Healthy'
            Test-Path -LiteralPath $script:statePath | Should -BeFalse

            $script:probeCalls = 0
            $script:probeSequence = @(1)
            (Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 }).Alerted | Should -BeTrue
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 2 -Exactly
        }

        It 'treats a corrupt state file as no state and replaces it' {
            Set-Content -LiteralPath $script:statePath -Value '{ definitely not json'
            $script:probeSequence = @(1)

            $result = Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 }

            $result.Alerted | Should -BeTrue
            Should -Invoke -ModuleName WslAutomation Send-WslAutomationAlert -Times 1 -Exactly
            (Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json).lastAlert | Should -Be 'Unrecovered'
        }

        It 'does not record the alert, so the next run retries, when no channel delivered it' {
            $script:alertResult = [pscustomobject]@{ Toast = $false; Email = $false }
            $script:probeSequence = @(1)

            $result = Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 }

            $result.Status | Should -Be 'Unrecovered'
            $result.Alerted | Should -BeFalse
            Test-Path -LiteralPath $script:statePath | Should -BeFalse
        }
    }

    Context 'log hygiene' {

        It 'never logs a user name, host name or the settings path' {
            $script:probeSequence = @(1)

            Invoke-TestWatchdog -Extra @{ IntegrationWaitSeconds = 10 } | Out-Null

            $log = Get-Content -LiteralPath $script:logFile -Raw
            $log | Should -Not -Match ([regex]::Escape($script:settingsPath))
            $log | Should -Not -Match ([regex]::Escape($script:statePath))
            foreach ($identity in @($env:USERNAME, $env:COMPUTERNAME)) {
                if ($identity) { $log | Should -Not -Match ([regex]::Escape($identity)) }
            }
        }
    }
}

Describe 'Send-WslAutomationAlert' {

    BeforeEach {
        $script:logFile = Join-Path $TestDrive 'alert.log'
        Remove-Item -LiteralPath $script:logFile -ErrorAction SilentlyContinue
        Mock -ModuleName WslAutomation Show-WslAutomationToast { $true }
        Mock -ModuleName WslAutomation Invoke-GhExe { [pscustomobject]@{ ExitCode = 0; Output = @('dispatched') } }
    }

    It 'shows the toast with the subject and dispatches the workflow with the exact argument array' {
        $result = Invoke-TestSendAlert -Subject 'A subject' -Body 'A body' -LogFile $script:logFile

        $result.Toast | Should -BeTrue
        $result.Email | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Show-WslAutomationToast -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Docker WSL integration' -and $Message -eq 'A subject'
        }
        Should -Invoke -ModuleName WslAutomation Invoke-GhExe -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 9 -and
            ($Arguments -join '|') -eq 'workflow|run|send-self-alert.yml|--repo|Adam-S-Daniel/fastmail-actions|-f|subject=A subject|-f|body=A body'
        }
    }

    It 'shows -ToastMessage in the toast while the email subject stays -Subject' {
        Invoke-TestSendAlert -Subject 'Email subject, via link' -ToastMessage 'Plain toast text' -Body 'b' -LogFile $script:logFile | Out-Null

        Should -Invoke -ModuleName WslAutomation Show-WslAutomationToast -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'Plain toast text'
        }
        Should -Invoke -ModuleName WslAutomation Invoke-GhExe -Times 1 -Exactly -ParameterFilter {
            $Arguments[6] -eq 'subject=Email subject, via link'
        }
    }

    It 'honors -WorkflowRepo and -WorkflowFile' {
        Invoke-TestSendAlert -Subject 's' -Body 'b' -LogFile $script:logFile -WorkflowRepo 'example/repo' -WorkflowFile 'other.yml' | Out-Null

        Should -Invoke -ModuleName WslAutomation Invoke-GhExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq 'workflow|run|other.yml|--repo|example/repo|-f|subject=s|-f|body=b'
        }
    }

    It 'logs one outcome line per channel' {
        Invoke-TestSendAlert -Subject 's' -Body 'b' -LogFile $script:logFile | Out-Null

        $lines = @(Get-Content -LiteralPath $script:logFile)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match 'alert toast: ok$'
        $lines[1] | Should -Match 'alert email: dispatched$'
    }

    It 'logs failures with the exit code but never the gh output' {
        Mock -ModuleName WslAutomation Show-WslAutomationToast { $false }
        Mock -ModuleName WslAutomation Invoke-GhExe { [pscustomobject]@{ ExitCode = 4; Output = @('HTTP 403: secret-response-body') } }

        $result = Invoke-TestSendAlert -Subject 's' -Body 'b' -LogFile $script:logFile

        $result.Toast | Should -BeFalse
        $result.Email | Should -BeFalse
        $log = Get-Content -LiteralPath $script:logFile -Raw
        $log | Should -Match 'alert toast: failed'
        $log | Should -Match 'alert email: failed \(exit 4\)'
        $log | Should -Not -Match 'secret-response-body'
    }

    It 'still sends the email when the toast fails, and the toast when the email fails' {
        Mock -ModuleName WslAutomation Show-WslAutomationToast { $false }
        $emailOnly = Invoke-TestSendAlert -Subject 's' -Body 'b' -LogFile $script:logFile
        $emailOnly.Toast | Should -BeFalse
        $emailOnly.Email | Should -BeTrue

        Mock -ModuleName WslAutomation Show-WslAutomationToast { $true }
        Mock -ModuleName WslAutomation Invoke-GhExe { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        $toastOnly = Invoke-TestSendAlert -Subject 's' -Body 'b' -LogFile $script:logFile
        $toastOnly.Toast | Should -BeTrue
        $toastOnly.Email | Should -BeFalse
    }

    It 'never throws when both channels fail, even by throwing' {
        Mock -ModuleName WslAutomation Show-WslAutomationToast { throw 'toast exploded' }
        Mock -ModuleName WslAutomation Invoke-GhExe { throw 'gh exploded' }

        $script:thrownResult = $null
        { $script:thrownResult = Invoke-TestSendAlert -Subject 's' -Body 'b' -LogFile $script:logFile } | Should -Not -Throw
        $result = $script:thrownResult

        $result.Toast | Should -BeFalse
        $result.Email | Should -BeFalse
        Get-Content -LiteralPath $script:logFile -Raw | Should -Not -Match 'exploded'
    }
}

Describe 'Invoke-DockerWslIntegrationWatchdog subject through the real alert function' {

    BeforeEach {
        $script:settingsPath = Join-Path $TestDrive 'settings-store.json'
        $script:logFile = Join-Path $TestDrive 'watchdog.log'
        $script:statePath = Join-Path $TestDrive 'watchdog-state.json'
        Set-Content -LiteralPath $script:settingsPath -Value '{"IntegratedWslDistros":["Debian"]}'

        Mock -ModuleName WslAutomation Invoke-DockerDesktopCli { [pscustomobject]@{ ExitCode = 0; Output = @('{"Status":"running"}') } }
        Mock -ModuleName WslAutomation Invoke-GhExe { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock -ModuleName WslAutomation Show-WslAutomationToast { $true }
        Mock -ModuleName WslAutomation Get-Date { [datetime]::new(2026, 11, 1, 12, 0, 0) }
        Mock -ModuleName WslAutomation Get-LastWakeTime { [datetime]::new(2026, 11, 1, 9, 0, 0) }
    }

    It 'ends every email subject with the watchdog suffix and keeps the body to fixed text plus the distro name' {
        $result = Invoke-DockerWslIntegrationWatchdog -DistroName 'Debian2' -SettingsStorePath $script:settingsPath -LogFile $script:logFile -StatePath $script:statePath

        $result.Status | Should -Be 'IntegrationNotConfigured'
        Should -Invoke -ModuleName WslAutomation Invoke-GhExe -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 9 -and
            ($Arguments[0..6] -join '|') -eq 'workflow|run|send-self-alert.yml|--repo|Adam-S-Daniel/fastmail-actions|-f|subject=Docker Desktop WSL integration no longer includes Debian2, via "Docker WSL Integration Watchdog" https://github.com/Adam-S-Daniel/wsl-automation/blob/main/scripts/ensure-docker-wsl-integration.ps1' -and
            $Arguments[7] -eq '-f' -and
            $Arguments[8].StartsWith('body=') -and $Arguments[8] -match 'Debian2'
        }
        Should -Invoke -ModuleName WslAutomation Show-WslAutomationToast -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Docker WSL integration' -and $Message -eq 'Docker Desktop WSL integration no longer includes Debian2'
        }
        $log = Get-Content -LiteralPath $script:logFile -Raw
        $log | Should -Match 'alert toast: ok'
        $log | Should -Match 'alert email: dispatched'
    }
}

Describe 'Show-WslAutomationToast' {

    BeforeEach {
        $script:titleVariable = 'WSL_AUTOMATION_TOAST_TITLE'
        $script:messageVariable = 'WSL_AUTOMATION_TOAST_MESSAGE'
        $script:savedTitle = [Environment]::GetEnvironmentVariable($script:titleVariable)
        $script:savedMessage = [Environment]::GetEnvironmentVariable($script:messageVariable)
        $script:seen = $null
        $script:childExitCode = 0
        Mock -ModuleName WslAutomation Invoke-WindowsPowerShellExe {
            $script:seen = [pscustomobject]@{
                Title     = [Environment]::GetEnvironmentVariable('WSL_AUTOMATION_TOAST_TITLE')
                Message   = [Environment]::GetEnvironmentVariable('WSL_AUTOMATION_TOAST_MESSAGE')
                Arguments = $Arguments
            }
            [pscustomobject]@{ ExitCode = $script:childExitCode; Output = @() }
        }
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable($script:titleVariable, $script:savedTitle)
        [Environment]::SetEnvironmentVariable($script:messageVariable, $script:savedMessage)
    }

    It 'hands the text to the child only through the two environment variables' {
        $title = 'Title <b>&amp; "quoted" Zq1'
        $message = "Message 'single' `$(Get-Date) Zq2"

        $ok = Invoke-TestToast -Title $title -Message $message

        $ok | Should -BeTrue
        $script:seen.Title | Should -Be $title
        $script:seen.Message | Should -Be $message
        $script:seen.Arguments.Count | Should -Be 4
        ($script:seen.Arguments[0..2] -join ' ') | Should -Be '-NoProfile -NonInteractive -EncodedCommand'
        $script = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:seen.Arguments[3]))
        $script | Should -Not -Match 'Zq1|Zq2|quoted|single'
        $script | Should -Match ([regex]::Escape('$env:WSL_AUTOMATION_TOAST_TITLE'))
        $script | Should -Match ([regex]::Escape('$env:WSL_AUTOMATION_TOAST_MESSAGE'))
    }

    It 'runs a fixed script that escapes the text and shows a ToastGeneric toast as Windows PowerShell' {
        Invoke-TestToast -Title 't' -Message 'm' | Out-Null

        $script = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:seen.Arguments[3]))
        $script | Should -Match ([regex]::Escape('[System.Security.SecurityElement]::Escape($env:WSL_AUTOMATION_TOAST_TITLE)'))
        $script | Should -Match ([regex]::Escape('[System.Security.SecurityElement]::Escape($env:WSL_AUTOMATION_TOAST_MESSAGE)'))
        $script | Should -Match ([regex]::Escape('[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]'))
        $script | Should -Match ([regex]::Escape('[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]'))
        $script | Should -Match 'ToastGeneric'
        ([regex]::Matches($script, '<text>')).Count | Should -Be 2
        $script | Should -Match ([regex]::Escape("CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')"))
    }

    It 'restores previously set environment variables afterward' {
        [Environment]::SetEnvironmentVariable($script:titleVariable, 'previous title')
        [Environment]::SetEnvironmentVariable($script:messageVariable, 'previous message')

        Invoke-TestToast -Title 'new title' -Message 'new message' | Out-Null

        $script:seen.Title | Should -Be 'new title'
        [Environment]::GetEnvironmentVariable($script:titleVariable) | Should -Be 'previous title'
        [Environment]::GetEnvironmentVariable($script:messageVariable) | Should -Be 'previous message'
    }

    It 'removes the environment variables afterward when they were not set before' {
        [Environment]::SetEnvironmentVariable($script:titleVariable, $null)
        [Environment]::SetEnvironmentVariable($script:messageVariable, $null)

        Invoke-TestToast -Title 'a' -Message 'b' | Out-Null

        [Environment]::GetEnvironmentVariable($script:titleVariable) | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable($script:messageVariable) | Should -BeNullOrEmpty
    }

    It 'returns $false for a nonzero child exit code' {
        $script:childExitCode = 1

        Invoke-TestToast -Title 'a' -Message 'b' | Should -BeFalse
    }

    It 'returns $false, restores the variables and does not throw when the seam throws' {
        [Environment]::SetEnvironmentVariable($script:titleVariable, 'kept')
        Mock -ModuleName WslAutomation Invoke-WindowsPowerShellExe { throw 'cannot start' }

        Invoke-TestToast -Title 'a' -Message 'b' | Should -BeFalse
        [Environment]::GetEnvironmentVariable($script:titleVariable) | Should -Be 'kept'
    }
}

Describe 'external program seams when the program is missing' {

    It 'Invoke-DockerDesktopCli returns exit code 127 and no output' {
        Mock -ModuleName WslAutomation Get-Command { $null }

        $result = InModuleScope WslAutomation { Invoke-DockerDesktopCli -Arguments @('desktop', 'status') }

        $result.ExitCode | Should -Be 127
        @($result.Output).Count | Should -Be 0
    }

    It 'Invoke-GhExe returns exit code 127 and no output' {
        Mock -ModuleName WslAutomation Get-Command { $null }

        $result = InModuleScope WslAutomation { Invoke-GhExe -Arguments @('auth', 'status') }

        $result.ExitCode | Should -Be 127
        @($result.Output).Count | Should -Be 0
    }
}
