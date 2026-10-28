#!/usr/bin/env bash
# Behavior test for scripts/update-task-checkout.sh, the Bash task bootstrap.
# Only the Windows side is stubbed (wslpath, pwsh.exe, timeout); no real
# checkout, Windows process or home directory is touched.
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
helper="$repository_root/scripts/update-task-checkout.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/home"
export HOME="$test_root/home"
export BOOTSTRAP_CALLS="$test_root/bootstrap-calls"
export TIMEOUT_CALLS="$test_root/timeout-calls"
cat >"$test_root/bin/wslpath" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ -n ${WSLPATH_FAIL:-} ]]; then exit 1; fi
printf '%s\n' "$2"
EOF_STUB
cat >"$test_root/bin/pwsh.exe" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BOOTSTRAP_CALLS"
if [[ -n ${BOOTSTRAP_REPLACEMENT:-} ]]; then
    cp -- "$BOOTSTRAP_REPLACEMENT" "$BOOTSTRAP_ENTRY"
fi
exit "${BOOTSTRAP_EXIT:-0}"
EOF_STUB
cat >"$test_root/bin/timeout" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TIMEOUT_CALLS"
if [[ ${TIMEOUT_EXIT:-0} != 0 ]]; then exit "$TIMEOUT_EXIT"; fi
shift 2
exec "$@"
EOF_STUB
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"

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

