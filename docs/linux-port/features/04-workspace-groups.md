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

On Linux (stage 1, 2026-07-24): the **full verb family is served** with
macOS wire parity — all 17 `workspace.group.*` verbs plus
`workspace.create`'s `group_id`/`group_placement`/
`group_reference_workspace_id` (so `cmux new-workspace --group …` and
`cmux workspace-group …` work unchanged). Groups persist across restarts.
The sidebar still renders the flat list — grouping is model-true but not
yet visual, hence `partial`.

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

**Stage 2 (open, GAPS "Next"):** collapsible sidebar sections with
header rows, colors/icons, attention aggregation onto collapsed headers
— touches the snapshot-boundary-sensitive sidebar row pattern, so it
must follow the immutable-snapshot row rules.

## Links

- [GAPS.md](../GAPS.md) — deferred families
- [PARITY.md](../PARITY.md) — workspace.group.* rows (❌)
