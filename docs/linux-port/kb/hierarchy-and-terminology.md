# Hierarchy and terminology — the canonical model

> Sources: https://cmux.com/en/docs/concepts, /en/docs/getting-started.
> Crawled 2026-07-22 via the port's own browser.

## The four-level hierarchy

```
Window                       (macOS window; ⌘⇧N; each window has its own sidebar)
  └── Workspace              (sidebar entry; ⌘N; CMUX_WORKSPACE_ID)
        └── Pane             (split region; ⌘D right / ⌘⇧D down; pane id in socket API)
              └── Surface    (tab within a pane; ⌘T; CMUX_SURFACE_ID)
                    └── Panel (terminal | browser content; internal concept)
```

Contracts worth quoting:

- "In the UI and keyboard shortcuts, workspaces are often called **'tabs'** …
  The socket API and environment variables use the term **workspace**."
- "Each pane has its own tab bar and can hold multiple surfaces."
- "Panel is mostly an internal concept. In the socket API and CLI, you
  interact with surfaces rather than panels directly."

| Context | Term |
|---|---|
| Sidebar UI | Tab |
| Keyboard shortcuts | Workspace or tab |
| Socket API | workspace |
| Env var | CMUX_WORKSPACE_ID |

## Creation / identification summary (docs table verbatim)

| Level | What it is | Created by | Identified by |
|---|---|---|---|
| Window | macOS window | ⌘⇧N | — |
| Workspace | Sidebar entry | ⌘N | CMUX_WORKSPACE_ID |
| Pane | Split region | ⌘D / ⌘⇧D | Pane ID (socket API) |
| Surface | Tab within pane | ⌘T | CMUX_SURFACE_ID |
| Panel | Terminal or browser | Automatic | Panel ID (internal) |

## Navigation defaults

Workspaces: ⌘1–⌘9 jump, ⌃⌘[/⌃⌘] prev/next, ⌘⇧W close, ⌘P workspace switcher.
Panes: ⌥⌘+arrows. Surfaces: ⌘⇧[/⌘⇧] prev/next (note: ⌘[/⌘] are **focus
history** by default, not surface nav), ⌃1–⌃9 select, ⌘W close.

## Adjacent structure (details in sibling kb files)

- **Workspace groups**: collapsible sidebar sections owned by an invisible
  *anchor workspace* (kb/sidebar-and-groups.md).
- **Canvas**: alternative freeform 2D layout for a workspace's panes replacing
  tiling (kb/canvas-and-viewers.md).
- Surfaces can be terminals, browsers, or viewer panels (markdown viewer, diff
  viewer, file preview, project visualizer, right-sidebar tools opened "as
  panes" since 0.64.5).

Getting-started facts: macOS 14+, DMG or `brew install --cask cmux`
(tap manaflow-ai/cmux), Sparkle auto-update with a titlebar update pill, CLI
symlink for outside use:
`sudo ln -sf "/Applications/cmux.app/Contents/Resources/bin/cmux" /usr/local/bin/cmux`.
