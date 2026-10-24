#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
script="$repository_root/scripts/publish-waiting-feed.sh"
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

assert_no_match() {
    [[ ! $1 =~ $2 ]] || fail "$3: '$1' unexpectedly matches '$2'"
    pass
}

# --- Stub curl: serves fixtures by query string and records its argv --------
mkdir -p "$test_root/bin" "$test_root/fx" "$test_root/run" "$test_root/home"
export CURL_ARGV="$test_root/curl-argv"
export FX="$test_root/fx"
export TEST_TOKEN='TESTTOKEN-abc123xyz'
cat >"$test_root/bin/curl" <<'EOF_STUB'
#!/usr/bin/env bash
output=''
headers=''
url=''
printf '%s\n' "$*" >>"$CURL_ARGV"
while (($#)); do
    case "$1" in
        -o) output=$2; shift 2 ;;
        -w) shift 2 ;;
        --max-time) printf '%s\n' "max-time=$2" >>"$CURL_ARGV.flags"; shift 2 ;;
        -H)
            if [[ $2 == @* ]]; then headers=${2#@}; fi
            shift 2
            ;;
        -sS | -q) shift ;;
        --proto) printf '%s\n' "proto=$2" >>"$CURL_ARGV.flags"; shift 2 ;;
        *) url=$1; shift ;;
    esac
done
# The token must reach curl only through the headers file.
if grep -qF "Authorization: Bearer $TEST_TOKEN" "$headers" 2>/dev/null &&
    grep -qF 'x-organization-uuid: org-uuid-test' "$headers" &&
    grep -qF 'anthropic-version: 2023-06-01' "$headers"; then
    printf '%s\n' ok >>"$CURL_ARGV.auth"
fi
[[ ${CURL_FAIL:-0} != 1 ]] || exit 7
query=${url#*\?}
case "$query" in
    *tags=*) fixture=tagged ;;
    *cursor=p2*) fixture=page2 ;;
    *cursor=p3*) fixture=page3 ;;
    *cursor=p4*) fixture=page4 ;;
    *) fixture=page1 ;;
esac
if [[ -n ${CURL_BODY:-} ]]; then
    printf '%s' "$CURL_BODY" >"$output"
else
    cp -- "$FX/$fixture.json" "$output"
fi
printf '%s' "${CURL_STATUS:-200}"
EOF_STUB
chmod +x "$test_root/bin/curl"
export PATH="$test_root/bin:$PATH"

# --- Fixtures -----------------------------------------------------------------
# item ID STATUS BUCKET DAY TAGS_JSON ORIGIN NEEDS_ACTION STATUS_DETAIL
item() {
    jq -nc --arg id "cse_$1" --arg st "$2" --arg b "$3" --arg u "$(printf '2026-10-%02dT10:00:00Z' "$4")" \
        --argjson tags "$5" --arg o "$6" --arg n "$7" --arg d "$8" '{
            id: $id, title: ("SECRETTITLE-" + $id), status: $st, status_bucket: $b,
            tags: $tags, updated_at: $u, unread: true,
            config: (if $o == "" then {} else {origin: $o} end),
            external_metadata: (if $n == "" and $d == "" then {} else
                {post_turn_summary: {needs_action: $n, status_detail: $d}} end)
        }'
}

# page NEXT_CURSOR ITEM... (an empty cursor means the last page)
page() {
    local next=$1
    shift
    printf '%s\n' "$@" | jq -s --arg next "$next" \
        '{data: ., next_cursor: (if $next == "" then null else $next end), resume_token: "r"}'
}

long_ask=$(printf 'x%.0s' {1..500})
a1=$(item a1 active blocked 1 '[]' claude_code_cli 'Approve the plan?' '')
page p2 "$a1" \
    "$(item a2 active review_ready 2 '[]' ios '' 'Review the diff')" \
    "$(item a3 archived blocked 20 '[]' claude_code_cli 'archived' '')" \
    "$(item a4 active blocked 21 '["hearth-overview"]' claude_code_cli 'overview' '')" \
    "$(item a5 active working 22 '[]' claude_code_cli 'working' '')" \
    "$(item a6 active completed 23 '[]' claude_code_cli 'done' '')" \
    "$(jq -c '.id = "cse_../../new?q=x"' <<<"$(item zz active blocked 25 '[]' claude_code_cli 'bad id' '')")" >"$FX/page1.json"
