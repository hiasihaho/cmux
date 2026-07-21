#!/usr/bin/env bash
# End-to-end test for the WebDriver stack (roadmap/06 increments 2–3):
# automation opt-in, attach mode, split adoption, trusted input, and the
# combination of WebDriver + cmux's own verbs on one shared surface.
#
#   linux/tests/webdriver-smoke.sh [--keep]
#
# --keep leaves the instance/driver running for manual poking.
# Exit 0 = all assertions passed, 1 = a failure, 2 = setup problem.
#
# Everything runs on an ISOLATED cmux instance (own app id/socket/session)
# — the human's daily instance is never touched.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/linux/.build/debug/cmux-adw"
CLI="$ROOT/linux/.build/debug/cmux"
APP_ID=com.manaflow.cmux.wdtest
SOCK=/tmp/cmux-wdtest.sock
SESSION_FILE=/tmp/cmux-wdtest-session.json
INSPECTOR=127.0.0.1:5599
WD_PORT=4499
PAGE_PORT=8402
WORK=$(mktemp -d)
KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

cleanup() {
    $KEEP && { echo "--keep: leaving instance ($SOCK) and driver (:$WD_PORT) up"; return; }
    [ -n "${SID:-}" ] && curl -s -m 10 -X DELETE "http://127.0.0.1:$WD_PORT/session/$SID" >/dev/null 2>&1
    pkill -f "WebKitWebDriver --port=$WD_PORT" 2>/dev/null
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
        [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
    done
    [ -n "${PAGE_PID:-}" ] && kill "$PAGE_PID" 2>/dev/null
    free_port $PAGE_PORT 2>/dev/null
    rm -rf "$WORK" "$SOCK" "$SESSION_FILE"
}
trap cleanup EXIT

command -v WebKitWebDriver >/dev/null || { echo "WebKitWebDriver not installed"; exit 2; }
[ -x "$BIN" ] || { echo "build first: cd linux && CMUX_GHOSTTY=1 swift build"; exit 2; }

# Pre-flight: make the run idempotent. A previous --keep run (or a crash)
# can leave the fixture server holding PAGE_PORT, the driver holding
# WD_PORT, or an old test instance alive — any of which silently poisons
# the results (learned the hard way: a stale :8402 made five assertions
# fail for unrelated-looking reasons).
free_port() {
    for pid in $(ss -tlnp 2>/dev/null | awk -v p=":$1\$" '$4 ~ p {match($0,/pid=([0-9]+)/,m); print m[1]}' | sort -u); do
        kill "$pid" 2>/dev/null
    done
}
free_port $PAGE_PORT; free_port $WD_PORT; free_port "${INSPECTOR##*:}"
pkill -f "WebKitWebDriver --port=$WD_PORT" 2>/dev/null
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

# ---------------------------------------------------------------- fixture
cat > "$WORK/app.js" <<'EOF'
document.getElementById('btn').addEventListener('click', e => {
  document.getElementById('out').textContent = 'click isTrusted=' + e.isTrusted;
});
console.log('fixture-loaded');
EOF
cat > "$WORK/index.html" <<'EOF'
<!DOCTYPE html><html><head><title>wd-smoke</title></head><body>
<button id="btn">click me</button><div id="out">none</div>
<script src="app.js"></script></body></html>
EOF
# --directory avoids a wrapper subshell: with `cd X && python3 ... &`
# the recorded $! is the SUBSHELL's pid, so cleanup killed the wrapper and
# orphaned the server (it kept holding PAGE_PORT after the suite).
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
sleep 1

# ------------------------------------------------------------- instance
info "starting isolated cmux (automation + inspector server)"
rm -f "$SOCK" "$SESSION_FILE"
env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
    CMUX_APP_ID=$APP_ID CMUX_SOCKET_PATH=$SOCK CMUX_SESSION_PATH=$SESSION_FILE \
    CMUX_WEBDRIVER=1 WEBKIT_INSPECTOR_SERVER=$INSPECTOR \
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty" \
    setsid nohup "$BIN" >"$WORK/cmux.log" 2>&1 &
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "instance never came up"; sed -n '1,20p' "$WORK/cmux.log"; exit 2; }
sleep 2
cx() { env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_SOCKET_PATH=$SOCK "$CLI" "$@"; }
grep -q 'WebDriver automation ENABLED' "$WORK/cmux.log" \
    && ok "automation opt-in active" || bad "automation opt-in" "banner missing"

PANES_BEFORE=$(cx --json list-panes | python3 -c "import json,sys;print(len(json.load(sys.stdin)['panes']))")

# --------------------------------------------------------------- driver
info "attaching WebKitWebDriver to the running instance"
WebKitWebDriver --port=$WD_PORT --target=$INSPECTOR >"$WORK/wd.log" 2>&1 &
sleep 3
SID=$(curl -s -m 45 -X POST "http://127.0.0.1:$WD_PORT/session" \
      -H 'Content-Type: application/json' -d '{"capabilities":{"alwaysMatch":{}}}' \
      | python3 -c "import json,sys;print(json.load(sys.stdin).get('value',{}).get('sessionId',''))")
[ -n "$SID" ] && ok "attach session created (no browser launch)" \
              || { bad "attach session" "no sessionId"; exit 1; }

wd()      { curl -s -m 25 "http://127.0.0.1:$WD_PORT/session/$SID$1"; }
wd_post() { curl -s -m 25 -X POST "http://127.0.0.1:$WD_PORT/session/$SID$1" \
            -H 'Content-Type: application/json' -d "$2"; }
