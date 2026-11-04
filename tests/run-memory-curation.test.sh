#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/run-memory-curation.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Stub only the Windows bootstrap and interop; no real checkout, Windows process
# or Claude session is touched.
mkdir -p "$test_root/bin"
export BOOTSTRAP_CALLS="$test_root/bootstrap-calls"
export TIMEOUT_CALLS="$test_root/timeout-calls"
export CLAUDE_CALLS="$test_root/claude-calls"
export CLAUDE_ARGV="$test_root/claude-argv"
export CLAUDE_CWD="$test_root/claude-cwd"
export AUDIT_CALLS="$test_root/audit-calls"
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
# cmd.exe prints the Windows profile with a CRLF, as the real one does.
cat >"$test_root/bin/cmd.exe" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ ${CMD_EXIT:-0} != 0 ]]; then exit "$CMD_EXIT"; fi
printf '%s\r\n' "$WIN_PROFILE"
EOF_STUB
# The Claude stub records its arguments and working directory and prints a summary.
cat >"$test_root/bin/claude" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'call\n' >>"$CLAUDE_CALLS"
printf '%s\n' "$@" >"$CLAUDE_ARGV"
printf '%s|%s\n' "$(pwd -P)" "$(test -f docs/routines/memory-curation.md && echo doc || echo nodoc)" >"$CLAUDE_CWD"
if [[ -n ${CLAUDE_TOUCH:-} ]]; then : >"$CLAUDE_TOUCH"; fi
printf 'SUMMARYSECRET curated things\n'
exit "${CLAUDE_EXIT:-0}"
EOF_STUB
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"

# Never read the real settings file: point it at one that does not exist.
export WSL_AUTOMATION_SETTINGS="$test_root/no-such-settings.env"
# Keep the bootstrap's attempt stamp out of the real home directory.
export WSL_AUTOMATION_UPDATE_STAMP="$test_root/state/checkout-update.stamp"

export HOME="$test_root/home"
unset CLAUDE_CONFIG_DIR WINDOWS_CLAUDE_HOME
export CLAUDE_BIN=claude
mkdir -p "$HOME"

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

assert_contains() {
    [[ $1 == *"$2"* ]] || fail "$3: output does not contain the expected text"
    pass
}

assert_lacks() {
    [[ $1 != *"$2"* ]] || fail "$3: output contains text that must stay private"
    pass
}

# A throwaway _agent-guidance with the routine doc and a stub memory_audit.py that
# records its arguments and fails for any directory whose path contains
# AUDIT_FAIL_MATCH.
fixture="$test_root/agent-guidance-src"
mkdir -p "$fixture/scripts" "$fixture/docs/routines"
printf 'routine\n' >"$fixture/docs/routines/memory-curation.md"
cat >"$fixture/scripts/memory_audit.py" <<'EOF'
import os
import sys

