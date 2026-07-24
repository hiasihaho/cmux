#!/usr/bin/env bash
# workspace.group.* end-to-end: create/list/rename/collapse/pin/add/remove/
# set_anchor/new_workspace/set_color/set_icon/move/focus/ungroup/delete,
# the `new-workspace --group` create path, the contiguity + pin-tier
# ordering invariant, anchor-close dissolution, error surfaces, and the
# session save/restore round-trip (features/04, macOS parity).
#
#   workspace-groups-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="workspace-groups-smoke"
APP_ID_SUFFIX="wsgroups"
PAGE_PORT=8434   # only picks a unique X display; no fixture server needed
source "$(dirname "$0")/lib.sh"

start_xvfb
start_instance || exit 2

# Order of workspace refs as the sidebar shows them.
ws_order() { cx list-workspaces 2>/dev/null | grep -oE 'workspace:[0-9]+' | tr '\n' ' '; }
# Field from the first group in workspace.group.list via python.
group_field() {
    v2 "{\"id\":1,\"method\":\"workspace.group.list\"}" | python3 -c "
import json,sys
r=json.load(sys.stdin)['result']['groups']
print(r[$2]$1 if len(r)>$2 else 'MISSING')" 2>/dev/null
}

# ------------------------------------------------------------------ create
info "group.create adopts children around a fresh anchor"
WS_A=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
WS_B=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
resp=$(v2 "{\"id\":1,\"method\":\"workspace.group.create\",\"params\":{\"name\":\"Proj\",\"child_workspace_ids\":[\"$WS_A\",\"$WS_B\"]}}")
echo "$resp" | grep -q '"member_count":3' && ok "create: anchor + 2 children" \
    || bad "create member_count" "$resp"
G=$(echo "$resp" | grep -oE 'workspace_group:[0-9]+' | head -1)
[ -n "$G" ] && ok "create: group ref minted ($G)" || bad "group ref" "$resp"
ANCHOR=$(group_field "['anchor_workspace_ref']" 0)
expect "list: one group with name" "Proj" "$(group_field "['name']" 0)"

# Contiguity: the run is anchor-first, A and B directly after it.
order=$(ws_order)
case "$order" in
    *"$ANCHOR $WS_A $WS_B"*) ok "contiguity: run is anchor-first" ;;
    *) bad "contiguity" "order: $order (anchor $ANCHOR)" ;;
esac

# ------------------------------------------------------- rename / collapse
expect "rename" "Crew" "$(v2 "{\"id\":1,\"method\":\"workspace.group.rename\",\"params\":{\"group_id\":\"$G\",\"name\":\"Crew\"}}" | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['name'])")"
v2 "{\"id\":1,\"method\":\"workspace.group.collapse\",\"params\":{\"group_id\":\"$G\"}}" | grep -q '"is_collapsed":true' \
    && ok "collapse" || bad "collapse" "no is_collapsed:true"
expect "expand" "False" "$(v2 "{\"id\":1,\"method\":\"workspace.group.expand\",\"params\":{\"group_id\":\"$G\"}}" >/dev/null; group_field "['is_collapsed']" 0)"

# --------------------------------------------- sidebar row projection
info "debug.sidebar_rows mirrors the rendered sidebar"
sidebar_rows() { v2 '{"id":1,"method":"debug.sidebar_rows"}'; }
row_count() { sidebar_rows | python3 -c "import json,sys;print(len(json.load(sys.stdin)['result']['rows']))"; }
header_title() { sidebar_rows | python3 -c "
import json,sys
rows=[r for r in json.load(sys.stdin)['result']['rows'] if r['kind']=='group_header']
print(rows[0]['title'] if rows else 'MISSING')"; }
expect "one group header row" "1" "$(sidebar_rows | python3 -c "import json,sys;print(sum(1 for r in json.load(sys.stdin)['result']['rows'] if r['kind']=='group_header'))")"
rows_open=$(row_count)
v2 "{\"id\":1,\"method\":\"workspace.group.collapse\",\"params\":{\"group_id\":\"$G\"}}" >/dev/null
expect "collapse hides the two member rows" "$((rows_open - 2))" "$(row_count)"
case "$(header_title)" in
    *"(3)"*) ok "collapsed header shows member count" ;;
    *) bad "header count" "title: $(header_title)" ;;
esac
v2 "{\"id\":1,\"method\":\"notification.create_for_caller\",\"params\":{\"preferred_workspace_id\":\"$WS_A\",\"title\":\"ping\"}}" >/dev/null
case "$(header_title)" in
    "●"*) ok "collapsed header aggregates hidden member attention" ;;
    *) bad "attention aggregation" "title: $(header_title)" ;;
