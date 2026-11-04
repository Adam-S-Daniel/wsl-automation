#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/publish-task-health.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

passed=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    passed=$((passed + 1))
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "$3: expected '$2', got '$1'"
    pass
}

assert_match() {
    [[ $1 =~ $2 ]] || fail "$3: '$1' does not match '$2'"
    pass
}

assert_no_match() {
    [[ ! $1 =~ $2 ]] || fail "$3: '$1' unexpectedly matches '$2'"
    pass
}

# --- Environment: nothing here touches the real HOME ---------------------------
now=1790000000
remote="$test_root/remote.git"
git init --quiet --bare -b main "$remote"
export HOME="$test_root/home"
export GIT_CONFIG_NOSYSTEM=1
export TZ=America/New_York
mkdir -p "$HOME/.cache" "$test_root/bin" "$test_root/fx" "$test_root/run"

# main stands in for a fleet repo's default branch, with files of its own.
seed="$test_root/seed"
GIT_CONFIG_GLOBAL=/dev/null git init --quiet -b main "$seed"
printf '%s\n' 'fleet file' >"$seed/AGENTS.md"
GIT_CONFIG_GLOBAL=/dev/null git -C "$seed" add AGENTS.md
GIT_CONFIG_GLOBAL=/dev/null git -C "$seed" -c user.name=x -c user.email=x@example.com commit --quiet -m 'fleet delivery'
GIT_CONFIG_GLOBAL=/dev/null git -C "$seed" push --quiet "$remote" HEAD:main
main_seed=$(git --git-dir="$remote" rev-parse main)
# Like the fleet's agent-checks pre-push hook: refuse a push to main.
mkdir -p "$test_root/hooks"
cat >"$test_root/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
while read -r _ _ remote_ref _; do
    [[ $remote_ref == refs/heads/main ]] && { echo 'test hook: push to main' >&2; exit 1; }
done
exit 0
HOOK
chmod +x "$test_root/hooks/pre-push"
printf '[core]\n\thooksPath = %s\n' "$test_root/hooks" >"$test_root/gitconfig"
export GIT_CONFIG_GLOBAL="$test_root/gitconfig"

# --- Stubs: pwsh.exe, cmd.exe, wslpath ----------------------------------------
export FX="$test_root/fx"
export PWSH_ARGV="$test_root/pwsh-argv"
export PWSH_NAMES="$test_root/pwsh-names"
export PWSH_WSLENV="$test_root/pwsh-wslenv"
export WIN_LOCAL="$test_root/winlocal"
cat >"$test_root/bin/pwsh.exe" <<'EOF_STUB'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "${args//$'\n'/ }" >>"$PWSH_ARGV"
printf '%s\n' "$WSLENV" >>"$PWSH_WSLENV"
printf '%s' "$WSL_TASK_HEALTH_NAMES" | base64 -d >"$PWSH_NAMES"
[[ ${PWSH_FAIL:-0} != 1 ]] || exit 5
cat -- "$FX/ps.json"
EOF_STUB
cat >"$test_root/bin/cmd.exe" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s\r\n' 'C:\Users\tester\AppData\Local'
EOF_STUB
cat >"$test_root/bin/wslpath" <<'EOF_STUB'
#!/usr/bin/env bash
[[ $1 == -u && $2 == 'C:\Users\tester\AppData\Local' ]] || exit 1
printf '%s\n' "$WIN_LOCAL"
EOF_STUB
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"

# Never read the real settings file: point it at one that does not exist.
export WSL_AUTOMATION_SETTINGS="$test_root/no-such-settings.env"

# --- Fixtures -----------------------------------------------------------------
# shellcheck disable=SC2016
evil_name='Evil "x" $(touch PWNED) `touch PWNED2`'
tasks_csv="Task A,Task B,Task Gone,$evil_name"
cat >"$FX/ps.json" <<'EOF_JSON'
[
  {"name": "Task A", "state": "Ready", "last_run_utc": "2026-09-22T03:00:00Z", "last_result": 0,
   "last_result_hex": "0x0", "next_run_utc": "2026-09-23T03:00:00Z", "extra": "/home/secret/path"},
  {"name": "Task B", "state": "Disabled", "last_run_utc": null, "last_result": 2147942405,
   "last_result_hex": "0x80070005", "next_run_utc": null},
  {"name": "Not Requested", "state": "Ready", "last_run_utc": null, "last_result": 0,
   "last_result_hex": "0x0", "next_run_utc": null}
]
EOF_JSON

