#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/wsl-restic-backup.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Stub restic, nice and ionice; no real repository or priority change is touched.
mkdir -p "$test_root/bin"
export RESTIC_CALLS="$test_root/restic-calls"
export NICE_CALLS="$test_root/nice-calls"
cat >"$test_root/bin/restic" <<'EOF_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RESTIC_CALLS"
# Skip the global flags to find the subcommand.
while (($#)); do
    case $1 in
        -r | --password-file) shift 2 ;;
        *) break ;;
    esac
done
case $1 in
    unlock) exit "${RESTIC_UNLOCK_EXIT:-0}" ;;
    backup)
        printf '%s\n' 'open repository' 'new       /home/someone/stdout-secret.txt' \
            'Files:           1 new,     0 changed,     0 unmodified' \
            'Added to the repository: 1.234 KiB (1.000 KiB stored)' '' \
            'processed 1 files, 1.234 KiB in 0:01' 'snapshot 1a2b3c4d saved'
        printf '%s\n' 'error: open /home/someone/stderr-secret.txt: permission denied' \
            'Error: lstat /root/other-secret: permission denied' \
            'Warning: at least one source file could not be read' >&2
        exit "${RESTIC_BACKUP_EXIT:-0}"
        ;;
    forget)
        printf '%s\n' 'snapshot 1a2b3c4d of [/] at /home/someone/forget-secret' >&2
        exit "${RESTIC_FORGET_EXIT:-0}"
        ;;
    check) exit "${RESTIC_CHECK_EXIT:-0}" ;;
    *) exit 99 ;;
esac
EOF_STUB
cat >"$test_root/bin/nice" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'nice %s\n' "$*" >>"$NICE_CALLS"
shift 2
exec "$@"
EOF_STUB
cat >"$test_root/bin/ionice" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'ionice %s\n' "$*" >>"$NICE_CALLS"
shift
exec "$@"
EOF_STUB
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"

repo="$test_root/repo"
password_file="$test_root/password"
excludes_file="$repository_root/scripts/wsl-restic-excludes.txt"
mkdir -p "$repo"
printf '%s\n' 'stub config' >"$repo/config"
printf '%s\n' 'stub password' >"$password_file"

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

reset_calls() {
    rm -f -- "$RESTIC_CALLS" "$NICE_CALLS"
    touch -- "$RESTIC_CALLS" "$NICE_CALLS"
}

