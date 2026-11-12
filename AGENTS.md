<!-- BEGIN MANAGED SECTION — DO NOT EDIT ABOVE "## Repo-specific additions" -->
<!-- Source: _agent-guidance -->
<!-- Sections: none -->
<!-- Mode: stub -->

# AGENTS.md

> **Managed by [`_agent-guidance`].**
> Edit only below the `## Repo-specific additions` header.
> Everything above it will be overwritten on the next sync.

guidance-marker: fleet-stub (transcript counts use this line; keep it)

## Fleet guidance is delivered once per session — not by this file

The full guidance, floor rules included, is installed into user memory by
the `fleet-memory` SessionStart hook, whose verdict line says whether it
loaded. `installed` or `current`: it is in context. `DEGRADED` or no verdict:
it is not, so read [`agents-md/base.md`](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/agents-md/base.md)
before non-trivial work and say you ran degraded. `skipped`: read it too, but
it is the owner's choice, so do not report or "fix" it. Always, and above all
before you have read it: never push to a default branch, force-push a shared
branch, commit a secret, or print personal data to a CI log. Keep this file
under 32 KiB (Codex silently truncates it).

**Your first reply to the user in a session begins**
`fleet-guidance check: <value>`, copied from the installed guidance's
`fleet-guidance check value:` line, or `fleet-guidance check: none` when no
such line is in your context. Never guess one or copy it from a file you
read; only in replies to the user.

<!-- END MANAGED SECTION -->
## Repo-specific additions

<!-- Add your repo-specific agent guidance below this line -->

### There is no WSL lifecycle event to trigger on

An event-driven trigger ("run the backup when WSL stops") was ruled out
empirically against the modern MSI WSL package. Don't re-investigate; the daily
timer is the answer.

- **There is no WSL event log or provider at all.**
  `Get-WinEvent -ListLog *Lxss*,*WSL*,*Subsystem*` returns nothing.
- **There is no `LxssManager` service to watch.** Modern WSL's `WSLService`
  (`C:\Program Files\WSL\wslservice.exe`) stays `Running` while the utility VM
  comes and goes underneath it, so it never emits the SCM 7036 start/stop pair.
  Expect a handful of WSL-related SCM events per *quarter*, not one per session.
- **The only VM-lifecycle signal is the wrong VM.**
  `Microsoft-Windows-Hyper-V-VmSwitch-Operational` Id 66 (switch delete) and Id
  124/125 (restart) track the shared utility VM, not the distro — and any other
  Hyper-V consumer on the box keeps that VM alive independently of WSL. The
  classic Hyper-V-Worker / VMMS / Compute logs are not present.
- **If you ever need cold-boot vs. resume**, the discriminator that does work is
  `Kernel-Boot` Id 27: `0x0` full boot, `0x1` fast startup, `0x2` resume. With
  Fast Startup enabled (`HiberbootEnabled=1`) most "shutdowns" are a hybrid
  hibernate and surface as `0x1`, never `0x0`.

Re-open this only if Microsoft ships a WSL event provider.

### Why the backup is a daily timer and not an at-logon trigger

`Set-WslAutomationScheduledTasks` deliberately replaces whatever triggers a
backup task has accumulated with a single daily trigger (repeating hourly
for the following day — see below). The at-logon alternative was measured and
rejected — don't reintroduce it.

- **An at-logon trigger fires only on a real logon.** Not on unlock (that is a
  separate `SessionStateChangeTrigger` with `StateChange=SessionUnlock`) and not
  on resume from sleep.
- **Real logons are far rarer than daily on a laptop that mostly sleeps.**
  Measured over a multi-week window from
  `TerminalServices-LocalSessionManager/Operational` Id 21, logons clustered
  onto under half the days, including one stretch of nearly two weeks with none
  at all.

So an at-logon trigger alone cannot guarantee a daily backup. A fixed daily
time is still the mechanism.

