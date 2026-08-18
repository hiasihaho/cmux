// Feed (workstream) verbs — the agent-hook event pipeline on Linux.
//
// The engine is the SHARED workstream model from CMUXAgentLaunch
// (WorkstreamStore / WorkstreamEvent / WorkstreamItem + JSONL persistence) —
// the exact code the macOS Feed uses — so ingest correlation, the ring
// buffer, and history live-load are macOS semantics for free. This file
// adds the Linux composition:
//
//   - a per-instance store whose JSONL lives beside the session file
//     (`<stem>-feed.jsonl`), following the scrollback lesson: two instances
//     must never share or prune each other's feed history;
//   - the socket verbs' wire encoding, mirrored shape-faithful from macOS
//     `FeedSocketEncoding` (Sources/Feed/FeedCoordinator.swift);
//   - blocking `feed.push` as a main-loop timeout + deferred `respond`
//     (macOS parks a socket-worker thread on a semaphore; on GTK that
//     would freeze the main loop, so the waiter is callback-shaped).
//
// Deliberate divergences, recorded in PARITY.md:
//   - `feed.jump` answers "is this workstream id known to the store";
//     macOS resolves hook-session records via FeedJumpResolver.
//   - no `tool_input_capabilities` enrichment (FeedPermissionActionPolicy
//     is macOS-app code; codex capability parsing has no consumer here yet).
//   - no agent-PID kqueue watcher; pending items expire via the push
//     wait timeout (and macOS-parity `expired` status on timeout).

import Foundation
import CMUXAgentLaunch

// MARK: - service

/// Main-loop-confined feed engine host. One per process, like the macOS
/// `FeedCoordinator.shared` it mirrors.
@MainActor
final class FeedService {
    static let shared = FeedService()

    let store: WorkstreamStore

    /// Blocking `feed.push` waiters keyed by `request_id`. A waiter's
    /// `respond` must fire exactly once: either from `deliverReply` or
    /// from its timeout.
    private struct Waiter {
        let itemId: UUID?
        let complete: ([String: Any]) -> Void
    }
    private var waiters: [String: Waiter] = [:]

