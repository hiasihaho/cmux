#!/usr/bin/env bash
# The minimal Dock (comfort mirror ⑦, MACOS-UX §5): global dock.json
# seeds terminal controls into a toggleable trailing panel; commands run
# in a login shell (proven by a marker file) and browser controls are
# skipped-and-counted. debug.dock is the state projection + dev toggle.
#
#   dock-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="dock-smoke"
APP_ID_SUFFIX="docktest"
PAGE_PORT=8435   # unique X display only; no fixture server
source "$(dirname "$0")/lib.sh"

MARKER=/tmp/cmux-docktest-marker
rm -f "$MARKER"
# The hermetic confighome lib.sh gives the instance is where the GLOBAL
# dock.json lives for this app.
CONFIGHOME="/tmp/cmux-$APP_ID_SUFFIX-confighome"
mkdir -p "$CONFIGHOME/cmux"
cat > "$CONFIGHOME/cmux/dock.json" << EOF
{ "controls": [
  { "id": "marker", "title": "Marker", "command": "echo dock-alive > $MARKER; tail -f /dev/null" },
  { "id": "shellback", "command": "true" },
  { "id": "web", "type": "browser", "url": "https://example.com" },
  { "id": "", "command": "echo bad-id-must-be-skipped" }
] }
EOF

start_xvfb
start_instance || exit 2

dock() { v2 "{\"id\":1,\"method\":\"debug.dock\"${1:+,\"params\":$1}}"; }
field() { dock "${2:-}" | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['$1'])"; }

expect "dock starts hidden" "False" "$(field visible)"
expect "dock is lazy (not populated while hidden)" "False" "$(field populated)"
v2 '{"id":1,"method":"debug.dock","params":{"set_visible":true}}' >/dev/null
sleep 3
expect "toggle shows the dock" "True" "$(field visible)"
expect "showing populates it" "True" "$(field populated)"
ids=$(dock | python3 -c "
import json,sys
print(' '.join(c['id'] for c in json.load(sys.stdin)['result']['controls']))")
expect "terminal controls load (bad ids dropped)" "marker shellback" "$ids"
expect "browser controls are skipped and counted" "1" "$(field skipped_browser_controls)"
found=""
for _ in $(seq 1 10); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
[ "$found" = "yes" ] && ok "control command really ran (login shell wrote the marker)" \
    || bad "dock command" "marker file never appeared"
v2 '{"id":1,"method":"debug.dock","params":{"set_visible":false}}' >/dev/null
sleep 1
expect "toggle hides the dock again" "False" "$(field visible)"

rm -f "$MARKER"
finish
