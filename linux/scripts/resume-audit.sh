#!/usr/bin/env bash
# Which agent sessions would auto-resume at the next restore/promote?
# Thin formatter over the `debug.resume_plan` verb — the app answers with
# its REAL resolver (AgentResume.resumeCommand), so this instrument can
# never drift from the code it audits. Targets the caller's instance;
# point CMUX_SOCKET_PATH elsewhere for dev/scratch instances.
#
#   linux/scripts/resume-audit.sh
set -euo pipefail
SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
python3 - "$SOCK" << 'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b'{"id":1,"method":"debug.resume_plan"}\n')
d = b""
while not d.endswith(b"\n"):
    c = s.recv(65536)
    if not c: break
    d += c
reply = json.loads(d)
if "result" not in reply:
    msg = reply.get("error", {}).get("message", "no result")
    print(f"instance cannot answer ({msg}) — it predates debug.resume_plan; promote/restart onto the current binary")
    sys.exit(1)
r = reply["result"]
print(f"auto-resume: {'ON' if r['auto_resume_enabled'] else 'OFF'}")
rows = r["surfaces"]
resuming = [x for x in rows if x.get("resume_command")]
print(f"{len(rows)} terminal surfaces, {len(resuming)} would resume:\n")
for x in rows:
    cmd = x.get("resume_command")
    mark = f"RESUMES  {cmd}" if cmd else "plain shell"
    print(f"  {x['workspace_ref']:>13}  {x['title'][:32]:<34} {mark}")
PY
