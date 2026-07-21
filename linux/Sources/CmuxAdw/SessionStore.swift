import Foundation

/// Session persistence — the Linux counterpart of the macOS
/// `SessionPersistence.swift`: workspaces and their pane trees as versioned
/// JSON, stored under the XDG data home instead of Application Support.
/// Shell working directories are captured live (OSC 7) at save time so a
/// restored session reopens shells where they were.
enum SessionStore {

    static let schemaVersion = 2

    struct Snapshot: Codable, Equatable {
        var version: Int
        var selectedIndex: Int
        var tabCounter: Int
        var workspaces: [WorkspaceSnapshot]
    }

    struct WorkspaceSnapshot: Codable, Equatable {
        var title: String
        /// Optional so version-2 files without it keep decoding.
        var customTitle: String?
        var workingDirectory: String
        var layout: LayoutSnapshot
        var focusedLeafIndex: Int
    }

    indirect enum LayoutSnapshot: Codable, Equatable {
        case leaf(kind: String, workingDirectory: String, url: String)
        case split(orientation: String, first: LayoutSnapshot, second: LayoutSnapshot)
    }

    static var fileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CMUX_SESSION_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base: URL
        if let dataHome = environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            base = URL(fileURLWithPath: dataHome)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share")
        }
        return base.appendingPathComponent("cmux/session-linux.json")
    }

    private static var lastSaved: Data?

    // MARK: save

    static func saveIfChanged(tabs: [TerminalTab], selection: UUID, tabCounter: Int) {
        guard !tabs.isEmpty else { return }
        let snapshot = snapshot(tabs: tabs, selection: selection, tabCounter: tabCounter)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(snapshot), data != lastSaved else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            lastSaved = data
        } catch {
            FileHandle.standardError.write(Data("cmux: failed to save session: \(error)\n".utf8))
        }
    }

    private static func snapshot(tabs: [TerminalTab], selection: UUID, tabCounter: Int) -> Snapshot {
        Snapshot(
            version: schemaVersion,
            selectedIndex: tabs.firstIndex { $0.id == selection } ?? 0,
            tabCounter: tabCounter,
            workspaces: tabs.map { tab in
                WorkspaceSnapshot(
                    title: tab.title,
                    customTitle: tab.customTitle,
                    workingDirectory: tab.workingDirectory,
                    // A workspace of nothing but inspector panes collapses to
                    // nil; restore it as a plain terminal rather than losing
                    // the workspace itself.
                    layout: layoutSnapshot(tab.layout)
                        ?? .leaf(kind: "terminal", workingDirectory: tab.workingDirectory, url: ""),
                    focusedLeafIndex: tab.surfaces.firstIndex {
                        $0.surfaceId == tab.focusedSurfaceId
                    } ?? 0
                )
            }
        )
    }

    /// Returns nil for panes that must not survive a restart. Inspector
    /// panes are the only such kind today: WebKit only hands out the
    /// inspector widget during its own `attach` signal, so there is nothing
    /// to recreate on restore — persisting one would resurrect an empty
    /// pane. A split with one pruned side collapses to the surviving side.
    private static func layoutSnapshot(_ node: PaneNode) -> LayoutSnapshot? {
        switch node {
        case .leaf(let leaf):
            switch leaf.kind {
            case .terminal:
                // Live cwd via OSC 7 beats the spawn-time directory.
                let cwd = SurfaceRegistry.shared.currentDirectory(for: leaf.surfaceId)
                    ?? leaf.workingDirectory
                return .leaf(kind: "terminal", workingDirectory: cwd, url: "")
            case .browser(let initialURL):
                // Live page URL beats the initial one.
                let url = SurfaceRegistry.shared.currentURL(for: leaf.surfaceId) ?? initialURL
                return .leaf(kind: "browser", workingDirectory: "", url: url)
            case .inspector:
                return nil
            }
        case .split(let orientation, let first, let second):
            switch (layoutSnapshot(first), layoutSnapshot(second)) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                return only
            case (let a?, let b?):
                return .split(orientation: orientation.rawValue, first: a, second: b)
            }
        }
    }

    // MARK: restore

    static func restore() -> (tabs: [TerminalTab], selection: UUID, tabCounter: Int)? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == schemaVersion,
              !snapshot.workspaces.isEmpty else { return nil }

        let tabs: [TerminalTab] = snapshot.workspaces.map { workspace in
            var tab = TerminalTab(
                title: workspace.title,
                workingDirectory: workspace.workingDirectory
            )
            tab.customTitle = workspace.customTitle
            tab.layout = layoutNode(workspace.layout)
            let leaves = tab.surfaces
            tab.focusedSurfaceId = (leaves[safe: workspace.focusedLeafIndex] ?? leaves.first
                ?? PaneLeaf()).surfaceId
            return tab
        }
        let selected = tabs[safe: snapshot.selectedIndex] ?? tabs[0]
        return (tabs, selected.id, max(snapshot.tabCounter, tabs.count))
    }

    private static func layoutNode(_ snapshot: LayoutSnapshot) -> PaneNode {
        switch snapshot {
        case .leaf(let kind, let workingDirectory, let url):
            if kind == "browser" {
                return .leaf(PaneLeaf(kind: .browser(initialURL: url)))
            }
            let cwd = workingDirectory.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : workingDirectory
            return .leaf(PaneLeaf(workingDirectory: cwd))
        case .split(let orientation, let first, let second):
            return .split(
                orientation: PaneNode.SplitOrientation(rawValue: orientation) ?? .horizontal,
                first: layoutNode(first),
                second: layoutNode(second)
            )
        }
    }
}