**The catch-up for a missed run is the trigger's own hourly repetition
(`-BackupRetryIntervalMinutes`, default 60, for one day), not
`-StartWhenAvailable`.** `-StartWhenAvailable` would fire a missed run the
instant the machine came back — which is exactly the wrong moment twice over:
it lands inside the WSL post-wake transition window (see below), and it gives
the backup's own wake guard (`Invoke-WslResticBackup`, and the manual
`Invoke-WslBackup`'s activity gate too) no chance to defer first. An hourly
retry still catches up a missed day within the same day, without racing the
wake; once a run succeeds, the rest of the day's retries skip silently.

### The three daily publish tasks catch up a missed run, with restarts

`Usage Census Publish`, `Session Miner` and `Task Health Publish` set
`StartWhenAvailable` (plus `RestartCount 3`, `RestartInterval 10 min`); a
laptop asleep at their minute otherwise skipped the day (result 2147946720,
`0x800710E0`; the miner went 11-10 to 11-12 without a run). The backup stays
off it (above) because `wsl --export` dies in the post-wake window; these
scripts only need a working `wsl.exe`, and the restart interval clears that
window if a catch-up lands in it. Memory Curation and the other tasks are
unchanged.

### The daily backup is a live restic backup, not `wsl --export`

The `WSL Ubuntu Daily Backup` task runs `Invoke-WslResticBackup`: restic as
root inside the running distro, into a repository on a local disk, then a
one-way robocopy into the OneDrive-synced backup dir. `Invoke-WslBackup`
(`wsl --export`) stays in the module as a manual-only command.

- **Why.** `wsl --export` always stops the distro (next section), so every
  nightly backup killed the running Claude Code sessions. That is not a flag
  away: in the WSL source, `ExportDistribution` calls `_ConversionBegin`, which
  calls `_TerminateInstanceInternal`. Don't look for an export mode that
  leaves the distro running.
- **`/mnt/*` is excluded on purpose.** `/mnt/wslg/distro` is a bind mount of
  `/` on the same device, so `--one-file-system` does not skip it and the
  backup would read the root filesystem twice (verified on the owner's machine
  2026-10-20). Keep the line in `scripts/wsl-restic-excludes.txt`.
- **It takes no `backup.lock`.** The lock exists so the keeper waits instead of
  launching a session into a distro an export is about to stop. restic stops
  nothing, so holding it would only delay the keeper.
