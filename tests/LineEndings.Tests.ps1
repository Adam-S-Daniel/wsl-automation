#requires -Version 7.6

Describe 'Shell script line endings' {

    It 'verifies that every .sh file has eol=lf in git attributes' {
        $repoRoot = Join-Path $PSScriptRoot '..'
        $shFiles = git -C $repoRoot ls-files '*.sh'

        $shFiles | Should -Not -BeNullOrEmpty -Because '.sh files must be checked in'

        foreach ($file in $shFiles) {
            $attrOutput = git -C $repoRoot check-attr eol -- $file
            $attrOutput | Should -Match 'eol: lf' -Because "git should normalize $file to LF line endings"
        }
    }

    It 'regression test: verifies that .sh files contain no carriage returns (CRLF -> LF fix for pipefail: invalid option name)' {
        # This is a regression test for the failure: bash scripts run from WSL against the
        # Windows checkout die with "set: pipefail: invalid option name" when core.autocrlf=true
        # produces CRLF line endings. Every .sh file must be pure LF on disk.
        $repoRoot = Join-Path $PSScriptRoot '..'
        $shFiles = git -C $repoRoot ls-files '*.sh'

        foreach ($file in $shFiles) {
            $fullPath = Join-Path $repoRoot $file
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $bytes | Should -Not -Contain 13 -Because "$file must have LF line endings, not CRLF"
        }
    }
}
