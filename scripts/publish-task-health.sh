#!/usr/bin/env bash
# Publishes a small snapshot of this machine's wsl-automation task health as
# task-health.json on the persistent/task-health branch of the private
# Adam-S-Daniel/waiting-feed repository, for the cloud fleet-health audit.
#
# Run daily by the 'Task Health Publish' scheduled task, which calls wsl.exe
# directly. Cloud sessions cannot see Windows Task Scheduler, so this is how the
# audit learns that a task is missing, failing or has stopped running.
#
# The snapshot holds counts, states, numbers and timestamps ONLY: no paths, user
# names, host names, log text or session names. Each source is reduced to a
# timestamp (and, for a WSL task log, the integer after "exit=" on its last
# line); nothing else is read from a log line.
#   - Task states: one Windows PowerShell call (Get-ScheduledTask and
#     Get-ScheduledTaskInfo, which work unelevated). The task names travel as
#     base64 in an environment variable, never inside the command text.
#   - restic: the newest mtime in the repository's snapshots directory. The
#     repository password is root-only here, so restic itself is never run.
#   - The keeper log (Windows) and the WSL task logs: the timestamp of the last line.
#
# The branch is output only and keeps exactly one commit, whose tree holds
# task-health.json and nothing else: each publish replaces it (force-with-lease),
# the same way publish-waiting-feed.sh does. main is a fleet repo's default
# branch, which takes changes only through pull requests, so this never writes it.
# The commit is built from objects, not the clone's index or working tree.
#
# It always publishes (generated_utc is the heartbeat). If the PowerShell call
# fails it still publishes, with "tasks_error": "unavailable" and no tasks, and
# exits 1.
#
# Like every task entry it first updates the shared task checkout from main and
# re-execs itself (update-task-checkout.sh); a daily run always tries.
#
# One line per run goes to stdout and the log: counts only. A --dry-run prints
# it but clones, writes, logs, commits and pushes nothing.
#
# Required setting, with no default: TASK_HEALTH_URL, the target repository. Set it
# in ~/.config/wsl-automation/settings.env or the environment (see
# task-settings.sh and config/settings.env.example); when it is missing the run
# logs a line naming it and exits 2.
#
# Usage: publish-task-health.sh [--dry-run]
#
# Environment seams (for tests):
#   TASK_HEALTH_BRANCH            default persistent/task-health
#   TASK_HEALTH_DIR               clone (default ~/.cache/task-health)
#   TASK_HEALTH_LOG               log file (default ~/.cache/task-health.log)
#   TASK_HEALTH_NOW               epoch seconds (default: now)
#   TASK_HEALTH_PWSH              pwsh.exe (default: on PATH, else the MSI install)
#   TASK_HEALTH_TASKS             comma-separated task names (default: all of them)
#   TASK_HEALTH_RESTIC_SNAPSHOTS  default /mnt/d/Backups/wsl-restic/snapshots
#   TASK_HEALTH_KEEPER_LOG        default: the Windows %LOCALAPPDATA%\wsl-automation\keeper.log
#   TASK_HEALTH_SESSION_MINER_LOG, TASK_HEALTH_MEMORY_CURATION_LOG,
#   TASK_HEALTH_USAGE_CENSUS_LOG, TASK_HEALTH_WAITING_FEED_LOG
#                                 default ~/.cache/<name>.log
set -euo pipefail

# Update the checkout from main and re-exec this entry first; see
# update-task-checkout.sh. A daily run always tries (interval 0).
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/update-task-checkout.sh
. "$scripts_dir/update-task-checkout.sh"
wsl_automation_task_bootstrap "$scripts_dir/publish-task-health.sh" 0 300 "$@"
# shellcheck source=scripts/task-settings.sh
. "$scripts_dir/task-settings.sh"

# The task starts a non-login shell (wsl.exe --exec), whose PATH lacks
# ~/.local/bin, where jq may be installed. Append it so system tools still win.
PATH="$PATH:$HOME/.local/bin"

# Never wait on a credential prompt: the task runs with no one to answer it.
export GIT_TERMINAL_PROMPT=0

readonly log_max_lines=2000
readonly powershell_timeout=120
readonly default_tasks='WSL Ubuntu Daily Backup,Claude Code Session Keeper,Claude Code Session Launcher,Codex Remote Control Launcher,ccstatusline Config Sync,Codex Cloud Environment Sync,Usage Census Publish,Session Miner,Memory Curation,Claude Waiting Feed Publish,Task Health Publish'

