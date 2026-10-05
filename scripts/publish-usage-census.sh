#!/usr/bin/env bash
# Publish the daily usage census from inside WSL.
#
# Run by the 'Usage Census Publish' scheduled task, which calls wsl.exe directly
# (no pwsh in between) with this script as the entry point. Arguments are passed
# through to skills-evals' scripts/publish_usage_census.sh, so --dry-run works.
#
# It shallow-clones skills-evals `main` and runs that copy instead of a local
# checkout: the owner's local skills-evals checkout sits on arbitrary feature
# branches, and the scheduled run must always execute the reviewed main version.
#
# One line per run is appended to the log (UTC timestamp, exit code, output
# collapsed onto one line). The publish script's output is totals only; nothing
# is added to it here, so no path or personal data reaches the log or stdout.
#
# Environment seams (for tests):
#   SKILLS_EVALS_URL   repository to clone (default: the GitHub skills-evals repo)
#   USAGE_CENSUS_LOG   log file (default: ~/.cache/usage-census.log)
set -euo pipefail

# Use Windows Git and the same cross-session mutex as the PowerShell tasks.
# Keep the existing wsl.exe task action: no task re-registration is necessary.
if [[ ${WSL_AUTOMATION_CENSUS_REEXEC:-} != 1 ]]; then
    scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    updater=$(wslpath -w "$scripts_dir/update-task-checkout.ps1" 2>/dev/null) || updater=''
    task_pwsh=$(command -v pwsh.exe || true)
    if [[ -z $task_pwsh ]]; then task_pwsh='/mnt/c/Program Files/PowerShell/7/pwsh.exe'; fi
    if [[ -z $updater ]] || ! "$task_pwsh" -NoProfile -File "$updater" -UpdateOnly >/dev/null 2>&1; then
        printf '%s\n' 'WARNING: checkout bootstrap unavailable; continuing with current code' >&2
    fi
    # Re-read the updated shell source once; retain positional arguments and publish status.
    export WSL_AUTOMATION_CENSUS_REEXEC=1
    exec /bin/bash "$scripts_dir/publish-usage-census.sh" "$@"
fi

url=${SKILLS_EVALS_URL:-https://github.com/Adam-S-Daniel/skills-evals.git}
log=${USAGE_CENSUS_LOG:-$HOME/.cache/usage-census.log}
mkdir -p -- "$(dirname -- "$log")"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

rc=0
if git clone --quiet --depth 1 -- "$url" "$tmp/skills-evals" >/dev/null 2>&1; then
    out=$(bash "$tmp/skills-evals/scripts/publish_usage_census.sh" "$@" 2>&1) || rc=$?
else
    out='usage census: could not clone skills-evals'
    rc=1
fi

# Collapse newlines (dropping a trailing one) so each run is exactly one log line.
one_line=${out//$'\n'/ | }
printf '%s exit=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$one_line" >>"$log"
printf '%s\n' "$out"
exit "$rc"
