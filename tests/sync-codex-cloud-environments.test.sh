#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/sync-codex-cloud-environments.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_fakes() {
    mkdir -p "$test_root/bin" "$test_root/codex"
    printf '%s\n' '{"tokens":{"access_token":"test-access","account_id":"test-account"}}' >"$test_root/codex/auth.json"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$test_root/bin/codex"
    cat >"$test_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
endpoint=''
for argument in "$@"; do
    case "$argument" in
        repos/*) endpoint=$argument ;;
    esac
done
[[ -n $endpoint ]] || exit 2
if [[ ${FAKE_GH_LOOKUP_FAIL:-0} == 1 ]]; then
    exit 1
fi
if [[ ${FAKE_GH_INVALID_RESPONSE:-0} == 1 ]]; then
    printf '%s\n' '{"fork":"false"}'
elif [[ $endpoint == "repos/${FAKE_FORK_REPOSITORY:-}" ]]; then
    printf '%s\n' '{"fork":true}'
else
    printf '%s\n' '{"fork":false}'
fi
EOF
    cat >"$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
method=GET
data=''
url=''
query=''
while (($#)); do
    case "$1" in
        --output|-o) output=$2; shift 2 ;;
        --request|-X) method=$2; shift 2 ;;
        --data-binary) data=$(printf '%s' "$2" | cut -c2-); shift 2 ;;
        --header)
            [[ $2 != Authorization:* ]] || exit 17
            shift 2
            ;;
        --write-out) shift 2 ;;
        --data-urlencode)
            if [[ $2 == query=* ]]; then query=${2#query=}; fi
            shift 2
            ;;
        --silent|--show-error|--get|--fail|--location) shift ;;
        *) url=$1; shift ;;
    esac
done
if [[ $url == https://raw.githubusercontent.com/Adam-S-Daniel/adam-agentskills/*/.claude/hooks/skills-bootstrap.sh ]]; then
    printf '%s\n' 'download' >>"$FAKE_DOWNLOAD_LOG"
    if [[ ${FAKE_BOOTSTRAP_TAMPER:-0} == 1 ]]; then
        printf '%s\n' 'tampered download' >"$output"
    else
        cp "$FAKE_BOOTSTRAP_FILE" "$output"
    fi
    exit 0
fi
if [[ $FAKE_PATCH_HTTP_FAIL == 1 && $url == *'/wham/environments/'* ]]; then
    printf '%s' '{"private":"response body must not leak"}' >"$output"
    printf '500'
elif [[ $FAKE_HTTP_FAIL == 1 && $url == *'/wham/environments' ]]; then
    printf '%s' '{"private":"response body must not leak"}' >"$output"
    printf '500'
elif [[ $url == *'/wham/environments' && $method == GET ]]; then
    printf '%s' "$FAKE_ENVIRONMENTS" >"$output"
    printf '200'
elif [[ $url == *'/wham/settings/code_review'* ]]; then
    inventory_count_file="$FAKE_REQUEST_DIR/inventory-count"
    inventory_count=0
    [[ -f $inventory_count_file ]] && inventory_count=$(cat "$inventory_count_file")
    inventory_count=$((inventory_count + 1))
    printf '%s' "$inventory_count" >"$inventory_count_file"
    if [[ $inventory_count == 1 ]]; then
        printf '%s' "$FAKE_INVENTORY_PAGE1" >"$output"
    else
        printf '%s' "$FAKE_INVENTORY_PAGE2" >"$output"
    fi
    printf '200'
