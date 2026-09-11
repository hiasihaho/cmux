#!/usr/bin/env bash
# Gate suite for the browser-WebAuthn SETTING (PASSKEYS.md §0; the
# "flag flip to a setting" roadmap item). The daily browser shows
# "WebAuthn isn't supported" purely because it runs without
# CMUX_WEBAUTHN=1, so the flag-gated polyfill never installs. This adds a
# cmux.json setting — `linux.browserWebAuthn` — so the feature can be
# turned on WITHOUT an env var, while keeping the env var as a HARD
# OVERRIDE for suites, the cmux_pk launcher and `promote --webauthn`.
#
# DEFAULT OFF (hias' call 2026-09-11): browser passkeys are a
# security-sensitive surface still earning a solid dogfood (the ceremony
# use-after-free was fixed 2026-09-10), so on-by-default is a later,
# separately-dogfooded decision. This suite pins that default.
#
#   linux/tests/webauthn-setting-smoke.sh [--keep]
#
# Contract: isEnabled = (env CMUX_WEBAUTHN == "1") OR (setting). Three
# legs: setting-on defines navigator.credentials with NO env; default
# (no setting, no env) leaves it undefined; env=1 overrides a false
# setting. The API-presence probe reads navigator.credentials the way a
# site's feature-detection does.
#
# Runs on an ISOLATED instance; the human's daily is never touched.
SUITE_NAME="webauthn-setting-smoke"
APP_ID_SUFFIX="wasettest"
PAGE_PORT=8449
source "$(dirname "$0")/lib.sh"

CONFIG_HOME="/tmp/cmux-$APP_ID_SUFFIX-confighome"
suite_cleanup() { rm -rf "$CONFIG_HOME"; return 0; }
require_tools python3

WORK=$(mktemp -d)
KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

# A localhost fixture: localhost is a secure context + top frame, which
# is all the polyfill needs to install. Empty page is enough for a
# feature-detection probe.
echo '<!DOCTYPE html><title>wa-setting</title><body>ok</body>' > "$WORK/index.html"
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
sleep 1
curl -s "http://localhost:$PAGE_PORT/index.html" | grep -q 'wa-setting' \
    || { echo "$SUITE_NAME: port $PAGE_PORT serving foreign content"; exit 2; }

URL="http://localhost:$PAGE_PORT/index.html"
API_PROBE='typeof navigator.credentials + "/" + typeof window.PublicKeyCredential'

write_config() {  # $1 = true|false|absent
    mkdir -p "$CONFIG_HOME/cmux"
    if [ "$1" = "absent" ]; then
        echo '{"linux": {}}' > "$CONFIG_HOME/cmux/cmux.json"
    else
        echo "{\"linux\": {\"browserWebAuthn\": $1}}" > "$CONFIG_HOME/cmux/cmux.json"
    fi
}
open_probe() {  # opens the fixture, echoes "<typeof creds>/<typeof PKC>"
    local surf
    surf=$(cx browser open "$URL" --focus false 2>/dev/null \
           | grep -oE 'surface=surface:[0-9]+' | cut -d= -f2)
    sleep 2
    cx browser eval --script "$API_PROBE" --surface "$surf" 2>/dev/null | tr -d '"'
}
restart_instance() {
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
        [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
    done
    sleep 1
    rm -f "$SESSION"
    start_instance || exit 2
    sleep 1
}

start_xvfb

# ---------------------------------- leg 1: setting ON, no env -> defined
info "leg 1: linux.browserWebAuthn=true (no env) exposes the API"
write_config true
INSTANCE_ENV=(XDG_CONFIG_HOME="$CONFIG_HOME" GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty")
start_instance || exit 2
sleep 1
OUT=$(open_probe)
[ "$OUT" = "object/function" ] \
    && ok "setting=true exposes navigator.credentials + PublicKeyCredential without CMUX_WEBAUTHN" \
    || bad "setting-on" "expected object/function, got '$OUT'"
ST=$(cx --json browser webauthn status 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('enabled'))" 2>/dev/null)
[ "$ST" = "True" ] && ok "webauthn status reports enabled:true from the setting" \
                   || bad "status enabled" "got '$ST'"

# --------------------------------- leg 2: default OFF (no setting, no env)
info "leg 2: default is OFF — absent setting leaves the API undefined"
write_config absent
restart_instance
OUT=$(open_probe)
[ "$OUT" = "undefined/undefined" ] \
    && ok "no setting + no env -> navigator.credentials undefined (default off)" \
    || bad "default-off" "expected undefined/undefined, got '$OUT'"

# --------------------------------- leg 3: env=1 overrides a false setting
info "leg 3: CMUX_WEBAUTHN=1 is a hard override of setting=false"
write_config false
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
INSTANCE_ENV=(XDG_CONFIG_HOME="$CONFIG_HOME" CMUX_WEBAUTHN=1 GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty")
start_instance || exit 2
sleep 1
OUT=$(open_probe)
[ "$OUT" = "object/function" ] \
    && ok "env CMUX_WEBAUTHN=1 exposes the API even with the setting false (hard override)" \
    || bad "env-override" "expected object/function, got '$OUT'"

echo
echo "== webauthn-setting-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
