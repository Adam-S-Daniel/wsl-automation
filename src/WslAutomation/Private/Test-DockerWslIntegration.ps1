function Test-DockerWslIntegration {
    <#
    .SYNOPSIS
        Reports whether Docker Desktop's WSL integration works inside an already-running distro.
    .DESCRIPTION
        Runs one command inside the distro (through Invoke-WslExe) that checks two things:
        Docker Desktop's shared socket under /mnt/wsl is present, and the docker CLI reaches the
        engine through it. The mount is the part that vanishes when Docker's pre-bootstrap
        unmounts it (https://github.com/docker/desktop-feedback/issues/678).

        Returns $true only on exit code 0. It never boots a stopped distro on purpose: the
        caller checks that the distro is Running first.
    .PARAMETER DistroName
        Name of the running WSL distro to probe.
    .EXAMPLE
        Test-DockerWslIntegration -DistroName 'Ubuntu'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$DistroName
    )

    $probe = 'test -S /mnt/wsl/docker-desktop/shared-sockets/host-services/backend.sock && timeout 20 docker version --format "{{.Server.Version}}" >/dev/null 2>&1'
    $result = Invoke-WslExe -Arguments @('--distribution', $DistroName, '--exec', 'sh', '-c', $probe)
    return ($result.ExitCode -eq 0)
}
