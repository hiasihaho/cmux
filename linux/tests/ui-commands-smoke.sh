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

# Raw v2 for verbs the CLI has no subcommand for yet.
v2() {
    python3 - "$SOCK" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode())
data = b""
while not data.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
print(data.decode().strip())
PY
}

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

finish
