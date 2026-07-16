import Adwaita
import Foundation
import Glibc

/// AF_UNIX control-socket server — Linux counterpart of the socket half of
/// `TerminalController` in the macOS app. Speaks the same newline-delimited
/// protocol: one request line per connection, one response line back.
///
/// Command handling is marshalled onto the GTK main loop via `Idle` (GLib
/// idle sources), because Meta/Adwaita state may only be mutated there.
final class ControlSocketServer {

    static let shared = ControlSocketServer()

    /// Runs on the GTK main thread; full request line in, response line out.
    var dispatcher: ((String) -> String)?

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
        let semaphore = DispatchSemaphore(value: 0)
        var result = "ERROR: Command timed out"
        Idle {
            result = dispatcher(line)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }
}
