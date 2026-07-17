#!/usr/bin/env bash
# Automated detector for the ghostty post-resize freeze (X11/XWayland).
# Usage: ghostty-resize-bisect.sh <ghostty-binary> [resources-dir]
# Exit 0 = healthy (resize survived), 1 = FROZEN, 125 = untestable
# (build/launch failure) — git-bisect-run compatible.
#
# Method: launch with a unique title, resize twice via xdotool, type a
# marker, then screenshot-diff two captures taken around more typing.
# A frozen surface keeps presenting its stale texture → captures are
# (nearly) identical.
set -u

BIN="${1:?usage: ghostty-resize-bisect.sh <ghostty-binary> [resources-dir]}"
RES="${2:-}"
TITLE="BISECT-$$-$RANDOM"
WORK=$(mktemp -d)
trap 'kill $GPID 2>/dev/null; rm -rf "$WORK"' EXIT

[ -x "$BIN" ] || exit 125

env_args=(GDK_BACKEND=x11)
[ -n "$RES" ] && env_args+=(GHOSTTY_RESOURCES_DIR="$RES")

env "${env_args[@]}" setsid "$BIN" --title="$TITLE" \
    >"$WORK/log" 2>&1 &
GPID=$!

# Find the window (ghostty startup can take a few seconds).
WID=""
for _ in $(seq 1 30); do
    WID=$(xdotool search --name "^$TITLE$" 2>/dev/null | head -1)
    [ -n "$WID" ] && break
    sleep 0.5
done
[ -n "$WID" ] || { echo "window never appeared" >&2; exit 125; }
sleep 2

# GTK ignores synthetic (XSendEvent) key events, so typing must go via
# XTEST to the FOCUSED window: activate first, then plain type/key.
xdotool windowactivate --sync "$WID" 2>/dev/null
sleep 0.5

# Sanity: typing works pre-resize (also warms the prompt).
xdotool type "echo PRE-$TITLE"
xdotool key Return
sleep 1

# The trigger: two interactive-ish resizes.
xdotool windowsize "$WID" 1100 750; sleep 1
xdotool windowsize "$WID" 700 500;  sleep 1
xdotool windowsize "$WID" 950 650;  sleep 1.5
GEOM=$(xdotool getwindowgeometry "$WID" | grep Geometry)
echo "post-resize $GEOM" >&2

# Capture, provoke output, capture again.
import -window "$WID" "$WORK/a.png" 2>/dev/null || exit 125
xdotool windowactivate --sync "$WID" 2>/dev/null
sleep 0.3
xdotool type "echo POST-$TITLE-MARKER"
xdotool key Return
sleep 1.5
import -window "$WID" "$WORK/b.png" 2>/dev/null || exit 125

# Frozen ⇒ captures identical (cursor blink allows a small delta).
DIFF=$(compare -metric AE "$WORK/a.png" "$WORK/b.png" null: 2>&1 | grep -oE '^[0-9.e+]+' | head -1)
DIFF=${DIFF%%.*}; DIFF=${DIFF:-0}
echo "pixel-diff after post-resize typing: $DIFF" >&2

if [ "$DIFF" -lt 500 ]; then
    echo "VERDICT: FROZEN" >&2
    exit 1
fi
echo "VERDICT: HEALTHY" >&2
exit 0
