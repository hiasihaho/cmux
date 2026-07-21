#!/usr/bin/env bash
# Regression test for pane zoom (macOS "Toggle Pane Zoom" / toggleSplitZoom).
#
#   pane-zoom-smoke.sh          # cleans up
#   pane-zoom-smoke.sh --keep   # leave the instance up
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="pane-zoom-smoke"
APP_ID_SUFFIX="zoomtest"
PAGE_PORT=8418
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
echo '<!doctype html><title>zoom fixture</title><h1>zoom</h1>' > "$WORK/index.html"
start_fixture_server "$WORK"

info "starting isolated cmux"
start_xvfb
start_instance || exit 2

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" >/dev/null
cx select-workspace --workspace "$WS" >/dev/null
sleep 3

BR=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["panes"]; print(p[1]["surface_refs"][0] if len(p)>1 else "")')
[ -n "$BR" ] || { echo "$SUITE_NAME: expected a split workspace" >&2; exit 2; }

width() { cx browser --surface "$BR" eval 'window.innerWidth' 2>/dev/null; }

# Zoom is a geometry feature, so the assertions are geometric. A mapped
# window is required for any of it, which is why the suite runs on Xvfb.
before=$(width)
[ "${before:-0}" -gt 0 ] || { skip "all zoom assertions" "pane has no allocation (unmapped window)"; finish; }

out=$(cx zoom-pane --surface "$BR" 2>&1)
sleep 2
zoomed=$(width)
expect "zoom reports zoomed"        "OK zoomed"   "$out"
[ "${zoomed:-0}" -gt $(( before * 3 / 2 )) ] \
    && ok "zoomed pane fills the workspace (${before}px → ${zoomed}px)" \
    || bad "zoom geometry" "${before}px → ${zoomed}px"

out=$(cx zoom-pane --surface "$BR" 2>&1)
sleep 2
expect "second zoom reports unzoomed" "OK unzoomed" "$out"
expect "unzoom restores the split"    "$before"     "$(width)"

# Zooming the OTHER pane while one is zoomed should switch to it, not
# un-zoom — "zoom this one" is the intent, and un-zooming would need a
# second keystroke to get where the user asked to go.
TERM_REF=$(first_surface_ref "$WS")
cx zoom-pane --surface "$BR" >/dev/null 2>&1
out=$(cx zoom-pane --surface "$TERM_REF" 2>&1)
expect "zooming another pane switches instead of un-zooming" "OK zoomed" "$out"
cx zoom-pane --surface "$TERM_REF" >/dev/null 2>&1

# Zoom is momentary state: restoring into it would hide panes the user
# forgot they had.
cx zoom-pane --surface "$BR" >/dev/null 2>&1
cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # force a save
sleep 2
persisted=$(python3 -c "
import json
try: d=json.load(open('$SESSION'))
except Exception: print('unreadable'); raise SystemExit
print('yes' if 'zoom' in json.dumps(d).lower() else 'no')" 2>/dev/null)
expect "zoom is not persisted" "no" "$persisted"

if screenshot "$WORK/zoom.png"; then
    ok "screenshot captured under Xvfb ($(stat -c%s "$WORK/zoom.png" 2>/dev/null) bytes)"
else
    skip "screenshot" "no Xvfb/import available"
fi

cx close-workspace --workspace "$WS" >/dev/null 2>&1
finish