- **The OneDrive copy order is load-bearing.** Everything but `snapshots\`
  first (`/E`, no deletes), then `snapshots\` (`/MIR`), and only on the weekly
  prune run `index\` then `data\` (`/MIR`). OneDrive can upload at any instant;
  in this order it never holds a snapshot whose packs have not arrived, and
  never loses a pack a surviving snapshot still needs.
- **The copy never carries attributes** (`/COPY:DT /DCOPY:T`). Robocopy's
  defaults copy the local folder's attributes over the OneDrive folder's and
  cleared its "Always keep on this device" pin on the first real run
  (2026-10-23).

### `wsl --export` stops the running distro

Verified 2026-09-25 on the durable workstation (WSL 2.7.14): a throwaway distro's shell was
watching `dmesg -w` when a backup export ran against it, and the export
killed it exactly as `wsl --shutdown` would. The production journal shows the
same thing on every real backup, right after the export starts:

```
InitTerminateInstanceInternal ... systemctl poweroff
```

**No flag or config avoids this** — `wsl --export` always stops the distro it
exports, tar or vhdx, in use or not. This is why `Invoke-WslBackup` gates on
`Test-WslActivity` before exporting (deferring while the distro looks
actively used, forcing through anyway once the newest backup is at least
`-ForceAfterDays` whole days old, default 3, and only inside the overnight
`-ForceWindowStartHour`/`-ForceWindowEndHour` window, default 02:00-06:00 local,
so a forced stop lands when nobody is working) rather than trying to export
around a live session.

`--vhd` needs the vhdx detached from the WSL utility VM to export, which does
not happen while any *other* distro is still attached to that same shared VM
(for example `docker-desktop`, which most machines keep running) — a second,
independent reason a vhdx export can fail with `ERROR_SHARING_VIOLATION` even
against an idle target distro, on top of the freshly-`--import`ed-and-never-
booted case below.

### `wsl --export` fails on a *transitioning* WSL, not (only) a busy one

Don't schedule an export to land right after a boot or a resume. Concurrent
use is not itself a Windows-side failure mode for the export call — a
full-size export completed cleanly while the distro was actively being
worked in — but the export still stops the distro either way (see above), so
`Invoke-WslBackup`'s activity gate exists independently of this transition
issue.

- **Both observed `exit -1` failures hit WSL mid-transition:** one where a
  scheduled wake pulled the machine out of sleep and the export died seconds
  later, and one where a `-StartWhenAvailable` catch-up fired a few minutes
  after a cold boot. The corroborating signal in the same window is SCM 7011 —
  "timeout (30000 ms) ... waiting for a transaction response from the WSLService
  service".
- **The WSL-init window runs up to roughly 270 seconds after boot.** Anything
  triggered off boot or logon therefore needs a delay of ten minutes, not five;
  five would have cleared the observed worst case by about a minute.

This is the gap `Invoke-WslBackup`'s own wake guard (`-MinMinutesSinceWake`,
via the private `Get-LastWakeTime`) closes, whatever the
scheduled task's own timing: any run — the daily trigger, an hourly
retry, or a manual invocation — checks minutes-since-boot-or-resume itself
and defers (`DeferredRecentWake`) rather than attempt the export inside the
transition window. Any other work that adds a boot/resume-adjacent trigger
owes the same delay.

### Idle Claude Code sessions do not count as backup activity

Observed live 2026-09-27: a second interactive Claude Code session
(`claude --resume <id>`, left open in a terminal alongside its npm/node MCP
child processes) deferred the backup 13 consecutive daily runs with
`Deferred: WSL in use (... claude, npm, node)`. Only the `-ForceAfterDays`
override (9 days when this was observed; the default is `-ForceAfterDays 3`, in-window
only) would ever have let a backup through — people routinely leave Claude sessions open, so this defeated the
activity gate's whole point. Don't re-treat a `claude` process as activity on
sight; it isn't one.

`Test-WslActivity` reads each non-Remote-Control `claude` process's own
`~/.claude/sessions/<pid>.json` (one `wsl --exec` call per pid, `status`
`busy` vs `idle`) and excludes an idle session, and everything it spawned,
before the pty rules run. This **fails safe to busy** on anything it doesn't
recognise — the file is Claude Code-internal and undocumented (observed in
2.1.282), so a missing file, a non-zero exit, a parse error, a pid mismatch,
or any status other than exactly `idle` all count as busy.
`Invoke-WslBackup` also `SIGTERM`s the idle sessions it finds,
immediately before the export, the same way it does for the Remote
Control session — they're resumable afterwards with `claude --resume`.

A session run as its versioned binary is identified too: its `comm` is the
binary's file name (e.g. `2.1.285`) and its argv0 is a path ending in
`claude/versions/<version>`. Observed 2026-09-29 with sessions spawned by
`claude rc` and with resumed sessions; a version-like `comm` with any other
argv0 is not treated as Claude.

### The keeper restores lost Claude sessions from a snapshot

When `claude rc` dies - quit by hand, or stopped with the whole distro by a
backup's `wsl --export` - the sessions running under it stop too and vanish
from `claude agents`. They are restorable: from each one's cwd,
`claude --bg --resume <full-session-uuid>` exits 0 and the session reappears,
idle, history intact. `Invoke-ClaudeSessionKeeper` automates exactly that:

- **Snapshot on every live run.** While the Remote Control server is alive,
  each run stores `claude agents --json` (via `wsl --exec bash -l -c`; both
  `claude` and `codex` live in `~/.local/bin`) as id/cwd/kind in
  `%LOCALAPPDATA%\wsl-automation\agents-snapshot.json`, atomically. A list
  that could not be read (`$null`) never overwrites it; an empty list does.
- **Restore on a dead run.** After launching a new server it resumes each
  snapshotted id that is not currently listed. The cwd and id reach bash as
  positional arguments (`bash -c 'cd -- "$1" && exec claude --bg --resume "$2"'
  bash <cwd> <id>`), never spliced into the command, and an id that is not a
  UUID is skipped.
- **The `restorePending` mark is load-bearing - don't remove it.** In the
  backup case the distro is still stopped on the dead run, so the live list
  can't be read and nothing is resumed. The next run then finds the new
  server alive, and without the mark it would refresh the snapshot from the
  post-crash list and forget every lost session. With it, that run restores
  first and only then clears the mark.
- **The backup records the sessions itself.** The keeper and the backup both
  fire at :00, and the keeper's last refresh raced the backup's teardown, so a
  session that was busy mid-turn was never snapshotted (observed 2026-10-05).
  `Invoke-WslBackup` writes the live list, restore-pending, right before it
  stops anything (best-effort; if the list is unreadable it re-marks the
  keeper's last snapshot), and the keeper's refresh re-checks the lock and the
  mark immediately before writing, so it never overwrites that file.
- **Interrupted sessions are asked to continue.** The snapshot carries a
  per-session `working` flag (`status` `busy` or `state` `working`). A
  `working` session is resumed with a fixed prompt as a third positional
  argument (`... --resume "$2" "$3"`); an idle one is resumed bare.
- **Known limitation:** for a stop that is not a backup (a crash), a session
  deliberately ended within the last keeper interval before `claude rc` died is
  brought back.
- Only session ids and counts go to the keeper log (LOCALAPPDATA, not the
  shared OneDrive backup log) - never a cwd or a session name.

The same keeper also keeps `codex remote-control start` running through a
second interactive launcher task (`Codex Remote Control Launcher`).
`Test-CodexRemoteControl` keys liveness to the daemon process
(`codex app-server ... --remote-control ... --managed-daemon`), never to the
launcher's tab: the daemon runs in its own session with no terminal and can
outlive the tab (or the command can return and close it), so a check on the
tab could relaunch it every interval. Keep it that way. The daemon has no pty, so
`Test-WslActivity` does not count it as activity.

Both Codex tasks (that launcher and `Codex Cloud Environment Sync`) are
registered **disabled** unless `register-tasks.ps1` gets `-EnableCodexTasks`, and
then the keeper task's action carries `-NoCodexRemoteControl`. Keep the two
together: a disabled launcher with a keeper that still tries to start it fails
every interval.

### Never leave an interactive prompt in a scheduled-task code path

`Read-Host`, `pause`, and any `-Confirm` prompt must be unreachable when a
script runs unattended. A scheduled task has no console to answer them, so the
run does not fail — it **hangs until `ExecutionTimeLimit` kills it**.

This is why `wsl-restic-backup.ps1`, the script the registered backup task runs,
keeps its `Read-Host` behind `-NoPause` and why the registered action must always
pass it. Every new script wired into a
task needs the same treatment — and the short-interval tasks (keeper,
ccstatusline sync, both `-MultipleInstances IgnoreNew`) are where it bites
hardest: one hung instance suppresses every subsequent interval for the whole
execution-time limit, not just the next one.

**Recognising it:** the run starts on time, the log stops a few seconds in, and
Task Scheduler Id 329 terminates it at *exactly* `ExecutionTimeLimit` later (2h
for the backup and the keeper, 5 min for ccstatusline).
`LastTaskResult=267014` (`0x41306`, `SCHED_S_TASK_TERMINATED`) is the signature
— a stuck prompt, not a slow export. Note it is a *terminated* result, not an
error one, so failure-only alerting will not see it.

The backup lock is not the tell: `Invoke-WslBackup` releases it in its own
`finally`, which runs before the wrapper's prompt. A hung task holds no lock.

### Keep the PowerShell sources ASCII-only

Every tracked `.ps1` / `.psm1` / `.psd1` here is pure ASCII and carries no BOM.
Keep it that way — in comments, comment-based help, and log strings alike. Use
`-` rather than an em dash and `->` rather than an arrow character.

Windows PowerShell 5.1 reads a BOM-less file as the active ANSI code page
(Windows-1252 on a US-English install), not UTF-8. A predecessor of
`wsl-ubuntu-backup.ps1` contained non-ASCII punctuation, and under 5.1 the three
bytes of `->` as an arrow (`E2 86 92`) decode to three cp1252 characters ending
in a smart quote — which 5.1 treats as a **string delimiter**, so the whole file
fails to parse.

What makes this latent rather than loud: pwsh 7 reads BOM-less UTF-8 correctly,
and CI runs `shell: pwsh` on `windows-latest` — so CI will never catch it. The
exposure is a human running `scripts\register-tasks.ps1` (or pasting it) from a
5.1 prompt, which is a normal thing to do on Windows.

A UTF-8 BOM also fixes it, but editors and tooling strip BOMs silently, so
staying ASCII is the invariant that actually holds. Check with:

```
LC_ALL=C git grep -nP '[\x80-\xff]' -- '*.ps1' '*.psm1' '*.psd1'
```

It must find nothing. (Scope the pathspec — the Markdown files legitimately use
em dashes.)

### Task principal is the owning user — never SYSTEM

Every task builds its principal from `$env:USERDOMAIN\$env:USERNAME`. Do
not switch one to `NT AUTHORITY\SYSTEM` to dodge an elevation or
stored-password problem — the S4U tasks in particular make it look tempting.

**Why it is not merely wrong but dangerous:** WSL distros are registered *per
Windows user account*. A task running as SYSTEM sees no distro at all, so every
`wsl.exe` call against it is meaningless. It registers cleanly, runs on
schedule, exits, and backs up nothing — no error to notice.

The accepted cost of a user principal is that the interactive tasks cannot run
before someone has logged on. That is expected. The S4U tasks, the backup among
them, run either way, and the backup's hourly retry covers a missed run.

### `wsl --export --vhd` and throwaway distros

Against a distro that was freshly `--import`ed and never booted,
`wsl --export --vhd` fails with `ERROR_SHARING_VIOLATION`. A scratch distro spun
up purely to exercise the vhdx path is therefore **not a valid test of it** —
the failure is the scratch distro's state, not a bug in the export. `-Format
tar` on the same distro succeeds.

This matters because the vhdx path ships (`Invoke-WslBackup` appends `--vhd`
when `-Format vhdx`) and no test exercises it for real — every test mocks the
`Invoke-WslExe` seam. Real, previously-booted distros export to vhdx fine.

Expect the vhdx to run roughly twice the size of the tar for the same distro,
and the export to take proportionally longer — worth planning for before running a
manual `-Format vhdx` export; no scheduled task runs it (the daily backup task has a
2h `ExecutionTimeLimit` and runs restic).

### PowerShell invoked from WSL is never elevated

The rule itself — `powershell.exe` / `pwsh.exe` launched from WSL holds a
filtered token, so reads succeed while elevation-requiring writes fail with
"Access is denied", and no flag, retry or downgraded principal fixes it — and
the hand-over procedure live in the **`windows-elevation-from-wsl`** skill
(`adam-coding-local` plugin in `adam-agentskills`;
`/adam-coding-local:windows-elevation-from-wsl`). This section keeps only what
is specific to this repo:

- **Both writes this repo makes need elevation.** `scripts\register-tasks.ps1`
  carries `#requires -RunAsAdministrator`, so from WSL it refuses before the
  first line runs ("The script cannot be run because it contains a '#requires'
  statement for running as Administrator") rather than failing part-way with
  "Access is denied" — and that holds for `-WhatIf` too, so even a dry run
  needs the elevated prompt. `scripts\grant-keeper-batch-logon.ps1` is an LSA
  rights grant (`SeBatchLogonRight`), the other denied shape.
- **Reads are the WSL-side tool.** `Get-ScheduledTask`, `Get-ScheduledTaskInfo`
  and `Export-ScheduledTask` against the tasks work from WSL; use them to
  investigate and to export what a re-registration will replace.
- **The line to hand over is the installer, as the README's step 4 gives it:**
  from an elevated PowerShell 7.6+ prompt in the Windows checkout
  (`D:\repos\adam-s-daniel\wsl-automation`),
  `.\scripts\register-tasks.ps1 -BackupDir '<dir>' -ResticRepoDir '<dir>'` —
  re-running it updates the existing tasks in place.

### The keeper restarts a dead WSL user manager, and linger stays on

2026-10-04 13:02 EDT a test ran `kill(-1, SIGKILL)` as the WSL user
([skills-evals#250](https://github.com/Adam-S-Daniel/skills-evals/pull/250)).
That killed `user@1000.service`; systemd then removed `/run/user/1000` and does
not start the manager again by itself. Every new shell warned
`XDG_RUNTIME_DIR ... is not a directory`, snap apps failed with `cannot create
XDG_RUNTIME_DIR`, and user timers stopped. `sudo systemctl start user@1000`
needs a password; `loginctl enable-linger` does not (polkit allows a user to
change their own linger) and starts the manager.

- **`Repair-WslUserRuntime` does that on every keeper run**, after the backup
  lock wait and before the session work: manager not running and linger off ->
  `enable-linger`; linger on -> `disable-linger` then `enable-linger`. It never
  throws, never boots a stopped distro, and logs one line that carries no uid or
  user name. The disable-then-enable order is inferred from `loginctl(1)` and
  was never run against a dead manager with linger already on; verify it the
  next time that happens before trusting it.
- **Linger is intentionally enabled on this machine.** Do not turn it off to
  "clean up"; the keeper's repair and the user's own recovery both rely on it.
- The manager is addressed by numeric uid, so no user name reaches a log.

### CI: three required checks that always run

`.github/workflows/ci.yml` has three jobs, `shell` (ubuntu), `test` (windows)
and `test-linux` (ubuntu), intended as required status checks; they are made
required in repo-settings' `fleet.yml` after this lands. A required check
cannot use `on.paths` (a skipped check blocks the merge), so all three run on
every pull request and skip early instead: each job's `salient` step diffs the
pull request's base and head and gates every later step on it, and a final
step reports success when nothing salient changed. The salient paths are
`src/**`, `scripts/**`, `tests/**`, `config/**`, `.github/workflows/ci.yml`,
`.github/workflows/actions.lock` and `PSScriptAnalyzerSettings.psd1`. On any
other event, or when the changed files cannot be determined, the job runs in
full. Keep the job ids, and add no `name:`, `matrix` or `concurrency:`;
`tests/CiWorkflow.Tests.ps1` enforces that shape.

**Action pins.** Workflows name actions by release tag, locked to a commit in
`.github/workflows/actions.lock`
([ADR 0024](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/decisions/0024-actions-pin-through-lockfiles.md)).

- The `shell` job runs the shared
  [`Adam-S-Daniel/verify-actions-lock`](https://github.com/Adam-S-Daniel/verify-actions-lock)
  check, which verifies the lockfile only when a pull request touches workflow
  dependencies.
- After changing a `uses:`, regenerate with `gh actions-lock --no-narrow`.
- A moved or unreachable pin: find out why first, then recover with
  `gh actions-lock --accept-moved`.
- `reachability-unknown` means GitHub's API was unreachable; re-run the job.
- Cross-repo reusable workflows (`jobs.<id>.uses`) are not covered by the
  lockfile and take a full 40-character commit SHA.

### A stub `~/repos/.git` breaks every worktree Project thread

`~/repos` is the folder of clones that `claude rc` runs in, and it is not
itself a git repository. Claude Code can write `.git/info/exclude` into it
anyway, leaving a `.git` directory that holds only `info/exclude` — no `HEAD`
file, no `objects` folder. While that stub exists, Claude Code treats `~/repos`
as a git repository.

- **Symptom.** claude.ai Project "Work locally" threads with Worktree on never
  start. `claude rc` prints `Failed to create worktree ... Failed to resolve
  base branch HEAD`, and the thread shows no output and reports the session
  dropped after about 2 minutes.
- **Fix.** `mv ~/repos/.git ~/repos/.git.stray`, then restart `claude rc`. The
  restart is not optional: a running `claude rc` caches the git-root answer
  and keeps believing the folder is a repository until it restarts.
- **Guard.** `Test-ClaudeStubGitDir` runs on every keeper run, after
  `Repair-WslUserRuntime`. It probes with one `sh -c` call and logs one warning
  line per run while the stub exists. It uses the same test Claude Code does
  before trusting a `.git` (a directory holding a `HEAD` file and an `objects`
  folder); a `.git` file or symlink counts as a stub too, since `~/repos`
  should hold no `.git` at all. It never throws and never boots a stopped
  distro.
- **It deliberately does not move the folder itself.** The keeper only warns:
  moving a `.git` is a change to the user's files, and the restart that makes
  the fix take effect would stop every session under `claude rc`.

### Memory curation covers both Claude homes on this machine

Claude Code on this machine keeps memory in two homes: the WSL one
(`~/.claude`) and the Windows one (`%USERPROFILE%\.claude`). The routine spec in
`_agent-guidance` (`docs/routines/memory-curation.md`) names only one, so
`scripts/run-memory-curation.sh` resolves the Windows home at run time (never a
hardcoded user name) and passes both to the headless session.

- **The log is counts-only and the summary is a local file.** Memory is private:
  the log gets directory and note counts, never a path, note name or note text,
  and Claude's summary goes to a mode-600 file (`~/.cache/memory-curation/last-summary.md`),
  not to the log.
- **An unresolvable Windows home is not a failure.** The run continues on the
  WSL home and logs `windows_home=unresolved`.

### Task health is published for the cloud audit

Cloud checks cannot see Windows Task Scheduler, so the daily `Task Health
Publish` task (`scripts/publish-task-health.sh`) publishes this machine's
task health, and `_agent-guidance`'s weekly fleet-health audit reads it.

- **Where.** `task-health.json` on the `persistent/task-health` branch of
  `Adam-S-Daniel/waiting-feed`: one parentless commit, replaced on every
  publish (force-with-lease), never `main`. Never delete the branch.
- **Counts, states, numbers and timestamps only.** No path, user name, host
  name, log text or session name goes into the file, the log line or stdout.
  Add a field only if it is one of those kinds of values.
- **restic is read through file mtimes, not restic.** The repository password
  is root-only, so the script takes the newest mtime in the repository's
  `snapshots` directory and never runs restic.

### Task start times are local, with no UTC offset

`New-ScheduledTaskTrigger` in pwsh 7 writes `StartBoundary` in UTC, and Task
Scheduler stores it with the offset in effect at registration
(`...-04:00`). Such a trigger fires at a fixed UTC instant, so every daily task
registered during daylight time ran an hour early after the November 2026
clock change. Every trigger therefore goes through the private
`ConvertTo-WslLocalTimeTrigger`, which writes the boundary back as local time
with no offset; Task Scheduler then keeps the wall-clock time across the
change. A new trigger must go through it too; `tests/Tasks.Tests.ps1` fails
otherwise.

### Docker Desktop WSL integration breaks after reboot; the watchdog repairs it

Diagnosed 2026-10-31; the `Docker WSL Integration Watchdog` task exists for it
(README has the statuses and alerts).

- **Symptom.** Every attempt failed with `dial unix /mnt/wsl/docker-desktop/shared-sockets/host-services/backend.sock: connect: no such file or directory`.
- **Cause.** Docker's `wsl-bootstrap` pre-bootstrap force-unmounts its
  shared-socket mounts under `/mnt/wsl`, a mount peer group shared across
  distros ([docker/desktop-feedback#678](https://github.com/docker/desktop-feedback/issues/678)).
  Ubuntu powered off 35 ms later and its systemd shutdown unmounted
  `host-services` for good.
- **"Skip WSL distro integration" removes the distro** from `IntegratedWslDistros`
  in `%APPDATA%\Docker\settings-store.json`.
- **A Docker Desktop restart re-creates the mounts, so it is the repair.**
  A missing integration entry needs the owner, so that case alerts and never restarts.
- **Interactive, not S4U:** the restart relaunches the Docker GUI, which must
  land in the user's session (and the toast needs the desktop). Hence
  `conhost.exe --headless`. Still the user, never SYSTEM.
- **Docker's start-at-login stays ON.** Starting Docker later makes it likelier
  Ubuntu is already running with sessions when the race fires.
