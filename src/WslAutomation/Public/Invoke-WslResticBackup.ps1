#requires -Version 7.6

function Invoke-WslResticBackup {
    <#
    .SYNOPSIS
        Backs up a running WSL distro with restic, live, then copies the repository one way into
        a OneDrive-synced backup directory.

    .DESCRIPTION
        Invoke-WslResticBackup runs scripts/wsl-restic-backup.sh inside the running distro as
        root. That script backs up / into a restic repository on the local Windows disk, applies
        the retention policy, and checks the repository. Unlike 'wsl --export' (Invoke-WslBackup,
        now a manual-only command), it never stops the distro, so running Claude Code sessions
        and anything else in the distro survive the backup. See AGENTS.md's "The daily backup is
        a live restic backup, not wsl --export" section.

        In order:

        1. A skip guard: when -StatePath already holds today's date, the backup already
           completed today and this returns 'Skipped' with NO log line - the backup task's hourly
           retry trigger (see Set-WslAutomationScheduledTasks) would otherwise add up to 23
           identical lines to the log every day.
        2. A wake guard: too soon after a boot or a resume from sleep (Get-LastWakeTime,
           -MinMinutesSinceWake), WSL may still be transitioning, so the run is deferred
           ('DeferredRecentWake') and logs one line. The next hourly retry tries again.
        3. The script runs through Invoke-WslExe as:

               wsl.exe -d <distro> -u root --cd <ScriptsDir> --exec /bin/bash ./wsl-restic-backup.sh
                   <repo as /mnt path> <PasswordFile> ./wsl-restic-excludes.txt <none|weekly>

           Maintenance is 'weekly' on -WeeklyMaintenanceDay, which adds 'restic forget --prune'
           and 'restic check --read-data-subset=5%'; every other day is 'none'.
        4. Its exit code is logged with what it means, along with only the summary lines of its
           output (lines starting "Added to the repository", "processed " or "errors="). No
           other output line is ever logged: restic's output can carry file paths. Exit 0 is OK
           and exit 10 is PARTIAL (a snapshot was saved, but some files were unreadable); any
           other exit code is logged and thrown.
        5. The repository is copied one way into (Join-Path -BackupDir 'restic') through
           Invoke-RobocopyExe, in an order that guarantees OneDrive never sees a snapshot whose
           data has not arrived yet:

           a. everything except snapshots\ (/E, never deletes: new packs and index files,
              keys, config);
           b. snapshots\ (/MIR, so snapshots that 'restic forget' removed go too);
           c. only on the weekly maintenance run, which pruned: index\ then data\ (/MIR), which
              removes the index files and packs the prune deleted.

           A robocopy exit code of 8 or more is a failure: it is logged and thrown. Robocopy's
           own output is never logged, since it can carry paths.
        6. On full success, today's date is written to -StatePath.

        This deliberately does NOT take the backup.lock that Invoke-WslBackup holds around its
        export. That lock exists so Invoke-ClaudeSessionKeeper waits instead of launching a
        session into a distro an export is about to stop. A restic backup stops nothing, so
        there is nothing for the keeper to wait out - holding the lock would only delay the
        keeper for no reason.

        Throws a terminating error on any failure; callers should not rely on a returned
        "failed" status.

    .PARAMETER BackupDir
        The OneDrive-synced backup directory. The repository copy goes to its 'restic'
        subdirectory, and the log defaults to a file in it.

    .PARAMETER RepoDir
        The restic repository on a local Windows drive, for example 'D:\Backups\wsl-restic'.
        It must be a drive-letter path: inside the distro it is reached at its /mnt/<drive>
        path (see ConvertTo-WslMountPath, which assumes WSL's default /mnt automount root).

    .PARAMETER DistroName
        Name of the WSL distro to back up. Defaults to 'Ubuntu'.

    .PARAMETER ScriptsDir
        Windows path of this repository's scripts directory, which holds wsl-restic-backup.sh
        and wsl-restic-excludes.txt. Defaults to the scripts directory next to this module.

    .PARAMETER PasswordFile
        Path, inside the distro, of the file holding the repository password. Defaults to
        '/root/.config/restic/password'. It is passed to restic with --password-file and never
        logged.

    .PARAMETER LogFile
        Path to the log file this run appends to. Defaults to a 'wsl-<distro>-backup.log' file
        inside BackupDir - the same log Invoke-WslBackup writes.

    .PARAMETER StatePath
        File holding the date (yyyy-MM-dd) of the last fully successful run. Defaults to
        "$env:LOCALAPPDATA\wsl-automation\restic-last-success.txt".

    .PARAMETER MinMinutesSinceWake
        Minimum number of minutes that must have passed since this machine last booted or
        resumed from sleep before the backup runs. Defaults to 10.

    .PARAMETER WeeklyMaintenanceDay
        The day of the week the run also prunes and reads a 5% sample of the repository data.
        Defaults to Sunday.

    .EXAMPLE
        Invoke-WslResticBackup -BackupDir 'C:\Users\<you>\OneDrive\Backups\WSL' -RepoDir 'D:\Backups\wsl-restic'

        Backs up the running 'Ubuntu' distro into D:\Backups\wsl-restic and copies the
        repository into the OneDrive folder's 'restic' subdirectory.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessage(
        'PSAvoidUsingPlainTextForPassword',
        '',
        Justification = 'A path to the root-only password file inside the distro, not the password itself.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$BackupDir,

        [Parameter(Mandatory)]
        [string]$RepoDir,

        [string]$DistroName = 'Ubuntu',

        [string]$ScriptsDir = ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' 'scripts'))),

        [string]$PasswordFile = '/root/.config/restic/password',

        [string]$LogFile = (Join-Path $BackupDir "wsl-$($DistroName.ToLowerInvariant())-backup.log"),

        [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'wsl-automation' 'restic-last-success.txt'),

        [int]$MinMinutesSinceWake = 10,

        [System.DayOfWeek]$WeeklyMaintenanceDay = [System.DayOfWeek]::Sunday
    )

    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')

    # Step 1: skip guard, ahead of everything else and with NO log line - the hourly retry
    # trigger would otherwise log the same "already done" line up to 23 times a day.
    if ((Test-Path -LiteralPath $StatePath) -and "$(Get-Content -LiteralPath $StatePath -Raw)".Trim() -eq $today) {
        return [pscustomobject]@{
            Status   = 'Skipped'
            ExitCode = $null
        }
    }

    # Step 2: wake guard, as in Invoke-WslBackup. WSL can still be transitioning for a few
    # minutes after a boot or a resume (see AGENTS.md); the next hourly retry tries again.
    $lastWakeTime = Get-LastWakeTime
    $minutesSinceWake = ((Get-Date) - $lastWakeTime).TotalMinutes
    if ($minutesSinceWake -lt $MinMinutesSinceWake) {
        $roundedMinutesSinceWake = [math]::Floor($minutesSinceWake)
        Write-WslAutomationLog -Message "Deferred: only $roundedMinutesSinceWake min since boot/resume (need $MinMinutesSinceWake)" -LogFile $LogFile
        return [pscustomobject]@{
            Status   = 'DeferredRecentWake'
            ExitCode = $null
        }
    }

    # Step 3: the repository as the distro sees it. Throws on a UNC or relative path.
    $repoLinuxPath = ConvertTo-WslMountPath -Path $RepoDir
    $maintenance = if ($now.DayOfWeek -eq $WeeklyMaintenanceDay) { 'weekly' } else { 'none' }

    # Step 4: run the backup inside the distro, as root so every file under / is readable.
    # --cd makes the scripts directory the working directory, so the script and the excludes
    # file are passed relative to it.
    Write-WslAutomationLog -Message '=== WSL restic backup starting ===' -LogFile $LogFile
    Write-WslAutomationLog -Message "distro=$DistroName maintenance=$maintenance" -LogFile $LogFile
    $resticArgs = @(
        '-d', $DistroName, '-u', 'root', '--cd', $ScriptsDir, '--exec', '/bin/bash', './wsl-restic-backup.sh',
        $repoLinuxPath, $PasswordFile, './wsl-restic-excludes.txt', $maintenance
    )
    $result = Invoke-WslExe -Arguments $resticArgs

    # Step 5: log the exit code, what it means, and only the summary lines. Every other output
    # line is dropped unlogged - restic's output can carry file paths.
    $exitMeanings = @{
        0  = 'OK'
        10 = 'PARTIAL: snapshot saved, but some files were unreadable'
        2  = 'invalid arguments to wsl-restic-backup.sh'
        20 = 'restic is not installed in the distro'
        21 = 'restic password file or repository missing'
        30 = 'restic backup failed'
        40 = 'restic forget/prune failed'
        50 = 'restic check failed'
    }
    $exitCode = $result.ExitCode
    $meaning = if ($exitMeanings.ContainsKey($exitCode)) { $exitMeanings[$exitCode] } else { 'unexpected exit code' }
    Write-WslAutomationLog -Message "restic script exit $exitCode ($meaning)" -LogFile $LogFile
    foreach ($line in $result.Output) {
        $trimmedLine = "$line".Trim()
        if ($trimmedLine.StartsWith('Added to the repository') -or $trimmedLine.StartsWith('processed ') -or $trimmedLine.StartsWith('errors=')) {
            Write-WslAutomationLog -Message "  restic: $trimmedLine" -LogFile $LogFile
        }
    }

    if ($exitCode -ne 0 -and $exitCode -ne 10) {
        Write-WslAutomationLog -Message "ERROR: restic backup failed (exit $exitCode): $meaning" -LogFile $LogFile
        throw "restic backup failed (exit $exitCode): $meaning"
    }

    # Step 6: one-way copy into the OneDrive-synced directory. The order is what keeps the copy
    # consistent at every instant OneDrive might upload it: packs and index files land before
    # the snapshot files that reference them, and only the weekly prune's deletions are
    # mirrored, after the snapshots that needed the deleted data are already gone.
    # locks/ is never copied: a lock caught mid-run would sit in the copy as a stale lock.
    # The repository's subdirectories are built as plain strings: Join-Path resolves the drive
    # and throws when it does not exist in this session. A trailing backslash is trimmed so a
    # path never ends in one inside robocopy's quoted arguments.
    $repoRoot = $RepoDir.TrimEnd('\')
    $copyDir = Join-Path $BackupDir 'restic'
    $robocopyOptions = @('/R:2', '/W:5', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $copySteps = @(
        @{ Name = 'repository (except snapshots)'; Arguments = @($repoRoot, $copyDir, '/E', '/XD', "$repoRoot\snapshots", "$repoRoot\locks") },
        @{ Name = 'snapshots'; Arguments = @("$repoRoot\snapshots", (Join-Path $copyDir 'snapshots'), '/MIR') }
    )
    if ($maintenance -eq 'weekly') {
        $copySteps += @(
            @{ Name = 'index'; Arguments = @("$repoRoot\index", (Join-Path $copyDir 'index'), '/MIR') },
            @{ Name = 'data'; Arguments = @("$repoRoot\data", (Join-Path $copyDir 'data'), '/MIR') }
        )
    }
    foreach ($copyStep in $copySteps) {
        $copyResult = Invoke-RobocopyExe -Arguments ($copyStep.Arguments + $robocopyOptions)
        # Robocopy exit codes 0-7 are success; 8 and up mean at least one copy failed. Its output
        # is never logged - it can carry paths.
        if ($copyResult.ExitCode -ge 8) {
            Write-WslAutomationLog -Message "ERROR: robocopy of the restic $($copyStep.Name) to the backup dir failed (exit $($copyResult.ExitCode))" -LogFile $LogFile
            throw "robocopy of the restic $($copyStep.Name) failed (exit $($copyResult.ExitCode))"
        }
    }

    # Step 7: record today's success, so the remaining hourly retries skip silently.
    $stateDir = Split-Path -Path $StatePath -Parent
    if ($stateDir -and -not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    Set-Content -LiteralPath $StatePath -Value $today -NoNewline
    Write-WslAutomationLog -Message 'restic backup complete (copy to OneDrive dir done)' -LogFile $LogFile

    return [pscustomobject]@{
        Status   = if ($exitCode -eq 10) { 'CompletedPartial' } else { 'Completed' }
        ExitCode = $exitCode
    }
}