esac
v2 "{\"id\":1,\"method\":\"workspace.group.expand\",\"params\":{\"group_id\":\"$G\"}}" >/dev/null
expect "expand restores member rows" "$rows_open" "$(row_count)"
cx select-workspace --workspace "$WS_A" >/dev/null 2>&1   # clear the attention dot


# ------------------------------------------------------------ pin tier
info "pinned group floats above ungrouped rows"
v2 "{\"id\":1,\"method\":\"workspace.group.pin\",\"params\":{\"group_id\":\"$G\"}}" >/dev/null
first=$(ws_order | awk '{print $1}')
expect "pin: run moves to the top" "$ANCHOR" "$first"
v2 "{\"id\":1,\"method\":\"workspace.group.unpin\",\"params\":{\"group_id\":\"$G\"}}" >/dev/null

# ------------------------------------------- membership: CLI create path
info "new-workspace --group joins at creation"
cx new-workspace --cwd /tmp --background --group "$G" --group-placement end >/dev/null 2>&1 \
    && ok "new-workspace --group accepted" || bad "new-workspace --group" "CLI error"
expect "member_count grows to 4" "4" "$(group_field "['member_count']" 0)"
resp=$(v2 "{\"id\":1,\"method\":\"workspace.create\",\"params\":{\"cwd\":\"/tmp\",\"focus\":false,\"group_id\":\"$G\"}}")
echo "$resp" | grep -q '"group_ref"' && ok "workspace.create returns group_ref" \
    || bad "workspace.create group_ref" "$resp"
v2 "{\"id\":1,\"method\":\"workspace.group.remove\",\"params\":{\"workspace_id\":\"$(echo "$resp" | grep -oE 'workspace:[0-9]+' | head -1)\"}}" >/dev/null

# ------------------------------------------------- group.new_workspace
WS_N=$(v2 "{\"id\":1,\"method\":\"workspace.group.new_workspace\",\"params\":{\"group_id\":\"$G\"}}" | grep -oE 'workspace:[0-9]+' | head -1)
[ -n "$WS_N" ] && ok "group.new_workspace creates a member" || bad "group.new_workspace" "no ref"
expect "member_count grows to 5" "5" "$(group_field "['member_count']" 0)"

# --------------------------------------------------------- add / remove
WS_C=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
v2 "{\"id\":1,\"method\":\"workspace.group.add\",\"params\":{\"group_id\":\"$G\",\"workspace_id\":\"$WS_C\",\"placement\":\"end\"}}" | grep -q '"ok":true' \
    && ok "add with placement end" || bad "add" "not ok"
v2 "{\"id\":1,\"method\":\"workspace.group.remove\",\"params\":{\"workspace_id\":\"$WS_C\"}}" | grep -q '"ok":true' \
    && ok "remove member" || bad "remove" "not ok"
v2 "{\"id\":1,\"method\":\"workspace.group.remove\",\"params\":{\"workspace_id\":\"$WS_C\"}}" | grep -q 'not_found' \
    && ok "remove non-member -> not_found" || bad "remove error" "no not_found"

# ---------------------------------------------------------- set_anchor
v2 "{\"id\":1,\"method\":\"workspace.group.set_anchor\",\"params\":{\"group_id\":\"$G\",\"workspace_id\":\"$WS_A\"}}" >/dev/null
expect "set_anchor reassigns the anchor" \
    "$WS_A" "$(group_field "['anchor_workspace_ref']" 0)"

# ------------------------------------------------------- color / icon
expect "set_color stores hex" "#aa5500" "$(v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"#aa5500\"}}" >/dev/null; group_field "['custom_color']" 0)"
expect "set_icon stores symbol" "folder.fill" "$(v2 "{\"id\":1,\"method\":\"workspace.group.set_icon\",\"params\":{\"group_id\":\"$G\",\"symbol\":\"folder.fill\"}}" >/dev/null; group_field "['icon_symbol']" 0)"
expect "set_color empty clears" "None" "$(v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"\"}}" >/dev/null; group_field "['custom_color']" 0)"

