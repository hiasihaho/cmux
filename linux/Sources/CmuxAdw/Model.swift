import Foundation

/// What a pane surface hosts — a shell terminal or a WebKit browser view
/// (macOS `Panel.PanelKind` counterpart).
enum SurfaceKind: Equatable {
    case terminal
    case browser(initialURL: String)
    /// Web Inspector (DevTools) for another surface's web view. Ephemeral
    /// by nature: WebKit hands out the inspector widget only during its
    /// own `attach` signal, so it cannot be rebuilt on session restore —
    /// these panes are deliberately not persisted.
    case inspector(targetSurfaceId: UUID)

    var typeName: String {
        switch self {
        case .terminal:
            return "terminal"
        case .browser:
            return "browser"
        case .inspector:
            return "inspector"
        }
    }
}

/// One surface hosted in a pane.
struct PaneSurface: Equatable {
    let surfaceId: UUID
    var kind: SurfaceKind
    /// Working directory the surface's shell was (or will be) spawned in
    /// (terminals only).
    var workingDirectory: String

    init(
        surfaceId: UUID = UUID(),
        kind: SurfaceKind = .terminal,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.surfaceId = surfaceId
        self.kind = kind
        self.workingDirectory = workingDirectory
    }
}

/// One pane in a workspace's split tree. A pane holds one or more surfaces
/// behind a tab strip (AdwTabView) — matching macOS, where Bonsplit panes
/// carry their own tabs. Popups land here as tabs instead of forcing yet
/// another split, which is what made five popups unreadable slivers.
///
/// The single-surface accessors below (`surfaceId`, `kind`,
/// `workingDirectory`) mean "the surface this pane is currently showing".
/// Most call sites want exactly that, which is why they still read as if a
/// pane were a surface.
struct PaneLeaf: Equatable {
    let paneId: UUID
    var surfaces: [PaneSurface]
    var selectedIndex: Int

    init(
        paneId: UUID = UUID(),
        surfaceId: UUID = UUID(),
        kind: SurfaceKind = .terminal,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.paneId = paneId
        self.surfaces = [PaneSurface(
            surfaceId: surfaceId, kind: kind, workingDirectory: workingDirectory
        )]
        self.selectedIndex = 0
    }

    init(paneId: UUID = UUID(), surfaces: [PaneSurface], selectedIndex: Int = 0) {
        self.paneId = paneId
        self.surfaces = surfaces.isEmpty ? [PaneSurface()] : surfaces
        self.selectedIndex = selectedIndex
    }

    /// Clamped: a pane must always have a valid selection, and closing the
    /// last tab is the caller's job, not something to crash on here.
    var safeIndex: Int {
        surfaces.isEmpty ? 0 : min(max(0, selectedIndex), surfaces.count - 1)
    }

    var selected: PaneSurface { surfaces[safeIndex] }

    var surfaceId: UUID { selected.surfaceId }

    var kind: SurfaceKind {
        get { selected.kind }
        set { surfaces[safeIndex].kind = newValue }
    }

    var workingDirectory: String {
        get { selected.workingDirectory }
        set { surfaces[safeIndex].workingDirectory = newValue }
    }

    func contains(surfaceId: UUID) -> Bool {
        surfaces.contains { $0.surfaceId == surfaceId }
    }

    mutating func select(surfaceId: UUID) {
        if let index = surfaces.firstIndex(where: { $0.surfaceId == surfaceId }) {
            selectedIndex = index
        }
    }
}

