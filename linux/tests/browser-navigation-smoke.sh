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
SUITE_NAME="browser-navigation-smoke"
APP_ID_SUFFIX="navtest"
PAGE_PORT=8409
source "$(dirname "$0")/lib.sh"

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
# A LOCAL tarpit (accepts the TCP connection, never sends a byte), not a
# "reserved" address: 10.255.255.1 is perfectly routable on corporate
# 10/8 networks — learned 2026-07-23 when the dev box joined one and this
# test dialed a real host that answered in 227ms. Accept-and-stay-silent
# makes the timeout deterministic on ANY network.
TARPIT_INFO="/tmp/cmux-navtest-tarpit-$$"
python3 - "$TARPIT_INFO" <<'PYT' &
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
held = []
while True:
    try:
        conn, _ = s.accept()
        held.append(conn)   # keep it open, never respond
    except Exception:
        break
PYT
TARPIT_PID=$!
for _ in $(seq 1 25); do [ -s "$TARPIT_INFO" ] && break; sleep 0.2; done
TARPIT_PORT=$(cat "$TARPIT_INFO" 2>/dev/null)
start_ms=$(date +%s%3N)
out=$(cx browser --surface "$S" goto "http://127.0.0.1:${TARPIT_PORT:-1}/" --timeout-ms 2000 2>&1)
rc=$?
kill "$TARPIT_PID" 2>/dev/null
rm -f "$TARPIT_INFO"
elapsed=$(( $(date +%s%3N) - start_ms ))
if [ "$rc" != "0" ] && echo "$out" | grep -qi timeout && [ "$elapsed" -lt 8000 ]; then
    ok "unreachable host times out honestly (${elapsed}ms, rc=$rc)"
else
    bad "unreachable host" "rc=$rc elapsed=${elapsed}ms out='$out'"
fi
# and the old page must still be the one reported — no half-navigated limbo.
# Poll briefly: with the tarpit the failed load is STOPPED at the timeout
# (the no-route address failed instantly), and an eval issued mid-teardown
# can catch the provisional context for a moment.
post_page=""
for _ in $(seq 1 10); do
    post_page=$(page)
    [ "$post_page" = "sel" ] && break
    sleep 0.5
done
[ "$post_page" = "sel" ] && ok "failed navigation left the previous page intact" \
                         || bad "post-timeout state" "page is '$post_page'"

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

# --- 9. chrome state (MACOS-UX §2.1 parity): the projection behind the
# back/forward sensitivity, the reload⇄stop icon and the https lock.
info "URL-bar chrome state (debug.browser_chrome)"
chrome() { v2 "{\"id\":9,\"method\":\"debug.browser_chrome\",\"params\":{\"surface_id\":\"$1\"}}" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['result'].get('$2'))"; }
# $S carries plenty of history by now, sits on histB after test 7.
expect "history behind -> back enabled" "True" "$(chrome "$S" can_go_back)"
expect "settled load -> reload (not stop)" "False" "$(chrome "$S" is_loading)"
expect "http fixture -> no https lock" "False" "$(chrome "$S" secure)"
cx browser --surface "$S" back >/dev/null 2>&1
expect "after back -> forward enabled" "True" "$(chrome "$S" can_go_forward)"
S2=$(cx browser open "http://127.0.0.1:$PAGE_PORT/fresh" --workspace "$WS" | grep -oE 'surface:[0-9]+')
sleep 2
expect "fresh surface -> back disabled" "False" "$(chrome "$S2" can_go_back)"
expect "fresh surface -> forward disabled" "False" "$(chrome "$S2" can_go_forward)"

cx close-workspace --workspace "$WS" >/dev/null 2>&1
finish
