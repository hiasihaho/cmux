import Adwaita
import Foundation
import Glibc

/// AF_UNIX control-socket server — Linux counterpart of the socket half of
/// `TerminalController` in the macOS app. Speaks the same newline-delimited
/// protocol: one request line per connection, one response line back.
///
/// Command handling is marshalled onto the GTK main loop via `Idle` (GLib
/// idle sources), because Meta/Adwaita state may only be mutated there.
/// Handlers reply through a completion instead of a return value, so verbs
/// backed by async GLib/WebKit callbacks (browser JS evaluation) can finish
/// later without ever blocking the main loop — only the per-connection
/// socket thread waits.
final class ControlSocketServer {

    static let shared = ControlSocketServer()

    /// Runs on the GTK main thread; full request line in, one response line
    /// out through the completion — which may be called synchronously or
    /// from a later main-loop callback, but exactly once either way.
    var dispatcher: ((String, @escaping (String) -> Void) -> Void)?

    private var listenFD: Int32 = -1
    private var started = false
    private(set) var path: String = ""

    /// Same resolution order as the macOS app/CLI: explicit override first,
    /// then the per-user XDG runtime dir (Linux-idiomatic replacement for
    /// macOS's fixed `/tmp/cmux.sock`).
    static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["CMUX_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        if let runtimeDir = environment["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty {
            // Inside a flatpak the bare runtime dir is a private tmpfs;
            // app/<id>/ is the one subpath the HOST also sees, so
            // host-side CLI/hooks/agents can reach the socket
            // (feature 15 round 2, probe-verified 2026-08-20).
            if let appId = environment["FLATPAK_ID"], !appId.isEmpty {
                return runtimeDir + "/app/" + appId + "/cmux.sock"
            }
            return runtimeDir + "/cmux.sock"
        }
        return "/tmp/cmux-\(getuid()).sock"
    }

    func start(path: String = ControlSocketServer.defaultSocketPath()) {
        guard !started else { return }
        started = true
        self.path = path

        // A client hanging up mid-response must not kill the app.
        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("cmux: cannot create control socket\n".utf8))
            return
        }

        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLength else {
            FileHandle.standardError.write(Data("cmux: socket path too long: \(path)\n".utf8))
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            FileHandle.standardError.write(Data("cmux: cannot bind \(path): \(String(cString: strerror(errno)))\n".utf8))
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 5) == 0 else {
            FileHandle.standardError.write(Data("cmux: cannot listen on \(path)\n".utf8))
            close(fd)
            return
        }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "cmux-control-socket"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        if !path.isEmpty { unlink(path) }
        started = false
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                break
            }
            let thread = Thread { [weak self] in self?.handleConnection(clientFD) }
            thread.name = "cmux-control-client"
            thread.start()
        }
    }

    /// Matches the macOS server: a connection carries any number of
    /// newline-delimited request/response rounds until the client hangs up.
    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let maxRequest = 1 << 20

        while pending.count < maxRequest {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])

            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty else { continue }

                let response = dispatchOnMainLoop(line)
                guard writeAll(fd, response + "\n") else { return }
            }
        }
    }

    private func writeAll(_ fd: Int32, _ string: String) -> Bool {
        let out = Array(string.utf8)
        var offset = 0
        while offset < out.count {
            let sent = out.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), out.count - offset)
            }
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }

    private func dispatchOnMainLoop(_ line: String) -> String {
        guard let dispatcher else { return "ERROR: App not ready" }
        let response = OneShotResponse()
        Idle {
            dispatcher(line) { response.fulfill($0) }
        }
        if let value = response.wait(seconds: Self.responseBudget(for: line)) { return value }
        // v2 clients need a JSON envelope even for transport-level timeouts.
        if line.hasPrefix("{") {
            return #"{"id":null,"ok":false,"error":{"code":"timeout","message":"Command timed out"}}"#
        }
        return "ERROR: Command timed out"
    }

    /// Verbs that carry their own `timeout_ms` (browser wait/navigate/
    /// download) must outlive it. A flat cap silently truncated them and
    /// reported a transport timeout that reads exactly like the condition
    /// never being met — the caller cannot tell "your predicate failed"
    /// from "we hung up on you first".
    private static func responseBudget(for line: String) -> Double {
        let floor = 15.0
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any] else { return floor }
        let requested: Int?
        if let value = params["timeout_ms"] as? Int {
            requested = value
        } else if let value = params["timeout_ms"] as? NSNumber {
            requested = value.intValue
        } else {
            requested = nil
        }
        guard let requested, requested > 0 else { return floor }
        return max(floor, Double(requested) / 1000.0 + 5.0)
    }
}

/// Thread-safe, take-once handoff between the main loop (fulfilling, maybe
/// from an async WebKit callback) and the socket client thread (waiting).
/// After a timeout the slot is poisoned so a late fulfillment is dropped
/// instead of racing the next request on the connection.
private final class OneShotResponse {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?
    private var closed = false

    func fulfill(_ response: String) {
        lock.lock()
        let accepted = !closed
        if accepted {
            value = response
            closed = true
        }
        lock.unlock()
        if accepted { semaphore.signal() }
    }

    func wait(seconds: Double) -> String? {
        _ = semaphore.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return value
    }
}
