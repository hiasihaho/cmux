# Concepts — how cmux is meant (official-docs distillation)

Crawled 2026-07-22 from `https://cmux.com/docs/*` **through the port's
own browser stack** (one surface, 21 navigations, zero verb failures —
the crawl loop is recorded in PROGRESS). Purpose: the product's mental
model, so port decisions are made knowing what each feature is *for* —
PARITY tracks verbs, UX-PARITY tracks presentation, this file tracks
intent. Re-crawl when upstream docs move; it costs two minutes.

## What cmux is (the north star)

> "A lightweight, native macOS terminal built on Ghostty for managing
> multiple AI coding agents."

Not a generic terminal with extras — an **agent supervision cockpit**.
Nearly every documented feature serves one loop:

    run agents in parallel → notice which one needs you →
    jump there with context → act → resume later from anywhere.

The port already *lives* this loop (it is developed inside itself); the
docs name the pieces we haven't built and explain the ones we have.

## The canonical hierarchy (docs/concepts)

    Window → Workspace (sidebar entry) → Pane (split region)
           → Surface (tab within a pane) → Panel (terminal|browser; internal)

Terminology contract: the sidebar UI calls workspaces **"tabs"**; the
socket API and env vars always say **workspace** (`CMUX_WORKSPACE_ID`,
`CMUX_SURFACE_ID`). "Panel" is internal — CLI/API address surfaces.

**Port status:** implemented 1:1 and it shows — the docs' hierarchy
table could have been written from our `cmux tree` output. The one
unbuilt floor is multi-window (GAPS).

## The two sidebars

- **Left = the work**: workspaces, orderable and groupable.
  *Workspace groups* are collapsible sections owned by an invisible
  **anchor workspace** (header = anchor; closing the anchor dissolves
  the group), pinnable, with icon + color, a hover **+** button, and
  full CLI (`cmux workspace-group …`). Workspaces also carry **status
  lanes** (mark done ⌘;, cycle status ⌘⇧;) — the sidebar is a triage
  board, not just a list.
- **Right = the instruments**: **Vault** (index of *local agent session
  transcripts* — Claude Code, Codex, OpenCode, Pi — searchable by
  content, drag a hit into the workspace to resume it), **Dock**
  (JSON-configured always-visible terminal controls: lazygit, log
  tails, `cmux feed tui`; project `.cmux/dock.json` wins over global,
  with a trust prompt), and a **file explorer**.

**Port status:** left sidebar is a flat list with a text attention dot;
no groups, pins, lanes, context menus, or drag order. The right sidebar
does not exist as a concept.

## The agent-supervision loop, piece by piece

| Piece | macOS mechanism (docs) | Port status |
|---|---|---|
| Run agents | Ghostty terminals; surfaces per pane | ✅ (Ghostty default, VTE fallback) |
| Notice | notifications (CLI `cmux notify`, **OSC 777**, **OSC 99**, agent hooks via `cmux hooks setup <agent>`), badge on workspace, desktop alert w/ suppression rules, sidebar status pills (`cmux set-status`) | 🟡 CLI + hooks + badges + desktop done; OSC 777/99 ingestion unverified; status pills missing |
| Triage | notification panel ⌘I, jump-to-unread ⌘⇧U, mark-oldest-unread ⌃⌘U, workspace switcher ⌘P, command palette ⌘⇧P, focus history ⌘[/⌘] | 🟡 panel + jump-to-unread done; palette, switcher, focus history missing |
| Act with context | splits, per-pane surface tabs, browser panes beside terminals, Diff viewer, Markdown viewer, TextBox (compose prompt before sending) | 🟡 splits/tabs/browser done; viewers + TextBox missing |
| Resume | session restore (layout + cwd + scrollback + browser history) **plus agent-native resume**: hooks capture the agent's session id, restore re-launches `claude --resume <id>` etc. (17 agents supported); Vault for *old* sessions | 🟡 layout restore done and strong; **agent-native resume missing — this very port session was resumed by hand-carrying ids in text files, which is precisely the workflow macOS automates** |

