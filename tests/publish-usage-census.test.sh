#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/publish-usage-census.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Stub only the Windows bootstrap; no real checkout or Windows process is touched.
mkdir -p "$test_root/bin"
export BOOTSTRAP_CALLS="$test_root/bootstrap-calls"
export TIMEOUT_CALLS="$test_root/timeout-calls"
cat >"$test_root/bin/wslpath" <<'EOF_STUB'
#!/usr/bin/env bash
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

# Never read the real settings file: point it at one that does not exist.
export WSL_AUTOMATION_SETTINGS="$test_root/no-such-settings.env"
# Keep the bootstrap's attempt stamp out of the real home directory.
export WSL_AUTOMATION_UPDATE_STAMP="$test_root/state/checkout-update.stamp"

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

# A throwaway skills-evals whose publish script echoes its arguments plus an
# env-controlled line and exits with an env-controlled code.
fixture="$test_root/skills-evals-src"
mkdir -p "$fixture/scripts"
cat >"$fixture/scripts/publish_usage_census.sh" <<'EOF'
#!/usr/bin/env bash
printf 'args:%s\n' "$*"
printf '%b\n' "${STUB_OUTPUT:-stub ok}"
exit "${STUB_EXIT:-0}"
EOF
git -C "$fixture" init --quiet
git -C "$fixture" add scripts/publish_usage_census.sh
git -C "$fixture" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false \
    commit --quiet -m 'fixture'

export SKILLS_EVALS_URL="file://$fixture"
log_file="$test_root/cache/usage-census.log"
export USAGE_CENSUS_LOG="$log_file"

line_count() {
    if [[ -f $log_file ]]; then wc -l <"$log_file" | tr -d ' '; else echo 0; fi
}

