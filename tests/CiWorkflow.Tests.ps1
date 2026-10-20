#requires -Version 7.6

# Parses .github/workflows/*.yml and .github/workflows/actions.lock with
# powershell-yaml and asserts the shape that keeps the CI jobs usable as
# required status checks and every third-party action locked.

BeforeDiscovery {
    $script:YamlAvailable = [bool](Get-Module -ListAvailable -Name powershell-yaml)
    if (-not $script:YamlAvailable -and $env:CI) {
        throw 'powershell-yaml is not installed; CI must install it before Pester runs.'
    }
}

BeforeAll {
    if (Get-Module -ListAvailable -Name powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
    }

    $script:WorkflowDir = Join-Path $PSScriptRoot '..' '.github' 'workflows'
    $script:CiPath = Join-Path $script:WorkflowDir 'ci.yml'
    $script:LockPath = Join-Path $script:WorkflowDir 'actions.lock'

    function script:Read-Yaml([string]$Path) {
        ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $Path -Raw)
    }

    # 'on' is a plain key to powershell-yaml (YAML 1.2), but guard against a
    # YAML 1.1 reading that turns it into a boolean.
    function script:Get-OnBlock($Workflow) {
        foreach ($key in $Workflow.Keys) {
            if ("$key" -eq 'on' -or "$key" -eq 'True') { return $Workflow[$key] }
        }
        $null
    }

    function script:Test-ThirdPartyAction([string]$Uses) {
        -not ($Uses.StartsWith('./') -or $Uses.StartsWith('$/') -or
            $Uses.StartsWith('docker://') -or $Uses.StartsWith('Adam-S-Daniel/cms-platform/'))
    }

    $script:Ci = Read-Yaml $script:CiPath
    $script:Lock = Read-Yaml $script:LockPath
}

Describe 'CI workflow shape (required-check readiness)' -Skip:(-not $script:YamlAvailable) {

    It 'has no paths or paths-ignore filter on pull_request or push' {
        $on = Get-OnBlock $script:Ci
        $on | Should -Not -BeNullOrEmpty
        foreach ($eventName in 'pull_request', 'push') {
            $on.Contains($eventName) | Should -BeTrue -Because "ci.yml must trigger on $eventName"
            $trigger = $on[$eventName]
            if ($trigger -is [System.Collections.IDictionary]) {
                $trigger.Contains('paths') | Should -BeFalse -Because "$eventName must not filter on paths"
                $trigger.Contains('paths-ignore') | Should -BeFalse -Because "$eventName must not filter on paths-ignore"
            }
        }
    }

    It 'has no concurrency at workflow or job level' {
        $script:Ci.Contains('concurrency') | Should -BeFalse
        foreach ($id in $script:Ci.jobs.Keys) {
            $script:Ci.jobs[$id].Contains('concurrency') | Should -BeFalse -Because "job $id must not set concurrency"
        }
    }

    It 'has exactly the jobs shell, test and test-linux, with no name, matrix or timeout-minutes' {
        @($script:Ci.jobs.Keys | Sort-Object) | Should -Be @('shell', 'test', 'test-linux')
        foreach ($id in $script:Ci.jobs.Keys) {
            $job = $script:Ci.jobs[$id]
            $job.Contains('name') | Should -BeFalse -Because "job $id is a required check by id"
            $job.Contains('timeout-minutes') | Should -BeFalse -Because "job $id must not set timeout-minutes"
            if ($job.Contains('strategy')) {
                $job.strategy.Contains('matrix') | Should -BeFalse -Because "job $id must not use a matrix"
            }
        }
    }

    It 'gates every step after the salient step in job <_>' -ForEach @('shell', 'test', 'test-linux') {
        $steps = @($script:Ci.jobs[$_].steps)
        $salient = @(for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i].id -eq 'salient') { $i } })
        $salient.Count | Should -Be 1 -Because "job $_ needs exactly one step with id: salient"

        $last = $steps.Count - 1
        $last | Should -BeGreaterThan $salient[0]
        $steps[$last].if | Should -BeExactly "steps.salient.outputs.run != 'true'" -Because 'the final step reports that nothing salient changed'

        for ($i = $salient[0] + 1; $i -lt $last; $i++) {
            $step = $steps[$i]
            # The lockfile check decides for itself whether to verify.
            if ($_ -eq 'shell' -and $step.name -eq 'Verify action lockfile') { continue }
            $step.if | Should -BeExactly "steps.salient.outputs.run == 'true'" -Because "step $i of job $_ must be gated on the salient step"
        }
    }

    It 'runs the shared lockfile check exactly once in the shell job, ungated' {
        $verify = @($script:Ci.jobs.shell.steps | Where-Object { $_.name -eq 'Verify action lockfile' })
        $verify.Count | Should -Be 1
        $verify[0].uses | Should -MatchExactly '^Adam-S-Daniel/verify-actions-lock@v\d+\.\d+\.\d+$'
        $verify[0].Contains('if') | Should -BeFalse
    }
}

