import Foundation

/// Session persistence — the Linux counterpart of the macOS
/// `SessionPersistence.swift`: workspaces and their pane trees as versioned
/// JSON, stored under the XDG data home instead of Application Support.
/// Shell working directories are captured live (OSC 7) at save time so a
/// restored session reopens shells where they were.
enum SessionStore {

    /// v3 normalizes the layout the way macOS cmux always has: surfaces
    /// live once in a flat array and the tree references them by id, so a
    /// pane can carry several (tabs). v2 inlined the surface into the leaf,
    /// which is exactly why multi-tab panes could not round-trip.
    static let schemaVersion = 3

    struct Snapshot: Codable, Equatable {
        var version: Int
        var selectedIndex: Int
        var tabCounter: Int
        var workspaces: [WorkspaceSnapshot]
        /// Workspace groups; optional so files written before groups
        /// existed decode unchanged (the BrowserSnapshot.profile pattern).
        var groups: [GroupSnapshot]? = nil
    }

    struct WorkspaceSnapshot: Codable, Equatable {
        var title: String
        var customTitle: String?
        var workingDirectory: String
        /// Flat, id-keyed; the layout tree references these.
        var surfaces: [SurfaceSnapshot]
        var layout: LayoutSnapshot
        var focusedSurfaceId: String?
        /// Index into `Snapshot.groups`; absent = ungrouped. Index-based
        /// (like macOS's `anchorMemberIndex` trick) because workspace
        /// UUIDs are not persisted and change on restore.
        var groupIndex: Int? = nil
    }

    /// One workspace group. Membership rides on each workspace
    /// (`groupIndex`); the anchor is identified by its 0-based position
    /// among the group's members in workspace order — restore-stable
    /// without persisted UUIDs, mirroring the macOS snapshot.
    struct GroupSnapshot: Codable, Equatable {
        var name: String
        var isCollapsed: Bool
        var isPinned: Bool
        var anchorMemberIndex: Int
        var customColor: String?
        var iconSymbol: String?
    }

    struct SurfaceSnapshot: Codable, Equatable {
        var id: String
        var type: String
        var workingDirectory: String
        /// User-pinned tab title (`tab.action rename`); absent = derived.
        var title: String?
        var browser: BrowserSnapshot?
        /// Terminal screen text, replayed on restore so a restored pane
        /// shows what was on it. Optional, so files written before this
        /// still decode.
        var scrollback: String?
    }

    /// `url`/`zoom`/history are the portable baseline (what macOS stores).
    /// `sessionState` is WebKitGTK's own blob — richer, optional, and never
    /// load-bearing; see BrowserSessionState for the layering rule.
    struct BrowserSnapshot: Codable, Equatable {
        var url: String
        var zoom: Double?
        var backURLs: [String]?
        var forwardURLs: [String]?
        var sessionState: String?
        /// Browser profile UUID; absent = the built-in default, so files
        /// written before profiles existed decode unchanged.
        var profile: String?
    }

    indirect enum LayoutSnapshot: Codable, Equatable {
        /// A pane and its tabs. `selectedId` is the one on top.
        case pane(surfaceIds: [String], selectedId: String?)
        /// Fraction of the paned's extent, matching macOS. Optional so v3
        /// files written before dividers were persisted still decode.
        case split(
            orientation: String, first: LayoutSnapshot, second: LayoutSnapshot,
            dividerPosition: Double? = nil
        )
    }

    // MARK: v2 (read-only — migrated on load, never written)

    private struct VersionProbe: Codable { var version: Int }

    private struct SnapshotV2: Codable {
        var version: Int
        var selectedIndex: Int
        var tabCounter: Int
        var workspaces: [WorkspaceSnapshotV2]
    }

    private struct WorkspaceSnapshotV2: Codable {
        var title: String
        var customTitle: String?
        var workingDirectory: String
        var layout: LayoutSnapshotV2
        var focusedLeafIndex: Int
    }

