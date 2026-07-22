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
mark_capture_epoch
cx send --surface "$T" 'echo VTE_SB_MARKER_XYZ; seq 1 200\n' >/dev/null 2>&1
# Poll, don't sleep — and keep forcing saves while polling: under
# full-gate load the output can land in the buffer AFTER a save already
# ran, so a single forced save can miss the marker (3 red assertions in
# the 2026-07-22 gate; green in isolation). The poll condition is
# capture COMPLETENESS (marker + seq's final line), not the marker
# alone — breaking on the marker saves a mid-seq snapshot and the
# staircase assertion then fails on the missing tail. Only post-epoch
# files count: the scrollback dir is shared and stale files satisfy
# the greps instantly.
sbdir="$SBDIR"
stored=0
for i in $(seq 1 30); do
    [ $(( i % 6 )) -eq 1 ] && force_save
    for fp in $(find "$sbdir" -name '*.txt' -newer "$CAPTURE_STAMP" 2>/dev/null); do
        if grep -q VTE_SB_MARKER_XYZ "$fp" && grep -q '^200' "$fp"; then
            stored=1
            break
        fi
    done
    [ "$stored" -gt 0 ] && break
    sleep 0.5
done
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
# Poll, don't sleep: replay latency varies with load.
screen=""
for _ in $(seq 1 30); do
    screen=$(cx read-screen --surface "$TB" --scrollback 2>/dev/null || cx read-screen --surface "$TB" 2>/dev/null)
    echo "$screen" | grep -q VTE_SB_MARKER_XYZ && break
    sleep 0.5
done
if echo "$screen" | grep -q VTE_SB_MARKER_XYZ; then
    ok "marker is back after the restart"
else
    bad "vte replay" "marker not present after restart"
    # Gate-only failure under investigation (2026-07-22): green in
    # isolation and in adjacent-pair runs. Say WHY next time.
    echo "  -- diag workspaces: $(cx list-workspaces 2>&1 | tr '\n' ' ')"
    echo "  -- diag target: WSB=$WSB TB=$TB"
    echo "  -- diag debug.surfaces:"
    v2 '{"id":9,"method":"debug.surfaces"}' | head -c 600 | sed 's/^/     /'
    echo
    echo "  -- diag screen tail:"
    echo "$screen" | tail -6 | sed 's/^/     /'
fi

# The replayed 1..200 lines must start at column 0 — a staircase would
# indent them (LF without CR).
echo "$screen" | grep -q '^199$\|^200$' \
    && ok "replayed lines are un-staircased (column 0)" \
    || bad "vte staircase" "sequence lines not at column 0"

errs=$(echo "$screen" | grep -ci "command not found")
expect "replayed text was not executed by the shell" "0" "${errs:-0}"

# ---------------------------------------------- legacy-dir read fallback
# Scrollback moved from the shared dirname(session)/scrollback to the
# per-session <stem>-scrollback dir (2026-07-22). One upgrade window
# remains: a session saved BEFORE the move restarts with its files still
# in the legacy dir, and the read fallback must replay them. Simulated
# by relocating this run's files to the legacy path before a restart.
# Delete this leg together with ScrollbackStore's legacyDirectory.
legacy_dir="$(dirname "$SESSION")/scrollback"
mkdir -p "$legacy_dir"
moved=0
for fp in "$SBDIR"/*.txt; do
    [ -f "$fp" ] && mv "$fp" "$legacy_dir/" && moved=$((moved + 1))
done
if [ "$moved" -gt 0 ]; then
    kill_instance
    start_instance || exit 2
    sleep 3
    WSC=$(cx list-workspaces | grep -oE 'workspace:[0-9]+' | sed -n '2p')
    cx select-workspace --workspace "$WSC" >/dev/null
    TC=$(first_surface_ref "$WSC")
    [ -n "$TC" ] && wait_for_shell "$TC" 30
    screen2=""
    for _ in $(seq 1 30); do
        screen2=$(cx read-screen --surface "$TC" --scrollback 2>/dev/null || cx read-screen --surface "$TC" 2>/dev/null)
        echo "$screen2" | grep -q VTE_SB_MARKER_XYZ && break
        sleep 0.5
    done
    echo "$screen2" | grep -q VTE_SB_MARKER_XYZ \
        && ok "pre-move files in the legacy shared dir still replay" \
        || bad "legacy fallback" "marker in legacy dir was not replayed"
else
    skip "legacy fallback assertion" "no scrollback files to relocate"
fi

finish