## Customization model (docs/configuration, custom-commands, shortcuts)

- One file: `~/.config/cmux/cmux.json` (+ project `.cmux/cmux.json`
  with a trust prompt — project configs can define commands, so trust
  is explicit). Schema families: app, terminal, notifications
  (incl. **notification hooks**: stdin JSON → stdout JSON filters),
  sidebar, workspaceGroups, ui, browser, shortcuts, …
- **Every cmux-owned shortcut is rebindable**, including two-step
  tmux-style chords (`["ctrl+b","c"]`) and explicit unbinding.
- **Custom commands**: palette actions, plus-button actions, and full
  **workspace layout templates** (declarative split/pane/surface trees
  with cwd resolution) — "save current layout as template" ⌃⌘S.

**Port status:** our `cmux.json` `linux` section has 3 keys; shortcuts
are hardcoded; no project configs, no trust flow, no templates.

## Concept inventory → port disposition

| Concept (doc page) | One-line essence | Port |
|---|---|---|
| Workspace groups | collapsible anchor-owned sidebar sections, full CLI | ❌ GAPS Later (`workspace.group.*`, 13 verbs) |
| TextBox (beta) | prompt composer above the terminal, per-surface, persisted | ❌ new — GAPS |
| Session restore | layout restore **+ agent resume tokens** | 🟡 agent resume → GAPS |
| Vault | search old agent transcripts, drag-to-resume | ❌ Later |
| Task Manager | `cmux top` / palette: per-workspace resource attribution | ❌ Later (`system.top`) |
| Custom commands | palette/plus-button actions, layout templates | ❌ Later |
| Dock | right-sidebar terminal controls from JSON | ❌ Later |
| Keyboard shortcuts | all rebindable, chords, `shortcuts.when` | ❌ rebinding → GAPS |
| Browser automation | the verb surface (we mirror it) + **browser focus mode**, design mode, React Grab | ✅ verbs / ❌ modes |
| Skills | `cmux skills install` — agent skills incl. diagnostics | 🟡 upstream skills load from the repo; install flow unverified on Linux |
| Notifications | lifecycle (received→unread→read→cleared), suppression rules, OSC 777/99, notification hooks, custom command | 🟡 see loop table |
| Canvas | freeform 2D pane layout (pan/zoom/tidy) — an alternative to tiling | ❌ Later (`canvas.*`) |
| Diff viewer / Markdown viewer / file explorer | vim-keyed read surfaces beside agents | ❌ Later |
| SSH / Remote tmux / iOS | remote workspaces, tmux mapping, phone client | ❌ out of scope for now |
| Feed | approval-request stream from agent hooks (`cmux feed tui`) | ❌ Later (`feed.*`) |

## Terminology and behavioral contracts worth honoring now

1. **"Tab" (UI) = workspace (API).** Our sidebar rows are "tabs" in
   user-facing text; verbs stay `workspace.*`. Already true — keep it.
2. **Suppression rules are part of the notification contract**
   (focused window / active workspace / open panel ⇒ no desktop
   alert). We implement the active-workspace rule; the docs make all
   three explicit.
3. **Read = viewed**: selecting a workspace marks its notifications
   read. Implemented — it is a documented behavior, not our invention.
4. **Project config requires trust before its commands run.** Any
   future `.cmux/` support on Linux must ship the trust prompt with it.
5. **`cmux docs <topic>` is the agent-facing manual** — upstream's
   agent prompts say "run `cmux docs dock` first". Worth verifying the
   merged CLI serves it offline on Linux.

## What this crawl changes

Fed into GAPS (same commit): OSC 777/99 ingestion verify, agent-native
session resume, shortcut rebinding, TextBox, and the small keyboard
batch (equalize splits, reopen-closed, focus history). The big families
(canvas, vault, dock, groups, viewers, feed) stay in Later — but they
are now *concepts with intent*, not just method-name inventories.
