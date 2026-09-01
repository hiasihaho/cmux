#!/usr/bin/env bash
# system.top — CPU/memory attributed to the pane tree.
#
# Two consumers justify this verb: `cmux top` for humans, and the CLI's
# pid->surface binding that OVERRIDES a stale/leaked CMUX_SURFACE_ID (the
# "codex jumble class"). The second can never fire while the verb answers
# unknown_method, which is what the Linux port did until 2026-09-01.
#
# Ghostty panes need the shim accessor `ghostty_embed_surface_pid`; it is
# resolved by dlsym, so an older shim degrades to "pids unknown" rather
# than breaking the build. This suite asserts BOTH: the tree is always
# well-formed, and attribution is real whenever the shim can answer.
#
#   system-top-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="system-top-smoke"
APP_ID_SUFFIX="toptest"
PAGE_PORT=8441   # unique X display only; no fixture server
source "$(dirname "$0")/lib.sh"

start_xvfb
start_instance || exit 2

top() { v2 '{"id":1,"method":"system.top","params":{"include_processes":true}}'; }
field() { python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

# --- 1: the verb exists and is shaped as the CLI consumes it -------------
resp=$(top)
expect "system.top is dispatched (not unknown_method)" "True" \
    "$(echo "$resp" | python3 -c "import json,sys;print('error' not in json.load(sys.stdin))")"
expect "one window in the payload" "1" "$(echo "$resp" | field "['result']['windows'].__len__()")"
expect "window carries a ref" "window:1" "$(echo "$resp" | field "['result']['windows'][0]['ref']")"
for key in cpu_percent memory_bytes process_count workspaces; do
    expect "window has $key" "True" \
        "$(echo "$resp" | python3 -c "import json,sys;print('$key' in json.load(sys.stdin)['result']['windows'][0])")"
done
expect "surface exposes top_level_pids" "True" "$(echo "$resp" | python3 -c "
import json,sys
su=json.load(sys.stdin)['result']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'][0]
print('top_level_pids' in su and 'processes' in su)")"

# --- 2: attribution is REAL when the shim can answer ---------------------
# A pid of 0 or a wrong pid would be worse than none, so assert the pid is
# a live process AND that a child spawned in the pane joins its subtree.
pids=$(top | field "['result']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'][0]['top_level_pids']")
if [ "$pids" = "[]" ]; then
    skip "process attribution" "shim predates ghostty_embed_surface_pid (dlsym miss) — degraded to unknown, which is the designed fallback"
    skip "child processes join the surface subtree" "no root pid to grow a subtree from"
else
    pid=$(echo "$pids" | tr -d '[] ')
    [ -d "/proc/$pid" ] && ok "reported pid $pid is a live process" \
        || bad "reported pid" "$pid is not in /proc"
    before=$(top | field "['result']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'][0]['process_count']")
    cx send --workspace workspace:1 --surface surface:1 'sleep 300 &' >/dev/null 2>&1
    cx send-key --workspace workspace:1 --surface surface:1 Enter >/dev/null 2>&1
    sleep 3
    after=$(top | field "['result']['windows'][0]['workspaces'][0]['panes'][0]['surfaces'][0]['process_count']")
    [ "$after" -gt "$before" ] && ok "child process joins the surface subtree ($before -> $after)" \
        || bad "subtree growth" "process_count stayed $before after spawning a child"
fi

finish
