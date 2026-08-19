<!-- BEGIN MANAGED SECTION — DO NOT EDIT ABOVE "## Repo-specific additions" -->
<!-- Source: _agent-guidance -->
<!-- Sections: none -->

# AGENTS.md

> **Managed by [`_agent-guidance`].**
> Edit only below the `## Repo-specific additions` header.
> Everything above it will be overwritten on the next sync.

This block is deliberately short. It carries the things that are **specific to
this account and learned the hard way** — incidents, fleet policy, machine
layout. It does not restate general engineering practice, and it does not
describe anything you can learn by reading the repo. Depth lives in each repo's
`docs/` and in the skills registry; follow the pointers when the work touches
that area.

## Working in these repos

- Fix what was asked. No speculative features, premature abstractions, or
  unused helpers.
- Prefer editing an existing file over creating a new one.
- Every public interface change updates the corresponding tests.
- Run the existing test suite before calling a task complete, and say plainly
  what you ran. New behaviour gets a test; a bug fix gets a regression test.
- Tests must be deterministic — no sleeps, no network, no reliance on
  wall-clock time.

## Finding your unknowns

Output quality on a non-trivial task is bounded by how well the ambiguities got
resolved — and most of them surface *during* implementation, not before it. So
treat unknown-hunting as part of the work, not a phase that ends at the plan:

- Before building: name what you don't know. Prefer a reference in **code** — an
  existing implementation to mirror, a failing test, a rubric, an HTML mockup —
  over a prose description of the same thing.
- While building: keep a running note of decisions that departed from the plan
  and edge cases you hit. Surface them; don't silently absorb them.
- After building: be able to explain what changed and why it is correct.
- Durable findings go in the **repo**, not in agent memory — an environment
  quirk, non-obvious wiring, where a source of truth actually lives, a
  sequencing constraint. Repo files version with the code and every person and
  every harness that opens the repo sees them; agent memory is per-agent and is
  silently missed by the next session. A fleet-wide rule goes in
  `_agent-guidance`'s `agents-md/base.md`, a repo fact below the
  `## Repo-specific additions` marker, a reusable procedure into the skills
  registry. A memory note is a supplement, never the only copy.

The full workflow (blind-spot pass, self-interview, implementation notes,
post-hoc explainer) is the **`finding-unknowns`** skill in the registry. Reach
for it on unfamiliar code, a new domain, or anything with subjective acceptance
criteria.

## Workstation layout

Repo locations are host-specific — match the convention of the machine you're on
(on Windows, check `$env:COMPUTERNAME`).

- **`ZENDA`** (Windows): local clones live under `D:\repos\<github-owner-or-org>\<repo>`
  (for example `D:\repos\adam-s-daniel\wsl-automation`). Clone new repos there, and
  assume existing repos live there rather than under the user profile
  (`C:\Users\<user>\...`).

## Sessions get cut off

**`ZENDA` drops sessions mid-task, frequently.** Assume any run can end between
one tool call and the next, and keep the work recoverable throughout rather
than only at the end.

- **Commit and push as you go**, on a branch. A pushed branch survives the
  laptop; the conversation, a dirty tree and a worktree do not — a worktree can
  be deleted with the session that made it. Small commits *are* the checkpoint.
- **Persist the expensive part**, which is the investigation and not the diff:
  the root cause, the baseline test result, the option already ruled out. A
  fresh session can regenerate a patch quickly; it cannot cheaply re-derive why
  the obvious fix was wrong. Put it in the commit message, the PR body, or an
  ADR — all of which outlive the context window. Chat does not.
- **Say where things stand before a long step** — a full test suite, a CI
  watch, a wide refactor — so a resumed session starts from a statement of what
  is done and what is next, not a reconstruction of it.
- **Report a resume pointer, not just an outcome:** branch, PR number, worktree
  path, and the next command to run.

## Security

Standard practice applies without being restated here. These are the ones with
teeth in this account:

