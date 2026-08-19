import Foundation

/// The agent that produced a `WorkstreamItem`. The raw value matches the
/// `_source` field on the wire frame that cmux hooks and the OpenCode plugin
/// emit, and matches Vibe Island's source tag 1:1 so existing hook payloads
/// can flow through unchanged.
public enum WorkstreamSource: String, Codable, Sendable, CaseIterable, Equatable {
    case claude
    case codex
    case pi
    case amp
    case cursor
    case opencode
    case gemini
    case hermesAgent = "hermes-agent"
    case copilot
    case codebuddy
    case factory
    case qoder
    // cmux ships kimi hook support (KimiCodeHookConfig in this very
    // package); without this case `_source: "kimi"` fell back to claude
    // and landed mislabeled — invisible to source-filtered feed queries
    // (kimi-session field report, 2026-08-18).
    case kimi
    // The app/desk itself as an event author (announcements, socket-input
    // tags). 2026-08-19, olmo-loop desk asks.
    case cmux
    // Landing spot for unregistered `_source` values. Falling back to
    // claude let unknown sources wear a registered identity — an
    // authority inversion (olmo-loop desk ask 2, 2026-08-19). The raw
    // wire string is not preserved; registering a source is one case.
    case unknown

    /// Parses a wire-frame `_source` string. Unknown sources fall back to
    /// `nil`; callers should persist the raw string separately when they want
    /// to surface out-of-band agents without widening this enum.
    public init?(wireName: String) {
        self.init(rawValue: wireName)
    }
}
