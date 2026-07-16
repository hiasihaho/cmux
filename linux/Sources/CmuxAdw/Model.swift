import Foundation

/// A single terminal tab, mirroring the role of `Workspace`/`TabManager`
/// entries in the macOS app. Pure model — portable across platforms.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    /// Placeholder surface identity until Phase 2 introduces real terminal
    /// surfaces — lets the CLI's workspace→surface resolution work today.
    let surfaceId: UUID
    var title: String
    var workingDirectory: String
    /// Set when an AI agent in this tab is waiting for input — the Linux
    /// equivalent of cmux's notification rings on macOS.
    var needsAttention: Bool

    init(
        id: UUID = UUID(),
        surfaceId: UUID = UUID(),
        title: String,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        needsAttention: Bool = false
    ) {
        self.id = id
        self.surfaceId = surfaceId
        self.title = title
        self.workingDirectory = workingDirectory
        self.needsAttention = needsAttention
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
