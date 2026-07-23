---
title: Workspace groups
area: workspaces
mac: full
linux: none
verbs: workspace.group.list, workspace.group.create, workspace.group.ungroup, workspace.group.delete, workspace.group.rename, workspace.group.collapse, workspace.group.expand, workspace.group.pin, workspace.group.unpin, workspace.group.add, workspace.group.remove, workspace.group.set_anchor, workspace.group.new_workspace, workspace.group.set_color, workspace.group.set_icon, workspace.group.move, workspace.group.focus
---

# Workspace groups

## Purpose

Organize a long sidebar of workspaces into named, collapsible groups —
color- and icon-tagged, pinnable — so a user running many parallel
tasks (the agent-heavy workflow cmux is built for) can keep projects
visually separated instead of scrolling one flat list.

## Usage

**Not available on the Linux port yet.** On macOS: create/rename/
collapse/pin groups in the sidebar, assign colors and icons, move
workspaces between groups; the whole surface is also socket-drivable
(the 17 `workspace.group.*` verbs).

## Implementation

Unported — a deliberately deferred "later" family (the sidebar grouping
model plus its persistence and sidebar UI). The Linux sidebar is a flat
`GtkListBox` with attention badges; adding groups touches the
snapshot-boundary-sensitive sidebar row pattern, so it should be built
against the immutable-snapshot row rules when it comes.

## Links

- [GAPS.md](../GAPS.md) — deferred families
- [PARITY.md](../PARITY.md) — workspace.group.* rows (❌)
