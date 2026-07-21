#!/usr/bin/env bash
# Regression test for find-in-page in browser panes (WebKitFindController).
#
#   browser-find-smoke.sh          # 11 assertions, cleans up
#   browser-find-smoke.sh --keep   # leave the instance up for poking
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="browser-find-smoke"
APP_ID_SUFFIX="findtest"
PAGE_PORT=8416
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
# Three "needle"s, exactly one of them uppercase — so case sensitivity is
# distinguishable (3 vs 1) rather than a yes/no.
printf '%s' '<!doctype html><title>find fixture</title><body>
<p>alpha needle one</p><p>beta NEEDLE two</p><p>gamma needle three</p><p>nothing</p>
</body>' > "$WORK/index.html"
start_fixture_server "$WORK"

info "starting isolated cmux"
start_xvfb
start_instance || exit 2

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
finish
