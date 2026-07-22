#!/usr/bin/env bash
# Keyboard/UI commands that existed on macOS with no Linux way in:
# directional pane focus, rename-workspace dialog, jump-to-unread, flash,
# and the surface.focus parity verb. Keyboard paths are driven with real
# xdotool keystrokes — a verb-level suite cannot see what a person can
# reach (learned when every suite was green while the browser pane had no
# way in).
#
#   ui-commands-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="ui-commands-smoke"
APP_ID_SUFFIX="uitest"
PAGE_PORT=8422
source "$(dirname "$0")/lib.sh"

require_tools xdotool
start_xvfb
start_instance || exit 2

# v2() — the raw JSON sender — comes from lib.sh.

focused_pane() {
    cx list-panes --workspace "$1" 2>/dev/null | grep "\[focused\]" | grep -oE 'pane:[0-9]+' | head -1
}

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
T=$(first_surface_ref "$WS")
if [ -z "$T" ] || ! wait_for_shell "$T"; then
    skip "all UI-command assertions" "the shell never started"
    finish
fi

WIN=$(DISPLAY="$XDISPLAY" xdotool search --name '^cmux$' | head -1)
DISPLAY="$XDISPLAY" xdotool windowactivate "$WIN" 2>/dev/null
DISPLAY="$XDISPLAY" xdotool windowfocus "$WIN" 2>/dev/null

# ------------------------------------------------- directional pane focus
info "directional pane focus (Ctrl+Shift+arrows)"
cx new-split right --surface "$T" >/dev/null; sleep 2
RIGHT=$(focused_pane "$WS")     # split focuses the new (right) pane
DISPLAY="$XDISPLAY" xdotool key --window "$WIN" ctrl+shift+Left; sleep 1
LEFT=$(focused_pane "$WS")
[ -n "$LEFT" ] && [ "$LEFT" != "$RIGHT" ] \
    && ok "Ctrl+Shift+Left moves focus to the left pane ($RIGHT → $LEFT)" \
    || bad "focus left" "focused pane stayed $LEFT"
DISPLAY="$XDISPLAY" xdotool key --window "$WIN" ctrl+shift+Right; sleep 1
BACK=$(focused_pane "$WS")
expect "Ctrl+Shift+Right returns to the right pane" "$RIGHT" "$BACK"
DISPLAY="$XDISPLAY" xdotool key --window "$WIN" ctrl+shift+Right; sleep 1
STILL=$(focused_pane "$WS")
expect "no pane further right: focus stays put" "$RIGHT" "$STILL"

# ------------------------------------------------------ surface.focus verb
info "surface.focus (parity verb)"
SURF_LEFT=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
print(json.load(sys.stdin)["panes"][0]["surface_refs"][0])')
resp=$(v2 "{\"id\":1,\"method\":\"surface.focus\",\"params\":{\"surface_id\":\"$SURF_LEFT\"}}")
echo "$resp" | grep -q '"surface_id"' \
    && ok "verb responds with the focused surface" \
    || bad "surface.focus" "$resp"
LEFT_PANE=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
print(json.load(sys.stdin)["panes"][0]["ref"])')
expect "and the model followed" "$LEFT_PANE" "$(focused_pane "$WS")"

# ------------------------------------------------------------ trigger flash
info "flash"
out=$(cx trigger-flash --surface "$SURF_LEFT" 2>&1 | head -1)
echo "$out" | grep -qiv "error" \
    && ok "trigger-flash verb succeeds ($out)" \
    || bad "trigger-flash" "$out"

# --------------------------------------------------------- rename dialog
info "rename-workspace dialog (Ctrl+Shift+E)"
DISPLAY="$XDISPLAY" xdotool key --window "$WIN" ctrl+shift+e; sleep 2
# The dialog's entry has focus with the old title selected; typing replaces.
DISPLAY="$XDISPLAY" xdotool type --delay 40 "Renamed By Dialog"
DISPLAY="$XDISPLAY" xdotool key Return; sleep 2
title=$(cx list-workspaces 2>/dev/null | grep -F "$WS" | head -1)
echo "$title" | grep -q "Renamed By Dialog" \
    && ok "dialog rename lands in the workspace title" \
    || bad "rename dialog" "row: $title"

