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

# BACKEND MATRIX. Resume delivery differs per backend — eager background
# spawn is Ghostty-only, so a VTE pane that is never shown has no shell
# to type into. This suite used to test whichever backend happened to be
# LINKED, so it went green on VTE while the Ghostty path was unproven
# (and vice versa) — 2026-08-20. Run every backend the binary supports.
if [ -z "${CMUX_SUITE_BACKEND:-}" ]; then
    _backends=(vte)
    ldd "$(dirname "$0")/../.build/debug/cmux-adw" 2>/dev/null \
        | grep -q libghostty-gtk && _backends=(ghostty vte)
    _rc=0
    for _b in "${_backends[@]}"; do
        echo "== $SUITE_NAME: backend $_b"
        CMUX_SUITE_BACKEND="$_b" "$0" "$@" || _rc=1
    done
    exit "$_rc"
fi

source "$(dirname "$0")/lib.sh"

FIXDIR=/tmp/cmux-resumetest-hooks
STUBDIR=/tmp/cmux-resumetest-bin
MARKER=/tmp/cmux-resumetest-marker
rm -rf "$FIXDIR" "$STUBDIR"
rm -f "$MARKER" "$SESSION"
mkdir -p "$FIXDIR" "$STUBDIR"
for stub in claude kimi hermes; do
    cat > "$STUBDIR/$stub" << EOF
#!/bin/sh
echo "$stub \$@" > $MARKER
EOF
    chmod +x "$STUBDIR/$stub"
done

# Instance shells inherit the suite env: the stub claude wins the PATH
# race, and the fixture store replaces the developer's real ~/.cmuxterm.
export PATH="$STUBDIR:$PATH"
# SHELL=/bin/sh keeps the VTE path rc-free, but Ghostty spawns the passwd
# shell as a LOGIN shell and reads ~/.bashrc regardless — which prepends
# the real agent dirs (~/.kimi-code/bin) ahead of the stubs, so the real
# kimi answered the resume and the leg failed (2026-08-18 via VTE,
# 2026-08-20 again via Ghostty). A throwaway HOME has no rc files at all,
# which is the only version of this that holds for BOTH backends.
STUBHOME="$FIXDIR/home"
mkdir -p "$STUBHOME"
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR SHELL=/bin/sh HOME=$STUBHOME
              CMUX_TERM=$CMUX_SUITE_BACKEND)

jfield() { python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

# One hermes hook record pointing this suite's live surface at <session id>.
write_hermes_record() {
    python3 -c "
import json, sys
sid, surface, path = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
    'version': 1,
    'sessions': {sid: {'isRestorable': True, 'agentLifecycle': 'idle', 'updatedAt': 100}},
    'activeSessionsBySurface': {surface: {'sessionId': sid, 'updatedAt': 100}},
    'activeSessionsByWorkspace': {},
}, open(path, 'w'))" "$1" "$SID" "$FIXDIR/hermes-agent-hook-sessions.json"
}

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
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR SHELL=/bin/sh HOME=$STUBHOME
              CMUX_TERM=$CMUX_SUITE_BACKEND CMUX_AUTO_RESUME=0)
start_instance || exit 2
sleep 4
[ ! -f "$MARKER" ] && ok "CMUX_AUTO_RESUME=0 suppresses the resume" \
    || bad "auto-resume off" "stub ran despite CMUX_AUTO_RESUME=0: $(cat "$MARKER")"

# --- phase C: hermes resumes under the PROFILE that owns the session ----
# Restore the resume-enabled env: the phase above deliberately turns
# auto-resume OFF, and inheriting that made both legs fail with
# "marker never appeared" (found while writing them).
INSTANCE_ENV=(CMUX_HOOK_SESSIONS_DIR=$FIXDIR SHELL=/bin/sh HOME=$STUBHOME
              CMUX_TERM=$CMUX_SUITE_BACKEND)
# Hermes keeps one session store per profile, so `hermes --resume <id>`
# under the default profile does not find a profile session at all — it
# says "session not found", which reads like data loss and is not. The
# id lives INSIDE the session file, not in its name, so the resolver
# matches on content.
rm -f "$MARKER" "$FIXDIR"/*-hook-sessions.json
kill_instance
HSID="20260903_014455_ab12cd"
# The LIVE shape, verified against a real profile session (2026-09-03):
# an extensionless per-tty pointer under terminal-sessions/. Scanning
# only sessions/ missed a session that had just run for ten minutes.
mkdir -p "$STUBHOME/.hermes/profiles/cmuxdesk/terminal-sessions"
cat > "$STUBHOME/.hermes/profiles/cmuxdesk/terminal-sessions/tty-dev-pts-9" << HJSON
{"session_id": "$HSID", "cwd": "/home/hias/cmux", "ts": 1788395111.76}
HJSON
# And the saved-conversation shape, which is a real .json under sessions/.
SSID="20260903_015500_beef01"
mkdir -p "$STUBHOME/.hermes/profiles/deskarchive/sessions/saved"
cat > "$STUBHOME/.hermes/profiles/deskarchive/sessions/saved/hermes_conversation_20260903_010203.json" << HJSON
{"model": "kimi-k3", "session_id": "$SSID", "messages": []}
HJSON
write_hermes_record "$HSID"
start_instance || exit 2
found=""
for _ in $(seq 1 30); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
if [ "$found" = "yes" ]; then
    expect "hermes resumes under the owning profile" \
        "hermes -p cmuxdesk --resume $HSID" "$(cat "$MARKER")"
else
    bad "hermes profile resume" "marker never appeared"
fi

# The saved-conversation store resolves as well (different profile, so a
# pass here cannot be the previous leg's fixture answering).
rm -f "$MARKER"
kill_instance
write_hermes_record "$SSID"
start_instance || exit 2
found=""
for _ in $(seq 1 30); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
if [ "$found" = "yes" ]; then
    expect "a saved conversation resolves its profile too" \
        "hermes -p deskarchive --resume $SSID" "$(cat "$MARKER")"
else
    bad "hermes saved-session resume" "marker never appeared"
fi

# And an id no profile claims must NOT acquire a -p flag.
rm -f "$MARKER"
kill_instance
DSID="20260903_020202_ffffff"
write_hermes_record "$DSID"
start_instance || exit 2
found=""
for _ in $(seq 1 30); do
    [ -f "$MARKER" ] && { found=yes; break; }
    sleep 0.5
done
if [ "$found" = "yes" ]; then
    expect "an unclaimed id keeps the plain hermes command" \
        "hermes --resume $DSID" "$(cat "$MARKER")"
else
    bad "hermes default resume" "marker never appeared"
fi

rm -rf "$FIXDIR" "$STUBDIR"
rm -f "$MARKER"
finish
