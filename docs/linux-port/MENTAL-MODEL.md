# cmux — the mental model on one page

The meta-summary of everything learned 2026-07-22 (docs crawl + dual UI
survey + kb/ deep dive). Details live in [CONCEPTS.md](CONCEPTS.md) and
[kb/](kb/INDEX.md); this page is the shape of the system. Update it
whenever those change in a way that redraws a picture.

## 1. What cmux is

> An agent supervision cockpit: a native terminal whose every feature
> serves the loop of running many AI coding agents in parallel without
> losing track of any of them.

```mermaid
flowchart LR
    A["RUN<br/>agents in parallel<br/>(terminal surfaces)"] --> B["NOTICE<br/>attention pipeline<br/>badges, alerts"]
    B --> C["TRIAGE<br/>jump-to-unread,<br/>palette, switcher"]
    C --> D["ACT<br/>splits, browser,<br/>viewers, TextBox"]
    D --> E["RESUME<br/>session restore, fork,<br/>Vault, resume tokens"]
    E --> A
```

The port lives this loop daily — it is developed inside itself.

## 2. The object hierarchy (the vocabulary)

```mermaid
flowchart TD
    W["Window<br/><i>macOS window; multi-window = own phase</i>"]
    W --> WS["Workspace = sidebar row, called 'tab' in UI<br/><code>CMUX_WORKSPACE_ID</code>"]
    WS --> P["Pane = split region"]
    P --> S["Surface = tab within the pane<br/><code>CMUX_SURFACE_ID</code>"]
    S --> T["Panel: Terminal<br/>(Ghostty, VTE fallback)"]
    S --> Br["Panel: Browser<br/>(WebKit)"]
```

Contract: UI text says **tab**, API says **workspace**; agents address
**surfaces**, never panels. The port implements this 1:1 (`cmux tree`).

## 3. The attention pipeline (how "notice" works)

```mermaid
flowchart TD
    H["agent hooks / Claude wrapper"] --> N
    Bell["terminal bell"] --> N
    OSC["OSC 777 / OSC 99<br/><i>port: verify</i>"] --> N
    CLI["cmux notify<br/>(CLI + socket)"] --> N
    N["notification store"] --> HK{"user notification hooks<br/>(JSON in/out filters)<br/><i>port: missing</i>"}
    HK --> T1["tier 1: flash ring<br/>transient, 0.9s"]
    HK --> T2["tier 2: pane unread ring<br/>persistent"]
    HK --> T3["tier 3: sidebar badge<br/>+ bell + dock count"]
    HK --> T4{"desktop alert —<br/>suppressed when window focused,<br/>workspace active, or panel open"}
    T3 --> J["triage: Cmd+Shift+U jump,<br/>Ctrl+Cmd+U cycle-to-back"]
    J --> R["selecting the workspace<br/>= mark read"]
```

One accent color, escalating persistence. The port has the store, the
badge (as a text dot), desktop alerts with the active-workspace rule,
and jump-to-unread; the ring tiers and hook filters are open rows.

## 4. Claude Code's lifecycle inside cmux (the load-bearing workflow)

```mermaid
sequenceDiagram
    participant U as Human
    participant C as cmux app
    participant W as claude wrapper
    participant A as Claude Code
    U->>C: run `claude` in a surface
    C->>W: transparent wrapper (automation.claudeCodeIntegration)
    W->>A: launch, hook settings injected
    W->>C: session id + cwd + surface recorded<br/>(~/.cmuxterm/claude-hook-sessions.json)
    A-->>C: Stop / permission hooks
    C-->>U: attention pipeline fires
    U->>C: relaunch cmux (days later)
    C->>C: restore layout, cwd, scrollback, browser
    C->>A: auto-run `claude --resume <saved id>`
    Note over C,A: same captured data also powers<br/>Fork Conversation and reopen-closed
```

**Wrapper, not hooks file** — that asymmetry (every other agent uses
`cmux hooks setup`) is the single most important implementation fact
for the port's resume work. This very session was resumed by
hand-carrying ids in text files; this diagram is the feature that
automates it.

## 5. Agent teams: the tmux shim

```mermaid
flowchart LR
    O["claude-teams / omc<br/>orchestrator"] -->|"tmux new-session,<br/>split-window, send-keys…"| F["fake tmux<br/>~/.cmuxterm/*-bin/tmux"]
    F --> X["cmux __tmux-compat<br/>(shared CLI — builds on Linux)"]
    X -->|"workspace.create, surface.split,<br/>send_text, read_text, pane.*"| Srv["cmux server"]
    Srv --> UI["teammates appear as<br/>native splits + sidebar metadata"]
```

kb/tmux-compat.md verified all ~25 shim verbs against the shared CLI:
**every socket verb they need is green on the port.** One dogfood run
of `cmux claude-teams` decides the headline.

## 6. UI geography (where things live)

```mermaid
flowchart LR
    subgraph win ["cmux window"]
        direction LR
        subgraph left ["left sidebar — the work"]
            LS["workspace rows: badge, spinner,<br/>branch, PRs, ports, checklist<br/>groups (anchor-owned), status lanes"]
        end
        subgraph center ["workspace area"]
            CT["panes, 28pt surface tab bars<br/>terminal + browser chrome<br/>in-window overlays:<br/>palette, find, suggestions"]
        end
        subgraph right ["right sidebar — instruments"]
            RS["files | find | sessions (Vault)<br/>| feed | dock"]
        end
    end
```

Principles that survive translation to GNOME: chrome lives *inside*
panes; workspaces only in the left sidebar; overlays instead of extra
windows; hover-revealed affordances; one attention color.
Port today: left sidebar (flat) + center; the right sidebar does not
exist yet as a concept.

## 7. The knowledge system (which doc answers what)

```mermaid
flowchart TD
    Q1["What is this feature for?"] --> CONCEPTS["CONCEPTS.md → kb/"]
    Q2["Which verbs work on Linux?"] --> PARITY["PARITY.md"]
    Q3["How should it look / did we decide?"] --> UX["UX-PARITY.md"]
    Q4["What do we build next?"] --> GAPS["GAPS.md"]
    Q5["What happened and what did it teach?"] --> PROG["PROGRESS.md / LESSONS.md"]
    Q6["Where does a session start?"] --> CATCH["CATCHUP.md"]
```

Rules that keep it true: same-commit updates, no gap closes without a
regression assertion, sweep after every merge, deviations are decisions.

## 8. Port heat map (2026-07-22)

| Loop stage | Substance | Port |
|---|---|---|
| Run | terminals (Ghostty default), splits, tabs, browser panes, profiles | ✅ strong |
| Notice | store, badges, desktop, bell, `notify`; rings/hooks/OSC open | 🟡 |
| Triage | jump-to-unread ✅; palette, switcher, focus history missing | 🟡 |
| Act | splits/tabs/browser ✅; viewers, TextBox, canvas missing | 🟡 |
| Resume | layout+scrollback ✅ (beyond macOS in places); agent resume, fork, Vault missing | 🟡 |
| Teams | shim verbs all green; end-to-end unverified | 🔎 |
