import Foundation

/// Capture and replay of a terminal pane's on-screen text across a
/// session restart.
///
/// macOS persists this too (`SessionTerminalPanelSnapshot.scrollback`),
/// and two of its decisions are worth copying rather than rediscovering:
///
/// - **Truncate to a budget.** Scrollback is unbounded and the session
///   file is rewritten on every structural change; persisting megabytes
///   of it would turn saves into IO churn.
/// - **Truncate ANSI-safely.** Cutting mid escape sequence replays
///   malformed control bytes into a fresh terminal, which can leave it in
///   a wrong colour or, worse, a wrong mode. The cut therefore advances
///   to the first byte after any sequence it lands inside.
///
/// The replay path differs from macOS by necessity and comes out cleaner:
/// macOS writes the text to a temp file, passes its path in the child's
/// environment, and relies on shell integration to print it at startup.
/// Ghostty gives us `inject_output` (added to the fork for this), which
/// feeds the bytes to the terminal parser directly — no temp file, no
/// environment variable, no dependence on the user's shell, and no chance
/// of the text reaching the shell as input.
enum TerminalScrollback {

    /// Matches macOS's per-terminal budget.
    static let maxCharacters = 64 * 1024

    /// Trailing `limit` characters, cut on a safe boundary.
    static func truncate(_ text: String, limit: Int = maxCharacters) -> String? {
        let trimmed = text
        guard trimmed.contains(where: { !$0.isWhitespace }) else { return nil }
        guard trimmed.count > limit else { return ansiSafeStart(trimmed, from: trimmed.startIndex) }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -limit)
        return ansiSafeStart(trimmed, from: start)
    }

    /// Advances past a partial escape sequence at the cut point. An ESC
    /// with no terminator before `start` means the cut landed inside one;
    /// resuming there would feed the terminal a truncated CSI.
    private static func ansiSafeStart(_ text: String, from start: String.Index) -> String? {
        var index = start
        // Skip any bytes belonging to a sequence that began before the cut.
        while index < text.endIndex {
            let ch = text[index]
            // A final byte of a CSI/OSC sequence, or a printable start.
            if ch == "\u{1B}" { break }
            if ch.isLetter || ch.isNumber || ch.isWhitespace || ch.isPunctuation || ch.isSymbol {
                break
            }
            index = text.index(after: index)
        }
        let result = String(text[index...])
        return result.isEmpty ? nil : result
    }

    /// Reset styling before and after the replayed block: the captured
    /// text can end mid-colour, and the shell's first prompt should not
    /// inherit it.
    static func replayPayload(_ text: String) -> String {
        "\u{1B}[0m" + text + "\u{1B}[0m\r\n"
    }
}

/// Text parked by a session restore until the surface's shell is running.
/// Same shape as `BrowserRestoreStore`, and for a sharper reason: a
/// Ghostty pane has no terminal to write to until it is first mapped, so
/// the replay cannot happen when the model is built.
enum TerminalScrollbackStore {
    static var pending: [UUID: String] = [:]

    /// Replays and consumes a pane's parked text. Called once the surface
    /// reports a running shell; a pane that is never shown keeps its text
    /// parked rather than losing it.
    static func replayIfPending(surfaceId: UUID, attempt: Int = 0) {
        guard let text = pending[surfaceId] else { return }
        if SurfaceRegistry.shared.ghosttyWriteDisplay(
            for: surfaceId, text: TerminalScrollback.replayPayload(text)
        ) {
            pending.removeValue(forKey: surfaceId)
            return
        }
        // The shell spawns on first map, which for a background workspace
        // may be much later — or never. Retry for ~10s, then drop it
        // rather than holding the text (and the expectation) forever.
        guard attempt < 20 else {
            pending.removeValue(forKey: surfaceId)
            return
        }
        scheduleOnMainLoop(afterMs: 500) {
            replayIfPending(surfaceId: surfaceId, attempt: attempt + 1)
        }
    }
}

