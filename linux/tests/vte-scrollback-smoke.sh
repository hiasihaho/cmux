#!/usr/bin/env bash
# Scrollback persistence under the VTE backend (CMUX_TERM=vte).
#
# The Ghostty path went first (fork's inject_output); this suite proves the
# VTE twin: capture via vte_terminal_get_text_range_format across the whole
# retained buffer, replay via vte_terminal_feed — parsed as terminal
# OUTPUT, never handed to the shell.
#
#   vte-scrollback-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="vte-scrollback-smoke"
APP_ID_SUFFIX="vtesbtest"
PAGE_PORT=8420
INSTANCE_ENV=(CMUX_TERM=vte)
source "$(dirname "$0")/lib.sh"

start_xvfb
start_instance || exit 2

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
T=$(first_surface_ref "$WS")
if [ -z "$T" ] || ! wait_for_shell "$T"; then
    skip "all VTE scrollback assertions" "the shell never started"
    finish
fi

info "capture: full buffer, not just the viewport"
# Enough output that the marker scrolls out of the visible screen — the
# capture must include scrollback for it to survive.
cx send --surface "$T" 'echo VTE_SB_MARKER_XYZ; seq 1 200\n' >/dev/null 2>&1
sleep 2
cx new-workspace --cwd /tmp --background >/dev/null 2>&1   # force a save
sleep 3
sbdir="$(dirname "$SESSION")/scrollback"
stored=$(grep -l VTE_SB_MARKER_XYZ "$sbdir"/*.txt 2>/dev/null | wc -l)
[ "${stored:-0}" -gt 0 ] \
    && ok "marker beyond the viewport is captured to the file" \
    || bad "vte capture" "no scrollback file holds the marker"

info "replay after a restart"
kill_instance
start_instance || exit 2
sleep 3
WSB=$(cx list-workspaces | grep -oE 'workspace:[0-9]+' | sed -n '2p')
cx select-workspace --workspace "$WSB" >/dev/null
TB=$(first_surface_ref "$WSB")
[ -n "$TB" ] && wait_for_shell "$TB" 30
sleep 2
screen=$(cx read-screen --surface "$TB" --scrollback 2>/dev/null || cx read-screen --surface "$TB" 2>/dev/null)
echo "$screen" | grep -q VTE_SB_MARKER_XYZ \
    && ok "marker is back after the restart" \
    || bad "vte replay" "marker not present after restart"

# The replayed 1..200 lines must start at column 0 — a staircase would
# indent them (LF without CR).
echo "$screen" | grep -q '^199$\|^200$' \
    && ok "replayed lines are un-staircased (column 0)" \
    || bad "vte staircase" "sequence lines not at column 0"

errs=$(echo "$screen" | grep -ci "command not found")
expect "replayed text was not executed by the shell" "0" "${errs:-0}"

finish
