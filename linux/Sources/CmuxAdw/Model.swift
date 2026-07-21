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

/// One surface inside a workspace's pane tree. MVP: one surface per
/// pane (macOS Bonsplit panes carry their own tab strips — later phase).
struct PaneLeaf: Equatable {
    let paneId: UUID
    let surfaceId: UUID
    var kind: SurfaceKind
    /// Working directory the surface's shell was (or will be) spawned in
    /// (terminals only).
    var workingDirectory: String

    init(
        paneId: UUID = UUID(),
        surfaceId: UUID = UUID(),
        kind: SurfaceKind = .terminal,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.paneId = paneId
        self.surfaceId = surfaceId
        self.kind = kind
        self.workingDirectory = workingDirectory
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
            return leaf.surfaceId.uuidString
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

    /// Removes the leaf holding `surfaceId`; the sibling subtree takes the
    /// removed node's place. Returns nil when this node itself disappears.
    func removing(surfaceId: UUID) -> PaneNode? {
        switch self {
        case .leaf(let leaf):
            return leaf.surfaceId == surfaceId ? nil : self
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
    }

    var surfaces: [PaneLeaf] { layout.leaves }

    /// The focused surface, falling back to the first leaf.
    var focusedSurface: PaneLeaf? {
        surfaces.first { $0.surfaceId == focusedSurfaceId } ?? surfaces.first
    }

    func contains(surfaceId: UUID) -> Bool {
        surfaces.contains { $0.surfaceId == surfaceId }
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