/// Scrollback on disk, one file per surface.
///
/// It used to live inline in the session JSON, which is rewritten on every
/// model change — so every line of terminal output made the whole document
/// dirty and triggered a full rewrite. With only the visible screen stored
/// that was already ~327 KB per save; uncapped it would be megabytes, many
/// times a minute. That write amplification, not disk space, is what forced
/// the original character budget.
///
/// Out of band, a pane that is not scrolling costs nothing: files are
/// written only when that surface's text actually changed. Which is what
/// makes a large — or unlimited — limit affordable.
enum ScrollbackStore {

    /// Alongside the session file, so an instance pointed at its own
    /// `CMUX_SESSION_PATH` (every test suite) keeps its own scrollback
    /// rather than writing into the user's real state directory.
    static var directory: URL {
        SessionStore.fileURL.deletingLastPathComponent().appendingPathComponent("scrollback")
    }

    /// Character budget. `CMUX_SCROLLBACK_LIMIT=0` keeps everything —
    /// affordable now that saves are incremental.
    static var limit: Int {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_SCROLLBACK_LIMIT"],
              let value = Int(raw), value >= 0 else { return TerminalScrollback.maxCharacters }
        return value
    }

    /// Hashes of what was last written, so an unchanged pane is not
    /// rewritten. In memory only: a cold start rewrites once, which is
    /// cheap and self-correcting.
    private static var lastWritten: [UUID: Int] = [:]

    private static func url(for surfaceId: UUID) -> URL {
        directory.appendingPathComponent("\(surfaceId.uuidString).txt")
    }

    /// Last time each surface's text was read. Reading full history is a
    /// copy of the whole buffer, and `saveIfChanged` runs on *every* model
    /// change — so the read is throttled even though the write is already
    /// change-gated. Without this, raising the limit would move the cost
    /// from writing to reading rather than removing it.
    private static var lastRead: [UUID: Date] = [:]
    private static let readInterval: TimeInterval = 2

    /// Captures a surface's text and stores it, subject to the throttle.
    /// Reads full history when a budget allows it, so raising the limit
    /// actually keeps more — capturing only the visible screen would make
    /// the setting meaningless.
    static func capture(surfaceId: UUID) {
        let now = Date()
        if let previous = lastRead[surfaceId], now.timeIntervalSince(previous) < readInterval {
            return
        }
        lastRead[surfaceId] = now
        // Always read history and let the limit bound it. Gating history
        // on the budget produced a cliff — 64k kept only the visible
        // screen while 65537 kept thousands of lines — and "limit" should
        // mean "how much do I keep", not "which capture mode am I in".
        // The 2s throttle above is what keeps the read affordable.
        write(
            SurfaceRegistry.shared.ghosttyReadText(for: surfaceId, includeScrollback: true),
            for: surfaceId
        )
    }

    static func write(_ text: String?, for surfaceId: UUID) {
        let budget = limit
        let payload = text.flatMap {
            budget == 0 ? TerminalScrollback.truncate($0, limit: Int.max)
                        : TerminalScrollback.truncate($0, limit: budget)
        }
        guard let payload, !payload.isEmpty else {
            // Nothing to keep: drop any stale file so a cleared pane does
            // not come back showing yesterday's output.
            if lastWritten.removeValue(forKey: surfaceId) != nil {
                try? FileManager.default.removeItem(at: url(for: surfaceId))
            }
            return
        }
        let hash = payload.hashValue
        guard lastWritten[surfaceId] != hash else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try payload.write(to: url(for: surfaceId), atomically: true, encoding: .utf8)
            lastWritten[surfaceId] = hash
        } catch {
            // A failed scrollback write must never cost the session itself.
            FileHandle.standardError.write(Data("cmux: scrollback write failed: \(error)\n".utf8))
        }
    }

    static func read(for surfaceId: UUID) -> String? {
        try? String(contentsOf: url(for: surfaceId), encoding: .utf8)
    }

    /// Removes files for surfaces the session no longer contains.
    static func prune(keeping live: Set<UUID>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.pathExtension == "txt" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            try? FileManager.default.removeItem(at: entry)
            lastWritten.removeValue(forKey: id)
        }
    }
}
