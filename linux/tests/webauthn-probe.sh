#!/usr/bin/env bash
# P0 probe for passkeys (docs/linux-port/PASSKEYS.md §7 step 0):
# does WebKitGTK's compiled-in WebAuthn light up inside a WebDriver
# automation session via the W3C virtual-authenticator endpoints?
#
#   linux/tests/webauthn-probe.sh [--keep]
#
# This is an EVIDENCE PROBE, not a gate: a negative finding is a valid
# result. Exit 0 = probe ran and printed a VERDICT line (CONFIRMED or
# REFUTED), 2 = setup problem. Promote to a real suite only if the
# feature path it probes becomes product behavior.
#
# Runs on an ISOLATED instance (own app id/socket/session/display);
# the human's daily instance is never touched.
SUITE_NAME="webauthn-probe"
APP_ID_SUFFIX="watest"
PAGE_PORT=8443
INSPECTOR=127.0.0.1:5597
WD_PORT=4497
source "$(dirname "$0")/lib.sh"

suite_cleanup() {
    [ -n "${SID:-}" ] && curl -s -m 10 -X DELETE "http://127.0.0.1:$WD_PORT/session/$SID" >/dev/null 2>&1
    [ -n "${WD_PID:-}" ] && kill "$WD_PID" 2>/dev/null
    free_port "$WD_PORT"
    free_port "${INSPECTOR##*:}"
}
free_port() {
    for pid in $(ss -tlnp 2>/dev/null | awk -v p=":$1\$" '$4 ~ p {match($0,/pid=([0-9]+)/,m); print m[1]}' | sort -u); do
        kill "$pid" 2>/dev/null
    done
}
free_port "$WD_PORT"
free_port "${INSPECTOR##*:}"
require_tools WebKitWebDriver

WORK=$(mktemp -d)
KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
note() { echo "  NOTE  $1"; }
info() { echo "== $1"; }

# Pre-flight: idempotency (same lessons as webdriver-smoke).
pkill -f "WebKitWebDriver --port=$WD_PORT" 2>/dev/null
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