    private init() {
        // Beside the session file, per instance — scoped to the session
        // FILE like scrollback (`<stem>-feed.jsonl`), so suites and dev
        // instances keep isolated feeds.
        let session = SessionStore.fileURL
        let stem = session.deletingPathExtension().lastPathComponent
        let logURL = session.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-feed.jsonl")
        let store = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: logURL)
        )
        self.store = store
        // Loads the persisted history page; live ingest works regardless.
        Task { @MainActor in await store.start() }
    }

    // MARK: push

    /// Ingests an event; calls `complete` exactly once with the macOS
    /// `FeedSocketEncoding.payload` shape (acknowledged/resolved/timed_out).
    func push(
        event: WorkstreamEvent,
        waitTimeoutSeconds: Double,
        complete: @escaping ([String: Any]) -> Void
    ) {
        // Non-blocking path: mirrors macOS `.acknowledged(itemId: nil)`
        // (the worker lane ingests asynchronously and cannot know the id;
        // we keep the wire shape identical rather than helpfully differing).
        guard let requestId = event.requestId, waitTimeoutSeconds > 0 else {
            store.ingest(event)
            complete(["status": "acknowledged"])
            return
        }

        store.ingest(event)
        let itemId = store.items.last?.id

        waiters[requestId] = Waiter(itemId: itemId, complete: complete)

        scheduleOnMainLoop(afterMs: UInt32(waitTimeoutSeconds * 1000)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let waiter = self.waiters.removeValue(forKey: requestId) else {
                    return // already resolved by a reply
                }
                if let itemId = waiter.itemId {
                    self.store.markExpired(itemId)
                }
                var payload: [String: Any] = ["status": "timed_out"]
                if let itemId = waiter.itemId { payload["item_id"] = itemId.uuidString }
                waiter.complete(payload)
            }
        }
    }

    // MARK: replies

    /// Resolves the store item for `requestId` and wakes its waiter (if one
    /// is still blocked). Mirrors macOS `FeedCoordinator.deliverReply`:
    /// the store is resolved even when no waiter exists — a reply may
    /// arrive after the push's wait timed out or when the push never waited.
    func deliverReply(requestId: String, decision: WorkstreamDecision) {
        let waiter = waiters.removeValue(forKey: requestId)

        let itemId = waiter?.itemId ?? Self.findItemId(for: requestId, in: store.items)
        if let itemId {
            store.markResolved(itemId, decision: decision)
        }

        if let waiter {
            var payload: [String: Any] = [
                "status": "resolved",
                "decision": FeedWireEncoding.decisionDict(decision),
            ]
            if let itemId { payload["item_id"] = itemId.uuidString }
            waiter.complete(payload)
        }
    }

    // MARK: queries

    func list(pendingOnly: Bool) -> [[String: Any]] {
        (pendingOnly ? store.pending : store.items).map(FeedWireEncoding.itemDict)
    }

    func isKnownWorkstream(_ workstreamId: String) -> Bool {
        store.items.contains { $0.workstreamId == workstreamId }
    }

    /// Reversed scan over payload request ids, byte-for-byte the macOS
    /// `FeedCoordinator.findItemId` logic.
    private static func findItemId(for requestId: String, in items: [WorkstreamItem]) -> UUID? {
        for item in items.reversed() {
            switch item.payload {
            case .permissionRequest(let rid, _, _, _) where rid == requestId:
                return item.id
            case .exitPlan(let rid, _, _) where rid == requestId:
                return item.id
            case .question(let rid, _) where rid == requestId:
                return item.id
            default:
                continue
            }
        }
        return nil
    }
}

// MARK: - wire encoding (mirror of macOS FeedSocketEncoding)

enum FeedWireEncoding {
    private static let primaryTextLimit = 8_000
    private static let secondaryTextLimit = 2_000

    static func decisionDict(_ decision: WorkstreamDecision) -> [String: Any] {
        switch decision {
        case .permission(let mode):
            return ["kind": "permission", "mode": mode.rawValue]
        case .exitPlan(let mode, let feedback):
            var dict: [String: Any] = ["kind": "exit_plan", "mode": mode.rawValue]
            if let feedback, !feedback.isEmpty {
                dict["feedback"] = feedback
            }
            return dict
        case .question(let selections):
            return ["kind": "question", "selections": selections]
        }
    }

