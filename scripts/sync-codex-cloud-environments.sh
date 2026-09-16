#!/usr/bin/env bash
# Reconciles one Codex Cloud environment for every repository visible through
# the configured GitHub connectors. It deliberately emits aggregate-only status.
set -euo pipefail

readonly api_base='https://chatgpt.com/backend-api'
readonly connector_search_limit=10
readonly inventory_page_size=100
readonly max_inventory_pages=100
readonly desired_script=$'set -euo pipefail\ncd /workspace/_agent-guidance\nnpm ci\nCODEX_HOME="${CODEX_HOME:-/opt/codex}" \\\n  bash .claude/hooks/fleet-memory.sh --codex-cloud\n'

dry_run=false
connector_override="${CODEX_CLOUD_GITHUB_CONNECTOR_ID:-}"
guidance_repository="${CODEX_CLOUD_GUIDANCE_REPOSITORY:-Adam-S-Daniel/_agent-guidance}"

usage() {
    printf '%s\n' 'usage: sync-codex-cloud-environments.sh [--dry-run] [--connector-id ID]'
}

while (($#)); do
    case "$1" in
        --dry-run) dry_run=true ;;
        --connector-id)
            shift
            if (($# == 0)) || [[ -z $1 ]]; then
                printf '%s\n' 'missing connector ID' >&2
                exit 2
            fi
            connector_override=$1
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

for dependency in codex curl jq flock mktemp; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'missing dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done

runtime_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
if [[ ! -d $runtime_dir || ! -w $runtime_dir ]]; then
    printf '%s\n' 'no writable per-user runtime directory' >&2
    exit 1
fi
lock_file="$runtime_dir/codex-cloud-environment-sync-${UID}.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
    printf '%s\n' 'another Codex Cloud environment sync is already running' >&2
    exit 1
fi

temporary_dir=$(mktemp -d "${runtime_dir%/}/codex-cloud-environment-sync.XXXXXX")
if [[ ! -d $temporary_dir || $temporary_dir != "${runtime_dir%/}"/* ]]; then
    printf '%s\n' 'could not create a safe temporary directory' >&2
    exit 1
fi
trap 'rm -rf -- "$temporary_dir"' EXIT

# This refreshes expiring credentials without an interactive login flow.
if ! codex cloud list --limit 1 >/dev/null 2>&1; then
    printf '%s\n' 'Codex login refresh failed' >&2
    exit 1
fi

codex_home="${CODEX_HOME:-$HOME/.codex}"
auth_file="$codex_home/auth.json"
if [[ ! -r $auth_file ]]; then
    printf '%s\n' 'Codex authentication state is unavailable' >&2
    exit 1
fi
access_token=$(jq -er '.tokens.access_token | strings | select(length > 0)' "$auth_file") || {
    printf '%s\n' 'Codex authentication state is invalid' >&2
    exit 1
}
account_id=$(jq -er '.tokens.account_id | strings | select(length > 0)' "$auth_file") || {
    printf '%s\n' 'Codex authentication state is invalid' >&2
    exit 1
}
if [[ $access_token == *$'\r'* || $access_token == *$'\n'* || $account_id == *$'\r'* || $account_id == *$'\n'* ]]; then
    printf '%s\n' 'Codex authentication state is invalid' >&2
    exit 1
fi
header_file="$temporary_dir/request-headers"
umask 077
printf 'Authorization: Bearer %s\nChatGPT-Account-ID: %s\nOAI-Product-Sku: CODEX\n' "$access_token" "$account_id" >"$header_file"

request() {
    local method=$1
    local path=$2
    local output=$3
    local body=${4:-}
    local error_path=${5:-$path}
    local status
    local -a args=(
        --silent --show-error --output "$output" --write-out '%{http_code}'
        --request "$method"
        --header "@$header_file"
    )
    if [[ -n $body ]]; then
        args+=(--header 'Content-Type: application/json' --data-binary "@$body")
    fi
    if ! status=$(curl "${args[@]}" "${api_base}${path}" 2>/dev/null); then
        printf 'HTTP %s %s transport failure\n' "$method" "$error_path" >&2
        return 1
    fi
    if [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
        printf 'HTTP %s %s status %s\n' "$method" "$error_path" "$status" >&2
        return 1
    fi
}

environment_file="$temporary_dir/environments.json"
request GET /wham/environments "$environment_file"
if ! jq -e '
    type == "array" and
    all(.[]; type == "object" and
        (.id | type == "string" and length > 0) and
        (.repos | type == "array"))
' "$environment_file" >/dev/null; then
    printf '%s\n' 'environment response has an unexpected schema' >&2
    exit 1
fi

if [[ -n $connector_override ]]; then
    connector_file="$temporary_dir/connectors.json"
    jq -n --arg connector "$connector_override" '[$connector]' >"$connector_file"
else
    connector_file="$temporary_dir/connectors.json"
    jq '[.[] | select((.github_connector_id? | type == "string") and (.github_connector_id | length > 0)) | .github_connector_id] | unique' "$environment_file" >"$connector_file"
fi
if [[ $(jq 'length' "$connector_file") -eq 0 ]]; then
    printf '%s\n' 'no GitHub connector is available; set CODEX_CLOUD_GITHUB_CONNECTOR_ID to bootstrap' >&2
    exit 1
fi
if ! jq -e 'all(.[]; type == "string" and test("^[A-Za-z0-9_-]+$"))' "$connector_file" >/dev/null; then
    printf '%s\n' 'candidate connector ID is invalid' >&2
    exit 1
fi

inventory_file="$temporary_dir/inventory.json"
seen_tokens_file="$temporary_dir/seen-tokens.txt"
jq -n '[]' >"$inventory_file"
: >"$seen_tokens_file"
next_token=''
for ((page_number = 1; page_number <= max_inventory_pages; page_number++)); do
    inventory_response="$temporary_dir/inventory-response.json"
    inventory_args=(--get --data-urlencode "per_page=$inventory_page_size")
    if [[ -n $next_token ]]; then
        inventory_args+=(--data-urlencode "next_token=$next_token")
    fi
    if ! status=$(curl --silent --show-error --output "$inventory_response" --write-out '%{http_code}' \
        "${inventory_args[@]}" --header "@$header_file" \
        "${api_base}/wham/settings/code_review" 2>/dev/null); then
        printf '%s\n' 'HTTP GET /wham/settings/code_review transport failure' >&2
        exit 1
    fi
    if [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
        printf 'HTTP GET /wham/settings/code_review status %s\n' "$status" >&2
        exit 1
    fi
    if ! jq -e '
        type == "object" and (.repo_review_settings | type == "array") and
        ((.next_token == null) or
            (.next_token | type == "string" and length > 0 and (test("[\\r\\n]") | not))) and
        all(.repo_review_settings[]; type == "object" and (.repository | type == "object") and
            (.repository.id | type == "string" and length > 0) and
            (.repository.name | type == "string" and length > 0) and
            (.repository.repository_full_name | type == "string" and length > 0))
    ' "$inventory_response" >/dev/null; then
        printf '%s\n' 'repository inventory response has an unexpected schema' >&2
        exit 1
    fi
    jq '[.repo_review_settings[] | {id: .repository.id, name: .repository.name, full_name: .repository.repository_full_name}]' \
        "$inventory_response" >"$temporary_dir/inventory-page.json"
    if ! jq -s '
        add | group_by(.id) |
        all(.[]; ([.[].name] | unique | length) == 1 and ([.[].full_name] | unique | length) == 1)
    ' "$inventory_file" "$temporary_dir/inventory-page.json" >/dev/null; then
        printf '%s\n' 'repository inventory has conflicting metadata for one ID' >&2
        exit 1
    fi
    jq -s 'add | unique_by(.id)' "$inventory_file" "$temporary_dir/inventory-page.json" >"$temporary_dir/merged-inventory.json"
    mv "$temporary_dir/merged-inventory.json" "$inventory_file"
    if jq -e '.next_token == null' "$inventory_response" >/dev/null; then
        break
    fi
    next_token=$(jq -er '.next_token' "$inventory_response")
    if grep -qxF -- "$next_token" "$seen_tokens_file"; then
        printf '%s\n' 'repository inventory repeated a pagination token' >&2
        exit 1
    fi
    printf '%s\n' "$next_token" >>"$seen_tokens_file"
    if ((page_number == max_inventory_pages)); then
        printf '%s\n' 'repository inventory exceeded the pagination safety limit' >&2
        exit 1
    fi
done

if [[ $(jq 'length' "$inventory_file") -eq 0 ]]; then
    printf '%s\n' 'repository inventory returned zero repositories' >&2
    exit 1
fi
guidance_matches=$(jq --arg full_name "$guidance_repository" '[.[] | select(.full_name == $full_name)] | length' "$inventory_file")
if [[ $guidance_matches -ne 1 ]]; then
    printf '%s\n' 'the required guidance repository is absent or ambiguous in the repository inventory' >&2
    exit 1
fi
guidance_repository_id=$(jq -er --arg full_name "$guidance_repository" '.[] | select(.full_name == $full_name) | .id' "$inventory_file")

connector_lines="$temporary_dir/connector-lines.txt"
jq -r '.[]' "$connector_file" >"$connector_lines"
repositories_file="$temporary_dir/repositories.json"
jq -n '[]' >"$repositories_file"
inventory_lines="$temporary_dir/inventory-lines.jsonl"
jq -c '.[]' "$inventory_file" >"$inventory_lines"
while IFS= read -r inventory_repository; do
    repository_id=$(jq -er '.id' <<<"$inventory_repository")
    repository_name=$(jq -er '.name' <<<"$inventory_repository")
    repository_full_name=$(jq -er '.full_name' <<<"$inventory_repository")
    matching_connectors="$temporary_dir/matching-connectors.json"
    jq -n '[]' >"$matching_connectors"
    while IFS= read -r connector_id; do
        response_file="$temporary_dir/repository-search.json"
        if ! status=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
            --get --data-urlencode "connector_id=$connector_id" \
            --data-urlencode "query=$repository_full_name" --data-urlencode "limit=$connector_search_limit" \
            --header "@$header_file" \
            "${api_base}/wham/github/repositories/search/all-installations" 2>/dev/null); then
            printf '%s\n' 'HTTP GET /wham/github/repositories/search/all-installations transport failure' >&2
            exit 1
        fi
        if [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
            printf 'HTTP GET /wham/github/repositories/search/all-installations status %s\n' "$status" >&2
            exit 1
        fi
        if ! jq -e '
            (if type == "array" then . else (.repositories // .items // .data) end) as $rows |
            ($rows | type == "array") and
            all($rows[]; type == "object" and (.id | type == "string" and length > 0))
        ' "$response_file" >/dev/null; then
            printf '%s\n' 'repository connector lookup response has an unexpected schema' >&2
            exit 1
        fi
        if jq -e --arg id "$repository_id" '
            (if type == "array" then . else (.repositories // .items // .data) end) |
            any(.[]; .id == $id)
        ' "$response_file" >/dev/null; then
            jq --arg connector "$connector_id" '. + [$connector] | unique' "$matching_connectors" >"$temporary_dir/merged-connectors.json"
            mv "$temporary_dir/merged-connectors.json" "$matching_connectors"
        fi
    done <"$connector_lines"
    if [[ $(jq 'length' "$matching_connectors") -eq 0 ]]; then
        printf '%s\n' 'repository inventory item is not visible through a candidate connector' >&2
        exit 1
    fi
    selected_connector=$(jq -er 'sort | .[0]' "$matching_connectors")
    jq --arg id "$repository_id" --arg name "$repository_name" --arg full_name "$repository_full_name" --arg connector "$selected_connector" \
        '. + [{id: $id, name: $name, full_name: $full_name, connector_id: $connector}]' "$repositories_file" >"$temporary_dir/merged-repositories.json"
    mv "$temporary_dir/merged-repositories.json" "$repositories_file"
done <"$inventory_lines"

repositories_lines="$temporary_dir/repository-lines.jsonl"
jq -c '.[]' "$repositories_file" >"$repositories_lines"

created=0
updated=0
unchanged=0
dry_run_changes=0
while IFS= read -r repository; do
    repository_id=$(jq -er '.id' <<<"$repository")
    repository_name=$(jq -er '.name' <<<"$repository")
    connector_id=$(jq -er '.connector_id' <<<"$repository")
    expected_repos=$(jq -nc --arg target "$repository_id" '[$target]')
    matches_file="$temporary_dir/matches.json"
    if [[ $repository_id == "$guidance_repository_id" ]]; then
        jq --arg id "$repository_id" --argjson expected "$expected_repos" '
            [.[] | .repos as $repos | select(($repos | type) == "array") |
                select($repos | all(.[]; type == "string" and length > 0)) |
                select(($repos | sort) == $expected)]
        ' "$environment_file" >"$matches_file"
    else
        legacy_dual_repo_set=$(jq -nc --arg target "$repository_id" --arg guidance "$guidance_repository_id" '[$target, $guidance] | sort')
        invalid_association_count=$(jq --arg id "$repository_id" --argjson expected "$legacy_dual_repo_set" '
            [.[] | .repos as $repos | select(($repos | type) == "array" and ($repos | index($id))) |
                select((($repos | all(.[]; type == "string" and length > 0)) | not) or (($repos | sort) != [$id] and ($repos | sort) != $expected))] | length
        ' "$environment_file")
        if ((invalid_association_count > 0)); then
            printf '%s\n' 'an existing environment associates a target repository with unrelated repositories' >&2
            exit 1
        fi
        jq --arg id "$repository_id" --argjson expected "$legacy_dual_repo_set" '
            [.[] | .repos as $repos | select(($repos | type) == "array") |
                select($repos | all(.[]; type == "string" and length > 0)) |
                select(($repos | sort) == [$id] or ($repos | sort) == $expected)]
        ' "$environment_file" >"$matches_file"
    fi
    match_count=$(jq 'length' "$matches_file")
    if ((match_count > 1)); then
        printf '%s\n' 'multiple candidate environments found for one repository; refusing to choose one' >&2
        exit 1
    fi
    if ((match_count == 0)); then
        payload_file="$temporary_dir/create.json"
        jq -n --arg label "$repository_name" --argjson repos "$expected_repos" --arg connector "$connector_id" \
            --arg setup "$desired_script" '{
                label: $label, description: "", machine_id: "wham-public/wham-universal",
                repos: $repos, github_connector_id: $connector, workspace_dir: "/workspace",
                agent_network_access: {mode: "off"}, setup: $setup, maintenance_setup: $setup,
                env_vars: {}, secrets_with_domains: [], share_settings: "workspace", share_targets: [],
                auto_setup_settings: {use_auto_setup: false},
                cache_settings: {post_setup_cache_enabled: true}, enable_authtranslator: false,
                enable_docker_in_docker: false
            }' >"$payload_file"
        if $dry_run; then
            ((dry_run_changes+=1))
        else
            request POST /wham/environments "$temporary_dir/create-response.json" "$payload_file"
            ((created+=1))
        fi
        continue
    fi

    environment=$(jq -c '.[0]' "$matches_file")
    if ! jq -e '(.id | type == "string" and test("^[A-Za-z0-9_-]+$"))' <<<"$environment" >/dev/null; then
        printf '%s\n' 'matched environment has an invalid ID' >&2
        exit 1
    fi
    if jq -e --arg desired "$desired_script" --argjson expected "$expected_repos" '
        def script: if type == "array" then join("\n") else . end;
        (.setup | script) == $desired and (.maintenance_setup | script) == $desired and .repos == $expected
    ' <<<"$environment" >/dev/null; then
        ((unchanged+=1))
        continue
    fi
    payload_file="$temporary_dir/update.json"
    if ! jq -e '(.etag | type == "string" and length > 0)' <<<"$environment" >/dev/null; then
        printf '%s\n' 'matched environment is missing the data required for a safe update' >&2
        exit 1
    fi
    jq -n --argjson environment "$environment" --argjson expected "$expected_repos" --arg setup "$desired_script" '
        {etag: $environment.etag, setup: $setup, maintenance_setup: $setup} +
        (if $environment.repos == $expected then {} else {repos: $expected} end)
    ' >"$payload_file"
    environment_id=$(jq -er '.id' <<<"$environment")
    if $dry_run; then
        ((dry_run_changes+=1))
    else
        request PATCH "/wham/environments/$environment_id" "$temporary_dir/update-response.json" "$payload_file" '/wham/environments/{environment_id}'
        ((updated+=1))
    fi
done <"$repositories_lines"

if $dry_run; then
    printf 'Codex Cloud environment sync dry run: %d proposed changes, %d unchanged\n' "$dry_run_changes" "$unchanged"
else
    printf 'Codex Cloud environment sync complete: %d created, %d updated, %d unchanged\n' "$created" "$updated" "$unchanged"
fi
