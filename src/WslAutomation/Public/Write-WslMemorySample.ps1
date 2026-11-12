function Write-WslMemorySample {
    <#
    .SYNOPSIS
        Appends one row of Windows and WSL memory statistics to a CSV log.
    .DESCRIPTION
        Samples the Windows memory counters, the memory of the processes that usually dominate
        it (Chrome, the compressed-memory store and the WSL utility VM), and - only when the WSL
        VM is already running - /proc/meminfo and /proc/pressure/memory from inside the distro.
        One row is appended to <LogDir>\samples.csv, which is created (header first) when
        missing. The log exists to answer whether .wslconfig's memory= limit is right, by
        showing over time how much of the machine the WSL VM actually uses and how hard it is
        pressed.

        Every size is in GB (1024^3 bytes) rounded to two decimals, computed from full-precision
        values; the pagefile usage is a percentage with one decimal. A process that is not
        running counts as 0.

        Whether the VM is running is decided from the vmmemWSL process, never by asking WSL, so
        logging can never boot a stopped VM. When it is not running, or when reading it fails,
        the WSL_* columns are left empty and the row is still written.

        Columns, in order: Time (local), Win_TotalGB, Win_AvailGB, Win_StandbyGB, Win_ModifiedGB,
        Win_CommitGB, Win_CommitLimitGB, Win_PagefilePct, Win_CompressionGB, Chrome_PrivateGB,
        VmmemWSL_WSGB, VmmemWSL_PrivGB, OtherVmmem_WSGB, OtherVmmem_PrivGB, WSL_Running (1 or 0),
        WSL_TotalGB, WSL_UsedGB (MemTotal - MemAvailable), WSL_AvailGB, WSL_CacheGB
        (Cached + Buffers), WSL_AnonGB, WSL_SwapUsedGB, WSL_CommittedGB (Committed_AS),
        WSL_PSISome300 and WSL_PSIFull300 (the avg300 value of each line of
        /proc/pressure/memory, as the kernel reports it).

        The Windows counter names are English, so this does not work on a localized Windows.
    .PARAMETER LogDir
        Directory holding samples.csv. Created when it does not exist.
    .PARAMETER DistroName
        Name of the WSL distro to read memory statistics from. Defaults to 'Ubuntu'.
    .EXAMPLE
        Write-WslMemorySample -LogDir "$env:LOCALAPPDATA\WslMemoryLog"

        Appends one row to %LOCALAPPDATA%\WslMemoryLog\samples.csv.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDir,

        [string]$DistroName = 'Ubuntu'
    )

    function ConvertTo-RoundedGb {
        param([double]$Bytes)
        [math]::Round($Bytes / 1GB, 2)
    }

    # A process that is not running has nothing to sum, which counts as 0. (Measure-Object -Sum
    # over no input has no Sum property at all, which strict mode turns into an error.)
    function Measure-ProcessMemory {
        param([string]$Name)
        $processes = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
        $workingSet = [double]0
        $private = [double]0
        foreach ($process in $processes) {
            $workingSet += $process.WorkingSet64
            $private += $process.PrivateMemorySize64
        }
        [pscustomobject]@{
            Running    = $processes.Count -gt 0
            WorkingSet = $workingSet
            Private    = $private
        }
    }

    $counterPaths = @(
        '\Memory\Available Bytes',
        '\Memory\Standby Cache Normal Priority Bytes',
        '\Memory\Modified Page List Bytes',
        '\Memory\Committed Bytes',
        '\Memory\Commit Limit',
        '\Paging File(_Total)\% Usage'
    )
    # Keyed by the counter's own name, which is the last path segment whatever the computer
    # name prefix is.
    $counters = @{}
    foreach ($sample in (Get-Counter -Counter $counterPaths).CounterSamples) {
        $counters[$sample.Path.Split('\')[-1].ToLowerInvariant()] = $sample.CookedValue
    }
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem

    $vmmemWsl = Measure-ProcessMemory -Name 'vmmemWSL'
    $vmmem = Measure-ProcessMemory -Name 'vmmem'
    $compression = Measure-ProcessMemory -Name 'Memory Compression'
    $chrome = Measure-ProcessMemory -Name 'chrome'

    $row = [ordered]@{
        Time              = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        # TotalVisibleMemorySize is in KB.
        Win_TotalGB       = ConvertTo-RoundedGb -Bytes ($operatingSystem.TotalVisibleMemorySize * 1KB)
        Win_AvailGB       = ConvertTo-RoundedGb -Bytes $counters['available bytes']
        Win_StandbyGB     = ConvertTo-RoundedGb -Bytes $counters['standby cache normal priority bytes']
        Win_ModifiedGB    = ConvertTo-RoundedGb -Bytes $counters['modified page list bytes']
        Win_CommitGB      = ConvertTo-RoundedGb -Bytes $counters['committed bytes']
        Win_CommitLimitGB = ConvertTo-RoundedGb -Bytes $counters['commit limit']
        Win_PagefilePct   = [math]::Round($counters['% usage'], 1)
        Win_CompressionGB = ConvertTo-RoundedGb -Bytes $compression.WorkingSet
        Chrome_PrivateGB  = ConvertTo-RoundedGb -Bytes $chrome.Private
        VmmemWSL_WSGB     = ConvertTo-RoundedGb -Bytes $vmmemWsl.WorkingSet
        VmmemWSL_PrivGB   = ConvertTo-RoundedGb -Bytes $vmmemWsl.Private
        OtherVmmem_WSGB   = ConvertTo-RoundedGb -Bytes $vmmem.WorkingSet
        OtherVmmem_PrivGB = ConvertTo-RoundedGb -Bytes $vmmem.Private
        WSL_Running       = [int]$vmmemWsl.Running
        WSL_TotalGB       = ''
        WSL_UsedGB        = ''
        WSL_AvailGB       = ''
        WSL_CacheGB       = ''
        WSL_AnonGB        = ''
        WSL_SwapUsedGB    = ''
        WSL_CommittedGB   = ''
        WSL_PSISome300    = ''
        WSL_PSIFull300    = ''
    }

    # Only look inside WSL when its VM is already running: `wsl -d` would otherwise start it, and
    # a memory log must never be the reason the VM is up.
    if ($vmmemWsl.Running) {
        $result = Invoke-WslExe -Arguments @('-d', $DistroName, '--exec', 'sh', '-c', 'cat /proc/meminfo; cat /proc/pressure/memory')
        if ($result.ExitCode -eq 0) {
            $meminfo = @{}
            $pressure = @{}
            foreach ($line in $result.Output) {
                if ($line -match '^(\w+):\s+(\d+) kB') {
                    $meminfo[$Matches[1]] = [double]$Matches[2] * 1KB
                }
                elseif ($line -match '^(some|full) .*avg300=([\d.]+)') {
                    $pressure[$Matches[1]] = $Matches[2]
                }
            }

            # A reply missing any field (an error line, a truncated read) is not a sample.
            $required = @('MemTotal', 'MemAvailable', 'Cached', 'Buffers', 'AnonPages', 'SwapTotal', 'SwapFree', 'Committed_AS')
            if (@($required | Where-Object { -not $meminfo.ContainsKey($_) }).Count -eq 0) {
                $row.WSL_TotalGB = ConvertTo-RoundedGb -Bytes $meminfo['MemTotal']
                $row.WSL_UsedGB = ConvertTo-RoundedGb -Bytes ($meminfo['MemTotal'] - $meminfo['MemAvailable'])
                $row.WSL_AvailGB = ConvertTo-RoundedGb -Bytes $meminfo['MemAvailable']
                $row.WSL_CacheGB = ConvertTo-RoundedGb -Bytes ($meminfo['Cached'] + $meminfo['Buffers'])
                $row.WSL_AnonGB = ConvertTo-RoundedGb -Bytes $meminfo['AnonPages']
                $row.WSL_SwapUsedGB = ConvertTo-RoundedGb -Bytes ($meminfo['SwapTotal'] - $meminfo['SwapFree'])
                $row.WSL_CommittedGB = ConvertTo-RoundedGb -Bytes $meminfo['Committed_AS']
                # Kernels built without PSI have no pressure file; those two stay empty.
                $row.WSL_PSISome300 = $pressure['some']
                $row.WSL_PSIFull300 = $pressure['full']
            }
        }
    }

    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    [pscustomobject]$row | Export-Csv -LiteralPath (Join-Path $LogDir 'samples.csv') -Append -NoTypeInformation
}
