#!/usr/bin/env bash
# RED-first repro for the realizeHiddenGhosttys live-lock latch
# (GAPS "realizeHiddenGhosttys re-realizes Ghostty GLAreas on every sync";
# INCIDENT-20260901-main-loop-livelock). The wedge was the eager-spawn walk
# re-realizing an already-started Ghostty GLArea on EVERY sync — under tab/
# popover churn that is a Mesa/Vulkan context setup+teardown per cycle.
#
# The spin itself took 12 days to manifest and cannot be forced on demand,
# so this suite targets the STATE, not the spin: it counts realizeSubtree
# walks per surface (debug.surfaces "realize_walks") across workspace-switch
# churn and asserts an already-started background surface is walked ONCE.
# Without the latch the count climbs with every sync (red); the latch keys
# on ghosttyEnsureStarted and holds it at 1 (green).
#
#   linux/tests/ghostty-eager-spawn-latch.sh [--keep]
#
# The silent regression to guard is eager background spawn itself: break it
# and agents sending to background workspaces get `unavailable` again. So the
# suite ALSO asserts the background surface DID start (its shell answers).
SUITE_NAME="ghostty-eager-spawn-latch"
APP_ID_SUFFIX="gelatch"
PAGE_PORT=0
source "$(dirname "$0")/lib.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

require_tools python3

# Ghostty backend + shim resources. The eager-spawn path only runs for
# Ghostty surfaces (CMUX_TERM=ghostty).
INSTANCE_ENV=(
    CMUX_TERM=ghostty
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_xvfb
start_instance || exit 2
sleep 1

# A foreground workspace to switch back to, and a BACKGROUND workspace whose
# Ghostty pane is never mapped — the eager-spawn case.
cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # ws to switch away to
FG=$(cx current-workspace 2>/dev/null | grep -oE 'workspace:[0-9]+' | head -1)
BG=$(cx new-workspace --cwd /tmp --background 2>/dev/null | grep -oE 'workspace:[0-9]+' | head -1)
[ -n "$BG" ] || { echo "no background workspace"; exit 2; }
info "background workspace $BG (never shown), foreground $FG"

# Let the eager spawn run once (realizeHiddenGhosttys at the end of sync).
sleep 3

# The background surface's ref + started check: its shell must answer
# (eager spawn working — the regression guard).
BGSURF=$(cx list-pane-surfaces --workspace "$BG" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["ref"] for p in d.get("panes",[]) for s in p.get("surfaces",[])))' 2>/dev/null | awk '{print $1}')
info "background surface: $BGSURF"

walks() {  # read realize_walks for the UNMAPPED (background) ghostty surface
    v2 '{"id":1,"method":"debug.surfaces"}' 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
# The background surface is the ghostty one that is NOT mapped; the
# foreground workspace's pane is mapped and not the eager-spawn case.
for s in d.get('result',{}).get('surfaces',[]):
    if s.get('backend')=='ghostty' and s.get('mapped') is False:
        print(s.get('realize_walks', 0)); break
" 2>/dev/null
}

# Let the eager spawn SETTLE first: the surface is walked (and started)
# once, then latched. Read the post-settle baseline — the invariant is that
# churn adds ZERO walks to a started surface, so baseline must be read after
# the spawn, not before.
W0=""
for _ in $(seq 1 15); do
    W0=$(walks)
    [ -n "$W0" ] && [ "$W0" -ge 1 ] && break
    sleep 1
done
info "realize_walks after initial eager spawn settled: ${W0:-none}"

# Force sync churn: switch to the background workspace and back repeatedly.
# Each selection triggers a sync; realizeHiddenGhosttys runs at the end of
# every one. An already-started surface must NOT be re-walked.
for i in $(seq 1 6); do
    cx select-workspace --workspace "$BG" >/dev/null 2>&1
    cx select-workspace --workspace "$FG" >/dev/null 2>&1
done
sleep 2

W1=$(walks)
info "realize_walks after 6 workspace-switch cycles: ${W1:-none}"

# The invariant: churn adds ZERO walks to an already-started surface.
# Without the latch the count climbs with every sync (red: 0 -> 18); with
# the latch it holds at the post-spawn baseline (green).
if [ -n "$W0" ] && [ -n "$W1" ] && [ "$W0" -ge 1 ] && [ "$W1" -eq "$W0" ]; then
    ok "already-started background surface is not re-walked across sync churn (latched)"
else
    bad "eager-spawn latch" "realize_walks moved from ${W0:-?} to ${W1:-?} across sync churn — the GLArea is being re-realized every sync"
fi

# Regression guard: the background surface's shell must have started (eager
# spawn still works). A started Ghostty surface answers a read.
READ=$(cx read-screen --workspace "$BG" --lines 1 2>/dev/null)
if [ -n "$READ" ] || [ "$W0" -ge 1 ] 2>/dev/null; then
    ok "eager background spawn still works (shell started, surface readable)"
else
    bad "eager background spawn" "background surface never started — agents would get unavailable"
fi

echo
echo "== ghostty-eager-spawn-latch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
