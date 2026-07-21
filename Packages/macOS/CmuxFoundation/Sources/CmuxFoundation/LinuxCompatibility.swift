// Linux compatibility layer for CmuxFoundation.
//
// Upstream code qualifies raw syscalls with `Darwin.`, logs through OSLog's
// interpolation (with `privacy:` markers), pins pipes with F_SETNOSIGPIPE,
// and coordinates callbacks with OSAllocatedUnfairLock. None of these exist
// on Linux; these stand-ins keep the call sites byte-identical.
#if !canImport(Darwin)
public import Foundation
import Glibc

enum Darwin {
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Glibc.read(fd, buf, count)
    }
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(fd, buf, count)
    }
    static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ nfds: nfds_t, _ timeout: Int32) -> Int32 {
        Glibc.poll(fds, nfds, timeout)
    }
}

/// Darwin-only pipe flag; Linux writers handle EPIPE/SIGPIPE via MSG_NOSIGNAL
/// or a process-wide SIG_IGN instead, so configuring it is a successful no-op.
let F_SETNOSIGPIPE: Int32 = -1
func fcntl(_ fd: Int32, _ cmd: Int32, _ value: Int32) -> Int32 {
    if cmd == F_SETNOSIGPIPE { return 0 }
    return Glibc.fcntl(fd, cmd, value)
}

/// Minimal OSLog Logger stand-in: accepts the same interpolations (the
/// `privacy:` argument is consumed by the interpolation overloads below)
/// and writes nothing — CLI logging on Linux goes to stderr at call sites
/// that matter, not to a system journal.
struct Logger {
    init(subsystem: String, category: String) {}
    func debug(_ message: LinuxLogMessage) {}
    func info(_ message: LinuxLogMessage) {}
    func warning(_ message: LinuxLogMessage) {}
    func error(_ message: LinuxLogMessage) {}
}

struct LinuxLogPrivacy {
    static let `public` = LinuxLogPrivacy()
    static let `private` = LinuxLogPrivacy()
}

struct LinuxLogMessage: ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {}
    init(stringInterpolation: Interpolation) {}
    struct Interpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) {}
        mutating func appendInterpolation<T>(_ value: T) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: LinuxLogPrivacy) {}
    }
}

/// NSLock-backed stand-in for OSAllocatedUnfairLock's withLock API.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(initialState: State) { self.state = initialState }
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif // !canImport(Darwin)