# ---------------------------------------------------------------- fixture
# Served on http://localhost (secure context; rpId must be a domain, so
# "localhost", never 127.0.0.1). Ceremonies run from a real click so a
# trusted-activation gate cannot mask the finding.
cat > "$WORK/app.js" <<'EOF'
const log = m => { document.getElementById('out').textContent = m; };
document.getElementById('create').addEventListener('click', async () => {
  log('creating');
  try {
    const cred = await navigator.credentials.create({ publicKey: {
      challenge: new Uint8Array(32),
      rp: { id: 'localhost', name: 'wa-probe' },
      user: { id: new Uint8Array(16).fill(7), name: 'probe@example.com', displayName: 'Probe' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
      timeout: 15000,
      attestation: 'none'
    }});
    window.__credId = new Uint8Array(cred.rawId);
    log('created:' + cred.id.slice(0, 12));
  } catch (e) { log('create-error:' + e.name + ':' + e.message); }
});
document.getElementById('get').addEventListener('click', async () => {
  log('getting');
  try {
    const assertion = await navigator.credentials.get({ publicKey: {
      challenge: new Uint8Array(32).fill(1),
      rpId: 'localhost',
      userVerification: 'required',
      timeout: 15000
    }});
    log('asserted:' + assertion.id.slice(0, 12));
  } catch (e) { log('get-error:' + e.name + ':' + e.message); }
});
EOF
cat > "$WORK/index.html" <<'EOF'
<!DOCTYPE html><html><head><title>wa-probe</title></head><body>
<button id="create">create</button> <button id="get">get</button>
<div id="out">none</div>
<script src="app.js"></script></body></html>
EOF
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
sleep 1

# ------------------------------------------------------------- instance
info "starting isolated cmux (automation + inspector server)"
INSTANCE_ENV=(
    CMUX_WEBDRIVER=1
    WEBKIT_INSPECTOR_SERVER=$INSPECTOR
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_xvfb
start_instance || exit 2
sleep 2
grep -q 'WebDriver automation ENABLED' "$LOG" \
    && ok "automation opt-in active" || { bad "automation opt-in" "banner missing"; exit 2; }

# --------------------------------------------------------------- driver
info "attaching WebKitWebDriver"
WebKitWebDriver --port=$WD_PORT --target=$INSPECTOR >"$WORK/wd.log" 2>&1 &
WD_PID=$!
sleep 3
SID=$(curl -s -m 45 -X POST "http://127.0.0.1:$WD_PORT/session" \
      -H 'Content-Type: application/json' -d '{"capabilities":{"alwaysMatch":{}}}' \
      | python3 -c "import json,sys;print(json.load(sys.stdin).get('value',{}).get('sessionId',''))")
[ -n "$SID" ] && ok "attach session created" || { bad "attach session" "no sessionId"; exit 2; }

wd()      { curl -s -m 25 "http://127.0.0.1:$WD_PORT/session/$SID$1"; }
wd_post() { curl -s -m 25 -X POST "http://127.0.0.1:$WD_PORT/session/$SID$1" \
            -H 'Content-Type: application/json' -d "$2"; }
jval()    { python3 -c "import json,sys;print(json.load(sys.stdin).get('value',''))"; }
wd_exec() { wd_post /execute/sync "$(python3 -c "import json,sys;print(json.dumps({'script':sys.argv[1],'args':[]}))" "$1")" | jval; }
wd_el()   { wd_post /element "$(python3 -c "import json,sys;print(json.dumps({'using':'css selector','value':sys.argv[1]}))" "$1")" \
            | python3 -c "import json,sys
d=json.load(sys.stdin).get('value')
print(list(d.values())[0] if isinstance(d,dict) else '')"; }

SURF=$(cx --json list-panes | python3 -c "
import json,sys
for p in json.load(sys.stdin)['panes']:
    for r in p.get('surface_refs',[]): print(r)" | tail -1)

wd_post /url "{\"url\":\"http://localhost:$PAGE_PORT/index.html\"}" >/dev/null; sleep 2

# ------------------------------------------------- probe 1: baseline API
info "probe 1: API surface before any virtual authenticator"
BASE=$(wd_exec "return typeof navigator.credentials + '/' + typeof window.PublicKeyCredential")
note "baseline: $BASE"

# ------------------------------------- probe 2: add virtual authenticator
info "probe 2: W3C virtual-authenticator endpoint"
AUTH_RESP=$(wd_post /webauthn/authenticator \
  '{"protocol":"ctap2","transport":"internal","hasResidentKey":true,"hasUserVerification":true,"isUserVerified":true,"automaticPresenceSimulation":true}')
note "add-authenticator response: $AUTH_RESP"
AUTH_ID=$(echo "$AUTH_RESP" | python3 -c "
import json,sys
v=json.load(sys.stdin).get('value')
print(v if isinstance(v,str) else '')")
if [ -n "$AUTH_ID" ]; then
    ok "virtual authenticator added (id=$AUTH_ID)"
else
    bad "virtual authenticator" "endpoint refused (see response above)"
fi

# ---------------------------------------------- probe 3: API after reload
info "probe 3: API surface after adding authenticator (fresh load)"
wd_post /url "{\"url\":\"http://localhost:$PAGE_PORT/index.html\"}" >/dev/null; sleep 2
AFTER=$(wd_exec "return typeof navigator.credentials + '/' + typeof window.PublicKeyCredential")
note "after: $AFTER"
case "$AFTER" in
    *object*function*) ok "navigator.credentials + PublicKeyCredential exposed" ;;
    *) bad "API exposure" "still '$AFTER'" ;;
esac

# ------------------------------------------ probe 4: ceremonies (trusted)
poll_out() {  # poll #out until it leaves the pending state or times out
    local pending="$1" i out
    for i in $(seq 1 20); do
        out=$(cx browser get text '#out' --surface "$SURF" 2>/dev/null | head -1)
        [ -n "$out" ] && [ "$out" != "none" ] && [ "$out" != "$pending" ] && { echo "$out"; return; }
        sleep 1
    done
    echo "$out"
}
if [ -n "$AUTH_ID" ]; then
    info "probe 4: create() ceremony via trusted click"
    EL=$(wd_el '#create')
    wd_post "/element/$EL/click" '{}' >/dev/null
    OUT=$(poll_out 'creating')
    note "create outcome: $OUT"
    case "$OUT" in
        created:*) ok "registration ceremony completed" ;;
        *)         bad "registration ceremony" "$OUT" ;;
    esac

    CREDS=$(wd "/webauthn/authenticator/$AUTH_ID/credentials")
    note "stored credentials: $CREDS"
    echo "$CREDS" | grep -q credentialId \
        && ok "credential visible via WebDriver" \
        || bad "credential listing" "none reported"

    info "probe 4b: get() assertion via trusted click"
    EL=$(wd_el '#get')
    wd_post "/element/$EL/click" '{}' >/dev/null
    OUT=$(poll_out 'getting')
    note "get outcome: $OUT"
    case "$OUT" in
        asserted:*) ok "assertion ceremony completed" ;;
        *)          bad "assertion ceremony" "$OUT" ;;
    esac
fi

echo
echo "== webauthn-probe: $PASS passed, $FAIL failed"
if [ -n "$AUTH_ID" ] && { echo "$AFTER" | grep -q object; }; then
    echo "VERDICT: CONFIRMED — WebAuthn lights up in automation sessions"
else
    echo "VERDICT: REFUTED — virtual-authenticator path not usable as probed"
fi
exit 0
