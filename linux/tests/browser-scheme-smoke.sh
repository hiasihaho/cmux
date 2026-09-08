#!/usr/bin/env bash
# The `cmux://` URI scheme — the app serving its OWN state to a pane.
#
# WHY THE SEAM EXISTS: a surface's scrollback has no path on disk. It
# lives in the running process, so `file://` cannot address it and a
# localhost server would mean binding, authenticating and defending a
# port for data that never needs to leave. WebKit's scheme handler is
# the seam built for exactly that (approved 2026-09-06, GAPS row).
#
# WHAT THIS ASSERTS, and the last block is the point: a REMOTE page must
# neither READ `cmux://` (a page that could fetch
# `cmux://surface/<id>/scrollback` would be reading the human's terminal)
# NOR NAVIGATE a pane onto it — the E1 ruling of 2026-09-08. The refusal
# legs come in pairs: what the page must not do, and what cmux must still
# be able to do, so the gap cannot be "closed" by breaking the seam.
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
cat > "$WORK/index.html" <<'HTML'
<!doctype html><title>scheme fixture</title><body>
<p>remote origin</p>
<button id="openhttp" onclick="window.open('/index.html','_blank')">http</button>
<button id="opencmux" onclick="window.open('cmux://about','_blank')">cmux</button>
</body>
HTML
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
elif echo "$nope" | grep -q '"status": *"unknown-route"'; then
    # "different document" would also pass for a handler that served an
    # empty page; assert the typed refusal itself (qvision review).
    ok "an unknown route is REFUSED with a typed status"
else
    bad "unknown route" "expected a typed unknown-route body; got: $(echo "$nope" | head -c 80)"
fi

info "the three non-answers are distinguishable across the seam"
cx browser --surface "$B" goto "cmux://surface/not-a-uuid/scrollback" >/dev/null 2>&1
sleep 2
badid=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "typed non-answers" "scheme not serving"
elif echo "$badid" | grep -q '"status": *"not-a-uuid"'; then
    ok "a malformed id answers not-a-uuid, not the unknown-route code"
else
    bad "typed non-answers" "got: $(echo "$badid" | head -c 80)"
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

info "E1: a remote page must not steer the pane onto cmux:// (hias ruling 2026-09-08)"
# Was a recorded SKIP (qvision review note 3): WebKit allowed it, and the
# suite refused to pass vacuously over a capability question. hias ruled
# it closed, so the skip becomes an assertion.
cx browser --surface "$B" goto "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1
sleep 3
cx browser --surface "$B" eval 'window.location = "cmux://about"; "issued"' >/dev/null 2>&1
sleep 3
navd=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
navurl=$(cx browser --surface "$B" eval 'location.href' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "remote navigation" "scheme not serving: a refusal here would prove nothing"
elif echo "$navd" | grep -q '"build"'; then
    bad "remote navigation to cmux://" "the page steered the pane onto app-owned state"
elif echo "$navurl" | grep -q "127.0.0.1:$PAGE_PORT"; then
    # Positive, not merely "not on cmux://": a pane that died into
    # about:blank would satisfy the negative form and prove nothing.
    ok "a remote page cannot navigate the pane to cmux://"
else
    bad "remote navigation to cmux://" "left the fixture without reaching cmux://: $navurl"
fi

info "E1: a subframe is an entry too, not just the main frame"
# Denied -> the iframe stays at about:blank, which INHERITS the parent
# origin and is therefore readable. Allowed -> it holds a cmux://
# document, whose opaque origin makes the same read throw. The two
# outcomes are distinguishable from the page, which is why this is an
# assertion and not a hope.
cx browser --surface "$B" goto "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1
sleep 3
cx browser --surface "$B" eval '(()=>{const f=document.createElement("iframe");f.src="cmux://about";document.body.appendChild(f);return "issued"})()' >/dev/null 2>&1
sleep 3
framed=$(cx browser --surface "$B" eval '(()=>{const f=document.querySelector("iframe");if(!f)return "NO-FRAME";try{return "READ:"+String(f.contentWindow.location.href)}catch(e){return "OPAQUE"}})()' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "subframe navigation" "scheme not serving"
elif echo "$framed" | grep -q "READ:about:blank"; then
    ok "a remote page cannot pull cmux:// into a subframe"
elif echo "$framed" | grep -q "OPAQUE"; then
    bad "subframe navigation" "the frame reached a cmux:// document (opaque origin)"
else
    skip "subframe navigation" "inconclusive probe, not a pass: $(echo "$framed" | head -c 60)"
fi

info "E1: window.open is a third entry (control first, or this proves nothing)"
# A popup becomes a TAB in the opener's pane, so the pane count does not
# move and the SURFACE count does — the counter browser-popup-smoke had
# to learn the same way. And the click is a real one: window.open issued
# from an eval carries no user gesture, WebKit's popup blocker refuses
# it, and the leg could then only ever skip.
surfaces() {
    cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
print(sum(p["surface_count"] for p in json.load(sys.stdin)["panes"]))'
}
cx browser --surface "$B" goto "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1
sleep 3
before=$(surfaces)
cx browser --surface "$B" click '#openhttp' >/dev/null 2>&1
sleep 3
control=$(surfaces)
cx browser --surface "$B" click '#opencmux' >/dev/null 2>&1
sleep 3
after=$(surfaces)
if [ "$SCHEME_OK" = "no" ]; then
    skip "window.open refusal" "scheme not serving"
elif [ "${control:-0}" -le "${before:-0}" ]; then
    # Popup routing sits behind a settings flag and a burst budget.
    # Without this control, "no new surface" is true for the wrong reason.
    skip "window.open refusal" "popups did not route here ($before -> $control): a refusal would prove nothing"
elif [ "${after:-0}" -eq "${control:-0}" ]; then
    ok "a remote page's window.open(cmux://) opens no pane"
else
    bad "window.open refusal" "a popup pane appeared for cmux:// ($control -> $after)"
fi

info "E1 refuses a CLASS — it must not take the route away from cmux"
# The other half of the ruling. A policy that closed the gap by making
# cmux:// unreachable for everyone would pass the leg above and destroy
# the seam; these two legs are what keep that honest.
cx browser --surface "$B" goto "cmux://about" >/dev/null 2>&1
sleep 3
mine=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "cmux keeps the route" "scheme not serving"
elif echo "$mine" | grep -q '"build"'; then
    ok "cmux itself still navigates a pane to cmux://"
else
    bad "cmux keeps the route" "the policy locked cmux out too: $(echo "$mine" | head -c 80)"
fi

cx browser --surface "$B" eval 'location.reload(); "issued"' >/dev/null 2>&1
sleep 3
reloaded=$(cx browser --surface "$B" eval 'document.body.innerText' 2>/dev/null)
if [ "$SCHEME_OK" = "no" ]; then
    skip "cmux:// reload" "scheme not serving"
elif echo "$reloaded" | grep -q '"build"'; then
    ok "a cmux:// document may still reload itself"
else
    bad "cmux:// reload" "reload of our own document was refused: $(echo "$reloaded" | head -c 80)"
fi

rm -rf "$WORK"
finish
