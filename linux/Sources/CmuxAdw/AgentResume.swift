// Agent session auto-resume — the Linux port of macOS
// `terminal.autoResumeAgentSessions` (kb/session-restore-and-resume.md):
// on session restore, a terminal surface whose agent session was recorded
// by the shared-CLI hooks gets its agent's NATIVE resume command typed
// into the freshly spawned shell, so a promote brings agents back
// mid-conversation instead of leaving bare prompts.
//
// The RECORDING half is the shared CLI (hook stores at
// `~/.cmuxterm/<agent>-hook-sessions.json`, version 1:
// `activeSessionsBySurface[<surface-uuid>] → sessionId` plus per-session
// records). Surface UUIDs persist across restore (SessionStore v3), so
// the lookup is exact per surface.
//
// Deviations from macOS, deliberate (PARITY.md):
//  - fixed per-agent command table only — the record's sanitized launch
//    command is never executed, and session ids are charset-validated
//    before being typed into a shell (no approval store / launcher
//    scripts / custom bindings);
//  - no `agentWasRunning` shell-activity gate at save time; a record that
//    is restorable and not ended resumes (macOS treats unknown as true).
//
// macOS parity kept: when a surface resumes, its stale scrollback is NOT
// replayed — the resumed agent redraws, and replaying "avoids replaying
// stale prompts or secrets" is the documented restore contract.

import Foundation

enum AgentResume {

    /// Hook-store directory; `CMUX_HOOK_SESSIONS_DIR` lets suites point an
    /// instance at a fixture store instead of the user's real one.
    static var storeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_HOOK_SESSIONS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm")
    }

    /// The native resume command for one agent (hook-store file prefix),
    /// from the macOS 17-agent resume matrix. Unknown agents return nil —
    /// notably kimi, whose hook store exists (#7201) but whose resume
    /// command the docs do not state; extend when verified.
    static func command(agent: String, sessionId: String) -> String? {
        switch agent {
        case "claude": return "claude --resume \(sessionId)"
        case "codex": return "codex resume \(sessionId)"
        case "opencode": return "opencode --session \(sessionId)"
        case "gemini": return "gemini --resume \(sessionId)"
        case "cursor": return "cursor-agent --resume \(sessionId)"
        case "amp": return "amp threads continue \(sessionId)"
        case "copilot": return "copilot --resume \(sessionId)"
        case "hermes-agent": return "hermes --resume \(sessionId)"
        case "grok": return "grok -r \(sessionId)"
        case "pi": return "pi --session \(sessionId)"
        case "codebuddy": return "codebuddy --resume \(sessionId)"
        case "factory": return "droid --resume \(sessionId)"
        case "qoder": return "qodercli --resume \(sessionId)"
        default: return nil
        }
    }

    /// Resolves the resume command for a restored surface: newest
    /// restorable active session across all agents' hook stores.
    static func resumeCommand(surfaceId: UUID) -> String? {
        guard LinuxSettings.autoResumeAgentSessions else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil
        ) else { return nil }

        var best: (updated: Double, command: String)?
        for file in files where file.lastPathComponent.hasSuffix("-hook-sessions.json") {
            let agent = String(file.lastPathComponent.dropLast("-hook-sessions.json".count))
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let active = root["activeSessionsBySurface"] as? [String: Any],
                  let entry = active[surfaceId.uuidString] as? [String: Any],
                  let sessionId = entry["sessionId"] as? String
            else { continue }
            // The id is typed into a live shell: strict charset, no
            // metacharacters, regardless of what the store claims.
            guard sessionId.range(
                of: "^[A-Za-z0-9._-]+$", options: .regularExpression
            ) != nil else { continue }

            let record = (root["sessions"] as? [String: Any])?[sessionId] as? [String: Any]
            if let restorable = record?["isRestorable"] as? Bool, !restorable { continue }
            if let lifecycle = record?["agentLifecycle"] as? String, lifecycle == "ended" { continue }
            guard let command = command(agent: agent, sessionId: sessionId) else { continue }

            let updated = (entry["updatedAt"] as? Double)
                ?? (record?["updatedAt"] as? Double) ?? 0
            if best == nil || updated > best!.updated {
                best = (updated, command)
            }
        }
        return best?.command
    }
}

/// Pending resume commands for restored surfaces, delivered once the
/// surface can take pty input — the same restartable readiness poll the
/// scrollback replay uses (TerminalScrollbackStore), because the same
/// mapping realities apply. Main-loop confined.
enum AgentResumeStore {
    static var pending: [UUID: String] = [:]
    private static var polling: Set<UUID> = []

    static func start(surfaceId: UUID) {
        guard pending[surfaceId] != nil, !polling.contains(surfaceId) else { return }
        polling.insert(surfaceId)
        poll(surfaceId: surfaceId, attempt: 0)
    }

    static func startPendingIfReady() {
        for surfaceId in pending.keys { start(surfaceId: surfaceId) }
    }

    static func forget(_ surfaceId: UUID) {
        pending.removeValue(forKey: surfaceId)
        polling.remove(surfaceId)
    }

    private static func poll(surfaceId: UUID, attempt: Int) {
        guard let command = pending[surfaceId] else {
            polling.remove(surfaceId)
            return
        }
        // `\r`, not `\n`: pty line discipline — the same normalization the
        // v1 send verb applies to typed input.
        if SurfaceRegistry.shared.readyForReplay(for: surfaceId),
           surfacePTYWrite(command + "\r", to: surfaceId) == nil {
            pending.removeValue(forKey: surfaceId)
            polling.remove(surfaceId)
            return
        }
        guard attempt < 20 else {
            polling.remove(surfaceId)
            return
        }
        scheduleOnMainLoop(afterMs: 500) {
            poll(surfaceId: surfaceId, attempt: attempt + 1)
        }
    }
}