page p3 \
    "$(item b1 active blocked 5 '[]' desktop_app "$long_ask" '')" \
    "$(item b2 active review_ready 3 '[]' web_claude_ai '' '')" \
    "$(item b3 active blocked 4 '[]' '' 'Which one?' '')" \
    "$(item b4 active blocked 6 '[]' claude-in-hearth '' 'Waiting on you')" \
    "$(item b5 active review_ready 11 '[]' android '' '')" >"$FX/page2.json"
# b2 gets a long title with a token in it, b3 an ask with credentials in it.
jq --arg t "SECRETTITLE-cse_b2 ghp_abcdefghijklmnop0123 $(printf 'y%.0s' {1..300})" \
    '(.data[] | select(.id == "cse_b2") | .title) = $t
     | (.data[] | select(.id == "cse_b3") | .external_metadata) =
       {post_turn_summary: {needs_action: "Use sk-ant-api03-ABCDEFGH12345678 and Bearer abcdefghijklmnopqrstuvwxyz0123"}}' \
    "$FX/page2.json" >"$FX/page2.tmp" && mv "$FX/page2.tmp" "$FX/page2.json"
page p4 "$(item c1 active blocked 7 '[]' claude_code_mcp_seed '' '')" >"$FX/page3.json"
page '' "$(item d1 active blocked 24 '[]' claude_code_cli 'past the page limit' '')" >"$FX/page4.json"
page '' \
    "$a1" \
    "$(item a3 archived blocked 20 '["hearth-thread"]' claude_code_cli 'archived' '')" \
    "$(item t1 active blocked 8 '["hearth-thread"]' claude_code_cli 'Thread question' '')" \
    "$(item t2 active review_ready 9 '["cowork-local"]' desktop_app '' 'Cowork review')" \
    "$(item t3 active blocked 10 '["cowork-remote"]' web_claude_ai 'Cowork ask' '')" >"$FX/tagged.json"

# --- Environment ----------------------------------------------------------------
now=1790000000
remote="$test_root/remote.git"
git init --quiet --bare -b main "$remote"
export HOME="$test_root/home"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export XDG_RUNTIME_DIR="$test_root/run"
export WAITING_FEED_CREDENTIALS="$test_root/credentials.json"
export WAITING_FEED_CLAUDE_JSON="$test_root/claude.json"
export WAITING_FEED_API_BASE='https://api.example.com'
export WAITING_FEED_DIR="$test_root/clone"
export WAITING_FEED_URL="file://$remote"
export WAITING_FEED_LOG="$test_root/cache/waiting-feed.log"
export WAITING_FEED_NOW=$now

write_credentials() {
    jq -n --arg t "$TEST_TOKEN" --argjson e "$1" '{claudeAiOauth: {accessToken: $t, expiresAt: $e}}' >"$WAITING_FEED_CREDENTIALS"
}
write_credentials $(((now + 3600) * 1000))
printf '%s\n' '{"oauthAccount":{"organizationUuid":"org-uuid-test"}}' >"$WAITING_FEED_CLAUDE_JSON"

out=''
rc=0
run_feed() {
    rc=0
    # Commit times follow the fixed clock, so the heartbeat age is deterministic.
    out=$(GIT_COMMITTER_DATE="$WAITING_FEED_NOW +0000" bash "$script" "$@" 2>&1) || rc=$?
}
reset_calls() { rm -f -- "$CURL_ARGV" "$CURL_ARGV.auth" "$CURL_ARGV.flags"; }
call_count() { if [[ -f $CURL_ARGV ]]; then wc -l <"$CURL_ARGV" | tr -d ' '; else echo 0; fi; }
log_count() { if [[ -f $WAITING_FEED_LOG ]]; then wc -l <"$WAITING_FEED_LOG" | tr -d ' '; else echo 0; fi; }
commit_count() { git --git-dir="$remote" rev-list --count main 2>/dev/null || echo 0; }
remote_head() { git --git-dir="$remote" rev-parse main 2>/dev/null || echo none; }
remote_feed() { git --git-dir="$remote" show main:feed.json; }
remote_jq() { remote_feed | jq -r "$1"; }

# --- First run: clones the empty remote, filters, maps, publishes ---------------
reset_calls
run_feed
assert_eq "$rc" 0 'first run exits 0'
assert_eq "$out" 'waiting feed: ok=true wait=7 review=4 published=yes' 'first run output is counts only'
assert_eq "$(commit_count)" 1 'first run pushes one commit'
assert_eq "$(remote_jq '.ok')" true 'feed is ok'
assert_eq "$(remote_jq '.error')" null 'feed has no error'
assert_eq "$(remote_jq '.generated_at')" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" 'generated_at is the UTC ISO time'
assert_eq "$(remote_jq 'keys_unsorted | join(",")')" 'generated_at,ok,error,items' 'top-level key order is stable'
assert_eq "$(remote_jq '.items[0] | keys_unsorted | join(",")')" 'id,link,title,bucket,kind,updated_at,ask,unread' 'item key order is stable'

