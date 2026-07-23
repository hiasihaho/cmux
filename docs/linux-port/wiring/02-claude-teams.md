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

## Sibling launchers

`codex-teams`, `omc`, `omo`, `omx` ride the *same* shim surface with
their own launcher env quirks — each shim writes to its own
`~/.cmuxterm/<name>-bin/tmux`. Verified individually only for
claude-teams so far; the others are a one-scratch-run-each GAPS row.