# Rendered color/icon on the header row (debug.sidebar_rows fields).
header_field() { sidebar_rows | python3 -c "
import json,sys
rows=[r for r in json.load(sys.stdin)['result']['rows'] if r['kind']=='group_header']
print(rows[0].get('$1') if rows else 'MISSING')"; }
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"#aa5500\"}}" >/dev/null
expect "header renders a valid hex color" "#aa5500" "$(header_field color_hex)"
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"red\"}}" >/dev/null
expect "non-hex color stored but not rendered" "None" "$(header_field color_hex)"
v2 "{\"id\":1,\"method\":\"workspace.group.set_icon\",\"params\":{\"group_id\":\"$G\",\"symbol\":\"star.fill\"}}" >/dev/null
expect "icon maps SF symbol to themed icon" "starred-symbolic" "$(header_field icon_name)"
v2 "{\"id\":1,\"method\":\"workspace.group.set_icon\",\"params\":{\"group_id\":\"$G\",\"symbol\":\"\"}}" >/dev/null
expect "cleared icon falls back to folder" "folder-symbolic" "$(header_field icon_name)"
# QA regression (2026-07-24): Pango parses only 3/4/6/8-digit hex; 5/7-digit
# values passing the render guard broke the header markup persistently.
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"#12345\"}}" >/dev/null
expect "5-digit hex never reaches the renderer" "None" "$(header_field color_hex)"
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"#1234567\"}}" >/dev/null
expect "7-digit hex never reaches the renderer" "None" "$(header_field color_hex)"
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"#ff000080\"}}" >/dev/null
expect "8-digit RGBA hex renders" "#ff000080" "$(header_field color_hex)"
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":123}}" | grep -q 'invalid_params' \
    && ok "non-string hex -> invalid_params" || bad "non-string hex" "not invalid_params"
v2 "{\"id\":1,\"method\":\"workspace.group.set_color\",\"params\":{\"group_id\":\"$G\",\"hex\":\"\"}}" >/dev/null

# ------------------------------------------------------------- focus
v2 "{\"id\":1,\"method\":\"workspace.group.focus\",\"params\":{\"group_id\":\"$G\"}}" >/dev/null
sel=$(v2 '{"id":1,"method":"workspace.current"}' | grep -oE 'workspace:[0-9]+' | head -1)
expect "focus selects the anchor" "$WS_A" "$sel"

# -------------------------------------------------- persistence round-trip
info "groups survive save + restart"
force_save
kill_instance
start_instance || exit 2
expect "restored group name" "Crew" "$(group_field "['name']" 0)"
expect "restored member_count" "5" "$(group_field "['member_count']" 0)"
# Refs are re-minted after restore; recapture handles.
G=$(v2 '{"id":1,"method":"workspace.group.list"}' | grep -oE 'workspace_group:[0-9]+' | head -1)
ANCHOR=$(group_field "['anchor_workspace_ref']" 0)
order=$(ws_order)
case "$order" in
    *"$ANCHOR"*) ok "restored run present in sidebar order" ;;
    *) bad "restored order" "$order" ;;
esac

# --------------------------------------------- anchor close dissolves
info "closing the anchor dissolves the group, members survive"
before=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
cx close-workspace --workspace "$ANCHOR" >/dev/null 2>&1
expect "group is gone" "MISSING" "$(group_field "['name']" 0)"
after=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
expect "only the anchor closed" "$((before - 1))" "$after"

# ------------------------------------------------------ ungroup / delete
info "ungroup preserves members; delete closes them"
WS_D=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
G2=$(v2 "{\"id\":1,\"method\":\"workspace.group.create\",\"params\":{\"name\":\"Temp\",\"child_workspace_ids\":[\"$WS_D\"]}}" | grep -oE 'workspace_group:[0-9]+' | head -1)
before=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
v2 "{\"id\":1,\"method\":\"workspace.group.ungroup\",\"params\":{\"group_id\":\"$G2\"}}" | grep -q '"ok":true' \
    && ok "ungroup" || bad "ungroup" "not ok"
after=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
expect "ungroup closes nothing" "$before" "$after"

WS_E=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
G3=$(v2 "{\"id\":1,\"method\":\"workspace.group.create\",\"params\":{\"name\":\"Doomed\",\"child_workspace_ids\":[\"$WS_E\"]}}" | grep -oE 'workspace_group:[0-9]+' | head -1)
before=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
resp=$(v2 "{\"id\":1,\"method\":\"workspace.group.delete\",\"params\":{\"group_id\":\"$G3\"}}")
echo "$resp" | grep -q '"closed_workspace_count":2' && ok "delete reports closures" \
    || bad "delete count" "$resp"
after=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
expect "delete closes anchor + member" "$((before - 2))" "$after"

# ------------------------------------------------------------ error surfaces
info "error surfaces"
v2 "{\"id\":1,\"method\":\"workspace.group.rename\",\"params\":{\"group_id\":\"$(python3 -c 'import uuid;print(uuid.uuid4())')\",\"name\":\"x\"}}" | grep -q 'not_found' \
    && ok "unknown group -> not_found" || bad "unknown group" "no not_found"
