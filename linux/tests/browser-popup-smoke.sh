#!/usr/bin/env bash
# Regression test for popup routing (window.open / target="_blank").
#
# The bug: with `javascript-can-open-windows-automatically` at its FALSE
# default, WebKit never even emits `create`, so popups silently did nothing
# — no pane, no error, window.open returning null. OAuth flows and
# "open in new tab" links simply dead-ended.
#
#   browser-popup-smoke.sh          # run all assertions, clean up
#   browser-popup-smoke.sh --keep   # leave the instance up for poking
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="browser-popup-smoke"
APP_ID_SUFFIX="popuptest"
PAGE_PORT=8413
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
cat > "$WORK/index.html" <<'HTML'
<!doctype html><title>opener</title><body>
<a id="lnk" href="/target-link.html" target="_blank">blank link</a>
<button id="btn" onclick="window.open('/target-script.html','_blank')">open</button>
</body>
HTML
echo '<!doctype html><title>popup-target</title><h1>popup</h1>' > "$WORK/target-link.html"
echo '<!doctype html><title>popup-target</title><h1>popup</h1>' > "$WORK/target-script.html"
start_fixture_server "$WORK"

info "starting isolated cmux"
start_xvfb
start_instance || exit 2

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
S=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" | grep -oE 'surface:[0-9]+')
[ -n "$S" ] || { echo "could not open a browser surface" >&2; exit 2; }
sleep 3

# Popups are TABS now, not splits: the pane count deliberately stays put
# while the surface count grows. Counting panes here is what the suite used
# to do, and it would now pass vacuously in the wrong direction.
surfaces() {
    cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
print(sum(p["surface_count"] for p in json.load(sys.stdin)["panes"]))'
}
all_surface_refs() {
    cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
print(" ".join(r for p in json.load(sys.stdin)["panes"] for r in p["surface_refs"]))'
}
# Surface refs no longer track pane refs once a pane holds several tabs, so
# ask the protocol for the real list instead of deriving it.
surface_with() {
    for ref in $(all_surface_refs); do
        case "$(cx browser --surface "$ref" get-url 2>/dev/null)" in
            *"$1") echo "$ref"; return;;
        esac
    done
}

# --- 1. window.open() lands in a pane.
before=$(surfaces)
cx browser --surface "$S" click '#btn' >/dev/null 2>&1
sleep 2
after=$(surfaces)
[ "$after" -gt "$before" ] && ok "window.open opened a new surface ($before → $after)" \
                           || bad "window.open" "surface count stayed $before"

# --- 2. that pane really shows the popup target.
script_ref=$(surface_with "target-script.html")
[ -n "$script_ref" ] && ok "window.open pane loaded the target URL ($script_ref)" \
                     || bad "window.open target" "no surface has target-script.html"

# --- 3. window.opener survives (proves the related-view construct property).
if [ -n "$script_ref" ]; then
    opener=$(cx browser --surface "$script_ref" eval 'String(!!window.opener)' 2>/dev/null)
    [ "$opener" = "true" ] && ok "window.opener intact (related-view shared the web process)" \
                           || bad "window.opener" "expected true, got '$opener'"
fi

# --- 4. target="_blank" lands in a pane too (a different code path in WebKit:
# navigation type LINK_CLICKED rather than OTHER).
before=$(surfaces)
cx browser --surface "$S" click '#lnk' >/dev/null 2>&1
sleep 2
after=$(surfaces)
[ "$after" -gt "$before" ] && ok "target=_blank opened a new surface ($before → $after)" \
                           || bad "target=_blank" "surface count stayed $before"
[ -n "$(surface_with 'target-link.html')" ] && ok "target=_blank pane loaded the target URL" \
                                            || bad "target=_blank target" "no surface has target-link.html"

# --- 5. the burst budget holds. Routing popups into panes is friendlier
# than hidden windows, but the popup blocker is off, so a page can ask in a
# loop; the per-opener budget is what stops a page filling the workspace.
before=$(surfaces)
cx browser --surface "$S" eval 'for(let i=0;i<8;i++){window.open("/target-script.html?"+i,"_blank")}; "fired"' >/dev/null 2>&1
sleep 3
delta=$(( $(surfaces) - before ))
[ "$delta" -le 5 ] && ok "popup burst capped (8 requested, $delta created)" \
                   || bad "burst limit" "8 requested, $delta created — budget not enforced"