- Validate anything that crosses a trust boundary — user input, API responses,
  file contents.
- Never build SQL, shell commands, or HTML by string-concatenating untrusted
  data. Use parameterized queries, shell arrays, and context-aware escaping.
- Never commit secrets, credentials, or `.env` files.
- Never disable TLS verification, authentication, or CSRF protection.

## Data exposure in CI and public repos

Treat CI run logs, job summaries, artifacts, workflow run pages, and git history
as **public** on a public repo. (Real incident: a workflow printed the owner's
email addresses and their correspondents' into a public Actions log.)

- **Never print personal or sensitive data to a log** — no emails, contacts,
  names, IDs, mailbox sizes/counts, tokens, or anything "useful to an attacker or
  scammer." Deliver sensitive results out-of-band (e.g. email the account itself,
  write to a private store) and log only a non-identifying status line.
- **Don't interpolate `${{ inputs.* }}` / `${{ github.event.* }}` into a `run:`
  block** — the rendered command is echoed to the log. Read inputs from
  `$GITHUB_EVENT_PATH` inside the script and `::add-mask::` sensitive values
  before use. `::add-mask::` only scrubs the log *stream*, not other surfaces.
- **Put sensitive config in secrets, not plaintext inputs or `vars`.** Only
  secret *values* are masked in logs.
- **Sanitize error output** — never dump an API/HTTP response body on failure (it
  can quote personal data); reduce it to a status code + machine error type, and
  keep the data-bearing serialization/call inside the try/catch.
- **Least privilege:** set `permissions:` to the minimum (usually
  `contents: read`) and require approval for outside-collaborator fork PRs.
- **Test fixtures use reserved `example.com` / `example.net` domains only** —
  never a real address; fixtures get committed and logged.

### git history & metadata
- **Sanitize before the first commit.** Fixing the current file does not remove
  data from history. If sensitive data was committed, rewrite history to drop the
  commits, delete every ref that points at them (branches, tags, **PRs**), and
  force-push. GitHub garbage-collects unreachable objects on its own schedule
  (days to weeks) — until then they remain reachable *by SHA* — and you can ask
  GitHub Support to expedite for a public repo. (This is the deliberate exception
  to "don't force-push"; it is a security remediation.)
- **Commit with the GitHub `…@users.noreply.github.com` identity** on public
  repos so a real email is not baked into commit author/committer metadata.

## Automation vs branch protection

Fleet repos enforce PR-only default branches via ruleset, managed as code in
`repo-settings` (see its ADR 0001). Design automation accordingly:

- Never design a bot that pushes to a protected default branch ad hoc — the
  push is rejected (GH013), even from the repo's own workflows.
