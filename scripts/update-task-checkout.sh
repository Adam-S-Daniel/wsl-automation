# shellcheck shell=bash
# Shared checkout bootstrap for the scheduled-task entry points that run as Bash
# in WSL (publish-usage-census.sh, publish-waiting-feed.sh). It is the Bash side
# of update-task-checkout.ps1, which the PowerShell entry points dot-source.
#
# Source this file first thing and call, before any task work:
#
#   wsl_automation_task_bootstrap ENTRY MIN_INTERVAL_SECONDS DEADLINE_SECONDS "$@"
#
# It updates the Windows checkout through update-task-checkout.ps1 -UpdateOnly,
# so every task shares one updater: Windows Git, the cross-session mutex,
# fast-forward to origin/main only, and fail open on a dirty, diverged or
# offline checkout. It then re-execs ENTRY from disk once (bash reads a script
# as it runs, so the old copy must not keep running) with the same arguments.
# Every failure warns on stderr and lets the task run its current code.
#
# MIN_INTERVAL_SECONDS throttles by attempt, so a short-interval task does not
# start a Windows PowerShell host and fetch every run: when any Bash entry
# started an update less than that long ago, the bootstrap returns at once.
# 0 always tries. DEADLINE_SECONDS bounds the whole Windows update; coreutils
# timeout kills it 5 seconds after that.
#
# Environment seams (for tests):
#   WSL_AUTOMATION_UPDATE_STAMP  attempt stamp (default
#                                ~/.local/state/wsl-automation/checkout-update.stamp)
#   WSL_AUTOMATION_NOW           epoch seconds (default: now)

wsl_automation_task_bootstrap() {
    local entry=$1 min_interval=$2 deadline=$3
    shift 3

    # The re-executed entry; the same guard name as the PowerShell side.
    if [[ ${WSL_AUTOMATION_TASK_REEXEC:-} == "$entry" ]]; then
        return 0
    fi

    local stamp=${WSL_AUTOMATION_UPDATE_STAMP:-$HOME/.local/state/wsl-automation/checkout-update.stamp}
    local now=${WSL_AUTOMATION_NOW:-$(date +%s)}
    local last=''
    if ((min_interval > 0)) && last=$(stat -c %Y -- "$stamp" 2>/dev/null) &&
        ((now >= last && now - last < min_interval)); then
        return 0
    fi
    # Stamp the attempt, not a success: an offline machine retries once per
    # interval instead of every run. A stamp that cannot be written only means
    # the next run tries again.
    { mkdir -p -- "$(dirname -- "$stamp")" && touch -d "@$now" -- "$stamp"; } 2>/dev/null || true

    local helper_dir updater task_pwsh task_timeout
    helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    updater=$(wslpath -w "$helper_dir/update-task-checkout.ps1" 2>/dev/null) || updater=''
    task_pwsh=$(command -v pwsh.exe || true)
    if [[ -z $task_pwsh ]]; then task_pwsh='/mnt/c/Program Files/PowerShell/7/pwsh.exe'; fi
    # Bound even a stuck Windows host. Missing timeout also fails open without starting it.
    task_timeout=$(command -v timeout || true)
    if [[ -z $updater || -z $task_timeout ]] ||
        ! "$task_timeout" --kill-after=5s "${deadline}s" "$task_pwsh" -NoProfile -File "$updater" -UpdateOnly >/dev/null 2>&1; then
        printf '%s\n' 'WARNING: checkout bootstrap unavailable; continuing with current code' >&2
    fi

    # Re-read the entry from disk once, even when HEAD did not move; keep the
    # arguments, and let the entry's own exit status stand.
    export WSL_AUTOMATION_TASK_REEXEC=$entry
    exec /bin/bash "$entry" "$@"
}
