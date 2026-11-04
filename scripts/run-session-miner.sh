#!/usr/bin/env bash
# Run the daily session miner from inside WSL.
#
# Run by the 'Session Miner' scheduled task, which calls wsl.exe directly (no pwsh
# in between) with this script as the entry point. Arguments are passed through to
# skills-evals' scripts/run_session_miner.sh, so --dry-run works.
#
# This runs ONLY on Adam's own computer (skills-evals ADR 0015). Transcripts never
# leave the machine: only redacted proposal files are pushed, to
# adam-agentskills-private's persistent/lessons branch. Without the denylist file
# (PRIVACY_DENYLIST_FILE, default ~/.config/privacy-denylist.txt) the miner exits 2
# and mines nothing.
#
# It shallow-clones skills-evals `main` and runs that copy instead of a local
# checkout: the owner's local skills-evals checkout sits on arbitrary feature
# branches, and the scheduled run must always execute the reviewed main version.
#
# One line per run is appended to the log (UTC timestamp, exit code, output
# collapsed onto one line). The miner's output is counts only; nothing is added to
# it here, so no path or personal data reaches the log or stdout.
#
# Required setting, with no default: SKILLS_EVALS_URL, the repository to clone.
# Set it in ~/.config/wsl-automation/settings.env or the environment (see
# task-settings.sh and config/settings.env.example); when it is missing the run
# logs a line naming it and exits 2.
#
# Environment seams (for tests):
#   SESSION_MINER_LOG  log file (default: ~/.cache/session-miner.log)
set -euo pipefail

# Update the checkout from main and re-exec this entry first; see
# update-task-checkout.sh. A daily run always tries (interval 0).
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/update-task-checkout.sh
. "$scripts_dir/update-task-checkout.sh"
# shellcheck source=scripts/task-settings.sh
. "$scripts_dir/task-settings.sh"
wsl_automation_task_bootstrap "$scripts_dir/run-session-miner.sh" 0 300 "$@"

# The miner refuses to run without a denylist; default to the owner's file.
export PRIVACY_DENYLIST_FILE=${PRIVACY_DENYLIST_FILE:-$HOME/.config/privacy-denylist.txt}

log=${SESSION_MINER_LOG:-$HOME/.cache/session-miner.log}
mkdir -p -- "$(dirname -- "$log")"

if ! wsl_automation_require_setting SKILLS_EVALS_URL; then
    out='session miner: setting SKILLS_EVALS_URL is missing or invalid'
    printf '%s exit=2 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$out" >>"$log"
    printf '%s\n' "$out"
    exit 2
fi
url=$SKILLS_EVALS_URL

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

rc=0
if git clone --quiet --depth 1 -- "$url" "$tmp/skills-evals" >/dev/null 2>&1; then
    out=$(bash "$tmp/skills-evals/scripts/run_session_miner.sh" "$@" 2>&1) || rc=$?
else
    out='session miner: could not clone skills-evals'
    rc=1
fi

# Collapse newlines (dropping a trailing one) so each run is exactly one log line.
one_line=${out//$'\n'/ | }
printf '%s exit=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$one_line" >>"$log"
printf '%s\n' "$out"
exit "$rc"
