# Feature timeline — when the big concepts landed

> Source: https://cmux.com/en/docs/changelog (full history to 0.8.0) +
> /en/blog dates. Crawled 2026-07-22 via the port's own browser.
> Use: judging maturity/stability of a feature before porting it, and seeing
> which problems upstream hit in what order (they preview the port's own path).

## Concept-introduction timeline (distilled)

| When | Version | Concept |
|---|---|---|
| 2026-02-12 | ~0.9 | Launch: native macOS terminal on Ghostty for parallel agents; vertical tabs, notification panel, socket API |
| 2026-02-15 | 0.32.0 | Sidebar metadata (status/progress/log verbs) |
| 2026-02-21 | 0.60.0 | Tab context menu, DevTools, **notification rings**, CJK input |
| 2026-02-25 | 0.61.0 | Tab colors, **Command Palette** (⌘⇧P), pin workspaces, PR/ports sidebar metadata, Open With |
| 2026-03-04 | — | ⌘⇧U story (blog) — supervision shortcut becomes the brand |
| 2026-03-12 | 0.62.0 | Markdown viewer v1, browser find, vi copy mode, localization |
| 2026-03-28 | 0.63.0 | **SSH workspaces** (relay daemon), **claude-teams** + tmux shim, **omo**, browser profile import, minimal mode, **custom commands** (project cmux.json), chorded shortcuts (0.63.2) |
| 2026-03-30 | — | GPL relicense |
| 2026-05-05 | 0.64.0 | **Session restore on quit + agent resume** (5 agents), **passkeys**, **file explorer** (SSH-capable), **Task Manager** (`cmux top`), cmux.json canonical (JSONC), menu-bar-only mode, `--layout` on workspace.create, /llms.txt docs |
| 2026-05-11 | 0.64.4 | Vault gains Pi & Hermes; browser cookie import polish |
| 2026-05-13 | 0.64.5 | **codex-teams**, menubar global search, markdown viewer v2 (webview), **Feed on by default**, notification CLI parity (dismiss/mark-read/open/jump-to-unread), right-sidebar tools as panes |
| 2026-05-19..23 | 0.64.7–.10 | **Conversation forks** (first appearance), Grok agent, browser memory/background preload, copy-on-select, extension-sidebar prototypes |
| 2026-05-22 | — | Blog wave: **Vault**, Task Manager, Finder, passkeys, unread shortcuts, markdown viewer |
| 2026-06-01 | 0.64.11 | **Workspace groups** (+ full CLI), **focus & recently-closed history**, **agent hibernation**, detachable SSH PTY daemon, **TextBox** (beta), `cmux diff`, Kiro hooks, Beta Features gate |
| 2026-06-02 | 0.64.12 | Feed re-gated behind Beta Features (off by default), diff shortcut, markdown zoom |
| 2026-06-04 | 0.64.13 | **Browser focus mode**, SSH agent forwarding, **custom sidebars** (runtime Swift interpreter, beta), mouse back/forward |
| 2026-06-06 | 0.64.14 | **iPhone companion (beta)**, cross-window workspace drag, out-of-process custom sidebars |
| 2026-06-12 | 0.64.15 | Diff **review comments → TextBox**, rebindable ⌘1–9 + **shortcut when-clauses**, in-process custom sidebars, iOS composer |
| 2026-06-15 | 0.64.16 | **AI auto-naming**, per-workspace env vars, left/right Option-as-Alt, **experimental canvas** |
| 2026-06-23 | 0.64.17 | Global font magnification, **remote tmux mirroring** (beta), diff branch picker, one-step grouped workspace creation |
| 2026-07-14 | 0.64.18 | **Saved workspace layouts** (capture current as template + default-for-new), Fork Conversation GA, per-monitor window memory, memory-pressure response + scrollback compression, Ollama/Kimi/Campfire agents, PushNotification bridge, durable tab deep links |
| 2026-07-19 | 0.64.20 | **Native AppKit sidebar** (default), **browser design mode**, TUI mouse forwarding, `cmux ssh --command` |

## Patterns worth noting

- Beta gating is a deliberate mechanism: Dock, Feed, Remote tmux, Custom
  Sidebars, TextBox, Canvas all shipped behind (or moved into) a Beta
  Features flag; Feed even shipped default-on then was re-gated.
- Upstream repeatedly fought the same perf classes the port's CLAUDE.md warns
  about: sidebar re-render/livelock loops (#3028, #6188, #6341, #8211),
  typing latency from title churn (#8084), memory leaks (0.64.9 hotfix,
  0.64.13 4.4 GB settings-observation leak) — culminating in the AppKit
  sidebar rewrite. The port's GTK sidebar should expect the same wall.
- The agent-resume matrix grew release by release (5 agents at 0.64.0 → 17+
  by 0.64.18); support is data-driven per agent (binary + resume template +
  feed bridge), i.e. designed to be extended.
- Contributor names on macOS features (azooz2003-bit, ejc3, mxschmitt, tobi…)
  show active external contribution — relevant for how a Linux port PR could
  land upstream.