    private indirect enum LayoutSnapshotV2: Codable {
        case leaf(kind: String, workingDirectory: String, url: String)
        case split(orientation: String, first: LayoutSnapshotV2, second: LayoutSnapshotV2)
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

    /// Set by the app: performs a save with the current model. Lets code
    /// that has no access to the model (a WebKit signal handler, say) ask
    /// for one.
    static var saveHook: (() -> Void)?
    private static var savePending = false

    /// Debounced save request. A navigation is not a model change, so
    /// browser state used to reach disk only on the 15s timer — quit a few
    /// seconds after navigating and the file still held the previous URL,
    /// which is exactly when a user expects their session to be captured.
    /// Debounced rather than immediate because a single navigation emits
    /// several load events, and this writes the whole session file.
    static func requestSave(afterMs: UInt32 = 1500) {
        guard !savePending else { return }
        savePending = true
        scheduleOnMainLoop(afterMs: afterMs) {
            savePending = false
            saveHook?()
        }
    }


    // MARK: save

    /// Set for the save that runs as the window closes: scrollback is then
    /// read unthrottled, because there is no later save to catch up.
    static var isFinalSave = false

    static func saveIfChanged(
        tabs: [TerminalTab], selection: UUID, tabCounter: Int,
        groups: [WorkspaceGroup] = []
    ) {
        guard !tabs.isEmpty else { return }
        let snapshot = snapshot(
            tabs: tabs, selection: selection, tabCounter: tabCounter, groups: groups)
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

    private static func snapshot(
        tabs: [TerminalTab], selection: UUID, tabCounter: Int,
        groups: [WorkspaceGroup]
    ) -> Snapshot {
        // Drop scrollback files for surfaces that no longer exist, or a
        // closed pane's text would outlive it indefinitely.
        ScrollbackStore.prune(keeping: Set(tabs.flatMap { $0.allSurfaces.map(\.surface.surfaceId) }))
        // Only groups that still have members are worth persisting.
        let liveGroups = groups.filter { group in
            tabs.contains { $0.groupId == group.id }
        }
        let groupSnapshots: [GroupSnapshot] = liveGroups.map { group in
            let members = tabs.filter { $0.groupId == group.id }
            return GroupSnapshot(
                name: group.name,
                isCollapsed: group.isCollapsed,
                isPinned: group.isPinned,
                anchorMemberIndex: members.firstIndex { $0.id == group.anchorWorkspaceId } ?? 0,
                customColor: group.customColor,
                iconSymbol: group.iconSymbol
            )
        }
        return Snapshot(
            version: schemaVersion,
            selectedIndex: tabs.firstIndex { $0.id == selection } ?? 0,
            tabCounter: tabCounter,
            workspaces: tabs.map { tab in
                var workspace = workspaceSnapshot(tab)
                workspace.groupIndex = tab.groupId.flatMap { gid in
                    liveGroups.firstIndex { $0.id == gid }
                }
                return workspace
            },
            groups: groupSnapshots.isEmpty ? nil : groupSnapshots
        )
    }

    private static func workspaceSnapshot(_ tab: TerminalTab) -> WorkspaceSnapshot {
        var surfaces: [SurfaceSnapshot] = []
        for (_, surface) in tab.allSurfaces {
            // Inspector panes are dropped: WebKit only surrenders the
            // DevTools widget during its own `attach` signal, so a restored
            // one would be a permanently empty pane.
            switch surface.kind {
            case .inspector:
                continue
            case .terminal:
                // Live cwd via OSC 7 beats the spawn-time directory.
                let cwd = SurfaceRegistry.shared.currentDirectory(for: surface.surfaceId)
                    ?? surface.workingDirectory
                // Scrollback goes to its own file, not into this document:
                // the session JSON is rewritten on every model change, so
                // inline text made every line of output rewrite everything.
                ScrollbackStore.capture(surfaceId: surface.surfaceId, force: isFinalSave)
                surfaces.append(SurfaceSnapshot(
                    id: surface.surfaceId.uuidString, type: "terminal",
                    workingDirectory: cwd,
                    title: PaneTabs.customTitles[surface.surfaceId],
                    browser: nil, scrollback: nil
                ))
            case .browser(let initialURL):
                var browser = BrowserSessionState.capture(
                    surfaceId: surface.surfaceId, fallbackURL: initialURL
                )
                if let profile = BrowserProfileAssignments.live[surface.surfaceId] {
                    browser?.profile = profile.uuidString
                }
                surfaces.append(SurfaceSnapshot(
                    id: surface.surfaceId.uuidString, type: "browser",
                    workingDirectory: "",
                    title: PaneTabs.customTitles[surface.surfaceId],
                    browser: browser
                ))
            }
        }
        let kept = Set(surfaces.map(\.id))
        return WorkspaceSnapshot(
            title: tab.title,
            customTitle: tab.customTitle,
            workingDirectory: tab.workingDirectory,
            surfaces: surfaces,
            // A workspace of nothing but inspector panes collapses to nil;
            // restore it as a plain terminal rather than losing the
            // workspace itself.
            layout: layoutSnapshot(
                tab.layout, kept: kept, dividers: PaneDividers.capture(tabId: tab.id)
            ) ?? .pane(surfaceIds: [], selectedId: nil),
            focusedSurfaceId: kept.contains(tab.focusedSurfaceId.uuidString)
                ? tab.focusedSurfaceId.uuidString : surfaces.first?.id
        )
    }

    /// Returns nil for a node whose surfaces were all dropped. A split with
    /// one pruned side collapses to the surviving side.
    private static func layoutSnapshot(
        _ node: PaneNode, kept: Set<String>,
        path: String = "", dividers: [String: Double] = [:]
    ) -> LayoutSnapshot? {
        switch node {
        case .leaf(let pane):
            let ids = pane.surfaces
                .map(\.surfaceId.uuidString)
                .filter(kept.contains)
            guard !ids.isEmpty else { return nil }
            let selected = pane.selected.surfaceId.uuidString
            return .pane(
                surfaceIds: ids,
                selectedId: ids.contains(selected) ? selected : ids.first
            )
        case .split(let orientation, let first, let second):
            let f = layoutSnapshot(first, kept: kept, path: path + "0", dividers: dividers)
            let s = layoutSnapshot(second, kept: kept, path: path + "1", dividers: dividers)
            switch (f, s) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                // A collapsed split takes the survivor's own divider with
                // it; this node's fraction no longer describes anything.
                return only
            case (let a?, let b?):
                return .split(
                    orientation: orientation.rawValue, first: a, second: b,
                    dividerPosition: dividers[path]
                )
            }
        }
    }

    // MARK: restore

    static func restore() -> (tabs: [TerminalTab], selection: UUID, tabCounter: Int, groups: [WorkspaceGroup])? {
        guard let data = try? Data(contentsOf: fileURL),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return nil }
        switch probe.version {
        case 3:
            guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
            return restoreV3(snapshot)
        case 2:
            // Migrated in place: a v2 file is read, converted, and the next
            // save writes v3. Refusing it would silently discard a real
            // session — the whole reason v2 stays decodable.
            guard let snapshot = try? JSONDecoder().decode(SnapshotV2.self, from: data) else { return nil }
            guard let restored = restoreV2(snapshot) else { return nil }
            return (restored.tabs, restored.selection, restored.tabCounter, [])
        default:
            return nil
        }
    }

