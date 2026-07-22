# Left sidebar and workspace groups — anatomy and contracts

> Sources: https://cmux.com/en/docs/workspace-groups, /en/docs/configuration
> (sidebar.*, workspaceGroups.*, workspaceColors.*, sidebarAppearance.*),
> /en/docs/api (sidebar metadata verbs), /en/docs/changelog (0.61.0, 0.64.11,
> 0.64.16, 0.64.20). Crawled 2026-07-22 via the port's own browser.

## What a workspace row shows (the sidebar is a triage board)

Per-workspace detail rows, each individually toggleable: git branch
(vertical|inline layout), working directory (viewport-aware truncation), PR
metadata (clickable, opens in embedded browser; fs-watched rather than
polled), SSH connection details, listening ports (clickable), latest
notification text (line-limit 12), log snippets, progress bar, status pills,
custom metadata pills, agent-activity spinner (leading|trailing), unread badge
(leading|trailing), workspace color (17 presets + custom palette;
indicator styles leftRail/solidFill/…), description, pin state, status lane.

Status lanes: **⌘;** mark workspace done, **⌘⇧;** cycle status one lane
forward. `app.reorderOnNotification` floats unread workspaces up; pinned
workspaces stay put. `app.iMessageMode` moves a workspace to top and previews
the submitted agent prompt. Inline rename by double-click (#7395); ⌘⇧R rename;
⌥⌘E edit description. Since 0.64.20 the sidebar is native AppKit rows
(perf at large workspace counts). Right-click sidebar view switcher offers
built-in views (Default Workspaces, Project Worktrees, …); **custom sidebars**
(beta) are user-authored via a runtime Swift interpreter with CLI validation
and live reload (0.64.13).

All metadata rows are script-writable: `cmux set-status/clear-status/
list-status`, `set-progress/clear-progress`, `log/clear-log/list-log`,
`sidebar-state` (see kb/cli-reference.md).

## Workspace groups

Model: a group is owned by exactly one **anchor workspace**; the group header
*is* the anchor's representation (no separate row). Click header name ⇒ focus
anchor's panels; click chevron ⇒ collapse. Anchors are always brand new —
"never promoted from an existing workspace". Anchor cwd inherits from the
first selected workspace (grouping a selection) or the active workspace (CLI
without --cwd). **Closing the anchor dissolves the group** (members become
ungrouped; nothing else closes; confirm dialog with don't-ask-again).
Group identity: name, SF Symbol icon (default folder.fill), optional color —
independent of the anchor's own customization (seeded at creation, may
diverge). Groups pin independently; sidebar order = pinned rows (workspaces
and groups) above unpinned, drag-order within tiers.

Creation: **⌃⌘G** new empty group; select ≥2 workspaces + **⌘⇧G** group
selection (⌘⇧G intentionally shared with React Grab — group handler only
consumes it on an explicit multi-selection); context menu New Empty Workspace
Group / New Group from Workspace / New Group from Selection; auto-named
"Group N". Header + button (hover) creates a workspace in the group at the
anchor cwd; ⌘N from a member/anchor lands inside the group
(placement `afterCurrent`|`top`|`end`; global default
`workspaceGroups.newWorkspacePlacement`, per-cwd override via
`workspaceGroups.byCwd` keyed by anchor cwd, longest-match, glob-capable).
Header context menu: Rename, Pin/Unpin, Edit Group Config (opens cmux.json),
Open Docs, Ungroup Workspaces (removes only the container), Delete Group
(closes header + every member; confirms). **⌃⌘.** collapse/expand focused
group.

### CLI (hyphenated form ships first; `cmux workspace group` becomes canonical later, alias kept forever)

```
cmux workspace-group list [--json]
cmux workspace-group create --name X [--cwd DIR] [--from <id>,<id>]   # returns workspace_group:N
cmux workspace-group ungroup|delete|rename|collapse|expand|pin|unpin <group-id>
cmux workspace-group add --group <gid> --workspace <wid>
cmux workspace-group remove --workspace <wid>
cmux workspace-group set-anchor --group <gid> --workspace <wid>
cmux workspace-group new-workspace <gid> [--placement afterCurrent|top|end]
cmux workspace-group set-color <gid> --hex "#7A4FD8"     # empty value clears
cmux workspace-group set-icon <gid> --symbol ladybug.fill
cmux workspace-group move <gid> (--to-index N | --before <gid> | --after <gid>)
cmux workspace-group focus <gid>
```

`delete` is irreversible (closes every member). Group name, anchor, pin,
collapse, color, icon persist across launches; membership is stored on each
workspace. Group headers show aggregate unread badges; the group menu can mark
members read/unread and clear notifications. Groups are surfaced in the cloud
CLI relay too (#5856).

## Port relevance

The port's sidebar is a flat GtkListBox with attention badges; CONCEPTS.md
records groups/pins/lanes as missing. New here vs CONCEPTS: the exact
anchor-dissolve/confirm semantics, byCwd config matching rule, the full
16-verb CLI surface, sticky manual-unread, iMessage mode, native-AppKit
rewrite (upstream hit the same "sidebar perf at scale" wall the port will),
and custom sidebars as a beta extension mechanism.
