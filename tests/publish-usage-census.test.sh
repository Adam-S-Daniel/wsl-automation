#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/publish-usage-census.sh"
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

printf 'PASS: %s assertions\n' "$passed"
