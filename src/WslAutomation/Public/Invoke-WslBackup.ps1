#requires -Version 7.6

function Invoke-WslBackup {
    <#
    .SYNOPSIS
        Exports a WSL distro to a backup file via a local staging area, with retention pruning.

    .DESCRIPTION
        Invoke-WslBackup exports the given WSL distro (tar or vhdx) to a local staging
        directory first, then atomically moves the completed export into the final
        backup directory. Staging avoids exporting a large file directly into a
        OneDrive-synced (or similarly watched) destination, which would otherwise
        cause continuous partial-file re-sync churn.

        A backup.lock file is held for the duration of the export so other
        automation (for example Invoke-ClaudeSessionKeeper) can detect that a
        backup is in progress and wait rather than interrupt it.

        On success, old backups beyond -RetentionCount are pruned per tag
        (daily/weekly) and the set of retained backups is logged.

        Throws a terminating error on any failure; callers should not rely on a
        returned "failed" status.

    .PARAMETER BackupDir
        Directory the finished backup file is written to. Created if missing.

    .PARAMETER DistroName
        Name of the WSL distro to export. Defaults to 'Ubuntu'.

    .PARAMETER Format
        Export format: 'tar' or 'vhdx'. Defaults to 'tar'.

    .PARAMETER StagingDir
        Local scratch directory the export is written to before being moved into
        BackupDir. Defaults to a 'wsl-backup-staging' folder under the current
        user's temp directory.

    .PARAMETER LogFile
        Path to the log file this run appends to. Defaults to a
        'wsl-<distro>-backup.log' file inside BackupDir.

    .PARAMETER RetentionCount
        Number of backups to keep per tag (daily/weekly). Older backups beyond
        this count are deleted. Defaults to 2.

    .PARAMETER LockPath
        Path to the backup lock file. Defaults to the module's standard lock
        path under $env:LOCALAPPDATA.

    .EXAMPLE
        Invoke-WslBackup -BackupDir 'C:\Backups\WSL'

        Exports the 'Ubuntu' distro as a tar file into C:\Backups\WSL, staging it
        locally first.

    .EXAMPLE
        Invoke-WslBackup -BackupDir 'C:\Backups\WSL' -Format vhdx -RetentionCount 4

        Exports as a VHDX and keeps the newest 4 daily and newest 4 weekly backups.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$BackupDir,

        [string]$DistroName = 'Ubuntu',

        [ValidateSet('tar', 'vhdx')]
        [string]$Format = 'tar',

        [string]$StagingDir = (Join-Path ([IO.Path]::GetTempPath()) 'wsl-backup-staging'),

        [string]$LogFile = (Join-Path $BackupDir "wsl-$($DistroName.ToLowerInvariant())-backup.log"),

        [int]$RetentionCount = 2,

        [string]$LockPath = (Get-WslBackupLockPath)
    )

    Write-WslAutomationLog -Message "=== WSL backup starting (distro=$DistroName format=$Format) ===" -LogFile $LogFile

    # Step 1: compute prefix / tag / final file name.
    $prefix = "wsl-$($DistroName.ToLowerInvariant())"
    $now = Get-Date
    $tag = if ($now.DayOfWeek -eq [System.DayOfWeek]::Sunday) { 'weekly' } else { 'daily' }
    $dateStamp = $now.ToString('yyyy-MM-dd')
    $FileName = "$prefix-$tag-$dateStamp.$Format"
    $finalPath = Join-Path $BackupDir $FileName

    # Step 2: ensure directories exist.
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $StagingDir)) {
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }

    # Step 3: skip-guard.
    if (Test-Path -LiteralPath $finalPath) {
        Write-WslAutomationLog -Message "Already exists ($FileName) - skipping." -LogFile $LogFile
        $existingItem = Get-Item -LiteralPath $finalPath
        $skipSizeMB = [math]::Round($existingItem.Length / 1MB, 2)
        return [pscustomobject]@{
            Status   = 'Skipped'
            FilePath = $finalPath
            SizeMB   = $skipSizeMB
        }
    }

    # Step 4: clean stale staging artifacts from prior runs.
    Get-ChildItem -Path $StagingDir -Filter "$prefix-*.$Format" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $StagingDir -Filter '*.partial' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # A hard kill (ExecutionTimeLimit, power loss) mid Move-Item (step 9) can orphan a
    # "<name>.<Format>.partial" file directly in BackupDir. Nothing else in this function ever
    # revisits BackupDir looking for these - the retention filter and the retained-listing
    # extension check both exclude ".partial" - so left alone they persist forever, consuming
    # disk/OneDrive quota. Sweep any such leftovers here, before every export.
    Get-ChildItem -Path $BackupDir -Filter "$prefix-*.$Format.partial" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Step 5: acquire the backup lock; everything after this runs in try/finally.
    New-WslBackupLock -LockPath $LockPath -DistroName $DistroName | Out-Null

    try {
        $stagingPath = Join-Path $StagingDir $FileName

        # Step 6: run the export.
        $exportArgs = @('--export', $DistroName, $stagingPath)
        if ($Format -eq 'vhdx') {
            $exportArgs += '--vhd'
        }
        $result = Invoke-WslExe -Arguments $exportArgs

        # Step 7: handle export failure.
        if ($result.ExitCode -ne 0) {
            Write-WslAutomationLog -Message "ERROR: wsl --export failed (exit $($result.ExitCode))" -LogFile $LogFile
            Write-WslAutomationLog -Message "  args: wsl $($exportArgs -join ' ')" -LogFile $LogFile
            foreach ($line in $result.Output) {
                $trimmedLine = "$line".Trim()
                if ($trimmedLine) {
                    Write-WslAutomationLog -Message "  wsl: $trimmedLine" -LogFile $LogFile
                }
            }
            if (Test-Path -LiteralPath $stagingPath) {
                Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
            }
            throw "wsl --export failed (exit $($result.ExitCode))"
        }

        # Step 8: verify the staging file landed and is non-empty.
        $stagingItem = Get-Item -LiteralPath $stagingPath -ErrorAction SilentlyContinue
        if (-not $stagingItem -or $stagingItem.Length -le 0) {
            Write-WslAutomationLog -Message "ERROR: staging file missing or empty after export ($stagingPath)" -LogFile $LogFile
            throw "Staging file missing or empty after export: $stagingPath"
        }

        # Step 9: move into place via a two-step move + rename.
        $finalPartialPath = "$finalPath.partial"
        try {
            Move-Item -LiteralPath $stagingPath -Destination $finalPartialPath -Force
            Rename-Item -LiteralPath $finalPartialPath -NewName $FileName -Force
        }
        catch {
            if (Test-Path -LiteralPath $finalPartialPath) {
                Remove-Item -LiteralPath $finalPartialPath -Force -ErrorAction SilentlyContinue
            }
            Write-WslAutomationLog -Message "ERROR: failed to move backup into place: $($_.Exception.Message)" -LogFile $LogFile
            throw
        }

        # Step 10: log completion size.
        $finalItem = Get-Item -LiteralPath $finalPath
        $sizeMB = [math]::Round($finalItem.Length / 1MB, 2)
        Write-WslAutomationLog -Message "Export complete: $sizeMB MB" -LogFile $LogFile

        # Step 11: retention pruning per tag.
        foreach ($retentionTag in @('daily', 'weekly')) {
            $matchingBackups = Get-ChildItem -Path $BackupDir -Filter "$prefix-$retentionTag-*.$Format" -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name -Descending
            $backupsToRemove = $matchingBackups | Select-Object -Skip $RetentionCount
            foreach ($oldBackup in $backupsToRemove) {
                Write-WslAutomationLog -Message "Removing old $retentionTag backup: $($oldBackup.Name)" -LogFile $LogFile
                Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # Step 12: list retained backups (both formats, any tag).
        Write-WslAutomationLog -Message 'Retained:' -LogFile $LogFile
        $retainedBackups = Get-ChildItem -Path $BackupDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$prefix-*" -and ($_.Extension -eq '.tar' -or $_.Extension -eq '.vhdx') } |
            Sort-Object -Property Name -Descending
        foreach ($retainedItem in $retainedBackups) {
            $retainedSizeMB = [math]::Round($retainedItem.Length / 1MB, 2)
            $retainedStamp = $retainedItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Write-WslAutomationLog -Message "  $($retainedItem.Name)  [$retainedSizeMB MB]  $retainedStamp" -LogFile $LogFile
        }

        # Step 13: done.
        Write-WslAutomationLog -Message '=== Done ===' -LogFile $LogFile

        return [pscustomobject]@{
            Status   = 'Completed'
            FilePath = $finalPath
            SizeMB   = $sizeMB
        }
    }
    finally {
        Remove-WslBackupLock -LockPath $LockPath
    }
}
