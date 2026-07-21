#!/usr/bin/env bash
# Regression test for session persistence schema v3.
#
# v2 inlined a surface into each layout leaf, so a pane could only ever
# persist one surface — multi-tab panes came back as sibling panes. v3
# normalizes it the way macOS cmux always has: surfaces in a flat array,
# the layout tree referencing them by id.
#
#   session-persistence-smoke.sh          # run all assertions, clean up
#   session-persistence-smoke.sh --keep   # leave the instance up
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"
APP_ID="com.manaflow.cmux.sesstest"
SOCK="/tmp/cmux-sesstest.sock"
SESSION="/tmp/cmux-sesstest-session.json"
LOG="/tmp/cmux-sesstest.log"
PAGE_PORT=8417
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }
expect() { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }

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
    sleep 1
    return 0
}
start_instance() {
    CMUX_APP_ID=$APP_ID CMUX_SOCKET_PATH=$SOCK CMUX_SESSION_PATH=$SESSION \
        nohup "$APP" >"$LOG" 2>&1 &
    for _ in $(seq 1 40); do
        CMUX_SOCKET_PATH=$SOCK "$CLI" ping >/dev/null 2>&1 && break
        sleep 0.5
    done
}
cleanup() {
    [ "$KEEP" = "1" ] && { echo "== --keep: instance on $SOCK, session $SESSION"; return; }
    [ -n "${PAGE_PID:-}" ] && kill "$PAGE_PID" 2>/dev/null
    free_port $PAGE_PORT
    kill_instance
    rm -f "$SESSION"
}
trap cleanup EXIT

free_port $PAGE_PORT
kill_instance
rm -f "$SESSION"

[ -x "$CLI" ] || { echo "missing $CLI — build with: cd linux && CMUX_GHOSTTY=1 swift build" >&2; exit 2; }
[ -x "$APP" ] || { echo "missing $APP" >&2; exit 2; }

WORK=$(mktemp -d)
echo '<!doctype html><title>page A</title><h1>A</h1>' > "$WORK/a.html"
echo '<!doctype html><title>page B</title><h1>B</h1>' > "$WORK/b.html"
cat > "$WORK/index.html" <<HTML
<!doctype html><title>opener</title><body>
<button id="btn" onclick="window.open('/a.html','_blank')">open</button>
</body>
HTML
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1 && break
    sleep 0.3
done

cx() { env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_SOCKET_PATH=$SOCK "$CLI" "$@"; }

# ---------------------------------------------------------------- v2 migration
# A v2 file must still load: refusing it would silently discard a real
# session, which is the whole reason the legacy decoder is kept.
info "v2 migration"
cat > "$SESSION" <<'JSON'
{
  "version": 2,
  "selectedIndex": 0,
  "tabCounter": 2,
  "workspaces": [
    {
      "title": "legacy one",
      "workingDirectory": "/tmp",
      "focusedLeafIndex": 0,
      "layout": { "leaf": { "kind": "terminal", "workingDirectory": "/tmp", "url": "" } }
    },
    {
      "title": "legacy two",
      "workingDirectory": "/tmp",
      "focusedLeafIndex": 0,
      "layout": { "split": { "orientation": "horizontal",
        "first":  { "leaf": { "kind": "terminal", "workingDirectory": "/tmp", "url": "" } },
        "second": { "leaf": { "kind": "browser", "workingDirectory": "", "url": "http://127.0.0.1:8417/b.html" } } } }
    }
  ]
}
JSON
start_instance
cx ping >/dev/null 2>&1 || { echo "instance did not come up (see $LOG)" >&2; exit 2; }
count=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
expect "v2 session still restores (both workspaces)" "2" "$count"