# The newest snapshot file decides; older ones and directories do not.
snapshots="$test_root/snapshots"
mkdir -p "$snapshots/subdir"
touch -d '@1788000000' "$snapshots/aaaa"
touch -d '@1789000000' "$snapshots/bbbb"
touch -d '@1789500000' "$snapshots/subdir"
# keeper.log is local time (TZ is America/New_York, EST on 2026-11-03).
mkdir -p "$WIN_LOCAL/wsl-automation"
printf '2026-11-02 09:00:00  older line\r\n2026-11-03 10:10:02  Claude Remote Control is running SECRETKEEPERTEXT\r\n' \
    >"$WIN_LOCAL/wsl-automation/keeper.log"
printf '%s\n' '2026-11-01T21:48:54Z exit=1 old line' '2026-11-02T21:48:54Z exit=0 session miner: SECRETMINERTEXT /home/x' \
    >"$HOME/.cache/session-miner.log"
printf '%s\n' '2026-11-03T15:06:02Z exit=3 memory curation: mode=live' >"$HOME/.cache/memory-curation.log"
# No usage-census.log at all. A waiting-feed line with no exit= field.
printf '%s\n' '2026-11-03T15:10:01Z waiting feed: ok=true' >"$HOME/.cache/waiting-feed.log"

export TASK_HEALTH_URL="file://$remote"
export TASK_HEALTH_DIR="$test_root/clone"
export TASK_HEALTH_LOG="$test_root/cache/task-health.log"
export TASK_HEALTH_NOW=$now
export TASK_HEALTH_PWSH="$test_root/bin/pwsh.exe"
export TASK_HEALTH_TASKS="$tasks_csv"
export TASK_HEALTH_RESTIC_SNAPSHOTS="$snapshots"
export XDG_RUNTIME_DIR="$test_root/run"
# The checkout bootstrap has its own test (update-task-checkout.test.sh); mark
# these runs as already re-executed so they test publishing only. The wiring
# check at the end clears this.
export WSL_AUTOMATION_TASK_REEXEC="$script"

out=''
rc=0
run_health() {
    rc=0
    out=$(bash "$script" "$@" 2>&1) || rc=$?
}
feed_ref=persistent/task-health
log_count() { if [[ -f $TASK_HEALTH_LOG ]]; then wc -l <"$TASK_HEALTH_LOG" | tr -d ' '; else echo 0; fi; }
commit_count() { git --git-dir="$remote" rev-list --count "$feed_ref" 2>/dev/null || echo 0; }
remote_head() { git --git-dir="$remote" rev-parse -q --verify "$feed_ref" 2>/dev/null || echo none; }
remote_json() { git --git-dir="$remote" show "$feed_ref:task-health.json"; }
remote_jq() { remote_json | jq -r "$1"; }

# --- --dry-run first: nothing is cloned, written, logged or pushed --------------
run_health --dry-run
assert_eq "$rc" 0 'dry run exits 0'
assert_eq "$out" 'task health: tasks=4 missing=2 nonzero_results=1 outputs_known=7 published=dry-run' 'dry run prints the counts line'
assert_eq "$(remote_head)" none 'dry run creates no branch'
assert_eq "$(find "$test_root/clone" -mindepth 1 2>/dev/null | wc -l | tr -d " ")" 0 'dry run does not even clone'
assert_eq "$(log_count)" 0 'dry run is not logged'

# --- First publish: shape and values -------------------------------------------
run_health
assert_eq "$rc" 0 'first publish exits 0'
assert_eq "$out" 'task health: tasks=4 missing=2 nonzero_results=1 outputs_known=7 published=yes' 'first publish line'
assert_eq "$(commit_count)" 1 'first publish pushes one commit'
assert_eq "$(git --git-dir="$remote" ls-tree --name-only "$feed_ref")" task-health.json 'the tree holds only task-health.json'
assert_eq "$(remote_jq 'keys_unsorted | join(",")')" 'generated_utc,outputs,schema,tasks' 'top-level keys are sorted'
assert_eq "$(remote_jq '.schema')" 1 'schema is 1'
assert_eq "$(remote_jq '.generated_utc')" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" 'generated_utc is the UTC time'
assert_eq "$(remote_jq 'has("tasks_error")')" false 'no tasks_error on success'
assert_eq "$(remote_jq '.tasks | length')" 4 'one entry per requested task'
assert_eq "$(remote_jq '[.tasks[].name] | join("|")')" "Task A|Task B|Task Gone|$evil_name" 'tasks keep the requested order (and drop unrequested ones)'
assert_eq "$(remote_jq '.tasks[0] | keys_unsorted | join(",")')" 'last_result,last_result_hex,last_run_utc,name,next_run_utc,state' 'task keys are sorted'
assert_eq "$(remote_jq '.tasks[0] | [.state, .last_run_utc, .last_result, .last_result_hex, .next_run_utc] | map(tostring) | join(" ")')" \
    'Ready 2026-09-22T03:00:00Z 0 0x0 2026-09-23T03:00:00Z' 'task A values'
