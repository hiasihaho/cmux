// Linux compatibility for CmuxSettings — see CmuxFoundation's
// LinuxCompatibility.swift for the rationale; these are internal copies of
// the same stand-ins (the originals are internal to that module).
#if !canImport(Darwin)
import Foundation
import Glibc

/// BSD name; Linux spells it PATH_MAX.
let MAXPATHLEN = PATH_MAX

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
#endif // !canImport(Darwin)
