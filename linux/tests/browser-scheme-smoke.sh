#!/usr/bin/env bash
# The `cmux://` URI scheme — the app serving its OWN state to a pane.
#
# WHY THE SEAM EXISTS: a surface's scrollback has no path on disk. It
# lives in the running process, so `file://` cannot address it and a
# localhost server would mean binding, authenticating and defending a
# port for data that never needs to leave. WebKit's scheme handler is
# the seam built for exactly that (approved 2026-09-06, GAPS row).
#
# WHAT THIS ASSERTS, and the last one is the point: a REMOTE page must
# not be able to read `cmux://`. A page that could fetch
# `cmux://surface/<id>/scrollback` would be reading the human's terminal.
#
#   browser-scheme-smoke.sh          # cleans up
#   browser-scheme-smoke.sh --keep   # leave the instance up
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="browser-scheme-smoke"
APP_ID_SUFFIX="schemetest"
PAGE_PORT=8452
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
printf '%s' '<!doctype html><title>scheme fixture</title><body><p>remote origin</p></body>' \
    > "$WORK/index.html"
start_fixture_server "$WORK"

start_xvfb
start_instance || exit 2

# A terminal surface with a marker in its buffer: app-owned state with no
# file behind it, which is the whole justification for the scheme.
MARKER="SCHEME_MARKER_$$"
WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
TSURF=$(first_surface_ref "$WS")
[ -n "$TSURF" ] || { echo "$SUITE_NAME: no terminal surface" >&2; exit 2; }
wait_for_shell "$TSURF" 30
cx send --surface "$TSURF" "echo $MARKER" >/dev/null 2>&1
cx send-key --surface "$TSURF" Enter >/dev/null 2>&1
sleep 2
# The SURFACE uuid, not a pane's: list-panes prints pane ids, and asking
# a browser pane for scrollback is how the first run of this suite failed.
TUUID=$(cx --id-format uuids list-pane-surfaces --workspace "$WS" 2>/dev/null \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
[ -n "$TUUID" ] || { echo "$SUITE_NAME: no surface uuid" >&2; exit 2; }

info "cmux://about — the app describing itself"
B=$(cx browser open "cmux://about" --workspace "$WS" | grep -oE 'surface:[0-9]+')
[ -n "$B" ] || { echo "$SUITE_NAME: no browser surface" >&2; exit 2; }
cx select-workspace --workspace "$WS" >/dev/null
sleep 3
about=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
# Gate for the last two legs: without a working scheme, "nothing leaked"
# and "nothing served" are TRUE FOR THE WRONG REASON. A vacuous pass is
# worse than a failure, so those legs skip instead (the same guard pk3's
# review demanded of the verbs secrecy leg).
SCHEME_OK=no
if echo "$about" | grep -q '"build"'; then
    SCHEME_OK=yes
    ok "cmux://about serves the build stamp"
else
    bad "about route" "got: $(echo "$about" | head -c 80)"
fi
echo "$about" | grep -q 'scheme_routes' \
    && ok "cmux://about lists its own routes" \
    || bad "about routes" "no scheme_routes in the payload"
echo "$about" | grep -qi 'not a freshness or authenticity claim' \
    && ok "the payload refuses to be read as a freshness claim" \
    || bad "about note" "the scope note is missing from the payload"

info "cmux://surface/<uuid>/scrollback — state with no file behind it"
cx browser --surface "$B" goto "cmux://surface/$TUUID/scrollback" >/dev/null 2>&1
sleep 3
back=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
echo "$back" | grep -q "$MARKER" \
    && ok "a terminal's scrollback is served to the pane" \
    || bad "scrollback route" "marker absent; got: $(echo "$back" | head -c 80)"

info "unknown route fails rather than serving something"
cx browser --surface "$B" goto "cmux://nope/nothing" >/dev/null 2>&1
sleep 3
nope=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "unknown-route refusal" "scheme not serving: refusal is indistinguishable from absence"
elif echo "$nope" | grep -q "$MARKER"; then
    bad "unknown route" "still showing the previous document"
else
    ok "an unknown route does not serve the previous document"
fi

info "a REMOTE page cannot read cmux:// (the point of the suite)"
cx browser --surface "$B" goto "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1
sleep 3
leak=$(cx browser --surface "$B" eval \
    'fetch("cmux://about").then(r=>r.text()).then(t=>"LEAKED:"+t.slice(0,20)).catch(e=>"REFUSED")' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "cross-origin refusal" "scheme not serving: a refusal here would prove nothing"
elif echo "$leak" | grep -q "REFUSED"; then
    ok "a remote origin's fetch of cmux:// is refused"
else
    bad "cross-origin read" "got: $(echo "$leak" | head -c 80)"
fi

rm -rf "$WORK"
finish