/// The split tree of a workspace — the Linux counterpart of Bonsplit's
/// layout tree (mirrors `SessionWorkspaceLayoutSnapshot` in the macOS app).
indirect enum PaneNode: Equatable {
    case leaf(PaneLeaf)
    case split(orientation: SplitOrientation, first: PaneNode, second: PaneNode)

    enum SplitOrientation: String, Equatable {
        case horizontal
        case vertical
    }

    var leaves: [PaneLeaf] {
        switch self {
        case .leaf(let leaf):
            return [leaf]
        case .split(_, let first, let second):
            return first.leaves + second.leaves
        }
    }

    /// Structure signature — when it changes, the GtkPaned skeleton is
    /// rebuilt (live terminal widgets are reparented, not recreated).
    var shapeSignature: String {
        switch self {
        case .leaf(let leaf):
            return leaf.surfaces.map(\.surfaceId.uuidString).joined(separator: "+")
        case .split(let orientation, let first, let second):
            return "(\(orientation.rawValue) \(first.shapeSignature) \(second.shapeSignature))"
        }
    }

    /// Splits the leaf holding `surfaceId`. `left`/`right` create a
    /// horizontal split, `up`/`down` a vertical one; `left`/`up` place the
    /// new pane first. Returns nil if the surface or direction is unknown.
    func splitting(surfaceId: UUID, direction: String, newLeaf: PaneLeaf) -> PaneNode? {
        let orientation: SplitOrientation
        let newFirst: Bool
        switch direction.lowercased() {
        case "left":
            orientation = .horizontal
            newFirst = true
        case "right":
            orientation = .horizontal
            newFirst = false
        case "up":
            orientation = .vertical
            newFirst = true
        case "down":
            orientation = .vertical
            newFirst = false
        default:
            return nil
        }

        switch self {
        case .leaf(let leaf):
            guard leaf.surfaceId == surfaceId else { return nil }
            return newFirst
                ? .split(orientation: orientation, first: .leaf(newLeaf), second: self)
                : .split(orientation: orientation, first: self, second: .leaf(newLeaf))
        case .split(let existingOrientation, let first, let second):
            if let replaced = first.splitting(surfaceId: surfaceId, direction: direction, newLeaf: newLeaf) {
                return .split(orientation: existingOrientation, first: replaced, second: second)
            }
            if let replaced = second.splitting(surfaceId: surfaceId, direction: direction, newLeaf: newLeaf) {
                return .split(orientation: existingOrientation, first: first, second: replaced)
            }
            return nil
        }
    }

    /// Selects a surface within its pane (a tab click), leaving the split
    /// structure untouched.
    func selecting(surfaceId: UUID) -> PaneNode {
        switch self {
        case .leaf(var leaf):
            guard leaf.contains(surfaceId: surfaceId) else { return self }
            leaf.select(surfaceId: surfaceId)
            return .leaf(leaf)
        case .split(let orientation, let first, let second):
            return .split(
                orientation: orientation,
                first: first.selecting(surfaceId: surfaceId),
                second: second.selecting(surfaceId: surfaceId)
            )
        }
    }

    /// Appends a surface as a new tab in the pane hosting `anchor`.
    func addingTab(_ surface: PaneSurface, nextTo anchor: UUID) -> PaneNode? {
        switch self {
        case .leaf(var leaf):
            guard leaf.contains(surfaceId: anchor) else { return nil }
            leaf.surfaces.append(surface)
            leaf.selectedIndex = leaf.surfaces.count - 1
            return .leaf(leaf)
        case .split(let orientation, let first, let second):
            if let replaced = first.addingTab(surface, nextTo: anchor) {
                return .split(orientation: orientation, first: replaced, second: second)
            }
            if let replaced = second.addingTab(surface, nextTo: anchor) {
                return .split(orientation: orientation, first: first, second: replaced)
            }
            return nil
        }
    }

    /// Inserts a surface into the pane `paneId` at `index` (clamped;
    /// nil = end) and selects it — surface.move's insertion half.
    func addingTab(_ surface: PaneSurface, toPane paneId: UUID, at index: Int?) -> PaneNode? {
        switch self {
        case .leaf(var leaf):
            guard leaf.paneId == paneId else { return nil }
            let position = min(max(index ?? leaf.surfaces.count, 0), leaf.surfaces.count)
            leaf.surfaces.insert(surface, at: position)
            leaf.selectedIndex = position
            return .leaf(leaf)
        case .split(let orientation, let first, let second):
            if let replaced = first.addingTab(surface, toPane: paneId, at: index) {
                return .split(orientation: orientation, first: replaced, second: second)
            }
            if let replaced = second.addingTab(surface, toPane: paneId, at: index) {
                return .split(orientation: orientation, first: first, second: replaced)
            }
            return nil
        }
    }

    /// Moves `surfaceId` to `index` within its own pane's tab list
    /// (clamped) — surface.reorder. Selection follows the moved surface.
    func reorderingTab(surfaceId: UUID, to index: Int) -> PaneNode? {
        switch self {
        case .leaf(var leaf):
            guard let from = leaf.surfaces.firstIndex(where: { $0.surfaceId == surfaceId })
            else { return nil }
            let surface = leaf.surfaces.remove(at: from)
            let position = min(max(index, 0), leaf.surfaces.count)
            leaf.surfaces.insert(surface, at: position)
            leaf.selectedIndex = position
            return .leaf(leaf)
        case .split(let orientation, let first, let second):
            if let replaced = first.reorderingTab(surfaceId: surfaceId, to: index) {
                return .split(orientation: orientation, first: replaced, second: second)
            }
            if let replaced = second.reorderingTab(surfaceId: surfaceId, to: index) {
                return .split(orientation: orientation, first: first, second: replaced)
            }
            return nil
        }
    }

    /// Exchanges the CONTENTS of two panes (tmux swap-pane): surfaces and
    /// selection swap, pane identities and divider geometry stay put.
    func swappingPanes(_ a: UUID, _ b: UUID) -> PaneNode? {
        guard let paneA = leaves.first(where: { $0.paneId == a }),
              let paneB = leaves.first(where: { $0.paneId == b }) else { return nil }
        func replace(_ node: PaneNode) -> PaneNode {
            switch node {
            case .leaf(var leaf):
                if leaf.paneId == a {
                    leaf.surfaces = paneB.surfaces
                    leaf.selectedIndex = paneB.selectedIndex
                } else if leaf.paneId == b {
                    leaf.surfaces = paneA.surfaces
                    leaf.selectedIndex = paneA.selectedIndex
                }
                return .leaf(leaf)
            case .split(let orientation, let first, let second):
                return .split(orientation: orientation, first: replace(first), second: replace(second))
            }
        }
        return replace(self)
    }

    /// Removes the leaf holding `surfaceId`; the sibling subtree takes the
    /// removed node's place. Returns nil when this node itself disappears.
    ///
    /// A pane with several tabs loses only the one tab — dropping the whole
    /// pane because one of its tabs closed would take the others with it.
    func removing(surfaceId: UUID) -> PaneNode? {
        switch self {
        case .leaf(var leaf):
            guard leaf.contains(surfaceId: surfaceId) else { return self }
            if leaf.surfaces.count > 1 {
                let index = leaf.surfaces.firstIndex { $0.surfaceId == surfaceId }
                leaf.surfaces.removeAll { $0.surfaceId == surfaceId }
                if let index { leaf.selectedIndex = max(0, min(index, leaf.surfaces.count - 1)) }
                return .leaf(leaf)
            }
            return nil
        case .split(let orientation, let first, let second):
            let newFirst = first.removing(surfaceId: surfaceId)
            let newSecond = second.removing(surfaceId: surfaceId)
            switch (newFirst, newSecond) {
            case (nil, let sibling?), (let sibling?, nil):
                return sibling
            case (let one?, let two?):
                return .split(orientation: orientation, first: one, second: two)
            case (nil, nil):
                return nil
            }
        }
    }
}

