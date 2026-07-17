@{
    RootModule        = 'WslAutomation.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '52f5cbb9-1545-4433-9d48-fc843b03ded4'
    Author            = 'Adam S. Daniel'
    CompanyName       = 'Unknown'
    Copyright         = '(c) 2026 Adam S. Daniel. All rights reserved.'
    Description       = 'WSL backup automation, Claude Code session keeper, and scheduled task registration.'
    PowerShellVersion = '7.6'

    FunctionsToExport = @(
        'New-WslBackupLock',
        'Test-WslBackupLock',
        'Remove-WslBackupLock',
        'Get-WslDistroState',
        'Invoke-WslBackup',
        'Test-ClaudeSession',
        'Start-ClaudeSession',
        'Invoke-ClaudeSessionKeeper',
        'Set-WslAutomationScheduledTasks'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('WSL', 'Backup', 'ClaudeCode', 'ScheduledTask')
            LicenseUri = ''
            ProjectUri = ''
        }
    }
}
