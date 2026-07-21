import CWebKit
import Foundation

/// Browser profiles: isolated cookie/storage/cache spaces per profile,
/// mirroring macOS cmux's `BrowserProfileStore` (roadmap/07).
///
/// One `WebKitNetworkSession` per profile, shared by every pane of that
/// profile — that sharing is what makes a profile one "container": all
/// "work" panes see each other's logins, other profiles see none of it.
/// The built-in default profile maps to WebKit's default session (what
/// every pane used before profiles existed), so pre-profile browsing
/// state stays where it was.
///
/// Wire format, names and slug rules deliberately match the macOS
/// implementation (`BrowserProfileDefinition`, `BrowserProfileAutomation`)
/// so `cmux browser profiles …` behaves identically on both platforms.
enum BrowserProfiles {

    struct Definition: Codable, Equatable {
        let id: UUID
        var displayName: String
        let createdAt: TimeInterval
        let isBuiltInDefault: Bool

        /// URL/socket-safe identifier derived from the name — same rules
        /// as macOS: the built-in default always slugs to "default",
        /// others lowercase, collapse non-alphanumerics to "-", trim,
        /// and fall back to the UUID when nothing is left.
        var slug: String {
            if isBuiltInDefault { return "default" }
            var out = ""
            var lastDash = true
            for scalar in displayName.lowercased().unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    out.append(Character(scalar))
                    lastDash = false
                } else if !lastDash {
                    out.append("-")
                    lastDash = true
                }
            }
            while out.hasSuffix("-") { out.removeLast() }
            return out.isEmpty ? id.uuidString.lowercased() : out
        }
    }

    /// The store file, next to the session file — a test instance pointed
    /// at its own `CMUX_SESSION_PATH` gets its own profiles (and its own
    /// profile data), never the user's.
    private static var storeURL: URL {
        SessionStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("browser-profiles.json")
    }

    static var profilesDirectory: URL {
        SessionStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("profiles")
    }

    private struct StoreFile: Codable {
        var profiles: [Definition]
        var lastUsedProfileID: UUID?
    }

    static let builtInDefaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static var loaded: StoreFile?

    private static func load() -> StoreFile {
        if let loaded { return loaded }
        var file: StoreFile
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(StoreFile.self, from: data) {
            file = decoded
        } else {
            file = StoreFile(profiles: [], lastUsedProfileID: nil)
        }
        if !file.profiles.contains(where: { $0.isBuiltInDefault }) {
            // The built-in default sorts first via the epoch timestamp,
            // like macOS.
            file.profiles.insert(Definition(
                id: builtInDefaultID, displayName: "Default",
                createdAt: 0, isBuiltInDefault: true
            ), at: 0)
        }
        loaded = file
        return file
    }

    private static func save(_ file: StoreFile) {
        loaded = file
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(file) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    // MARK: queries

    static var all: [Definition] { load().profiles }

    static var effectiveLastUsedID: UUID {
        let file = load()
        if let last = file.lastUsedProfileID,
           file.profiles.contains(where: { $0.id == last }) {
            return last
        }
        return builtInDefaultID
    }

    /// Resolves a CLI query — id, slug, or display name (case-insensitive),
    /// like macOS's `resolveProfile`. Throws on ambiguity so a typo can
    /// never silently pick the wrong container.
    static func resolve(_ query: String) throws -> Definition {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let profiles = load().profiles
        if let uuid = UUID(uuidString: trimmed),
           let exact = profiles.first(where: { $0.id == uuid }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        let matches = profiles.filter {
            $0.slug == lowered || $0.displayName.lowercased() == lowered
        }
        guard let first = matches.first else {
            throw ProfileError.notFound(trimmed)
        }
        guard matches.count == 1 else {
            throw ProfileError.ambiguous(trimmed)
        }
        return first
    }

    enum ProfileError: Error {
        case notFound(String)
        case ambiguous(String)
        case duplicateName(String)
        case builtInDefault(String)
        case inUse(String, Int)

        var message: String {
            switch self {
            case .notFound(let q): return "No cmux browser profile matches '\(q)'."
            case .ambiguous(let q): return "Multiple cmux browser profiles match '\(q)'. Use the profile ID instead."
            case .duplicateName(let n): return "A browser profile named '\(n)' already exists."
            case .builtInDefault(let op): return "The built-in default profile cannot be \(op)."
            case .inUse(let n, let count): return "Browser profile '\(n)' is in use by \(count) open pane\(count == 1 ? "" : "s")."
            }
        }
    }

    // MARK: mutations (mirror macOS create/rename/delete/clear semantics)

    static func create(named rawName: String) throws -> Definition {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.notFound(rawName) }
        var file = load()
        guard !file.profiles.contains(where: { $0.displayName.lowercased() == name.lowercased() }) else {
            throw ProfileError.duplicateName(name)
        }
        let profile = Definition(
            id: UUID(), displayName: name,
            createdAt: Date().timeIntervalSince1970, isBuiltInDefault: false
        )
        file.profiles.append(profile)
        save(file)
        return profile
    }

    static func rename(_ query: String, to rawName: String) throws -> Definition {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = try resolve(query)
        guard !profile.isBuiltInDefault else { throw ProfileError.builtInDefault("renamed") }
        var file = load()
        guard !file.profiles.contains(where: {
            $0.id != profile.id && $0.displayName.lowercased() == name.lowercased()
        }) else { throw ProfileError.duplicateName(name) }
        guard let index = file.profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ProfileError.notFound(query)
        }
        file.profiles[index].displayName = name
        save(file)
        return file.profiles[index]
    }

    static func delete(_ query: String, liveCount: (UUID) -> Int) throws -> Definition {
        let profile = try resolve(query)
        guard !profile.isBuiltInDefault else { throw ProfileError.builtInDefault("deleted") }
        let inUse = liveCount(profile.id)
        guard inUse == 0 else { throw ProfileError.inUse(profile.displayName, inUse) }
        var file = load()
        file.profiles.removeAll { $0.id == profile.id }
        if file.lastUsedProfileID == profile.id { file.lastUsedProfileID = nil }
        save(file)
        sessions.removeValue(forKey: profile.id)
        try? FileManager.default.removeItem(at: directory(for: profile.id))
        return profile
    }

    /// Clears a profile's site data (cookies, storage, cache). Only when
    /// no pane currently uses it: WebKit's live-session clear is async and
    /// racy against open pages; requiring the panes closed keeps "cleared"
    /// meaning cleared. (macOS clears live stores; noted in PARITY.)
    static func clear(_ query: String, liveCount: (UUID) -> Int) throws -> Definition {
        let profile = try resolve(query)
        let inUse = liveCount(profile.id)
        guard inUse == 0 else { throw ProfileError.inUse(profile.displayName, inUse) }
        sessions.removeValue(forKey: profile.id)
        try? FileManager.default.removeItem(at: directory(for: profile.id))
        return profile
    }

    static func noteUsed(_ id: UUID) {
        var file = load()
        guard file.lastUsedProfileID != id else { return }
        file.lastUsedProfileID = id
        save(file)
    }

    // MARK: WebKit sessions

    private static var sessions: [UUID: OpaquePointer] = [:]

    private static func directory(for id: UUID) -> URL {
        profilesDirectory.appendingPathComponent(id.uuidString)
    }

    /// The network session for a profile; nil means "use WebKit's default"
    /// (the built-in default profile — pre-profile state lives there).
    static func session(for id: UUID) -> OpaquePointer? {
        guard id != builtInDefaultID else { return nil }
        if let cached = sessions[id] { return cached }
        let base = directory(for: id)
        let data = base.appendingPathComponent("data")
        let cache = base.appendingPathComponent("cache")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        guard let session = webkit_network_session_new(data.path, cache.path) else { return nil }
        // Cookies do not persist automatically in a custom session — the
        // data directory only covers storage/cache. Without this line a
        // profile's logins survive the session but not a restart.
        if let cookies = webkit_network_session_get_cookie_manager(session) {
            webkit_cookie_manager_set_persistent_storage(
                cookies,
                data.appendingPathComponent("cookies.sqlite").path,
                WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE
            )
        }
        sessions[id] = session
        return session
    }
}

/// Which profile each browser surface belongs to.
///
/// `pending` carries the assignment from the verb/restore into the
/// factory (the network session is construct-only, so it must be known
/// before the web view exists); `live` is what persistence and the
/// in-use checks read. Same two-phase shape as `BrowserRestoreStore`.
enum BrowserProfileAssignments {
    static var pending: [UUID: UUID] = [:]
    static var live: [UUID: UUID] = [:]

    static func liveCount(of profileId: UUID) -> Int {
        live.values.filter { $0 == profileId }.count
    }

    static func forget(_ surfaceId: UUID) {
        pending.removeValue(forKey: surfaceId)
        live.removeValue(forKey: surfaceId)
    }
}
