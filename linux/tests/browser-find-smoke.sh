#!/usr/bin/env bash
# Regression test for find-in-page in browser panes (WebKitFindController).
#
#   browser-find-smoke.sh          # run all assertions, clean up
#   browser-find-smoke.sh --keep   # leave the instance up for poking
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"
APP_ID="com.manaflow.cmux.findtest"
SOCK="/tmp/cmux-findtest.sock"
SESSION="/tmp/cmux-findtest-session.json"
LOG="/tmp/cmux-findtest.log"
PAGE_PORT=8416
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

free_port() {
    local pids
    pids=$(ss -lptnH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    [ -n "$pids" ] && kill $pids 2>/dev/null
    return 0
}
kill_instance() {
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | grep -q "CMUX_APP_ID=$APP_ID" && kill "$pid" 2>/dev/null
    done
    return 0
}
cleanup() {
    [ "$KEEP" = "1" ] && { echo "== --keep: instance on $SOCK, fixture on $PAGE_PORT"; return; }
    [ -n "${PAGE_PID:-}" ] && kill "$PAGE_PID" 2>/dev/null
    free_port $PAGE_PORT
    kill_instance
    rm -f "$SESSION"
}
trap cleanup EXIT

free_port $PAGE_PORT
kill_instance
sleep 0.5

[ -x "$CLI" ] || { echo "missing $CLI — build with: cd linux && CMUX_GHOSTTY=1 swift build" >&2; exit 2; }
[ -x "$APP" ] || { echo "missing $APP" >&2; exit 2; }

WORK=$(mktemp -d)
# Three "needle"s, exactly one of them uppercase — so case sensitivity is
# distinguishable (3 vs 1) rather than a yes/no.
printf '%s' '<!doctype html><title>find fixture</title><body>
<p>alpha needle one</p><p>beta NEEDLE two</p><p>gamma needle three</p><p>nothing</p>
</body>' > "$WORK/index.html"
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1 && break
    sleep 0.3
done

info "starting isolated cmux"
CMUX_APP_ID=$APP_ID CMUX_SOCKET_PATH=$SOCK CMUX_SESSION_PATH=$SESSION \
    nohup "$APP" >"$LOG" 2>&1 &
for _ in $(seq 1 40); do
    CMUX_SOCKET_PATH=$SOCK "$CLI" ping >/dev/null 2>&1 && break
    sleep 0.5
done
cx() { env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_SOCKET_PATH=$SOCK "$CLI" "$@"; }
cx ping >/dev/null 2>&1 || { echo "instance did not come up (see $LOG)" >&2; exit 2; }

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
S=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" | grep -oE 'surface:[0-9]+')
[ -n "$S" ] || { echo "could not open a browser surface" >&2; exit 2; }
cx select-workspace --workspace "$WS" >/dev/null
sleep 3

find() { cx browser --surface "$S" find-in-page "$@" 2>/dev/null; }
expect() { # expect <label> <expected> <actual>
    [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"
}

expect "search reports total match count"        "1 of 3" "$(find needle)"
find --next >/dev/null
expect "next advances the current index"         "3 of 3" "$(find --next)"
expect "next wraps at the end"                   "1 of 3" "$(find --next)"
expect "previous wraps backwards"                "3 of 3" "$(find --previous)"

# The count argument of found-text is the TOTAL only on the initial search
# (it is 1 afterwards), so a naive implementation reads "1 of 1" here.
# Step off the wrap boundary first: from match 3, "next" correctly wraps to
# 1, which would not exercise a mid-sequence advance.
find --next >/dev/null
expect "stepping does not corrupt the total"     "2 of 3" "$(find --next)"

expect "case-sensitive narrows the match set"    "1 of 1" "$(find NEEDLE --case-sensitive)"
expect "case-insensitive by default"             "1 of 3" "$(find NEEDLE)"

# A new search must reset the previous count first; otherwise a caller
# polling on the count returns the OLD query's numbers before the new
# result lands, and a no-match query reports the previous "1 of 3".
expect "no match reports no results"             "No results" "$(find zzznotthere)"
expect "recovers after a failed search"          "1 of 3" "$(find needle)"
expect "clear resets the state"                  "No results" "$(find --clear)"

# Find must not disturb the page itself.
url_before=$(cx browser --surface "$S" get-url 2>/dev/null)
find needle >/dev/null
url_after=$(cx browser --surface "$S" get-url 2>/dev/null)
expect "find does not navigate the page"         "$url_before" "$url_after"

cx close-workspace --workspace "$WS" >/dev/null 2>&1
echo
echo "== browser-find-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
