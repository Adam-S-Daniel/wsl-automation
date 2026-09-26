# wsl-automation

PowerShell automation for a WSL2 Ubuntu distro on Windows:

- A staged, atomic-ish backup of the distro (`tar` or `vhdx`) with retention.
- A "keeper" that makes sure a Claude Code session with Remote Control
  enabled is running in the distro, coordinating with the backup via a lock
  file so the two never collide.
- A scheduled-task installer that wires both of the above into Windows Task
  Scheduler.

## What this is

`wsl-automation` is a small PowerShell 7.6+ module (`WslAutomation`) plus a
handful of thin wrapper scripts meant to be run directly or from Windows
Task Scheduler. It covers three jobs:

1. **Backup** - export a WSL distro (`wsl --export`) on a schedule, with
   staging, retention, and a log in the historical format.
2. **Session keeper** - periodically check whether a Claude Code session with
   Remote Control enabled is running inside the distro, and launch one (in a
   Windows Terminal tab) if not - but only after waiting for any in-progress
   backup to clear. Remote Control is the point: it is what lets you pick the
   session up from claude.ai or the phone without being at the machine.
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

2. **Background-keeper prerequisites (once per machine).** The session
   keeper runs as a background (session 0) task so its frequent check never
   flashes a window on the desktop. That imposes two one-time requirements:

   - **PowerShell 7 installed via MSI** (not the Microsoft Store build). A
     Store-packaged pwsh cannot be activated in session 0, so the keeper
     task needs a non-packaged pwsh at `C:\Program Files\PowerShell\7\`.
     Install it with `winget install --id Microsoft.PowerShell --scope
     machine` or the MSI from the PowerShell releases page. `register-tasks`
     prefers this path automatically and warns if only a Store pwsh is found.
   - **The "Log on as a batch job" right** for your account, which a
     background (S4U) task needs. On a machine where you are a local admin
     this is *not* covered by the default Administrators grant (an S4U logon
     gets a UAC-filtered token in which Administrators is deny-only). Grant
     it to your own account from an elevated prompt:

     ```powershell
     .\scripts\grant-keeper-batch-logon.ps1
     ```

3. Open an elevated PowerShell 7.6+ prompt (scheduled task registration
   needs administrator rights) and run the task installer, pointing it at
   where you want backups written:

   ```powershell
   cd C:\Users\<you>\repos\wsl-automation
   .\scripts\register-tasks.ps1 -BackupDir 'D:\Backups\wsl'
   ```

   This creates/updates the scheduled tasks described below. Re-running it is
   safe and idempotent - it will update the existing tasks in place rather
   than duplicating them.

## Task descriptions

### Backup task (default name: `WSL Ubuntu Daily Backup`)

`wsl --export` stops the distro it exports - tar or vhdx, in use or not (see
AGENTS.md's "wsl --export stops the running distro" section) - so this task
is built around not exporting out from under a live session, and around
retrying rather than waking straight into WSL's own post-wake transition
window.

- Runs `scripts\wsl-ubuntu-backup.ps1` daily at a fixed time (default 02:00),
  then **retries every `-BackupRetryIntervalMinutes` (default 60 minutes) for
  the following day** if that run didn't complete - any pre-existing logon or
  other triggers on the task are replaced with just this one. This replaces
  the previous `-StartWhenAvailable` catch-up, which used to fire a missed
  run the instant the machine came back from sleep, before `Invoke-WslBackup`
  had a chance to check anything.
- Settings: does **not** wake the machine to run (`-WakeToRun` is off by
  default) and does **not** use `-StartWhenAvailable` - the hourly retry
  above is what catches up a missed run instead. Has a 4 hour execution time
  limit and will not start a second instance while one is already running
  (`-MultipleInstances IgnoreNew`). Pass `-WakeBackupToRun` to register a
  *fresh* task with `-WakeToRun`; waking is off by default because on Modern
  Standby (S0 low-power idle) laptops a scheduled wake can hang the machine
  in a half-woken state - enable it only on hardware where scheduled wake is
  reliable, such as an S3-capable desktop. Re-running the installer against
  an *existing* backup task always forces `StartWhenAvailable` back to
  `$false` while leaving everything else on it (including `WakeToRun`) as it
  already was.
- Runs the backup interactively as the current user (needed for `wsl.exe`
  to reach the right WSL session).
- **Before every export**, `Invoke-WslBackup` runs three checks, in order:
  1. **Wake guard.** If fewer than `-MinMinutesSinceWake` (default 10)
     minutes have passed since the machine last booted or resumed from
     sleep, the run is deferred (`DeferredRecentWake`) and logs one line
     explaining why - `wsl --export` can otherwise fail outright while WSL is
     still transitioning (see AGENTS.md).
  2. **Force check.** Once the newest existing backup (any tag/format) is
     more than `-ForceAfterDays` (default 9; 0 disables this) days old, or
     none exists yet, the export is forced through regardless of activity -
     a persistently busy distro must not be allowed to postpone every backup
     forever.
  3. **Activity gate**, unless forced or `-IgnoreActivity` is passed: if the
     distro looks actively used (`Test-WslActivity` - see below), the run is
     deferred (`DeferredBusy`) rather than kill live work, and logs one line
     naming how many interactive processes and which command names (never
     raw arguments) made it look busy.

  A run that finds today's backup file already present returns `Skipped`
  with **no log line at all** - unlike the deferrals above, which do log one
  line each - since the hourly retry would otherwise add up to 23 identical
  "already exists" lines to the shared log every day.
- **What counts as activity** (`Test-WslActivity`, via `ps` inside the
  distro): any process with a real tty that isn't the Claude Code Remote
  Control session's own tty, or a `tmux`/`screen` multiplexer session (which
  commonly has no tty at all). The Remote Control session itself - the
  keeper's always-on session, kept alive so it can be driven from claude.ai
  or the phone - does **not** count as activity by itself. **Known
  limitation:** this only sees processes with a real pty; VS Code Remote -
  WSL and other tty-less work (for example a `nohup`'d dev server) are not
  detected as activity and will not defer a backup.
- **Immediately before the export**, once the lock is held, the Claude Code
  Remote Control session is stopped with `SIGTERM` (best-effort - a failure
  only logs). It doesn't count as activity and the keeper relaunches it
  within its own polling interval, so nothing is preserved by leaving it
  running through an export that is about to stop the whole distro anyway.

### Keeper task (default name: `Claude Code Session Keeper`)

- Runs `scripts\ensure-claude-session.ps1` on a repeating interval (default
  every 5 minutes), starting from midnight of the day it was registered.
- Runs as a **background (S4U) task in session 0** - "run whether the user
  is logged on or not", no stored password. This is what keeps the frequent
  check from ever flashing a console window on the desktop: session 0 has no
  interactive desktop to draw one on. (An interactive task with
  `-WindowStyle Hidden` still flashes briefly, because Task Scheduler creates
  the console window before pwsh can hide it.) See the prerequisites above -
  this mode needs an MSI pwsh and the batch-logon right.
- Settings: allowed to run on battery, won't stop if the machine switches
  to battery mid-run, 2 hour execution time limit, and will not start a
  second instance while one is already running.
- Because it runs in session 0 it cannot open a terminal itself; when no
  Remote Control session is running it triggers the launcher task below.

### Launcher task (default name: `Claude Code Session Launcher`)

- Has **no trigger of its own** - it only ever runs on demand, started by
  the background keeper when no Remote Control session is found.
- Runs **interactively** as the current user, so the Windows Terminal window
  it opens is visible on the desktop. Its action is `wt.exe` directly (not
  pwsh), selecting the distro's Windows Terminal profile (`-p <DistroName>`,
  for the correct icon/colours) and running
  `wsl.exe -d <DistroName> --cd ~ -- bash -l -c "cd ~/repos || cd ~ && exec claude --remote-control"`.
  The command is quoted so it reaches `bash -c` as one argument - unquoted,
  `--remote-control` becomes bash's `$0` and you get a plain local session the
  keeper never recognizes, so it relaunches every interval.
  Because it is a separate GUI process, opening a session never flashes a pwsh
  console either. It only produces a usable session when a user is logged on
  interactively at the console; it is not meant to work headlessly.
- The session opens in **`~/repos`** inside the distro. The `cd` is bash's job,
  not `wsl.exe`'s: `wsl --cd` takes only the bare `~`, an absolute Linux path
  starting with `/`, or an absolute Windows path, so `--cd ~/repos` would be
  read as a Windows path - and the absolute Linux path can't be hardcoded here
  because the distro username isn't known when the argument list is built.
  `|| cd ~` means a missing `~/repos` costs you the working directory, not the
  session: without it the failed `cd` would short-circuit the `&&`, the tab
  would close before `claude` started, and the keeper would reopen it every
  interval forever.

### Codex Cloud environment sync task (default name: `Codex Cloud Environment Sync`)

- Runs `scripts\sync-codex-cloud-environments.ps1` at exactly 00:00 and 12:00.
  A missed time remains missed; it does not use `-StartWhenAvailable` or wake
  the computer.
- Runs as a background S4U task for the current Windows user, is allowed on
  battery, has a 15 minute execution limit, and ignores a second overlapping
  instance. It uses the same MSI PowerShell and batch-logon prerequisites as
  the keeper.
- First checks that the selected WSL distro is already running. A stopped
  distro is skipped without invoking a distro command. When it is running, the
  task refreshes the authenticated Codex CLI state, pages through the Code
  Review repository inventory, and maps each repository to a connected GitHub
  connector by an exact repository-name lookup. It uses authenticated GitHub CLI
  metadata to skip forks, so only connected non-forks receive environments. Each
  environment has only its target repository selected, including the guidance
  repository's own environment. The enrolled repository setup provides
  `/workspace/_agent-guidance`. Setup and maintenance both run:

  ```bash
  set -euo pipefail
  cd /workspace/_agent-guidance
  npm ci
  CODEX_HOME="${CODEX_HOME:-/opt/codex}" \
    bash .claude/hooks/fleet-memory.sh --codex-cloud
  ```

  The reconciler requires `codex`, `curl`, `jq`, `flock`, and `mktemp` inside
  the distro. Its status output is aggregate-only and excludes account,
  repository, environment, and response-body data.
- The synchronizer calls Codex's private ChatGPT web API. That contract is not
  a public stability guarantee, so this script may need an update if Codex
  changes the environment or repository-discovery endpoints.
- Logs outcomes, without response data, to
  `%LOCALAPPDATA%\wsl-automation\codex-cloud-sync.log`.

### Legacy scripts

Any paths passed via `-LegacyScriptsToArchive` are renamed in place to
`<name>.superseded-<yyyyMMdd>` rather than deleted, so old ad-hoc scripts
this module replaces are preserved for reference but no longer picked up
by anything.

## Task history

Windows ships with the Task Scheduler operational log
(`Microsoft-Windows-TaskScheduler/Operational`, the "History" tab in Task
Scheduler) **disabled**. Without it, a scheduled task leaves only its last
result code behind - no start or finish times, no per-run exit codes, and no
record of a run that was terminated at its execution time limit. That gap is
exactly what made a failed Codex Cloud sync run on a new machine hard to
diagnose: the only evidence was a single result code, with no way to tell
when it ran or what it did before failing.

The installer (`scripts\register-tasks.ps1`, via
`Set-WslAutomationScheduledTasks`) enables this log once per run if it is
currently disabled. Pass `-SkipTaskHistory` to opt out. A failure to enable
it only warns - it never aborts task registration.

To read it, once enabled:

```powershell
Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational |
    Where-Object Message -match '<task name>'
