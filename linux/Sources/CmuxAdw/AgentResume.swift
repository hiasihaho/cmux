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
        // The FLAG, never the subcommand: `hermes resume` (no dashes) lifts
        // the emergency stop set by `hermes pause` — a dangerous confusable
        // (verified against hermes --help, 2026-08-18).
        case "hermes-agent":
            // …and the PROFILE, when the session belongs to one: see
            // hermesProfile(forSessionId:).
            if let profile = hermesProfile(forSessionId: sessionId) {
                return "hermes -p \(profile) --resume \(sessionId)"
            }
            return "hermes --resume \(sessionId)"
        case "grok": return "grok -r \(sessionId)"
        case "pi": return "pi --session \(sessionId)"
        case "codebuddy": return "codebuddy --resume \(sessionId)"
        case "factory": return "droid --resume \(sessionId)"
        case "qoder": return "qodercli --resume \(sessionId)"
        // Verified live by the kimi session (2026-08-18): Kimi Code resumes
        // with --session (alias -r/--resume); accepts both the current
        // session_<uuid> and legacy ses_<uuid> id shapes.
        case "kimi": return "kimi --session \(sessionId)"
        default: return nil
        }
    }

    /// Which hermes PROFILE owns this session id, if not the default.
    ///
    /// Hermes keeps one session store per profile — `~/.hermes/sessions`
    /// for the default, `~/.hermes/profiles/<name>/sessions` for the rest
    /// — so `hermes --resume <id>` run under the wrong profile does not
    /// find the session at all; it reports "session not found", which
    /// reads like data loss and is not. macOS never hits this because its
    /// CLI rebuilds the resume command from the running process's argv,
    /// where `-p <profile>` survives. This port uses a fixed command
    /// table (see the header), so it has to recover the profile itself.
    ///
    /// Matching is on CONTENT, not filename: the id lives inside the file
    /// as `"session_id"`, while the name carries a different timestamp
    /// (`hermes_conversation_20260531_203236.json` holds session
    /// `20260531_201509_0ccf4f`). Head bytes only, newest first, capped —
    /// this runs on the restore path, once per surface.
    ///
    /// TWO stores per profile, both scanned (found by testing a real
    /// profile session, 2026-09-03): `sessions/` holds saved
    /// conversations, and `terminal-sessions/<tty>` is the per-tty
    /// "what ran here last" pointer — extensionless, tiny, and the one
    /// that actually exists for a live session. Scanning only `sessions/`
    /// found nothing for a session that had just run for ten minutes.
    ///
    /// Returns nil for the default profile, an unknown id, or anything
    /// whose name is not shell-safe: the caller types the result into a
    /// live shell, so an unrecognised profile degrades to the plain
    /// command rather than widening what gets typed.
    static func hermesProfile(forSessionId sessionId: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let hermesHome: URL
        if let explicit = env["HERMES_HOME"], !explicit.isEmpty {
            hermesHome = URL(fileURLWithPath: explicit)
        } else {
            // HOME from the environment, not homeDirectoryForCurrentUser:
            // the suites run an instance under a stub HOME, and a lookup
            // that ignored it would read the developer's real profiles.
            let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            hermesHome = URL(fileURLWithPath: home).appendingPathComponent(".hermes")
        }
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(
            at: hermesHome.appendingPathComponent("profiles"),
            includingPropertiesForKeys: nil
        ) else { return nil }

        let needles = ["\"session_id\": \"\(sessionId)\"", "\"session_id\":\"\(sessionId)\""]
        for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = profile.lastPathComponent
            guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                continue
            }
            var files: [(URL, Date)] = []
            for store in ["terminal-sessions", "sessions"] {
                guard let walker = fm.enumerator(
                    at: profile.appendingPathComponent(store),
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let url as URL in walker {
                    // No extension filter: the tty pointers carry none.
                    let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]
                    )
                    guard values?.isRegularFile == true else { continue }
                    files.append((url, values?.contentModificationDate ?? .distantPast))
                    if files.count >= 600 { break }
                }
            }
            for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(300) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                guard let head = try? handle.read(upToCount: 4096),
                      let text = String(data: head, encoding: .utf8) else { continue }
                if needles.contains(where: { text.contains($0) }) { return name }
            }
        }
        return nil
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
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let sessions = root["sessions"] as? [String: Any] ?? [:]
            // Primary: the per-surface index. Fallback: scan session
            // records by their surfaceId field — some writers (kimi's
            // SessionStart, observed 2026-08-18) create the record before
            // filling the index; newest updatedAt wins.
            var sessionId: String?
            if let active = root["activeSessionsBySurface"] as? [String: Any],
               let entry = active[surfaceId.uuidString] as? [String: Any],
               let indexed = entry["sessionId"] as? String {
                sessionId = indexed
            } else {
                var newest = -Double.infinity
                for (sid, raw) in sessions {
                    guard let rec = raw as? [String: Any],
                          rec["surfaceId"] as? String == surfaceId.uuidString else { continue }
                    let updated = (rec["updatedAt"] as? Double) ?? 0
                    if updated > newest { newest = updated; sessionId = sid }
                }
            }
            guard let sessionId else { continue }
            // The id is typed into a live shell: strict charset, no
            // metacharacters, regardless of what the store claims.
            guard sessionId.range(
                of: "^[A-Za-z0-9._-]+$", options: .regularExpression
            ) != nil else { continue }
            // Real claude session ids are UUIDs. Claude-compatible wrappers
            // (found 2026-08-18: ses_… ids in the claude store from
            // ~/lfm-research, absent from every other agent's index) write
            // their own id shapes through the same hooks — resuming those
            // with `claude --resume` would misfire, so they are skipped.
            if agent == "claude", UUID(uuidString: sessionId) == nil { continue }

            let record = sessions[sessionId] as? [String: Any]
            if let restorable = record?["isRestorable"] as? Bool, !restorable { continue }
            if let lifecycle = record?["agentLifecycle"] as? String, lifecycle == "ended" { continue }
            guard let command = command(agent: agent, sessionId: sessionId) else { continue }

            let updated = (record?["updatedAt"] as? Double) ?? 0
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
        if SurfaceRegistry.shared.readyForPTYWrite(for: surfaceId),
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