Describe 'Action pins (actions.lock)' -Skip:(-not $script:YamlAvailable) {

    It 'locks every third-party step uses: in ci.yml' {
        $deps = $script:Lock.dependencies
        $deps | Should -Not -BeNullOrEmpty
        $listed = @($script:Lock.workflows['.github/workflows/ci.yml'])
        $listed.Count | Should -BeGreaterThan 0

        $checked = 0
        foreach ($id in $script:Ci.jobs.Keys) {
            foreach ($step in @($script:Ci.jobs[$id].steps)) {
                if (-not $step.Contains('uses')) { continue }
                $uses = [string]$step.uses
                if (-not (Test-ThirdPartyAction $uses)) { continue }

                $at = $uses.LastIndexOf('@')
                $at | Should -BeGreaterThan 0 -Because "$uses must name a ref"
                $name = $uses.Substring(0, $at)
                $ref = $uses.Substring($at + 1)

                # gh actions-lock lowercases owner/repo in its keys; the ref stays exact.
                $matchKey = {
                    param($key)
                    $k = [string]$key
                    $kAt = $k.LastIndexOf('@')
                    $kAt -gt 0 -and $k.Substring(0, $kAt) -ieq $name -and $k.Substring($kAt + 1) -ceq $ref
                }

                $keys = @($deps.Keys | Where-Object { & $matchKey $_ })
                $keys.Count | Should -Be 1 -Because "$uses must have exactly one actions.lock dependency"
                $dep = $deps[$keys[0]]
                $dep.commit | Should -MatchExactly '^sha1-[0-9a-f]{40}$'
                $dep.ref | Should -BeExactly $ref

                @($listed | Where-Object { & $matchKey $_ }).Count | Should -Be 1 -Because "$uses must be listed under .github/workflows/ci.yml"
                $checked++
            }
        }
        $checked | Should -BeGreaterThan 0
    }

    It 'pins every cross-repo reusable workflow to a full commit SHA' {
        # actions.lock does not lock reusable workflows (jobs.<id>.uses), so
        # those still take a 40-character commit SHA.
        foreach ($file in Get-ChildItem -LiteralPath $script:WorkflowDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' }) {
            $workflow = Read-Yaml $file.FullName
            if (-not $workflow.Contains('jobs')) { continue }
            foreach ($id in $workflow.jobs.Keys) {
                $job = $workflow.jobs[$id]
                if (-not $job.Contains('uses')) { continue }
                $uses = [string]$job.uses
                if ($uses.StartsWith('./') -or $uses.StartsWith('$/') -or $uses.StartsWith('Adam-S-Daniel/cms-platform/')) { continue }
                $uses | Should -MatchExactly '@[0-9a-f]{40}$' -Because "$($file.Name) job $id"
            }
        }
    }
}
