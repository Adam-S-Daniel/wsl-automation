#!/usr/bin/env bash
# Publishes the "waiting on Adam" feed: his Claude Code cloud sessions that are
# blocked or ready for review, as feed.json on the persistent/waiting-feed
# branch of the private Adam-S-Daniel/waiting-feed repository.
#
# Run every minute by the 'Claude Waiting Feed Publish' scheduled task, which
# calls wsl.exe directly. It reads the Claude Code login that already exists
# (~/.claude/.credentials.json) and NEVER refreshes it: an expired login is
# reported as login_expired and the previous items are kept.
#
# Unlike publish-usage-census.sh this does not bootstrap a Windows checkout
# update itself (a pwsh.exe updater with a 300 s timeout is far too heavy for a
# 1-minute cadence). It still runs from the shared task checkout, which the
# other tasks fast-forward to origin/main, so whatever lands on main runs here
# with the Claude login and the git credential in reach.
#
# The feed branch is output only and keeps exactly one commit, whose tree holds
# feed.json and nothing else: each publish replaces it (force-with-lease), so
# session titles and asks from earlier minutes are not kept in its history.
# main is a fleet repo's default branch, which takes changes only through pull
# requests (the agent-checks pre-push hook refuses a direct push), so the
# script never writes it. The commit is built from objects, not the clone's
# index or working tree, so the clone stays on a clean main. Titles are capped and obvious secret
# shapes (API keys, tokens) are masked before anything is written.
#
# Output is one aggregate-only line per run: counts, never titles, ids or
# tokens. The same line, with a UTC timestamp and the exit code, is appended to
# the log only when a run published or failed, so a quiet minute adds nothing.
#
# Usage: publish-waiting-feed.sh [--dry-run]   (--dry-run: no write, commit or push)
#
# Environment seams (for tests):
#   WAITING_FEED_CREDENTIALS  default ~/.claude/.credentials.json
#   WAITING_FEED_CLAUDE_JSON  default ~/.claude.json
#   WAITING_FEED_API_BASE     default https://api.anthropic.com
#   WAITING_FEED_NOW          epoch seconds (default: now); expiry check and heartbeat
#   WAITING_FEED_DIR          feed clone (default ~/.cache/waiting-feed)
#   WAITING_FEED_URL          feed remote (default the private GitHub repo)
#   WAITING_FEED_LOG          log file (default ~/.cache/waiting-feed.log)
set -euo pipefail

# The task starts a non-login shell (wsl.exe --exec), whose PATH lacks
# ~/.local/bin, where jq may be installed. Append it so system tools still win.
PATH="$PATH:$HOME/.local/bin"

# Never wait on a credential prompt: the task runs with no one to answer it.
export GIT_TERMINAL_PROMPT=0

readonly max_pages=3
readonly log_max_lines=2000
readonly heartbeat_seconds=900
readonly tagged_query='limit=100&tags=hearth-thread&tags=cowork-local&tags=cowork-remote'

dry_run=false
case "${1:-}" in
    '') ;;
    --dry-run) dry_run=true ;;
    *)
        printf '%s\n' 'usage: publish-waiting-feed.sh [--dry-run]' >&2
        exit 2
        ;;
esac