# The point of routing popups to tabs: the opener's pane must not shrink.
pane_count=$(cx list-panes --workspace "$WS" 2>/dev/null | grep -c 'pane:')
[ "$pane_count" -le 2 ] && ok "popups did NOT add splits (pane count $pane_count)" \
                        || bad "popups still split" "pane count grew to $pane_count"
# Allocations only exist for a mapped workspace; this suite runs in a
# background one, so select it before measuring anything geometric.
cx select-workspace --workspace "$WS" >/dev/null 2>&1
sleep 2
# Measure the pane's VISIBLE surface. The opener is now a background tab,
# and a background tab has no allocation at all (0px) — which is correct
# for tabs and was impossible with splits, where every pane is on screen.
visible=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
panes = json.load(sys.stdin)["panes"]
best = max(panes, key=lambda p: p["surface_count"])
print(best["selected_surface_ref"])')
size=$(cx browser --surface "$visible" eval 'window.innerWidth' 2>/dev/null)
[ "${size:-0}" -gt 300 ] && ok "tabbed pane keeps its full width (${size}px on $visible)" \
                         || bad "pane shrank" "width ${size}px — popups are splitting again"

# --- 6. closing tabs. The risky part of tabbed panes: closing one tab must
# take only that tab, and closing the LAST one must take the pane with it.
# Getting this wrong either strands a pane nothing renders, or drops a whole
# pane (and its siblings' worth of work) because one tab was closed.
tabbed_pane_surfaces() {
    cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
panes = json.load(sys.stdin)["panes"]
best = max(panes, key=lambda p: p["surface_count"])
print(best["surface_count"])'
}
before=$(tabbed_pane_surfaces)
victim=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
panes = json.load(sys.stdin)["panes"]
best = max(panes, key=lambda p: p["surface_count"])
print(best["surface_refs"][-1])')
panes_before=$(cx list-panes --workspace "$WS" 2>/dev/null | grep -c 'pane:')
cx close-surface --surface "$victim" >/dev/null 2>&1
sleep 1
after=$(tabbed_pane_surfaces)
panes_after=$(cx list-panes --workspace "$WS" 2>/dev/null | grep -c 'pane:')
[ "$after" -eq "$((before - 1))" ] && ok "closing one tab removes exactly that tab ($before → $after)" \
                                   || bad "tab close" "surface count $before → $after"
[ "$panes_after" -eq "$panes_before" ] && ok "closing a tab keeps its pane alive" \
                                       || bad "tab close took the pane" "panes $panes_before → $panes_after"

# Close the remaining tabs one by one; the pane must survive until the last.
guard=0
while [ "$(tabbed_pane_surfaces)" -gt 1 ] && [ "$guard" -lt 10 ]; do
    ref=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
panes = json.load(sys.stdin)["panes"]
best = max(panes, key=lambda p: p["surface_count"])
print(best["surface_refs"][-1])')
    cx close-surface --surface "$ref" >/dev/null 2>&1
    sleep 1
    guard=$((guard+1))
done
remaining=$(cx list-panes --workspace "$WS" 2>/dev/null | grep -c 'pane:')
[ "$remaining" -eq "$panes_before" ] && ok "pane survives until its last tab is closed" \
                                     || bad "pane died early" "panes now $remaining, expected $panes_before"

# And the last tab takes the pane.
last=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
panes = json.load(sys.stdin)["panes"]
best = max(panes, key=lambda p: p["surface_count"])
print(best["surface_refs"][0])')
cx close-surface --surface "$last" >/dev/null 2>&1
sleep 1
final=$(cx list-panes --workspace "$WS" 2>/dev/null | grep -c 'pane:')
[ "$final" -lt "$panes_before" ] && ok "closing the last tab closes the pane ($panes_before → $final)" \
                                 || bad "pane leaked" "pane count stayed $final"

cx close-workspace --workspace "$WS" >/dev/null 2>&1
finish