# (a) and (b): --dry-run reaches the stub; exit 0 propagates; one log line.
rc=0
out=$(bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 0 'exit code on success'
assert_match "$out" 'args:--dry-run' '--dry-run reaches the publish script'
assert_eq "$(line_count)" 1 'one log line after the first run'
assert_match "$(sed -n 1p "$log_file")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z exit=0 ' 'success log line format'

# (c): a nonzero exit propagates and is logged.
rc=0
out=$(STUB_EXIT=3 bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 3 'nonzero exit propagates'
assert_match "$(sed -n 2p "$log_file")" ' exit=3 ' 'nonzero exit is logged'

# (d): multi-line output is logged on one line.
rc=0
STUB_OUTPUT='first\nsecond\nthird' bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$(line_count)" 3 'multi-line output adds exactly one log line'
assert_match "$(sed -n 3p "$log_file")" 'first \| second \| third$' 'multi-line output is collapsed with |'

# (e): an unreachable URL gives exit 1 and a logged message.
rc=0
out=$(SKILLS_EVALS_URL="file://$test_root/does-not-exist" bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 1 'clone failure exits 1'
assert_eq "$out" 'usage census: could not clone skills-evals' 'clone failure message on stdout'
assert_match "$(sed -n 4p "$log_file")" ' exit=1 usage census: could not clone skills-evals$' 'clone failure is logged'

# (f): runs append, they do not overwrite.
assert_eq "$(line_count)" 4 'log accumulates one line per run'

# One bootstrap per original run; the child guard prevents a second update.
# The daily census always tries (interval 0), whatever the attempt stamp says.
assert_eq "$(wc -l <"$BOOTSTRAP_CALLS" | tr -d ' ')" 4 'bootstrap executes once per run'
assert_match "$(sed -n 1p "$BOOTSTRAP_CALLS")" '-NoProfile -File .*update-task-checkout.ps1 -UpdateOnly$' 'bootstrap uses the shared Windows updater'
assert_eq "$(sed -n 1p "$TIMEOUT_CALLS")" "--kill-after=5s 300s $test_root/bin/pwsh.exe -NoProfile -File $repository_root/scripts/update-task-checkout.ps1 -UpdateOnly" 'bootstrap deadline and arguments'

# Offline/failed bootstrap still runs the publisher and preserves its status.
rc=0
out=$(BOOTSTRAP_EXIT=1 STUB_EXIT=3 bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 3 'bootstrap failure preserves publisher exit'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'bootstrap failure warns'
assert_match "$out" 'args:--dry-run' 'bootstrap failure still publishes'

# The update replaces the shell entry itself: it must be read from disk before work runs.
# This is a Git-free fixture, with no remotes or inherited push configuration.
mkdir -p "$test_root/updated/scripts"
cp -- "$script" "$test_root/updated/scripts/publish-usage-census.sh"
cp -- "$repository_root/scripts/update-task-checkout.sh" "$test_root/updated/scripts/update-task-checkout.sh"
cp -- "$repository_root/scripts/task-settings.sh" "$test_root/updated/scripts/task-settings.sh"
cat >"$test_root/replacement.sh" <<'EOF_REPLACEMENT'
#!/usr/bin/env bash
printf 'updated code:%s\n' "$*"
exit 4
EOF_REPLACEMENT
rc=0
out=$(BOOTSTRAP_REPLACEMENT="$test_root/replacement.sh" BOOTSTRAP_ENTRY="$test_root/updated/scripts/publish-usage-census.sh" bash "$test_root/updated/scripts/publish-usage-census.sh" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 4 'updated shell entry exit propagates'
assert_eq "$out" 'updated code:--dry-run' 'runs the updated entry from disk with arguments'
assert_eq "$(wc -l <"$BOOTSTRAP_CALLS" | tr -d ' ')" 6 'failure and update each bootstrap once'

# A simulated deadline failure never starts the Windows host, and publishing still runs.
rc=0
out=$(TIMEOUT_EXIT=124 STUB_EXIT=3 bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 3 'bootstrap timeout preserves publisher exit'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'bootstrap timeout warns'
assert_match "$out" 'args:--dry-run' 'bootstrap timeout still publishes'
assert_eq "$(wc -l <"$BOOTSTRAP_CALLS" | tr -d ' ')" 6 'timeout does not launch Windows host'
assert_eq "$(wc -l <"$TIMEOUT_CALLS" | tr -d ' ')" 7 'timeout seam runs once per original entry'

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
    STUB_EXIT=3 bash "$script" --dry-run 2>&1
) || rc=$?
assert_eq "$rc" 3 'missing timeout preserves publisher exit'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'missing timeout warns'
assert_match "$out" 'args:--dry-run' 'missing timeout still publishes'
assert_eq "$(wc -l <"$BOOTSTRAP_CALLS" | tr -d ' ')" 6 'missing timeout does not launch Windows host'
assert_eq "$(wc -l <"$TIMEOUT_CALLS" | tr -d ' ')" 7 'missing timeout does not invoke timeout'

# --- SKILLS_EVALS_URL is a required setting with no fallback ------------------------------
# (1) Unset and no settings file: exit 2, naming the key, before any clone.
rc=0
out=$(env -u SKILLS_EVALS_URL bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 2 'a missing SKILLS_EVALS_URL exits 2'
assert_match "$out" 'SKILLS_EVALS_URL is not set; set it in ~/.config/wsl-automation/settings.env' 'the error names the key and where to set it'
assert_match "$out" 'usage census: setting SKILLS_EVALS_URL is missing or invalid' 'the failure is reported on stdout'
[[ $out != *'could not clone'* ]] || fail 'a missing SKILLS_EVALS_URL must not reach the clone'
pass
assert_match "$(tail -n 1 "$log_file")" ' exit=2 usage census: setting SKILLS_EVALS_URL is missing or invalid$' 'the failure is logged with exit 2 and names the key'
[[ $(tail -n 1 "$log_file") != *"$test_root"* ]] || fail 'the log line must not hold a path'
pass

# (2) Provided only by a settings file: the script uses it.
printf '# comment\nOTHER_KEY=ignored\n\nSKILLS_EVALS_URL=file://%s\n' "$fixture" >"$test_root/settings.env"
rc=0
out=$(env -u SKILLS_EVALS_URL WSL_AUTOMATION_SETTINGS="$test_root/settings.env" bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 0 'SKILLS_EVALS_URL from the settings file is used'
assert_match "$out" 'args:--dry-run' 'the clone from the settings file reaches the publish script'

# --- Explorer dispatch after a real publish -----------------------------------------------
# A stub gh records its arguments; a git insteadOf rule maps a GitHub-shaped
# SKILLS_EVALS_URL to the local fixture, so nothing touches the network.
export GH_CALLS="$test_root/gh-calls"
cat >"$test_root/bin/gh" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s @ %s\n' "$*" "$(git config --get remote.origin.url)" >>"$GH_CALLS"
echo 'https://github.com/example-owner/run-url-must-not-be-logged'
exit "${GH_EXIT:-0}"
EOF_STUB
chmod +x "$test_root/bin/gh"
gh_url='https://github.com/example-owner/example-evals.git'
gh_calls() {
    if [[ -f $GH_CALLS ]]; then wc -l <"$GH_CALLS" | tr -d ' '; else echo 0; fi
}
published='census: 3 skills; published; private events: 2 new of 5'
run_mapped() {
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$fixture.insteadOf" GIT_CONFIG_VALUE_0="$gh_url" \
        SKILLS_EVALS_URL="$gh_url" bash "$script" "$@" 2>&1
}

# (g) A published census dispatches explorer-data.yml from inside the clone, with no --repo or --ref.
rc=0
out=$(STUB_OUTPUT="$published" run_mapped) || rc=$?
assert_eq "$rc" 0 'a published census with a good dispatch exits 0'
assert_eq "$(gh_calls)" 1 'a published census dispatches once'
assert_eq "$(sed -n 1p "$GH_CALLS")" "workflow run explorer-data.yml @ $gh_url" 'dispatch runs in the clone (origin is the GitHub URL) with no --repo or --ref'
assert_match "$(tail -n 1 "$log_file")" ' exit=0 .*; published; .* \| explorer dispatch: requested$' 'a requested dispatch is logged'
[[ $(tail -n 1 "$log_file") != *run-url-must-not-be-logged* ]] || fail "gh output must not reach the log"
[[ $out != *run-url-must-not-be-logged* ]] || fail "gh output must not reach stdout"
pass

# (h) Unchanged and dry-run notes do not dispatch.
for note in 'census: 3 skills; unchanged, nothing published; private events: 0 new of 5' \
    'census: 3 skills; dry run, committed locally and pushed nothing; private events: 0 new of 5, dry run'; do
    rc=0
    out=$(STUB_OUTPUT="$note" run_mapped --dry-run) || rc=$?
    assert_eq "$rc" 0 "no publish exits 0 ($note)"
    [[ $out != *'explorer dispatch'* ]] || fail "no dispatch status without a publish ($note)"
    pass
done
assert_eq "$(gh_calls)" 1 'unchanged and dry-run runs do not dispatch'

# (i) A failed dispatch keeps the push, logs a non-identifying status and exits 5.
rc=0
out=$(GH_EXIT=4 STUB_OUTPUT="$published" run_mapped) || rc=$?
assert_eq "$rc" 5 'a failed dispatch after a good publish exits 5'
assert_eq "$(gh_calls)" 2 'the failed dispatch was attempted'
assert_match "$(tail -n 1 "$log_file")" ' exit=5 .* \| explorer dispatch: failed \(gh exit 4\)$' 'a failed dispatch is logged with the gh exit code only'
[[ $(tail -n 1 "$log_file") != *example-owner* ]] || fail 'the log line must not name the repository'
[[ $out != *run-url-must-not-be-logged* ]] || fail 'the gh error body must not reach stdout'
pass

# (j) A publisher failure keeps its own exit code even when the dispatch also fails
# (the public census can publish before the private events fail).
rc=0
out=$(GH_EXIT=4 STUB_EXIT=1 STUB_OUTPUT="$published" run_mapped) || rc=$?
assert_eq "$rc" 1 'the publisher exit code wins over a failed dispatch'
assert_match "$out" 'explorer dispatch: failed \(gh exit 4\)' 'the failed dispatch is still reported'

# (k) A timed-out dispatch (timeout exits 124) logs it and exits 5.
rc=0
out=$(GH_EXIT=124 STUB_OUTPUT="$published" run_mapped) || rc=$?
assert_eq "$rc" 5 'a timed-out dispatch exits 5'
assert_match "$out" 'explorer dispatch: failed \(gh exit 124\)' 'the timeout is reported with exit 124'
assert_match "$(tail -n 1 "$log_file")" ' exit=5 .* \| explorer dispatch: failed \(gh exit 124\)$' 'the timeout is logged'

printf 'PASS: %s assertions\n' "$passed"
