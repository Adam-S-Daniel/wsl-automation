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
# Required setting, with no default: SKILLS_EVALS_URL, the repository to clone.
# Set it in ~/.config/wsl-automation/settings.env or the environment (see
# task-settings.sh and config/settings.env.example); when it is missing the run
# logs a line naming it and exits 2.
#
# Environment seams (for tests):
#   USAGE_CENSUS_LOG   log file (default: ~/.cache/usage-census.log)
set -euo pipefail

# Update the checkout from main and re-exec this entry first; see
# update-task-checkout.sh. A daily run always tries (interval 0).
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/update-task-checkout.sh
. "$scripts_dir/update-task-checkout.sh"
wsl_automation_task_bootstrap "$scripts_dir/publish-usage-census.sh" 0 300 "$@"
# shellcheck source=scripts/task-settings.sh
. "$scripts_dir/task-settings.sh"

log=${USAGE_CENSUS_LOG:-$HOME/.cache/usage-census.log}
mkdir -p -- "$(dirname -- "$log")"

if ! wsl_automation_require_setting SKILLS_EVALS_URL; then
    out='usage census: setting SKILLS_EVALS_URL is missing or invalid'
    printf '%s exit=2 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$out" >>"$log"
    printf '%s\n' "$out"
    exit 2
fi
url=$SKILLS_EVALS_URL

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