/// One sidebar row as displayed: an ungrouped workspace, a visible group
/// member, or a group header (the anchor rendering as the group's
/// disclosure row). Pure value — this is the sidebar's snapshot boundary:
/// rows carry no references into live state.
struct SidebarRowModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case workspace
        case groupHeader(groupId: UUID, collapsed: Bool, memberCount: Int, pinned: Bool)
    }
    /// The workspace id (for a header: the anchor's). Selecting the row
    /// selects this workspace through the ordinary selection binding —
    /// which is exactly the macOS "header click selects the anchor".
    let id: UUID
    var title: String
    var kind: Kind
    /// Header tint, validated to a hex color (Pango-safe); nil elsewhere.
    var colorHex: String? = nil
    /// GTK themed icon for header rows (mapped from the stored macOS
    /// SF Symbol name; `folder-symbolic` default); nil on plain rows.
    var iconName: String? = nil
    /// True for group-member rows (context menu offers Remove from Group).
    var inGroup: Bool = false
}

/// One context-menu entry — pure value, shared between the popover
/// builder and `debug.sidebar_menu` (wiring/09 shared-projection rule).
struct SidebarMenuItem: Equatable {
    let id: String
    let title: String
    var destructive: Bool = false
    var enabled: Bool = true
}

/// The right-click menu contents per sidebar row — the macOS menus'
/// core slice (MACOS-UX §4), restricted to actions the port serves.
enum SidebarContextMenuModel {
    static func items(for row: SidebarRowModel, workspaceCount: Int) -> [SidebarMenuItem] {
        if case let .groupHeader(_, collapsed, _, pinned) = row.kind {
            return [
                SidebarMenuItem(id: "new_in_group", title: "New Workspace in Group"),
                SidebarMenuItem(id: "rename_group", title: "Rename Group…"),
                SidebarMenuItem(id: "pin_group", title: pinned ? "Unpin Group" : "Pin Group"),
                SidebarMenuItem(
                    id: "collapse_group", title: collapsed ? "Expand Group" : "Collapse Group"),
                SidebarMenuItem(id: "ungroup", title: "Ungroup Workspaces"),
                SidebarMenuItem(id: "delete_group", title: "Delete Group", destructive: true)
            ]
        }
        var items = [
            SidebarMenuItem(id: "rename_workspace", title: "Rename Workspace…"),
            SidebarMenuItem(
                id: "close_others", title: "Close Other Workspaces",
                enabled: workspaceCount > 1)
        ]
        items.append(row.inGroup
            ? SidebarMenuItem(id: "remove_from_group", title: "Remove from Group")
            : SidebarMenuItem(id: "new_group", title: "New Group from Workspace…"))
        items.append(SidebarMenuItem(id: "copy_id", title: "Copy Workspace ID"))
        items.append(SidebarMenuItem(
            id: "close_workspace", title: "Close Workspace", destructive: true))
        return items
    }
}

