# wsl-automation

PowerShell automation for a WSL2 Ubuntu distro on Windows:

- A staged, atomic-ish backup of the distro (`tar` or `vhdx`) with retention.
- A "keeper" that makes sure a Claude Code session is running in the distro,
  coordinating with the backup via a lock file so the two never collide.
- A scheduled-task installer that wires both of the above into Windows Task
  Scheduler.

## What this is

`wsl-automation` is a small PowerShell 7.6+ module (`WslAutomation`) plus a
handful of thin wrapper scripts meant to be run directly or from Windows
Task Scheduler. It covers three jobs:

1. **Backup** - export a WSL distro (`wsl --export`) on a schedule, with
   staging, retention, and a log in the historical format.
2. **Session keeper** - periodically check whether a Claude Code session is
   running inside the distro, and launch one (in a Windows Terminal tab) if
   not - but only after waiting for any in-progress backup to clear.
3. **Task registration** - create or update the two Scheduled Tasks above
   idempotently, and archive any legacy ad-hoc scripts they replace.

## Why staging

Exporting a large distro (tens of GB) directly into a folder that a sync
client (OneDrive or similar) is watching causes the sync client to see the
destination file grow continuously and re-upload partial versions of it,
often for the entire duration of the export. That's a lot of wasted
bandwidth and churn for a file that is only valid once it's complete.

To avoid this, the export target is first written to a local staging
directory (by default under the system TEMP directory, which a sync client
is not watching). Once the export finishes successfully, the file is moved
into the real backup directory in two steps:

1. `Move-Item` the staged file to `<final-name>.partial` in the backup
   directory.
2. `Rename-Item` `<final-name>.partial` to `<final-name>`.

The rename is a fast, local metadata operation, so the sync client only
ever observes the final file appearing complete in one step - never a
partially-written file at the name it actually watches.

## Lock protocol

The backup and the session keeper share a simple JSON lock file so the
keeper never launches a session while a backup export is in flight (and
vice versa, if you choose to gate the backup on session activity too).

- **Default path**: `%LOCALAPPDATA%\wsl-automation\backup.lock`
  (override with `-LockPath` on any function that accepts it).
- **Shape**:

  ```json
  {
    "ProcessId": 12345,
    "StartedUtc": "2026-07-17T02:00:00.0000000Z",
    "DistroName": "Ubuntu"
  }
  ```

- **Lifecycle**: `Invoke-WslBackup` creates the lock right before calling
  `wsl --export` and removes it in a `finally` block, so it is cleaned up
  whether the export succeeds or throws.
- **Staleness**: a lock older than `-StaleMinutes` (default 240 minutes / 4
  hours) is considered stale - a backup that should have finished long ago,
  most likely left over from a crash or a machine sleep/resume in the
  middle of an export. `Invoke-ClaudeSessionKeeper` treats a stale lock as
  if there were no lock at all: it logs a note, removes the lock, and
  proceeds.
- **Waiting**: when the lock is present and fresh, the keeper polls (every
  `-PollSeconds`, default 30s) for up to `-MaxWaitMinutes` (default 60)
  before giving up on waiting and proceeding anyway (logging a warning).
  This bounds how long a stuck backup can delay session availability.

## Install

1. Clone this repository anywhere on the machine, for example:

   ```
   C:\Users\<you>\repos\wsl-automation
   ```

2. Open an elevated PowerShell 7.6+ prompt (scheduled task registration
   needs administrator rights) and run the task installer, pointing it at
   where you want backups written:

   ```powershell
   cd C:\Users\<you>\repos\wsl-automation
   .\scripts\register-tasks.ps1 -BackupDir 'D:\Backups\wsl'
   ```

   This creates/updates the two scheduled tasks described below. Re-running
   it is safe and idempotent - it will update the existing tasks in place
   rather than duplicating them.

## Task descriptions

### Backup task (default name: `WSL Ubuntu Daily Backup`)

- Runs `scripts\wsl-ubuntu-backup.ps1` once a day at a fixed time (default
  02:00), via a single daily trigger (any pre-existing logon or other
  triggers on the task are replaced with just this one).
- Settings: does **not** wake the machine to run by default - it starts as
  soon as possible once the machine is next awake if the scheduled time was
  missed (`-StartWhenAvailable`), has a 4 hour execution time limit, and
  will not start a second instance while one is already running
  (`-MultipleInstances IgnoreNew`). Pass `-WakeBackupToRun` to register it
  with `-WakeToRun` instead. Waking is off by default because on Modern
  Standby (S0 low-power idle) laptops a scheduled wake can hang the machine
  in a half-woken state; enable it only on hardware where scheduled wake is
  reliable, such as an S3-capable desktop.
- Runs the backup interactively as the current user (needed for `wsl.exe`
  to reach the right WSL session).

### Keeper task (default name: `Claude Code Session Keeper`)

- Runs `scripts\ensure-claude-session.ps1` on a repeating interval (default
  every 5 minutes), starting from midnight of the day it was registered.
- Settings: allowed to run on battery, won't stop if the machine switches
  to battery mid-run, 2 hour execution time limit, and will not start a
  second instance while one is already running.
- Also runs interactively as the current user (a Claude Code session
  launched in the background under a service account would not be visible
  or usable).

### Legacy scripts

Any paths passed via `-LegacyScriptsToArchive` are renamed in place to
`<name>.superseded-<yyyyMMdd>` rather than deleted, so old ad-hoc scripts
this module replaces are preserved for reference but no longer picked up
by anything.

## Keeper semantics

- A "Claude session" is a running `claude` process, checked with
  `pgrep -af claude` inside the distro. Infrastructure helper processes -
  `claude daemon run`, `claude bg-pty-host`, `claude bg-spare` - are
  explicitly excluded from the count, since their presence does not mean
  an interactive session exists.
- The keeper **never boots a stopped distro** just to check or launch a
  session - if the distro isn't already `Running`, it does nothing.
- Because the launch uses Windows Terminal (`wt.exe`) to open a new tab,
  it only produces a usable, visible session when a user is logged on
  interactively at the console; it is not meant to work headlessly.
- If a backup lock is present and fresh, the keeper waits (see "Lock
  protocol" above) rather than launching a session immediately, so a
  freshly-launched `claude` process never competes with an in-progress
  `wsl --export` for distro resources. After the configured maximum wait
  it proceeds anyway rather than waiting forever.

## Testing

Tests are written in Pester v5 syntax and are compatible with both Pester
5.7.1 and 6.0.0. From the repository root:

```powershell
Invoke-Pester ./tests
```

No test invokes real `wsl.exe` - every test mocks the module's
`Invoke-WslExe` seam - and all filesystem paths used by the tests live
under Pester's `TestDrive:`.

## Requirements

- PowerShell 7.6 or later.
- Windows (Task Scheduler integration and `wt.exe` launch are
  Windows-only; the module's non-scheduling functions are otherwise plain
  PowerShell 7.6+).
- WSL2 with the distro you want to back up / keep alive already installed.