# Newest first, with archived, hearth-overview, working and completed dropped
# and the item present in both the paged and the tagged call listed once.
assert_eq "$(remote_jq '[.items[].id] | join(" ")')" \
    'cse_b5 cse_t3 cse_t2 cse_t1 cse_c1 cse_b4 cse_b1 cse_b3 cse_b2 cse_a2 cse_a1' 'filtered, deduplicated, newest-first ids'
assert_eq "$(remote_jq '[.items[].id] | any(contains("/"))')" false 'an id outside the cse_ form is dropped'
assert_eq "$(remote_jq '[.items[] | select(.id == "cse_a1")] | length')" 1 'duplicate across paged and tagged calls appears once'
assert_eq "$(remote_jq '[.items[].id] | any(. == "cse_d1")')" false 'page 4 is never fetched'
assert_eq "$(remote_jq '.items | map(.bucket) | unique | join(",")')" 'review,wait' 'buckets are wait and review only'
assert_eq "$(remote_jq '.items[] | select(.id == "cse_a1") | .bucket')" wait 'blocked is wait'
assert_eq "$(remote_jq '.items[] | select(.id == "cse_a2") | .bucket')" review 'review_ready is review'

# Link form.
assert_eq "$(remote_jq '.items[] | select(.id == "cse_a1") | .link')" 'https://claude.ai/code/session_a1' 'link replaces the cse_ prefix'

# Kind mapping.
kind_of() { remote_jq ".items[] | select(.id == \"cse_$1\") | .kind"; }
assert_eq "$(kind_of a1)" 'Claude Code' 'claude_code_cli is Claude Code'
assert_eq "$(kind_of c1)" 'Claude Code' 'claude_code_mcp_seed is Claude Code'
assert_eq "$(kind_of b1)" 'Desktop' 'desktop_app is Desktop'
assert_eq "$(kind_of a2)" 'iPhone' 'ios is iPhone'
assert_eq "$(kind_of b5)" 'Android' 'android is Android'
assert_eq "$(kind_of b2)" 'Web' 'web_claude_ai is Web'
assert_eq "$(kind_of b4)" 'Project thread' 'claude-in-hearth is a Project thread'
assert_eq "$(kind_of b3)" 'Session' 'a missing origin is Session'
assert_eq "$(kind_of t1)" 'Project thread' 'the hearth-thread tag beats the origin'
assert_eq "$(kind_of t2)" 'Cowork' 'cowork-local is Cowork'
assert_eq "$(kind_of t3)" 'Cowork' 'cowork-remote is Cowork'

# ask: needs_action, then status_detail, else null; capped at 400 characters.
ask_of() { remote_jq ".items[] | select(.id == \"cse_$1\") | .ask"; }
assert_eq "$(ask_of a1)" 'Approve the plan?' 'needs_action is the ask'
assert_eq "$(ask_of a2)" 'Review the diff' 'status_detail is the fallback when needs_action is empty'
assert_eq "$(ask_of b2)" null 'no summary gives a null ask'
assert_eq "$(ask_of b3)" 'Use sk-ant-[redacted] and Bearer [redacted]' 'credential shapes in the ask are masked'
assert_eq "$(remote_jq '.items[] | select(.id == "cse_b2") | .title | length')" 200 'a long title is capped at 200 characters'
assert_match "$(remote_jq '.items[] | select(.id == "cse_b2") | .title')" '^SECRETTITLE-cse_b2 ghp_\[redacted\] y' 'credential shapes in the title are masked'
assert_no_match "$(remote_feed)" 'ghp_abcdefghijklmnop0123|sk-ant-api03|abcdefghijklmnopqrstuvwxyz0123' 'no credential reaches the feed'
assert_eq "$(remote_jq '.items[] | select(.id == "cse_b1") | .ask | length')" 400 'a long ask is capped at 400 characters'
assert_eq "$(remote_jq '.items[] | select(.id == "cse_a1") | .unread')" true 'unread is carried'

