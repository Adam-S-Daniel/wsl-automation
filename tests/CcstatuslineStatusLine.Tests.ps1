#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force
}

Describe 'Set-CcstatuslineStatusLine' -Skip:(-not $IsWindows) {

    BeforeEach {
        $script:settingsPath = Join-Path $TestDrive 'settings.json'
        $script:cmd = 'C:/tools/ccstatusline.exe'
        $script:utf8 = [System.Text.UTF8Encoding]::new($false)

        # $TestDrive is shared across every It in this Describe; clear the settings file and any
        # backups a prior test left so each test starts from a clean slate.
        Get-ChildItem -LiteralPath $TestDrive -Force |
            Where-Object { $_.Name -eq 'settings.json' -or $_.Name -like '*.bak' } |
            Remove-Item -Force
    }

    It 'creates the file with the statusLine and width and makes no backup when the file is missing' {
        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Updated'
        $result.BackupPath | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.bak').Count | Should -Be 0
        $written = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $written['statusLine']['type'] | Should -Be 'command'
        $written['statusLine']['command'] | Should -Be $script:cmd
        $written['statusLine']['padding'] | Should -Be 0
        $written['statusLine']['refreshInterval'] | Should -Be 20
        $written['env']['CCSTATUSLINE_WIDTH'] | Should -Be '130'
        $bytes = [System.IO.File]::ReadAllBytes($script:settingsPath)
        $bytes[0] | Should -Not -Be 0xEF
        $script:utf8.GetString($bytes) | Should -Match '\r\n$'
    }

    It 'preserves other keys and their order, and backs up the original byte-for-byte' {
        $original = @'
{
  "theme": "dark",
  "permissions": {
    "allow": [
      "Bash(git status)"
    ]
  },
  "env": {
    "OTHER_VAR": "1"
  }
}
'@
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes($original))
        $originalHash = (Get-FileHash -LiteralPath $script:settingsPath).Hash

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Updated'
        $written = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json -AsHashtable
        @($written.Keys) | Should -Be @('theme', 'permissions', 'env', 'statusLine')
        $written['theme'] | Should -Be 'dark'
        @($written['permissions']['allow']) | Should -Be @('Bash(git status)')
        $written['env']['OTHER_VAR'] | Should -Be '1'
        $written['env']['CCSTATUSLINE_WIDTH'] | Should -Be '130'
        $written['statusLine']['command'] | Should -Be $script:cmd

        $backups = @(Get-ChildItem -LiteralPath $TestDrive -Filter '*-ET-settings.json.bak')
        $backups.Count | Should -Be 1
        $backups[0].FullName | Should -Be $result.BackupPath
        (Get-FileHash -LiteralPath $result.BackupPath).Hash | Should -Be $originalHash
    }

    It 'returns AlreadySet and leaves the file bytes unchanged on a second run' {
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes("{`n  `"theme`": `"dark`"`n}`n"))
        Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd | Out-Null
        $hashAfterFirst = (Get-FileHash -LiteralPath $script:settingsPath).Hash

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'AlreadySet'
        (Get-FileHash -LiteralPath $script:settingsPath).Hash | Should -Be $hashAfterFirst
    }

    It 'keeps a UTF-8 BOM, CRLF newlines and the trailing newline of the original' {
        $original = $script:utf8.GetBytes("{`r`n  `"theme`": `"dark`"`r`n}`r`n")
        [System.IO.File]::WriteAllBytes($script:settingsPath, [byte[]](@(0xEF, 0xBB, 0xBF) + $original))

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Updated'
        $bytes = [System.IO.File]::ReadAllBytes($script:settingsPath)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = $script:utf8.GetString($bytes, 3, $bytes.Length - 3)
        $text | Should -Match '\r\n$'
        $text | Should -Not -Match '(?<!\r)\n'
    }

    It 'keeps LF newlines, no BOM and no trailing newline when the original had none' {
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes("{`n  `"theme`": `"dark`"`n}"))

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Updated'
        $bytes = [System.IO.File]::ReadAllBytes($script:settingsPath)
        $bytes[0] | Should -Not -Be 0xEF
        $bytes | Should -Not -Contain 13
        $bytes[-1] | Should -Not -Be 10
        $bytes | Should -Contain 10
    }

    It 'returns Conflict without writing or backing up when a different statusLine exists, and replaces it with -Force' {
        $original = '{"statusLine":{"type":"command","command":"other"}}'
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes($original))
        $originalHash = (Get-FileHash -LiteralPath $script:settingsPath).Hash

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Conflict'
        (Get-FileHash -LiteralPath $script:settingsPath).Hash | Should -Be $originalHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.bak').Count | Should -Be 0

        $forced = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd -Force

        $forced.Status | Should -Be 'Updated'
        $written = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $written['statusLine']['command'] | Should -Be $script:cmd
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*-ET-settings.json.bak').Count | Should -Be 1
    }

    It 'returns AlreadySet when the statusLine is equal but its keys are in a different order' {
        $original = '{"statusLine":{"refreshInterval":20,"padding":0,"command":"C:/tools/ccstatusline.exe","type":"command"},"env":{"CCSTATUSLINE_WIDTH":"90"}}'
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes($original))
        $originalHash = (Get-FileHash -LiteralPath $script:settingsPath).Hash

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'AlreadySet'
        (Get-FileHash -LiteralPath $script:settingsPath).Hash | Should -Be $originalHash
    }

    It 'never changes an existing env.CCSTATUSLINE_WIDTH' {
        $original = '{"env":{"CCSTATUSLINE_WIDTH":"200"}}'
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes($original))

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Updated'
        $written = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $written['env']['CCSTATUSLINE_WIDTH'] | Should -Be '200'
    }

    It 'preserves ISO-date-looking string values exactly' {
        # An offset timestamp: parsed as a DateTime it would be re-serialized in local time.
        $original = "{`n  `"lastSeen`": `"2026-09-28T12:34:56.1234567+02:00`"`n}`n"
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes($original))

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'Updated'
        $rawContent = Get-Content -LiteralPath $script:settingsPath -Raw
        $rawContent.Contains('"lastSeen": "2026-09-28T12:34:56.1234567+02:00"') | Should -BeTrue
    }

    It 'returns SettingsInvalid and leaves the file bytes unchanged when the file is not valid JSON' {
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes('not json{'))
        $originalHash = (Get-FileHash -LiteralPath $script:settingsPath).Hash

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd

        $result.Status | Should -Be 'SettingsInvalid'
        (Get-FileHash -LiteralPath $script:settingsPath).Hash | Should -Be $originalHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.bak').Count | Should -Be 0
    }

    It 'returns Skipped and writes nothing under -WhatIf' {
        [System.IO.File]::WriteAllBytes($script:settingsPath, $script:utf8.GetBytes('{"theme":"dark"}'))
        $originalHash = (Get-FileHash -LiteralPath $script:settingsPath).Hash

        $result = Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath -Command $script:cmd -WhatIf

        $result.Status | Should -Be 'Skipped'
        (Get-FileHash -LiteralPath $script:settingsPath).Hash | Should -Be $originalHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.bak').Count | Should -Be 0
    }

    It 'defaults the command to the bun shim path with forward slashes only' {
        Set-CcstatuslineStatusLine -SettingsPath $script:settingsPath | Out-Null

        $written = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $written['statusLine']['command'] | Should -BeLike '*/.bun/bin/ccstatusline.exe'
        $written['statusLine']['command'] | Should -Not -Match '\\'
    }
}