wd_el()   { wd_post /element "$(python3 -c "import json,sys;print(json.dumps({'using':'css selector','value':sys.argv[1]}))" "$1")" \
            | python3 -c "import json,sys
d=json.load(sys.stdin).get('value')
print(list(d.values())[0] if isinstance(d,dict) else '')"; }
jval()    { python3 -c "import json,sys;print(json.load(sys.stdin).get('value',''))"; }

# WebDriver enforces real-user interactability: clicking a hidden match
# returns "element not interactable" (a synthetic JS click would have
# fired blindly). GitHub ships several hidden copies of its nav links, so
# pick the first DISPLAYED match rather than the first match.
wd_first_displayed() {
    local els el payload
    # Build the payload with json.dumps: selectors legitimately contain
    # double quotes (a[href$="/issues"]), which hand-escaping into a JSON
    # string silently corrupts — the request then matches nothing.
    payload=$(python3 -c "import json,sys;print(json.dumps({'using':'css selector','value':sys.argv[1]}))" "$1")
    els=$(wd_post /elements "$payload" \
          | python3 -c "
import json,sys
for e in (json.load(sys.stdin).get('value') or []): print(list(e.values())[0])")
    for el in $els; do
        if [ "$(wd "/element/$el/displayed" | jval)" = "True" ]; then
            echo "$el"; return
        fi
    done
}

PANES_AFTER=$(cx --json list-panes | python3 -c "import json,sys;print(len(json.load(sys.stdin)['panes']))")
[ "$PANES_AFTER" -gt "$PANES_BEFORE" ] \
    && ok "split adoption: pane count $PANES_BEFORE → $PANES_AFTER" \
    || bad "split adoption" "pane count unchanged ($PANES_BEFORE)"

# the adopted pane is the browser surface
SURF=$(cx --json list-panes | python3 -c "
import json,sys
for p in json.load(sys.stdin)['panes']:
    for r in p.get('surface_refs',[]): print(r)" | tail -1)

# ------------------------------------------------- local fixture assertions
info "local fixture: trusted input + shared surface"
wd_post /url "{\"url\":\"http://127.0.0.1:$PAGE_PORT/index.html\"}" >/dev/null; sleep 2
WD_URL=$(wd /url | jval)
CX_URL=$(cx browser url --surface "$SURF" 2>/dev/null | head -1)
[ "$WD_URL" = "$CX_URL" ] && [ -n "$WD_URL" ] \
    && ok "same surface (driver and cmux both report $WD_URL)" \
    || bad "same surface" "driver='$WD_URL' cmux='$CX_URL'"

EL=$(wd_el '#btn')
wd_post "/element/$EL/click" '{}' >/dev/null; sleep 1
OUT=$(cx browser get text '#out' --surface "$SURF" 2>/dev/null | head -1)
[ "$OUT" = "click isTrusted=true" ] \
    && ok "trusted input (page saw isTrusted=true via WebDriver click)" \
    || bad "trusted input" "got '$OUT'"

CONSOLE=$(cx --json browser console list --surface "$SURF" 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('count',0))")
[ "${CONSOLE:-0}" -ge 1 ] \
    && ok "console capture v2 on the driver-controlled pane ($CONSOLE entries)" \
    || bad "console capture" "no entries"

# ------------------------------------------------------ GitHub (strict CSP)
if curl -s -m 8 -o /dev/null https://github.com; then
    info "github.com: strict CSP + real navigation"
    wd_post /url '{"url":"https://github.com/manaflow-ai/cmux"}' >/dev/null
    # Poll instead of a fixed sleep: GitHub load time varies with the
    # network, and a too-short wait fails assertions for reasons that
    # look like product bugs.
    for _ in $(seq 1 20); do
        [ -n "$(wd_first_displayed 'a[href$="/issues"]')" ] && break
        sleep 1
    done

    SNAP=$(cx browser snapshot --surface "$SURF" 2>/dev/null | head -3)
    echo "$SNAP" | grep -q 'document' \
        && ok "cmux snapshot works on strict-CSP site (isolated-world fallback)" \
        || bad "snapshot on GitHub" "empty/failed"

    BEFORE=$(wd /url | jval)
    ISSUES=$(wd_first_displayed 'a[href$="/issues"]')
    if [ -n "$ISSUES" ]; then
        wd_post "/element/$ISSUES/click" '{}' >/dev/null; sleep 5
        AFTER=$(wd /url | jval)
        case "$AFTER" in
            *"/issues"*)
                if [ "$AFTER" != "$BEFORE" ]; then
                    ok "WebDriver click navigated GitHub ($BEFORE → $AFTER)"
                else
                    bad "GitHub click navigation" "url did not change"
                fi ;;
            *) bad "GitHub click navigation" "url stayed '$AFTER' (was '$BEFORE')" ;;
        esac
        CX_AFTER=$(cx browser url --surface "$SURF" 2>/dev/null | head -1)
        [ "$CX_AFTER" = "$AFTER" ] \
            && ok "cmux sees the driver's navigation on the same pane" \
            || bad "post-navigation surface sync" "driver='$AFTER' cmux='$CX_AFTER'"
    else
        bad "GitHub issues link" "selector found nothing"
    fi
else
    echo "  SKIP  github.com unreachable (offline)"
fi

echo
echo "== webdriver-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
