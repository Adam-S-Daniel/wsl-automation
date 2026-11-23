# Dated observations behind AGENTS.md rules

`AGENTS.md` keeps each rule and its mechanism. The dated "observed" and
"verified" facts, and the PR and issue history behind them, live here. Each
heading names the `AGENTS.md` section it supports.

## Restic backup: why `/mnt/*` is excluded

`/mnt/wslg/distro` is a bind mount of `/` on the same device, so
`--one-file-system` does not skip it and the backup would read the root
filesystem twice. Verified on the owner's machine 2026-10-20.

## OneDrive copy: why it never carries attributes

Robocopy's defaults copy the local folder's attributes over the OneDrive
folder's and cleared its "Always keep on this device" pin on the first real
run (2026-10-23).

## `wsl --export` stops the running distro

Verified 2026-09-25 on the durable workstation (WSL 2.7.14): a throwaway
distro's shell was watching `dmesg -w` when a backup export ran against it, and
the export killed it exactly as `wsl --shutdown` would. The production journal
shows the same thing on every real backup, right after the export starts:

```
InitTerminateInstanceInternal ... systemctl poweroff
```

## Backup `exit -1` failures hit WSL mid-transition

- Both observed `exit -1` failures hit WSL mid-transition: one where a
  scheduled wake pulled the machine out of sleep and the export died seconds
  later, and one where a `-StartWhenAvailable` catch-up fired a few minutes
  after a cold boot. The corroborating signal in the same window is SCM 7011:
  "timeout (30000 ms) ... waiting for a transaction response from the
  WSLService service".
- The WSL-init window runs up to roughly 270 seconds after boot. Five minutes
  would have cleared the observed worst case by about a minute, hence the
  ten-minute delay rule.

## Idle Claude Code sessions do not count as backup activity

Observed live 2026-09-27: a second interactive Claude Code session
(`claude --resume <id>`, left open in a terminal alongside its npm/node MCP
child processes) deferred the backup 13 consecutive daily runs with
`Deferred: WSL in use (... claude, npm, node)`. Only the `-ForceAfterDays`
override (9 days when this was observed; the default is `-ForceAfterDays 3`,
in-window only) would ever have let a backup through. People routinely leave
Claude sessions open, so this defeated the activity gate's whole point.

## Versioned-binary Claude sessions

A session run as its versioned binary is identified by its `comm` (the
binary's file name, e.g. `2.1.285`) and an argv0 ending in
`claude/versions/<version>`. Observed 2026-09-29 with sessions spawned by
`claude rc` and with resumed sessions.

## The backup records the sessions itself

The keeper and the backup both fire at :00, and the keeper's last refresh
raced the backup's teardown, so a session that was busy mid-turn was never
snapshotted (observed 2026-10-05).

## The keeper restarts a dead WSL user manager

2026-10-04 13:02 EDT a test ran `kill(-1, SIGKILL)` as the WSL user
([skills-evals#250](https://github.com/Adam-S-Daniel/skills-evals/pull/250)).

## Docker Desktop WSL integration watchdog

Diagnosed 2026-10-31. Docker's `wsl-bootstrap` pre-bootstrap force-unmounts its
shared-socket mounts under `/mnt/wsl`, a mount peer group shared across
distros
([docker/desktop-feedback#678](https://github.com/docker/desktop-feedback/issues/678)).
Ubuntu powered off 35 ms later and its systemd shutdown unmounted
`host-services` for good.
