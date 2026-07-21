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

    /// Line endings as a *terminal* means them, not as a file does.
    ///
    /// `read_text` returns clipboard-shaped text: rows joined with bare
    /// LF. Replayed through `inject_output` those bytes reach the terminal
    /// parser directly, where LF means "down one row" and nothing else —
    /// so every line starts where the previous one ended and the whole
    /// block staircases off to the right.
    ///
    /// macOS gets the CR for free and never has to think about it: it
    /// replays by having the shell print a temp file to the pty, and the
    /// tty line discipline's `ONLCR` flag rewrites LF to CRLF on the way
    /// out. Bypassing the pty is what makes the Linux path simpler; this
    /// is the bill for it.
    ///
    /// CRLF is collapsed first so the conversion is idempotent, and a
    /// lone CR is left alone — in captured output it is column-0 movement
    /// the writer meant, not a line break.
    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Reset styling before and after the replayed block: the captured
    /// text can end mid-colour, and the shell's first prompt should not
    /// inherit it.
    static func replayPayload(_ text: String) -> String {
        "\u{1B}[0m" + normalizeLineEndings(text) + "\u{1B}[0m\r\n"
    }
}

/// Text parked by a session restore until the surface's shell is running.
/// Same shape as `BrowserRestoreStore`, and for a sharper reason: a
/// Ghostty pane has no terminal to write to until it is first mapped, so
/// the replay cannot happen when the model is built.
///
/// Replay is therefore a *restartable poll*, which two bugs made necessary.
///
/// A pane in a workspace the human has not opened is the awkward case: it
/// exists in the model, but GTK never maps it, so its terminal never
/// starts. The first version polled for ~10s and then discarded the text —
/// so every workspace not opened within ten seconds of a restart came back
/// empty while its scrollback file still sat on disk holding the content.
/// Not discarding was necessary but not sufficient: a single retry when
/// the view syncs still lands *before* the newly-shown pane has been
/// mapped, so it fails too. Hence: keep the text, and let each sync start
/// a fresh poll — selecting a workspace is exactly the moment its panes
/// begin to map.
enum TerminalScrollbackStore {
    static var pending: [UUID: String] = [:]

    /// Surfaces with a poll in flight, so a burst of syncs cannot stack
    /// several chains onto one surface. All access is from the GTK main
    /// loop, so a plain Set is safe.
    private static var polling: Set<UUID> = []

    /// Begins (or resumes) polling for one surface. Safe to call
    /// repeatedly; a chain already running is left alone.
    static func startReplay(surfaceId: UUID) {
        guard pending[surfaceId] != nil, !polling.contains(surfaceId) else { return }
        polling.insert(surfaceId)
        poll(surfaceId: surfaceId, attempt: 0)
    }

    /// Restarts polling for every surface still holding text. Called from
    /// the view sync: selecting a workspace for the first time is what
    /// finally maps its panes.
    static func replayPendingIfReady() {
        for surfaceId in pending.keys { startReplay(surfaceId: surfaceId) }
    }

    /// Drops text for a surface that no longer exists, so a closed pane
    /// does not hold its content forever.
    static func forget(_ surfaceId: UUID) {
        pending.removeValue(forKey: surfaceId)
        polling.remove(surfaceId)
    }

    private static func poll(surfaceId: UUID, attempt: Int) {
        guard let text = pending[surfaceId] else {
            polling.remove(surfaceId)
            return
        }
        // Only inject into a *mapped* surface. `write_display` accepts
        // bytes as soon as the core surface exists, so an unmapped pane
        // would report success and queue the replay into a terminal that
        // has not started — the text would be consumed and lost.
        if SurfaceRegistry.shared.ghosttyIsMapped(for: surfaceId),
           SurfaceRegistry.shared.ghosttyWriteDisplay(
               for: surfaceId, text: TerminalScrollback.replayPayload(text)
           ) {
            pending.removeValue(forKey: surfaceId)
            polling.remove(surfaceId)
            return
        }
        // Give up on *this* chain, never on the text: the next sync starts
        // a new one. A pane that is never shown simply keeps its content.
        guard attempt < 20 else {
            polling.remove(surfaceId)
            return
        }
        scheduleOnMainLoop(afterMs: 500) {
            poll(surfaceId: surfaceId, attempt: attempt + 1)
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
    ///
    /// `force` skips the throttle, for the one save where being up to two
    /// seconds stale is not acceptable: the last one before the window
    /// closes. Without it the exit save is a no-op precisely when the user
    /// ran something and quit straight after.
    static func capture(surfaceId: UUID, force: Bool = false) {
        let now = Date()
        if !force, let previous = lastRead[surfaceId],
           now.timeIntervalSince(previous) < readInterval {
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
        // "Could not read" is not "there is nothing to keep". A pane whose
        // shell has not started — or whose widget is being torn down —
        // reports nil, and treating that as an empty pane would delete a
        // perfectly good file. Only a surface that genuinely reports its
        // text may retire what is on disk.
        guard let text else { return }
        let budget = limit
        let payload = budget == 0
            ? TerminalScrollback.truncate(text, limit: Int.max)
            : TerminalScrollback.truncate(text, limit: budget)
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
