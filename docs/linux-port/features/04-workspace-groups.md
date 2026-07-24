---
title: Workspace groups
area: workspaces
mac: full
linux: partial
verbs: workspace.group.list, workspace.group.create, workspace.group.ungroup, workspace.group.delete, workspace.group.rename, workspace.group.collapse, workspace.group.expand, workspace.group.pin, workspace.group.unpin, workspace.group.add, workspace.group.remove, workspace.group.set_anchor, workspace.group.new_workspace, workspace.group.set_color, workspace.group.set_icon, workspace.group.move, workspace.group.focus
---

# Workspace groups

## Purpose

Organize a long sidebar of workspaces into named, collapsible groups —
color- and icon-tagged, pinnable — so a user running many parallel
tasks (the agent-heavy workflow cmux is built for) can keep projects
visually separated instead of scrolling one flat list.

## Usage

On macOS: create/rename/collapse/pin groups in the sidebar, assign
colors and icons, move workspaces between groups; the whole surface is
also socket-drivable (the 17 `workspace.group.*` verbs).

On Linux (stages 1+2, 2026-07-24): the **full verb family is served**
with macOS wire parity — all 17 `workspace.group.*` verbs plus
`workspace.create`'s `group_id`/`group_placement`/
`group_reference_workspace_id` (so `cmux new-workspace --group …` and
`cmux workspace-group …` work unchanged) — and the **sidebar renders
sections**: group header rows with a disclosure chevron (click toggles
collapse without stealing selection; clicking the header itself selects
the anchor, like macOS), indented member rows, a member count on
collapsed headers, and attention aggregation (a hidden member's unread
dot surfaces on its collapsed header). Groups persist across restarts.
Still `partial`: colors/icons are stored but not yet rendered, and
group management (create/rename/move) has no UI affordance — CLI/socket
only.

## Implementation

Linux mirrors the macOS model exactly: membership is a per-workspace
`groupId` relation (no member array on the group), the anchor is a real
member that doubles as the header, and every mutation re-establishes
"contiguous runs, anchor-first, pinned tier above unpinned"
(`normalizeGroupContiguity` in `ControlProtocol.swift`). Closing the
anchor dissolves the group; `remove` of the anchor does too. Persistence
rides `session-linux.json` as an optional `groups` array plus a
`groupIndex` per workspace (index-based — workspace UUIDs change on
restore, the macOS `anchorMemberIndex` trick). Suite:
`tests/workspace-groups-smoke.sh` (34 assertions incl. the save/restart
round-trip).

**Stage 2 (landed 2026-07-24):** the sidebar projects
`(tabs, groups) → [SidebarRowModel]` through `SidebarRows.project` —
a pure value snapshot shared verbatim with `debug.sidebar_rows`, so the
suite's row assertions are assertions on what the human sees. Rows keep
a structure-stable shape (every row is an EitherView/ViewStack): the
ListBox differ updates rows in place by id, and a row whose widget type
changes between renders keeps its stale widget otherwise — the trap
stage 2 hit and documented (PROGRESS 2026-07-24). The chevron is a real
flat Button inside the row, so its click never reaches row selection.

**Remaining (GAPS "Next"):** render `custom_color`/`icon_symbol` on
headers; UI affordances for create/rename/move (context menu).

## Links

- [GAPS.md](../GAPS.md) — deferred families
- [PARITY.md](../PARITY.md) — workspace.group.* rows (❌)
