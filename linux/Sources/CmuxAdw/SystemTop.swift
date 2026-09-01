import Foundation

/// `system.top` — CPU/memory attributed to the pane tree (macOS calls it the
/// task manager). Two consumers, and the second is the reason this is not a
/// nicety:
///
///  1. `cmux top` for humans: per-window/workspace/pane/surface rows.
///  2. the CLI's `resolveAgentProcessTerminalBinding`, which asks "which
///     surface owns this pid?" to OVERRIDE a stale or leaked
///     `CMUX_SURFACE_ID` — the "codex jumble class", where an agent session
///     routes to the wrong pane and the wrong binding survives reloads.
///     Without this verb that correction can never fire on Linux.
///
/// Process facts come from /proc. CPU percent is cumulative-over-lifetime
/// ((utime+stime) / elapsed), exactly what `ps %CPU` reports — NOT a
/// sampled instantaneous share, because sampling would mean sleeping on the
/// GTK main thread. Documented rather than faked.
enum SystemTop {

    // MARK: - /proc snapshot

    struct ProcEntry {
        let pid: pid_t
        let ppid: pid_t
        let command: String
        let cpuSeconds: Double
        let cpuPercent: Double
        let memoryBytes: Int
    }

    private static let clockTicks: Double = {
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        return ticks > 0 ? Double(ticks) : 100
    }()

    private static let pageSize: Int = {
        let size = sysconf(Int32(_SC_PAGESIZE))
        return size > 0 ? Int(size) : 4096
    }()