/// Pure projection (tabs, groups) → displayed sidebar rows. The single
/// source of truth for BOTH the sidebar view and `debug.sidebar_rows`
/// (shared-behavior rule) — a suite assertion on the verb is an assertion
/// on what the human sees.
enum SidebarRows {
    /// Only a strict hex color reaches Pango markup — the verb stores
    /// arbitrary strings (macOS parity), the renderer guards. The grammar
    /// must match what Pango actually parses: 3/4/6/8 hex digits — a
    /// permissive `{3,8}` let 5/7-digit values through and broke the
    /// header markup persistently (QA find, 2026-07-24).
    static func validatedHex(_ raw: String?) -> String? {
        guard let raw,
              raw.range(
                  of: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$",
                  options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    /// The stored icon is a free-form SF Symbol name (macOS vocabulary);
    /// map the common ones onto GTK themed icons, defaulting to the
    /// folder — the same default macOS renders (`folder.fill`).
    static func gtkIconName(forSymbol symbol: String?) -> String {
        switch symbol?.split(separator: ".").first.map(String.init) {
        case "star": return "starred-symbolic"
        case "hammer", "wrench": return "applications-engineering-symbolic"
        case "terminal", "apple": return "utilities-terminal-symbolic"
        case "globe", "network", "safari": return "web-browser-symbolic"
        case "book", "text": return "accessories-dictionary-symbolic"
        case "flask", "testtube": return "applications-science-symbolic"
        case "person", "figure": return "system-users-symbolic"
        case "heart": return "emblem-favorite-symbolic"
        default: return "folder-symbolic"
        }
    }

    /// GLib markup escaping for the header label (its Text renders with
    /// `useMarkup` so the color span works; the NAME must never parse).
    static func markupEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func project(tabs: [TerminalTab], groups: [WorkspaceGroup]) -> [SidebarRowModel] {
        var rows: [SidebarRowModel] = []
        for tab in tabs {
            guard let gid = tab.groupId,
                  let group = groups.first(where: { $0.id == gid }) else {
                rows.append(SidebarRowModel(
                    id: tab.id,
                    title: (tab.needsAttention ? "●  " : "") + tab.title,
                    kind: .workspace
                ))
                continue
            }
            let members = tabs.filter { $0.groupId == gid }
            if tab.id == group.anchorWorkspaceId {
                // Collapsed headers aggregate every member's attention —
                // a hidden member's unread must still be visible.
                let attention = group.isCollapsed
                    ? members.contains { $0.needsAttention }
                    : tab.needsAttention
                let name = group.name.isEmpty ? tab.title : group.name
                let count = group.isCollapsed ? "  (\(members.count))" : ""
                rows.append(SidebarRowModel(
                    id: tab.id,
                    title: (attention ? "●  " : "") + name + count,
                    kind: .groupHeader(
                        groupId: gid,
                        collapsed: group.isCollapsed,
                        memberCount: members.count,
                        pinned: group.isPinned
                    ),
                    colorHex: validatedHex(group.customColor),
                    iconName: gtkIconName(forSymbol: group.iconSymbol)
                ))
            } else if !group.isCollapsed {
                rows.append(SidebarRowModel(
                    id: tab.id,
                    title: "      " + (tab.needsAttention ? "●  " : "") + tab.title,
                    kind: .workspace,
                    inGroup: true
                ))
            }
        }
        return rows
    }
}

/// A named, collapsible sidebar group of workspaces — mirroring the macOS
/// `WorkspaceGroup` value exactly: the group stores NO member list.
/// Membership is a relation on each workspace (`TerminalTab.groupId`);
/// members are always derived by filtering tabs. The anchor is a real
/// member workspace rendered as the group header; closing it dissolves
/// the group. Sidebar invariant (normalizeGroupContiguity): contiguous
/// group runs, anchor-first member order, pinned groups above unpinned
/// top-level rows.
struct WorkspaceGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    var isPinned: Bool
    var anchorWorkspaceId: UUID
    /// Hex tint; nil → no tint. (macOS falls back to the cwd-config color
    /// from cmux.json — not wired on Linux yet.)
    var customColor: String?
    /// Free-form icon name, stored verbatim like macOS's SF Symbol string.
    /// No renderability check here — there are no SF Symbols on Linux; the
    /// stage-2 sidebar UI maps known names onto themed icons.
    var iconSymbol: String?

    init(
        id: UUID = UUID(),
        name: String,
        anchorWorkspaceId: UUID,
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        customColor: String? = nil,
        iconSymbol: String? = nil
    ) {
        self.id = id
        self.name = name
        self.anchorWorkspaceId = anchorWorkspaceId
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}

/// A workspace tab: title, attention state and a pane tree of surfaces —
/// mirroring the macOS `Workspace`/`TabManager` entries.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    /// User-pinned title (workspace.rename) — while set, OSC title updates
    /// from the shell no longer overwrite `title` (macOS setCustomTitle).
    var customTitle: String?
    var workingDirectory: String
    var layout: PaneNode
    var focusedSurfaceId: UUID
    /// Set when an AI agent in this tab is waiting for input — the Linux
    /// equivalent of cmux's notification rings on macOS.
    var needsAttention: Bool
    /// While set, this surface's pane fills the workspace and the rest of
    /// the split tree is not built (macOS `toggleSplitZoom`). Deliberately
    /// NOT persisted: zoom is a momentary "let me see this" state, and
    /// restoring into it would hide panes the user forgot they had.
    var zoomedSurfaceId: UUID?
    /// Bumped when a surface in this workspace is torn down for respawn
    /// (surface.respawn on a ghostty pane). Part of the view sync's shape
    /// signature, so the bump forces the subtree rebuild that destroys
    /// the old widget and mounts the replacement. Transient, not
    /// persisted.
    var respawnNonce: Int = 0
    /// The workspace group this tab belongs to, if any (macOS
    /// `Workspace.groupId`). The group's member list is always derived
    /// from this relation, never stored on the group.
    var groupId: UUID? = nil

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        needsAttention: Bool = false
    ) {
        let leaf = PaneLeaf(workingDirectory: workingDirectory)
        self.id = id
        self.title = title
        self.customTitle = nil
        self.workingDirectory = workingDirectory
        self.layout = .leaf(leaf)
        self.focusedSurfaceId = leaf.surfaceId
        self.needsAttention = needsAttention
        self.zoomedSurfaceId = nil
    }