assert_eq "$(remote_jq '.tasks[1] | [.state, .last_run_utc, .last_result, .last_result_hex, .next_run_utc] | map(tostring) | join(" ")')" \
    'Disabled null 2147942405 0x80070005 null' 'task B values (large result, null times)'
assert_eq "$(remote_jq '.tasks[2] | [.state, .last_run_utc, .last_result, .last_result_hex, .next_run_utc] | map(tostring) | join(" ")')" \
    'missing null null null null' 'a task the host did not return is missing'
assert_eq "$(remote_jq '.tasks[3].state')" missing 'the odd task name is just another missing task'
assert_no_match "$(remote_json)" 'secret|SECRET' 'no extra field or log text reaches the file'

assert_eq "$(remote_jq '.outputs | keys_unsorted | join(",")')" \
    'keeper_last_line_utc,memory_curation_last_exit,memory_curation_last_run_utc,restic_latest_snapshot_utc,session_miner_last_exit,session_miner_last_run_utc,usage_census_last_exit,usage_census_last_run_utc,waiting_feed_last_exit,waiting_feed_last_run_utc' 'output keys'
assert_eq "$(remote_jq '.outputs.restic_latest_snapshot_utc')" "$(date -u -d '@1789000000' +%Y-%m-%dT%H:%M:%SZ)" 'restic: newest snapshot file mtime'
assert_eq "$(remote_jq '.outputs.keeper_last_line_utc')" 2026-11-03T15:10:02Z 'keeper: last line local time converted to UTC'
assert_eq "$(remote_jq '.outputs.session_miner_last_run_utc')" 2026-11-02T21:48:54Z 'session miner timestamp is from the last line'
assert_eq "$(remote_jq '.outputs.session_miner_last_exit')" 0 'session miner exit is from the last line'
assert_eq "$(remote_jq '.outputs.memory_curation_last_run_utc')" 2026-11-03T15:06:02Z 'memory curation timestamp'
assert_eq "$(remote_jq '.outputs.memory_curation_last_exit')" 3 'a nonzero exit is parsed as a number'
assert_eq "$(remote_jq '.outputs.usage_census_last_run_utc')" null 'a missing log gives a null timestamp'
assert_eq "$(remote_jq '.outputs.usage_census_last_exit')" null 'a missing log gives a null exit'
assert_eq "$(remote_jq '.outputs.waiting_feed_last_run_utc')" 2026-11-03T15:10:01Z 'a line without exit= still gives its timestamp'
assert_eq "$(remote_jq '.outputs.waiting_feed_last_exit')" null 'a line without exit= gives a null exit'

assert_eq "$(git --git-dir="$remote" log -1 --format=%ae "$feed_ref")" '4205216+Adam-S-Daniel@users.noreply.github.com' 'fixed noreply identity'
assert_eq "$(git --git-dir="$remote" rev-list --max-parents=0 "$feed_ref")" "$(remote_head)" 'the commit has no parent'
assert_eq "$(git --git-dir="$remote" rev-parse main)" "$main_seed" 'main is never written'
assert_eq "$(git -C "$TASK_HEALTH_DIR" status --short)" '' 'the clone stays clean'

# --- Task names reach PowerShell as data, never as command text -----------------
assert_eq "$(sed -n 1,4p "$PWSH_NAMES" | tr '\n' '|')" "Task A|Task B|Task Gone|$evil_name|" 'PowerShell received every name intact'
assert_no_match "$(cat "$PWSH_ARGV")" 'touch|Task A|Evil' 'no task name is in the PowerShell command line'
assert_match "$(sed -n 1p "$PWSH_ARGV")" '^-NoProfile -NonInteractive -Command ' 'PowerShell runs without a profile'
assert_match "$(sed -n 1p "$PWSH_WSLENV")" '(^|:)WSL_TASK_HEALTH_NAMES(:|$)' 'the names variable is forwarded through WSLENV'
assert_eq "$(wc -l <"$PWSH_ARGV" | tr -d ' ')" 2 'exactly one PowerShell call per run'
[[ ! -e PWNED && ! -e PWNED2 && ! -e "$test_root/PWNED" && ! -e "$HOME/PWNED" ]] || fail 'a task name was executed'
pass