credentials=${WAITING_FEED_CREDENTIALS:-$HOME/.claude/.credentials.json}
claude_json=${WAITING_FEED_CLAUDE_JSON:-$HOME/.claude.json}
api_base=${WAITING_FEED_API_BASE:-https://api.anthropic.com}
feed_dir=${WAITING_FEED_DIR:-$HOME/.cache/waiting-feed}
feed_url=${WAITING_FEED_URL:-https://github.com/Adam-S-Daniel/waiting-feed.git}
log_file=${WAITING_FEED_LOG:-$HOME/.cache/waiting-feed.log}
now=${WAITING_FEED_NOW:-$(date +%s)}
readonly feed_branch=persistent/waiting-feed

for dependency in curl jq flock git mktemp timeout; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'missing dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done

# Prefer the per-user tmpfs, so a request headers file left by a killed run
# does not outlive a reboot.
runtime_dir="${XDG_RUNTIME_DIR:-}"
if [[ -z $runtime_dir && -d /run/user/$UID && -w /run/user/$UID ]]; then
    runtime_dir="/run/user/$UID"
fi
runtime_dir="${runtime_dir:-/tmp}"
if [[ ! -d $runtime_dir || ! -w $runtime_dir ]]; then
    printf '%s\n' 'no writable per-user runtime directory' >&2
    exit 1
fi
exec 9>"$runtime_dir/waiting-feed-publish-${UID}.lock"
if ! flock -n 9; then
    printf '%s\n' 'another waiting feed publish is already running' >&2
    exit 1
fi

temporary_dir=$(mktemp -d "${runtime_dir%/}/waiting-feed-publish.XXXXXX")
if [[ ! -d $temporary_dir || $temporary_dir != "${runtime_dir%/}"/* ]]; then
    printf '%s\n' 'could not create a safe temporary directory' >&2
    exit 1
fi
trap 'rm -rf -- "$temporary_dir"' EXIT

timestamp=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)

log_line() {
    mkdir -p -- "$(dirname -- "$log_file")"
    printf '%s exit=%s %s\n' "$timestamp" "$2" "$1" >>"$log_file"
    # A long outage logs every minute; keep only the most recent lines.
    if (($(wc -l <"$log_file") > log_max_lines)); then
        tail -n "$((log_max_lines / 2))" -- "$log_file" >"$log_file.tmp" && mv -f -- "$log_file.tmp" "$log_file"
    fi
}

# The clone is the only state: its origin/persistent/waiting-feed is the
# previous feed.
if [[ ! -d $feed_dir/.git ]]; then
    mkdir -p -- "$(dirname -- "$feed_dir")"
    if ! timeout 60 git clone --quiet -- "$feed_url" "$feed_dir" >/dev/null 2>&1; then
        line='waiting feed: could not clone the feed repository'
        printf '%s\n' "$line"
        log_line "$line" 1
        exit 1
    fi
fi
git_feed=(git -C "$feed_dir")
# Only ever push to the feed repository this script was configured with
# (compared without a trailing .git or slash).
same_repo() {
    local a=${1%/} b=${2%/}
    [[ ${a%.git} == "${b%.git}" ]]
}
if ! same_repo "$("${git_feed[@]}" remote get-url origin 2>/dev/null || true)" "$feed_url"; then
    line='waiting feed: the clone does not point at the feed repository'
    printf '%s\n' "$line"
    log_line "$line" 1
    exit 1
fi
# The remote is the source of truth: anything committed there by hand (or a
# replaced commit) must not wedge every later push as a non-fast-forward.
# Keeping the checkout on origin/main keeps the hooks it carries current.
if timeout 60 "${git_feed[@]}" fetch --quiet --prune origin >/dev/null 2>&1 &&
    main_head=$("${git_feed[@]}" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null); then
    "${git_feed[@]}" reset --quiet --hard "$main_head" >/dev/null 2>&1 || true
fi
prev_head=$("${git_feed[@]}" rev-parse -q --verify "refs/remotes/origin/$feed_branch" 2>/dev/null || true)
committed_file="$temporary_dir/committed.json"
if [[ -n $prev_head ]] && "${git_feed[@]}" show "$prev_head:feed.json" >"$committed_file" 2>/dev/null &&
    jq -e 'type == "object"' "$committed_file" >/dev/null 2>&1; then
    :
else
    printf '%s\n' '{}' >"$committed_file"
fi

# --- Collect the sessions; on failure err holds the short code ---------------
err=''
items_file="$temporary_dir/items.json"
all_file="$temporary_dir/all.jsonl"
body_file="$temporary_dir/body.json"
header_file="$temporary_dir/request-headers"
: >"$all_file"

# Fetch one page of the listing ($1 = query string) and append its items.
fetch_page() {
    local status
    # -q: ignore ~/.curlrc (a trace option there would log the token).
    if ! status=$(curl -q -sS --proto '=https' --max-time 30 -o "$body_file" -w '%{http_code}' \
        -H "@$header_file" "$api_base/v1/code/sessions?$1" 2>/dev/null); then
        err=network
        return 0
    fi
    if [[ $status == 401 ]]; then
        err=login_expired
    elif [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
        err="http_$status"
    elif ! jq -e '.data | type == "array"' "$body_file" >/dev/null 2>&1; then
        err=bad_response
    else
        jq -c '.data[]' "$body_file" >>"$all_file"
    fi
    return 0
}

collect() {
    local token org expires_at cursor query page
    if [[ ! -r $credentials ]] || [[ ! -r $claude_json ]]; then
        err=no_credentials
        return 0
    fi
    token=$(jq -er '.claudeAiOauth.accessToken | strings | select(length > 0)' "$credentials" 2>/dev/null) || {
        err=no_credentials
        return 0
    }
    org=$(jq -er '.oauthAccount.organizationUuid | strings | select(length > 0)' "$claude_json" 2>/dev/null) || {
        err=no_credentials
        return 0
    }
    if [[ $token == *$'\r'* || $token == *$'\n'* || $org == *$'\r'* || $org == *$'\n'* ]]; then
        err=no_credentials
        return 0
    fi
    # expiresAt is epoch milliseconds. Never refresh: just report it.
    expires_at=$(jq -r '.claudeAiOauth.expiresAt | numbers | floor' "$credentials" 2>/dev/null || true)
    if [[ $expires_at =~ ^[0-9]+$ ]] && ((expires_at <= now * 1000)); then
        err=login_expired
        return 0
    fi
    # The token goes to curl through a private headers file, never argv.
    (
        umask 077
        printf 'Authorization: Bearer %s\nanthropic-version: 2023-06-01\nx-organization-uuid: %s\nContent-Type: application/json\nUser-Agent: waiting-feed-publisher/1\n' \
            "$token" "$org" >"$header_file"
    )

    cursor=''
    for ((page = 1; page <= max_pages; page++)); do
        query='limit=100'
        if [[ -n $cursor ]]; then
            query+="&cursor=$(jq -rn --arg c "$cursor" '$c | @uri')"
        fi
        fetch_page "$query"
        [[ -z $err ]] || return 0
        cursor=$(jq -r '.next_cursor | strings' "$body_file")
        [[ -n $cursor ]] || break
    done
    # Project threads and Cowork sessions can sit past the first pages.
    fetch_page "$tagged_query"
    return 0
}
collect
# Done with the token: don't leave it on disk for the rest of the run.
rm -f -- "$header_file"

# --- Build the new feed ---------------------------------------------------
if [[ -z $err ]]; then
    jq -s '
        # The API exposes no project or thread ids, so every item links to its
        # plain session page. Change the link form here only.
        def link: "https://claude.ai/code/session_" + (.id | sub("^cse_"; ""));
        def has_tag($t): any((.tags // [])[]?; . == $t);
        def kind:
            if has_tag("hearth-thread") then "Project thread"
            elif has_tag("cowork-local") or has_tag("cowork-remote") then "Cowork"
            else (.config.origin? // null) as $o
                | if $o == "claude_code_cli" or $o == "claude_code_mcp_seed" then "Claude Code"
                  elif $o == "desktop_app" then "Desktop"
                  elif $o == "ios" then "iPhone"
                  elif $o == "android" then "Android"
                  elif $o == "web_claude_ai" then "Web"
                  elif $o == "claude-in-hearth" then "Project thread"
                  else "Session" end
            end;
        def nonempty: strings | select(length > 0);
        # Session text is copied to GitHub, so mask obvious credential shapes.
        def redact:
            gsub("(?<k>sk-ant-|sk-|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|xox[abposr]-|AKIA|ASIA|AIza)[A-Za-z0-9_\\-]{8,}"; "\(.k)[redacted]")
            | gsub("(?i)(?<k>bearer\\s+)[A-Za-z0-9._~+/=-]{16,}"; "\(.k)[redacted]");
        def ask:
            (.external_metadata.post_turn_summary? // {}) as $s
            | ((($s.needs_action? | nonempty) // ($s.status_detail? | nonempty)) // null)
            | if . == null then null else (redact | .[0:400]) end;
        def short_title: if type == "string" then (redact | .[0:200]) else null end;
        [ .[]
          | select(type == "object" and (.id | type == "string") and (.id | test("^cse_[A-Za-z0-9_-]+$")))
        ]
        | group_by(.id) | map(.[0])
        | map(select(
              (.status != "archived")
              and (has_tag("hearth-overview") | not)
              and (.status_bucket == "blocked" or .status_bucket == "review_ready")))
        | sort_by([.updated_at // "", .id]) | reverse
        | map({
              id,
              link: link,
              title: (.title | short_title),
              bucket: (if .status_bucket == "blocked" then "wait" else "review" end),
              kind: kind,
              updated_at,
              ask: ask,
              unread: (.unread == true)
          })
    ' "$all_file" >"$items_file"
    ok=true
else
    jq -c '.items // []' "$committed_file" >"$items_file"
    ok=false
fi

new_feed="$temporary_dir/feed.json"
jq -n --arg generated_at "$timestamp" --argjson ok "$ok" --arg error "$err" --slurpfile items "$items_file" '
    {generated_at: $generated_at, ok: $ok, error: (if $error == "" then null else $error end), items: $items[0]}
' >"$new_feed"

wait_count=$(jq '[.items[] | select(.bucket == "wait")] | length' "$new_feed")
review_count=$(jq '[.items[] | select(.bucket == "review")] | length' "$new_feed")

# --- Publish when something changed, or as a heartbeat ---------------------
state='{ok, error, items}'
new_state=$(jq -S -c "$state" "$new_feed")
old_state=$(jq -S -c "$state" "$committed_file")
publish=true
message="Update waiting feed ($wait_count wait, $review_count review)"
if [[ $new_state == "$old_state" ]]; then
    committed_at=0
    if [[ -n $prev_head ]]; then
        committed_at=$("${git_feed[@]}" log -1 --format=%ct "$prev_head" 2>/dev/null || echo 0)
    fi
    if ((now - committed_at < heartbeat_seconds)); then
        publish=false
    else
        message+=' [heartbeat]'
    fi
fi
if [[ $ok == false ]]; then
    message+=" [ok=false: $err]"
fi

published=no
push_failed=false
if $dry_run; then
    published=dry-run
elif $publish; then
    # A fixed noreply identity and a UTC date, whatever the machine's git config.
    export GIT_AUTHOR_NAME='Adam Daniel' GIT_COMMITTER_NAME='Adam Daniel'
    export GIT_AUTHOR_EMAIL=4205216+Adam-S-Daniel@users.noreply.github.com
    export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    export GIT_AUTHOR_DATE="$now +0000" GIT_COMMITTER_DATE="$now +0000"
    # One parentless commit replaces the branch, so the history holds only the
    # current feed. The lease refuses the push if the remote moved since fetch.
    lease=(--force-with-lease="$feed_branch:$prev_head")
    if blob=$("${git_feed[@]}" hash-object -w -- "$new_feed") &&
        tree=$(printf '100644 blob %s\tfeed.json\n' "$blob" | "${git_feed[@]}" mktree) &&
        new_head=$("${git_feed[@]}" commit-tree "$tree" -m "$message" 2>/dev/null) &&
        timeout 60 "${git_feed[@]}" push --quiet "${lease[@]}" origin "$new_head:refs/heads/$feed_branch" >/dev/null 2>&1; then
        published=yes
    else
        # Nothing local changed, so the next run sees the change again.
        push_failed=true
        published=failed
    fi
fi

line="waiting feed: ok=$ok"
if [[ $ok == false ]]; then
    line+=" error=$err"
fi
line+=" wait=$wait_count review=$review_count published=$published"
rc=0
if [[ $ok == false || $push_failed == true ]]; then
    rc=1
fi
printf '%s\n' "$line"
if [[ $published == yes || $rc -ne 0 ]]; then
    log_line "$line" "$rc"
fi
exit "$rc"