count() {
    if [[ -f $1 ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi
}

# A fixture checkout: the real helper beside an entry that bootstraps with
# FIXTURE_INTERVAL and FIXTURE_DEADLINE, then reports what ran and exits with
# FIXTURE_EXIT. Each run gets a fresh copy, so a replaced entry never leaks.
new_fixture() {
    fixture="$test_root/fixture-$1/scripts"
    mkdir -p "$fixture"
    cp -- "$helper" "$fixture/update-task-checkout.sh"
    cat >"$fixture/entry.sh" <<'EOF_ENTRY'
#!/usr/bin/env bash
set -euo pipefail
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/update-task-checkout.sh
. "$scripts_dir/update-task-checkout.sh"
wsl_automation_task_bootstrap "$scripts_dir/entry.sh" "${FIXTURE_INTERVAL:-0}" "${FIXTURE_DEADLINE:-300}" "$@"
printf 'original code:%s\n' "$*"
exit "${FIXTURE_EXIT:-0}"
EOF_ENTRY
    entry="$fixture/entry.sh"
}

export WSL_AUTOMATION_UPDATE_STAMP="$test_root/state/checkout-update.stamp"
now=2000000000
export WSL_AUTOMATION_NOW=$now

# --- Interval 0: one update, one re-exec, arguments and status kept ---------
new_fixture always
rc=0
out=$(FIXTURE_EXIT=3 bash "$entry" --dry-run 'two words' 2>&1) || rc=$?
assert_eq "$rc" 3 'entry exit status propagates through the re-exec'
assert_eq "$out" 'original code:--dry-run two words' 'arguments survive the re-exec; no warning on success'
assert_eq "$(count "$BOOTSTRAP_CALLS")" 1 'the re-executed entry does not update again'
assert_eq "$(sed -n 1p "$TIMEOUT_CALLS")" "--kill-after=5s 300s $test_root/bin/pwsh.exe -NoProfile -File $fixture/update-task-checkout.ps1 -UpdateOnly" 'shared Windows updater, deadline and arguments'
assert_eq "$(stat -c %Y -- "$WSL_AUTOMATION_UPDATE_STAMP")" "$now" 'the attempt is stamped with the run time'

# The deadline is the caller's.
rc=0
FIXTURE_DEADLINE=120 bash "$entry" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'second run succeeds'
assert_match "$(sed -n 2p "$TIMEOUT_CALLS")" '^--kill-after=5s 120s ' 'caller deadline reaches timeout'

# Interval 0 ignores a fresh stamp (the daily census always tries).
touch -d "@$now" -- "$WSL_AUTOMATION_UPDATE_STAMP"
bash "$entry" >/dev/null 2>&1
assert_eq "$(count "$BOOTSTRAP_CALLS")" 3 'interval 0 always tries'

# --- Throttle by attempt ----------------------------------------------------
rm -f -- "$BOOTSTRAP_CALLS" "$TIMEOUT_CALLS"
touch -d "@$((now - 299))" -- "$WSL_AUTOMATION_UPDATE_STAMP"
rc=0
out=$(FIXTURE_INTERVAL=300 FIXTURE_EXIT=5 bash "$entry" arg 2>&1) || rc=$?
assert_eq "$rc" 5 'a throttled run still runs the task and keeps its status'
assert_eq "$out" 'original code:arg' 'a throttled run is silent'
assert_eq "$(count "$TIMEOUT_CALLS")" 0 'an attempt 299 s ago skips the Windows host'
assert_eq "$(stat -c %Y -- "$WSL_AUTOMATION_UPDATE_STAMP")" "$((now - 299))" 'a skipped run leaves the stamp alone'

# Negative control: at the interval boundary the update runs.
touch -d "@$((now - 300))" -- "$WSL_AUTOMATION_UPDATE_STAMP"
FIXTURE_INTERVAL=300 bash "$entry" >/dev/null 2>&1
assert_eq "$(count "$BOOTSTRAP_CALLS")" 1 'an attempt 300 s ago updates again'
assert_eq "$(stat -c %Y -- "$WSL_AUTOMATION_UPDATE_STAMP")" "$now" 'the new attempt is stamped'

# A stamp from the future (clock moved back) does not block updates forever.
touch -d "@$((now + 3600))" -- "$WSL_AUTOMATION_UPDATE_STAMP"
FIXTURE_INTERVAL=300 bash "$entry" >/dev/null 2>&1
assert_eq "$(count "$BOOTSTRAP_CALLS")" 2 'a future stamp does not throttle'

# A missing stamp tries and creates it.
rm -rf -- "$test_root/state"
FIXTURE_INTERVAL=300 bash "$entry" >/dev/null 2>&1
assert_eq "$(count "$BOOTSTRAP_CALLS")" 3 'a missing stamp tries'
assert_eq "$(stat -c %Y -- "$WSL_AUTOMATION_UPDATE_STAMP")" "$now" 'a missing stamp is created'

# The default stamp lives under the user's state directory.
rc=0
(unset WSL_AUTOMATION_UPDATE_STAMP; FIXTURE_INTERVAL=300 bash "$entry" >/dev/null 2>&1) || rc=$?
assert_eq "$rc" 0 'default stamp run succeeds'
assert_eq "$(stat -c %Y -- "$HOME/.local/state/wsl-automation/checkout-update.stamp")" "$now" 'default stamp location'

# An unwritable stamp still updates, and the task still runs.
blocker="$test_root/not-a-directory"
: >"$blocker"
rc=0
out=$(WSL_AUTOMATION_UPDATE_STAMP="$blocker/stamp" FIXTURE_INTERVAL=300 FIXTURE_EXIT=6 bash "$entry" 2>&1) || rc=$?
assert_eq "$rc" 6 'an unwritable stamp keeps the task status'
assert_eq "$out" 'original code:' 'an unwritable stamp is silent'
assert_eq "$(count "$BOOTSTRAP_CALLS")" 5 'an unwritable stamp still updates'

# --- Fail open --------------------------------------------------------------
rm -f -- "$BOOTSTRAP_CALLS" "$TIMEOUT_CALLS"
rc=0
out=$(BOOTSTRAP_EXIT=1 FIXTURE_EXIT=3 bash "$entry" a 2>&1) || rc=$?
assert_eq "$rc" 3 'updater failure keeps the task status'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'updater failure warns'
assert_match "$out" 'original code:a' 'updater failure still runs the task'

rc=0
out=$(TIMEOUT_EXIT=124 FIXTURE_EXIT=3 bash "$entry" 2>&1) || rc=$?
assert_eq "$rc" 3 'deadline keeps the task status'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'deadline warns'
assert_eq "$(count "$BOOTSTRAP_CALLS")" 1 'a simulated deadline never starts the Windows host'

rc=0
out=$(WSLPATH_FAIL=1 FIXTURE_EXIT=3 bash "$entry" 2>&1) || rc=$?
assert_eq "$rc" 3 'wslpath failure keeps the task status'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'wslpath failure warns'
assert_eq "$(count "$TIMEOUT_CALLS")" 2 'wslpath failure never starts the deadline or the host'

# Hide only timeout from Bash lookup; the other test tools stay available.
rc=0
out=$(
    # Exported function is invoked by the child Bash entry. Older ShellCheck
    # reports this as SC2317; 0.11 reports it as SC2329.
    # shellcheck disable=SC2317,SC2329
    command() {
        if [[ $1 == -v && ${2:-} == timeout ]]; then return 1; fi
        builtin command "$@"
    }
    export -f command
    FIXTURE_EXIT=3 bash "$entry" 2>&1
) || rc=$?
assert_eq "$rc" 3 'missing timeout keeps the task status'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'missing timeout warns'
assert_eq "$(count "$TIMEOUT_CALLS")" 2 'missing timeout does not invoke timeout'
assert_eq "$(count "$BOOTSTRAP_CALLS")" 1 'missing timeout does not start the Windows host'

# pwsh.exe not on PATH: fall back to the standard MSI install path.
rc=0
out=$(
    # shellcheck disable=SC2317,SC2329
    command() {
        if [[ $1 == -v && ${2:-} == pwsh.exe ]]; then return 1; fi
        builtin command "$@"
    }
    export -f command
    bash "$entry" 2>&1
) || rc=$?
assert_eq "$rc" 0 'the absent MSI host keeps the task status'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'the absent MSI host warns'
assert_match "$out" 'original code:' 'the absent MSI host still runs the task'
assert_match "$(tail -n 1 "$TIMEOUT_CALLS")" '^--kill-after=5s 300s /mnt/c/Program Files/PowerShell/7/pwsh\.exe -NoProfile ' 'MSI fallback path'

# --- The updated entry runs from disk ----------------------------------------
new_fixture updated
cat >"$test_root/replacement.sh" <<'EOF_REPLACEMENT'
#!/usr/bin/env bash
printf 'updated code:%s\n' "$*"
exit 4
EOF_REPLACEMENT
rc=0
out=$(BOOTSTRAP_REPLACEMENT="$test_root/replacement.sh" BOOTSTRAP_ENTRY="$entry" bash "$entry" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 4 'the updated entry exit propagates'
assert_eq "$out" 'updated code:--dry-run' 'the updated entry runs from disk with the arguments'

# --- The guard is specific to the entry --------------------------------------
new_fixture guard
rm -f -- "$BOOTSTRAP_CALLS"
WSL_AUTOMATION_TASK_REEXEC="$entry" bash "$entry" >/dev/null 2>&1
assert_eq "$(count "$BOOTSTRAP_CALLS")" 0 'the guard for this entry skips the update'
# Negative control: a guard left by another entry does not suppress this one.
out=$(WSL_AUTOMATION_TASK_REEXEC="$test_root/other/entry.sh" bash "$entry" 2>&1)
assert_eq "$(count "$BOOTSTRAP_CALLS")" 1 'a guard for another entry still updates'
assert_no_match "$out" 'WARNING' 'a guard for another entry updates cleanly'

printf 'PASS: %s assertions\n' "$passed"