# --- The log line is counts only ------------------------------------------------
assert_eq "$(log_count)" 1 'a publishing run is logged'
assert_match "$(sed -n 1p "$TASK_HEALTH_LOG")" '^2026-09-21T14:13:20Z exit=0 task health: tasks=4 missing=2 nonzero_results=1 outputs_known=7 published=yes$' 'log line format'
assert_no_match "$(cat "$TASK_HEALTH_LOG")$out" "$test_root|Task A|SECRET|/home" 'log and output carry no path, name or log text'

# --- A second publish replaces the single commit --------------------------------
first_head=$(remote_head)
TASK_HEALTH_NOW=$((now + 86400)) run_health
assert_eq "$rc" 0 'second publish exits 0'
assert_eq "$(commit_count)" 1 'the branch still holds exactly one commit'
assert_no_match "$(remote_head)" "^$first_head\$" 'the commit was replaced'
assert_eq "$(git --git-dir="$remote" ls-tree -r --name-only "$feed_ref")" task-health.json 'still exactly one file'
assert_eq "$(remote_jq '.generated_utc')" "$(date -u -d "@$((now + 86400))" +%Y-%m-%dT%H:%M:%SZ)" 'generated_utc is the heartbeat'
assert_eq "$(git --git-dir="$remote" rev-parse main)" "$main_seed" 'main is still untouched'
assert_eq "$(log_count)" 2 'the second run is logged'

# --- --dry-run with a clone present pushes nothing ------------------------------
before=$(remote_head)
TASK_HEALTH_NOW=$((now + 90000)) run_health --dry-run
assert_eq "$rc" 0 'dry run with a clone exits 0'
assert_eq "$(remote_head)" "$before" 'dry run pushes nothing'
assert_eq "$(log_count)" 2 'dry run is still not logged'

# --- Push only to the configured URL -------------------------------------------
decoy="$test_root/decoy.git"
git init --quiet --bare -b main "$decoy"
git -C "$TASK_HEALTH_DIR" remote set-url origin "file://$decoy"
TASK_HEALTH_NOW=$((now + 90000)) run_health
assert_eq "$rc" 1 'a clone pointing elsewhere exits nonzero'
assert_match "$out" 'published=no$' 'a clone pointing elsewhere is not published'
assert_eq "$(git --git-dir="$decoy" for-each-ref | wc -l | tr -d ' ')" 0 'nothing reached the other repository'
assert_eq "$(remote_head)" "$before" 'nothing reached the configured one either'
git -C "$TASK_HEALTH_DIR" remote set-url origin "file://$remote"

