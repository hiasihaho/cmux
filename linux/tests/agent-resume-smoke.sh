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
for stub in claude kimi hermes codex; do
    cat > "$STUBDIR/$stub" << EOF
#!/bin/sh
echo "$stub \$@" > $MARKER
# RR-HOME: record the directory the resumed agent actually landed in, so
# a cwd-prefix (cd <hook-cwd> && …) is proven by the agent's real pwd,
# not merely inspected in the plan string.
pwd > $MARKER.pwd
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

# --- phase RR-HOME: the resumed agent lands in its RECORDED cwd ---------
# GAP (b), the "bare shell in $HOME" shape: an agent whose pane restored
# at a DIFFERENT directory than the agent's own recorded cwd must still
# resume INTO its cwd. macOS prefixes `cd <cwd> && <resume>`; Linux did
# not, so the agent ran wherever the shell happened to be. Two proofs:
# the plan string carries the prefix, AND the resumed stub's real pwd is
# the recorded dir. RR3: covered for both claude and codex (two kinds).
rm -f "$MARKER" "$MARKER.pwd" "$FIXDIR"/*-hook-sessions.json
kill_instance
# The workspace restores at /tmp (via new-workspace below), but the agent
# was working in /etc — the two deliberately diverge.
start_instance || exit 2
RH_SID=$(v2 '{"id":1,"method":"surface.list"}' | jfield "['result']['surfaces'][0]['id']")
RHU="22222222-3333-4444-8555-666666666666"
cat > "$FIXDIR/claude-hook-sessions.json" << EOF
{ "version": 1,
  "sessions": { "$RHU": { "isRestorable": true, "agentLifecycle": "idle", "updatedAt": 200, "cwd": "/etc" } },
  "activeSessionsBySurface": { "$RH_SID": { "sessionId": "$RHU", "updatedAt": 200 } },
  "activeSessionsByWorkspace": {} }
EOF
force_save
plan=$(v2 '{"id":2,"method":"debug.resume_plan"}')
expect "RR-HOME: plan carries a cd-prefix to the recorded cwd" \
    "cd '/etc' || [ ! -d '/etc' ] && claude --resume $RHU" \
    "$(echo "$plan" | jfield "['result']['surfaces'][0].get('resume_command','')")"
# and prove it end to end: the resumed stub's real pwd is /etc
kill_instance
start_instance || exit 2
found=""
for _ in $(seq 1 30); do [ -f "$MARKER.pwd" ] && { found=yes; break; }; sleep 0.5; done
if [ "$found" = "yes" ]; then
    expect "RR-HOME: resumed agent's real pwd is the recorded cwd" "/etc" "$(cat "$MARKER.pwd")"
else
    bad "RR-HOME pwd" "stub never ran"
fi

# --- phase RR-CODEX: gap (b) holds for a SECOND agent kind (RR3) --------
rm -f "$MARKER" "$MARKER.pwd" "$FIXDIR"/*-hook-sessions.json
kill_instance
start_instance || exit 2
RC_SID=$(v2 '{"id":1,"method":"surface.list"}' | jfield "['result']['surfaces'][0]['id']")
RCU="cccccccc-3333-4444-8555-666666666666"
cat > "$FIXDIR/codex-hook-sessions.json" << EOF
{ "version": 1,
  "sessions": { "$RCU": { "agentLifecycle": "idle", "updatedAt": 200, "cwd": "/usr" } },
  "activeSessionsBySurface": { "$RC_SID": { "sessionId": "$RCU", "updatedAt": 200 } },
  "activeSessionsByWorkspace": {} }
EOF
force_save
plan=$(v2 '{"id":2,"method":"debug.resume_plan"}')
expect "RR-CODEX: codex resume also carries the cd-prefix" \
    "cd '/usr' || [ ! -d '/usr' ] && codex resume $RCU" \
    "$(echo "$plan" | jfield "['result']['surfaces'][0].get('resume_command','')")"
# RR3 executed evidence (helper cross-check): not the plan string — the
# codex stub REALLY ran (argv proves the session id) in its recorded cwd
# (real pwd), for a second agent kind.
kill_instance
start_instance || exit 2
found=""
for _ in $(seq 1 30); do [ -f "$MARKER.pwd" ] && { found=yes; break; }; sleep 0.5; done
if [ "$found" = "yes" ]; then
    expect "RR-CODEX: codex stub really ran with its session id" \
        "codex resume $RCU" "$(cat "$MARKER")"
    expect "RR-CODEX: codex stub's real pwd is the recorded cwd" "/usr" "$(cat "$MARKER.pwd")"
else
    bad "RR-CODEX exec" "codex stub never ran"; bad "RR-CODEX pwd" "no marker"
fi

# --- phase RR-GONE: a VANISHED cwd never blocks resume -----------------
# A cd-prefix to a missing directory would abort the resume entirely —
# worse than a bare shell. So a non-existent recorded cwd falls back to
# the bare command.
rm -f "$FIXDIR"/*-hook-sessions.json
kill_instance
start_instance || exit 2
RG_SID=$(v2 '{"id":1,"method":"surface.list"}' | jfield "['result']['surfaces'][0]['id']")
RGU="99999999-3333-4444-8555-666666666666"
cat > "$FIXDIR/claude-hook-sessions.json" << EOF
{ "version": 1,
  "sessions": { "$RGU": { "isRestorable": true, "agentLifecycle": "idle", "updatedAt": 200, "cwd": "/no/such/dir/xyzzy" } },
  "activeSessionsBySurface": { "$RG_SID": { "sessionId": "$RGU", "updatedAt": 200 } },
  "activeSessionsByWorkspace": {} }
EOF
force_save
plan=$(v2 '{"id":2,"method":"debug.resume_plan"}')
expect "RR-GONE: a vanished cwd falls back to the bare command" \
    "claude --resume $RGU" \
    "$(echo "$plan" | jfield "['result']['surfaces'][0].get('resume_command','')")"


# --- phase RR-SWAP: the index must not cross two same-kind sessions -----
# helper cross-check (2026-09-11): the resolver trusted
# activeSessionsBySurface BLINDLY and never checked the record's own
# surfaceId. Cross two same-kind sessions' index entries and each surface
# resumes the OTHER's session. The fix honours an index entry only when the
# record it points at names THIS surface; on a mismatch it falls back to the
# surfaceId record-scan and recovers this surface's own session. Real
# executed presence: the resumed stub's argv (session id) AND pwd (that
# session's recorded cwd) — not the plan string alone.
rm -f "$MARKER" "$MARKER.pwd" "$FIXDIR"/*-hook-sessions.json
kill_instance
start_instance || exit 2
RS_SID=$(v2 '{"id":1,"method":"surface.list"}' | jfield "['result']['surfaces'][0]['id']")
RS_OWN="aaaaaaaa-1111-4111-8111-111111111111"       # belongs to THIS surface, cwd /etc
RS_FOREIGN="bbbbbbbb-2222-4222-8222-222222222222"    # belongs to ANOTHER surface, cwd /usr
RS_FOREIGN_SURFACE="cccccccc-3333-4333-8333-333333333333"
# MUTANT: the live surface's index entry points at the FOREIGN session,
# whose record says it belongs to RS_FOREIGN_SURFACE. Higher updatedAt too,
# so a naive newest-wins scan would also mispick it — only the surfaceId
# coupling gets this right.
cat > "$FIXDIR/claude-hook-sessions.json" << EOF
{ "version": 1,
  "sessions": {
    "$RS_OWN":     { "isRestorable": true, "agentLifecycle": "idle", "updatedAt": 300, "cwd": "/etc", "surfaceId": "$RS_SID" },
    "$RS_FOREIGN": { "isRestorable": true, "agentLifecycle": "idle", "updatedAt": 400, "cwd": "/usr", "surfaceId": "$RS_FOREIGN_SURFACE" }
  },
  "activeSessionsBySurface": { "$RS_SID": { "sessionId": "$RS_FOREIGN", "updatedAt": 400 } },
  "activeSessionsByWorkspace": {} }
EOF
force_save
plan=$(v2 '{"id":2,"method":"debug.resume_plan"}')
expect "RR-SWAP: a crossed index falls back to this surface's own session" \
    "cd '/etc' || [ ! -d '/etc' ] && claude --resume $RS_OWN" \
    "$(echo "$plan" | jfield "['result']['surfaces'][0].get('resume_command','')")"
kill_instance
start_instance || exit 2
found=""
for _ in $(seq 1 30); do [ -f "$MARKER.pwd" ] && { found=yes; break; }; sleep 0.5; done
if [ "$found" = "yes" ]; then
    expect "RR-SWAP: resumed the surface's OWN session (real argv)" \
        "claude --resume $RS_OWN" "$(cat "$MARKER")"
    expect "RR-SWAP: resumed in the OWN session's cwd (real pwd)" "/etc" "$(cat "$MARKER.pwd")"
else
    bad "RR-SWAP exec" "stub never ran"; bad "RR-SWAP pwd" "no marker"
fi
# positive control: an UNcrossed index still resumes via the index path
# (the coupling check must not break the normal case).
rm -f "$MARKER" "$MARKER.pwd"
kill_instance
python3 - "$FIXDIR/claude-hook-sessions.json" "$RS_SID" "$RS_OWN" << 'PY'
import json, sys
p, surface, own = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
d["activeSessionsBySurface"] = {surface: {"sessionId": own, "updatedAt": 300}}
json.dump(d, open(p, "w"))
PY
start_instance || exit 2
found=""
for _ in $(seq 1 30); do [ -f "$MARKER" ] && { found=yes; break; }; sleep 0.5; done
[ "$found" = "yes" ] \
    && expect "RR-SWAP control: a correct index still resumes its session" "claude --resume $RS_OWN" "$(cat "$MARKER")" \
    || bad "RR-SWAP control" "stub never ran"

# --- phase RR-SHELL: no restorable record => bare shell, agent absent ---
# The "bare shell in $HOME" strand shape: a surface restores but its agent
# never resumes. This leg bounds the presence oracle — a non-restorable
# record leaves ONLY the shell (agent absent), a restorable one brings the
# agent back — both proven by real executed presence (marker present/absent
# + argv). Part 2b makes the generic Stop write that flag for real; here the
# two states are fixtured to prove the oracle can tell them apart.
rm -f "$MARKER" "$MARKER.pwd" "$FIXDIR"/*-hook-sessions.json
kill_instance
start_instance || exit 2
RSH_SID=$(v2 '{"id":1,"method":"surface.list"}' | jfield "['result']['surfaces'][0]['id']")
RSH_U="dddddddd-4444-4444-8444-444444444444"
cat > "$FIXDIR/claude-hook-sessions.json" << EOF
{ "version": 1,
  "sessions": { "$RSH_U": { "isRestorable": false, "agentLifecycle": "idle", "updatedAt": 300 } },
  "activeSessionsBySurface": { "$RSH_SID": { "sessionId": "$RSH_U", "updatedAt": 300 } },
  "activeSessionsByWorkspace": {} }
EOF
force_save
kill_instance
start_instance || exit 2
sleep 5
[ ! -f "$MARKER" ] \
    && ok "RR-SHELL: a non-restorable record leaves a bare shell (agent absent)" \
    || bad "RR-SHELL absent" "agent resumed despite isRestorable:false: $(cat "$MARKER")"
python3 - "$FIXDIR/claude-hook-sessions.json" << 'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for r in d["sessions"].values(): r["isRestorable"] = True
json.dump(d, open(p, "w"))
PY
kill_instance
start_instance || exit 2
found=""
for _ in $(seq 1 30); do [ -f "$MARKER" ] && { found=yes; break; }; sleep 0.5; done
[ "$found" = "yes" ] \
    && expect "RR-SHELL control: a restorable record resumes the agent" "claude --resume $RSH_U" "$(cat "$MARKER")" \
    || bad "RR-SHELL control" "restorable record did not resume"


# --- phase STOP-WRITE: the generic Stop self-describes as restorable -----
# Part 2b/3, exercised through the REAL generic Stop hook (not a fabricated
# store): invoke `cmux hooks codex stop` against the live instance and prove
# it (a) writes isRestorable:true into the codex record (closing the measured
# claude-6/6 vs others-0/6 omission) and (b) appends a Part 3 audit line
# recording that a restorable record was written. CMUX_AGENT_HOOK_STATE_DIR is
# pinned to the fixture so the developer's ~/.cmuxterm is never touched.
rm -f "$FIXDIR"/*-hook-sessions.json "$FIXDIR/resume-stop-audit.jsonl"
kill_instance
start_instance || exit 2
SW_SID=$(v2 '{"id":1,"method":"surface.list"}' | jfield "['result']['surfaces'][0]['id']")
SW_U="eeeeeeee-5555-4555-8555-555555555555"
# Seed AFTER startup (so startup auto-resume cannot race the store) a codex
# record with NO isRestorable flag — the measured 0/6 shape.
cat > "$FIXDIR/codex-hook-sessions.json" << EOF
{ "version": 1,
  "sessions": { "$SW_U": { "agentLifecycle": "running", "updatedAt": 500, "cwd": "/tmp", "surfaceId": "$SW_SID" } },
  "activeSessionsBySurface": { "$SW_SID": { "sessionId": "$SW_U", "updatedAt": 500 } },
  "activeSessionsByWorkspace": {} }
EOF
echo "{\"session_id\":\"$SW_U\",\"cwd\":\"/tmp\"}" | \
  env CMUX_SOCKET_PATH=$SOCK CMUX_HOOK_SESSIONS_DIR=$FIXDIR CMUX_AGENT_HOOK_STATE_DIR=$FIXDIR \
      CMUX_SURFACE_ID=$SW_SID CMUX_WORKSPACE_ID=workspace:1 "$CLI" hooks codex stop >/dev/null 2>&1
expect "STOP-WRITE: generic codex Stop writes isRestorable:true" "True" \
    "$(python3 -c "import json;print(json.load(open('$FIXDIR/codex-hook-sessions.json'))['sessions'].get('$SW_U',{}).get('isRestorable'))" 2>/dev/null)"
expect "STOP-WRITE: Part 3 audit records a restorable write for codex" "yes" \
    "$(python3 -c "
import json
try:
    hit=[x for x in (json.loads(l) for l in open('$FIXDIR/resume-stop-audit.jsonl'))
         if x.get('sessionId')=='$SW_U' and x.get('restorable') is True and x.get('kind')=='codex']
    print('yes' if hit else 'no')
except Exception:
    print('no')" 2>/dev/null)"

rm -rf "$FIXDIR" "$STUBDIR"
rm -f "$MARKER" "$MARKER.pwd"
finish
