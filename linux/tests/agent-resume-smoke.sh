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
for stub in claude kimi; do
    cat > "$STUBDIR/$stub" << EOF
#!/bin/sh
echo "$stub \$@" > $MARKER
EOF
    chmod +x "$STUBDIR/$stub"
done

# Instance shells inherit the suite env: the stub claude wins the PATH
# race, and the fixture store replaces the developer's real ~/.cmuxterm.
export PATH="$STUBDIR:$PATH"
# SHELL=/bin/sh: rc-free shells, so the env PATH (stub first) survives —
# the real kimi lives in an rc-prepended dir and beat the stub otherwise
# (found 2026-08-18 when a debug instance popped a real kimi trust prompt).
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR SHELL=/bin/sh)

jfield() { python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

start_xvfb
start_instance || exit 2

# --- phase A: record a fake agent session against the live surface ------
SID=$(v2 '{"id":1,"method":"surface.list"}' \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['surfaces'][0]['id'])")
[ -n "$SID" ] && ok "got the live surface uuid" || bad "surface uuid" "empty"

CUUID="11111111-2222-4333-8444-555555555555"
cat > "$FIXDIR/claude-hook-sessions.json" << EOF
{
  "version": 1,
  "sessions": {
    "$CUUID": { "isRestorable": true, "agentLifecycle": "idle", "updatedAt": 100 }
  },
  "activeSessionsBySurface": {
    "$SID": { "sessionId": "$CUUID", "updatedAt": 100 }
  },
  "activeSessionsByWorkspace": {}
}
EOF

force_save && ok "session saved" || bad "session.save" "no saved marker"

# The debug.resume_plan verb answers with the REAL resolver against the
# fixture store — the resume-audit instrument's backend.
plan=$(v2 '{"id":2,"method":"debug.resume_plan"}')
expect "resume plan reports the pending resume" \
    "claude --resume $CUUID" \
    "$(echo "$plan" | jfield "['result']['surfaces'][0].get('resume_command','')")"

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
        "claude --resume $CUUID" "$(cat "$MARKER")"
else
    bad "auto-resume" "marker never appeared (stub claude did not run)"
    bad "resume command" "no marker to inspect"
fi

# --- phase B2: wrapper-written ses_ ids under claude are skipped --------
# (2026-08-18: claude-compatible wrappers record ses_<id> shapes through
# the claude hooks; resuming those with claude --resume would misfire, so
# only real UUID session ids resume under claude.)
rm -f "$MARKER"
kill_instance
python3 - "$FIXDIR/claude-hook-sessions.json" "$SID" << 'PY'
import json, sys
json.dump({
    "version": 1,
    "sessions": {"ses_wrapper1": {"isRestorable": True, "agentLifecycle": "idle", "updatedAt": 100}},
    "activeSessionsBySurface": {sys.argv[2]: {"sessionId": "ses_wrapper1", "updatedAt": 100}},
    "activeSessionsByWorkspace": {},
}, open(sys.argv[1], "w"))
PY
start_instance || exit 2
sleep 4
[ ! -f "$MARKER" ] && ok "non-UUID claude record is skipped" \
    || bad "claude UUID gate" "resumed a wrapper id: $(cat "$MARKER")"

# --- phase B3: kimi resumes via --session (verified 2026-08-18) ---------
rm -f "$MARKER" "$FIXDIR/claude-hook-sessions.json"
kill_instance
python3 - "$FIXDIR/kimi-hook-sessions.json" "$SID" << 'PY'
import json, sys
json.dump({
    "version": 1,
    "sessions": {"session_smoke42": {"isRestorable": True, "agentLifecycle": "idle", "updatedAt": 100}},
    "activeSessionsBySurface": {sys.argv[2]: {"sessionId": "session_smoke42", "updatedAt": 100}},
    "activeSessionsByWorkspace": {},
}, open(sys.argv[1], "w"))
PY
start_instance || exit 2
found=""
for _ in $(seq 1 30); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
if [ "$found" = "yes" ]; then
    ok "kimi stub ran on restore"
    expect "kimi resumes via --session" \
        "kimi --session session_smoke42" "$(cat "$MARKER")"
else
    bad "kimi auto-resume" "marker never appeared"
    bad "kimi resume command" "no marker to inspect"
fi

# --- phase B4: record-only stores (kimi SessionStart shape) -------------
# Kimi's hook writer creates the session record (with surfaceId) BEFORE
# filling activeSessionsBySurface — observed live 2026-08-18 right after
# hook install. The resolver must fall back to scanning records.
rm -f "$MARKER"
kill_instance
python3 - "$FIXDIR/kimi-hook-sessions.json" "$SID" << 'PY'
import json, sys
json.dump({
    "version": 1,
    "sessions": {"session_recordonly7": {
        "surfaceId": sys.argv[2], "agentLifecycle": "unknown", "updatedAt": 100}},
    "activeSessionsBySurface": {},
    "activeSessionsByWorkspace": {},
}, open(sys.argv[1], "w"))
PY
start_instance || exit 2
found=""
for _ in $(seq 1 30); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
if [ "$found" = "yes" ]; then
    ok "record-only store resumes via surfaceId fallback"
    expect "record-only resume carries the session id" \
        "kimi --session session_recordonly7" "$(cat "$MARKER")"
else
    bad "record-only fallback" "marker never appeared"
    bad "record-only command" "no marker to inspect"
fi

# --- phase C: the setting suppresses it ---------------------------------
rm -f "$MARKER"
kill_instance
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR SHELL=/bin/sh CMUX_AUTO_RESUME=0)
start_instance || exit 2
sleep 4
[ ! -f "$MARKER" ] && ok "CMUX_AUTO_RESUME=0 suppresses the resume" \
    || bad "auto-resume off" "stub ran despite CMUX_AUTO_RESUME=0: $(cat "$MARKER")"

rm -rf "$FIXDIR" "$STUBDIR"
rm -f "$MARKER"
finish
