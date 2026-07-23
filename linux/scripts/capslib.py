"""Shared capability parsing for the tripwire scripts.

One home for "what does the CLI send / the Linux server dispatch and
advertise / macOS have", so capabilities-sweep.py and features-board.py
measure the same reality instead of each keeping its own copy of the
regexes and file lists (the drift class these tools exist to catch).

All functions parse SOURCE, not a running instance, so they work in any
checkout. Names are v2 methods (dotted); v1 verbs are excluded.
"""
import glob
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Every Linux server file that dispatches v2 methods (case labels or
# `method == "..."` guards). Keep in sync with the dispatcher includes.
SERVER_FILES = [
    "linux/Sources/CmuxAdw/ControlProtocol.swift",
    "linux/Sources/CmuxAdw/BrowserAutomation.swift",
    "linux/Sources/CmuxAdw/BrowserSurfaces.swift",
    "linux/Sources/CmuxAdw/BrowserFind.swift",
    "linux/Sources/CmuxAdw/PaneSearch.swift",
    "linux/Sources/CmuxAdw/BrowserWebDriver.swift",
    "linux/Sources/CmuxAdw/InspectorSurfaces.swift",
]

MAC_SERVER = "Sources/TerminalController.swift"


def _read(path):
    with open(os.path.join(ROOT, path)) as f:
        return f.read()


def cli_sent():
    """v2 methods the shared CLI can send (CLI/*.swift)."""
    sent = set()
    for f in glob.glob(os.path.join(ROOT, "CLI/*.swift")):
        src = open(f).read()
        sent |= set(re.findall(r'method:\s*"([a-z_][a-z0-9_.]*)"', src))
        sent |= set(re.findall(r'method\s*=\s*"([a-z_][a-z0-9_.]*)"', src))
    return {m for m in sent if "." in m}


def linux_served():
    """v2 methods the Linux server dispatches (case labels incl. aliases)."""
    served = set()
    for f in SERVER_FILES:
        src = _read(f)
        # `case "a", "b":` lines list every alias; split them out.
        for line in re.findall(r'case ("[a-z_][a-z0-9_.", ]*"):', src):
            served |= set(re.findall(r'"([a-z_][a-z0-9_.]*)"', line))
        served |= set(re.findall(r'method == "([a-z_][a-z0-9_.]*)"', src))
    return {m for m in served if "." in m}


def linux_advertised():
    """The hardcoded system.capabilities methods array on the Linux side."""
    m = re.search(r'"methods": \[(.*?)\]', _read(SERVER_FILES[0]), re.S)
    if not m:
        return set()
    return set(re.findall(r'"([a-z_][a-z0-9_.]*)"', m.group(1)))


def mac_advertised():
    """The hardcoded capabilities array on the macOS side (v2Capabilities)."""
    m = re.search(
        r'func v2Capabilities\(\).*?var methods: \[String\] = \[(.*?)\]\n',
        _read(MAC_SERVER), re.S)
    if not m:
        return set()
    return {x for x in re.findall(r'"([a-zA-Z_][a-zA-Z0-9_.]*)"', m.group(1))
            if "." in x}


def mac_served():
    """Dotted case labels + `method == "..."` guards across ALL macOS app
    sources. Broad on purpose (dispatch is spread over TerminalController
    extensions, VMClientSocketCommands, …); unrelated dotted switches
    (settings key paths) can add strays — harmless for the board, which
    only looks up the verbs feature pages actually list."""
    served = set()
    for f in glob.glob(os.path.join(ROOT, "Sources/**/*.swift"), recursive=True):
        src = open(f).read()
        for line in re.findall(r'case ("[a-z_][a-z0-9_.", ]*"):', src):
            served |= set(re.findall(r'"([a-z_][a-z0-9_.]*)"', line))
        served |= set(re.findall(r'method == "([a-z_][a-z0-9_.]*)"', src))
    return {m for m in served if "." in m}


def mac_methods():
    """v2 methods the macOS server has: advertised ∪ dispatched. NOT
    unioned with cli_sent() — the shared CLI carries Linux-added verbs
    (pane.zoom, session.save) that upstream's server doesn't serve, and
    counting them as macOS-present is exactly the lie the features board
    exists to avoid. Known limitation: methods dispatched without a
    string case label anywhere (canvas.* seems name-mapped dynamically)
    read as absent — investigate before authoring a page over them."""
    return mac_advertised() | mac_served()