# The restic call for one subcommand (empty when it never ran).
restic_call() {
    local line
    while IFS= read -r line; do
        if [[ " $line " == *" $1 "* ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done <"$RESTIC_CALLS"
}

run() {
    bash "$script" "$repo" "$password_file" "$excludes_file" "$@" 2>&1
}

expected_summary='Added to the repository: 1.234 KiB (1.000 KiB stored)
processed 1 files, 1.234 KiB in 0:01
errors=2'

# (a): daily run - forget without --prune, check without --read-data-subset.
reset_calls
rc=0
out=$(run none) || rc=$?
assert_eq "$rc" 0 'daily run exits 0'
assert_eq "$out" "$expected_summary" 'stdout is only the two summary lines and the error count'
assert_eq "$(wc -l <"$RESTIC_CALLS" | tr -d ' ')" 4 'unlock, backup, forget and check each run once'
assert_eq "$(sed -n 1p "$RESTIC_CALLS")" "-r $repo --password-file $password_file unlock" 'unlock runs first with -r and --password-file'
assert_eq "$(restic_call backup)" "-r $repo --password-file $password_file backup / --one-file-system --exclude-caches --exclude-file $excludes_file" 'backup arguments'
assert_eq "$(restic_call forget)" "-r $repo --password-file $password_file forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3" 'daily forget has no --prune'
assert_eq "$(restic_call check)" "-r $repo --password-file $password_file check" 'daily check has no --read-data-subset'
assert_match "$(sed -n 1p "$NICE_CALLS")" '^nice -n 19 ionice -c3 restic .* backup / ' 'backup runs under nice and ionice'

# (b): weekly run - forget --prune and check --read-data-subset=5%.
reset_calls
rc=0
out=$(run weekly) || rc=$?
assert_eq "$rc" 0 'weekly run exits 0'
assert_match "$(restic_call forget)" ' forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune$' 'weekly forget adds --prune'
assert_match "$(restic_call check)" ' check --read-data-subset=5%$' 'weekly check reads a 5% data subset'

# (c): backup exit 3 (snapshot saved, some files unreadable) is PARTIAL: exit 10.
reset_calls
rc=0
out=$(RESTIC_BACKUP_EXIT=3 run none) || rc=$?
assert_eq "$rc" 10 'partial backup exits 10'
assert_eq "$out" "$expected_summary" 'partial backup still prints the summary'
assert_match "$(restic_call check)" ' check$' 'partial backup still forgets and checks'

# (d): any other backup failure exits 30 and skips forget and check.
reset_calls
rc=0
out=$(RESTIC_BACKUP_EXIT=1 run none) || rc=$?
assert_eq "$rc" 30 'failed backup exits 30'
assert_eq "$(restic_call forget)" '' 'failed backup does not forget'
assert_eq "$(restic_call check)" '' 'failed backup does not check'

# (e): forget failure exits 40 and skips check.
reset_calls
rc=0
out=$(RESTIC_FORGET_EXIT=1 run weekly) || rc=$?
assert_eq "$rc" 40 'forget failure exits 40'
assert_eq "$(restic_call check)" '' 'forget failure does not check'
assert_no_match "$out" 'forget-secret' 'forget output never reaches stdout'

# (f): check failure exits 50, partial or not.
reset_calls
rc=0
out=$(RESTIC_CHECK_EXIT=1 run none) || rc=$?
assert_eq "$rc" 50 'check failure exits 50'
rc=0
out=$(RESTIC_BACKUP_EXIT=3 RESTIC_CHECK_EXIT=1 run none) || rc=$?
assert_eq "$rc" 50 'check failure after a partial backup still exits 50'

# (g): a stale-lock unlock failure is not fatal on its own.
reset_calls
rc=0
out=$(RESTIC_UNLOCK_EXIT=1 run none) || rc=$?
assert_eq "$rc" 0 'unlock failure alone does not fail the run'

# (h): restic missing exits 20 before touching anything. Hide only restic from
# Bash lookup; the other test tools stay available.
reset_calls
rc=0
out=$(
    # Exported function is invoked by the child Bash entry. Older ShellCheck
    # reports this as SC2317; 0.11 reports it as SC2329.
    # shellcheck disable=SC2317,SC2329
    command() {
        if [[ $1 == -v && ${2:-} == restic ]]; then return 1; fi
        builtin command "$@"
    }
    export -f command
    run none
) || rc=$?
assert_eq "$rc" 20 'missing restic exits 20'
assert_eq "$(wc -l <"$RESTIC_CALLS" | tr -d ' ')" 0 'missing restic runs nothing'

# (i): a missing password file or repository exits 21 before touching anything.
reset_calls
rc=0
out=$(bash "$script" "$repo" "$test_root/no-such-password" "$excludes_file" none 2>&1) || rc=$?
assert_eq "$rc" 21 'missing password file exits 21'
rc=0
out=$(bash "$script" "$test_root/no-such-repo" "$password_file" "$excludes_file" none 2>&1) || rc=$?
assert_eq "$rc" 21 'missing repository exits 21'
assert_eq "$(wc -l <"$RESTIC_CALLS" | tr -d ' ')" 0 'missing password file or repository runs nothing'

# (j): bad arguments exit 2.
rc=0
bash "$script" "$repo" "$password_file" "$excludes_file" monthly >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 2 'unknown maintenance mode exits 2'
rc=0
bash "$script" "$repo" "$password_file" "$excludes_file" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 2 'missing argument exits 2'

# (k): no path restic printed - on stderr or outside the summary on stdout -
# reaches the output, on success or failure.
for backup_exit in 0 3 1; do
    rc=0
    out=$(RESTIC_BACKUP_EXIT=$backup_exit run none) || rc=$?
    assert_no_match "$out" '/home/|/root/' "no file path in the output (backup exit $backup_exit)"
    assert_no_match "$out" 'secret' "no stub secret in the output (backup exit $backup_exit)"
done

printf 'PASS: %s assertions\n' "$passed"
