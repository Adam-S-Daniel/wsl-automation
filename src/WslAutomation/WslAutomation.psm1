#requires -Version 7.6
Set-StrictMode -Version Latest

$moduleRoot = $PSScriptRoot

$privateFiles = @(Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$publicFiles = @(Get-ChildItem -Path (Join-Path -Path $moduleRoot -ChildPath 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in $privateFiles) {
    . $file.FullName
}

foreach ($file in $publicFiles) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'New-WslBackupLock',
    'Test-WslBackupLock',
    'Remove-WslBackupLock',
    'Get-WslDistroState',
    'Invoke-WslBackup',
    'Test-ClaudeSession',
    'Start-ClaudeSession',
    'Invoke-ClaudeSessionKeeper',
    'Set-WslAutomationScheduledTasks',
    'Update-CcstatuslineConfig',
    'Update-WslAutomationRepo'
)