    private static func restoreV3(_ snapshot: Snapshot) -> (tabs: [TerminalTab], selection: UUID, tabCounter: Int, groups: [WorkspaceGroup])? {
        guard !snapshot.workspaces.isEmpty else { return nil }
        var tabs: [TerminalTab] = snapshot.workspaces.map { workspace in
            var byId: [String: PaneSurface] = [:]
            for entry in workspace.surfaces {
                let id = UUID(uuidString: entry.id) ?? UUID()
                if let pinned = entry.title, !pinned.isEmpty {
                    PaneTabs.customTitles[id] = pinned
                }
                let kind: SurfaceKind
                if entry.type == "browser" {
                    kind = .browser(initialURL: entry.browser?.url ?? "")
                    // Parked for the surface factory; the richer state (zoom,
                    // history, WebKit blob) cannot ride in SurfaceKind.
                    if let browser = entry.browser {
                        BrowserRestoreStore.pending[id] = browser
                        // Profile before web-view construction: the network
                        // session is construct-only.
                        if let profileRaw = browser.profile,
                           let profileId = UUID(uuidString: profileRaw) {
                            BrowserProfileAssignments.pending[id] = profileId
                        }
                    }
                } else {
                    kind = .terminal
                    // Sessions written before scrollback moved out of band
                    // still carry it inline; prefer the file, keep the
                    // fallback so nothing is lost on the first upgrade.
                    if let text = ScrollbackStore.read(for: id) ?? entry.scrollback,
                       !text.isEmpty {
                        TerminalScrollbackStore.pending[id] = text
                    }
                }
                byId[entry.id] = PaneSurface(
                    surfaceId: id, kind: kind,
                    workingDirectory: entry.workingDirectory.isEmpty
                        ? workspace.workingDirectory : entry.workingDirectory
                )
            }
            var tab = TerminalTab(title: workspace.title, workingDirectory: workspace.workingDirectory)
            tab.customTitle = workspace.customTitle
            var dividers: [String: Double] = [:]
            tab.layout = layoutNode(workspace.layout, byId: byId, dividers: &dividers)
                ?? .leaf(PaneLeaf(workingDirectory: workspace.workingDirectory))
            PaneDividers.persisted[tab.id] = dividers
            let live = tab.allSurfaces.map(\.surface.surfaceId)
            tab.focusedSurfaceId = workspace.focusedSurfaceId
                .flatMap { UUID(uuidString: $0) }
                .flatMap { live.contains($0) ? $0 : nil }
                ?? live.first ?? tab.focusedSurfaceId
            return tab
        }
        // Rebuild groups: fresh UUIDs (workspace ids are new too), members
        // linked by index, anchor by position among members. A group whose
        // members all vanished is dropped.
        var groups: [WorkspaceGroup] = []
        for (index, entry) in (snapshot.groups ?? []).enumerated() {
            let memberPositions = snapshot.workspaces.indices.filter {
                snapshot.workspaces[$0].groupIndex == index
            }
            guard !memberPositions.isEmpty else { continue }
            let anchorPosition = memberPositions[safe: entry.anchorMemberIndex]
                ?? memberPositions[0]
            let group = WorkspaceGroup(
                name: entry.name,
                anchorWorkspaceId: tabs[anchorPosition].id,
                isCollapsed: entry.isCollapsed,
                isPinned: entry.isPinned,
                customColor: entry.customColor,
                iconSymbol: entry.iconSymbol
            )
            for position in memberPositions {
                tabs[position].groupId = group.id
            }
            groups.append(group)
        }
        let selected = tabs[safe: snapshot.selectedIndex] ?? tabs[0]
        return (tabs, selected.id, max(snapshot.tabCounter, tabs.count), groups)
    }

