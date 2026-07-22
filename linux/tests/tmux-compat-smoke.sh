#!/usr/bin/env bash
# The tmux-compat surface `cmux claude-teams` stands on (also codex-teams,
# omc/omo/omx): the shared CLI's tmux shim translates tmux verbs into
# socket calls, so Claude Code teammates become native cmux splits.
#
# Verified end-to-end with a real Claude session 2026-07-22 (teammate
# spawned as a split, ran its command, was captured and shut down). This
# suite pins the two server contracts that run made work — and that were
# both missing when the probe started:
#
#   1. `system.identify` must carry a `focused` block with pane_id —
#      the teams launcher builds the shim's TMUX identity from it, and
#      without it every spawn died with "Could not determine current
#      tmux pane/window" while the env silently fell back to default,0,0.
#   2. `surface.current` must answer — the shim resolves every
#      list/target/send through it.
#
# The tmux verbs themselves are driven through `cmux __tmux-compat`
# exactly as the shim script does, from INSIDE a pane (the pane's env is
# the shim's identity), with no Claude in the loop.
#
#   tmux-compat-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="tmux-compat-smoke"
APP_ID_SUFFIX="tmuxctest"
source "$(dirname "$0")/lib.sh"

start_xvfb
start_instance || exit 2

T=$(first_surface_ref workspace:1)
if [ -z "$T" ] || ! wait_for_shell "$T"; then
    skip "all tmux-compat assertions" "the shell never started"
    finish
fi

# ------------------------------------------------ the launcher's contract
info "system.identify carries the focused block the teams launcher needs"
foc=$(python3 - "$SOCK" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b'{"id":1,"method":"system.identify"}\n')
data = b""
while not data.endswith(b"\n"):
    c = s.recv(65536)
    if not c: break
    data += c
f = json.loads(data).get("result", {}).get("focused") or {}
print("pane" if f.get("pane_id") else "nopane", "ws" if f.get("workspace_id") else "nows")
PY
)
expect "identify.focused has pane_id and workspace_id" "pane ws" "$foc"

info "surface.current answers with the focused pane envelope"
cur=$(python3 - "$SOCK" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b'{"id":2,"method":"surface.current","params":{}}\n')
data = b""
while not data.endswith(b"\n"):
    c = s.recv(65536)
    if not c: break
    data += c
r = json.loads(data).get("result", {})
print("ok" if (r.get("pane_id") and r.get("surface_ref") and r.get("surface_type")) else "incomplete")
PY
)
expect "surface.current returns pane_id + surface_ref + surface_type" "ok" "$cur"

# --------------------------------------- the shim round trip, from a pane
# Everything below runs INSIDE the pane via `cx send`, because the pane's
# inherited CMUX_* env is the identity `__tmux-compat` resolves against —
# exactly how the claude-teams shim script invokes it.
info "tmux verbs round-trip through __tmux-compat (the claude-teams path)"
WORK="/tmp/cmux-$APP_ID_SUFFIX-work"
mkdir -p "$WORK"
rm -f "$WORK/tmux-rt.out"
RT_OUT="$WORK/tmux-rt.out"
cat > "$WORK/tmux-rt.sh" <<'EOS'
#!/bin/bash
cmux __tmux-compat split-window -h 2>&1
sleep 3
panes=$(cmux __tmux-compat list-panes -F '#{pane_id}' 2>&1)
echo "PANES:$(echo "$panes" | grep -c '^%')"
target=$(echo "$panes" | tail -1)
cmux __tmux-compat send-keys -t "$target" "echo TMUXC_RT_MARKER" Enter 2>&1
sleep 2
echo "CAPTURE:$(cmux __tmux-compat capture-pane -p -t "$target" 2>/dev/null | grep -c TMUXC_RT_MARKER)"
cmux __tmux-compat kill-pane -t "$target" 2>&1
sleep 2
echo "AFTERKILL:$(cmux __tmux-compat list-panes -F '#{pane_id}' 2>/dev/null | grep -c '^%')"
EOS
cx send --surface "$T" "bash $WORK/tmux-rt.sh > $RT_OUT 2>&1\n" >/dev/null 2>&1
for _ in $(seq 1 30); do
    grep -q "AFTERKILL:" "$RT_OUT" 2>/dev/null && break
    sleep 1
done
expect "split-window created a second pane" "PANES:2" "$(grep '^PANES:' "$RT_OUT" 2>/dev/null)"
expect "send-keys + capture-pane round-trip the marker" "CAPTURE:2" "$(grep '^CAPTURE:' "$RT_OUT" 2>/dev/null)"
expect "kill-pane collapses back to one pane" "AFTERKILL:1" "$(grep '^AFTERKILL:' "$RT_OUT" 2>/dev/null)"

finish
