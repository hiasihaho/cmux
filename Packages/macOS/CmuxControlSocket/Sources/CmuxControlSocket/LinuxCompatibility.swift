// Linux compatibility for CmuxControlSocket (client side; the Server/ tree
// is Darwin-only and compiled out).
#if !canImport(Darwin)
import Foundation
import Glibc
import Crypto

// Glibc exposes SOCK_STREAM as `__socket_type`, not Int32.
let SOCK_STREAM = Int32(Glibc.SOCK_STREAM.rawValue)

enum Darwin {
    static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
        Glibc.connect(fd, addr, len)
    }
    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Glibc.read(fd, buf, count)
    }
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(fd, buf, count)
    }
    static func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
        Glibc.socket(domain, type, proto)
    }
}

/// swift-crypto's SymmetricKey predates Sendable audits; the key is an
/// immutable byte box, so the retroactive conformance is sound.
extension SymmetricKey: @retroactive @unchecked Sendable {}

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

struct Logger {
    init(subsystem: String, category: String) {}
    func debug(_ m: LinuxLogMessage) {}
    func info(_ m: LinuxLogMessage) {}
    func warning(_ m: LinuxLogMessage) {}
    func error(_ m: LinuxLogMessage) {}
}
struct LinuxLogPrivacy { static let `public` = LinuxLogPrivacy(); static let `private` = LinuxLogPrivacy() }
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
#endif // !canImport(Darwin)
