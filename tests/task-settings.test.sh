#!/usr/bin/env bash
# Each case runs in its own subshell on purpose, so a modified key never leaks.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# shellcheck source=scripts/task-settings.sh
. "$repository_root/scripts/task-settings.sh"

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

assert_contains() {
    [[ $1 == *"$2"* ]] || fail "$3: '$1' does not contain '$2'"
    pass
}

assert_lacks() {
    [[ $1 != *"$2"* ]] || fail "$3: '$1' contains '$2'"
    pass
}

# Each case runs in a subshell so an exported key never leaks into the next one.
# It sets rc, out (stderr) and value (the key after the call).
settings="$test_root/settings.env"
export WSL_AUTOMATION_SETTINGS="$settings"
unset DEMO_KEY || true
rc=0
out=''
value=''
resolve() {
    local key=$1
    rc=0
    out=$(
        wsl_automation_require_setting "$key" 2>&1 >/dev/null || exit $?
        printf '%s' "${!key}" >"$test_root/value"
    ) || rc=$?
    if [[ $rc == 0 ]]; then value=$(<"$test_root/value"); else value=''; fi
}

# A missing file and no environment: exit 2, naming the key and where to set it.
rm -f -- "$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'a missing key with no file returns 2'
assert_contains "$out" 'DEMO_KEY is not set; set it in ~/.config/wsl-automation/settings.env' 'the error names the key and the file'
assert_contains "$out" 'WSL_AUTOMATION_SETTINGS' 'the error names the override variable'
assert_contains "$out" 'config/settings.env.example' 'the error names the example'

# A plain value from the file.
printf 'DEMO_KEY=https://example.com/a.git\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 0 'a value in the file resolves'
assert_eq "$value" 'https://example.com/a.git' 'the file value is exported'

# The key is exported to child processes, not only set.
printf 'DEMO_KEY=exported-value\n' >"$settings"
exported=$(
    wsl_automation_require_setting DEMO_KEY
    bash -c 'printf "%s" "${DEMO_KEY-UNSET}"'
)
assert_eq "$exported" 'exported-value' 'the resolved key is exported'

# The environment wins over the file.
printf 'DEMO_KEY=from-file\n' >"$settings"
rc=0
value=$(
    DEMO_KEY=from-env
    wsl_automation_require_setting DEMO_KEY
    printf '%s' "$DEMO_KEY"
) || rc=$?
assert_eq "$rc" 0 'an environment value resolves'
assert_eq "$value" 'from-env' 'the environment wins over the file'

# The environment value resolves even when the file is malformed (it is not read).
printf 'this is not valid\n' >"$settings"
value=$(
    DEMO_KEY=from-env
    wsl_automation_require_setting DEMO_KEY
    printf '%s' "$DEMO_KEY"
) || rc=$?
assert_eq "$value" 'from-env' 'a malformed file is not read when the environment has the value'

# Blank lines and comments are skipped; other keys are ignored.
printf '# a comment\n\n   \n  # indented comment\nOTHER_KEY=other\nDEMO_KEY=wanted\n# DEMO_KEY=commented-out\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 0 'comments and blank lines are skipped'
assert_eq "$value" 'wanted' 'only the requested key is taken'

# Last occurrence wins.
printf 'DEMO_KEY=first\nDEMO_KEY=second\nOTHER_KEY=x\n' >"$settings"
resolve DEMO_KEY
assert_eq "$value" 'second' 'the last occurrence wins'

# ~/ expands to $HOME/; nothing else is expanded or unquoted.
printf 'DEMO_KEY=~/repos/demo\n' >"$settings"
resolve DEMO_KEY
assert_eq "$value" "$HOME/repos/demo" 'a leading ~/ expands to HOME'
printf 'DEMO_KEY=a~/b\n' >"$settings"
resolve DEMO_KEY
assert_eq "$value" 'a~/b' 'a tilde elsewhere is kept'
# shellcheck disable=SC2016
printf 'DEMO_KEY=$HOME/x "quoted" '"'"'single'"'"'\n' >"$settings"
resolve DEMO_KEY
# shellcheck disable=SC2016
assert_eq "$value" '$HOME/x "quoted" '"'"'single'"'"'' 'variables are not expanded and quotes are not stripped'

# A value may contain =.
printf 'DEMO_KEY=https://example.com/?a=b\n' >"$settings"
resolve DEMO_KEY
assert_eq "$value" 'https://example.com/?a=b' 'a value may contain ='

# A final line with no trailing newline and a CRLF file both resolve.
printf 'DEMO_KEY=no-newline' >"$settings"
resolve DEMO_KEY
assert_eq "$value" 'no-newline' 'a last line without a newline resolves'
printf '# c\r\nDEMO_KEY=crlf\r\n' >"$settings"
resolve DEMO_KEY
assert_eq "$value" 'crlf' 'CRLF line endings resolve'

# An empty value is an error, also when an earlier line had a value.
printf 'DEMO_KEY=\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'an empty value returns 2'
assert_contains "$out" 'DEMO_KEY is not set' 'an empty value is reported as not set'
printf 'DEMO_KEY=earlier\nDEMO_KEY=\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'a later empty value overrides an earlier one'

# An empty environment value does not count as set.
printf 'DEMO_KEY=from-file\n' >"$settings"
value=$(
    DEMO_KEY=''
    wsl_automation_require_setting DEMO_KEY
    printf '%s' "$DEMO_KEY"
)
assert_eq "$value" 'from-file' 'an empty environment value falls through to the file'

# A key absent from a file that has others is an error.
printf 'OTHER_KEY=other\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'a key absent from the file returns 2'

# A malformed line is an error naming its line number, not the file path.
printf '# ok\nDEMO_KEY=fine\nthis is not valid\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'a malformed line returns 2'
assert_contains "$out" 'malformed line 3' 'the error names the line number'
assert_lacks "$out" "$test_root" 'the error does not name the file path'
assert_lacks "$out" 'settings.env' 'the error does not name the file'
printf 'lowercase_key=x\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'a lowercase key is malformed'
assert_contains "$out" 'malformed line 1' 'the lowercase key line is named'
printf 'export DEMO_KEY=x\n' >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 2 'a shell export line is malformed (the file is never sourced)'

# The file is data: a command in it is never run.
marker="$test_root/ran"
# shellcheck disable=SC2016
printf 'DEMO_KEY=$(touch %s)\n' "$marker" >"$settings"
resolve DEMO_KEY
assert_eq "$rc" 0 'a command-shaped value resolves as plain text'
[[ ! -e $marker ]] || fail 'the settings file value was executed'
pass

# WSL_AUTOMATION_SETTINGS unset: the default path is under HOME.
home_dir="$test_root/home"
mkdir -p "$home_dir/.config/wsl-automation"
printf 'DEMO_KEY=from-default-path\n' >"$home_dir/.config/wsl-automation/settings.env"
value=$(
    unset WSL_AUTOMATION_SETTINGS
    HOME=$home_dir
    wsl_automation_require_setting DEMO_KEY
    printf '%s' "$DEMO_KEY"
)
assert_eq "$value" 'from-default-path' 'the default file is ~/.config/wsl-automation/settings.env'

printf 'PASS: %s assertions\n' "$passed"
