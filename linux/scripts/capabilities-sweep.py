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
"""
import re
import glob
import os
import sys
from collections import defaultdict

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(root)

sent = set()
for f in glob.glob("CLI/*.swift"):
    src = open(f).read()
    sent |= set(re.findall(r'method:\s*"([a-z_][a-z0-9_.]*)"', src))
    sent |= set(re.findall(r'method\s*=\s*"([a-z_][a-z0-9_.]*)"', src))
sent = {m for m in sent if "." in m}

served = set()
SERVER_FILES = [
    "linux/Sources/CmuxAdw/ControlProtocol.swift",
    "linux/Sources/CmuxAdw/BrowserAutomation.swift",
    "linux/Sources/CmuxAdw/BrowserSurfaces.swift",
    "linux/Sources/CmuxAdw/BrowserFind.swift",
    "linux/Sources/CmuxAdw/PaneSearch.swift",
    "linux/Sources/CmuxAdw/BrowserWebDriver.swift",
    "linux/Sources/CmuxAdw/InspectorSurfaces.swift",
]
for f in SERVER_FILES:
    src = open(f).read()
    # `case "a", "b":` lines list every alias; split them out.
    for line in re.findall(r'case ("[a-z_][a-z0-9_.", ]*"):', src):
        served |= set(re.findall(r'"([a-z_][a-z0-9_.]*)"', line))
    served |= set(re.findall(r'method == "([a-z_][a-z0-9_.]*)"', src))

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

sys.exit(0)
