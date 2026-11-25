#!/usr/bin/env bash
# Behavior test for scripts/portable.sh: every helper gives the same answer with
# GNU tools and with BSD (macOS) stand-ins that reject the GNU-only forms.
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
passed=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_eq() {
    [[ $1 == "$2" ]] || fail "$3: expected '$2', got '$1'"
    passed=$((passed + 1))
}

# shellcheck source=tests/portable-stubs.sh
. "$repository_root/tests/portable-stubs.sh"
# shellcheck source=scripts/portable.sh
. "$repository_root/scripts/portable.sh"
make_bsd_bin "$test_root/bsd"
export TZ=UTC

epoch=1790000000
iso=2026-09-21T14:13:20Z
file="$test_root/f"
: >"$file"

# The stubs really behave like BSD: the GNU forms fail.
PATH="$test_root/bsd:$PATH" bash -c 'date -u -d @1 +%s' 2>/dev/null && fail 'BSD date stub accepted -d'
PATH="$test_root/bsd:$PATH" bash -c 'stat -c %Y /' 2>/dev/null && fail 'BSD stat stub accepted -c'
passed=$((passed + 2))

for flavor in gnu bsd; do
    if [[ $flavor == bsd ]]; then PATH="$test_root/bsd:$PATH"; fi
    assert_eq "$(wsl_automation_epoch_format "$epoch" %Y-%m-%dT%H:%M:%SZ)" "$iso" "$flavor: epoch to UTC ISO"
    assert_eq "$(wsl_automation_local_to_epoch '2026-09-21 14:13:20')" "$epoch" "$flavor: local time to epoch (TZ=UTC)"
    wsl_automation_touch_epoch 1789000000 "$file"
    assert_eq "$(wsl_automation_file_mtime "$file")" 1789000000 "$flavor: touch then mtime round-trips"
    assert_eq "$(wsl_automation_epoch_format 0 %Y-%m-%d)" 1970-01-01 "$flavor: epoch zero"
done

printf 'PASS: %s assertions\n' "$passed"