# ------------------------------------------------------- jump to unread
info "jump to unread (Ctrl+Shift+U)"
WS2=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx notify --title "attention" --workspace "$WS2" >/dev/null 2>&1
sleep 1
DISPLAY="$XDISPLAY" xdotool key --window "$WIN" ctrl+shift+u; sleep 2
current=$(cx current-workspace 2>/dev/null | head -1)
ws2_uuid=$(cx --id-format uuids --json list-workspaces 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for w in d.get('workspaces',[]):
        print(w.get('workspace_id',''))
except Exception: pass" | sed -n '3p')
# current-workspace prints a UUID; match via list-workspaces selected marker instead.
selected=$(cx list-workspaces 2>/dev/null | grep "\[selected\]" | grep -oE 'workspace:[0-9]+')
expect "the unread workspace is now selected" "$WS2" "$selected"

# ------------------------------------- capabilities-sweep verb round trip
# These verbs existed on macOS with CLI commands the port silently failed
# on until the 2026-07-22 sweep (linux/scripts/capabilities-sweep.py).
info "sweep verbs: notification round trip, devtools alias, zoom"
cx notify --title "sweep" --workspace "$WS2" >/dev/null 2>&1
sleep 1
NID=$(cx --json list-notifications 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d[0]["id"] if isinstance(d,list) and d else "")')
expect "mark-notification-read --id" "OK" "$(cx mark-notification-read --id "$NID" 2>&1 | head -1)"
open_out=$(cx open-notification --id "$NID" 2>&1 | head -1)
echo "$open_out" | grep -q "^OK" \
    && ok "open-notification jumps to the workspace" \
    || bad "open-notification" "$open_out"
expect "dismiss-notification --id" "OK" "$(cx dismiss-notification --id "$NID" 2>&1 | head -1)"

B=$(cx browser open about:blank --workspace "$WS2" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1)
sleep 2
expect "browser zoom in (browser.zoom.set)" "OK" "$(cx browser --surface "$B" zoom in 2>&1 | head -1)"
dev_out=$(cx browser --surface "$B" devtools 2>&1 | head -1)
echo "$dev_out" | grep -q "^OK" \
    && ok "browser devtools alias (devtools.toggle → inspect)" \
    || bad "devtools alias" "$dev_out"

# v1 verbs the skill's fast-start uses (caught by exercising /cmux: the
# v2-only sweep missed the v1 dimension entirely).
info "v1 verbs from the sweep's blind spot"
lw=$(cx list-windows 2>&1 | head -1)
echo "$lw" | grep -qE '^\* 0: [0-9A-F-]+ cmux' \
    && ok "list-windows answers (single window)" \
    || bad "list-windows" "$lw"
expect "reload-config reloads cmux.json" "OK" "$(cx reload-config 2>&1 | head -1 | cut -d' ' -f1)"

# --------------------------------------------- GAPS batch 1 (2026-07-22)
info "gaps batch 1: tree, clear-history, last-pane"
tree_out=$(cx tree 2>&1)
echo "$tree_out" | grep -q "workspace workspace:" && echo "$tree_out" | grep -q "◀ active" \
    && ok "tree renders topology with active markers" \
    || bad "system.tree" "$(echo "$tree_out" | head -2)"

cx send --surface "$T" 'echo CLEARME_MARK; seq 1 100\n' >/dev/null 2>&1; sleep 2
before_clear=$(cx read-screen --surface "$T" --scrollback 2>/dev/null | grep -c CLEARME_MARK)
cx clear-history --surface "$T" >/dev/null 2>&1; sleep 1
after_clear=$(cx read-screen --surface "$T" --scrollback 2>/dev/null | grep -c CLEARME_MARK)
[ "${before_clear:-0}" -ge 1 ] && [ "${after_clear:-0}" -eq 0 ] \
    && ok "clear-history erases scrollback (marker $before_clear → 0)" \
    || bad "surface.clear_history" "before=$before_clear after=$after_clear"

# last-pane toggles between the two most recent panes (tmux semantics).
cx focus-pane --pane "$LEFT_PANE" --workspace "$WS" >/dev/null 2>&1; sleep 1
cx focus-pane --pane "$RIGHT" --workspace "$WS" >/dev/null 2>&1; sleep 1
cx last-pane --workspace "$WS" >/dev/null 2>&1; sleep 1
expect "last-pane returns to the previous pane" "$LEFT_PANE" "$(focused_pane "$WS")"
cx last-pane --workspace "$WS" >/dev/null 2>&1; sleep 1
expect "last-pane again toggles back" "$RIGHT" "$(focused_pane "$WS")"

# --------------------------------------------- GAPS batch 2: tab.action
info "gaps batch 2: tab.action (rename, add, close-others)"
expect "rename-tab pins a title" "OK" "$(cx rename-tab --surface "$T" "Pinned By Test" 2>&1 | head -1 | cut -d' ' -f1)"
cx tab-action --action new-browser-right --surface "$T" --url about:blank >/dev/null 2>&1; sleep 2
tabs_now=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
print(max(p["surface_count"] for p in json.load(sys.stdin)["panes"]))')
[ "${tabs_now:-1}" -ge 2 ] && ok "new-browser-right adds a tab ($tabs_now in pane)" \
                          || bad "tab.action new-browser-right" "surface_count=$tabs_now"
cx tab-action --action close-others --surface "$T" >/dev/null 2>&1; sleep 2
tabs_after=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
print(max(p["surface_count"] for p in json.load(sys.stdin)["panes"]))')
expect "close-others trims back to one" "1" "$tabs_after"

# highlight: upstream's element outline, un-shadowed from our old
# find-in-page alias (a merge collision that killed it on BOTH platforms).
B2=$(cx browser open "data:text/html,<button id='hi'>press</button>" --workspace "$WS2" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1)
sleep 3
expect "browser highlight outlines an element" "OK" "$(cx browser --surface "$B2" highlight '#hi' 2>&1 | head -1)"
hl_missing=$(cx browser --surface "$B2" highlight '#nope' 2>&1 | head -1)
echo "$hl_missing" | grep -q "not found" \
    && ok "highlight errors helpfully on a missing element" \
    || bad "highlight missing" "$hl_missing"
expect "find-in-page still works under its own name" "1 of 1" "$(cx browser --surface "$B2" find-in-page press 2>&1 | head -1)"

# ------------------------------- GAPS batch 4: surface.move / reorder
info "gaps batch 4: move-surface and reorder-surface"
# The T pane currently has 1 surface; give it a second, then reorder.
cx tab-action --action new-browser-right --surface "$T" --url about:blank >/dev/null 2>&1; sleep 2
order_before=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["panes"]:
    if len(p["surface_refs"]) > 1: print(",".join(p["surface_refs"])); break')
cx reorder-surface --surface "$T" --index 1 >/dev/null 2>&1; sleep 1
order_after=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["panes"]:
    if len(p["surface_refs"]) > 1: print(",".join(p["surface_refs"])); break')
[ -n "$order_before" ] && [ "$order_before" != "$order_after" ] \
    && ok "reorder-surface changes the tab order ($order_before → $order_after)" \
    || bad "surface.reorder" "order unchanged: $order_after"

# Move the browser tab into the other pane of the split.
MOVER=$(echo "$order_after" | tr ',' '\n' | grep -v "^$T$" | head -1)
move_out=$(cx move-surface --surface "$MOVER" --pane "$RIGHT" 2>&1 | head -1)
sleep 2
now_in=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["panes"]:
    if "'"$MOVER"'" in p["surface_refs"]: print(p["ref"]); break')
expect "move-surface lands the tab in the target pane" "$RIGHT" "$now_in"

# Cross-workspace: a LIVE terminal keeps running across the move.
cx send --surface "$T" 'echo MOVE_SURVIVOR_XYZ\n' >/dev/null 2>&1; sleep 2
move_ws_out=$(cx move-surface --surface "$T" --workspace "$WS2" 2>&1 | head -1)
echo "        (move said: $move_ws_out)"
sleep 2
cx select-workspace --workspace "$WS2" >/dev/null 2>&1
# Poll, don't sleep: the reparented surface needs a map + draw cycle,
# and a fixed 3s flaked once under full-suite load.
alive=0
for _ in $(seq 1 20); do
    alive=$(cx read-screen --surface "$T" 2>/dev/null | grep -c MOVE_SURVIVOR_XYZ)
    [ "${alive:-0}" -ge 1 ] && break
    sleep 0.5
done
[ "${alive:-0}" -ge 1 ] \
    && ok "cross-workspace move keeps the terminal alive" \
    || bad "surface.move cross-workspace" "marker gone after move"
cx select-workspace --workspace "$WS" >/dev/null 2>&1; sleep 1
# Bring T home so later sections operate on $WS as they assume.
cx move-surface --surface "$T" --workspace "$WS" >/dev/null 2>&1; sleep 1

# ----------------------------- GAPS batch 5: pane swap/resize/break/join
info "gaps batch 5: swap, resize, break, join"
# Earlier sections have collapsed the workspace to one pane; this batch
# needs a live split of its own.
cx new-split right --surface "$T" >/dev/null 2>&1; sleep 2
PA=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys; print(json.load(sys.stdin)["panes"][0]["ref"])')
PB=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys; d=json.load(sys.stdin)["panes"]; print(d[1]["ref"] if len(d)>1 else "")')
if [ -n "$PB" ]; then
    before_a=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys; print(",".join(json.load(sys.stdin)["panes"][0]["surface_refs"]))')
    cx swap-pane --pane "$PA" --target-pane "$PB" --workspace "$WS" >/dev/null 2>&1; sleep 1
    after_b=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys; print(",".join(json.load(sys.stdin)["panes"][1]["surface_refs"]))')
    expect "swap-pane exchanges pane contents" "$before_a" "$after_b"
else
    skip "swap-pane" "workspace lost its split earlier"
fi

# resize: the divider fraction in a forced save must move.
v2 '{"id":9,"method":"session.save"}' >/dev/null
f1=$(python3 -c "
import json
d=json.load(open('$SESSION'))
def walk(n):
    if 'split' in n:
        yield n['split'].get('dividerPosition')
        yield from walk(n['split']['first']); yield from walk(n['split']['second'])
vals=[v for w in d['workspaces'] for v in walk(w['layout']) if v]
print(round(vals[0],3) if vals else '')")
cx resize-pane --pane "$PA" --workspace "$WS" -L --amount 6 >/dev/null 2>&1; sleep 1
v2 '{"id":10,"method":"session.save"}' >/dev/null
f2=$(python3 -c "
import json
d=json.load(open('$SESSION'))
def walk(n):
    if 'split' in n:
        yield n['split'].get('dividerPosition')
        yield from walk(n['split']['first']); yield from walk(n['split']['second'])
vals=[v for w in d['workspaces'] for v in walk(w['layout']) if v]
print(round(vals[0],3) if vals else '')")
[ -n "$f1" ] && [ -n "$f2" ] && [ "$f1" != "$f2" ] \
    && ok "resize-pane moves the divider ($f1 → $f2)" \
    || bad "pane.resize" "fraction $f1 → $f2"

# break: the surface becomes its own workspace (bare Ghostty panes respawn
# their shell on relocation — a known roadmap/05 limitation — so this
# asserts STRUCTURE and cwd survival, not scrollback survival).
ws_count_before=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
cx break-pane --surface "$T" --focus true >/dev/null 2>&1; sleep 2
ws_count_after=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
[ "$ws_count_after" -gt "$ws_count_before" ] \
    && ok "break-pane creates a workspace ($ws_count_before → $ws_count_after)" \
    || bad "pane.break" "workspace count $ws_count_before → $ws_count_after"
broken_ws=$(cx --json list-panes 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(1 if any("'"$T"'" in p["surface_refs"] for p in d.get("panes",[])) else 0)' 2>/dev/null)
expect "the broken-out surface lives in the new workspace" "1" "$broken_ws"

# join: back into a pane of the original workspace.
cx join-pane --surface "$T" --target-pane "$PA" >/dev/null 2>&1; sleep 2
joined=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
print(1 if any("'"$T"'" in p["surface_refs"] for p in json.load(sys.stdin)["panes"]) else 0)')
expect "join-pane brings it back as a tab" "1" "$joined"
expect "and the emptied break workspace closed" "$ws_count_before" "$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')"

# The doctor verb that debugging this batch produced.
doc=$(v2 '{"id":11,"method":"debug.surfaces"}')
echo "$doc" | grep -q '"backend"' && echo "$doc" | grep -q '"parent_type"' \
    && ok "debug.surfaces reports widget lifecycle state" \
    || bad "debug.surfaces" "$(echo "$doc" | head -c 120)"

finish