# Pagination stops at three pages, plus one tagged call.
assert_eq "$(call_count)" 4 'three pages plus one tagged call'
assert_match "$(sed -n 1p "$CURL_ARGV")" 'https://api\.example\.com/v1/code/sessions\?limit=100$' 'first call has no cursor'
assert_match "$(sed -n 2p "$CURL_ARGV")" 'limit=100&cursor=p2$' 'second call follows the cursor'
assert_match "$(sed -n 3p "$CURL_ARGV")" 'limit=100&cursor=p3$' 'third call follows the cursor'
assert_match "$(sed -n 4p "$CURL_ARGV")" 'limit=100&tags=hearth-thread&tags=cowork-local&tags=cowork-remote$' 'tagged call repeats tags'
assert_no_match "$(cat "$CURL_ARGV")" 'cursor=p4' 'no fourth page'
assert_eq "$(grep -c '^max-time=' "$CURL_ARGV.flags")" 4 'every call passes --max-time'
assert_eq "$(grep '^max-time=' "$CURL_ARGV.flags" | sort -u)" 'max-time=30' 'the timeout is 30 seconds'
assert_eq "$(grep '^proto=' "$CURL_ARGV.flags" | sort -u)" 'proto==https' 'every call is limited to https'
assert_eq "$(awk '{print $1}' "$CURL_ARGV" | sort -u)" '-q' 'curl ignores ~/.curlrc (-q comes first)'

# The token and the organization travel only in the private headers file.
assert_eq "$(wc -l <"$CURL_ARGV.auth" | tr -d ' ')" 4 'the headers file carried the token, org and version on every call'
assert_no_match "$(cat "$CURL_ARGV")" "$TEST_TOKEN" 'the token never appears in curl argv'
assert_no_match "$(cat "$CURL_ARGV")" 'org-uuid-test' 'the organization never appears in curl argv'
assert_match "$(sed -n 1p "$CURL_ARGV")" '-H @' 'headers are passed as a file'
assert_eq "$(find "$XDG_RUNTIME_DIR" -name request-headers | wc -l | tr -d ' ')" 0 'no headers file is left behind'

# Output and log carry counts only.
assert_no_match "$out" 'SECRETTITLE|cse_|TESTTOKEN' 'output has no titles, ids or tokens'
assert_eq "$(log_count)" 1 'a publishing run is logged'
assert_match "$(sed -n 1p "$WAITING_FEED_LOG")" '^2026-[0-9-]+T[0-9:]+Z exit=0 waiting feed: ok=true wait=7 review=4 published=yes$' 'log line format'
assert_no_match "$(cat "$WAITING_FEED_LOG")" 'SECRETTITLE|cse_|TESTTOKEN' 'log has no titles, ids or tokens'
assert_eq "$(git --git-dir="$remote" log -1 --format=%ae main)" '4205216+Adam-S-Daniel@users.noreply.github.com' 'fallback commit identity'
assert_eq "$(git --git-dir="$remote" log -1 --format=%s main)" 'Update waiting feed (7 wait, 4 review)' 'commit message'

# --- Unchanged within 900 s: nothing happens -------------------------------------
head_before=$(git -C "$WAITING_FEED_DIR" rev-parse HEAD)
remote_before=$(remote_head)
feed_before=$(cat "$WAITING_FEED_DIR/feed.json")
WAITING_FEED_NOW=$((now + 60)) run_feed
assert_eq "$rc" 0 'unchanged run exits 0'
assert_eq "$out" 'waiting feed: ok=true wait=7 review=4 published=no' 'unchanged run output'
assert_eq "$(git -C "$WAITING_FEED_DIR" rev-parse HEAD)" "$head_before" 'no new commit within 900 s'
assert_eq "$(cat "$WAITING_FEED_DIR/feed.json")" "$feed_before" 'working tree untouched within 900 s'
assert_eq "$(git -C "$WAITING_FEED_DIR" status --short)" '' 'clone stays clean'
assert_eq "$(commit_count)" 1 'remote has no new commit'
assert_eq "$(log_count)" 1 'a quiet minute adds no log line'

# --- Unchanged at 900 s: heartbeat -------------------------------------------------
WAITING_FEED_NOW=$((now + 900)) run_feed
assert_eq "$rc" 0 'heartbeat run exits 0'
assert_eq "$out" 'waiting feed: ok=true wait=7 review=4 published=yes' 'heartbeat output'
assert_eq "$(commit_count)" 1 'heartbeat replaces the single commit'
assert_no_match "$(remote_head)" "^$remote_before\$" 'heartbeat commit is pushed'
assert_eq "$(git --git-dir="$remote" log -1 --format=%s main)" 'Update waiting feed (7 wait, 4 review) [heartbeat]' 'heartbeat commit message'
assert_eq "$(remote_jq '.generated_at')" "$(date -u -d "@$((now + 900))" +%Y-%m-%dT%H:%M:%SZ)" 'heartbeat refreshes generated_at'
assert_eq "$(log_count)" 2 'heartbeat is logged'

