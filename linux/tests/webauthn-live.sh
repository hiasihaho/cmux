#!/usr/bin/env bash
# LIVE proof drive for the WebAuthn client layer: register + authenticate
# on https://webauthn.io — a real third-party relying party whose server
# verifies our attestation and assertion. First green 2026-09-01
# (PROGRESS.md); kept as a repeatable script because "a real RP accepted
# it" is the proof no local fixture can give.
#
#   linux/tests/webauthn-live.sh [--keep]
#
# NOT a gate suite (external service + network): run it for dogfood,
# release confidence, or after touching ceremony/CBOR/signing code.
# webauthn-smoke.sh is the offline gate. Exit 0 = logged in, 1 = a step
# failed, 2 = setup/offline.
#
# Runs on an ISOLATED instance; the human's daily is never touched.
SUITE_NAME="webauthn-live"
APP_ID_SUFFIX="walive"
PAGE_PORT=8445   # no fixture server; unique X display slot only
source "$(dirname "$0")/lib.sh"

VAULT="/tmp/cmux-$APP_ID_SUFFIX-vault.json"
suite_cleanup() {
    rm -f "$VAULT"
    return 0
}

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
rm -f "$VAULT"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

curl -s -m 8 -o /dev/null https://webauthn.io || { echo "SKIP: webauthn.io unreachable"; exit 2; }

for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

info "starting isolated instance (CMUX_WEBAUTHN=1, auto-approve)"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
)
start_xvfb
start_instance || exit 2
sleep 1

SURF=$(cx browser open https://webauthn.io --focus false 2>/dev/null \
       | grep -oE 'surface=surface:[0-9]+' | cut -d= -f2)
[ -n "$SURF" ] || { echo "no browser surface"; exit 2; }
cx browser "$SURF" wait --load-state complete --timeout 25 >/dev/null 2>&1
sleep 2

USERNAME="cmux-linux-$(date +%s)"
info "register as $USERNAME"
cx browser "$SURF" fill 'input#input-email' "$USERNAME" >/dev/null 2>&1 \
    || { bad "username field" "fill failed"; exit 1; }
cx browser "$SURF" click '#register-button' >/dev/null 2>&1 \
    || { bad "register button" "click failed"; exit 1; }
# Poll the vault, not the page: the credential landing in OUR store is
# the half we own; the server round-trip is proven by authenticate.
CRED=""
for _ in $(seq 1 15); do
    CRED=$(python3 -c "
import json
try:
    d = json.load(open('$VAULT'))
    print(next(c['userName'] for c in d['credentials'] if c['rpId'] == 'webauthn.io'))
except Exception:
    pass" 2>/dev/null)
    [ -n "$CRED" ] && break
    sleep 1
done
[ "$CRED" = "$USERNAME" ] \
    && ok "registration ceremony ran (vault holds webauthn.io credential for $USERNAME)" \
    || { bad "registration" "vault: '$CRED'"; exit 1; }

info "authenticate (server-side signature verification)"
cx browser "$SURF" click '#login-button' >/dev/null 2>&1
for _ in $(seq 1 15); do
    URL=$(cx browser "$SURF" url 2>/dev/null | head -1)
    case "$URL" in *"/profile"*) break ;; esac
    sleep 1
done
case "$URL" in
    *"/profile"*) ok "webauthn.io accepted the assertion (landed on $URL)" ;;
    *) bad "authenticate" "url stayed '$URL'"; exit 1 ;;
esac
cx browser "$SURF" get text 'h3' 2>/dev/null | head -1 | grep -qi "logged in" \
    && ok "profile page confirms login" \
    || echo "  NOTE  profile heading not matched (cosmetic; URL check already passed)"

echo
echo "== webauthn-live: $PASS passed, $FAIL failed — a real RP verified our ES256 assertion"
[ "$FAIL" -eq 0 ]