dry_run=false
case "${1:-}" in
    '') ;;
    --dry-run) dry_run=true ;;
    *)
        printf '%s\n' 'usage: publish-task-health.sh [--dry-run]' >&2
        exit 2
        ;;
esac

branch=${TASK_HEALTH_BRANCH:-persistent/task-health}
clone_dir=${TASK_HEALTH_DIR:-$HOME/.cache/task-health}
log_file=${TASK_HEALTH_LOG:-$HOME/.cache/task-health.log}
now=${TASK_HEALTH_NOW:-$(date +%s)}
tasks_csv=${TASK_HEALTH_TASKS:-$default_tasks}
snapshots_dir=${TASK_HEALTH_RESTIC_SNAPSHOTS:-/mnt/d/Backups/wsl-restic/snapshots}

for dependency in jq git flock mktemp timeout base64 find; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'missing dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done

mkdir -p -- "$HOME/.cache"
exec 9>"$HOME/.cache/task-health-publish.lock"
if ! flock -n 9; then
    printf '%s\n' 'another task health publish is already running' >&2
    exit 1
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf -- "$temporary_dir"' EXIT

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
timestamp=$(iso "$now")

log_line() {
    mkdir -p -- "$(dirname -- "$log_file")"
    printf '%s exit=%s %s\n' "$timestamp" "$2" "$1" >>"$log_file"
    # Keep only the most recent lines.
    if (($(wc -l <"$log_file") > log_max_lines)); then
        tail -n "$((log_max_lines / 2))" -- "$log_file" >"$log_file.tmp" && mv -f -- "$log_file.tmp" "$log_file"
    fi
}

if ! wsl_automation_require_setting TASK_HEALTH_URL; then
    line='task health: setting TASK_HEALTH_URL is missing or invalid'
    printf '%s\n' "$line"
    if ! $dry_run; then log_line "$line" 2; fi
    exit 2
fi
target_url=$TASK_HEALTH_URL

# --- Task states: ONE Windows PowerShell call --------------------------------
names_json=$(jq -Rc 'split(",") | map(select(length > 0))' <<<"$tasks_csv")
pwsh=${TASK_HEALTH_PWSH:-}
if [[ -z $pwsh ]]; then
    pwsh=$(command -v pwsh.exe 2>/dev/null || true)
    pwsh=${pwsh:-/mnt/c/Program\ Files/PowerShell/7/pwsh.exe}
fi
# Fixed text with no task name in it: the names arrive as base64 in an
# environment variable (forwarded into Windows through WSLENV) and are only ever
# compared with Get-ScheduledTask's own TaskName values, never evaluated.
# shellcheck disable=SC2016
ps_script='$ErrorActionPreference = "Stop"
$names = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:WSL_TASK_HEALTH_NAMES)) -split "`n" | Where-Object { $_ })
$all = @(Get-ScheduledTask)
function ConvertTo-UtcText($d) { if ($d -and $d.Year -ge 2000) { $d.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null } }
$rows = foreach ($n in $names) {
    $row = [ordered]@{ name = $n; state = "missing"; last_run_utc = $null; last_result = $null; last_result_hex = $null; next_run_utc = $null }
    $t = $all | Where-Object { $_.TaskName -eq $n } | Select-Object -First 1
    if ($t) {
        $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
        $row.state = [string]$t.State
        $row.last_run_utc = ConvertTo-UtcText $i.LastRunTime
        $row.last_result = [int64]$i.LastTaskResult
        $row.last_result_hex = "0x{0:X}" -f [int64]$i.LastTaskResult
        $row.next_run_utc = ConvertTo-UtcText $i.NextRunTime
    }
    [pscustomobject]$row
}
ConvertTo-Json -Compress -InputObject @($rows)'
names_b64=$(jq -r 'join("\n")' <<<"$names_json" | base64 -w0)
tasks_error=false
ps_json=''
if ps_out=$(WSL_TASK_HEALTH_NAMES=$names_b64 WSLENV="WSL_TASK_HEALTH_NAMES${WSLENV:+:$WSLENV}" \
    timeout "$powershell_timeout" "$pwsh" -NoProfile -NonInteractive -Command "$ps_script" </dev/null 2>/dev/null) &&
    jq -e 'type == "array"' <<<"$ps_out" >/dev/null 2>&1; then
    ps_json=$ps_out
