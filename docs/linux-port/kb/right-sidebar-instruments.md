# Right sidebar — Vault, Dock, Feed, Files, Find, Task Manager

> Sources: https://cmux.com/en/docs/vault, /en/docs/dock, /en/docs/task-manager,
> /en/blog/cmux-vault, /en/blog/task-manager, /en/blog/cmux-finder,
> /en/docs/configuration (fileExplorer, sidebar.rightMaxWidth, shortcuts.when),
> /en/docs/changelog. Crawled 2026-07-22 via the port's own browser.

The right sidebar is a moded instrument panel. The `shortcuts.when` context
key `sidebarMode` enumerates the modes: **files, find, sessions, feed, dock**.
Toggle right sidebar **⌥⌘B**; toggle right-sidebar *focus* **⌘⇧E**; row nav
J/K (⌃N/⌃P, H/L collapse/expand in Files; `/` starts search); Enter opens.
Right-sidebar tools can also open **as panes** (0.64.5). Width cap:
`sidebar.rightMaxWidth`.

## Vault (mode: sessions)

Purpose: "finding old AI coding agent sessions by transcript content instead
of by terminal history." Indexes local session records of Codex, Claude Code,
OpenCode, and Pi (only formats cmux can read on the local machine; no remote
hosts). Workflow: open Vault → search a file, branch, issue title, error
message, or conversation phrase → **drag the hit into the current workspace**
→ the session reopens beside your current context. Explicit non-goal: "not
for restoring the current app layout after relaunch" (that's session restore).
Blog framing: "Shell history tells you what command started an agent. Vault
searches what the agent actually discussed, changed, and reported." Grok
sessions became Vault-resumable in 0.64.8. Capped folder sections always offer
"Show more" (#6327).

## Dock (mode: dock; Beta-Features-gated by default)

Terminal UI controls pinned to the right sidebar — each control is a command
from JSON running in its own **Ghostty-backed terminal section** in the login
shell. Uses: lazygit, log tails, dev-server status, queues, `cmux feed tui
--opentui`. Config resolution: project `.cmux/dock.json` (nearest parent;
nested trees apply to their subtree) > `~/.config/cmux/dock.json` > empty.
Project docks prompt for trust before launching. Schema:
`{"controls":[{id, title, command, cwd?, height?, env?}]}` — stable lowercase
ids, `height` in points (others share remaining space), relative cwd resolves
from project root (project) or home (global). Team-sharing guidance: commit
repo controls, keep secrets out, personal controls global. The docs ship a
full agent prompt for setting up a Dock ("Run `cmux docs dock` first…").
Configurable max width (#4385).

## Feed (mode: feed; Beta-Features-gated, off by default since 0.64.12)

One chronological stream of "notifications, agent events, and workspace
activity"; fed by the agents' Feed bridges (PermissionRequest/PreToolUse/…,
see the resume matrix) — approval requests appear here even when banners are
hook-suppressed. Also consumable as a TUI: `cmux feed tui [--opentui]`
(commonly embedded as a Dock control). Kiro verbosity:
`automation.kiroNotificationLevel`. History: introduced default-on (0.64.5),
re-gated behind Beta Features (0.64.12) mirroring Dock.

## Files (mode: files) — "cmux Finder"

Finder-like file explorer with **full SSH support** (remote workspaces get the
same tree). Previews videos, images, PDFs, markdown inside cmux; drag a
markdown file into the workspace to open the viewer. Double-click action
configurable: `preview` (default) | `defaultEditor` | `preferredEditor`
(`app.preferredEditor`); directories always toggle; remote explorers always
preview. Cmd-click file previews toggleable from the palette. Preview headers
carry an Open With menu.

## Find (mode: find)

Directory search pane (⌘⇧F "Find in directory"); powered by ripgrep
(`automation.ripgrepBinaryPath`).

## Task Manager (window + CLI, palette entry)

`cmux top` or ⌘⇧P → "Task Manager". Shows resource usage for windows,
workspaces, panes, terminal processes, **known coding agent processes**
(attributed to their workspace/surface), and browser webviews + helpers.
Troubleshooting loop: open when fans spin → sort by CPU/RAM → **jump from the
row back to the owning surface** → act with context. Positioned explicitly
against Activity Monitor ("shows load from cmux but does not identify the
responsible workspace"). Column sorting + Program Totals aggregation (0.64.5).
`cmux top` also works headless for scripts/SSH.

## Port relevance

The port has no right sidebar at all (CONCEPTS). New beyond CONCEPTS: the
five-mode structure with `sidebarMode` as a shortcut-context key, Dock/Feed
beta gating, feed-as-TUI reuse inside Dock, Vault's drag-to-resume being the
same session data as ⌘⇧T/fork, and Task Manager's jump-back contract.
