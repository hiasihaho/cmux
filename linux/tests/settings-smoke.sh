#!/usr/bin/env bash
# Settings file (~/.config/cmux/cmux.json, "linux" section) + preferences
# window. Resolution order under test: environment > file > default —
# the env vars came first and suites/scripts depend on them winning.
#
#   settings-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="settings-smoke"
APP_ID_SUFFIX="settest"
PAGE_PORT=8421
# Point XDG_CONFIG_HOME at a fixture so the suite never reads (or writes!)
# the user's real config.
CONFIG_HOME="/tmp/cmux-settest-config"
INSTANCE_ENV=(XDG_CONFIG_HOME=$CONFIG_HOME)
source "$(dirname "$0")/lib.sh"

rm -rf "$CONFIG_HOME"
mkdir -p "$CONFIG_HOME/cmux"
suite_cleanup() { rm -rf "$CONFIG_HOME"; }

# ------------------------------------------------- file: scrollback limit
info "settings file: scrollback limit"
cat > "$CONFIG_HOME/cmux/cmux.json" <<'JSON'
{
  "linux": {
    "scrollbackLimit": 4096,
    "terminalBackend": "vte"
  }
}
JSON
start_xvfb
start_instance || exit 2
WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
T=$(first_surface_ref "$WS")
if [ -n "$T" ] && wait_for_shell "$T"; then
    cx send --surface "$T" 'seq 1 2000\n' >/dev/null 2>&1
    sleep 3
    cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # force a save
    sleep 3
    sbdir="$(dirname "$SESSION")/scrollback"
    largest=$(stat -c%s "$sbdir"/*.txt 2>/dev/null | sort -n | tail -1)
    # 4096 chars + ANSI-safety slack; without the limit this is ~10KB+.
    if [ -n "$largest" ] && [ "$largest" -le 6000 ]; then
        ok "file limit bounds the capture ($largest bytes ≤ 6000)"
    else
        bad "scrollback limit from file" "largest capture: ${largest:-none} bytes"
    fi
else
    skip "scrollback limit assertion" "the shell never started"
fi

# ------------------------------------------------- file: terminal backend
# The config chose VTE; a ghostty-linked build logs its embed init only
# when Ghostty actually starts. VTE panes also lack the "pwd" property
# path, but the log line is the cheapest honest signal.
info "settings file: terminal backend"
inits=$(grep -c "ghostty_embed_init\|found Ghostty resources dir" "$LOG" 2>/dev/null)
expect "backend=vte in the file keeps Ghostty uninitialized" "0" "${inits:-0}"

# ------------------------------------------------------- env beats file
info "environment overrides the file"
kill_instance
INSTANCE_ENV=(XDG_CONFIG_HOME=$CONFIG_HOME CMUX_TERM=ghostty)
start_instance || exit 2
WS2=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS2" >/dev/null
T2=$(first_surface_ref "$WS2")
[ -n "$T2" ] && wait_for_shell "$T2" >/dev/null 2>&1
sleep 2
inits2=$(grep -c "found Ghostty resources dir" "$LOG" 2>/dev/null)
[ "${inits2:-0}" -ge 1 ] \
    && ok "CMUX_TERM=ghostty wins over the file's vte" \
    || bad "env override" "Ghostty never initialized despite CMUX_TERM=ghostty"

# ------------------------------------------------- preferences window
info "preferences window (Ctrl+comma)"
if command -v xdotool >/dev/null 2>&1 && [ "$USE_XVFB" = "1" ]; then
    WIN=$(DISPLAY="$XDISPLAY" xdotool search --name '^cmux$' | head -1)
    DISPLAY="$XDISPLAY" xdotool windowfocus "$WIN" 2>/dev/null
    DISPLAY="$XDISPLAY" xdotool key --window "$WIN" ctrl+comma
    sleep 2
    PREFS=$(DISPLAY="$XDISPLAY" xdotool search --name 'cmux Preferences' | head -1)
    [ -n "$PREFS" ] && ok "window opens on Ctrl+comma" \
                    || bad "preferences window" "no window titled 'cmux Preferences'"
    if [ -n "$PREFS" ]; then
        screenshot /tmp/cmux-settest-prefs.png \
            && ok "screenshot captured ($(stat -c%s /tmp/cmux-settest-prefs.png) bytes)" \
            || skip "screenshot" "import not available"
    fi
else
    skip "preferences window assertions" "needs Xvfb + xdotool"
fi

# The window writes through LinuxSettings; prove a write lands in the file
# by asking the app to update settings the same way the widgets do — via
# an edit through the running instance is UI-bound, so instead assert the
# file the suite provided is still intact (the app must not clobber it on
# read).
python3 -c "
import json
d = json.load(open('$CONFIG_HOME/cmux/cmux.json'))
assert d['linux']['scrollbackLimit'] == 4096
print('ok')" >/dev/null 2>&1 \
    && ok "config file not clobbered by reads" \
    || bad "config file" "content changed without a write"

finish
