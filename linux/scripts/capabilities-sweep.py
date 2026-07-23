#!/usr/bin/env python3
"""Diff the v2 methods the shared CLI can SEND against what the Linux
server DISPATCHES.

Run after every upstream merge:

    linux/scripts/capabilities-sweep.py

The quiet-rename class is the reason this exists: after the 2026-07-22
catch-up merge, `cmux notify` silently failed for a day because upstream
renamed the method it sends (notification.create_for_caller) — the CLI
printed an error only agents ever saw. A method in this report is not
necessarily work to do (most are macOS-only features that error
honestly); the dangerous ones are methods sent by COMMANDS THE PORT
CLAIMS TO SUPPORT — check new entries against PARITY.md.

Also self-checks the server's ADVERTISED capability list (the hardcoded
`"methods"` array in system.capabilities) against what the dispatcher
actually handles, in both directions, and exits 1 on drift. Added
2026-07-24 after the list was found 16 methods stale (browser.tab.*,
browser.profiles.*, pane.zoom, …) — agents that introspect capabilities
were under-told what the port can do.
"""
import re
import glob
import os
import sys
from collections import defaultdict

import capslib

root = capslib.ROOT
os.chdir(root)

sent = capslib.cli_sent()
served = capslib.linux_served()

missing = sorted(m for m in sent - served if "." in m)

# The v1 dimension: verbs sent as plain socket lines (sendV1Command).
# Found the hard way — `list-windows` and `reload-config` were quietly
# broken while the v2-only sweep reported all clear.
v1_sent = set()
for f in glob.glob("CLI/*.swift"):
    src = open(f).read()
    v1_sent |= set(re.findall(r'sendV1Command\("([a-z_]+)', src))
    v1_sent |= set(re.findall(r'socketCmd\s*=\s*"([a-z_]+)"', src))
v1_served = set(re.findall(r'case "([a-z_]+)":', open("linux/Sources/CmuxAdw/ControlProtocol.swift").read()))
v1_missing = sorted(v1_sent - v1_served)
print(f"CLI sends {len(sent)} v2 methods; server dispatches {len(served & sent)} of them; missing: {len(missing)}")
groups = defaultdict(list)
for m in missing:
    groups[m.split(".")[0]].append(m)
for prefix in sorted(groups):
    print(f"\n[{prefix}] ({len(groups[prefix])})")
    for m in groups[prefix]:
        print(f"  {m}")

if v1_missing:
    print(f"\n[v1 verbs] ({len(v1_missing)})")
    for m in v1_missing:
        print(f"  {m}")

# Self-check: the advertised system.capabilities list must match what the
# dispatcher handles. Everything above is informational (macOS-only verbs
# error honestly); THIS is a hard failure — a stale advertised list lies
# to agents that introspect capabilities before calling.
advertised = capslib.linux_advertised()
served_v2 = served
unadvertised = sorted(served_v2 - advertised)
undispatched = sorted(advertised - served_v2)
drift = False
if unadvertised:
    drift = True
    print(f"\n[DRIFT] dispatched but not advertised in system.capabilities ({len(unadvertised)})")
    for m in unadvertised:
        print(f"  {m}")
if undispatched:
    drift = True
    print(f"\n[DRIFT] advertised in system.capabilities but not dispatched ({len(undispatched)})")
    for m in undispatched:
        print(f"  {m}")
if drift:
    print("\nFix the \"methods\" array in ControlProtocol.swift (system.capabilities).")
    sys.exit(1)
print("\ncapabilities self-check: advertised list matches dispatcher")
sys.exit(0)
