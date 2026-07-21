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
SUITE_NAME="session-persistence-smoke"
APP_ID_SUFFIX="sesstest"
PAGE_PORT=8417
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
echo '<!doctype html><title>page A</title><h1>A</h1>' > "$WORK/a.html"
echo '<!doctype html><title>page B</title><h1>B</h1>' > "$WORK/b.html"
cat > "$WORK/index.html" <<HTML
<!doctype html><title>opener</title><body>
<button id="btn" onclick="window.open('/a.html','_blank')">open</button>
</body>
HTML
start_fixture_server "$WORK"


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
start_xvfb
start_instance || exit 2
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
start_instance || exit 2
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
start_instance || exit 2
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

# ------------------------------------------------ capture is not throttled
# A navigation is not a model change, so browser state used to reach disk
# only on the 15s timer: quitting a few seconds after navigating persisted
# the PREVIOUS url. Now a committed load requests a debounced save.
info "navigation is captured without waiting for the session timer"
kill_instance
rm -f "$SESSION"
start_instance || exit 2
WS2=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
S2=$(cx browser open "http://127.0.0.1:$PAGE_PORT/a.html" --workspace "$WS2" | grep -oE 'surface:[0-9]+')
cx select-workspace --workspace "$WS2" >/dev/null
sleep 3
cx browser --surface "$S2" goto "http://127.0.0.1:$PAGE_PORT/b.html" >/dev/null 2>&1
sleep 3                     # well inside the old 15s window
kill_instance
persisted=$(python3 -c "
import json
d=json.load(open('$SESSION'))
urls=[(s.get('browser') or {}).get('url','') for w in d['workspaces'] for s in w['surfaces'] if s['type']=='browser']
print('yes' if any(u.endswith('/b.html') for u in urls) else 'no')" 2>/dev/null)
expect "a navigation is persisted without the 15s timer" "yes" "$persisted"

# ------------------------------------------------------- divider positions
# Stored as a FRACTION, like macOS: a pixel offset restored into a
# differently sized window is simply wrong.
info "divider positions survive a restart"
kill_instance
rm -f "$SESSION"
start_instance || exit 2
WS3=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx browser open "http://127.0.0.1:$PAGE_PORT/a.html" --workspace "$WS3" >/dev/null
cx select-workspace --workspace "$WS3" >/dev/null
sleep 3
BR=$(cx --json list-panes --workspace "$WS3" 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["panes"]; print(p[1]["surface_refs"][0] if len(p)>1 else "")')
width_half=$(cx browser --surface "$BR" eval 'window.innerWidth' 2>/dev/null)
cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # force a save
sleep 2

captured=$(python3 -c "
import json
d=json.load(open('$SESSION'))
def walk(n):
    if 'split' in n:
        yield n['split'].get('dividerPosition')
        yield from walk(n['split']['first']); yield from walk(n['split']['second'])
vals=[v for w in d['workspaces'] for v in walk(w['layout']) if v is not None]
print('yes' if vals else 'no')" 2>/dev/null)
expect "a divider fraction is persisted" "yes" "$captured"

# Move it well off centre and restart: the pane must come back wider.
python3 -c "
import json
d=json.load(open('$SESSION'))
def setdiv(n):
    if 'split' in n:
        n['split']['dividerPosition']=0.25
        setdiv(n['split']['first']); setdiv(n['split']['second'])
for w in d['workspaces']: setdiv(w['layout'])
json.dump(d, open('$SESSION','w'))" 2>/dev/null
kill_instance
start_instance || exit 2
sleep 3
WS3B=$(cx list-workspaces | grep -oE 'workspace:[0-9]+' | sed -n '2p')
cx select-workspace --workspace "$WS3B" >/dev/null
sleep 3
BR2=$(cx --json list-panes --workspace "$WS3B" 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["panes"]; print(p[1]["surface_refs"][0] if len(p)>1 else "")')
width_quarter=$(cx browser --surface "$BR2" eval 'window.innerWidth' 2>/dev/null)
if [ -n "$width_half" ] && [ -n "$width_quarter" ] \
   && [ "$width_quarter" -gt $(( width_half * 5 / 4 )) ]; then
    ok "restored fraction moves the divider (${width_half}px at 0.5 → ${width_quarter}px at 0.25)"
else
    bad "divider restore" "0.5 gave '${width_half}px', 0.25 gave '${width_quarter}px'"
fi

# A v3 file written before dividers were persisted must still load.
python3 -c "
import json
d=json.load(open('$SESSION'))
def strip(n):
    if 'split' in n:
        n['split'].pop('dividerPosition', None)
        strip(n['split']['first']); strip(n['split']['second'])
for w in d['workspaces']: strip(w['layout'])
json.dump(d, open('$SESSION','w'))" 2>/dev/null
kill_instance
start_instance || exit 2
sleep 2
expect "v3 files without dividerPosition still restore" "3" \
    "$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')"

# --------------------------------------------------- terminal cwd tracking
# Ghostty reports the working directory with OSC 7 and validates the host
# against gethostname() first. A stale inherited HOSTNAME (a desktop
# session started before the machine was renamed) makes every report be
# rejected, so panes restore in their spawn directory instead of where the
# user left them. cmux passes the real hostname to the shells it spawns;
# this asserts a `cd` is actually captured.
info "terminal working directory is tracked"
kill_instance
rm -f "$SESSION"
start_instance || exit 2
WS4=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS4" >/dev/null
T4=$(first_surface_ref "$WS4")
if [ -n "$T4" ] && wait_for_shell "$T4"; then
    cx send --surface "$T4" 'cd /etc\n' >/dev/null 2>&1
    sleep 2
    cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # force a save
    sleep 2
    tracked=$(python3 -c "
import json
d=json.load(open('$SESSION'))
dirs=[s['workingDirectory'] for w in d['workspaces'] for s in w['surfaces'] if s['type']=='terminal']
print('yes' if '/etc' in dirs else 'no:' + ','.join(dirs))" 2>/dev/null)
    expect "a cd is captured into the session" "yes" "$tracked"
    # grep -c prints 0 AND exits 1 when there are no matches, so a
    # `|| echo 0` fallback appends a second zero ("0\n0").
    rejects=$(grep -c "must be local" "$LOG" 2>/dev/null)
    rejects=${rejects:-0}
    expect "no OSC 7 host rejections" "0" "$rejects"
else
    skip "terminal cwd assertions" "the shell never started (unmapped window)"
fi

# ------------------------------------------------------ scrollback replay
# A restored pane should show what was on it. Ghostty gets the text via the
# fork's `inject_output` message, so it is parsed as terminal OUTPUT — a
# send_text replay would hand the user's own history to the shell as input.
info "terminal screen text survives a restart"
kill_instance
rm -f "$SESSION"
start_instance || exit 2
WS5=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS5" >/dev/null
T5=$(first_surface_ref "$WS5")
if [ -n "$T5" ] && wait_for_shell "$T5"; then
    cx send --surface "$T5" 'echo SCROLLBACK_MARKER_XYZ\n' >/dev/null 2>&1
    sleep 2
    cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # force a save
    sleep 2
    # Scrollback lives OUTSIDE the session document: that file is
    # rewritten on every model change, so inline text made every line of
    # output rewrite everything (~327KB per save before this).
    sbdir="$(dirname "$SESSION")/scrollback"
    stored=$(grep -l SCROLLBACK_MARKER_XYZ "$sbdir"/*.txt 2>/dev/null | wc -l)
    [ "${stored:-0}" -gt 0 ] && ok "screen text is captured to its own file" \
                             || bad "scrollback capture" "no file under $sbdir holds the marker"
    inline=$(grep -c SCROLLBACK_MARKER_XYZ "$SESSION" 2>/dev/null)
    expect "and NOT inlined into the session json" "0" "${inline:-0}"

    kill_instance
    start_instance || exit 2
    sleep 3
    T5B=$(first_surface_ref "$WS5")
    [ -n "$T5B" ] && wait_for_shell "$T5B" 30
    sleep 2
    replayed=$(cx read-screen --surface "$T5B" 2>/dev/null | grep -c SCROLLBACK_MARKER_XYZ)
    [ "${replayed:-0}" -gt 0 ] \
        && ok "screen text is replayed after a restart ($replayed line(s))" \
        || bad "scrollback replay" "marker not on screen after restart"

    # The replay must not reach the shell as input: if it had, the marker
    # line would have been executed and the shell would echo a command not
    # found, or worse, run whatever was in the history.
    errs=$(cx read-screen --surface "$T5B" 2>/dev/null | grep -ci "command not found")
    expect "replayed text was not executed by the shell" "0" "${errs:-0}"
else
    skip "scrollback assertions" "the shell never started (unmapped window)"
fi

finish
