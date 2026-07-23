# ③ claude-teams / the tmux shim

The wiring that prompted this atlas. `cmux claude-teams` makes Claude
Code believe it is inside tmux, so when it spawns teammate agents they
land as **native cmux splits** instead of tmux panes. Verified
end-to-end on the port 2026-07-22; this session runs inside it.

## The redirect chain

```mermaid
flowchart LR
    launch["cmux claude-teams<br/>(shared CLI)"] -->|"writes"| shimdir["~/.cmuxterm/<br/>claude-teams-bin/tmux"]
    launch -->|"sets env + PATH prepend"| envset["TMUX, TMUX_PANE,<br/>CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1,<br/>CMUX_SOCKET_PATH"]
    launch -->|"exec"| claude["claude (real binary)"]

    claude -->|"issues tmux commands"| shim["the shim script<br/>(first tmux on PATH)"]
    shim -->|"exec cmux __tmux-compat …"| compat["__tmux-compat<br/>(shared CLI dispatch)"]
    compat -->|"v2 socket calls"| server["Linux cmux server"]
    server -->|"native split"| ui["teammate = cmux pane<br/>+ sidebar + notifications"]

    style shim fill:#8957e522,stroke:#8957e5
    style compat fill:#8957e522,stroke:#8957e5
```

The shim itself is three lines — a `tmux` that `exec`s
`cmux __tmux-compat "$@"`. Prepending its directory to `PATH` means
Claude finds it before any real tmux. **Trap:** the launcher OWNS that
directory; hand-editing the shim breaks the next launch with a Cocoa
"file exists" error — delete the dir and let it regenerate.

## The fake tmux identity

The launcher builds a `TMUX` value and `TMUX_PANE` that *encode the
current cmux location*, resolved from the server at launch:

```mermaid
flowchart TB
    launch["runClaudeTeams"] -->|"system.identify"| server["Linux server"]
    server -->|"focused block:<br/>workspace_id, pane_id"| launch
    launch --> tmuxval["TMUX = /tmp/cmux-claude-teams/<br/>&lt;workspaceId&gt;,&lt;windowToken&gt;,&lt;paneToken&gt;"]
    launch --> paneval["TMUX_PANE = %&lt;stable-numeric-pane-id&gt;"]

    tmuxval -.->|"decoded by"| compat["__tmux-compat"]
    paneval -.->|"decoded by"| compat
    compat -->|"maps back to"| loc["the real cmux workspace + pane"]

    style server fill:#1f6feb22,stroke:#1f6feb
```

**This is the bit the port was missing.** `system.identify` on Linux
returned only flat fields — no `focused` block — so the launcher fell
back to a `default,0,0` fake env, and every teammate spawn died with
*"Could not determine current tmux pane/window."* Adding the `focused`
block (macOS's exact envelope) fixed it. See PROGRESS 2026-07-22 "late".

## What the shim translates

`__tmux-compat` handles ~25 tmux verbs; each maps to a socket method the
port already implements. The load-bearing ones:

```mermaid
flowchart LR
    subgraph tmux["tmux verb (from Claude's harness)"]
        direction TB
        t1["new-session / new-window"]
        t2["split-window"]
        t3["send-keys"]
        t4["capture-pane"]
        t5["select-pane / -window"]
        t6["kill-pane / -window"]
        t7["list-panes / -windows"]
        t8["display-message #{pane_id}"]
    end
    subgraph verb["cmux socket method (server)"]
        direction TB
        v1["workspace.create"]
        v2["surface.split"]
        v3["surface.send_text / send_key"]
        v4["surface.read_text"]
        v5["surface.focus / workspace.select"]
        v6["surface.close / workspace.close"]
        v7["pane.list / workspace.list"]
        v8["surface.current ← resolves the target"]
    end
    t1-->v1
    t2-->v2
    t3-->v3
    t4-->v4
    t5-->v5
    t6-->v6
    t7-->v7
    t8-->v8

    style v8 fill:#2ea04322,stroke:#2ea043
```

`surface.current` (green) is the other verb the port had to add: the
shim resolves *every* list/target/send through it, so its absence
silently broke the whole read half while splits still worked. Guarded
now by `linux/tests/tmux-compat-smoke.sh`.

## Sibling launchers — NOT homogeneous (corrected 2026-07-23, batch 1)

The four "sibling" launchers are **not** one uniform shim family. The
parallel-dogfood `teams-siblings` package (verified against `CLI/cmux.swift`)
found they differ in *how* they integrate — only three use the tmux shim,
and they don't even write it the same way:

```mermaid
flowchart TB
    subgraph shimfamily["tmux-shim family (write ~/.cmuxterm/&lt;name&gt;-bin/tmux → __tmux-compat)"]
        omc["omc / omx<br/>resolve the agent binary FIRST,<br/>then write the shim<br/>(binary absent ⇒ NO shim)"]
        omo["omo<br/>resolves `opencode`, installs the<br/>oh-my-openagent plugin (bun/npm,<br/>a real network side effect), then shim"]
        claude["claude-teams<br/>writes the shim, then execs claude<br/>(the only 'write shim then exec' one)"]
    end
    codex["codex-teams<br/>NO tmux shim — a Codex<br/>app-server + watcher<br/>(ws://127.0.0.1, tracks the surface<br/>codex runs in)"]

    style codex fill:#f8514922,stroke:#f85149
    style claude fill:#2ea04322,stroke:#2ea043
```

- **claude-teams** — writes the shim, then execs the agent (verified
  end-to-end; ✅).
- **omc / omx** — resolve the agent binary *before* writing the shim, so
  an absent binary exits early with no shim written. Same `__tmux-compat`
  substrate once the shim exists.
- **omo** — resolves `opencode` (not a literal `omo`) and installs its
  oh-my-openagent plugin (a real bun/npm side effect) *before* the shim.
- **codex-teams** — writes **no** tmux shim at all; it runs a Codex
  **app-server + watcher** over a loopback WebSocket and tracks the pane
  codex runs in that way. A fundamentally different integration.

`teams-siblings-smoke.sh` verifies the launcher/shim setup path (14
assertions); the real "teammate becomes a split" leg is skipped because
the agent binaries aren't installed here (see GAPS).
