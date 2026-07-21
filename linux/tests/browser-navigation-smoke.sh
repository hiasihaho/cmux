#!/usr/bin/env bash
# Regression test for the navigation barrier (goto/back/forward/reload).
#
# The bug: `browser goto` returned as soon as the load was *requested*, so a
# following eval/wait ran against the PREVIOUS document and reported success
# with data from the wrong page. Measured 2 stale in 12 against a live site.
#
# This suite serves its own fixture with a deliberate server-side delay, so
# the race window is wide and the result does not depend on network luck.
#
#   browser-navigation-smoke.sh          # run all assertions, clean up
#   browser-navigation-smoke.sh --keep   # leave the instance up for poking
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"
APP_ID="com.manaflow.cmux.navtest"
SOCK="/tmp/cmux-navtest.sock"
SESSION="/tmp/cmux-navtest-session.json"
LOG="/tmp/cmux-navtest.log"
PAGE_PORT=8409
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

# Pre-flight: a previous --keep run leaves the port and instance held, which
# would otherwise fail this run for unrelated-looking reasons.
free_port $PAGE_PORT
kill_instance
sleep 0.5

[ -x "$CLI" ] || { echo "missing $CLI — build with: cd linux && CMUX_GHOSTTY=1 swift build" >&2; exit 2; }
[ -x "$APP" ] || { echo "missing $APP" >&2; exit 2; }

# --- fixture: every page waits before responding, widening the race window.
WORK=$(mktemp -d)
cat > "$WORK/server.py" <<'PY'
import sys, time
# Threading matters: the handler stalls on purpose, and a serial server
# would queue the rapid-fire navigations into a backlog that wedges every
# later assertion (which looks exactly like a product bug).
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY = 0.3

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "index"
        time.sleep(DELAY)                      # server-side stall
        body = (
            "<!doctype html><title>%s</title>"
            "<body><h1 id='who'>%s</h1>"
            "<script>window.__page=%r;</script>" % (name, name, name)
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

python3 "$WORK/server.py" $PAGE_PORT >/dev/null 2>&1 &
PAGE_PID=$!
for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$PAGE_PORT/warmup" >/dev/null 2>&1 && break
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
S=$(cx browser open "http://127.0.0.1:$PAGE_PORT/start" --workspace "$WS" | grep -oE 'surface:[0-9]+')
[ -n "$S" ] || { echo "could not open a browser surface" >&2; exit 2; }
sleep 2

page() { cx browser --surface "$S" eval 'window.__page' 2>/dev/null; }

# --- 1. the barrier: goto must never be followed by a stale read.
info "navigation barrier (20 iterations against a 300ms-delayed server)"
stale=0
for i in $(seq 1 20); do
    target="p$i"
    cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/$target" >/dev/null 2>&1
    got=$(page)
    [ "$got" = "$target" ] || { stale=$((stale+1)); echo "    stale: wanted $target got '$got'"; }
done
[ "$stale" = "0" ] && ok "goto → eval never read a stale document (20/20)" \
                   || bad "goto → eval stale reads" "$stale of 20"

# --- 2. discriminating power: the same loop with --no-wait is the OLD
# behavior. Informational only — whether the race actually trips is timing
# dependent, and asserting on it would be a flaky test. If this reports 0
# for a long time, the fixture delay has stopped widening the window and
# assertion 1 has quietly lost its teeth.
nowait_stale=0
for i in $(seq 1 20); do
    target="n$i"
    cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/$target" --no-wait >/dev/null 2>&1
    [ "$(page)" = "$target" ] || nowait_stale=$((nowait_stale+1))
done
echo "  INFO  --no-wait (pre-fix behavior) went stale $nowait_stale/20 — the race this suite guards"

# --- 3. load_state is reported, and reports "finished" for a normal page.
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/ls" >/dev/null 2>&1
state=$(cx --json browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/ls2" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("load_state",""))' 2>/dev/null)
[ "$state" = "finished" ] && ok "goto reports load_state=finished" \
                          || bad "load_state" "expected finished, got '$state'"

# --- 4. --wait-selector chains onto the barrier atomically.
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/sel" --wait-selector '#who' >/dev/null 2>&1
[ "$(page)" = "sel" ] && ok "goto --wait-selector lands on the new document" \
                      || bad "--wait-selector" "page is '$(page)'"

# --- 5. a navigation that cannot commit must error, never report success.
start_ms=$(date +%s%3N)
out=$(cx browser --surface "$S" goto http://10.255.255.1/ --timeout-ms 2000 2>&1)
rc=$?
elapsed=$(( $(date +%s%3N) - start_ms ))
if [ "$rc" != "0" ] && echo "$out" | grep -qi timeout && [ "$elapsed" -lt 8000 ]; then
    ok "unreachable host times out honestly (${elapsed}ms, rc=$rc)"
else
    bad "unreachable host" "rc=$rc elapsed=${elapsed}ms out='$out'"
fi
# and the old page must still be the one reported — no half-navigated limbo
[ "$(page)" = "sel" ] && ok "failed navigation left the previous page intact" \
                      || bad "post-timeout state" "page is '$(page)'"

# --- 6. flags must not be folded into the URL (goto joined all args before).
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/flagtest" --snapshot-after >/dev/null 2>&1
[ "$(page)" = "flagtest" ] && ok "trailing flags are not swallowed into the URL" \
                           || bad "flag/URL parsing" "page is '$(page)'"

# --- 7. history verbs get the same barrier.
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/histA" >/dev/null 2>&1
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/histB" >/dev/null 2>&1
cx browser --surface "$S" back >/dev/null 2>&1
back_page=$(page)
cx browser --surface "$S" forward >/dev/null 2>&1
fwd_page=$(page)
if [ "$back_page" = "histA" ] && [ "$fwd_page" = "histB" ]; then
    ok "back/forward block until their document is live"
else
    bad "history barrier" "back='$back_page' forward='$fwd_page'"
fi

# --- 8. a timeout above the old flat 15s transport cap is honored.
start_ms=$(date +%s%3N)
cx browser --surface "$S" wait --function 'false' --timeout-ms 18000 >/dev/null 2>&1
elapsed=$(( $(date +%s%3N) - start_ms ))
if [ "$elapsed" -gt 16000 ]; then
    ok "timeout_ms above 15s is honored end-to-end (${elapsed}ms)"
else
    bad "transport timeout cap" "wait --timeout-ms 18000 returned after ${elapsed}ms"
fi

cx close-workspace --workspace "$WS" >/dev/null 2>&1
echo
echo "== browser-navigation-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