elif [[ $url == *'/repositories/search/all-installations'* ]]; then
    [[ ${#query} -ne 1 || $FAKE_REJECT_BROAD_SEARCH != 1 ]] || exit 18
    printf '%s' "$FAKE_SEARCH_RESPONSE" >"$output"
    printf '200'
elif [[ $url == *'/wham/environments' && $method == POST ]]; then
    cat "$data" >>"$FAKE_REQUEST_DIR/create.jsonl"
    printf '\n' >>"$FAKE_REQUEST_DIR/create.jsonl"
    printf '{}' >"$output"
    printf '200'
elif [[ $url == *'/wham/environments/'* && $method == PATCH ]]; then
    cp "$data" "$FAKE_REQUEST_DIR/update.json"
    printf '{}' >"$output"
    printf '200'
else
    printf '{}' >"$output"
    printf '200'
fi
EOF
    cat >"$test_root/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm:%s:%s\n' "$PWD" "$*" >>"$FAKE_RUN_LOG"
EOF
    cat >"$test_root/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '--check --status' ]] || exit 2
IFS=' ' read -r digest file
[[ $digest =~ ^[a-f0-9]{64}$ ]] || exit 3
cmp -s -- "$FAKE_BOOTSTRAP_FILE" "$file"
EOF
    chmod 755 "$test_root/bin/codex" "$test_root/bin/gh" "$test_root/bin/curl"
    chmod 755 "$test_root/bin/npm" "$test_root/bin/sha256sum"
}

run_sync() {
    local result_file=$1
    shift
    rm -f "$test_root/requests/inventory-count"
    PATH="$test_root/bin:$PATH" CODEX_HOME="$test_root/codex" XDG_RUNTIME_DIR="$test_root/runtime" \
        FAKE_REQUEST_DIR="$test_root/requests" "$script" "$@" >"$result_file" 2>&1
}

make_fakes
mkdir -p "$test_root/runtime" "$test_root/requests"
export FAKE_HTTP_FAIL=0
export FAKE_PATCH_HTTP_FAIL=0
export FAKE_REJECT_BROAD_SEARCH=1
export FAKE_GH_LOOKUP_FAIL=0
export FAKE_GH_INVALID_RESPONSE=0
export FAKE_FORK_REPOSITORY=''
export FAKE_INVENTORY_PAGE1='{"repo_review_settings":[{"repository":{"id":"guidance-1","name":"_agent-guidance","repository_full_name":"Adam-S-Daniel/_agent-guidance"}},{"repository":{"id":"repo-1","name":"example-repo","repository_full_name":"Example/example-repo"}}],"next_token":null}'
export FAKE_INVENTORY_PAGE2='{"repo_review_settings":[],"next_token":null}'
export FAKE_SEARCH_RESPONSE='{"repositories":[{"id":"guidance-1","name":"_agent-guidance"},{"id":"repo-1","name":"example-repo"}]}'
export CODEX_CLOUD_GITHUB_CONNECTOR_ID='connector-1'

export FAKE_ENVIRONMENTS='[{"id":"unrelated-environment","repos":[]}]'
export CODEX_CLOUD_GITHUB_CONNECTOR_ID=$'connector\nmalicious'
if run_sync "$test_root/malicious-connector.out" --dry-run; then
    fail 'newline-containing connector ID was accepted'
fi
grep -qxF 'candidate connector ID is invalid' "$test_root/malicious-connector.out" || fail 'malicious connector failure was not sanitized'
export CODEX_CLOUD_GITHUB_CONNECTOR_ID='connector-1'

run_sync "$test_root/create.out"
expected_script=$(jq -er 'select(.repos == ["repo-1"]) | .setup' "$test_root/requests/create.jsonl")
expected_guidance_script=$(jq -er 'select(.repos == ["guidance-1"]) | .setup' "$test_root/requests/create.jsonl")
expected_script+=$'\n'
expected_guidance_script+=$'\n'
[[ $expected_script == *'cd /workspace/example-repo'* ]] || fail 'target setup does not use its own checkout'
[[ $expected_guidance_script == *'cd /workspace/_agent-guidance'* ]] || fail 'guidance setup does not use its own checkout'
[[ $expected_script != "$expected_guidance_script" ]] || fail 'different repositories received the same setup'
[[ -f $test_root/requests/create.jsonl ]] || fail 'expected create requests'
jq -s -e --arg expected "$expected_script" --arg guidance "$expected_guidance_script" '
    length == 2 and
    any(.[]; .repos == ["repo-1"] and .setup == $expected and .maintenance_setup == $expected) and
    any(.[]; .repos == ["guidance-1"] and .setup == $guidance and .maintenance_setup == $guidance)
' "$test_root/requests/create.jsonl" >/dev/null || fail 'create payloads do not include the guidance repository correctly'

mkdir -p "$test_root/workspace/example-repo/.claude/hooks"
printf '%s\n' '{"version":1}' >"$test_root/workspace/example-repo/skills.lock"
printf '%s\n' 'lockfileVersion: 3' >"$test_root/workspace/example-repo/package-lock.json"
printf '%s\n' '# delivered hook marker' >"$test_root/workspace/example-repo/.claude/hooks/skills-bootstrap.sh"
cat >"$test_root/workspace/example-repo/.claude/hooks/fleet-memory.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'memory:%s:%s:%s\n' "$PWD" "$CODEX_HOME" "$*" >>"$FAKE_RUN_LOG"
EOF
cat >"$test_root/bootstrap-fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'skills:%s:%s:%s\n' "$CLAUDE_PROJECT_DIR" "$CODEX_HOME" "$*" >>"$FAKE_RUN_LOG"
EOF
printf '%s\n' "$expected_script" |
    sed "s#^cd /workspace/example-repo\$#cd $test_root/workspace/example-repo#" >"$test_root/target-setup.sh"
run_setup() {
    local result_file=$1
    : >"$test_root/setup-events"
    rm -f "$test_root/download-events"
    PATH="$test_root/bin:$PATH" FAKE_RUN_LOG="$test_root/setup-events" \
        FAKE_DOWNLOAD_LOG="$test_root/download-events" FAKE_BOOTSTRAP_FILE="$test_root/bootstrap-fixture.sh" \
        bash "$test_root/target-setup.sh" >"$result_file" 2>&1
}
run_setup "$test_root/opted-in.out"
grep -qxF "npm:$test_root/workspace/example-repo:ci" "$test_root/setup-events" || fail 'npm ci was not conditional on a lockfile'
grep -qxF "memory:$test_root/workspace/example-repo:/opt/codex:--codex-cloud" "$test_root/setup-events" || fail 'memory hook did not run in selected checkout'
grep -qxF "skills:$test_root/workspace/example-repo:/opt/codex:--codex-cloud" "$test_root/setup-events" || fail 'reviewed bootstrap did not run for enrolled repository'
[[ $(wc -l <"$test_root/download-events") -eq 1 ]] || fail 'enrolled repository did not download once'

rm "$test_root/workspace/example-repo/skills.lock" "$test_root/workspace/example-repo/package-lock.json" \
    "$test_root/workspace/example-repo/.claude/hooks/skills-bootstrap.sh"
run_setup "$test_root/lockless.out"
grep -qxF 'skills: skipped (no skills.lock in selected repository)' "$test_root/lockless.out" || fail 'lockless skip was not explicit'
[[ ! -e $test_root/download-events ]] || fail 'lockless repository downloaded a bootstrap'
[[ $(wc -l <"$test_root/setup-events") -eq 1 ]] || fail 'lockless repository ran npm or bootstrap'
[[ ! -e $test_root/workspace/example-repo/skills.lock ]] || fail 'lockless repository was enrolled'

ln -s "$test_root/bootstrap-fixture.sh" "$test_root/workspace/example-repo/skills.lock"
if run_setup "$test_root/symlink-lock.out"; then
    fail 'symlink skills lock was accepted'
fi
grep -qxF 'skills: DEGRADED (selected repository has an invalid skills.lock)' "$test_root/symlink-lock.out" || fail 'invalid lock failure was unclear'
[[ ! -e $test_root/download-events ]] || fail 'invalid lock downloaded a bootstrap'
rm "$test_root/workspace/example-repo/skills.lock"

printf '%s\n' '{"version":1}' >"$test_root/workspace/example-repo/skills.lock"
if run_setup "$test_root/missing-hook.out"; then
    fail 'missing delivered hook was accepted'
fi
grep -qxF 'skills: DEGRADED (enrolled repository is missing its delivered bootstrap hook)' "$test_root/missing-hook.out" || fail 'missing hook failure was unclear'
[[ ! -e $test_root/download-events ]] || fail 'missing hook downloaded a bootstrap'

printf '%s\n' '# delivered hook marker' >"$test_root/workspace/example-repo/.claude/hooks/skills-bootstrap.sh"
FAKE_BOOTSTRAP_TAMPER=1
export FAKE_BOOTSTRAP_TAMPER
if run_setup "$test_root/tampered.out"; then
    fail 'tampered bootstrap was executed'
fi
unset FAKE_BOOTSTRAP_TAMPER
grep -qxF 'skills: DEGRADED (reviewed bootstrap digest mismatch)' "$test_root/tampered.out" || fail 'digest mismatch was unclear'
[[ $(wc -l <"$test_root/setup-events") -eq 1 ]] || fail 'tampered bootstrap ran'

cat >"$test_root/draining-bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 -c '
import os
import stat
import sys

actual = os.fstat(0)
null_device = os.stat(os.devnull)
if not stat.S_ISCHR(actual.st_mode) or actual.st_rdev != null_device.st_rdev:
    print("bootstrap stdin was not /dev/null", file=sys.stderr)
    sys.exit(83)
'
cat >/dev/null
printf 'skills:%s:%s:%s\n' "$CLAUDE_PROJECT_DIR" "$CODEX_HOME" "$*" >>"$FAKE_RUN_LOG"
EOF
PATH="$test_root/bin:$PATH" FAKE_BOOTSTRAP_FILE="$test_root/draining-bootstrap.sh" \
    FAKE_DOWNLOAD_LOG="$test_root/download-events" FAKE_RUN_LOG="$test_root/open-stdin-events" \
    python3 - "$test_root" <<'PY'
import os
import signal
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
if subprocess.run(
    ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
).returncode == 0:
    raise SystemExit("negative-control directory unexpectedly inherited Git reach")

setup = root / "target-setup.sh"
text = setup.read_text()
invocation = 'bash "$bootstrap_file" --codex-cloud </dev/null'
if text.count(invocation) != 1:
    raise SystemExit("generated setup lacks the single expected stdin redirect")
negative = root / "without-stdin-redirect.sh"
negative.write_text(text.replace(invocation, 'bash "$bootstrap_file" --codex-cloud'))

def run_with_open_stdin(path: Path, events: Path, expect_null: bool) -> None:
    read_fd, write_fd = os.pipe()
    env = os.environ.copy()
    env["FAKE_RUN_LOG"] = str(events)
    process = subprocess.Popen(
        ["bash", str(path)], stdin=read_fd, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env, start_new_session=True,
    )
    os.close(read_fd)
    try:
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise SystemExit("setup hung while bootstrap drained open stdin")
        if not expect_null:
            if process.returncode != 83 or b"bootstrap stdin was not /dev/null" not in stderr:
                raise SystemExit(f"negative control did not fail its stdin assertion: {process.returncode}: {stderr!r}")
            if events.exists() and "skills:" in events.read_text():
                raise SystemExit("negative-control bootstrap continued after its stdin assertion")
            return
        if process.returncode != 0:
            raise SystemExit(f"setup failed with /dev/null stdin: {process.returncode}: {stderr!r}")
        if b"skills: skipped" in stdout:
            raise SystemExit("enrolled setup skipped skills")
        if "skills:" not in events.read_text():
            raise SystemExit("bootstrap did not finish after closed stdin")
    finally:
        os.close(write_fd)
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()

run_with_open_stdin(negative, root / "negative-stdin-events", expect_null=False)
run_with_open_stdin(setup, root / "open-stdin-events", expect_null=True)
PY

rm -f "$test_root/requests/create.jsonl" "$test_root/requests/update.json"
export FAKE_FORK_REPOSITORY='Example/example-repo'
export FAKE_ENVIRONMENTS='[{"id":"unrelated-environment","repos":[]}]'
run_sync "$test_root/fork.out"
jq -s -e --arg expected "$expected_guidance_script" 'length == 1 and .[0].repos == ["guidance-1"] and .[0].setup == $expected and .[0].maintenance_setup == $expected' "$test_root/requests/create.jsonl" >/dev/null || fail 'fork received a Codex Cloud environment'
rm -f "$test_root/requests/create.jsonl" "$test_root/requests/update.json"
export FAKE_FORK_REPOSITORY=''

export FAKE_GH_LOOKUP_FAIL=1
if run_sync "$test_root/github-lookup-failure.out" --dry-run; then
    fail 'GitHub metadata lookup failure was accepted'
fi
grep -qxF 'GitHub repository metadata lookup failed' "$test_root/github-lookup-failure.out" || fail 'GitHub metadata lookup failure was not sanitized'
if grep -qF 'Example/example-repo' "$test_root/github-lookup-failure.out"; then
    fail 'GitHub metadata lookup failure leaked a repository name'
fi
export FAKE_GH_LOOKUP_FAIL=0

export FAKE_GH_INVALID_RESPONSE=1
if run_sync "$test_root/github-schema-failure.out" --dry-run; then
    fail 'non-boolean GitHub fork metadata was accepted'
fi
grep -qxF 'GitHub repository metadata response has an unexpected schema' "$test_root/github-schema-failure.out" || fail 'GitHub metadata schema failure was not sanitized'
export FAKE_GH_INVALID_RESPONSE=0

idempotent_environment=$(jq -nc --arg setup "$expected_script" --arg guidance "$expected_guidance_script" '[{id:"environment-1",etag:"etag-1",github_connector_id:"connector-1",repos:["repo-1"],setup:[$setup],maintenance_setup:[$setup],auto_setup_settings:{use_auto_setup:false}},{id:"environment-2",etag:"etag-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:[$guidance],maintenance_setup:[$guidance],auto_setup_settings:{use_auto_setup:false}}]')
export FAKE_ENVIRONMENTS="$idempotent_environment"
run_sync "$test_root/idempotent.out"
[[ ! -e $test_root/requests/create.jsonl && ! -e $test_root/requests/update.json ]] || fail 'idempotent sync wrote an environment'

auto_setup_drift=$(jq --arg target 'repo-1' '
    map(if .repos == [$target] then
        .auto_setup_settings = {use_auto_setup:true, cache_hint:"keep"} |
        .agent_network_access = {mode:"off"}
    else . end)
' <<<"$idempotent_environment")
export FAKE_ENVIRONMENTS="$auto_setup_drift"
run_sync "$test_root/auto-setup-drift.out"
jq -e --arg expected "$expected_script" '
    keys == ["auto_setup_settings", "etag", "maintenance_setup", "setup"] and
    .etag == "etag-1" and .setup == $expected and .maintenance_setup == $expected and
    .auto_setup_settings == {use_auto_setup:false, cache_hint:"keep"}
' "$test_root/requests/update.json" >/dev/null || fail 'automatic setup drift was not corrected narrowly'
rm -f "$test_root/requests/update.json"

legacy_dual_environment=$(jq -nc --arg setup "$expected_script" --arg guidance "$expected_guidance_script" '[{id:"environment-1",etag:"etag-1",github_connector_id:"connector-1",repos:["guidance-1","repo-1"],setup:$setup,maintenance_setup:$setup,auto_setup_settings:{use_auto_setup:false}},{id:"environment-2",etag:"etag-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:$guidance,maintenance_setup:$guidance,auto_setup_settings:{use_auto_setup:false}}]')
export FAKE_ENVIRONMENTS="$legacy_dual_environment"
run_sync "$test_root/legacy-dual.out"
jq -e --arg expected "$expected_script" 'keys == ["etag", "maintenance_setup", "repos", "setup"] and .etag == "etag-1" and .repos == ["repo-1"] and .setup == $expected and .maintenance_setup == $expected' "$test_root/requests/update.json" >/dev/null || fail 'dual-repository environment was not migrated to its target singleton'
rm -f "$test_root/requests/update.json"

invalid_matching_id_environment=$(jq -nc --arg setup "$expected_script" --arg guidance "$expected_guidance_script" '[{id:"invalid/environment-id",github_connector_id:"connector-1",repos:["repo-1"],setup:$setup,maintenance_setup:$setup,auto_setup_settings:{use_auto_setup:false}},{id:"environment-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:$guidance,maintenance_setup:$guidance,auto_setup_settings:{use_auto_setup:false}}]')
export FAKE_ENVIRONMENTS="$invalid_matching_id_environment"
if run_sync "$test_root/invalid-matching-id.out" --dry-run; then
    fail 'invalid matching environment ID was accepted as unchanged'
fi
grep -qxF 'matched environment has an invalid ID' "$test_root/invalid-matching-id.out" || fail 'invalid matching environment ID failure was not safe'

legacy_environment=$(jq -nc --arg setup "$expected_script" --arg guidance "$expected_guidance_script" '[{id:"environment-1",etag:"etag-1",github_connector_id:"connector-1",repos:["repo-1"],setup:["old"],maintenance_setup:"old",auto_setup_settings:{use_auto_setup:false}},{id:"environment-2",etag:"etag-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:[$guidance],maintenance_setup:[$guidance],auto_setup_settings:{use_auto_setup:false}}]')
export FAKE_ENVIRONMENTS="$legacy_environment"
run_sync "$test_root/update.out"
if [[ ! -f $test_root/requests/update.json ]]; then
    cat "$test_root/update.out" >&2
    fail 'expected update request'
fi
jq -e --arg expected "$expected_script" 'keys == ["etag", "maintenance_setup", "setup"] and .etag == "etag-1" and .setup == $expected and .maintenance_setup == $expected' "$test_root/requests/update.json" >/dev/null || fail 'single-repository script update payload is incorrect'

rm -f "$test_root/requests/create.jsonl" "$test_root/requests/update.json"
export FAKE_ENVIRONMENTS='[]'
run_sync "$test_root/dry-run.out" --dry-run
grep -qxF 'Codex Cloud environment sync dry run: 2 proposed changes, 0 unchanged' "$test_root/dry-run.out" || fail 'two-page inventory did not include both repositories'
[[ ! -e $test_root/requests/create.jsonl && ! -e $test_root/requests/update.json ]] || fail 'dry run wrote an environment'

export FAKE_ENVIRONMENTS='[{"id":"environment-1","etag":"etag-1","github_connector_id":"connector-1","repos":["repo-1"],"setup":["old"],"maintenance_setup":["old"]},{"id":"environment-2","etag":"etag-2","github_connector_id":"connector-1","repos":["repo-1","guidance-1"],"setup":["old"],"maintenance_setup":["old"]}]'
if run_sync "$test_root/duplicate.out" --dry-run; then
    fail 'duplicate environments were accepted'
fi
grep -qxF 'multiple candidate environments found for one repository; refusing to choose one' "$test_root/duplicate.out" || fail 'duplicate failure was not clear and safe'

export FAKE_HTTP_FAIL=1
if run_sync "$test_root/http-failure.out"; then
    fail 'HTTP failure was accepted'
fi
grep -qF 'HTTP GET /wham/environments status 500' "$test_root/http-failure.out" || fail 'HTTP failure was not sanitized'
if grep -qF 'response body must not leak' "$test_root/http-failure.out"; then
    fail 'HTTP response body leaked'
fi

export FAKE_HTTP_FAIL=0
export FAKE_PATCH_HTTP_FAIL=1
export FAKE_ENVIRONMENTS='[{"id":"sensitive-environment-id","etag":"etag-1","github_connector_id":"connector-1","repos":["repo-1"],"setup":["old"],"maintenance_setup":["old"]},{"id":"guidance-environment","etag":"etag-2","github_connector_id":"connector-1","repos":["guidance-1"],"setup":["old"],"maintenance_setup":["old"]}]'
if run_sync "$test_root/patch-failure.out"; then
    fail 'PATCH failure was accepted'
fi
grep -qF 'HTTP PATCH /wham/environments/{environment_id} status 500' "$test_root/patch-failure.out" || fail 'PATCH failure was not sanitized'
if grep -qF 'response body must not leak' "$test_root/patch-failure.out" || grep -qF 'sensitive-environment-id' "$test_root/patch-failure.out"; then
    fail 'PATCH failure leaked sensitive data'
fi

export FAKE_HTTP_FAIL=0
export FAKE_PATCH_HTTP_FAIL=0
export FAKE_ENVIRONMENTS='[]'
export FAKE_SEARCH_RESPONSE='{"repositories":"invalid"}'
if run_sync "$test_root/discovery-failure.out"; then
    fail 'invalid repository discovery response was accepted'
fi
grep -qxF 'repository connector lookup response has an unexpected schema' "$test_root/discovery-failure.out" || fail 'repository connector lookup failure was not propagated'

export FAKE_SEARCH_RESPONSE='{"repositories":[{"id":"","name":"example-repo"}]}'
if run_sync "$test_root/empty-id-failure.out"; then
    fail 'empty repository ID was accepted'
fi
grep -qxF 'repository connector lookup response has an unexpected schema' "$test_root/empty-id-failure.out" || fail 'empty repository ID was not rejected'

export FAKE_SEARCH_RESPONSE='{"repositories":[{"id":"guidance-1","name":"_agent-guidance"},{"id":"repo-1","name":"example-repo"},{"id":"repo-2","name":"second-repo"}]}'
export FAKE_INVENTORY_PAGE1='{"repo_review_settings":[{"repository":{"id":"guidance-1","name":"_agent-guidance","repository_full_name":"Adam-S-Daniel/_agent-guidance"}}],"next_token":"opaque-next-token"}'
export FAKE_INVENTORY_PAGE2='{"repo_review_settings":[{"repository":{"id":"repo-2","name":"second-repo","repository_full_name":"Example/second-repo"}}],"next_token":null}'
export FAKE_ENVIRONMENTS='[]'
run_sync "$test_root/two-page.out" --dry-run
grep -qxF 'Codex Cloud environment sync dry run: 2 proposed changes, 0 unchanged' "$test_root/two-page.out" || fail 'second inventory page was not included'

export FAKE_INVENTORY_PAGE1=$'{"repo_review_settings":[],"next_token":"bad\\nnext-token"}'
if run_sync "$test_root/newline-token.out" --dry-run; then
    fail 'newline-containing pagination token was accepted'
fi
grep -qxF 'repository inventory response has an unexpected schema' "$test_root/newline-token.out" || fail 'pagination token failure was not sanitized'

export FAKE_INVENTORY_PAGE1='{"repo_review_settings":[{"repository":{"id":"guidance-1","name":"_agent-guidance","repository_full_name":"Adam-S-Daniel/_agent-guidance"}},{"repository":{"id":"repo-1","name":"different-name","repository_full_name":"Example/example-repo"}}],"next_token":null}'
if run_sync "$test_root/mismatched-name.out" --dry-run; then
    fail 'mismatched repository name and full path were accepted'
fi
grep -qxF 'repository inventory item has an invalid GitHub repository path' "$test_root/mismatched-name.out" || fail 'mismatched path failure was not sanitized'

printf '%s\n' 'PASS: 26 Codex Cloud environment sync behaviors'
