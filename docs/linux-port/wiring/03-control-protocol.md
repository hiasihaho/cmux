# ④ Control protocol — CLI ↔ socket ↔ dispatch

Everything an agent, shortcut, or the human's UI does eventually becomes
a socket message the server dispatches. The CLI is **shared with macOS**;
only the server side is Linux code, and the wire format is identical — so
`cmux <anything>` behaves the same on both platforms.

## The round trip

```mermaid
sequenceDiagram
    participant P as pane shell / agent
    participant C as cmux CLI (shared)
    participant S as ControlSocketServer
    participant H as ControlCommandHandler
    P->>C: cmux browser open …
    Note over C: resolve handles (surface:2 → uuid),<br/>pick v1 line or v2 JSON, frame it
    C->>S: connect unix socket, write one line
    S->>S: handleConnection (per-fd thread)
    S->>H: dispatchOnMainLoop(line)
    Note over H: handle() → v1 or v2 by shape
    H-->>S: response line (JSON or plain)
    S-->>C: write reply, close
    C-->>P: printed result / --json
```

The server reads whole lines on a per-connection thread
(`ControlSocketServer.handleConnection`) but hops every command onto the
**GTK main loop** (`dispatchOnMainLoop`) before touching the model —
the model and all widgets are main-loop-only.

## Two protocol generations

```mermaid
flowchart TB
    line["one socket line"] --> shape{"starts with '{' ?"}
    shape -->|yes| v2["handleV2<br/>JSON: {id, method, params}"]
    shape -->|no| v1["handleV1<br/>space-split verb + args"]
    v2 --> sync{"needs async?<br/>(browser nav, dialogs)"}
    sync -->|no| v2sync["handleV2Sync → switch(method)"]
    sync -->|yes| v2async["respond later<br/>(navigation barrier, file dialogs)"]
    v1 --> v1verbs["ping, list-workspaces,<br/>list-windows, reload-config,<br/>notify_target, …"]

    style v2 fill:#1f6feb22,stroke:#1f6feb
    style v1 fill:#8957e522,stroke:#8957e5
```

**v2** (JSON) is the modern surface — `system.*`, `surface.*`, `pane.*`,
`browser.*`, `notification.*`, `workspace.*`. **v1** (plain lines) is the
legacy surface the CLI still uses for a handful of verbs and the tmux
shim's fast paths. The capabilities sweep scans **both** — a rename can
hide in either generation (that is how `cmux notify` and `list-windows`
silently broke after the upstream merge).

## Peer credentials (the security boundary)

```mermaid
flowchart LR
    conn["incoming connection"] --> cred["SO_PEERCRED<br/>→ peer uid/pid"]
    cred --> proc["/proc/&lt;pid&gt;/stat<br/>ancestry walk"]
    proc --> decide{"same user,<br/>expected ancestry?"}
    decide -->|yes| allow["dispatch"]
    decide -->|no| deny["reject"]
```

The port re-implements macOS's `LOCAL_PEERCRED`/sysctl boundary with
Linux `SO_PEERCRED` + `/proc` ancestry — same guarantee (only the
owning user's processes drive the socket), different syscalls. This is
in the shared CLI's Linux compat layer, ported during the catch-up merge.

## The capabilities sweep (a standing tripwire)

```mermaid
flowchart LR
    cli["shared CLI source"] -->|"extract every<br/>method it can SEND"| sendable["212 v2 + v1 methods"]
    server["Linux server"] -->|"extract every<br/>method it DISPATCHES"| handled["handled set"]
    sendable --> diff["capabilities-sweep.py<br/>diff"]
    handled --> diff
    diff --> renames["quiet renames of<br/>CLAIMED features → fix now"]
    diff --> gaps["honest macOS-only<br/>methods → unknown_method"]

    style renames fill:#f8514922,stroke:#f85149
```

Run after every upstream merge (`linux/scripts/capabilities-sweep.py`).
The red class — the CLI quietly changing what it dials while both ends
look healthy — now has a permanent guard.