    static func itemDict(_ item: WorkstreamItem) -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": item.id.uuidString,
            "workstream_id": item.workstreamId,
            "source": item.source.rawValue,
            "kind": item.kind.rawValue,
            "created_at": isoFormatter.string(from: item.createdAt),
            "updated_at": isoFormatter.string(from: item.updatedAt),
        ]
        if let cwd = item.cwd { dict["cwd"] = cwd }
        if let title = item.title { dict["title"] = title }
        switch item.status {
        case .pending:
            dict["status"] = "pending"
        case .resolved(let decision, let at):
            dict["status"] = "resolved"
            dict["decision"] = decisionDict(decision)
            dict["resolved_at"] = isoFormatter.string(from: at)
        case .expired(let at):
            dict["status"] = "expired"
            dict["resolved_at"] = isoFormatter.string(from: at)
        case .telemetry:
            dict["status"] = "telemetry"
        }
        switch item.payload {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            dict["request_id"] = requestId
            dict["tool_name"] = toolName
            // macOS adds `tool_input_capabilities` (codex capability parsing,
            // FeedPermissionActionPolicy) — app-side code, omitted here.
            assignLimitedText(toolInputJSON, key: "tool_input", to: &dict)
            if let pattern { dict["pattern"] = pattern }
        case .exitPlan(let requestId, let plan, let defaultMode):
            dict["request_id"] = requestId
            assignLimitedText(plan, key: "plan", to: &dict)
            dict["plan_summary"] = plan.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            dict["default_mode"] = defaultMode.rawValue
        case .question(let requestId, let questions):
            dict["request_id"] = requestId
            dict["questions"] = questions.map(questionDict)
            if let firstQuestion = questions.first {
                assignLimitedText(firstQuestion.prompt, key: "question_prompt", to: &dict)
                dict["question_multi_select"] = firstQuestion.multiSelect
                dict["question_options"] = firstQuestion.options.map { option in
                    var optionDict: [String: Any] = [
                        "id": option.id,
                        "label": limitedText(option.label, limit: secondaryTextLimit).text,
                    ]
                    if let description = option.description {
                        assignLimitedText(description, key: "description", to: &optionDict, limit: secondaryTextLimit)
                    }
                    return optionDict
                }
            }
        case .toolUse(let toolName, let toolInputJSON):
            dict["tool_name"] = toolName
            assignLimitedText(toolInputJSON, key: "tool_input", to: &dict)
        case .toolResult(let toolName, let resultJSON, let isError):
            dict["tool_name"] = toolName
            assignLimitedText(resultJSON, key: "tool_result", to: &dict)
            dict["tool_result_is_error"] = isError
        case .userPrompt(let text), .assistantMessage(let text):
            assignLimitedText(text, key: "text", to: &dict)
        case .sessionStart, .sessionEnd:
            break
        case .stop(let reason):
            if let reason { assignLimitedText(reason, key: "reason", to: &dict, limit: secondaryTextLimit) }
        case .todos(let todos):
            dict["todos"] = todos.map { todo in
                [
                    "id": todo.id,
                    "content": limitedText(todo.content, limit: secondaryTextLimit).text,
                    "state": todo.state.rawValue,
                ]
            }
        }
        return dict
    }

    private static func questionDict(_ question: WorkstreamQuestionPrompt) -> [String: Any] {
        var dict: [String: Any] = [
            "id": question.id,
            "multi_select": question.multiSelect,
        ]
        if let header = question.header {
            assignLimitedText(header, key: "header", to: &dict, limit: secondaryTextLimit)
        }
        assignLimitedText(question.prompt, key: "prompt", to: &dict, limit: primaryTextLimit)
        dict["options"] = question.options.map { option in
            var optionDict: [String: Any] = [
                "id": option.id,
                "label": limitedText(option.label, limit: secondaryTextLimit).text,
            ]
            if let description = option.description {
                assignLimitedText(description, key: "description", to: &optionDict, limit: secondaryTextLimit)
            }
            return optionDict
        }
        return dict
    }

    private static func limitedText(_ value: String, limit: Int) -> (text: String, truncated: Bool) {
        guard value.count > limit else { return (value, false) }
        let end = value.index(value.startIndex, offsetBy: max(limit - 3, 0))
        return (String(value[..<end]) + "...", true)
    }

    private static func assignLimitedText(
        _ value: String,
        key: String,
        to dict: inout [String: Any],
        limit: Int = 8_000
    ) {
        let limited = limitedText(value, limit: limit)
        dict[key] = limited.text
        if limited.truncated {
            dict["\(key)_truncated"] = true
        }
    }
}

// MARK: - socket verbs

