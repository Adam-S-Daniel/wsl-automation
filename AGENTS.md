<!-- BEGIN MANAGED SECTION — DO NOT EDIT ABOVE "## Repo-specific additions" -->
<!-- Source: _agent-guidance -->
<!-- Sections: none -->
<!-- Mode: stub -->

# AGENTS.md

> **Managed by [`_agent-guidance`].**
> Edit only below the `## Repo-specific additions` header.
> Everything above it will be overwritten on the next sync.

## Fleet guidance is delivered once per session — not by this file

The account's full guidance — incidents, fleet policy, machine layout, the
traps that cost real outages — is installed into **user memory**
(`~/.claude/CLAUDE.md`) by the `fleet-memory` SessionStart hook, so it is
loaded **once per session** no matter how many repos are attached
([2026-08-29: inlined per repo, it took 332.3k tokens](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/evidence/2026-08-29-guidance-inlined-in-every-repo.md)).

**Check the session-start verdict before you rely on it.** The hook prints one
line:

- `fleet-guidance: installed (v<id>, <n> bytes)` or `fleet-guidance: current` —
  the full guidance is in context. Use it.
- `fleet-guidance: DEGRADED — <reason>` — it is **not** in context. You have
  only what is below. Read `agents-md/base.md` in the `_agent-guidance`
  checkout (or on GitHub) before non-trivial work, and say in your reply that
  you were running degraded.
- `fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set)` — also not in context,
  but by the machine owner's deliberate choice, not a fault. User memory is
  GLOBAL on a durable machine, so the guidance would otherwise load in every
  unrelated project on that box; `FLEET_GUIDANCE_SKIP` opts out and removes any
  block an earlier session installed. Read `agents-md/base.md` the same way you
  would when degraded — just don't report it as a problem or try to "fix" it.

No verdict at all means the hook never ran — treat that as DEGRADED.

## Codex reads the same block, from `~/.codex/AGENTS.md`

The hook writes the same block to `~/.codex/AGENTS.md` whenever `~/.codex`
exists — Codex's global **user** instructions, outside its 32 KiB
`project_doc_max_bytes` project-doc budget. Register it once per machine with
`scripts/register-codex-hook.sh` from an `_agent-guidance` checkout, then
trust it in `/hooks`. `codex debug prompt-input` renders instructions loaded
from disk by its own diagnostic process; it does not run SessionStart hooks
or inspect an existing session or daemon. Verify delivery in the launched
session's initial instructions and verdict; see the
[2026-10-04 evidence](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/evidence/codex-trust-and-daemon-0160.md#prompt-debugging-source-read-2026-10-04-cli-01600-rust-v01600).

For Codex Cloud, use **Manual** environment setup with persistent
`CODEX_HOME=/opt/codex`. Preserve the repository's dependency setup and run
`bash .claude/hooks/fleet-memory.sh --codex-cloud` in both setup and
maintenance; reset the cache for the first verification. Fresh setup and
cached maintenance were verified in the `_agent-guidance` environment. See
[`docs/codex-cloud.md`](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/codex-cloud.md).
If the Cloud shell has no `codex debug prompt-input`, the saved task response's
raw initial instruction envelope is the echo-free proof of model-visible
delivery.

## The floor: rules that hold even when the guidance did not load

These are the ones with teeth. They are restated here, deliberately, because a
session that lost the guidance must not also lose these.

- **Branch protection is real.** Fleet repos are PR-only on their default
  branch; a direct push is rejected (GH013), even from the repo's own
  workflows. Never design a bot that pushes to a protected default branch.
- **Every `uses:` is pinned to a full 40-character commit SHA, with no
  trailing version comment.** The one carve-out is a ref into this account's
  own `cms-platform`, which stays on its release tag.
- **Never commit secrets or `.env` files, and never print personal data to a
  CI log** — logs, artifacts and git history on a public repo are public.
- **A successful `git push` does not mean your commit exists.** A refused
  pre-commit hook still lets the push report success. Verify with
  `git merge-base --is-ancestor <sha> origin/<branch>` — it is the only check
  that names both the commit and the ref.
- **"The watch finished" is not "CI passed."** Read the parsed conclusions;
  never infer pass/fail from a watch command's exit code.
- **A GitHub 404 means "not authorized", not "not there."** Never report a
  repo, PR or branch as gone on a 404 alone.
- **The fleet spans TWO owners** — `Adam-S-Daniel` and `jodidaniel`. A query
  scoped to one returns a plausible, complete-shaped, wrong answer.
- **Anything you name gets its link** — what you hand over, what you are
  waiting on, and what you cite as already done.
- **Merge with a merge commit** (`gh pr merge --merge`); do not amend
  published commits or force-push shared branches.
- **Keep this file under 32 KiB.** Codex truncates project instructions at
  that byte silently; the sync warns and the drift report flags
  `codex-truncated`.

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
`Invoke-WslBackup`'s own wake guard and activity gate (`Test-WslActivity`) no
chance to defer first. An hourly retry still catches up a missed day within
the same day, without racing the wake.

### `wsl --export` stops the running distro

Verified 2026-09-25 on BOXY (WSL 2.7.14): a throwaway distro's shell was
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
via the private `Get-LastWakeTime`) now closes directly, rather than relying
on the scheduled task's own timing: any run — the daily trigger, an hourly
retry, or a manual invocation — checks minutes-since-boot-or-resume itself
and defers (`DeferredRecentWake`) rather than attempt the export inside the
transition window. Any other work that adds a boot/resume-adjacent trigger
owes the same delay.

