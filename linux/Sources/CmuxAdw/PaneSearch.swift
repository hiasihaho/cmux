import CVte
import CWebKit
import Foundation

/// `cmux search` — text search across every pane at once.
///
/// Deliberately NOT built on `WebKitFindController`. "Find in this pane"
/// (live highlight, next/previous, match count) and "which of my panes
/// mentions this?" are different features that happen to share a name;
/// a shared engine would leak immediately, because one is a line buffer
/// with scrollback and the other is a DOM with frames. They share a result
/// shape here, nothing more.
///
/// This half needs no new WebKit API — a terminal surface already exposes
/// its text and a browser pane's is one eval away — and it is the half an
/// agent cannot do by hand across eight panes.
///
/// **Results are a snapshot.** A browser pane repaints and a terminal
/// scrolls underneath you; matches describe the moment they were taken.
/// Terminal coverage is bounded by what the backend returns (Ghostty can
/// include scrollback, VTE currently gives the screenful ending at the
/// cursor).
extension ControlCommandHandler {

    /// Raw text of a terminal surface, shared by `surface.read_text` and
    /// pane search so the two can never disagree about what a pane says.
    func terminalText(for surfaceId: UUID, scrollback: Bool) -> String? {
        #if canImport(CGhosttyEmbed)
        if SurfaceRegistry.shared.ghostty(for: surfaceId) != nil {
            return SurfaceRegistry.shared.ghosttyReadText(
                for: surfaceId, includeScrollback: scrollback
            )
        }
        #endif
        guard let terminal = SurfaceRegistry.shared.terminal(for: surfaceId) else { return nil }
        // Screenful ending at the cursor, not the viewport: an unmapped
        // terminal never scrolls its viewport and would otherwise return a
        // stale first screenful forever.
        var cursorCol: glong = 0
        var cursorRow: glong = 0
        vte_terminal_get_cursor_position(terminal, &cursorCol, &cursorRow)
        let visibleRows = glong(vte_terminal_get_row_count(terminal))
        let startRow = max(0, cursorRow - visibleRows + 1)
        guard let raw = vte_terminal_get_text_range_format(
            terminal, VTE_FORMAT_TEXT, startRow, 0, cursorRow, -1, nil
        ) else { return nil }
        let text = String(cString: raw)
        g_free(raw)
        return text
    }

    func v2SearchPanes(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let query = (params["query"] as? String), !query.isEmpty else {
            return respond(psError(id: id, code: "invalid_params", message: "Missing query"))
        }
        let ignoreCase = (params["ignore_case"] as? Bool)
            ?? (params["ignore_case"] as? NSNumber)?.boolValue ?? true
        let useRegex = (params["regex"] as? Bool)
            ?? (params["regex"] as? NSNumber)?.boolValue ?? false
        let scrollback = (params["scrollback"] as? Bool)
            ?? (params["scrollback"] as? NSNumber)?.boolValue ?? false
        let maxPerSurface = (params["max_per_surface"] as? Int) ?? 20
        let kindFilter = (params["kind"] as? String)?.lowercased()

        var regex: NSRegularExpression?
        if useRegex {
            do {
                regex = try NSRegularExpression(
                    pattern: query, options: ignoreCase ? [.caseInsensitive] : []
                )
            } catch {
                return respond(psError(
                    id: id, code: "invalid_params",
                    message: "Invalid regex: \(error.localizedDescription)"
                ))
            }
        }

        /// Matching lines, capped, with 1-based line numbers.
        func matches(in text: String) -> [[String: Any]] {
            var hits: [[String: Any]] = []
            for (index, rawLine) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                let line = String(rawLine)
                let matched: Bool
                if let regex {
                    matched = regex.firstMatch(
                        in: line, range: NSRange(line.startIndex..., in: line)
                    ) != nil
                } else {
                    matched = line.range(
                        of: query, options: ignoreCase ? [.caseInsensitive] : []
                    ) != nil
                }
                guard matched else { continue }
                hits.append([
                    "line": index + 1,
                    "text": line.trimmingCharacters(in: .whitespaces)
                ])
                if hits.count >= maxPerSurface { break }
            }
            return hits
        }