extension ControlCommandHandler {
    /// `feed.push` — async-completing: the blocking form replies from a
    /// waiter resolution or its main-loop timeout, never blocking the loop.
    func v2FeedPush(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        // Validation mirrors macOS `v2FeedPush` including message text.
        let waitTimeout: Double
        if let rawTimeout = params["wait_timeout_seconds"] {
            let seconds: Double?
            if let number = rawTimeout as? NSNumber {
                seconds = number.doubleValue
            } else if let value = rawTimeout as? Double {
                seconds = value
            } else if let value = rawTimeout as? Int {
                seconds = Double(value)
            } else {
                seconds = nil
            }
            guard let seconds else {
                respond(v2Error(id: id, code: "invalid_params", message: "feed.push wait_timeout_seconds must be numeric"))
                return
            }
            guard seconds.isFinite, seconds >= 0, seconds <= 120 else {
                respond(v2Error(id: id, code: "invalid_params", message: "feed.push wait_timeout_seconds must be between 0 and 120"))
                return
            }
            waitTimeout = seconds
        } else {
            waitTimeout = 0
        }

        let eventDict: [String: Any]
        if let nested = params["event"] as? [String: Any] {
            eventDict = nested
        } else if params["session_id"] != nil,
                  params["hook_event_name"] != nil,
                  params["_source"] != nil {
            eventDict = params
        } else {
            respond(v2Error(id: id, code: "invalid_params", message: "feed.push requires an `event` object"))
            return
        }

        let event: WorkstreamEvent
        do {
            let data = try JSONSerialization.data(withJSONObject: eventDict)
            event = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        } catch {
            respond(v2Error(id: id, code: "invalid_params", message: "feed.push event failed to decode: \(error)"))
            return
        }

        MainActor.assumeIsolated {
            FeedService.shared.push(event: event, waitTimeoutSeconds: waitTimeout) { payload in
                respond(v2Ok(id: id, result: payload))
            }
        }
    }

    func v2FeedList(id: Any?, params: [String: Any]) -> String {
        // Only a real JSON boolean counts (macOS legacy `as? Bool` behavior).
        let pendingOnly = (params["pending_only"] as? Bool) ?? false
        let items = MainActor.assumeIsolated {
            FeedService.shared.list(pendingOnly: pendingOnly)
        }
        return v2Ok(id: id, result: ["items": items])
    }

    func v2FeedJump(id: Any?, params: [String: Any]) -> String {
        guard let workstreamID = params["workstream_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "feed.jump requires workstream_id")
        }
        let matched = MainActor.assumeIsolated {
            FeedService.shared.isKnownWorkstream(workstreamID)
        }
        return v2Ok(id: id, result: ["workstream_id": workstreamID, "matched": matched])
    }

    func v2FeedPermissionReply(id: Any?, params: [String: Any]) -> String {
        guard let requestId = params["request_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "feed.permission.reply requires request_id")
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamPermissionMode(rawValue: modeRaw)
        else {
            return v2Error(id: id, code: "invalid_params", message: "feed.permission.reply requires mode ∈ once|always|all|bypass|deny")
        }
        MainActor.assumeIsolated {
            FeedService.shared.deliverReply(requestId: requestId, decision: .permission(mode))
        }
        return v2Ok(id: id, result: ["delivered": true])
    }

    func v2FeedQuestionReply(id: Any?, params: [String: Any]) -> String {
        guard let requestId = params["request_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "feed.question.reply requires request_id")
        }
        guard let selections = params["selections"] as? [String] else {
            return v2Error(id: id, code: "invalid_params", message: "feed.question.reply requires selections: [string]")
        }
        MainActor.assumeIsolated {
            FeedService.shared.deliverReply(requestId: requestId, decision: .question(selections: selections))
        }
        return v2Ok(id: id, result: ["delivered": true])
    }

    func v2FeedExitPlanReply(id: Any?, params: [String: Any]) -> String {
        guard let requestId = params["request_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "feed.exit_plan.reply requires request_id")
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamExitPlanMode(rawValue: modeRaw)
        else {
            return v2Error(id: id, code: "invalid_params", message: "feed.exit_plan.reply requires mode ∈ ultraplan|bypassPermissions|autoAccept|manual|deny")
        }
        let feedback = params["feedback"] as? String
        MainActor.assumeIsolated {
            FeedService.shared.deliverReply(requestId: requestId, decision: .exitPlan(mode, feedback: feedback))
        }
        return v2Ok(id: id, result: ["delivered": true])
    }
}