    private static func systemUptimeSeconds() -> Double {
        guard let raw = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8),
              let first = raw.split(separator: " ").first,
              let value = Double(first) else { return 0 }
        return value
    }

    /// Where process facts come from. Inside a Flatpak the sandbox has its
    /// OWN pid namespace, so Ghostty's host-spawned shells (whose host pids
    /// the shim reports) cannot be resolved against the local /proc — the
    /// same number there is an unrelated process, or nothing.
    enum Source {
        case local
        /// Host /proc, read through `flatpak-spawn --host`. One spawn per
        /// snapshot, TTL-cached, because this runs on the GTK main thread.
        case host
    }

    /// One pass over /proc. Unreadable entries are skipped rather than
    /// guessed at: a process that vanished mid-walk is not an error.
    static func snapshot(source: Source = .local) -> [pid_t: ProcEntry] {
        if source == .host { return hostSnapshot() }
        let uptime = systemUptimeSeconds()
        var table: [pid_t: ProcEntry] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return table
        }
        for name in names {
            guard let pid = pid_t(name) else { continue }
            guard let stat = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8) else {
                continue
            }
            // comm can contain spaces and parentheses — split after the LAST
            // ')' , which is why naive whitespace splitting of /proc/pid/stat
            // is a classic bug.
            guard let commEnd = stat.lastIndex(of: ")") else { continue }
            let commStart = stat.firstIndex(of: "(")
            let comm = commStart.map { String(stat[stat.index(after: $0)..<commEnd]) } ?? ""
            let rest = stat[stat.index(after: commEnd)...]
                .split(separator: " ", omittingEmptySubsequences: true)
            // rest[0] = state, [1] = ppid … indices are the man-page fields
            // minus 3 (pid, comm, and the state we are counting from).
            guard rest.count > 20,
                  let ppid = pid_t(rest[1]),
                  let utime = Double(rest[11]),
                  let stime = Double(rest[12]),
                  let startTicks = Double(rest[19]) else { continue }
            let cpuSeconds = (utime + stime) / clockTicks
            let elapsed = max(uptime - startTicks / clockTicks, 0.001)
            let rssPages = Double(rest[core: 21] ?? "0") ?? 0
            table[pid] = ProcEntry(
                pid: pid,
                ppid: ppid,
                command: commandLine(pid: name) ?? comm,
                cpuSeconds: cpuSeconds,
                cpuPercent: (cpuSeconds / elapsed) * 100,
                memoryBytes: Int(rssPages) * pageSize
            )
        }
        return table
    }

    /// Full argv, NUL-separated in /proc, falling back to the kernel's comm
    /// for kernel threads and for processes whose cmdline is unreadable.
    private static func commandLine(pid: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"),
              !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\0")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    // MARK: - host /proc (Flatpak)

    private static var hostCache: (taken: Date, table: [pid_t: ProcEntry])?
    private static let hostCacheTTL: TimeInterval = 2

    /// The host's process table, fetched with ONE `flatpak-spawn --host`
    /// per snapshot: /proc/uptime followed by every /proc/<pid>/stat. Only
    /// stat is read — it carries ppid, utime, stime, starttime and rss, so
    /// a second file per process (cmdline) would double the transfer for a
    /// nicer command string. `comm` from stat is the honest trade.
    ///
    /// Needs no new permission: `--talk-name=org.freedesktop.Flatpak` is
    /// already how pane shells reach the host. Cached briefly because this
    /// blocks the GTK main thread, and hard-timeout'd because a wedged
    /// portal must degrade to "unknown", never hang the app.
    private static func hostSnapshot() -> [pid_t: ProcEntry] {
        if let cache = hostCache, Date().timeIntervalSince(cache.taken) < hostCacheTTL {
            return cache.table
        }
        let script = "cat /proc/uptime; for f in /proc/[0-9]*/stat; do cat \"$f\" 2>/dev/null; done"
        guard let dump = runHost(["/usr/bin/flatpak-spawn", "--host", "sh", "-c", script]) else {
            return [:]
        }
        var lines = dump.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty,
              let uptime = Double(lines.removeFirst().split(separator: " ").first ?? "") else {
            return [:]
        }
        var table: [pid_t: ProcEntry] = [:]
        for line in lines {
            guard let entry = parseStat(String(line), uptime: uptime) else { continue }
            table[entry.pid] = entry
        }
        hostCache = (Date(), table)
        return table
    }

    private static func runHost(_ argv: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting: a full pipe buffer with a waiting parent is
        // the classic deadlock, and /proc of a busy host easily exceeds it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A single /proc/<pid>/stat line. Split after the LAST ')': comm can
    /// contain spaces and parentheses, which is what breaks naive parsers.
    private static func parseStat(_ stat: String, uptime: Double) -> ProcEntry? {
        guard let commEnd = stat.lastIndex(of: ")"),
              let openParen = stat.firstIndex(of: "(") else { return nil }
        guard let pid = pid_t(stat[stat.startIndex..<openParen].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let comm = String(stat[stat.index(after: openParen)..<commEnd])
        let rest = stat[stat.index(after: commEnd)...]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard rest.count > 21,
              let ppid = pid_t(rest[1]),
              let utime = Double(rest[11]),
              let stime = Double(rest[12]),
              let startTicks = Double(rest[19]),
              let rssPages = Double(rest[21]) else { return nil }
        let cpuSeconds = (utime + stime) / clockTicks
        let elapsed = max(uptime - startTicks / clockTicks, 0.001)
        return ProcEntry(
            pid: pid,
            ppid: ppid,
            command: comm,
            cpuSeconds: cpuSeconds,
            cpuPercent: (cpuSeconds / elapsed) * 100,
            memoryBytes: Int(rssPages) * pageSize
        )
    }

    /// pid → children, built once so each surface's subtree is a walk rather
    /// than a rescan.
    static func childIndex(_ table: [pid_t: ProcEntry]) -> [pid_t: [pid_t]] {
        var index: [pid_t: [pid_t]] = [:]
        for entry in table.values {
            index[entry.ppid, default: []].append(entry.pid)
        }
        return index
    }

    /// The process subtree rooted at `pid`, as nested payload dictionaries.
    /// Depth-bounded: a pid cycle (impossible in a sane /proc, cheap to
    /// guard) must not hang the main loop.
    static func processTree(
        root: pid_t,
        table: [pid_t: ProcEntry],
        children: [pid_t: [pid_t]],
        depth: Int = 0
    ) -> [String: Any]? {
        guard depth < 32, let entry = table[root] else { return nil }
        let kids = (children[root] ?? [])
            .compactMap { processTree(root: $0, table: table, children: children, depth: depth + 1) }
        return [
            "pid": Int(entry.pid),
            "ppid": Int(entry.ppid),
            "command": entry.command,
            "cpu_percent": entry.cpuPercent,
            "cpu_seconds": entry.cpuSeconds,
            "memory_bytes": entry.memoryBytes,
            "children": kids
        ]
    }

    /// Aggregate over a subtree without double-counting a pid.
    static func aggregate(
        roots: [pid_t],
        table: [pid_t: ProcEntry],
        children: [pid_t: [pid_t]]
    ) -> (cpu: Double, memory: Int, count: Int) {
        var seen: Set<pid_t> = []
        var stack = roots
        var cpu = 0.0
        var memory = 0
        while let pid = stack.popLast() {
            guard !seen.contains(pid), let entry = table[pid] else { continue }
            seen.insert(pid)
            cpu += entry.cpuPercent
            memory += entry.memoryBytes
            stack.append(contentsOf: children[pid] ?? [])
        }
        return (cpu, memory, seen.count)
    }
}

private extension Array where Element == Substring {
    /// Field access that tolerates a short /proc line instead of trapping.
    subscript(core index: Int) -> String? {
        indices.contains(index) ? String(self[index]) : nil
    }
}