# --- An unreachable remote fails the run, after logging ---------------------------
rc=0
out=$(TASK_HEALTH_URL="file://$test_root/missing.git" TASK_HEALTH_DIR="$test_root/clone2" bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 1 'a failed clone exits nonzero'
assert_match "$out" 'published=no$' 'a failed clone is reported'
assert_match "$(tail -n 1 "$TASK_HEALTH_LOG")" ' exit=1 task health: .* published=no$' 'a failed clone is logged with exit 1'

# --- A PowerShell failure still publishes, with tasks_error, and exits 1 ----------
TASK_HEALTH_NOW=$((now + 100000)) PWSH_FAIL=1 run_health
assert_eq "$rc" 1 'a PowerShell failure exits nonzero'
assert_eq "$out" 'task health: tasks=0 missing=0 nonzero_results=0 outputs_known=7 published=yes' 'a PowerShell failure still publishes'
assert_eq "$(remote_jq '.tasks_error')" unavailable 'tasks_error is published'
assert_eq "$(remote_jq '.tasks | length')" 0 'no tasks are published'
assert_eq "$(remote_jq '.outputs.memory_curation_last_exit')" 3 'the other outputs are still published'
assert_eq "$(commit_count)" 1 'the failure publish still leaves one commit'
assert_match "$(tail -n 1 "$TASK_HEALTH_LOG")" ' exit=1 task health: tasks=0 ' 'the failure is logged with exit 1'
rc=0
out=$(TASK_HEALTH_NOW=$((now + 100100)) TASK_HEALTH_PWSH="$test_root/no-such-pwsh.exe" bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 1 'a missing pwsh.exe exits nonzero'
assert_eq "$(remote_jq '.tasks_error')" unavailable 'a missing pwsh.exe is published as unavailable'
printf '%s\n' 'not json' >"$FX/ps.json"
TASK_HEALTH_NOW=$((now + 100300)) run_health
assert_eq "$rc" 1 'output that is not JSON exits nonzero'
assert_eq "$(remote_jq '.tasks_error')" unavailable 'output that is not JSON is unavailable'

# --- An unresolvable keeper log is null, not a failure ----------------------------
cat >"$test_root/bin/cmd.exe" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s\r\n' '%LOCALAPPDATA%'
EOF_STUB
printf '%s\n' '[]' >"$FX/ps.json"
TASK_HEALTH_NOW=$((now + 100400)) TASK_HEALTH_TASKS=',' run_health
assert_eq "$rc" 0 'an unresolved %LOCALAPPDATA% is not a failure'
assert_eq "$(remote_jq '.outputs.keeper_last_line_utc')" null 'an unresolved keeper log is null'
assert_eq "$(remote_jq '.tasks | length')" 0 'an empty task list is published as such'
TASK_HEALTH_NOW=$((now + 100500)) TASK_HEALTH_KEEPER_LOG="$WIN_LOCAL/wsl-automation/keeper.log" run_health
assert_eq "$(remote_jq '.outputs.keeper_last_line_utc')" 2026-11-03T15:10:02Z 'the keeper log seam overrides the resolution'

# --- The entry updates its checkout first: every run, within 300 s ----------------
mkdir -p "$test_root/bootstrap-bin"
export BOOTSTRAP_CALLS="$test_root/bootstrap-calls"
cat >"$test_root/bootstrap-bin/wslpath" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s\n' "$2"
EOF_STUB
# Record only the bootstrap; the publisher's own timeout calls run for real.
real_timeout=$(command -v timeout)
cat >"$test_root/bootstrap-bin/timeout" <<EOF_STUB
#!/usr/bin/env bash
if [[ \${*: -1} == -UpdateOnly ]]; then
    printf '%s\\n' "\$*" >>"\$BOOTSTRAP_CALLS"
    exit 0
fi
exec $real_timeout "\$@"
EOF_STUB
chmod +x "$test_root/bootstrap-bin/"*
printf '%s\n' '[]' >"$FX/ps.json"
rc=0
out=$(env -u WSL_AUTOMATION_TASK_REEXEC PATH="$test_root/bootstrap-bin:$PATH" \
    WSL_AUTOMATION_UPDATE_STAMP="$test_root/state/stamp" WSL_AUTOMATION_NOW="$now" \
    bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 0 'a bootstrapped run still publishes'
assert_match "$out" 'published=dry-run$' 'the bootstrapped run reaches the publisher with its arguments'
assert_match "$(sed -n 1p "$BOOTSTRAP_CALLS")" '^--kill-after=5s 300s .*pwsh\.exe -NoProfile -File .*/scripts/update-task-checkout\.ps1 -UpdateOnly$' 'the task updates through the shared updater within 300 s'

# --- TASK_HEALTH_URL is a required setting with no fallback ------------------
# (1) Unset and no settings file: exit 2, naming the key, publishing nothing.
before=$(remote_head)
rc=0
out=$(env -u TASK_HEALTH_URL TASK_HEALTH_NOW=$((now + 200000)) bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 2 'a missing TASK_HEALTH_URL exits 2'
assert_match "$out" 'TASK_HEALTH_URL is not set; set it in ~/.config/wsl-automation/settings.env' 'the error names the key and where to set it'
assert_match "$out" 'task health: setting TASK_HEALTH_URL is missing or invalid' 'the failure is reported on stdout'
assert_match "$(tail -n 1 "$TASK_HEALTH_LOG")" ' exit=2 task health: setting TASK_HEALTH_URL is missing or invalid$' 'the failure is logged with exit 2 and names the key'
[[ $(tail -n 1 "$TASK_HEALTH_LOG") != *"$test_root"* ]] || fail 'the log line must not hold a path'
pass
assert_eq "$(remote_head)" "$before" 'nothing was published without the setting'

# (2) Provided only by a settings file: the snapshot is pushed to it.
fresh_remote="$test_root/fresh-remote.git"
git init --quiet --bare -b main "$fresh_remote"
printf '# comment\nOTHER_KEY=ignored\n\nTASK_HEALTH_URL=file://%s\n' "$fresh_remote" >"$test_root/settings.env"
rc=0
out=$(env -u TASK_HEALTH_URL WSL_AUTOMATION_SETTINGS="$test_root/settings.env" TASK_HEALTH_DIR="$test_root/clone-settings" \
    TASK_HEALTH_NOW=$((now + 200100)) bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 0 'TASK_HEALTH_URL from the settings file is used'
assert_match "$out" 'published=yes$' 'the run with the file setting publishes'
assert_eq "$(git --git-dir="$fresh_remote" rev-list --count "$feed_ref")" 1 'the snapshot reached the repository named in the file'

printf 'PASS: %s assertions\n' "$passed"