# --- Changed: a new item produces a commit pushed to the remote -----------------
t=$((now + 1000))
remote_before=$(remote_head)
page p2 "$a1" "$(item a7 active blocked 12 '[]' claude_code_cli 'New ask' '')" >"$FX/page1.json"
WAITING_FEED_NOW=$t run_feed
assert_eq "$out" 'waiting feed: ok=true wait=8 review=3 published=yes' 'changed output'
assert_eq "$(commit_count)" 1 'the remote keeps one commit'
assert_no_match "$(remote_head)" "^$remote_before\$" 'a changed feed is committed and pushed'
assert_eq "$(git --git-dir="$remote" rev-list --max-parents=0 main)" "$(remote_head)" 'the commit has no parent'
assert_eq "$(git -C "$WAITING_FEED_DIR" rev-parse HEAD)" "$(git --git-dir="$remote" rev-parse main)" 'remote head equals the clone head'
assert_eq "$(remote_jq '.items[0].id')" cse_a7 'new item is first'
assert_eq "$(git --git-dir="$remote" log -1 --format=%s main)" 'Update waiting feed (8 wait, 3 review)' 'changed commit message has no heartbeat tag'

# --- --dry-run writes, commits and pushes nothing -------------------------------
page p2 "$a1" >"$FX/page1.json"
dry_before=$(remote_head)
WAITING_FEED_NOW=$((t + 60)) run_feed --dry-run
assert_eq "$rc" 0 'dry run exits 0'
assert_match "$out" 'published=dry-run$' 'dry run output'
assert_eq "$(remote_head)" "$dry_before" 'dry run pushes nothing'
assert_eq "$(git -C "$WAITING_FEED_DIR" status --short)" '' 'dry run leaves the clone clean'
assert_eq "$(log_count)" 3 'dry run is not logged'

# --- Failures keep the previous items and set ok=false ---------------------------
t=$((now + 10000))
prev_ids=$(remote_jq '[.items[].id] | join(" ")')

# Expired token: no HTTP call at all.
write_credentials $((t * 1000))
reset_calls
WAITING_FEED_NOW=$t run_feed
assert_eq "$rc" 1 'expired token exits nonzero'
assert_eq "$out" 'waiting feed: ok=false error=login_expired wait=8 review=3 published=yes' 'expired token output'
assert_eq "$(call_count)" 0 'expired token makes no curl call'
assert_eq "$(remote_jq '.ok')" false 'expired state is published'
assert_eq "$(remote_jq '.error')" login_expired 'expired error code'
assert_eq "$(remote_jq '[.items[].id] | join(" ")')" "$prev_ids" 'expired token keeps the previous items'
assert_match "$(git --git-dir="$remote" log -1 --format=%s main)" '\[ok=false: login_expired\]$' 'failure commit message names the error'
assert_match "$(tail -n 1 "$WAITING_FEED_LOG")" 'exit=1 waiting feed: ok=false error=login_expired ' 'failure is logged with exit 1'

# The same failure again, within 900 s: no new commit, but still nonzero and logged.
commits=$(remote_head)
logs=$(log_count)
WAITING_FEED_NOW=$((t + 60)) run_feed
assert_eq "$rc" 1 'a repeated failure still exits nonzero'
assert_match "$out" 'published=no$' 'a repeated failure is not republished'
assert_eq "$(remote_head)" "$commits" 'a repeated failure adds no commit'
assert_eq "$(log_count)" $((logs + 1)) 'a repeated failure is logged'

# Recovery.
write_credentials $(((t + 3600) * 1000))
WAITING_FEED_NOW=$((t + 120)) run_feed
assert_eq "$rc" 0 'recovery exits 0'
assert_eq "$(remote_jq '.ok')" true 'recovery publishes ok=true'
assert_eq "$(remote_jq '.error')" null 'recovery clears the error'

