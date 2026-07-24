# ② Instance topology & sockets

How many cmux processes run, how they stay isolated, and which socket
each answers on. This is the safety model the whole self-hosting
workflow rests on: *the agent develops the port from inside a running
instance of it*, so "which process am I talking to" is never academic.

## The processes

```mermaid
flowchart TB
    subgraph daily_p["daily — the human's instance (and the agent's host)"]
        daily["cmux-adw<br/>CMUX_APP_ID = com.manaflow.cmux<br/>socket = $XDG_RUNTIME_DIR/cmux.sock"]
    end
    subgraph dev_p["dev / dev2 — isolated test slots"]
        dev["cmux-adw<br/>CMUX_APP_ID = …cmux.dev<br/>socket = /tmp/cmux-dev.sock"]
    end
    subgraph scratch_p["scratch-&lt;tag&gt; — ad-hoc probes & screenshots"]
        scratch["cmux-adw<br/>CMUX_APP_ID = …cmux.scratch-&lt;tag&gt;<br/>socket = /tmp/cmux-scratch-&lt;tag&gt;.sock<br/>own Xvfb :140-:159<br/>watch: x11vnc+noVNC :N→6900+N → pane in the caller (ADR-0010)"]
    end

    swiftbuild["swift build"] -->|"replaces binary ON DISK<br/>(running procs unaffected)"| binary["linux/.build/debug/cmux-adw"]
    binary -.->|"promote.sh restarts"| daily
    binary -.->|"start.sh dev"| dev
    binary -.->|"scratch.sh start"| scratch

    style daily_p fill:#1f6feb22,stroke:#1f6feb
    style dev_p fill:#2ea04322,stroke:#2ea043
    style scratch_p fill:#8957e522,stroke:#8957e5
```

**Prime directive:** never kill the daily — the agent's shell is a pane
of it and dies with it. `swift build` is always safe (it only rewrites
the on-disk binary); the running process keeps its old code until an
approved restart.

## Identity comes from the environment

Three env vars make an instance a distinct universe. Set them and you
get a parallel cmux; forget one and you collide with the daily.

```mermaid
flowchart LR
    env["launch env"] --> a["CMUX_APP_ID<br/>→ GTK application id<br/>(CmuxApp.swift:12)"]
    env --> b["CMUX_SOCKET_PATH<br/>→ control socket<br/>(ControlSocketServer.swift:34)"]
    env --> c["CMUX_SESSION_PATH<br/>→ session JSON +<br/>dirname/scrollback/"]
    a --> iso["isolated instance"]
    b --> iso
    c --> iso
    c -.->|"NEVER /tmp: scrollback dir<br/>is pruned on save"| warn["a /tmp session<br/>deletes suite captures"]
```

Socket resolution order (`ControlSocketServer.defaultSocketPath`):
`CMUX_SOCKET_PATH` override → `$XDG_RUNTIME_DIR/cmux.sock` → `/tmp/cmux-$(uid).sock`.
macOS uses a fixed `/tmp/cmux.sock`; the port follows XDG instead.

## Who may kill whom

The one rule that keeps the self-hosting loop safe: **kill strictly by
`CMUX_APP_ID` match in `/proc/<pid>/environ`, never by process name.**
`pkill -f cmux-adw` also matches the agent's own shell command line —
it has bitten twice.

```mermaid
flowchart TB
    want["stop instance X"] --> loop["for pid in pgrep -x cmux-adw"]
    loop --> check{"/proc/pid/environ<br/>has CMUX_APP_ID=X ?"}
    check -->|yes| kill["kill pid"]
    check -->|no| skip["leave it — could be the daily"]
```

Every wrapper encodes this: `scratch.sh stop`, `promote.sh`, the test
harness teardown, and the manual `for pid in $(pgrep -x cmux-adw)` loops
in the briefing all match on the app-id, never the name.

## Terminal panes inherit the socket

A shell spawned into any surface gets `CMUX_SOCKET_PATH`,
`CMUX_WORKSPACE_ID`, and `CMUX_SURFACE_ID` in its environment
(`TerminalSurfaces.swift:84`, `GhosttySurfaces.swift:74`) — so a bare
`cmux` command inside a pane targets *its own* instance and identifies
*its own* pane, with no flags. That inheritance is exactly what the
tmux shim rides on (see ③).