```

Event IDs worth knowing:

- **100** - task instance started.
- **102** - task instance finished.
- **201** - action completed, with its return code.
- **329** - task terminated at its execution time limit (see AGENTS.md's
  "Never leave an interactive prompt in a scheduled-task code path" section -
  this is the signature of a hung `Read-Host` or other unattended prompt, not
  a slow run).

To enable it by hand, from an elevated prompt, without running the
installer:

```powershell
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
```

## Keeper semantics

- A "Claude session" is a running `claude` process **whose command line
  carries `--remote-control`**, checked with `pgrep -af claude` inside the
  distro. Infrastructure helper processes - `claude daemon run`,
  `claude bg-pty-host`, `claude bg-spare` - are explicitly excluded from the
  count, since their presence does not mean an interactive session exists.
- A plain `claude` session you opened by hand does **not** satisfy the keeper.
  It cannot be driven remotely, which is the only reason the keeper exists, so
  the keeper opens a Remote Control session alongside it. Expect a second tab
  in that case; that is the intended behavior, not a duplicate-launch bug.
- The check reads the process command line, so a session where Remote Control
  was turned on from *inside* it (the `/remote-control` command rather than the
  flag) is not detected. That costs an extra session, never a missing one.
- The keeper **never boots a stopped distro** just to check or launch a
  session - if the distro isn't already `Running`, it does nothing.
- The launch is performed by the interactive launcher task (see above),
  which uses Windows Terminal (`wt.exe`) to open a new tab, so it only
  produces a usable, visible session when a user is logged on interactively
  at the console; it is not meant to work headlessly.
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

- PowerShell 7.6 or later. For the background keeper specifically, an **MSI**
  install of PowerShell 7 (`C:\Program Files\PowerShell\7\`) - a Store-packaged
  pwsh cannot run in the session 0 the keeper uses.
- Windows (Task Scheduler integration and `wt.exe` launch are
  Windows-only; the module's non-scheduling functions are otherwise plain
  PowerShell 7.6+).
- The "Log on as a batch job" right for the account running the keeper (see
  `scripts\grant-keeper-batch-logon.ps1`).
- WSL2 with the distro you want to back up / keep alive already installed.
- For Codex Cloud synchronization: authenticated Codex and GitHub CLIs, plus
  `curl`, `jq`, `flock`, and `mktemp` in that distro.
