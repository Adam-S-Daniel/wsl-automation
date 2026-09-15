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
        --silent|--show-error|--get) shift ;;
        *) url=$1; shift ;;
    esac
done
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
    chmod 755 "$test_root/bin/codex" "$test_root/bin/curl"
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
export FAKE_INVENTORY_PAGE1='{"repo_review_settings":[{"repository":{"id":"guidance-1","name":"_agent-guidance","repository_full_name":"Adam-S-Daniel/_agent-guidance"}},{"repository":{"id":"repo-1","name":"example-repo","repository_full_name":"Example/example-repo"}}],"next_token":null}'
export FAKE_INVENTORY_PAGE2='{"repo_review_settings":[],"next_token":null}'
export FAKE_SEARCH_RESPONSE='{"repositories":[{"id":"guidance-1","name":"_agent-guidance"},{"id":"repo-1","name":"example-repo"}]}'
export CODEX_CLOUD_GITHUB_CONNECTOR_ID='connector-1'
expected_script=$'set -euo pipefail\ncd /workspace/_agent-guidance\nnpm ci\nCODEX_HOME="'
expected_script+='$'
expected_script+=$'{CODEX_HOME:-/opt/codex}" \\\n  bash .claude/hooks/fleet-memory.sh --codex-cloud\n'

export FAKE_ENVIRONMENTS='[{"id":"unrelated-environment","repos":[]}]'
export CODEX_CLOUD_GITHUB_CONNECTOR_ID=$'connector\nmalicious'
if run_sync "$test_root/malicious-connector.out" --dry-run; then
    fail 'newline-containing connector ID was accepted'
fi
grep -qxF 'candidate connector ID is invalid' "$test_root/malicious-connector.out" || fail 'malicious connector failure was not sanitized'
export CODEX_CLOUD_GITHUB_CONNECTOR_ID='connector-1'

run_sync "$test_root/create.out"
[[ -f $test_root/requests/create.jsonl ]] || fail 'expected create requests'
jq -s -e --arg expected "$expected_script" '
    length == 2 and
    any(.[]; (.repos | sort) == ["guidance-1", "repo-1"] and .setup == $expected and .maintenance_setup == $expected) and
    any(.[]; .repos == ["guidance-1"] and .setup == $expected and .maintenance_setup == $expected)
' "$test_root/requests/create.jsonl" >/dev/null || fail 'create payloads do not include the guidance repository correctly'

rm -f "$test_root/requests/create.jsonl" "$test_root/requests/update.json"
idempotent_environment=$(jq -nc --arg setup "$expected_script" '[{id:"environment-1",etag:"etag-1",github_connector_id:"connector-1",repos:["repo-1","guidance-1"],setup:[$setup],maintenance_setup:[$setup]},{id:"environment-2",etag:"etag-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:[$setup],maintenance_setup:[$setup]}]')
export FAKE_ENVIRONMENTS="$idempotent_environment"
run_sync "$test_root/idempotent.out"
[[ ! -e $test_root/requests/create.jsonl && ! -e $test_root/requests/update.json ]] || fail 'idempotent sync wrote an environment'

invalid_matching_id_environment=$(jq -nc --arg setup "$expected_script" '[{id:"invalid/environment-id",github_connector_id:"connector-1",repos:["repo-1","guidance-1"],setup:$setup,maintenance_setup:$setup},{id:"environment-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:$setup,maintenance_setup:$setup}]')
export FAKE_ENVIRONMENTS="$invalid_matching_id_environment"
if run_sync "$test_root/invalid-matching-id.out" --dry-run; then
    fail 'invalid matching environment ID was accepted as unchanged'
fi
grep -qxF 'matched environment has an invalid ID' "$test_root/invalid-matching-id.out" || fail 'invalid matching environment ID failure was not safe'

legacy_environment=$(jq -nc --arg setup "$expected_script" '[{id:"environment-1",etag:"etag-1",github_connector_id:"connector-1",repos:["repo-1"],setup:["old"],maintenance_setup:"old"},{id:"environment-2",etag:"etag-2",github_connector_id:"connector-1",repos:["guidance-1"],setup:[$setup],maintenance_setup:[$setup]}]')
export FAKE_ENVIRONMENTS="$legacy_environment"
run_sync "$test_root/update.out"
if [[ ! -f $test_root/requests/update.json ]]; then
    cat "$test_root/update.out" >&2
    fail 'expected update request'
fi
jq -e --arg expected "$expected_script" 'keys == ["etag", "maintenance_setup", "repos", "setup"] and .etag == "etag-1" and (.repos | sort) == ["guidance-1", "repo-1"] and .setup == $expected and .maintenance_setup == $expected' "$test_root/requests/update.json" >/dev/null || fail 'legacy environment migration payload is incorrect'

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

printf '%s\n' 'PASS: 13 Codex Cloud environment sync behaviors'
