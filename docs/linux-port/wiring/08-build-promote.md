# ⑨ Build → scratch → promote

The dev loop that lets the agent develop the port from inside a running
copy of it, without ever risking the human's daily instance. Three build
artifacts, three instance slots, one human-approved checkpoint.

## The two binaries

```mermaid
flowchart TB
    src["Swift sources<br/>linux/Sources/CmuxAdw/"] --> sb["swift build (from linux/)"]
    sb -->|"VTE only"| vte["cmux-adw (VTE default)"]
    sb -->|"CMUX_GHOSTTY=1"| ghostty["cmux-adw + shim linkage"]
    shim_src["ghostty submodule<br/>branch linux-gtk-embed"] -->|"zig build lib-gtk<br/>-Doptimize=ReleaseSafe"| zigout["zig-out/…/ghostty_gtk_embed.h<br/>+ lib"]
    zigout -.->|"linked into"| ghostty

    style ghostty fill:#2ea04322,stroke:#2ea043
```

`swift build` is **always safe** — it rewrites the on-disk binary; every
running instance keeps its old code until an approved restart. ReleaseSafe
is the standard shim mode (Debug scrolls sluggishly; ReleaseFast SEGVs in
`ghostty_embed_init` — parked). Header changes reach Swift only after the
zig build reinstalls `zig-out/include`.

## Where a new binary is exercised

```mermaid
flowchart LR
    binary["fresh linux/.build/debug/cmux-adw"] --> gate["linux/tests/run-all.sh<br/>(13 suites, own Xvfb :90-:139)"]
    binary --> scratch["scratch.sh start &lt;tag&gt;<br/>(probes, screenshots, :140-:159)"]
    binary --> dev["start.sh dev / dev2<br/>(runtime experiments)"]
    gate --> green{"green?"}
    green -->|yes| promote["ready to promote"]
    green -->|no| fix["fix, rebuild"]
    fix --> binary

    style gate fill:#1f6feb22,stroke:#1f6feb
```

Both the suites (`lib.sh`) and `scratch.sh` now launch with a **hermetic
`XDG_CONFIG_HOME`** — a stray user-level ghostty theme typo pops a modal
error dialog that eats pointer-driven assertions, and hermetic config
makes the harness independent of the developer's dotfiles.

## The promote checkpoint (user-approved)

```mermaid
sequenceDiagram
    participant U as human (plain terminal / dev pane)
    participant PR as promote.sh
    participant D as daily instance
    U->>PR: promote.sh --no-build
    PR->>PR: self-hosting guard<br/>(refuses to run from inside the daily)
    PR->>D: session.save (final-save semantics)
    PR->>D: SIGTERM (kill by app-id)
    PR->>D: start.sh daily on the new binary
    Note over D: session restore brings layout,<br/>cwds, scrollback, browser back
    U->>D: claude --continue (or claude-teams --continue)
```

The guard is the crux: a shell inside the daily dies with it, so
`promote.sh` refuses to run from a pane of the instance it is about to
kill — run it from a plain terminal or a dev pane. `--slot dev2`
exercises the identical code path against a disposable instance (how the
script itself is tested).

## The whole cadence, one arrow

```mermaid
flowchart LR
    edit["edit sources"] --> build["swift build"] --> verify["scratch / suites"] --> commit["commit + push<br/>(docs same-commit)"] --> promote["promote.sh<br/>(when the human is ready)"] --> dogfood["dogfood in the daily"]
    dogfood -.->|"next task"| edit
```

Everything reaches the daily only at the next promote — so the agent can
land a whole day's work on disk, and the human pulls it in with one
30-second checkpoint when convenient.
