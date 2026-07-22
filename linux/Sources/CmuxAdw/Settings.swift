import Foundation

/// Persistent app settings for the Linux port.
///
/// Stored in the same file macOS cmux uses — `~/.config/cmux/cmux.json` —
/// under a `"linux"` object, so the two schemas can never collide and a
/// dotfiles repo can carry one cmux config for both platforms.
///
/// Resolution order, deliberately: **environment > file > default**. The
/// env vars came first and every test suite (and power-user script)
/// depends on them; a settings file must never silently override an
/// explicit `CMUX_SCROLLBACK_LIMIT=0` in someone's service unit.
///
/// The file is re-read lazily with an mtime gate — an external edit
/// (hand, `cmux` CLI, dotfiles sync) is picked up on the next access
/// without a file watcher; the preferences window writes through this
/// type so its changes apply immediately.
enum LinuxSettings {

    enum TerminalBackend: String {
        case ghostty
        case vte
    }

    static var fileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let configHome = environment["XDG_CONFIG_HOME"], !configHome.isEmpty {
            base = URL(fileURLWithPath: configHome)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
        }
        return base.appendingPathComponent("cmux/cmux.json")
    }

    // MARK: file cache (mtime-gated)

    private static var cached: [String: Any] = [:]
    private static var cachedMtime: Date?

    private static func linuxSection() -> [String: Any] {
        let url = fileURL
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if mtime == cachedMtime { return cached }
        cachedMtime = mtime
        cached = [:]
        if let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let linux = root["linux"] as? [String: Any] {
            cached = linux
        }
        return cached
    }

    /// Merges values into the `"linux"` object, preserving everything else
    /// in the file — macOS keys, comments are NOT preserved (plain JSON
    /// round-trip), so the file is rewritten pretty-printed.
    static func update(_ values: [String: Any]) {
        let url = fileURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }
        var linux = (root["linux"] as? [String: Any]) ?? [:]
        for (key, value) in values {
            if value is NSNull {
                linux.removeValue(forKey: key)
            } else {
                linux[key] = value
            }
        }
        root["linux"] = linux
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
        cachedMtime = nil   // next read sees the new values
    }

    /// Drops the cache so the next access re-reads the file — the v1
    /// `reload_config` verb, though the mtime gate makes explicit reloads
    /// rarely necessary.
    static func invalidate() {
        cachedMtime = nil
        cached = [:]
    }

    // MARK: the settings

    /// Scrollback persistence budget in characters; 0 keeps everything.
    /// Env: CMUX_SCROLLBACK_LIMIT. Key: linux.scrollbackLimit.
    static var scrollbackLimit: Int {
        if let raw = ProcessInfo.processInfo.environment["CMUX_SCROLLBACK_LIMIT"],
           let value = Int(raw), value >= 0 {
            return value
        }
        if let value = linuxSection()["scrollbackLimit"] as? Int, value >= 0 {
            return value
        }
        return TerminalScrollback.maxCharacters
    }

    /// Search URL template for non-URL text in the browser address bar;
    /// `%s` is replaced with the query.
    /// Env: CMUX_SEARCH_URL. Key: linux.searchUrl.
    static var searchURL: String {
        if let raw = ProcessInfo.processInfo.environment["CMUX_SEARCH_URL"], !raw.isEmpty {
            return raw
        }
        if let value = linuxSection()["searchUrl"] as? String, !value.isEmpty {
            return value
        }
        return "https://www.google.com/search?q=%s"
    }

    /// Terminal backend for shim-linked builds. Startup-only: the Ghostty
    /// runtime initializes once, so a change applies to the next launch
    /// (the preferences window says so).
    /// Env: CMUX_TERM. Key: linux.terminalBackend.
    static var terminalBackend: TerminalBackend {
        if let raw = ProcessInfo.processInfo.environment["CMUX_TERM"],
           let backend = TerminalBackend(rawValue: raw.lowercased()) {
            return backend
        }
        if let raw = linuxSection()["terminalBackend"] as? String,
           let backend = TerminalBackend(rawValue: raw.lowercased()) {
            return backend
        }
        return .ghostty
    }
}