        // Scope: one workspace if asked, otherwise every workspace.
        let scopedTabs: [TerminalTab] = {
            guard let raw = params["workspace_id"] as? String, !raw.isEmpty,
                  let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw) else {
                return tabs.wrappedValue
            }
            return tabs.wrappedValue.filter { $0.id == uuid }
        }()

        let registry = RefRegistry.shared
        let collector = PaneSearchCollector()

        // Terminal panes answer synchronously; browser panes need a JS round
        // trip each, so they are dispatched and counted, and the response
        // waits for the last one.
        var pendingBrowsers: [(tab: TerminalTab, leaf: PaneLeaf, webView: UnsafeMutablePointer<WebKitWebView>)] = []

        for tab in scopedTabs {
            for leaf in tab.surfaces {
                let kind = leaf.kind.typeName
                if let kindFilter, kindFilter != kind { continue }
                collector.searched += 1

                switch leaf.kind {
                case .terminal:
                    guard let text = terminalText(for: leaf.surfaceId, scrollback: scrollback),
                          !text.isEmpty else { continue }
                    let hits = matches(in: text)
                    guard !hits.isEmpty else { continue }
                    // NOT tab.title: the workspace title follows whichever
                    // surface is focused, so a terminal hit would be captioned
                    // with the browser pane's page title. The shell's live cwd
                    // actually identifies the pane.
                    let cwd = SurfaceRegistry.shared.currentDirectory(for: leaf.surfaceId)
                        ?? leaf.workingDirectory
                    collector.results.append(
                        Self.resultEntry(tab: tab, leaf: leaf, kind: kind, hits: hits,
                                         title: cwd, url: "", registry: registry)
                    )
                case .browser:
                    guard let raw = SurfaceRegistry.shared.browser(for: leaf.surfaceId) else { continue }
                    pendingBrowsers.append((tab, leaf, UnsafeMutablePointer<WebKitWebView>(raw)))
                case .inspector:
                    // DevTools panes host WebKit's own UI; searching it would
                    // report matches the user never wrote.
                    collector.searched -= 1
                    continue
                }
            }
        }

        collector.outstanding = pendingBrowsers.count
        let finish = {
            let sorted = collector.results.sorted {
                (($0["match_count"] as? Int) ?? 0) > (($1["match_count"] as? Int) ?? 0)
            }
            respond(self.psOk(id: id, result: [
                "query": query,
                "surfaces_searched": collector.searched,
                "total_matches": sorted.reduce(0) { $0 + (($1["match_count"] as? Int) ?? 0) },
                "results": sorted
            ]))
        }

        guard !pendingBrowsers.isEmpty else { return finish() }

        for entry in pendingBrowsers {
            // innerText, not textContent: it reflects what is actually
            // rendered, so hidden markup and <script> bodies do not produce
            // matches a human would never see on screen.
            BrowserJS.run(
                entry.webView,
                script: "(() => document.body ? document.body.innerText : '')()"
            ) { outcome in
                if case .success(let value) = outcome, let text = value as? String, !text.isEmpty {
                    let hits = matches(in: text)
                    if !hits.isEmpty {
                        let url = webkit_web_view_get_uri(entry.webView)
                            .map { String(cString: $0) } ?? ""
                        let title = webkit_web_view_get_title(entry.webView)
                            .map { String(cString: $0) } ?? ""
                        collector.results.append(
                            Self.resultEntry(tab: entry.tab, leaf: entry.leaf, kind: "browser",
                                             hits: hits, title: title, url: url, registry: registry)
                        )
                    }
                }
                collector.outstanding -= 1
                if collector.outstanding <= 0 { finish() }
            }
        }
    }

    private static func resultEntry(
        tab: TerminalTab, leaf: PaneLeaf, kind: String,
        hits: [[String: Any]], title: String, url: String, registry: RefRegistry
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "surface_id": leaf.surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: leaf.surfaceId),
            "pane_id": leaf.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: leaf.paneId),
            "kind": kind,
            "title": title,
            "match_count": hits.count,
            "matches": hits
        ]
        if !url.isEmpty { entry["url"] = url }
        return entry
    }
}

/// Accumulates results across the synchronous terminal pass and the async
/// browser evals. Single-threaded by construction: everything runs on the
/// GTK main loop, which is also why no lock is needed.
final class PaneSearchCollector {
    var results: [[String: Any]] = []
    var searched = 0
    var outstanding = 0
}

// Envelope helpers, file-local like BrowserAutomation's `baOk`/`baError`
// (ControlProtocol keeps its own private). Same wire shape.
extension ControlCommandHandler {
    fileprivate func psOk(id: Any?, result: [String: Any]) -> String {
        psEncode(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    fileprivate func psError(id: Any?, code: String, message: String) -> String {
        psEncode(["id": id ?? NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }

    fileprivate func psEncode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }
}
