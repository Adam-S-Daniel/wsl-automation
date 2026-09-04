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
loaded **once per session** no matter how many repos are attached. It used to
be inlined here in every repo, which meant a session with 19 repos open
carried 19 identical copies: 332.3k tokens of a 1M window, measured
2026-08-29.

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
backup task has accumulated with a single daily one. The at-logon alternative
was measured and rejected — don't reintroduce it.

- **An at-logon trigger fires only on a real logon.** Not on unlock (that is a
  separate `SessionStateChangeTrigger` with `StateChange=SessionUnlock`) and not
  on resume from sleep.
- **Real logons are far rarer than daily on a laptop that mostly sleeps.**
  Measured over a multi-week window from
  `TerminalServices-LocalSessionManager/Operational` Id 21, logons clustered
  onto under half the days, including one stretch of nearly two weeks with none
  at all.

So an at-logon trigger alone cannot guarantee a daily backup. The fixed daily
time plus `-StartWhenAvailable` is the mechanism that actually catches up a
missed run.

### `wsl --export` fails on a *transitioning* WSL, not a busy one

Don't schedule an export to land right after a boot or a resume — and don't
blame a failed export on the distro being in use.

- **Concurrent use is not the failure mode.** A full-size export completed
  cleanly while the distro was actively being worked in.
- **Both observed `exit -1` failures hit WSL mid-transition:** one where a
  scheduled wake pulled the machine out of sleep and the export died seconds
  later, and one where a `-StartWhenAvailable` catch-up fired a few minutes
  after a cold boot. The corroborating signal in the same window is SCM 7011 —
  "timeout (30000 ms) ... waiting for a transaction response from the WSLService
  service".
- **The WSL-init window runs up to roughly 270 seconds after boot.** Anything
  triggered off boot or logon therefore needs a delay of ten minutes, not five;
  five would have cleared the observed worst case by about a minute.

This is the one gap `-StartWhenAvailable` leaves open: it deliberately fires a
missed run at the next opportunity, which can be moments after a resume. Any
work that adds a boot/resume-adjacent trigger owes it a delay.

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

All four tasks build their principal from `$env:USERDOMAIN\$env:USERNAME`. Do
not switch one to `NT AUTHORITY\SYSTEM` to dodge an elevation or
stored-password problem — the S4U tasks in particular make it look tempting.

**Why it is not merely wrong but dangerous:** WSL distros are registered *per
Windows user account*. A task running as SYSTEM sees no distro at all, so every
`wsl.exe` call against it is meaningless. It registers cleanly, runs on
schedule, exits, and backs up nothing — no error to notice.

The accepted cost of a user principal is that these tasks cannot run before
someone has logged on. That is expected; `-StartWhenAvailable` covers it for the
backup.

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
pointed at from the fleet guidance's "Workstation layout" bullet for `ZENDA`.
This section keeps only what is specific to this repo:

- **Both writes this repo makes need elevation.** `scripts\register-tasks.ps1`
  carries `#requires -RunAsAdministrator`, so from WSL it refuses before the
  first line runs ("The script cannot be run because it contains a '#requires'
  statement for running as Administrator") rather than failing part-way with
  "Access is denied" — and that holds for `-WhatIf` too, so even a dry run
  needs the elevated prompt. `scripts\grant-keeper-batch-logon.ps1` is an LSA
  rights grant (`SeBatchLogonRight`), the other denied shape.
- **Reads are the WSL-side tool.** `Get-ScheduledTask`, `Get-ScheduledTaskInfo`
  and `Export-ScheduledTask` against the four tasks work from WSL; use them to
  investigate and to export what a re-registration will replace.
- **The line to hand over is the installer, as the README's step 3 gives it:**
  from an elevated PowerShell 7.6+ prompt in the Windows checkout
  (`D:\repos\adam-s-daniel\wsl-automation`),
  `.\scripts\register-tasks.ps1 -BackupDir '<dir>'` — re-running it updates
  the existing tasks in place.