# Force a save so the file is rewritten in the new format.
cx new-workspace --cwd /tmp --background >/dev/null 2>&1
sleep 2
version=$(python3 -c "import json;print(json.load(open('$SESSION'))['version'])" 2>/dev/null)
expect "file is rewritten as v3" "3" "$version"
shape=$(python3 -c "
import json; w=json.load(open('$SESSION'))['workspaces'][0]
print('ok' if 'surfaces' in w and 'layout' in w else 'missing')" 2>/dev/null)
expect "v3 shape has a flat surfaces array" "ok" "$shape"

# ------------------------------------------------------------ v3 tab round-trip
info "multi-tab pane round-trip"
kill_instance
rm -f "$SESSION"
start_instance
WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
S=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" | grep -oE 'surface:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
sleep 3
cx browser --surface "$S" click '#btn' >/dev/null 2>&1   # popup -> a second tab
sleep 2
# Give the opener real history, so back/forward has something to restore.
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/b.html" >/dev/null 2>&1
sleep 1
# A navigation is not a model change, so nudge one to force a save.
cx new-workspace --cwd /tmp --background >/dev/null 2>&1
sleep 2

tabs_before=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
print(max(p["surface_count"] for p in json.load(sys.stdin)["panes"]))')
[ "$tabs_before" -ge 2 ] && ok "built a tabbed pane to persist ($tabs_before tabs)" \
                         || bad "setup" "expected a tabbed pane, got $tabs_before"

# No captured URL may be empty: a save fires on the model change that adopts
# a popup, before WebKit has committed a URI to the new view, and writing ""
# then makes the tab come back blank forever.
empties=$(python3 -c "
import json; d=json.load(open('$SESSION'))
print(sum(1 for w in d['workspaces'] for s in w['surfaces']
          if s['type']=='browser' and not (s.get('browser') or {}).get('url')))" 2>/dev/null)
expect "no browser surface persisted an empty URL" "0" "$empties"

selected_before=$(python3 -c "
import json; d=json.load(open('$SESSION'))
def panes(n):
    if 'pane' in n: yield n['pane']
    else:
        yield from panes(n['split']['first']); yield from panes(n['split']['second'])
for w in d['workspaces']:
    for p in panes(w['layout']):
        if len(p['surfaceIds'])>1: print(p['selectedId']); raise SystemExit" 2>/dev/null)

kill_instance
start_instance
sleep 3

tabs_after=$(cx --json list-panes --workspace workspace:2 2>/dev/null | python3 -c '
import json,sys
print(max(p["surface_count"] for p in json.load(sys.stdin)["panes"]))' 2>/dev/null)
expect "tabbed pane restores AS TABS, not sibling panes" "$tabs_before" "${tabs_after:-0}"

selected_after=$(cx --id-format uuids --json list-panes --workspace workspace:2 2>/dev/null | python3 -c '
import json,sys
for p in json.load(sys.stdin)["panes"]:
    if p["surface_count"]>1: print(p["selected_surface_id"]); raise SystemExit' 2>/dev/null)
expect "the selected tab is preserved" "$selected_before" "$selected_after"

restored_urls=$(cx --id-format uuids --json list-panes --workspace workspace:2 2>/dev/null | python3 -c '
import json,sys
for p in json.load(sys.stdin)["panes"]:
    if p["surface_count"]>1: print("\n".join(p["surface_ids"])); raise SystemExit' 2>/dev/null \
  | while read -r u; do cx browser --surface "$u" get-url 2>/dev/null; done | grep -c 'http://')
[ "${restored_urls:-0}" -ge 2 ] && ok "every restored tab loaded its URL ($restored_urls)" \
                                || bad "tab URLs" "only $restored_urls tabs have a URL"

# ------------------------------------------------- native back/forward history
# The portable URL list alone cannot make history navigable — macOS emulates
# it with a shadow stack. WebKitGTK can restore its own session blob, so the
# list is real. Restoring must NOT re-load the URL on top of the restored
# list either, or "back" lands on the page you are already looking at.
info "restored history is navigable"
OPENER=$(cx --id-format uuids --json list-panes --workspace workspace:2 2>/dev/null | python3 -c '
import json,sys
for p in json.load(sys.stdin)["panes"]:
    if p["surface_count"]>1: print(p["surface_ids"][0]); raise SystemExit' 2>/dev/null)
before_back=$(cx browser --surface "$OPENER" get-url 2>/dev/null)
cx browser --surface "$OPENER" back >/dev/null 2>&1
sleep 1
after_back=$(cx browser --surface "$OPENER" get-url 2>/dev/null)
[ -n "$after_back" ] && [ "$after_back" != "$before_back" ] \
    && ok "back navigates within the restored history ($after_back)" \
    || bad "restored history" "back did not move (still $after_back)"
cx browser --surface "$OPENER" forward >/dev/null 2>&1
sleep 1
expect "forward returns to the restored entry" "$before_back" "$(cx browser --surface "$OPENER" get-url 2>/dev/null)"

echo
echo "== session-persistence-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
