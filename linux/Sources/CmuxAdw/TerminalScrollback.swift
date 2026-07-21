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