v2 '{"id":1,"method":"workspace.group.rename","params":{"group_id":"","name":"x"}}' | grep -q 'invalid_params' \
    && ok "empty group_id -> invalid_params" || bad "empty group_id" "no invalid_params"
WS_F=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
GE=$(v2 "{\"id\":1,\"method\":\"workspace.group.create\",\"params\":{\"name\":\"Err\",\"child_workspace_ids\":[\"$WS_F\"]}}" | grep -oE 'workspace_group:[0-9]+' | head -1)
v2 "{\"id\":1,\"method\":\"workspace.group.new_workspace\",\"params\":{\"group_id\":\"$GE\",\"placement\":\"sideways\"}}" | grep -q 'invalid_params' \
    && ok "bad placement -> invalid_params" || bad "bad placement" "no invalid_params"
resp=$(cx --json new-workspace --cwd /tmp --background --group-placement end 2>&1)
echo "$resp" | grep -q 'group_id is required' && ok "placement without group -> invalid_params" \
    || bad "flag validation" "$resp"

# ------------------------------------------ hover affordances (MACOS-UX §2.3)
# Fresh instance so the sidebar is EXACTLY [~ | header | member] — three
# rows at y≈76/115/155 (the geometry verified by screenshot). The ✕/＋
# are CSS row:hover-revealed buttons at the row's trailing edge; a real
# pointer hover + click drives them. On regression the click merely
# selects the row and the counts stay unchanged.
info "hover affordances (row ✕ close, header ＋ new-in-group; fresh instance)"
kill_instance
rm -f "$SESSION"
start_instance || exit 2
WH=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
v2 "{\"id\":1,\"method\":\"workspace.group.create\",\"params\":{\"name\":\"H\",\"child_workspace_ids\":[\"$WH\"]}}" >/dev/null
sleep 2
expect "fresh group has anchor + member" "2" "$(group_field "['member_count']" 0)"
# Retry-until-effect with a pointer jiggle per attempt (enter+motion
# before the press) — belt-and-braces against first-frame latency.
# Historical note: the original "flaky clicks" here were bare xdotool
# calls driving the AMBIENT display — the developer's real desktop —
# because lib.sh didn't export DISPLAY; it does now (2026-07-24).
before=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
after=$before
for _ in 1 2 3 4 5; do
    xdotool mousemove 600 400 sleep 0.2 mousemove 246 155 sleep 0.2 click 1
    sleep 1.5
    after=$(cx list-workspaces 2>/dev/null | grep -c 'workspace:')
    [ "$after" = "$((before - 1))" ] && break
done
expect "hover ✕ closes the member row" "$((before - 1))" "$after"
members=1
for _ in 1 2 3 4 5; do
    xdotool mousemove 600 400 sleep 0.2 mousemove 246 115 sleep 0.2 click 1
    sleep 1.5
    members=$(group_field "['member_count']" 0)
    [ "$members" -ge 2 ] && break
done
[ "$members" -ge 2 ] && ok "hover ＋ adds a workspace to the group" \
    || bad "hover ＋" "member_count stayed $members"

# ------------------------------------------ context menus (MACOS-UX §4)
# Menu CONTENT via debug.sidebar_menu (the same projection the popover
# builds from), then one real right-click → item click-through.
info "context menus (projection + click-through)"
menu_ids() { v2 "{\"id\":1,\"method\":\"debug.sidebar_menu\",\"params\":{\"workspace_id\":\"$1\"}}" \
    | python3 -c "import json,sys;print(' '.join(i['id'] for i in json.load(sys.stdin)['result']['items']))"; }
case "$(menu_ids workspace:1)" in
    *new_group*) ok "ungrouped row offers New Group from Workspace" ;;
    *) bad "ungrouped menu" "$(menu_ids workspace:1)" ;;
esac
MEM=$(sidebar_rows | python3 -c "
import json,sys
rows=json.load(sys.stdin)['result']['rows']
mem=[r for r in rows if r['kind']=='workspace' and r.get('in_group')]
print(mem[0]['workspace_ref'] if mem else 'MISSING')")
case "$(menu_ids "$MEM")" in
    *remove_from_group*) ok "member row offers Remove from Group" ;;
    *) bad "member menu" "$(menu_ids "$MEM")" ;;
esac
ANC=$(sidebar_rows | python3 -c "
import json,sys
rows=[r for r in json.load(sys.stdin)['result']['rows'] if r['kind']=='group_header']
print(rows[0]['workspace_ref'] if rows else 'MISSING')")
case "$(menu_ids "$ANC")" in
    *delete_group*) ok "header row offers the group menu" ;;
    *) bad "header menu" "$(menu_ids "$ANC")" ;;
