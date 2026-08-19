#!/usr/bin/env bash
# Feed (workstream) verbs — the agent-hook event pipeline (GAPS: roadmap/08
# item 1). feed.push ingests hook events into the shared WorkstreamStore
# (telemetry + actionable), feed.list snapshots them in the macOS wire
# shape, the reply verbs resolve pending items, and the blocking
# feed.push form waits on the main loop (resolved by a reply, expired on
# timeout). `cmux hooks feed` is the CLI ingest path the opencode plugin
# and agent hooks use.
#
#   feed-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="feed-smoke"
APP_ID_SUFFIX="feedtest"
PAGE_PORT=8436   # unique X display only; no fixture server
source "$(dirname "$0")/lib.sh"

# Hermetic feed: the store loads persisted history at boot (by design),
# so a prior run's JSONL would shift every count below.
rm -f "/tmp/cmux-feedtest-session-feed.jsonl"

start_xvfb
start_instance || exit 2

jfield() { python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

# --- 1: telemetry push (event object form) -------------------------------
resp=$(v2 '{"id":1,"method":"feed.push","params":{"event":{"session_id":"s-tele","hook_event_name":"PreToolUse","_source":"claude","tool_name":"Bash","tool_input":"{\"command\":\"ls\"}","cwd":"/tmp"}}}')
expect "telemetry push acknowledged" "acknowledged" "$(echo "$resp" | jfield "['result']['status']")"

items=$(v2 '{"id":2,"method":"feed.list"}')
expect "list has the telemetry item" "1" "$(echo "$items" | jfield "['result']['items'].__len__()")"
expect "item is telemetry" "telemetry" "$(echo "$items" | jfield "['result']['items'][0]['status']")"
expect "tool name survived" "Bash" "$(echo "$items" | jfield "['result']['items'][0]['tool_name']")"

# --- 2: actionable push (top-level event form), pending filter -----------
resp=$(v2 '{"id":3,"method":"feed.push","params":{"session_id":"s-perm","hook_event_name":"PermissionRequest","_source":"claude","tool_name":"Bash","tool_input":"{\"command\":\"rm\"}","_opencode_request_id":"req-1"}}')
expect "actionable push acknowledged" "acknowledged" "$(echo "$resp" | jfield "['result']['status']")"

pending=$(v2 '{"id":4,"method":"feed.list","params":{"pending_only":true}}')
expect "pending_only filters to the actionable item" "1" "$(echo "$pending" | jfield "['result']['items'].__len__()")"
expect "pending item carries request_id" "req-1" "$(echo "$pending" | jfield "['result']['items'][0]['request_id']")"

# --- 3: reply resolves the pending item ----------------------------------
resp=$(v2 '{"id":5,"method":"feed.permission.reply","params":{"request_id":"req-1","mode":"once"}}')
expect "reply delivered" "True" "$(echo "$resp" | jfield "['result']['delivered']")"
resolved=$(v2 '{"id":6,"method":"feed.list"}' | jfield "['result']['items'][-1]")
expect "item resolved by the reply" "resolved" "$(v2 '{"id":6,"method":"feed.list"}' | jfield "['result']['items'][-1]['status']")"
expect "decision recorded" "once" "$(v2 '{"id":6,"method":"feed.list"}' | jfield "['result']['items'][-1]['decision']['mode']")"

# --- 4: blocking push resolved by a live reply ---------------------------
blockout=/tmp/cmux-feedtest-block.json
( v2 '{"id":7,"method":"feed.push","params":{"session_id":"s-block","hook_event_name":"PermissionRequest","_source":"claude","tool_name":"Edit","tool_input":"{}","_opencode_request_id":"req-2","wait_timeout_seconds":8}}' > "$blockout" ) &
blocker=$!
sleep 1
v2 '{"id":8,"method":"feed.permission.reply","params":{"request_id":"req-2","mode":"deny"}}' >/dev/null
wait "$blocker"
expect "blocking push resolved by reply" "resolved" "$(jfield "['result']['status']" < "$blockout")"
expect "blocking push carries the decision" "deny" "$(jfield "['result']['decision']['mode']" < "$blockout")"

# --- 5: blocking push times out and expires the item ---------------------
resp=$(v2 '{"id":9,"method":"feed.push","params":{"session_id":"s-timeout","hook_event_name":"PermissionRequest","_source":"claude","tool_name":"Edit","tool_input":"{}","_opencode_request_id":"req-3","wait_timeout_seconds":1}}')
expect "unanswered blocking push times out" "timed_out" "$(echo "$resp" | jfield "['result']['status']")"
expect "timed-out item expired" "expired" "$(v2 '{"id":10,"method":"feed.list"}' | jfield "['result']['items'][-1]['status']")"

# --- 6: jump + validation errors -----------------------------------------
ws=$(v2 '{"id":11,"method":"feed.list"}' | jfield "['result']['items'][0]['workstream_id']")
expect "jump matches a known workstream" "True" "$(v2 "{\"id\":12,\"method\":\"feed.jump\",\"params\":{\"workstream_id\":\"$ws\"}}" | jfield "['result']['matched']")"
expect "jump misses an unknown workstream" "False" "$(v2 '{"id":13,"method":"feed.jump","params":{"workstream_id":"nope-1"}}' | jfield "['result']['matched']")"
expect "push without event is invalid_params" "invalid_params" "$(v2 '{"id":14,"method":"feed.push","params":{}}' | jfield "['error']['code']")"
expect "oversized wait timeout rejected" "invalid_params" "$(v2 '{"id":15,"method":"feed.push","params":{"event":{"session_id":"x","hook_event_name":"Stop","_source":"claude"},"wait_timeout_seconds":600}}' | jfield "['error']['code']")"

# --- 7: the CLI ingest path (`cmux hooks feed`) --------------------------
# The hook no-ops outside a cmux pane (no CMUX_SURFACE_ID), so impersonate
# a pane of THIS suite instance — never the human's (cx scrubs on purpose).
before=$(v2 '{"id":16,"method":"feed.list"}' | jfield "['result']['items'].__len__()")
echo '{"session_id":"s-cli","hook_event_name":"UserPromptSubmit","prompt":"hello from the cli"}' \
    | env CMUX_SURFACE_ID=surface:1 CMUX_WORKSPACE_ID=workspace:1 CMUX_QUIET=1 \
        CMUX_SOCKET_PATH="$SOCK" "$CLI" hooks feed --source claude >/dev/null 2>&1
sleep 1
after=$(v2 '{"id":17,"method":"feed.list"}' | jfield "['result']['items'].__len__()")
[ "$after" -gt "$before" ] && ok "hooks feed ingests via the CLI" \
    || bad "hooks feed" "item count did not grow ($before -> $after)"

# --- 7b: source fidelity — kimi must not be relabeled --------------------
# kimi-session bug report 2026-08-18: cmux ships kimi hook support
# (KimiCodeHookConfig) but WorkstreamSource lacked the case, so
# `_source: "kimi"` fell back to claude — landing mislabeled, invisible
# to every source-filtered query (indistinguishable from a drop).
resp=$(v2 '{"id":18,"method":"feed.push","params":{"event":{"session_id":"kimi-src","hook_event_name":"PreToolUse","_source":"kimi","tool_name":"Bash","tool_input":"{}"}}}')
expect "kimi push acknowledged" "acknowledged" "$(echo "$resp" | jfield "['result']['status']")"
expect "kimi source survives (not relabeled)" "kimi" "$(v2 '{"id":19,"method":"feed.list"}' | jfield "['result']['items'][-1]['source']")"

# --- 7c: unknown sources land as "unknown", never as claude --------------
# (olmo-loop desk ask 2, 2026-08-19: an unregistered _source wearing the
# claude identity is an authority inversion; "cmux" is a registered
# source for app/desk-authored events.)
resp=$(v2 '{"id":20,"method":"feed.push","params":{"event":{"session_id":"src-foo","hook_event_name":"Stop","_source":"foobar"}}}')
expect "unknown-source push acknowledged" "acknowledged" "$(echo "$resp" | jfield "['result']['status']")"
expect "unknown source lands as unknown" "unknown" "$(v2 '{"id":21,"method":"feed.list"}' | jfield "['result']['items'][-1]['source']")"
resp=$(v2 '{"id":22,"method":"feed.push","params":{"event":{"session_id":"src-cmux","hook_event_name":"Stop","_source":"cmux"}}}')
expect "cmux is a registered source" "cmux" "$(v2 '{"id":23,"method":"feed.list"}' | jfield "['result']['items'][-1]['source']")"

# --- 7d: socket-typed pane input is tagged in the feed -------------------
# (olmo-loop desk ask 3: agent pane-sends must be distinguishable from
# human typing; metadata only — the typed content itself is never copied.)
before=$(v2 '{"id":24,"method":"feed.list"}' | jfield "['result']['items'].__len__()")
cx send 'echo tagged-input-probe' >/dev/null 2>&1
sleep 1
tagged=$(v2 '{"id":25,"method":"feed.list"}' | python3 -c "
import json,sys
items=[i for i in json.load(sys.stdin)['result']['items'] if i['workstream_id'].startswith('cmux-socket-input')]
print(len(items))")
[ "$tagged" -ge 1 ] && ok "socket-typed input tagged in the feed" \
    || bad "socket-input tagging" "no cmux-socket-input item after a send"
notext=$(v2 '{"id":26,"method":"feed.list"}' | python3 -c "
import json,sys
items=[i for i in json.load(sys.stdin)['result']['items'] if i['workstream_id'].startswith('cmux-socket-input')]
print('leak' if any('tagged-input-probe' in json.dumps(i) for i in items) else 'clean')")
expect "tagged item carries metadata only, not the typed text" "clean" "$notext"

# --- 8: persistence — the JSONL beside the session file ------------------
# Appends hop through the persistence actor; give the async writes a beat.
FEEDLOG="${SESSION%.json}-feed.jsonl"
sleep 1
if [ -f "$FEEDLOG" ]; then
    ok "feed JSONL exists beside the session file"
    lines=$(wc -l < "$FEEDLOG")
    [ "$lines" -ge 8 ] && ok "JSONL holds the ingested items ($lines lines)" \
        || bad "JSONL line count" "expected >= 8, got $lines"
    if python3 -c "
import json,sys
[json.loads(l) for l in open('$FEEDLOG') if l.strip()]
" 2>/dev/null; then
        ok "JSONL lines parse as items"
    else
        bad "JSONL parse" "invalid JSON line in $FEEDLOG"
    fi
else
    bad "feed persistence" "no JSONL at $FEEDLOG"
    bad "JSONL line count" "file missing"
    bad "JSONL parse" "file missing"
fi

rm -f "$blockout"
finish