- Generated data (badges, run summaries, reports, dashboards) belongs on a
  dedicated unprotected results branch (e.g. skills-evals' `eval-results`);
  consumers read from that branch and treat its content as untrusted.
- The rare bot that genuinely must write to a default branch needs a ruleset
  bypass actor declared in repo-settings' `fleet.yml` — never a hand-granted
  UI bypass (the drift report flags those). The AGENTS.md sync App is the
  standing example.
- PR + auto-merge is not a sanctioned bot-write path for fleet repos; the
  cms-platform-managed repos (outside the fleet ruleset) use it by their own
  design.

### A required status check gets no `concurrency` group

A job that publishes a **required** status context and can fire more than once
on the same head sha — label events, an `opened` + `synchronize` burst, any
multi-event trigger — gets no `concurrency` block at all.

- GitHub picks **non-deterministically** between a cancelled run and a
  successful one for the same context + sha. When cancelled wins the PR is hard
  blocked: the merge API returns `405 Required status check "<ctx>" is
  cancelled`, and nothing overrides it — not native auto-merge, not an explicit
  merge call, not a nudge bot. The PR looks all-green and simply never lands.
- **`cancel-in-progress: false` is not "run them all."** GitHub keeps the
  in-progress run plus only the *latest* pending run in the group and cancels
  the other pending duplicates, so a same-sha burst still leaves cancelled runs
  behind. Flipping that flag is the fix that looks right and changes nothing.
- Same mechanic on any shared lane: when one push drives two workflows into one
  group, the older pending sibling is cancelled. Make the triggers pairwise
  disjoint — a shared group only serialises runs that already arrive apart.
- Jobs triggered only by `push` / `synchronize` — each a new sha — are safe to
  cancel and keep `cancel-in-progress: true`.
- Lock the invariant with a test that **parses** the workflow YAML (the `yaml`
  package — never a regex or line scan, which reads clean on text it cannot
  see), so the block cannot come back.

## "The watch finished" is not "CI passed"

Never read CI pass/fail off a watch command's exit code, or off the fact that it
returned. Three failure modes stack: in `cmd | tail` the shell's `$?` is
`tail`'s — always 0 — masking the non-zero from `gh pr checks`; a backgrounded
watch reports that same pipeline code, so its "completed (exit code 0)"
notification says nothing about the build; and `tail -N` can show only the
passing and skipping lines while the FAILURE lines scrolled out of the window,
so eyeballing it looks green too. (Real incident: all three lined up on one PR —
e2e and lint were FAILURE while the session reported CI green and moved on.)

- Capture the real code with `${PIPESTATUS[0]}`, or don't pipe the watch at all.
- After **any** CI watch, query the conclusions explicitly and report the parsed
  result before acting on it:

  ```bash
  gh pr view <n> --repo <owner>/<repo> --json statusCheckRollup --jq \
    '.statusCheckRollup[] | (.conclusion // .state) as $c
     | select($c != null and $c != "SUCCESS" and $c != "NEUTRAL")
     | "\(.name // .context): \($c)"'
  ```

  A check run carries `.conclusion`, a legacy commit status carries `.state` —
  filter on only one and the other's failures read as clean.
- Treat "watch done" as "now verify", never as "passed". Don't launch a watch
  and go passive without a definite verify-the-rollup step on resume.

## Dependency updates

Dependabot runs with a **minimum package age** (`cooldown`) so an unattended
merge still gets a cooling-off period: `default-days: 7`, `semver-major-days: 30`.
Two things about that setting are easy to get wrong:

- It applies to **version** updates only. A security advisory bypasses cooldown
  entirely and opens immediately — the wait never delays a vulnerability fix.
- An unset `cooldown` is **not** "no wait": GitHub applies an implicit 3-day
  minimum age to version updates. Writing 7 is a raise from 3, not from zero.

`semver-minor-days` / `semver-patch-days` are deliberately left undefined —
they fall back to `default-days`, and spelling them out only invites drift.

The window is not only Dependabot's. A package you add or bump **by hand** mid-task
is the case with no automation watching it: check the publish date
(`npm view <pkg> time --json`), take the newest release that has already cleared
the 7 days rather than the freshest one, and pin it exact (no caret) so `npm ci`
cannot drift onto a version that has had no cooling-off at all.

## Pinning GitHub Actions

**Every `uses:` is pinned to a full 40-character commit SHA** — in workflows,
composite actions, and reusable-workflow references alike, with exactly one
carve-out, named below. Never a tag, never a branch, never an abbreviated SHA. A
tag is a movable pointer: pinning to one gives whoever can retag the upstream
repo a shell on the runner, holding that job's token.

```yaml
uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1 (2023-10-17)
```

- **The trailing `# vX.Y.Z (YYYY-MM-DD)` comment is part of the pin.** Forty hex
  characters say nothing on their own; the version says what it is and the date
  says how stale it is. Dependabot rewrites the SHA and the version but not the
  date, so dates drift — cosmetic, a chore, never an incident.
- **Wait 7 days after a release before adopting it** — the cooling-off above,
  applied by hand. If the newest release is younger than that, pin the previous
  one.
- **Dereference annotated tags.** `gh api repos/<owner>/<repo>/git/ref/tags/<tag>`
  returning `.object.type == "tag"` gives you the tag object's SHA, not the
  commit's, and pinning that fails at runtime. Follow it with
  `git/tags/<that-sha>`, or ask git directly:
  `git ls-remote <url> 'refs/tags/<tag>^{}'`.
- **The one carve-out: a reusable *workflow* from a repo this account owns stays
  on a tag.** `uses: Adam-S-Daniel/cms-platform/.github/workflows/<x>.yml@v0.1.85`
  is correct as written — do not "fix" it to a SHA. The tag is the platform's
  release identity: `platform-bump.yml` moves the `uses:@` refs, the theme gem,
  `platform.lock` and every `platform_ref:` input to one release in a single PR,
  and `check-platform-pin-consistency.js` asserts each of those refs equals
  `platform.lock`'s `platform_ref` — a SHA there fails the lint and strands the
  bump. It stops there: the platform's own composite actions under
  `.github/actions/` take a SHA and the usual `# vX.Y.Z` comment, and nothing
  third-party is ever a tag.
- `./local/path` and `docker://` refs have nothing to pin. Leave them.

`sha_pinning_required: true` enforces the rule at the repo level — set by
`repo-settings`' `fleet.yml` for the fleet and `cms-platform`'s
`repo-settings.yml` for the three sites it manages. It governs **actions**, not
reusable-workflow refs: adamdaniel.ai and jodidaniel.com were already enforcing
it at the 2026-07-13 audit and still call 32 tag-pinned cms-platform reusables
apiece, and four repos on the `fleet.yml` default call one each. That is what
makes the carve-out workable — and what leaves a tag in a *third-party* reusable
ref for review, not the setting, to catch.

## Subagent delegation (model routing)

- Don't write code in the main loop: run the implementation in a subagent on an
  appropriately lower-power model (e.g. the Agent tool's `model` override in
  Claude Code; skip if the harness has no subagent support).
- Route by mechanicalness: smallest model (haiku-class) for exactly-specified
  edits — pin bumps, renames, config/doc tweaks; mid-tier (sonnet-class) for
  normal implementation from a clear spec. Escalate rather than ship a wrong
  diff when the task is genuinely subtle (cross-repo invariants, race
  conditions).
- The main loop keeps root-cause investigation, architectural decisions,
  writing the spec, and review of the subagent's diff before commit.
- Delegated work is done when a **verifier exits 0**, not when the report reads
  as finished. Name the exact command in the spec and require its exit code
  back. A subagent that cannot run it reports BLOCKED; a count that disagrees
  with the spec's stated expectation is a stop-and-report condition, never a
  rounding difference.
- Don't assume the subagent sees this file: general-purpose and custom
  subagents receive the full memory hierarchy (imports included), but
  Explore/Plan-type agents and SDK harnesses with `settingSources: []` skip
  repo guidance entirely. Restate load-bearing constraints (style, test
  command, invariants) in the delegation prompt, and don't hand
  guidance-sensitive work to agents that won't see it.
- **Any prompt that sends a subagent to live-test states the credential
  boundary** — which `HOME`/profile it may use, what it may read, and that it
  must not copy real credentials anywhere to make the test pass. (Real
  incident: a reviewer live-testing a plugin migration in a scratch `HOME`
  copied the account's real OAuth credentials into it. The test worked; nobody
  had asked, and nothing in the prompt forbade it.)
- Supply a throwaway credential, or scope the test to what runs
  unauthenticated. If it genuinely cannot run without a real one, that is the
  operator's call — not a gap for the subagent to close on its own initiative.

## Skills ecosystem

- The canonical skills registry is `github.com/Adam-S-Daniel/agentskills`,
  organized as three bundle plugins — `adam` (general-purpose, cloud-safe;
  default-on), `adam-local` (machine-bound), and `fastmail` — each holding
  `skills/<skill>/` directories.
- In Claude Code with the marketplace installed, invoke a skill as
  `/adam:<skill>` (e.g. `/adam:finding-unknowns`).
- Local machines get the marketplace plus per-agent symlinks via that repo's
  `setup.sh`.
- Cloud/ephemeral sessions still get **no** plugins from repo-declared
  settings — that Claude Code limitation (agentskills' `docs/decisions/0001`)
  is unchanged. What changed is that it now has a fix: a repo carrying its own
  `skills.lock` plus the `skills-bootstrap` SessionStart hook installs the
  bundles that lock names directly into those sessions, verified against a
  pinned commit and per-skill digests. Such a session opens with a `skills:`
  verdict naming what loaded, or why nothing did — read it instead of guessing.
- **Adoption is opt-in and double-keyed, and no longer rare.** Delivery needs
  an allowlist entry in `_agent-guidance`'s `repos.yml` AND a `skills.lock` the
  repo committed itself — the fleet sync never writes one, because the lock is
  where a repo declares which bundles it installs (some federate several
  registries). A repo holds both keys, or is mid-adoption holding one, or is
  deliberately out for a reason — a propagation experiment the bundle would
  contaminate, a dormant repo whose sessions never happen. Which of the three
  fits an unfamiliar repo is not guessable: look for `skills.lock`. Bundles
  cost always-on context in every session that carries them, which is why this
  stays a deliberate per-repo decision and not a fleet default.
- New reusable skills graduate **into** the registry (sensitive ones into
  `agentskills-private`) rather than living on in a consumer repo. A long skill
  splits across files rather than growing into one wall of text.

## Git practices

- Write concise commit messages that explain *why*, not just *what*.
- One logical change per commit.
- Do not amend published commits or force-push shared branches.
- **Merge with a merge commit — `gh pr merge --merge`.** Squash and rebase are
  disabled on every fleet repo, so `--squash` fails rather than falling back;
  do not try it, and do not offer it as a choice. The exceptions are the three
  cms-platform-managed repos (`cms-platform`, `adamdaniel.ai`,
  `jodidaniel.com`), where squash stays enabled because the Decap publish chain
  arms SQUASH auto-merge on every editorial PR and squash is what collapses an
  editor's many per-save commits into one `publish: <title>` commit. Merge
  commits work there too, so `--merge` is the one form that works everywhere.

  Squash is off elsewhere because it is actively unsafe for a repo that pins
  commits by sha: it collapses a branch into a new commit and strands the
  originals on no branch, so a lockfile naming the pre-merge content commit
  (agentskills' `skills.lock`) ends up pinning something a fresh clone of the
  default branch does not contain. Measured on throwaway clones 2026-08-15 —
  `generate_skills_lock.py --check` then fails with `cannot resolve ref`.
  Settings are enforced as code: `repo-settings`' `fleet.yml` for the fleet,
  `cms-platform`'s `repo-settings.yml` for the three above.

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

An agent working in WSL drives Windows through `powershell.exe` / `pwsh.exe`,
and that process inherits a filtered, non-elevated token. There is no way to
raise a UAC prompt from the WSL side. The failure is asymmetric, which is what
makes it easy to misread:

- **Reads succeed** — `Get-ScheduledTask`, `Get-Service`, registry reads. The
  surface looks fully available.
- **Writes fail with "Access is denied"** — `Register-ScheduledTask` /
  `Set-ScheduledTask` on a `RunLevel=HighestAvailable` task, service changes,
  LSA rights grants such as "Log on as a batch job".

Don't chase it with a flag, a retry, or a downgraded principal. Investigate and
compose the command from WSL, then hand the user the exact line to paste into
an **elevated Windows** prompt, and say plainly that it needs elevation. Export
any object you are about to rewrite first (e.g. `Export-ScheduledTask` to XML)
so there is something to restore.
