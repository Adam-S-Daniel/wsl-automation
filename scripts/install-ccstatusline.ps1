#requires -Version 7.6
<#
.SYNOPSIS
    One-shot installer for the Windows ccstatusline runtime and Claude Code statusLine entry.

.DESCRIPTION
    The ccstatusline config sync task copies only the layout. Windows Claude Code also needs a
    Windows runtime (Bun plus the ccstatusline npm package) and a statusLine entry in
    %USERPROFILE%\.claude\settings.json. This script sets both up:

      1. Finds bun.exe (PATH, then the winget package folder), installing Bun with winget
         (user scope) when it is missing.
      2. Runs `bun add -g ccstatusline@<version>`.
      3. Adds the statusLine entry (and env.CCSTATUSLINE_WIDTH, when absent) to settings.json
         with Set-CcstatuslineStatusLine, which backs the file up first.

    Run it from a normal (non-elevated) PowerShell 7 prompt. It is idempotent: re-running it
    leaves an up-to-date install alone. The Bun and ccstatusline versions are pinned exactly and
    bumped by hand, taking the newest release that is at least 7 days old.

.PARAMETER BunVersion
    Exact Bun version to install with winget when bun.exe is not found. Defaults to '1.4.2'.

.PARAMETER CcstatuslineVersion
    Exact ccstatusline npm package version to install. Defaults to '2.2.30'.

.PARAMETER Width
    Value for env.CCSTATUSLINE_WIDTH, written only when settings.json has no such key. Defaults
    to '130'.

.PARAMETER Force
    Replace an existing statusLine in settings.json that differs from the ccstatusline one. The
    file is backed up first.

.EXAMPLE
    ./install-ccstatusline.ps1

    Installs Bun and ccstatusline if needed and points Windows Claude Code's statusLine at it.
#>
[CmdletBinding()]
param(
    [string]$BunVersion = '1.4.2',

    [string]$CcstatuslineVersion = '2.2.30',

    [string]$Width = '130',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WslAutomation') -Force

function Find-BunExe {
    $command = Get-Command bun -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }
    $wingetPattern = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Oven-sh.Bun_*\bun-windows-x64\bun.exe'
    $match = Get-ChildItem -Path $wingetPattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) {
        return $match.FullName
    }
    return $null
}

$bunExe = Find-BunExe
if (-not $bunExe) {
    Write-Information -MessageData "installing Bun $BunVersion with winget" -InformationAction Continue
    winget install --id Oven-sh.Bun --version $BunVersion --scope user --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install of Bun failed with exit code $LASTEXITCODE"
    }
    $bunExe = Find-BunExe
    if (-not $bunExe) {
        throw 'Bun was installed but bun.exe could not be found'
    }
}

# The ccstatusline.exe shim bun creates needs `bun` on PATH, and winget only updates the user PATH
# for processes started afterwards, so add bun's directory to this process now.
$env:Path = "$(Split-Path -Path $bunExe -Parent)$([System.IO.Path]::PathSeparator)$env:Path"

& $bunExe add -g "ccstatusline@$CcstatuslineVersion"
if ($LASTEXITCODE -ne 0) {
    throw "bun add -g ccstatusline@$CcstatuslineVersion failed with exit code $LASTEXITCODE"
}

$result = Set-CcstatuslineStatusLine -Width $Width -Force:$Force
Write-Information -MessageData "ccstatusline statusLine: $($result.Status)" -InformationAction Continue
if ($result.Status -eq 'Conflict') {
    Write-Warning "$($result.SettingsPath) already has a different statusLine; re-run with -Force to replace it (the file is backed up first)."
}
elseif ($result.Status -eq 'SettingsInvalid') {
    throw "$($result.SettingsPath) is not valid JSON; fix it and re-run"
}

Write-Information -MessageData 'Restart Windows Terminal and any Windows Claude Code sessions so they pick up the new PATH.' -InformationAction Continue
