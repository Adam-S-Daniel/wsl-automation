#requires -Version 7.6

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

    function script:Read-Utf8([string]$Path) {
        [System.Text.UTF8Encoding]::new($false).GetString([System.IO.File]::ReadAllBytes($Path))
    }
    function script:Write-Utf8([string]$Path, [string]$Text) {
        [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
    }
    function script:New-Dir([string]$Path) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $Path
    }
    function script:ConvertTo-WslKey([string]$WindowsPath) {
        $full = [System.IO.Path]::GetFullPath($WindowsPath)
        '/mnt/' + $full.Substring(0, 1).ToLowerInvariant() + '/' + $full.Substring(3).Replace('\', '/')
    }
}

Describe 'Get-CodexTrustedText' {

    It 'appends a new table to empty text' {
        InModuleScope WslAutomation {
            $result = Get-CodexTrustedText -Text '' -Path 'D:\repos\x'
            $result | Should -BeExactly "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`n"
        }
    }

    It 'finds a header in basic-string spelling and leaves a trusted table unchanged' {
        InModuleScope WslAutomation {
            $text = "[projects.`"D:\\repos\\x`"]`ntrust_level = `"trusted`"`n"
            $result = Get-CodexTrustedText -Text $text -Path 'D:\repos\x'
            ($result -ceq $text) | Should -BeTrue
        }
    }

    It 'finds a header in literal-string spelling and leaves a trusted table unchanged' {
        InModuleScope WslAutomation {
            $text = "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`n"
            $result = Get-CodexTrustedText -Text $text -Path 'D:\repos\x'
            ($result -ceq $text) | Should -BeTrue
        }
    }

    It 'replaces an untrusted trust_level in place' {
        InModuleScope WslAutomation {
            $text = "[projects.'D:\repos\x']`ntrust_level = `"untrusted`"`nother = 1`n"
            $result = Get-CodexTrustedText -Text $text -Path 'D:\repos\x'
            $result | Should -BeExactly "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`nother = 1`n"
        }
    }

    It 'inserts a missing trust_level right after the header' {
        InModuleScope WslAutomation {
            $text = "[projects.'D:\repos\x']`nother = 1`n"
            $result = Get-CodexTrustedText -Text $text -Path 'D:\repos\x'
            $result | Should -BeExactly "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`nother = 1`n"
        }
    }

    It 'preserves unrelated content byte for byte' {
        InModuleScope WslAutomation {
            $before = "# my config`nmodel = `"x`"`n`n[mcp_servers.a]`ncommand = `"b`"  # keep`n"
            $after = "`n[projects.'D:\other']`ntrust_level = `"trusted`"`n"
            $result = Get-CodexTrustedText -Text ($before + $after) -Path 'D:\repos\x'
            $result.StartsWith($before + $after, [System.StringComparison]::Ordinal) | Should -BeTrue
            $result.EndsWith("[projects.'D:\repos\x']`ntrust_level = `"trusted`"`n", [System.StringComparison]::Ordinal) | Should -BeTrue
        }
    }

    It 'uses CRLF for additions when asked' {
        InModuleScope WslAutomation {
            $result = Get-CodexTrustedText -Text "a = 1`r`n" -Path 'D:\repos\x' -NewLine "`r`n"
            $result | Should -BeExactly "a = 1`r`n`r`n[projects.'D:\repos\x']`r`ntrust_level = `"trusted`"`r`n"
        }
    }

    It 'handles text without a trailing newline' {
        InModuleScope WslAutomation {
            $result = Get-CodexTrustedText -Text 'a = 1' -Path 'D:\repos\x'
            $result | Should -BeExactly "a = 1`n`n[projects.'D:\repos\x']`ntrust_level = `"trusted`"`n"
        }
    }

    It 'handles a header on the last line without a newline' {
        InModuleScope WslAutomation {
            $result = Get-CodexTrustedText -Text "[projects.'D:\repos\x']" -Path 'D:\repos\x'
            $result | Should -BeExactly "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`n"
        }
    }

    It 'uses a basic-string key when the path contains a single quote' {
        InModuleScope WslAutomation {
            $result = Get-CodexTrustedText -Text '' -Path "D:\repos\it's"
            $result | Should -BeExactly "[projects.`"D:\\repos\\it's`"]`ntrust_level = `"trusted`"`n"
        }
    }

    It 'does not mistake a trust_level in a later table for this table' {
        InModuleScope WslAutomation {
            $text = "[projects.'D:\repos\x']`nother = 1`n`n[projects.'D:\repos\y']`ntrust_level = `"trusted`"`n"
            $result = Get-CodexTrustedText -Text $text -Path 'D:\repos\x'
            $result | Should -BeExactly "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`nother = 1`n`n[projects.'D:\repos\y']`ntrust_level = `"trusted`"`n"
        }
    }
}

Describe 'Write-AgentTrustFile' {

    It 'writes nothing and returns false under -WhatIf' {
        $file = Join-Path $TestDrive 'wat-whatif.json'
        InModuleScope WslAutomation -Parameters @{ File = $file } {
            $result = Write-AgentTrustFile -Path $File -Bytes ([byte[]](65, 66)) -WhatIf
            $result | Should -BeFalse
        }
        Test-Path -LiteralPath $file | Should -BeFalse
        Test-Path -LiteralPath "$file.tmp" | Should -BeFalse
    }

    It 'writes the bytes, backs up the original and leaves no .tmp' {
        $file = Join-Path $TestDrive 'wat-write.json'
        Write-Utf8 $file 'old'
        InModuleScope WslAutomation -Parameters @{ File = $file } {
            $result = Write-AgentTrustFile -Path $File -Bytes ([byte[]](65, 66))
            $result | Should -BeTrue
        }
        Read-Utf8 $file | Should -BeExactly 'AB'
        Read-Utf8 "$file.bak-agent-trust" | Should -BeExactly 'old'
        Test-Path -LiteralPath "$file.tmp" | Should -BeFalse
    }
}

Describe 'Grant-ClaudeProjectTrust' {

    BeforeEach {
        $script:cfg = Join-Path $TestDrive 'claude.json'
        foreach ($p in @($script:cfg, "$($script:cfg).bak-agent-trust", "$($script:cfg).tmp")) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
    }

    It 'does nothing and does not create the file when it is missing' {
        InModuleScope WslAutomation -Parameters @{ Cfg = $script:cfg } {
            $result = Grant-ClaudeProjectTrust -ConfigPath $Cfg -Key 'D:/repos/x'
            $result | Should -BeNullOrEmpty
        }
        Test-Path -LiteralPath $script:cfg | Should -BeFalse
    }

    It 'warns and leaves the file unchanged when the JSON is invalid' {
        Write-Utf8 $script:cfg '{ not json'
        InModuleScope WslAutomation -Parameters @{ Cfg = $script:cfg } {
            $result = Grant-ClaudeProjectTrust -ConfigPath $Cfg -Key 'D:/repos/x' -WarningVariable warn -WarningAction SilentlyContinue
            $result | Should -BeNullOrEmpty
            @($warn).Count | Should -Be 1
        }
        Read-Utf8 $script:cfg | Should -BeExactly '{ not json'
        Test-Path -LiteralPath "$($script:cfg).bak-agent-trust" | Should -BeFalse
    }

    It 'adds a new key with hasTrustDialogAccepted true and preserves other fields' {
        Write-Utf8 $script:cfg '{"numStartups":7,"projects":{"D:/other":{"allowedTools":["a"],"hasTrustDialogAccepted":false}}}'
        InModuleScope WslAutomation -Parameters @{ Cfg = $script:cfg } {
            $result = @(Grant-ClaudeProjectTrust -ConfigPath $Cfg -Key @('D:/repos/x', 'D:/other'))
            $result | Should -Be @('D:/repos/x', 'D:/other')
        }
        $json = Read-Utf8 $script:cfg | ConvertFrom-Json -AsHashtable
        $json['numStartups'] | Should -Be 7
        $json['projects']['D:/repos/x']['hasTrustDialogAccepted'] | Should -BeTrue
        $json['projects']['D:/other']['hasTrustDialogAccepted'] | Should -BeTrue
        $json['projects']['D:/other']['allowedTools'] | Should -Be @('a')
    }

    It 'returns nothing and does not rewrite the file when already trusted' {
        Write-Utf8 $script:cfg '{"projects":{"D:/repos/x":{"hasTrustDialogAccepted":true}}}'
        InModuleScope WslAutomation -Parameters @{ Cfg = $script:cfg } {
            $result = Grant-ClaudeProjectTrust -ConfigPath $Cfg -Key 'D:/repos/x'
            $result | Should -BeNullOrEmpty
        }
        Test-Path -LiteralPath "$($script:cfg).bak-agent-trust" | Should -BeFalse
        Read-Utf8 $script:cfg | Should -BeExactly '{"projects":{"D:/repos/x":{"hasTrustDialogAccepted":true}}}'
    }

    It 'writes a backup of the original content and UTF-8 without a BOM when changing' {
        $original = '{"a":1}'
        Write-Utf8 $script:cfg $original
        InModuleScope WslAutomation -Parameters @{ Cfg = $script:cfg } {
            Grant-ClaudeProjectTrust -ConfigPath $Cfg -Key 'D:/repos/x' | Out-Null
        }
        Read-Utf8 "$($script:cfg).bak-agent-trust" | Should -BeExactly $original
        $bytes = [System.IO.File]::ReadAllBytes($script:cfg)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $bytes[0] | Should -Be ([byte][char]'{')
    }
}

Describe 'Grant-CodexProjectTrust' {

    BeforeEach {
        $script:toml = Join-Path $TestDrive 'codex-config.toml'
        foreach ($p in @($script:toml, "$($script:toml).bak-agent-trust", "$($script:toml).tmp")) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
    }

    It 'creates the file when its directory exists' {
        InModuleScope WslAutomation -Parameters @{ Toml = $script:toml } {
            $result = @(Grant-CodexProjectTrust -ConfigPath $Toml -Key 'D:\repos\x')
            $result | Should -Be @('D:\repos\x')
        }
        Read-Utf8 $script:toml | Should -BeExactly "[projects.'D:\repos\x']`ntrust_level = `"trusted`"`n"
    }

    It 'skips when the directory is missing' {
        $missing = Join-Path $TestDrive 'no-such-dir' 'config.toml'
        InModuleScope WslAutomation -Parameters @{ Toml = $missing } {
            $result = Grant-CodexProjectTrust -ConfigPath $Toml -Key 'D:\repos\x'
            $result | Should -BeNullOrEmpty
        }
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'preserves the BOM and CRLF style' {
        $bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + [System.Text.UTF8Encoding]::new($false).GetBytes("a = 1`r`n")
        [System.IO.File]::WriteAllBytes($script:toml, $bytes)
        InModuleScope WslAutomation -Parameters @{ Toml = $script:toml } {
            Grant-CodexProjectTrust -ConfigPath $Toml -Key 'D:\repos\x' | Out-Null
        }
        $out = [System.IO.File]::ReadAllBytes($script:toml)
        $out[0] | Should -Be 0xEF
        $out[1] | Should -Be 0xBB
        $out[2] | Should -Be 0xBF
        $text = [System.Text.UTF8Encoding]::new($false).GetString($out, 3, $out.Length - 3)
        $text | Should -BeExactly "a = 1`r`n`r`n[projects.'D:\repos\x']`r`ntrust_level = `"trusted`"`r`n"
    }

    It 'returns nothing on a second run' {
        InModuleScope WslAutomation -Parameters @{ Toml = $script:toml } {
            Grant-CodexProjectTrust -ConfigPath $Toml -Key 'D:\repos\x' | Out-Null
            $again = Grant-CodexProjectTrust -ConfigPath $Toml -Key 'D:\repos\x'
            $again | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-AgentTrustDefaultOwnerRoot' {

    It 'returns the two D:\repos owner roots for a Windows host' {
        InModuleScope WslAutomation {
            $result = @(Get-AgentTrustDefaultOwnerRoot -IsWindowsHost $true)
            $result | Should -Be @('D:\repos\adam-s-daniel', 'D:\repos\jodidaniel')
        }
    }

    It 'returns ~/repos for a non-Windows host' {
        InModuleScope WslAutomation {
            $result = @(Get-AgentTrustDefaultOwnerRoot -IsWindowsHost $false)
            $result | Should -Be @(Join-Path $HOME 'repos')
        }
    }
}

Describe 'Set-AgentWorkspaceTrust' {

    BeforeEach {
        $script:base = Join-Path $TestDrive ('ws-' + [guid]::NewGuid().ToString('N'))
        $script:root = New-Dir (Join-Path $script:base 'owner')
        $script:claude = Join-Path $script:base 'claude.json'
        $script:codex = Join-Path $script:base 'codex.toml'
        Write-Utf8 $script:claude '{"projects":{}}'
        Write-Utf8 $script:codex ''
        $script:common = @{
            OwnerRoot        = @($script:root)
            ClaudeConfigPath = $script:claude
            CodexConfigPath  = $script:codex
        }
    }

    It 'scan mode trusts the root and git children (dir and file) but not non-git children' {
        $repo = New-Dir (Join-Path $script:root 'repo')
        New-Dir (Join-Path $repo '.git') | Out-Null
        $wt = New-Dir (Join-Path $script:root 'wt')
        Write-Utf8 (Join-Path $wt '.git') 'gitdir: elsewhere'
        $plain = New-Dir (Join-Path $script:root 'plain')

        $common = $script:common
        $result = @(Set-AgentWorkspaceTrust @common)

        $claudeKeys = @($result | Where-Object Agent -EQ 'Claude' | ForEach-Object Key)
        $expected = @($script:root, $repo, $wt) | ForEach-Object { [System.IO.Path]::GetFullPath($_).Replace('\', '/') }
        $claudeKeys | Sort-Object | Should -Be ($expected | Sort-Object)
        $claudeKeys | Should -Not -Contain ([System.IO.Path]::GetFullPath($plain).Replace('\', '/'))
        $claudeKeys | ForEach-Object { $_ | Should -Not -Match '\\' }
    }

    It 'writes both the Windows key and the /mnt key for Codex' -Skip:(-not $IsWindows) {
        $repo = New-Dir (Join-Path $script:root 'repo')
        New-Dir (Join-Path $repo '.git') | Out-Null

        $common = $script:common
        $result = @(Set-AgentWorkspaceTrust @common)

        $codexKeys = @($result | Where-Object Agent -EQ 'Codex' | ForEach-Object Key)
        $codexKeys | Should -Contain ([System.IO.Path]::GetFullPath($repo))
        $codexKeys | Should -Contain (ConvertTo-WslKey $repo)
        (ConvertTo-WslKey $repo) | Should -Match '^/mnt/[a-z]/'
        $toml = Read-Utf8 $script:codex
        $toml.Contains("[projects.'$(ConvertTo-WslKey $repo)']") | Should -BeTrue
        $toml.Contains("[projects.'$([System.IO.Path]::GetFullPath($repo))']") | Should -BeTrue
    }

    It 'writes only the Linux key for Codex, with no /mnt key' -Skip:$IsWindows {
        $repo = New-Dir (Join-Path $script:root 'repo')
        New-Dir (Join-Path $repo '.git') | Out-Null

        $common = $script:common
        $result = @(Set-AgentWorkspaceTrust @common)

        $codexKeys = @($result | Where-Object Agent -EQ 'Codex' | ForEach-Object Key)
        $codexKeys | Should -Contain ([System.IO.Path]::GetFullPath($repo))
        @($codexKeys | Where-Object { $_.StartsWith('/mnt/') }).Count | Should -Be 0
        $toml = Read-Utf8 $script:codex
        $toml.Contains("[projects.'$([System.IO.Path]::GetFullPath($repo))']") | Should -BeTrue
        $toml.Contains('/mnt/') | Should -BeFalse
    }

    It 'treats a path differing only in case as outside the root on Linux' -Skip:$IsWindows {
        $wrongCase = Join-Path ($script:root + '').ToUpperInvariant() 'x'
        $common = $script:common
        @(Set-AgentWorkspaceTrust @common -Path $wrongCase).Count | Should -Be 0
    }

    It 'treats a path differing only in case as inside the root on Windows' -Skip:(-not $IsWindows) {
        $wrongCase = Join-Path ($script:root + '').ToUpperInvariant() 'x'
        $common = $script:common
        @(Set-AgentWorkspaceTrust @common -Path $wrongCase).Count | Should -BeGreaterThan 0
    }

    It 'uses the platform default owner roots when -OwnerRoot is not given' {
        $repo = New-Dir (Join-Path $script:root 'repo')
        New-Dir (Join-Path $repo '.git') | Out-Null
        Mock -ModuleName WslAutomation Get-AgentTrustDefaultOwnerRoot -MockWith { $script:root }

        $result = @(Set-AgentWorkspaceTrust -ClaudeConfigPath $script:claude -CodexConfigPath $script:codex)

        Should -Invoke -ModuleName WslAutomation Get-AgentTrustDefaultOwnerRoot -Times 1 -Exactly
        @($result | Where-Object Agent -EQ 'Claude').Key | Should -Contain ([System.IO.Path]::GetFullPath($repo).Replace('\', '/'))
    }

    It 'skips a -Path outside the owner roots' {
        $outside = New-Dir (Join-Path $script:base 'outside')
        $common = $script:common
        $result = @(Set-AgentWorkspaceTrust @common -Path $outside)
        $result.Count | Should -Be 0
        Read-Utf8 $script:claude | Should -BeExactly '{"projects":{}}'
    }

    It 'trusts a -Path nested deeper under a root' {
        $deep = New-Dir (Join-Path $script:root 'a' 'b' 'c')
        $common = $script:common
        $result = @(Set-AgentWorkspaceTrust @common -Path $deep)
        @($result | Where-Object Agent -EQ 'Claude').Key | Should -Be ([System.IO.Path]::GetFullPath($deep).Replace('\', '/'))
    }

    It 'does not treat a sibling with the same name prefix as under the root' {
        $sibling = New-Dir ($script:root + '-sibling')
        $common = $script:common
        @(Set-AgentWorkspaceTrust @common -Path $sibling).Count | Should -Be 0
    }

    It 'returns nothing on a second run' {
        $repo = New-Dir (Join-Path $script:root 'repo')
        New-Dir (Join-Path $repo '.git') | Out-Null
        $common = $script:common
        Set-AgentWorkspaceTrust @common | Out-Null
        @(Set-AgentWorkspaceTrust @common).Count | Should -Be 0
    }

    It 'changes no files under -WhatIf' {
        $repo = New-Dir (Join-Path $script:root 'repo')
        New-Dir (Join-Path $repo '.git') | Out-Null
        $common = $script:common
        Set-AgentWorkspaceTrust @common -WhatIf | Out-Null
        Read-Utf8 $script:claude | Should -BeExactly '{"projects":{}}'
        Read-Utf8 $script:codex | Should -BeExactly ''
        Test-Path -LiteralPath "$($script:claude).bak-agent-trust" | Should -BeFalse
    }
}

Describe 'Install-AgentTrustGitHook' {

    BeforeEach {
        $script:tpl = Join-Path $TestDrive ('tpl-' + [guid]::NewGuid().ToString('N'))
        $script:tplKey = [System.IO.Path]::GetFullPath($script:tpl).Replace('\', '/')
        $script:hook = Join-Path $script:tpl 'hooks' 'post-checkout'
        $script:pwshPath = Join-Path $TestDrive 'bin' 'pwsh.exe'
        $script:trustPath = Join-Path $TestDrive 'scripts' 'trust-agent-workspaces.ps1'
        $script:gitState = @{ Template = $null; HooksPath = $null; LocalHooksPath = @{} }

        Mock -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments -contains '--global' -and $Arguments -contains '--get' -and $Arguments -contains 'init.templateDir' } -MockWith {
            if ($script:gitState.Template) { [pscustomobject]@{ ExitCode = 0; Output = @($script:gitState.Template) } }
            else { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        }
        Mock -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments -contains '--global' -and $Arguments -contains '--get' -and $Arguments -contains 'core.hooksPath' } -MockWith {
            if ($script:gitState.HooksPath) { [pscustomobject]@{ ExitCode = 0; Output = @($script:gitState.HooksPath) } }
            else { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        }
        Mock -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments[0] -eq '-C' -and $Arguments -contains '--local' -and $Arguments -contains 'core.hooksPath' } -MockWith {
            $value = $script:gitState.LocalHooksPath[$Arguments[1]]
            if ($value) { [pscustomobject]@{ ExitCode = 0; Output = @($value) } }
            else { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        }
        Mock -ModuleName WslAutomation Invoke-GitExe -ParameterFilter { $Arguments -notcontains '--get' } -MockWith {
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
    }

    It 'installs a fresh LF-only, BOM-less hook and sets init.templateDir' {
        $result = Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath

        $result.Status | Should -Be 'Installed'
        $result.TemplateDir | Should -Be $script:tplKey
        $bytes = [System.IO.File]::ReadAllBytes($script:hook)
        $bytes -contains 13 | Should -BeFalse
        ($bytes[0] -eq 0xEF) | Should -BeFalse
        $text = Read-Utf8 $script:hook
        $text.StartsWith('#!/bin/sh') | Should -BeTrue
        $text.Contains('0000000000000000000000000000000000000000') | Should -BeTrue
        $text.Contains([System.IO.Path]::GetFullPath($script:pwshPath).Replace('\', '/')) | Should -BeTrue
        $text.Contains([System.IO.Path]::GetFullPath($script:trustPath).Replace('\', '/')) | Should -BeTrue
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'config' -and $Arguments[1] -eq '--global' -and $Arguments[2] -eq 'init.templateDir' -and $Arguments[3] -eq $script:tplKey
        }
    }

    It 'reports AlreadyInstalled and makes no set call on a second run' {
        Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath | Out-Null
        $script:gitState.Template = $script:tplKey

        $result = Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath

        $result.Status | Should -Be 'AlreadyInstalled'
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 1 -Exactly -ParameterFilter { $Arguments -notcontains '--get' }
    }

    It 'throws on a different existing templateDir without writing a hook, and succeeds with -Force' {
        $script:gitState.Template = 'C:/somewhere/else'

        { Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath } | Should -Throw '*init.templateDir*'
        Test-Path -LiteralPath $script:hook | Should -BeFalse

        $result = Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath -Force
        $result.Status | Should -Be 'Installed'
        Test-Path -LiteralPath $script:hook | Should -BeTrue
    }

    It 'warns when core.hooksPath is set' {
        $script:gitState.HooksPath = 'C:/hooks'
        Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
        @($warn).Count | Should -Be 1
        "$($warn[0])" | Should -BeLike '*core.hooksPath*C:/hooks*'
    }

    It 'throws on a foreign post-checkout hook, and overwrites it with -Force' {
        New-Dir (Split-Path $script:hook -Parent) | Out-Null
        Write-Utf8 $script:hook "#!/bin/sh`necho mine`n"

        { Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath } | Should -Throw '*not written by this installer*'
        Read-Utf8 $script:hook | Should -BeExactly "#!/bin/sh`necho mine`n"

        Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath -Force | Out-Null
        (Read-Utf8 $script:hook).Contains('wsl-automation') | Should -BeTrue
    }

    It 'writes nothing and makes no set call under -WhatIf' {
        Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath -WhatIf | Out-Null
        Test-Path -LiteralPath $script:hook | Should -BeFalse
        Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 0 -Exactly -ParameterFilter { $Arguments -notcontains '--get' }
    }

    It 'defaults -PwshPath to the pwsh on PATH off Windows' -Skip:$IsWindows {
        $expected = [System.IO.Path]::GetFullPath((Get-Command pwsh).Source).Replace('\', '/')
        Install-AgentTrustGitHook -TemplateDir $script:tpl -TrustScriptPath $script:trustPath | Out-Null
        (Read-Utf8 $script:hook).Contains($expected) | Should -BeTrue
    }

    It 'makes the template hook executable (0755) on Linux' -Skip:$IsWindows {
        Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath | Out-Null
        [int][System.IO.File]::GetUnixFileMode($script:hook) | Should -Be 493
    }

    It 'fixes a current but non-executable template hook and reports Installed' -Skip:$IsWindows {
        Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath | Out-Null
        $script:gitState.Template = $script:tplKey
        [System.IO.File]::SetUnixFileMode($script:hook, [System.IO.UnixFileMode]0x1A4)

        $result = Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath

        $result.Status | Should -Be 'Installed'
        [int][System.IO.File]::GetUnixFileMode($script:hook) | Should -Be 493
        $again = Install-AgentTrustGitHook -TemplateDir $script:tpl -PwshPath $script:pwshPath -TrustScriptPath $script:trustPath
        $again.Status | Should -Be 'AlreadyInstalled'
    }

    Context '-IncludeExistingClones' {

        BeforeEach {
            $script:owner = New-Dir (Join-Path $TestDrive ('own-' + [guid]::NewGuid().ToString('N')))
            $script:repoA = New-Dir (Join-Path $script:owner 'repo-a')
            New-Dir (Join-Path $script:repoA '.git') | Out-Null
            $script:worktree = New-Dir (Join-Path $script:owner 'wt')
            Write-Utf8 (Join-Path $script:worktree '.git') 'gitdir: elsewhere'
            $script:plain = New-Dir (Join-Path $script:owner 'plain')
            $script:install = @{
                TemplateDir           = $script:tpl
                PwshPath              = $script:pwshPath
                TrustScriptPath       = $script:trustPath
                IncludeExistingClones = $true
                OwnerRoot             = @($script:owner)
            }
            $script:cloneHook = Join-Path $script:repoA '.git' 'hooks' 'post-checkout'
        }

        It 'writes the template hook bytes into a child with a .git directory' {
            $install = $script:install
            $result = Install-AgentTrustGitHook @install

            @($result.ExistingClones) | Should -Be @($script:repoA)
            Read-Utf8 $script:cloneHook | Should -BeExactly (Read-Utf8 $script:hook)
            ([System.IO.File]::ReadAllBytes($script:cloneHook)) -contains 13 | Should -BeFalse
        }

        It 'skips a linked worktree (.git file) and non-git children' {
            $install = $script:install
            Install-AgentTrustGitHook @install | Out-Null

            Test-Path -LiteralPath (Join-Path $script:worktree '.git' 'hooks') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:plain '.git') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:plain 'hooks') | Should -BeFalse
        }

        It 'does not descend past direct children' {
            $nested = New-Dir (Join-Path $script:owner 'group' 'deep')
            New-Dir (Join-Path $nested '.git') | Out-Null
            $install = $script:install
            $result = Install-AgentTrustGitHook @install

            @($result.ExistingClones) | Should -Be @($script:repoA)
            Test-Path -LiteralPath (Join-Path $nested '.git' 'hooks') | Should -BeFalse
        }

        It 'warns and skips a repo with a foreign post-checkout hook, even with -Force' {
            New-Dir (Split-Path $script:cloneHook -Parent) | Out-Null
            Write-Utf8 $script:cloneHook "#!/bin/sh`necho mine`n"
            $install = $script:install
            $result = Install-AgentTrustGitHook @install -Force -WarningVariable warn -WarningAction SilentlyContinue

            @($result.ExistingClones).Count | Should -Be 0
            Read-Utf8 $script:cloneHook | Should -BeExactly "#!/bin/sh`necho mine`n"
            @($warn).Count | Should -Be 1
            "$($warn[0])" | Should -BeLike '*repo-a*not written by this installer*'
        }

        It 'warns and skips a repo whose local core.hooksPath is set' {
            $script:gitState.LocalHooksPath[$script:repoA] = '.githooks'
            $install = $script:install
            $result = Install-AgentTrustGitHook @install -WarningVariable warn -WarningAction SilentlyContinue

            @($result.ExistingClones).Count | Should -Be 0
            Test-Path -LiteralPath $script:cloneHook | Should -BeFalse
            @($warn).Count | Should -Be 1
            "$($warn[0])" | Should -BeLike '*repo-a*core.hooksPath*.githooks*'
            Should -Invoke -ModuleName WslAutomation Invoke-GitExe -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq '-C' -and $Arguments[1] -eq $script:repoA -and $Arguments -contains '--local' -and $Arguments -contains 'core.hooksPath'
            }
        }

        It 'overwrites an older hook that carries the installer marker' {
            New-Dir (Split-Path $script:cloneHook -Parent) | Out-Null
            Write-Utf8 $script:cloneHook "#!/bin/sh`n# Installed by wsl-automation scripts/install-agent-trust-hook.ps1.`necho old`n"
            $install = $script:install
            $result = Install-AgentTrustGitHook @install

            @($result.ExistingClones) | Should -Be @($script:repoA)
            Read-Utf8 $script:cloneHook | Should -BeExactly (Read-Utf8 $script:hook)
        }

        It 'is idempotent: a second run reports no existing clones' {
            $install = $script:install
            Install-AgentTrustGitHook @install | Out-Null
            $script:gitState.Template = $script:tplKey

            $result = Install-AgentTrustGitHook @install

            @($result.ExistingClones).Count | Should -Be 0
            $result.Status | Should -Be 'AlreadyInstalled'
        }

        It 'writes nothing into clones under -WhatIf' {
            $install = $script:install
            $result = Install-AgentTrustGitHook @install -WhatIf

            @($result.ExistingClones).Count | Should -Be 0
            Test-Path -LiteralPath $script:cloneHook | Should -BeFalse
        }

        It 'returns an empty ExistingClones and touches no clone without the switch' {
            $install = $script:install
            $install.Remove('IncludeExistingClones')
            $result = Install-AgentTrustGitHook @install

            @($result.ExistingClones).Count | Should -Be 0
            $result.PSObject.Properties.Name | Should -Contain 'ExistingClones'
            Test-Path -LiteralPath $script:cloneHook | Should -BeFalse
        }

        It 'makes the clone hook executable (0755) on Linux' -Skip:$IsWindows {
            $install = $script:install
            Install-AgentTrustGitHook @install | Out-Null
            [int][System.IO.File]::GetUnixFileMode($script:cloneHook) | Should -Be 493
        }

        It 'fixes a current but non-executable clone hook on Linux' -Skip:$IsWindows {
            $install = $script:install
            Install-AgentTrustGitHook @install | Out-Null
            $script:gitState.Template = $script:tplKey
            [System.IO.File]::SetUnixFileMode($script:cloneHook, [System.IO.UnixFileMode]0x1A4)

            $result = Install-AgentTrustGitHook @install

            @($result.ExistingClones) | Should -Be @($script:repoA)
            [int][System.IO.File]::GetUnixFileMode($script:cloneHook) | Should -Be 493
        }
    }
}
