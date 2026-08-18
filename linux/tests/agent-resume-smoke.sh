#!/usr/bin/env bash
# Agent session auto-resume on restore (macOS `terminal.autoResumeAgentSessions`;
# GAPS 2026-08-18): a restored terminal surface whose agent session was
# recorded by the hooks gets the agent's NATIVE resume command typed into
# its fresh shell. The suite fakes the recording half — a fixture hook
# store (CMUX_HOOK_SESSIONS_DIR) keyed by the REAL surface uuid, plus a
# stub `claude` on PATH that logs its argv — then restarts the instance
# onto the same session file and asserts the command ran; a third phase
# asserts CMUX_AUTO_RESUME=0 suppresses it.
#
#   agent-resume-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="agent-resume-smoke"
APP_ID_SUFFIX="resumetest"
PAGE_PORT=8438   # unique X display only; no fixture server
source "$(dirname "$0")/lib.sh"

FIXDIR=/tmp/cmux-resumetest-hooks
STUBDIR=/tmp/cmux-resumetest-bin
MARKER=/tmp/cmux-resumetest-marker
rm -rf "$FIXDIR" "$STUBDIR"
rm -f "$MARKER" "$SESSION"
mkdir -p "$FIXDIR" "$STUBDIR"
cat > "$STUBDIR/claude" << EOF
#!/bin/sh
echo "\$@" > $MARKER
EOF
chmod +x "$STUBDIR/claude"

# Instance shells inherit the suite env: the stub claude wins the PATH
# race, and the fixture store replaces the developer's real ~/.cmuxterm.
export PATH="$STUBDIR:$PATH"
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR)

start_xvfb
start_instance || exit 2

# --- phase A: record a fake agent session against the live surface ------
SID=$(v2 '{"id":1,"method":"surface.list"}' \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['surfaces'][0]['id'])")
[ -n "$SID" ] && ok "got the live surface uuid" || bad "surface uuid" "empty"

cat > "$FIXDIR/claude-hook-sessions.json" << EOF
{
  "version": 1,
  "sessions": {
    "ses_smoke1": { "isRestorable": true, "agentLifecycle": "idle", "updatedAt": 100 }
  },
  "activeSessionsBySurface": {
    "$SID": { "sessionId": "ses_smoke1", "updatedAt": 100 }
  },
  "activeSessionsByWorkspace": {}
}
EOF

force_save && ok "session saved" || bad "session.save" "no saved marker"

# --- phase B: restart onto the same session — the resume command runs ---
kill_instance
start_instance || exit 2

found=""
for _ in $(seq 1 30); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
if [ "$found" = "yes" ]; then
    ok "stub agent ran on restore"
    expect "resume command carries the recorded session id" \
        "--resume ses_smoke1" "$(cat "$MARKER")"
else
    bad "auto-resume" "marker never appeared (stub claude did not run)"
    bad "resume command" "no marker to inspect"
fi

# --- phase C: the setting suppresses it ---------------------------------
rm -f "$MARKER"
kill_instance
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR CMUX_AUTO_RESUME=0)
start_instance || exit 2
sleep 4
[ ! -f "$MARKER" ] && ok "CMUX_AUTO_RESUME=0 suppresses the resume" \
    || bad "auto-resume off" "stub ran despite CMUX_AUTO_RESUME=0: $(cat "$MARKER")"

rm -rf "$FIXDIR" "$STUBDIR"
rm -f "$MARKER"
finish