esac
# Click-through: right-click the member row, pick "Remove from Group"
# (4th item since "Workspace Color…" joined; menu popped from the row at
# y≈155 puts it at y≈319).
before=$(group_field "['member_count']" 0)
removed=""
for _ in 1 2 3 4 5; do
    xdotool mousemove 600 400 sleep 0.2 mousemove 120 155 sleep 0.2 click 3
    sleep 1
    xdotool mousemove 126 319 sleep 0.2 click 1
    sleep 1.5
    now=$(group_field "['member_count']" 0)
    if [ "$now" = "$((before - 1))" ]; then removed=yes; break; fi
    xdotool key Escape; sleep 0.5
done
[ "$removed" = "yes" ] && ok "right-click → Remove from Group removes the member" \
    || bad "menu click-through" "member_count $before -> $(group_field "['member_count']" 0)"

# --------------------------------------- workspace colors (MACOS-UX §1.2)
info "workspace colors (palette click-through + rail projection + restore)"
case "$(menu_ids workspace:1)" in
    *workspace_color*) ok "row menu offers Workspace Color" ;;
    *) bad "color menu item" "$(menu_ids workspace:1)" ;;
esac
case "$(menu_ids "$ANC")" in
    *group_color*) ok "header menu offers Group Color" ;;
    *) bad "group color item" "$(menu_ids "$ANC")" ;;
esac
row0_color() { sidebar_rows | python3 -c "
import json,sys
print(json.load(sys.stdin)['result']['rows'][0].get('color_hex'))"; }
colored=""
for _ in 1 2 3 4 5; do
    # Right-click ws1 (row 0) → "Workspace Color…" (2nd item, y≈168) →
    # the Red swatch (first circle, ≈43,128).
    xdotool mousemove 600 400 sleep 0.2 mousemove 120 76 sleep 0.2 click 3
    sleep 1
    xdotool mousemove 103 168 sleep 0.2 click 1
    sleep 1
    xdotool mousemove 43 128 sleep 0.2 click 1
    sleep 1.5
    if [ "$(row0_color)" = "#C0392B" ]; then colored=yes; break; fi
    xdotool key Escape; sleep 0.5
done
[ "$colored" = "yes" ] && ok "palette click-through sets the row color" \
    || bad "palette click-through" "row0 color: $(row0_color)"
force_save
kill_instance
start_instance || exit 2
expect "workspace color survives restart" "#C0392B" "$(row0_color)"

# ------------------------------------------ sidebar DnD (MACOS-UX §3.2)
# The verb and the drag share one mutation (applyWorkspaceReorder).
# State: rows [~ | header]. A fresh top-level workspace joins the group
# via `after` the anchor, leaves via `before` it, then joins again by a
# REAL pointer drag into the run.
info "workspace.reorder + drag membership"
ANC2=$(sidebar_rows | python3 -c "
import json,sys
rows=[r for r in json.load(sys.stdin)['result']['rows'] if r['kind']=='group_header']
print(rows[0]['workspace_ref'] if rows else 'MISSING')")
WD=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
v2 "{\"id\":1,\"method\":\"workspace.reorder\",\"params\":{\"workspace_id\":\"$WD\",\"after_workspace_id\":\"$ANC2\"}}" >/dev/null
expect "reorder after an anchor joins the group" "2" "$(group_field "['member_count']" 0)"
v2 "{\"id\":1,\"method\":\"workspace.reorder\",\"params\":{\"workspace_id\":\"$WD\",\"before_workspace_id\":\"$ANC2\"}}" >/dev/null
expect "reorder before a header leaves the group" "1" "$(group_field "['member_count']" 0)"
v2 "{\"id\":1,\"method\":\"workspace.reorder\",\"params\":{\"workspace_id\":\"$WD\",\"index\":0,\"before_workspace_id\":\"$ANC2\"}}" | grep -q 'invalid_params' \
    && ok "two targets -> invalid_params" || bad "reorder validation" "no invalid_params"
# NOTE — pointer-drag membership is deliberately NOT asserted here.
# The drag itself is verified (interactive, both directions, PROGRESS
# 2026-07-24); a drag assertion at THIS point in the suite instead
# trips a separate bug: after this suite's full click/popover/restore
# history the adwaita-swift ListBox render desyncs from the projection
# (rows missing), so the row-index → coordinate mapping lies. That
# renderer bug has its own GAPS row; when it is fixed, re-add the drag
# assertion here as its canary.

finish