# Each failure code, with the previous items kept.
write_credentials $(((now + 1000000) * 1000))
t=$((t + 2000))
failure_case() { # expected-error [env assignments...]
    local expected=$1
    shift
    env "$@" WAITING_FEED_NOW=$t GIT_COMMITTER_DATE="$t +0000" bash "$script" >"$test_root/failure.out" 2>&1 && rc=0 || rc=$?
    assert_eq "$rc" 1 "$expected exits nonzero"
    assert_match "$(cat "$test_root/failure.out")" "error=$expected " "$expected in the output line"
    assert_eq "$(remote_jq '.error')" "$expected" "$expected is published"
    assert_eq "$(remote_jq '.ok')" false "$expected sets ok=false"
    assert_eq "$(remote_jq '.items | length')" 10 "$expected keeps the previous items"
    t=$((t + 1000))
}
failure_case login_expired CURL_STATUS=401
failure_case http_500 CURL_STATUS=500
failure_case network CURL_FAIL=1
failure_case bad_response CURL_BODY='not json'
failure_case bad_response 'CURL_BODY={"data":"nope"}'
failure_case no_credentials WAITING_FEED_CREDENTIALS="$test_root/missing.json"

# --- A push that fails exits nonzero and is retried on the next run --------------
t=$((t + 5000))
page p2 "$a1" "$(item a8 active blocked 13 '[]' claude_code_cli 'Another ask' '')" >"$FX/page1.json"
printf '#!/bin/sh\nexit 1\n' >"$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
commits=$(remote_head)
WAITING_FEED_NOW=$t run_feed
assert_eq "$rc" 1 'a failed push exits nonzero'
assert_match "$out" 'published=failed$' 'a failed push is reported'
assert_eq "$(remote_head)" "$commits" 'a failed push adds nothing to the remote'
assert_match "$(tail -n 1 "$WAITING_FEED_LOG")" 'exit=1 .*published=failed$' 'a failed push is logged'
rm -f -- "$remote/hooks/pre-receive"
WAITING_FEED_NOW=$((t + 30)) run_feed
assert_eq "$rc" 0 'the next run publishes the change'
assert_match "$out" 'published=yes$' 'the change is retried'
assert_no_match "$(remote_head)" "^$commits\$" 'the retried change is pushed'
assert_eq "$(commit_count)" 1 'the retried change still leaves one commit'
assert_eq "$(remote_jq '.items[0].id')" cse_a8 'the retried item is in the remote feed'

# --- A clone pointing anywhere else is refused before anything is sent ---------
good_url=$(git -C "$WAITING_FEED_DIR" remote get-url origin)
git -C "$WAITING_FEED_DIR" remote set-url origin "file://$test_root/elsewhere.git"
reset_calls
WAITING_FEED_NOW=$((t + 60)) run_feed
assert_eq "$rc" 1 'a foreign remote exits nonzero'
assert_eq "$out" 'waiting feed: the clone does not point at the feed repository' 'a foreign remote is reported'
assert_eq "$(call_count)" 0 'a foreign remote makes no API call'
git -C "$WAITING_FEED_DIR" remote set-url origin "$good_url"

# --- A commit made on the remote by hand does not wedge later pushes ------------
other="$test_root/other"
git clone --quiet "file://$remote" "$other"
printf '%s\n' 'hand edit' >"$other/NOTE"
git -C "$other" add NOTE
git -C "$other" -c user.name=x -c user.email=x@example.com commit --quiet -m 'hand edit'
git -C "$other" push --quiet origin HEAD:main
t=$((t + 5000))
page p2 "$a1" "$(item a9 active blocked 14 '[]' claude_code_cli 'Yet another' '')" >"$FX/page1.json"
WAITING_FEED_NOW=$t run_feed
assert_eq "$rc" 0 'a run after an outside commit exits 0'
assert_match "$out" 'published=yes$' 'a run after an outside commit publishes'
assert_eq "$(remote_jq '.items[0].id')" cse_a9 'the new feed replaced the outside commit'
assert_eq "$(commit_count)" 1 'history is back to one commit'

# --- The log is trimmed once it grows past its limit ----------------------------
for _ in $(seq 2100); do printf '%s\n' 'old line'; done >"$WAITING_FEED_LOG"
WAITING_FEED_NOW=$((t + 30)) CURL_STATUS=500 run_feed
assert_eq "$rc" 1 'a failure run for the log check exits 1'
assert_eq "$(log_count)" 1000 'the log is cut to its most recent half'
assert_match "$(tail -n 1 "$WAITING_FEED_LOG")" 'error=http_500' 'the newest line is kept'

printf 'PASS: %s assertions\n' "$passed"