    /// The workspace's panes. Named `surfaces` historically, when a pane
    /// could only hold one; kept because most callers want "the pane and
    /// the surface it is showing".
    var surfaces: [PaneLeaf] { layout.leaves }

    var panes: [PaneLeaf] { layout.leaves }

    /// Every surface in the workspace, including tabs that are not on top.
    /// Anything that must not miss a background tab — session save, pane
    /// search, widget construction, registry cleanup — uses this.
    var allSurfaces: [(paneId: UUID, surface: PaneSurface)] {
        layout.leaves.flatMap { pane in
            pane.surfaces.map { (pane.paneId, $0) }
        }
    }

    /// The pane showing the focused surface, falling back to the first.
    var focusedSurface: PaneLeaf? {
        surfaces.first { $0.contains(surfaceId: focusedSurfaceId) } ?? surfaces.first
    }

    func contains(surfaceId: UUID) -> Bool {
        surfaces.contains { $0.contains(surfaceId: surfaceId) }
    }
}

/// Mirror of the macOS `TerminalNotification` (TerminalNotificationStore.swift)
/// — one attention event delivered by an agent/CLI for a tab.
struct TerminalNotification: Identifiable, Equatable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    var title: String
    var subtitle: String
    var body: String
    var isRead: Bool

    init(
        id: UUID = UUID(),
        tabId: UUID,
        surfaceId: UUID? = nil,
        title: String,
        subtitle: String = "",
        body: String = "",
        isRead: Bool = false
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.isRead = isRead
    }
}
