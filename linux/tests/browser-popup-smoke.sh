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
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"
APP_ID="com.manaflow.cmux.popuptest"
SOCK="/tmp/cmux-popuptest.sock"
SESSION="/tmp/cmux-popuptest-session.json"
LOG="/tmp/cmux-popuptest.log"
PAGE_PORT=8413
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
cat > "$WORK/index.html" <<'HTML'
<!doctype html><title>opener</title><body>
<a id="lnk" href="/target-link.html" target="_blank">blank link</a>
<button id="btn" onclick="window.open('/target-script.html','_blank')">open</button>
</body>
HTML
echo '<!doctype html><title>popup-target</title><h1>popup</h1>' > "$WORK/target-link.html"
echo '<!doctype html><title>popup-target</title><h1>popup</h1>' > "$WORK/target-script.html"
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
sleep 3

panes() { cx list-panes --workspace "$WS" 2>/dev/null | grep -c 'pane:'; }
# Find the surface whose URL ends in $1 (popup surfaces get fresh refs).
surface_with() {
    for ref in $(cx list-panes --workspace "$WS" 2>/dev/null | grep -oE 'pane:[0-9]+' | sed 's/pane/surface/'); do
        case "$(cx browser --surface "$ref" get-url 2>/dev/null)" in
            *"$1") echo "$ref"; return;;
        esac
    done
}

# --- 1. window.open() lands in a pane.
before=$(panes)
cx browser --surface "$S" click '#btn' >/dev/null 2>&1
sleep 2
after=$(panes)
[ "$after" -gt "$before" ] && ok "window.open routed into a pane ($before → $after)" \
                           || bad "window.open" "pane count stayed $before"

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
before=$(panes)
cx browser --surface "$S" click '#lnk' >/dev/null 2>&1
sleep 2
after=$(panes)
[ "$after" -gt "$before" ] && ok "target=_blank routed into a pane ($before → $after)" \
                           || bad "target=_blank" "pane count stayed $before"
[ -n "$(surface_with 'target-link.html')" ] && ok "target=_blank pane loaded the target URL" \
                                            || bad "target=_blank target" "no surface has target-link.html"

# --- 5. the burst budget holds. Routing popups into panes is friendlier
# than hidden windows, but the popup blocker is off, so a page can ask in a
# loop; the per-opener budget is what stops a page filling the workspace.
before=$(panes)
cx browser --surface "$S" eval 'for(let i=0;i<8;i++){window.open("/target-script.html?"+i,"_blank")}; "fired"' >/dev/null 2>&1
sleep 3
delta=$(( $(panes) - before ))
[ "$delta" -le 5 ] && ok "popup burst capped (8 requested, $delta created)" \
                   || bad "burst limit" "8 requested, $delta created — budget not enforced"

cx close-workspace --workspace "$WS" >/dev/null 2>&1
echo
echo "== browser-popup-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