    private static func layoutNode(
        _ snapshot: LayoutSnapshot, byId: [String: PaneSurface],
        path: String = "", dividers: inout [String: Double]
    ) -> PaneNode? {
        switch snapshot {
        case .pane(let surfaceIds, let selectedId):
            let surfaces = surfaceIds.compactMap { byId[$0] }
            guard !surfaces.isEmpty else { return nil }
            let index = selectedId.flatMap { id in
                surfaces.firstIndex { $0.surfaceId.uuidString == id }
            } ?? 0
            return .leaf(PaneLeaf(surfaces: surfaces, selectedIndex: index))
        case .split(let orientation, let first, let second, let dividerPosition):
            if let dividerPosition { dividers[path] = dividerPosition }
            switch (
                layoutNode(first, byId: byId, path: path + "0", dividers: &dividers),
                layoutNode(second, byId: byId, path: path + "1", dividers: &dividers)
            ) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                return only
            case (let a?, let b?):
                return .split(
                    orientation: PaneNode.SplitOrientation(rawValue: orientation) ?? .horizontal,
                    first: a, second: b
                )
            }
        }
    }

    // MARK: v2 migration

    private static func restoreV2(_ snapshot: SnapshotV2) -> (tabs: [TerminalTab], selection: UUID, tabCounter: Int)? {
        guard !snapshot.workspaces.isEmpty else { return nil }
        let tabs: [TerminalTab] = snapshot.workspaces.map { workspace in
            var tab = TerminalTab(title: workspace.title, workingDirectory: workspace.workingDirectory)
            tab.customTitle = workspace.customTitle
            tab.layout = layoutNodeV2(workspace.layout)
            let leaves = tab.surfaces
            tab.focusedSurfaceId = (leaves[safe: workspace.focusedLeafIndex] ?? leaves.first
                ?? PaneLeaf()).surfaceId
            return tab
        }
        let selected = tabs[safe: snapshot.selectedIndex] ?? tabs[0]
        return (tabs, selected.id, max(snapshot.tabCounter, tabs.count))
    }

    private static func layoutNodeV2(_ snapshot: LayoutSnapshotV2) -> PaneNode {
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
                first: layoutNodeV2(first),
                second: layoutNodeV2(second)
            )
        }
    }
}