with open(os.environ["AUDIT_CALLS"], "a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
match = os.environ.get("AUDIT_FAIL_MATCH")
sys.exit(1 if match and match in sys.argv[1] else 0)
EOF
git -C "$fixture" init --quiet
git -C "$fixture" add scripts/memory_audit.py docs/routines/memory-curation.md
git -C "$fixture" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false \
    commit --quiet -m 'fixture'

# Fake memory: the WSL home holds two memory dirs (3 notes, 1 archived), the Windows
# home one (3 notes, 2 archived). MEMORY.md and archive/ files are never notes.
wsl_home="$HOME/.claude"
win_profile="$test_root/winuser"
win_home="$win_profile/.claude"
mkdir -p "$wsl_home/projects/p-one/memory/archive" "$wsl_home/projects/p-two/memory" \
    "$wsl_home/projects/p-empty" "$win_home/projects/p-three/memory/archive/sub"
printf 'index\n' >"$wsl_home/projects/p-one/memory/MEMORY.md"
printf 'note\n' >"$wsl_home/projects/p-one/memory/note-alpha.md"
printf 'note\n' >"$wsl_home/projects/p-one/memory/note-beta.md"
printf 'note\n' >"$wsl_home/projects/p-one/memory/not-markdown.txt"
printf 'old\n' >"$wsl_home/projects/p-one/memory/archive/old-gamma.md"
printf 'note\n' >"$wsl_home/projects/p-two/memory/note-delta.md"
printf 'index\n' >"$win_home/projects/p-three/memory/MEMORY.md"
printf 'note\n' >"$win_home/projects/p-three/memory/note-epsilon.md"
printf 'note\n' >"$win_home/projects/p-three/memory/note-zeta.md"
printf 'note\n' >"$win_home/projects/p-three/memory/note-eta.md"
printf 'old\n' >"$win_home/projects/p-three/memory/archive/old-theta.md"
printf 'old\n' >"$win_home/projects/p-three/memory/archive/sub/old-iota.md"
mkdir -p "$test_root/roots-one"

export AGENT_GUIDANCE_URL="file://$fixture"
log_file="$test_root/cache/memory-curation.log"
summary_file="$test_root/cache/memory-curation/last-summary.md"
export MEMORY_CURATION_LOG="$log_file"
export MEMORY_CURATION_SUMMARY="$summary_file"
export MEMORY_CURATION_CLONE_ROOTS="$test_root/roots-one:$test_root/no-such-root"
export WIN_PROFILE="$win_profile"

line_count() {
    if [[ -f $log_file ]]; then wc -l <"$log_file" | tr -d ' '; else echo 0; fi
}
last_log() {
    tail -n 1 "$log_file"
}

# Live run: both homes, one --add-dir each, auto permission mode, run in the clone.
rc=0
out=$(bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 0 'exit code on a live run'
assert_eq "$(wc -l <"$CLAUDE_CALLS" | tr -d ' ')" 1 'live run calls claude once'
argv=$(cat "$CLAUDE_ARGV")
assert_eq "$(sed -n 1p "$CLAUDE_ARGV")" -p 'claude gets -p first'
prompt=$(sed -n 2p "$CLAUDE_ARGV")
assert_contains "$prompt" 'docs/routines/memory-curation.md in the current directory' 'prompt points at the routine doc'
assert_lacks "$prompt" 'Adam-S-Daniel' 'prompt names no owner'
assert_contains "$prompt" "$wsl_home/projects/*/memory/" 'prompt names the WSL home'
assert_contains "$prompt" "$win_home/projects/*/memory/" 'prompt names the Windows home'
assert_contains "$prompt" "$test_root/roots-one" 'prompt names an existing clone root'
assert_lacks "$prompt" 'no-such-root' 'prompt omits a missing clone root'
assert_contains "$argv" $'--permission-mode\nauto' 'permission mode auto'
assert_eq "$(grep -cx -- '--add-dir' "$CLAUDE_ARGV")" 2 'one --add-dir per home'
assert_contains "$argv" $'--add-dir\n'"$wsl_home/projects" 'WSL projects dir added'
assert_contains "$argv" $'--add-dir\n'"$win_home/projects" 'Windows projects dir added'
assert_match "$(cat "$CLAUDE_CWD")" '/_agent-guidance\|doc$' 'claude runs in the fresh clone'
assert_eq "$(sed -n 1p "$TIMEOUT_CALLS")" "--kill-after=5s 300s $test_root/bin/pwsh.exe -NoProfile -File $repository_root/scripts/update-task-checkout.ps1 -UpdateOnly" 'bootstrap deadline and arguments'
assert_eq "$(sed -n 2p "$TIMEOUT_CALLS")" '--kill-after=60s 7200 claude -p '"$prompt"' --permission-mode auto --add-dir '"$wsl_home/projects"' --add-dir '"$win_home/projects" 'claude runs under the default 2h timeout'
assert_contains "$out" 'SUMMARYSECRET curated things' 'summary is printed to stdout'

# Summary file: written, private, and exactly Claude's output.
assert_eq "$(cat "$summary_file")" 'SUMMARYSECRET curated things' 'summary file content'
assert_eq "$(stat -c %a "$summary_file")" 600 'summary file mode is 600'

# Log: one line, counts only.
assert_eq "$(line_count)" 1 'one log line after the first run'
assert_eq "$(last_log | cut -d' ' -f2-)" 'exit=0 memory curation: mode=live homes=2 windows_home=resolved dirs=3 notes_before=6 notes_after=6 archived_before=3 archived_after=3' 'live log line counts'
assert_match "$(last_log)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z exit=0 ' 'log line timestamp format'
log_text=$(cat "$log_file")
assert_lacks "$log_text" "$test_root" 'log holds no path'
assert_lacks "$log_text" 'note-alpha' 'log holds no note name'
assert_lacks "$log_text" 'SUMMARYSECRET' 'log holds no Claude output'

# A pre-existing, looser summary file is tightened, and notes_after sees new notes.
chmod 644 "$summary_file"
rc=0
CLAUDE_TOUCH="$wsl_home/projects/p-two/memory/note-new.md" bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'exit code when claude adds a note'
assert_eq "$(stat -c %a "$summary_file")" 600 'summary file mode is reset to 600'
assert_match "$(last_log)" ' notes_before=6 notes_after=7 ' 'log shows the note count after the run'
rm -- "$wsl_home/projects/p-two/memory/note-new.md"

# A nonzero Claude exit propagates and is logged.
rc=0
CLAUDE_EXIT=3 bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 3 'nonzero claude exit propagates'
assert_match "$(last_log)" ' exit=3 memory curation: mode=live ' 'nonzero claude exit is logged'

# A failed run does not poison the next one.
rc=0
bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'run after a failure succeeds again'

# --dry-run never calls claude and audits every memory dir.
: >"$CLAUDE_CALLS"
rc=0
out=$(bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 0 'exit code on a clean dry run'
assert_eq "$(wc -l <"$CLAUDE_CALLS" | tr -d ' ')" 0 'dry run never calls claude'
assert_eq "$(wc -l <"$AUDIT_CALLS" | tr -d ' ')" 3 'dry run audits every memory dir'
assert_contains "$(cat "$AUDIT_CALLS")" "$wsl_home/projects/p-one/memory --today " 'dry run audits a WSL memory dir'
assert_contains "$(cat "$AUDIT_CALLS")" "$win_home/projects/p-three/memory --today " 'dry run audits a Windows memory dir'
assert_match "$(sed -n 1p "$AUDIT_CALLS")" " --today [0-9]{4}-[0-9]{2}-[0-9]{2} --clone-root $test_root/roots-one\$" 'audit gets the date and each existing clone root'
assert_eq "$out" '' 'dry run prints nothing from the audits'
assert_match "$(last_log)" ' exit=0 memory curation: mode=dry-run homes=2 windows_home=resolved dirs=3 notes_before=6 notes_after=6 archived_before=3 archived_after=3 audits_ok=3 audits_failed=0$' 'dry-run log line counts'

# An audit failure exits 1 and counts the failure.
rc=0
AUDIT_FAIL_MATCH=p-two bash "$script" --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 1 'audit failure exits 1'
assert_match "$(last_log)" ' exit=1 memory curation: mode=dry-run .* audits_ok=2 audits_failed=1$' 'audit failure is counted in the log'

# Clone failure: exit 1, message on stdout and in the log, no claude call.
: >"$CLAUDE_CALLS"
rc=0
out=$(AGENT_GUIDANCE_URL="file://$test_root/does-not-exist" bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 1 'clone failure exits 1'
assert_eq "$out" 'memory curation: could not clone _agent-guidance' 'clone failure message on stdout'
assert_match "$(last_log)" ' exit=1 memory curation: could not clone _agent-guidance$' 'clone failure is logged'
assert_eq "$(wc -l <"$CLAUDE_CALLS" | tr -d ' ')" 0 'clone failure never calls claude'

# Unresolved Windows home (cmd.exe fails): WSL home only, run still succeeds.
rc=0
CMD_EXIT=1 bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'unresolved Windows home does not fail the run'
assert_eq "$(grep -cx -- '--add-dir' "$CLAUDE_ARGV")" 1 'unresolved Windows home adds one home'
assert_lacks "$(cat "$CLAUDE_ARGV")" "$win_home" 'unresolved Windows home is not passed'
assert_match "$(last_log)" ' homes=1 windows_home=unresolved dirs=2 notes_before=3 notes_after=3 archived_before=1 archived_after=1$' 'unresolved Windows home is logged'

# An empty cmd.exe answer is unresolved too.
rc=0
WIN_PROFILE='' bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'empty Windows profile does not fail the run'
assert_match "$(last_log)" ' homes=1 windows_home=unresolved ' 'empty Windows profile is unresolved'

# Explicit WINDOWS_CLAUDE_HOME wins over cmd.exe, which is not even asked.
rc=0
CMD_EXIT=1 WINDOWS_CLAUDE_HOME="$win_home" bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'explicit Windows home run succeeds'
assert_match "$(last_log)" ' homes=2 windows_home=explicit dirs=3 ' 'explicit Windows home is logged'

# A Windows home without a projects dir is skipped.
mkdir -p "$test_root/bare-home"
rc=0
WINDOWS_CLAUDE_HOME="$test_root/bare-home" bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'Windows home without projects succeeds'
assert_match "$(last_log)" ' homes=1 windows_home=explicit dirs=2 ' 'Windows home without projects is skipped'

# The same real directory under two names counts once.
ln -s "$wsl_home" "$test_root/home-link"
rc=0
WINDOWS_CLAUDE_HOME="$test_root/home-link" bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'deduped home run succeeds'
assert_eq "$(grep -cx -- '--add-dir' "$CLAUDE_ARGV")" 1 'same home is passed once'
assert_match "$(last_log)" ' homes=1 windows_home=explicit dirs=2 notes_before=3 ' 'same home is counted once'

# CLAUDE_CONFIG_DIR moves the WSL home.
rc=0
CLAUDE_CONFIG_DIR="$win_home" CMD_EXIT=1 bash "$script" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 'CLAUDE_CONFIG_DIR run succeeds'
assert_match "$(last_log)" ' homes=1 windows_home=unresolved dirs=1 notes_before=3 ' 'CLAUDE_CONFIG_DIR selects the WSL home'

# MEMORY_CURATION_TIMEOUT reaches timeout.
MEMORY_CURATION_TIMEOUT=90 bash "$script" >/dev/null 2>&1
assert_match "$(tail -n 1 "$TIMEOUT_CALLS")" '^--kill-after=60s 90 claude ' 'MEMORY_CURATION_TIMEOUT overrides the default'

# Offline/failed bootstrap still runs and preserves Claude's status.
rc=0
out=$(BOOTSTRAP_EXIT=1 CLAUDE_EXIT=4 bash "$script" 2>&1) || rc=$?
assert_eq "$rc" 4 'bootstrap failure preserves claude exit'
assert_match "$out" 'WARNING: checkout bootstrap unavailable' 'bootstrap failure warns'
assert_contains "$out" 'SUMMARYSECRET' 'bootstrap failure still curates'

# The update replaces the shell entry itself: it must be read from disk before work runs.
# This is a Git-free fixture, with no remotes or inherited push configuration.
mkdir -p "$test_root/updated/scripts"
cp -- "$script" "$test_root/updated/scripts/run-memory-curation.sh"
cp -- "$repository_root/scripts/update-task-checkout.sh" "$test_root/updated/scripts/update-task-checkout.sh"
cp -- "$repository_root/scripts/task-settings.sh" "$test_root/updated/scripts/task-settings.sh"
cat >"$test_root/replacement.sh" <<'EOF_REPLACEMENT'
#!/usr/bin/env bash
printf 'updated code:%s\n' "$*"
exit 4
EOF_REPLACEMENT
before_lines=$(line_count)
rc=0
out=$(BOOTSTRAP_REPLACEMENT="$test_root/replacement.sh" BOOTSTRAP_ENTRY="$test_root/updated/scripts/run-memory-curation.sh" bash "$test_root/updated/scripts/run-memory-curation.sh" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 4 'updated shell entry exit propagates'
assert_eq "$out" 'updated code:--dry-run' 'runs the updated entry from disk with arguments'
assert_eq "$(line_count)" "$before_lines" 'the replaced entry logs nothing itself'

# One bootstrap per original run, one log line per run that reached the wrapper's
# body (the replaced run above bootstrapped but never reached its own body).
assert_eq "$(wc -l <"$BOOTSTRAP_CALLS" | tr -d ' ')" "$(($(line_count) + 1))" 'bootstrap executes once per run'
assert_match "$(sed -n 1p "$BOOTSTRAP_CALLS")" '-NoProfile -File .*update-task-checkout.ps1 -UpdateOnly$' 'bootstrap uses the shared Windows updater'
assert_match "$(cat "$log_file")" 'exit=0 memory curation: mode=live' 'runs append to the log'
assert_eq "$(grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z exit=[0-9]+ memory curation: ' "$log_file" || true)" 0 'every log line has the same shape'

# --- AGENT_GUIDANCE_URL is a required setting with no fallback ------------------------------
# (1) Unset and no settings file: exit 2, naming the key, before any clone.
rc=0
out=$(env -u AGENT_GUIDANCE_URL bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 2 'a missing AGENT_GUIDANCE_URL exits 2'
assert_match "$out" 'AGENT_GUIDANCE_URL is not set; set it in ~/.config/wsl-automation/settings.env' 'the error names the key and where to set it'
assert_match "$out" 'memory curation: setting AGENT_GUIDANCE_URL is missing or invalid' 'the failure is reported on stdout'
[[ $out != *'could not clone'* ]] || fail 'a missing AGENT_GUIDANCE_URL must not reach the clone'
pass
assert_match "$(tail -n 1 "$log_file")" ' exit=2 memory curation: setting AGENT_GUIDANCE_URL is missing or invalid$' 'the failure is logged with exit 2 and names the key'
[[ $(tail -n 1 "$log_file") != *"$test_root"* ]] || fail 'the log line must not hold a path'
pass

# (2) Provided only by a settings file: the script uses it.
printf '# comment\nOTHER_KEY=ignored\n\nAGENT_GUIDANCE_URL=file://%s\n' "$fixture" >"$test_root/settings.env"
rc=0
out=$(env -u AGENT_GUIDANCE_URL WSL_AUTOMATION_SETTINGS="$test_root/settings.env" bash "$script" --dry-run 2>&1) || rc=$?
assert_eq "$rc" 0 'AGENT_GUIDANCE_URL from the settings file is used'
assert_match "$(last_log)" ' exit=0 memory curation: mode=dry-run ' 'the clone from the settings file reaches the audits'

printf 'PASS: %s assertions\n' "$passed"
