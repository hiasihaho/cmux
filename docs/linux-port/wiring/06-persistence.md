# ⑦ Session & scrollback

What survives a restart, and the two-file design that makes "keep all
scrollback" affordable. The port deliberately diverges from macOS here —
WebKitGTK's native session blob and out-of-band scrollback beat the
mac's shadow-stack emulation.

## What persists

```mermaid
flowchart LR
    model["live model"] --> save["SessionStore.saveIfChanged<br/>(scene body, mtime-gated)"]
    save --> sessionjson["session.json (schema v3)<br/>flat surfaces[] + layout tree"]
    sessionjson --> l1["window / workspace / pane layout"]
    sessionjson --> l2["working directories"]
    sessionjson --> l3["browser URL + nav history + zoom"]
    sessionjson --> l4["divider positions (fractions)"]
    sessionjson --> l5["per-surface tab titles (pinned)"]

    save -.->|"per surface, SEPARATE file"| sbdir["dirname(session)/scrollback/<br/>&lt;surfaceId&gt;.txt"]
```

Scrollback lives **out of band** — one file per surface next to the
session — because the session JSON is rewritten on every model change;
inline text made every line of terminal output rewrite the whole
document (327 KB per save in a real dev session). Out of band, the limit
is configurable up to unlimited (`CMUX_SCROLLBACK_LIMIT=0`).

## The exit save (why output isn't lost)

```mermaid
flowchart TB
    output["terminal output"] -.->|"NOT a model change"| gap["only saved on the 15s timer"]
    gap --> risk["run ls, close in 3s → output gone"]
    close["window close (WM_DELETE_WINDOW)"] --> hook["SessionExitSave close-request hook"]
    hook --> final["one final save while<br/>terminals are still alive"]
    final --> forced["capture(force:true)<br/>bypasses the 2s read throttle"]
    forced --> sbdir["scrollback files current"]

    style risk fill:#f8514922,stroke:#f85149
    style final fill:#2ea04322,stroke:#2ea043
```

The close must be the *polite* one — `xdotool windowclose` calls
XDestroyWindow and bypasses `close-request`, which cost a debugging
round and is why the suite uses a real `WM_DELETE_WINDOW` C helper.

## Restore & replay

```mermaid
flowchart TB
    launch["instance starts"] --> read["read session.json"]
    read --> build["rebuild windows / panes / cwds"]
    build --> park["park scrollback text<br/>TerminalScrollbackStore.pending[surfaceId]"]
    park --> poll["startReplay: restartable poll"]
    poll --> mapped{"pane MAPPED?<br/>(gtk_widget_get_mapped)"}
    mapped -->|no, background ws| wait["stay pending;<br/>each view-sync restarts the poll"]
    mapped -->|yes| inject["write_display(replayPayload)<br/>parsed as terminal OUTPUT, not input"]
    wait -.->|"workspace finally selected"| mapped

    style inject fill:#2ea04322,stroke:#2ea043
```

Two lessons baked in: replay is gated on the pane being **mapped** (an
unmapped background pane's write silently succeeds into a terminal that
has not started, losing the text), and `replayPayload` normalizes
**LF→CRLF** — `read_text` returns bare-LF rows and `inject_output` feeds
the parser directly, where LF means "down a row" without a return, so
un-normalized text staircases off to the right. macOS gets the CR free
via the pty's ONLCR discipline; bypassing the pty is the port's speed,
and this is the bill.

Ghostty and VTE both capture/replay now (VTE via
`get_text_range_format` + `feed`); the CRLF normalization is
backend-agnostic in `replayPayload`, so the staircase lesson carried
over for free.