else
    tasks_error=true
    names_json='[]'
    ps_json='[]'
fi

# Keep only the known fields, in the expected types, for each wanted task in
# order; a task the call did not return is "missing".
tasks_json=$(jq -c --argjson names "$names_json" '
    def ts: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else null end;
    . as $rows
    | $names | map(. as $n
        | (($rows | map(select(type == "object" and .name == $n)) | .[0]) // null) as $r
        | if $r == null then
            {name: $n, state: "missing", last_run_utc: null, last_result: null, last_result_hex: null, next_run_utc: null}
          else
            {name: $n,
             state: (if ($r.state | type) == "string" and ($r.state | test("^[A-Za-z]{1,20}$")) then $r.state else "unknown" end),
             last_run_utc: ($r.last_run_utc | ts),
             last_result: (if ($r.last_result | type) == "number" then $r.last_result else null end),
             last_result_hex: (if ($r.last_result_hex | type) == "string" and ($r.last_result_hex | test("^0x[0-9A-F]{1,16}$")) then $r.last_result_hex else null end),
             next_run_utc: ($r.next_run_utc | ts)}
          end)
' <<<"$ps_json")

# --- Output ages: timestamps (and exit codes) only ----------------------------
last_line() {
    if [[ -f $1 && -r $1 ]]; then
        tail -n 1 -- "$1" 2>/dev/null | tr -d '\r' || true
    fi
}

restic_utc=''
if [[ -d $snapshots_dir ]]; then
    newest=$(find "$snapshots_dir" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -rn | sed -n 1p || true)
    if [[ ${newest%%.*} =~ ^[0-9]+$ ]]; then
        restic_utc=$(iso "${newest%%.*}")
    fi
fi

keeper_log=${TASK_HEALTH_KEEPER_LOG:-}
if [[ -z $keeper_log ]]; then
    # The Windows %LOCALAPPDATA%, resolved now: no user name is hardcoded here.
    local_app_data=$( (cd /mnt/c 2>/dev/null || true; timeout 30 cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null </dev/null) | tr -d '\r' || true)
    if [[ -n $local_app_data && $local_app_data != *%* ]]; then
        keeper_dir=$(wslpath -u "$local_app_data" 2>/dev/null || true)
        if [[ -n $keeper_dir ]]; then
            keeper_log="$keeper_dir/wsl-automation/keeper.log"
        fi
    fi
fi
keeper_utc=''
keeper_line=$(last_line "$keeper_log")
if [[ $keeper_line =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    # The keeper logs local time: read it in this machine's zone (date -u would
    # take it as UTC), then print the instant in UTC.
    keeper_epoch=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null || true)
    if [[ $keeper_epoch =~ ^[0-9]+$ ]]; then
        keeper_utc=$(iso "$keeper_epoch")
    fi
fi

# One WSL task log: sets <prefix>_run (ISO UTC) and <prefix>_exit (integer) from
# the last line, empty when unavailable.
read_task_log() {
    local line run='' code=''
    line=$(last_line "$2")
    if [[ $line =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\  ]]; then
        run=${BASH_REMATCH[1]}
    fi
    if [[ $line =~ \ exit=([0-9]{1,5})(\ |$) ]]; then
        code=${BASH_REMATCH[1]}
    fi
    printf -v "$1_run" '%s' "$run"
    printf -v "$1_exit" '%s' "$code"
}
session_miner_run='' session_miner_exit='' memory_curation_run='' memory_curation_exit=''
usage_census_run='' usage_census_exit='' waiting_feed_run='' waiting_feed_exit=''
read_task_log session_miner "${TASK_HEALTH_SESSION_MINER_LOG:-$HOME/.cache/session-miner.log}"
read_task_log memory_curation "${TASK_HEALTH_MEMORY_CURATION_LOG:-$HOME/.cache/memory-curation.log}"
read_task_log usage_census "${TASK_HEALTH_USAGE_CENSUS_LOG:-$HOME/.cache/usage-census.log}"
read_task_log waiting_feed "${TASK_HEALTH_WAITING_FEED_LOG:-$HOME/.cache/waiting-feed.log}"

new_file="$temporary_dir/task-health.json"
jq -n -S --arg generated "$timestamp" --argjson tasks "$tasks_json" --argjson tasks_error "$tasks_error" \
    --arg restic "$restic_utc" --arg keeper "$keeper_utc" \
    --arg sm_run "$session_miner_run" --arg sm_exit "$session_miner_exit" \
    --arg mc_run "$memory_curation_run" --arg mc_exit "$memory_curation_exit" \
    --arg uc_run "$usage_census_run" --arg uc_exit "$usage_census_exit" \
    --arg wf_run "$waiting_feed_run" --arg wf_exit "$waiting_feed_exit" '
    def text: if . == "" then null else . end;
    def code: if . == "" then null else tonumber end;
    {
        schema: 1,
        generated_utc: $generated,
        tasks: $tasks,
        outputs: {
            restic_latest_snapshot_utc: ($restic | text),
            keeper_last_line_utc: ($keeper | text),
            session_miner_last_run_utc: ($sm_run | text),
            session_miner_last_exit: ($sm_exit | code),
            memory_curation_last_run_utc: ($mc_run | text),
            memory_curation_last_exit: ($mc_exit | code),
            usage_census_last_run_utc: ($uc_run | text),
            usage_census_last_exit: ($uc_exit | code),
            waiting_feed_last_run_utc: ($wf_run | text),
            waiting_feed_last_exit: ($wf_exit | code)
        }
    } + (if $tasks_error then {tasks_error: "unavailable"} else {} end)
' >"$new_file"

task_count=$(jq '.tasks | length' "$new_file")
missing_count=$(jq '[.tasks[] | select(.state == "missing")] | length' "$new_file")
nonzero_count=$(jq '[.tasks[] | select(.last_result != null and .last_result != 0)] | length' "$new_file")
known_count=$(jq '[.outputs[] | select(. != null)] | length' "$new_file")

# --- Publish: one parentless commit replaces the branch ----------------------
published=no
rc=0
if [[ $tasks_error == true ]]; then
    rc=1
fi

# Only ever push to the repository this script was configured with (compared
# without a trailing .git or slash).
same_repo() {
    local a=${1%/} b=${2%/}
    [[ ${a%.git} == "${b%.git}" ]]
}

publish() {
    local git_clone=(git -C "$clone_dir") main_head prev_head blob tree new_head message
    if [[ ! -d $clone_dir/.git ]]; then
        mkdir -p -- "$(dirname -- "$clone_dir")"
        timeout 60 git clone --quiet -- "$target_url" "$clone_dir" >/dev/null 2>&1 || return 1
    fi
    same_repo "$("${git_clone[@]}" remote get-url origin 2>/dev/null || true)" "$target_url" || return 1
    # The remote is the source of truth: a commit made there by hand must not
    # wedge later pushes. Keeping the checkout on origin/main keeps the hooks it
    # carries current.
    if timeout 60 "${git_clone[@]}" fetch --quiet --prune origin >/dev/null 2>&1 &&
        main_head=$("${git_clone[@]}" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null); then
        "${git_clone[@]}" reset --quiet --hard "$main_head" >/dev/null 2>&1 || true
    fi
    prev_head=$("${git_clone[@]}" rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null || true)
    # A fixed noreply identity and a UTC date, whatever the machine's git config.
    export GIT_AUTHOR_NAME='Adam Daniel' GIT_COMMITTER_NAME='Adam Daniel'
    export GIT_AUTHOR_EMAIL=4205216+Adam-S-Daniel@users.noreply.github.com
    export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    export GIT_AUTHOR_DATE="$now +0000" GIT_COMMITTER_DATE="$now +0000"
    message="Update task health (tasks=$task_count missing=$missing_count)"
    # The lease refuses the push if the remote moved since the fetch.
    blob=$("${git_clone[@]}" hash-object -w -- "$new_file") &&
        tree=$(printf '100644 blob %s\ttask-health.json\n' "$blob" | "${git_clone[@]}" mktree) &&
        new_head=$("${git_clone[@]}" commit-tree "$tree" -m "$message" 2>/dev/null) &&
        timeout 60 "${git_clone[@]}" push --quiet --force-with-lease="$branch:$prev_head" origin "$new_head:refs/heads/$branch" >/dev/null 2>&1
}

if $dry_run; then
    published=dry-run
elif publish; then
    published=yes
else
    rc=1
fi

line="task health: tasks=$task_count missing=$missing_count nonzero_results=$nonzero_count outputs_known=$known_count published=$published"
printf '%s\n' "$line"
if ! $dry_run; then
    log_line "$line" "$rc"
fi
exit "$rc"