### Idle Claude Code sessions do not count as backup activity

Observed live 2026-09-27: a second interactive Claude Code session
(`claude --resume <id>`, left open in a terminal alongside its npm/node MCP
child processes) deferred the backup 13 consecutive daily runs with
`Deferred: WSL in use (... claude, npm, node)`. Only the `-ForceAfterDays`
override (9 days when this was observed; 3 now, in-window only) would ever have let a backup
through — people routinely leave Claude sessions open, so this defeated the
activity gate's whole point. Don't re-treat a `claude` process as activity on
sight; it isn't one.

`Test-WslActivity` reads each non-Remote-Control `claude` process's own
`~/.claude/sessions/<pid>.json` (one `wsl --exec` call per pid, `status`
`busy` vs `idle`) and excludes an idle session, and everything it spawned,
before the pty rules run. This **fails safe to busy** on anything it doesn't
recognise — the file is Claude Code-internal and undocumented (observed in
2.1.282), so a missing file, a non-zero exit, a parse error, a pid mismatch,
or any status other than exactly `idle` all count as busy, same as before
this existed. `Invoke-WslBackup` also `SIGTERM`s the idle sessions it finds,
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

### Never leave an interactive prompt in a scheduled-task code path

`Read-Host`, `pause`, and any `-Confirm` prompt must be unreachable when a
script runs unattended. A scheduled task has no console to answer them, so the
run does not fail — it **hangs until `ExecutionTimeLimit` kills it**.

This is why `wsl-ubuntu-backup.ps1` keeps its `Read-Host` behind `-NoPause` and
why the registered action must always pass it. Every new script wired into a
task needs the same treatment — and the short-interval tasks (keeper,
ccstatusline sync, both `-MultipleInstances IgnoreNew`) are where it bites
hardest: one hung instance suppresses every subsequent interval for the whole
execution-time limit, not just the next one.

**Recognising it:** the run starts on time, the log stops a few seconds in, and
Task Scheduler Id 329 terminates it at *exactly* `ExecutionTimeLimit` later (4h
for the backup, 2h for the keeper, 5 min for ccstatusline).
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

The accepted cost of a user principal is that these tasks cannot run before
someone has logged on. That is expected; the backup trigger's hourly repetition
(`-BackupRetryIntervalMinutes`) catches it up once someone has logged on;
`-StartWhenAvailable` is forced off (see above).

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
and the export to take proportionally longer — worth checking against the backup
task's 4h `ExecutionTimeLimit` before switching a machine to `-Format vhdx`.

### PowerShell invoked from WSL is never elevated

The rule itself — `powershell.exe` / `pwsh.exe` launched from WSL holds a
filtered token, so reads succeed while elevation-requiring writes fail with
"Access is denied", and no flag, retry or downgraded principal fixes it — and
the hand-over procedure live in the **`windows-elevation-from-wsl`** skill
(`adam-local` bundle in `agentskills`; `/adam-local:windows-elevation-from-wsl`),
pointed at from the fleet guidance's "Workstation layout" section. This
section keeps only what is specific to this repo:

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
- **The line to hand over is the installer, as the README's step 3 gives it:**
  from an elevated PowerShell 7.6+ prompt in the Windows checkout
  (`D:\repos\adam-s-daniel\wsl-automation`),
  `.\scripts\register-tasks.ps1 -BackupDir '<dir>'` — re-running it updates
  the existing tasks in place.

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
